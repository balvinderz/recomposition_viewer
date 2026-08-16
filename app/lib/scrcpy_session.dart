import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:scrcpy_video_view/scrcpy_video_view.dart';

enum ScrcpyStatus { idle, starting, streaming, stopping, error }

class ScrcpySession extends ChangeNotifier {
  ScrcpySession()
    : player = Player(
        configuration: const PlayerConfiguration(
          title: 'Recomposition Viewer device preview',
          bufferSize: 512 * 1024,
        ),
      ) {
    videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _subscriptions.add(player.stream.width.listen(_onWidth));
    _subscriptions.add(player.stream.height.listen(_onHeight));
    _subscriptions.add(player.stream.error.listen(_onPlayerError));
  }

  final Player player;
  late final VideoController videoController;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  ScrcpyStatus status = ScrcpyStatus.idle;
  String? message;
  String? serial;
  int? frameWidth;
  int? frameHeight;
  int? deviceWidth;
  int? deviceHeight;

  Process? _scrcpyProcess;
  Directory? _temporaryDirectory;
  HttpServer? _streamServer;
  ScrcpyVideoController? _directController;
  VoidCallback? _directListener;
  int _generation = 0;
  bool _disposed = false;

  bool get isActive =>
      status == ScrcpyStatus.starting ||
      status == ScrcpyStatus.streaming ||
      status == ScrcpyStatus.stopping;

  bool get isDirect => _directController != null;

  ScrcpyVideoController? get directVideoController => _directController;

  Future<void> start(String deviceSerial) async {
    if (isActive && serial == deviceSerial) return;
    if (isActive) await stop();

    final generation = ++_generation;
    serial = deviceSerial;
    status = ScrcpyStatus.starting;
    message = null;
    frameWidth = null;
    frameHeight = null;
    deviceWidth = null;
    deviceHeight = null;
    notifyListeners();

    try {
      if (!Platform.isMacOS) {
        throw UnsupportedError('The embedded device preview requires macOS.');
      }
      final scrcpy = _findExecutable('scrcpy');
      final adb = _findExecutable('adb');
      await _readDeviceSize(adb, deviceSerial);

      await player.stop();
      try {
        await _startDirectStream(
          serial: deviceSerial,
          adb: adb,
          scrcpy: scrcpy,
          generation: generation,
        );
        return;
      } catch (directError) {
        if (generation != _generation) return;
        await _cleanUpDirectResources();
        status = ScrcpyStatus.starting;
        message =
            'Direct VideoToolbox preview unavailable; using compatibility '
            'stream. ${_friendlyError(directError)}';
        _safeNotify();
      }

      await _startCompatibilityStream(
        serial: deviceSerial,
        scrcpy: scrcpy,
        generation: generation,
      );
    } catch (error) {
      if (generation != _generation) return;
      await _cleanUpResources(stopPlayer: true);
      status = ScrcpyStatus.error;
      message = _friendlyError(error);
      _safeNotify();
    }
  }

  Future<void> _startDirectStream({
    required String serial,
    required String adb,
    required String scrcpy,
    required int generation,
  }) async {
    final controller = ScrcpyVideoController(
      configuration: ScrcpyVideoConfiguration(adbPath: adb, scrcpyPath: scrcpy),
    );
    _directController = controller;
    var startCompleted = false;

    void syncPluginState() {
      if (generation != _generation || _disposed) return;
      frameWidth = controller.videoWidth;
      frameHeight = controller.videoHeight;
      if (controller.state == ScrcpyVideoState.streaming) {
        status = ScrcpyStatus.streaming;
        message = null;
      } else if (controller.state == ScrcpyVideoState.error && startCompleted) {
        unawaited(
          _handleDirectPluginError(
            controller,
            controller.error ?? 'Direct stream failed',
            generation,
          ),
        );
      }
      _safeNotify();
    }

    _directListener = syncPluginState;
    controller.addListener(syncPluginState);
    await controller.start(serial);
    startCompleted = true;
  }

  Future<void> _handleDirectPluginError(
    ScrcpyVideoController controller,
    Object error,
    int generation,
  ) async {
    if (generation != _generation ||
        _disposed ||
        _directController != controller) {
      return;
    }
    await _cleanUpDirectResources();
    if (generation != _generation || _disposed) return;
    frameWidth = null;
    frameHeight = null;
    status = ScrcpyStatus.error;
    message = 'Direct preview: ${_friendlyError(error)}';
    _safeNotify();
  }

  Future<void> _startCompatibilityStream({
    required String serial,
    required String scrcpy,
    required int generation,
  }) async {
    await _configurePlayerForLowLatency();
    final temp = await Directory.systemTemp.createTemp('recomposition_scrcpy_');
    _temporaryDirectory = temp;
    final pipePath = '${temp.path}/video.mkv';
    final fifo = await Process.run('/usr/bin/mkfifo', [pipePath]);
    if (fifo.exitCode != 0) {
      throw StateError(_processFailure('Could not create video pipe', fifo));
    }
    final streamUrl = await _startStreamRelay(pipePath, generation);

    final process = await Process.start(scrcpy, [
      '--serial=$serial',
      '--no-window',
      '--no-audio',
      '--no-control',
      '--video-codec=h264',
      '--video-bit-rate=8M',
      '--max-fps=60',
      '--max-size=1920',
      '--record=$pipePath',
      '--record-format=mkv',
    ]);
    _scrcpyProcess = process;
    _pipeProcessOutput(process.stdout, generation);
    _pipeProcessOutput(process.stderr, generation);
    unawaited(_watchProcess(process, generation));

    await player.open(Media(streamUrl), play: true);
    _safeNotify();
  }

  Future<void> stop() async {
    if (status == ScrcpyStatus.idle) return;
    ++_generation;
    status = ScrcpyStatus.stopping;
    message = null;
    notifyListeners();

    await _cleanUpResources(stopPlayer: true);
    frameWidth = null;
    frameHeight = null;
    status = ScrcpyStatus.idle;
    _safeNotify();
  }

  Future<void> _readDeviceSize(String adb, String deviceSerial) async {
    final result = await Process.run(adb, [
      '-s',
      deviceSerial,
      'shell',
      'wm',
      'size',
    ]);
    if (result.exitCode != 0) return;
    final matches = RegExp(
      r'(?:Override|Physical) size:\s*(\d+)x(\d+)',
    ).allMatches('${result.stdout}').toList();
    if (matches.isEmpty) return;
    final match = matches.last;
    deviceWidth = int.tryParse(match.group(1)!);
    deviceHeight = int.tryParse(match.group(2)!);
  }

  void _onWidth(int? width) {
    frameWidth = width;
    _markStreamingWhenReady();
  }

  void _onHeight(int? height) {
    frameHeight = height;
    _markStreamingWhenReady();
  }

  void _markStreamingWhenReady() {
    if (status == ScrcpyStatus.starting &&
        frameWidth != null &&
        frameHeight != null) {
      status = ScrcpyStatus.streaming;
      message = null;
    }
    _safeNotify();
  }

  void _onPlayerError(String error) {
    if (status == ScrcpyStatus.stopping || status == ScrcpyStatus.idle) return;
    message = error;
    _safeNotify();
  }

  void _pipeProcessOutput(Stream<List<int>> stream, int generation) {
    stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      if (generation == _generation && line.contains('ERROR')) {
        message = line.trim();
        _safeNotify();
      }
    });
  }

  Future<String> _startStreamRelay(String pipePath, int generation) async {
    var claimed = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _streamServer = server;
    server.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.headers.contentType = ContentType(
          'video',
          'x-matroska',
        );
        await request.response.close();
        return;
      }
      if (request.method != 'GET' || claimed || generation != _generation) {
        request.response.statusCode = HttpStatus.conflict;
        await request.response.close();
        return;
      }

      claimed = true;
      request.response.headers.contentType = ContentType('video', 'x-matroska');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.bufferOutput = false;
      try {
        await request.response.addStream(File(pipePath).openRead());
      } catch (error) {
        if (generation == _generation && status != ScrcpyStatus.stopping) {
          message = 'Stream relay: $error';
          _safeNotify();
        }
      } finally {
        await request.response.close();
      }
    });
    return 'http://${server.address.address}:${server.port}/stream.mkv';
  }

  Future<void> _configurePlayerForLowLatency() async {
    final nativePlayer = player.platform as NativePlayer;
    await nativePlayer.command(['apply-profile', 'low-latency']);
    await nativePlayer.setProperty('cache', 'no');
    await nativePlayer.setProperty('cache-on-disk', 'no');
    await nativePlayer.setProperty('cache-pause', 'no');
    await nativePlayer.setProperty('demuxer-readahead-secs', '0');
  }

  Future<void> _watchProcess(Process process, int generation) async {
    final exitCode = await process.exitCode;
    if (generation != _generation || _disposed) return;

    _scrcpyProcess = null;
    await player.stop();
    await _closeStreamRelay();
    await _deleteTemporaryDirectory();
    frameWidth = null;
    frameHeight = null;
    status = ScrcpyStatus.error;
    message = exitCode == 0
        ? 'Device preview ended unexpectedly.'
        : 'scrcpy exited with code $exitCode.';
    _safeNotify();
  }

  Future<void> _cleanUpResources({required bool stopPlayer}) async {
    await _cleanUpDirectResources();

    final process = _scrcpyProcess;
    _scrcpyProcess = null;
    if (process != null) {
      process.kill(ProcessSignal.sigint);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigterm);
      }
    }
    if (stopPlayer) await player.stop();
    await _closeStreamRelay();
    await _deleteTemporaryDirectory();
  }

  Future<void> _cleanUpDirectResources() async {
    final controller = _directController;
    final listener = _directListener;
    _directController = null;
    _directListener = null;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    await controller?.stop();
    controller?.dispose();
  }

  Future<void> _closeStreamRelay() async {
    final server = _streamServer;
    _streamServer = null;
    await server?.close(force: true);
  }

  Future<void> _deleteTemporaryDirectory() async {
    final directory = _temporaryDirectory;
    _temporaryDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  static String _findExecutable(String name) {
    final candidates = <String>[
      ...?Platform.environment['PATH']
          ?.split(':')
          .map((directory) => '$directory/$name'),
      '/opt/homebrew/bin/$name',
      '/usr/local/bin/$name',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    throw StateError('$name was not found. Install it with Homebrew.');
  }

  static String _processFailure(String prefix, ProcessResult result) {
    final detail = '${result.stderr}'.trim();
    return detail.isEmpty
        ? '$prefix (exit ${result.exitCode})'
        : '$prefix: $detail';
  }

  static String _friendlyError(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is UnsupportedError) return error.message.toString();
    if (error is ProcessException) return error.message;
    return error.toString();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _cleanUpResources(stopPlayer: true);
    await player.dispose();
  }
}

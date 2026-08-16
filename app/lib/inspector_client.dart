import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract class InspectorClient {
  Future<void> start();
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]);
  Future<void> dispose();
}

class InspectorClientException implements Exception {
  const InspectorClientException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ProcessInspectorClient implements InspectorClient {
  Process? _process;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final StringBuffer _recentErrors = StringBuffer();

  @override
  Future<void> start() async {
    if (_process != null) return;
    final environment = Platform.environment;
    final backend = _resolveBackend(environment);
    try {
      _process = await Process.start(
        environment['UV'] ?? 'uv',
        backend.arguments,
        environment: {
          ...environment,
          'PATH':
              '${environment['PATH'] ?? ''}:/opt/homebrew/bin:/usr/local/bin',
        },
      );
    } on ProcessException catch (error) {
      throw InspectorClientException(
        'Could not start the inspector backend: ${error.message}. '
        'Install uv with `brew install uv`, or set UV to its executable path.',
      );
    }
    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _recentErrors.writeln(line);
        });
    unawaited(
      _process!.exitCode.then((code) {
        final detail = _recentErrors.toString().trim();
        final error = InspectorClientException(
          'Inspector backend exited with code $code${detail.isEmpty ? '' : ': $detail'}',
        );
        for (final completer in _pending.values) {
          if (!completer.isCompleted) completer.completeError(error);
        }
        _pending.clear();
        _process = null;
      }),
    );
  }

  _BackendLaunch _resolveBackend(Map<String, String> environment) {
    final configuredProject = environment['ANDROID_COMPOSE_INSPECTOR_PROJECT'];
    if (configuredProject != null && configuredProject.isNotEmpty) {
      return _BackendLaunch.forProject(configuredProject);
    }

    final configuredWheel = environment['ANDROID_COMPOSE_INSPECTOR_WHEEL'];
    if (configuredWheel != null && configuredWheel.isNotEmpty) {
      return _BackendLaunch.forWheel(configuredWheel);
    }

    final project = _findBackendProject();
    if (project != null) return _BackendLaunch.forProject(project);

    final executable = File(Platform.resolvedExecutable);
    final appContents = executable.parent.parent;
    final backendDirectory = Directory('${appContents.path}/Resources/backend');
    if (backendDirectory.existsSync()) {
      final bundledWheels = backendDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.whl'))
          .toList();
      if (bundledWheels.length == 1) {
        return _BackendLaunch.forWheel(bundledWheels.single.path);
      }
    }

    throw const InspectorClientException(
      'Could not find the inspector backend. Run the app from the repository, '
      'use scripts/build_macos.sh to create a distributable app, or set '
      'ANDROID_COMPOSE_INSPECTOR_PROJECT.',
    );
  }

  String? _findBackendProject() {
    final roots = <Directory>{
      Directory.current.absolute,
      File(Platform.resolvedExecutable).parent.absolute,
    };
    for (final root in roots) {
      Directory current = root;
      for (var depth = 0; depth < 8; depth++) {
        final candidate = Directory(
          '${current.path}/plugins/android-compose-inspector',
        );
        if (File('${candidate.path}/pyproject.toml').existsSync()) {
          return candidate.path;
        }
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }
    return null;
  }

  void _handleLine(String line) {
    try {
      final response = jsonDecode(line) as Map<String, dynamic>;
      final id = (response['id'] as num).toInt();
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (response['ok'] == true) {
        completer.complete(
          (response['result'] as Map<dynamic, dynamic>).cast<String, dynamic>(),
        );
      } else {
        final error = response['error'] as Map<String, dynamic>?;
        completer.completeError(
          InspectorClientException(
            error?['message'] as String? ?? 'Inspector command failed',
          ),
        );
      }
    } catch (error) {
      _recentErrors.writeln('Invalid backend response: $line ($error)');
    }
  }

  @override
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    await start();
    final process = _process;
    if (process == null) {
      throw const InspectorClientException('Inspector backend is not running');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    process.stdin.writeln(
      jsonEncode({'id': id, 'command': command, 'arguments': arguments}),
    );
    await process.stdin.flush();
    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _pending.remove(id);
        throw InspectorClientException('$command timed out');
      },
    );
  }

  @override
  Future<void> dispose() async {
    final process = _process;
    if (process == null) return;
    try {
      await send('shutdown').timeout(const Duration(seconds: 4));
    } catch (_) {
      process.kill();
    }
    await process.stdin.close();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _process = null;
  }
}

class _BackendLaunch {
  const _BackendLaunch(this.arguments);

  factory _BackendLaunch.forProject(String path) => _BackendLaunch([
    'run',
    '--quiet',
    '--project',
    path,
    '--python',
    '3.11',
    'python',
    '-m',
    'android_compose_inspector.bridge',
  ]);

  factory _BackendLaunch.forWheel(String path) => _BackendLaunch([
    'run',
    '--quiet',
    '--no-project',
    '--python',
    '3.11',
    '--with',
    path,
    'python',
    '-m',
    'android_compose_inspector.bridge',
  ]);

  final List<String> arguments;
}

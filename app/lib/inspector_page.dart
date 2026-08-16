import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:scrcpy_video_view/scrcpy_video_view.dart';

import 'inspector_client.dart';
import 'hierarchy_geometry.dart';
import 'hierarchy_projection.dart';
import 'models.dart';
import 'preview_geometry.dart';
import 'preview_hit_testing.dart';
import 'scrcpy_session.dart';

export 'inspector_client.dart' show InspectorClient;

/// Coordinates the inspector lifecycle and presents hierarchy, metrics, and
/// device preview in a three-pane desktop workspace.
class InspectorPage extends StatefulWidget {
  const InspectorPage({super.key, this.client, this.enablePreview = true});

  final InspectorClient? client;
  final bool enablePreview;

  @override
  State<InspectorPage> createState() => _InspectorPageState();
}

class _InspectorPageState extends State<InspectorPage> {
  late final InspectorClient _client;
  late final bool _ownsClient;
  ScrcpySession? _previewSession;
  final _packageController = TextEditingController(text: 'com.example.app');
  final _searchController = TextEditingController();
  final _treeHorizontalController = ScrollController();
  final _treeVerticalController = ScrollController();

  List<DeviceInfo> _devices = const [];
  String? _selectedSerial;
  InspectorStatus? _status;
  List<ComposableNode> _nodes = const [];
  final List<int> _activityHistory = [];
  final Set<String> _collapsedNodeIdentities = {};
  String? _selectedNodeIdentity;
  Timer? _pollTimer;
  Timer? _retryTimer;
  DateTime? _trackingStartedAt;
  DateTime? _lastCapture;
  bool _backendReady = false;
  bool _busy = false;
  bool _pollInFlight = false;
  bool _recovering = false;
  bool _selectionInitialized = false;
  int _consecutivePollFailures = 0;
  bool _hideFramework = true;
  String? _error;
  NodeSort _sort = NodeSort.tree;

  bool get _attached => _status?.attached ?? false;
  bool get _tracking => _status?.tracking ?? false;

  // Backend and device lifecycle ------------------------------------------------

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.client == null;
    _client = widget.client ?? ProcessInspectorClient();
    if (widget.enablePreview) {
      _previewSession = ScrcpySession()..addListener(_onPreviewChanged);
    }
    _treeHorizontalController.addListener(_repaintTreeScroll);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    _setBusy(true);
    try {
      await _client.start();
      final prerequisites = await _client.send('prerequisites');
      if (prerequisites['ready'] != true) {
        throw InspectorClientException(
          'Backend prerequisites are incomplete: $prerequisites',
        );
      }
      await _refreshDevices();
      if (mounted) {
        setState(() {
          _backendReady = true;
          _error = null;
        });
      }
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _refreshDevices() async {
    try {
      final response = await _client.send('devices');
      final devices = (response['devices'] as List<dynamic>? ?? const [])
          .map(
            (item) => DeviceInfo.fromJson(
              (item as Map<dynamic, dynamic>).cast<String, dynamic>(),
            ),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        if (devices.isEmpty) {
          _selectedSerial = null;
        } else if (!devices.any((device) => device.serial == _selectedSerial)) {
          _selectedSerial = devices.first.serial;
        }
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _attach() async {
    final package = _packageController.text.trim();
    if (package.isEmpty) {
      _showError(const InspectorClientException('Enter an application ID'));
      return;
    }
    _setBusy(true);
    try {
      final response = await _client.send('attach', {
        'package': package,
        if (_selectedSerial != null) 'device': _selectedSerial,
      });
      if (!mounted) return;
      setState(() {
        _status = InspectorStatus.fromJson(response);
        _nodes = const [];
        _collapsedNodeIdentities.clear();
        _selectedNodeIdentity = null;
        _selectionInitialized = false;
        _activityHistory.clear();
        _error = null;
      });
      final trackingResponse = await _client.send('start', {'reset': true});
      if (!mounted) return;
      setState(() {
        _status = InspectorStatus.fromJson(trackingResponse);
        _trackingStartedAt = DateTime.now();
        _recovering = false;
        _consecutivePollFailures = 0;
        _retryTimer?.cancel();
      });
      final preview = _previewSession;
      final serial = _status?.device ?? _selectedSerial;
      if (preview != null && serial != null) {
        unawaited(preview.start(serial));
      }
      _startPolling();
      await _pollSnapshot();
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _startTracking() async {
    _setBusy(true);
    try {
      final response = await _client.send('start', {'reset': false});
      if (!mounted) return;
      setState(() {
        _status = InspectorStatus.fromJson(response);
        _trackingStartedAt ??= DateTime.now();
        _recovering = false;
        _consecutivePollFailures = 0;
        _retryTimer?.cancel();
        _error = null;
      });
      _startPolling();
      await _pollSnapshot();
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _resetCounts() async {
    _setBusy(true);
    try {
      await _client.send('reset');
      if (mounted) {
        setState(() {
          _nodes = const [];
          _activityHistory.clear();
          _trackingStartedAt = _tracking ? DateTime.now() : null;
        });
      }
      await _pollSnapshot();
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _stopTracking() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setBusy(true);
    try {
      final response = await _client.send('stop');
      if (mounted) {
        setState(() => _status = InspectorStatus.fromJson(response));
      }
      await _pollSnapshot();
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _detach() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setBusy(true);
    try {
      await _previewSession?.stop();
      await _client.send('detach');
      if (!mounted) return;
      setState(() {
        _status = null;
        _nodes = const [];
        _collapsedNodeIdentities.clear();
        _selectedNodeIdentity = null;
        _selectionInitialized = false;
        _activityHistory.clear();
        _trackingStartedAt = null;
        _lastCapture = null;
        _recovering = false;
        _consecutivePollFailures = 0;
        _error = null;
      });
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _pollSnapshot() async {
    if (!_attached || _pollInFlight) return;
    if (_retryTimer?.isActive ?? false) return;
    _pollInFlight = true;
    try {
      final response = await _client.send('snapshot', {
        'app_only': _hideFramework,
      });
      final nodes = (response['nodes'] as List<dynamic>? ?? const [])
          .map(
            (item) => ComposableNode.fromJson(
              (item as Map<dynamic, dynamic>).cast<String, dynamic>(),
            ),
          )
          .toList();
      final statusJson = response['status'];
      final snapshotStatus = statusJson is Map<dynamic, dynamic>
          ? InspectorStatus.fromJson(statusJson.cast<String, dynamic>())
          : null;
      if (!mounted) return;
      final recent = nodes.fold<int>(
        0,
        (sum, node) => sum + node.recompositionDelta,
      );
      setState(() {
        if (snapshotStatus != null) _status = snapshotStatus;
        _nodes = nodes;
        final identities = nodes.map((node) => node.identity).toSet();
        _collapsedNodeIdentities.retainWhere(identities.contains);
        if (_tracking) {
          _activityHistory.add(recent);
          if (_activityHistory.length > 60) _activityHistory.removeAt(0);
        }
        if (!_selectionInitialized) {
          _selectedNodeIdentity = nodes.firstOrNull?.identity;
          _selectionInitialized = nodes.isNotEmpty;
        } else if (_selectedNodeIdentity != null &&
            !nodes.any((node) => node.identity == _selectedNodeIdentity)) {
          // A lazy item can leave composition while scrolling. Do not silently
          // move the highlight to another instance from the same call site.
          _selectedNodeIdentity = null;
        }
        _lastCapture = DateTime.now();
        _recovering = false;
        _consecutivePollFailures = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
        _error = null;
      });
    } catch (error) {
      _consecutivePollFailures++;
      final delaySeconds = math.min(
        8,
        math.pow(2, _consecutivePollFailures - 1).toInt(),
      );
      if (mounted) {
        setState(() {
          _recovering = true;
          _error = '$error · retrying automatically';
        });
      }
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(seconds: delaySeconds), () {
        _retryTimer = null;
        unawaited(_pollSnapshot());
      });
    } finally {
      _pollInFlight = false;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _pollTimer = Timer.periodic(
      // Bounds are positional data, not just counters. Keep the overlay close
      // to the live video while _pollInFlight prevents overlapping requests.
      const Duration(milliseconds: 300),
      (_) => unawaited(_pollSnapshot()),
    );
  }

  void _repaintTreeScroll() {
    if (mounted) setState(() {});
  }

  // Preview selection and hierarchy reveal -------------------------------------

  void _onPreviewChanged() {
    if (mounted) setState(() {});
  }

  void _scrollTreeHorizontally(double delta) {
    if (!_treeHorizontalController.hasClients) return;
    final position = _treeHorizontalController.position;
    final next = (_treeHorizontalController.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _treeHorizontalController.jumpTo(next.toDouble());
  }

  void _selectNodeFromPreview({
    required Offset position,
    required Size viewportSize,
    required Size frameSize,
    required Size coordinateSize,
  }) {
    final node = findClosestComposableAtPreviewPoint(
      nodes: _nodes,
      position: position,
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: viewportSize,
    );
    if (node == null) return;
    final query = _searchController.text.trim().toLowerCase();
    final ancestorIdentities = hierarchyAncestorIdentities(
      _nodes,
      node.identity,
    );
    setState(() {
      _selectionInitialized = true;
      _selectedNodeIdentity = node.identity;
      _sort = NodeSort.tree;
      _collapsedNodeIdentities.removeAll(ancestorIdentities);
      if (query.isNotEmpty && !_nodeMatchesQuery(node, query)) {
        _searchController.clear();
      }
    });
    _revealSelectedNodeInHierarchy();
    unawaited(_pollSnapshot().whenComplete(_revealSelectedNodeInHierarchy));
  }

  bool _nodeMatchesQuery(ComposableNode node, String query) =>
      query.isEmpty ||
      node.name.toLowerCase().contains(query) ||
      node.source.toLowerCase().contains(query) ||
      node.path.toLowerCase().contains(query);

  void _revealSelectedNodeInHierarchy() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_treeVerticalController.hasClients) return;
      final identity = _selectedNodeIdentity;
      if (identity == null) return;
      final index = _visibleNodes.indexWhere(
        (node) => node.identity == identity,
      );
      if (index < 0) return;

      final position = _treeVerticalController.position;
      final target = centeredItemScrollOffset(
        index: index,
        itemExtent: 38,
        leadingPadding: 6,
        viewportExtent: position.viewportDimension,
        minScrollExtent: position.minScrollExtent,
        maxScrollExtent: position.maxScrollExtent,
      );
      // Snapshot polling rebuilds this list every 300 ms and can cancel a
      // driven scroll activity. A post-layout jump remains deterministic while
      // capture is live and places the selected row in the viewport at once.
      _treeVerticalController.jumpTo(target);

      if (_treeHorizontalController.hasClients) {
        final horizontalPosition = _treeHorizontalController.position;
        final horizontalTarget = selectedLabelHorizontalOffset(
          depth: _treeDepth(_visibleNodes[index]),
          indentExtent: 13,
          // The row uses an 18 px disclosure slot, a 4 px gap, a 14 px
          // composable icon, and an 8 px label gap.
          labelLeadingExtent: 44,
          viewportExtent: horizontalPosition.viewportDimension,
          minScrollExtent: horizontalPosition.minScrollExtent,
          maxScrollExtent: horizontalPosition.maxScrollExtent,
        );
        _treeHorizontalController.jumpTo(horizontalTarget);
      }
    });
  }

  void _setBusy(bool value) {
    if (mounted) setState(() => _busy = value);
  }

  void _showError(Object error) {
    if (mounted) setState(() => _error = error.toString());
  }

  bool get _collapseEnabled =>
      _sort == NodeSort.tree && _searchController.text.trim().isEmpty;

  // Tree projection and expansion state ----------------------------------------

  List<HierarchyRowData> get _visibleRows {
    final query = _searchController.text.trim().toLowerCase();
    if (_sort == NodeSort.tree) {
      return projectHierarchyRows(
        nodes: _nodes,
        collapsedNodeIdentities: _collapsedNodeIdentities,
        applyCollapse: query.isEmpty,
      ).where((row) => _nodeMatchesQuery(row.node, query)).toList();
    }

    final visible = _nodes
        .where((node) => _nodeMatchesQuery(node, query))
        .toList();
    switch (_sort) {
      case NodeSort.tree:
        throw StateError('Tree order is projected before flat sorting');
      case NodeSort.activity:
        visible.sort(compareNodesByRecompositionHeat);
      case NodeSort.recompositions:
        visible.sort((a, b) => b.recompositions.compareTo(a.recompositions));
      case NodeSort.skips:
        visible.sort((a, b) => b.skips.compareTo(a.skips));
      case NodeSort.name:
        visible.sort((a, b) => a.name.compareTo(b.name));
    }
    return visible
        .map((node) => HierarchyRowData(node: node, hasChildren: false))
        .toList();
  }

  List<ComposableNode> get _visibleNodes =>
      _visibleRows.map((row) => row.node).toList();

  void _toggleNodeExpansion(ComposableNode node) {
    setState(() {
      if (!_collapsedNodeIdentities.remove(node.identity)) {
        _collapsedNodeIdentities.add(node.identity);
        final selectedIdentity = _selectedNodeIdentity;
        if (selectedIdentity != null &&
            hierarchyAncestorIdentities(
              _nodes,
              selectedIdentity,
            ).contains(node.identity)) {
          _selectedNodeIdentity = node.identity;
        }
      }
    });
  }

  void _expandAllNodes() {
    setState(_collapsedNodeIdentities.clear);
  }

  void _collapseAllNodes() {
    final allRows = projectHierarchyRows(
      nodes: _nodes,
      collapsedNodeIdentities: const {},
      applyCollapse: false,
    );
    final selectedIdentity = _selectedNodeIdentity;
    final selectedAncestors = selectedIdentity == null
        ? const <String>[]
        : hierarchyAncestorIdentities(_nodes, selectedIdentity);
    setState(() {
      _collapsedNodeIdentities
        ..clear()
        ..addAll(
          allRows
              .where((row) => row.hasChildren)
              .map((row) => row.node.identity),
        );
      if (selectedAncestors.isNotEmpty) {
        _selectedNodeIdentity = selectedAncestors.first;
      }
    });
  }

  ComposableNode? get _selectedNode => _nodes
      .where((node) => node.identity == _selectedNodeIdentity)
      .firstOrNull;

  int _treeDepth(ComposableNode node) {
    if (_sort != NodeSort.tree) return 0;
    return math.max(0, node.depth);
  }

  String get _elapsed {
    final started = _trackingStartedAt;
    if (started == null) return '00:00';
    final duration = DateTime.now().difference(started);
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _packageController.dispose();
    _searchController.dispose();
    _treeHorizontalController.removeListener(_repaintTreeScroll);
    _treeHorizontalController.dispose();
    _treeVerticalController.dispose();
    _previewSession?.removeListener(_onPreviewChanged);
    _previewSession?.dispose();
    if (_ownsClient) unawaited(_client.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedNode;
    return Scaffold(
      body: Column(
        children: [
          _buildHeader(),
          _buildTargetBar(),
          _buildCaptureBar(),
          if (_error != null)
            _ErrorBanner(
              message: _error!,
              onClose: () => setState(() => _error = null),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildHierarchy()),
                Container(width: 1, color: _C.border),
                SizedBox(
                  width: _previewSession == null ? 420 : 380,
                  child: _buildDetails(selected),
                ),
                if (_previewSession != null) ...[
                  Container(width: 1, color: _C.border),
                  SizedBox(width: 360, child: _buildDevicePreview(selected)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Workspace panels ------------------------------------------------------------

  Widget _buildHeader() {
    final stateLabel = !_backendReady
        ? 'Starting backend'
        : _recovering
        ? 'Recovering inspector…'
        : _attached
        ? 'Attached · ${_status?.device}'
        : 'Ready to attach';
    final stateColor = !_backendReady
        ? _C.warning
        : _recovering
        ? _C.warning
        : _attached
        ? _C.positive
        : _C.muted;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: _C.header,
        border: Border(bottom: BorderSide(color: _C.border)),
      ),
      child: Row(
        children: [
          Image.asset(
            'assets/branding/logo_mark.png',
            width: 22,
            height: 22,
            filterQuality: FilterQuality.high,
          ),
          const SizedBox(width: 10),
          const Text(
            'Recomposition Viewer',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 9),
          const Spacer(),
          _Dot(color: stateColor),
          const SizedBox(width: 8),
          Text(stateLabel, style: _C.subtleText),
        ],
      ),
    );
  }

  Widget _buildTargetBar() {
    final selected = _devices
        .where((device) => device.serial == _selectedSerial)
        .firstOrNull;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: _C.toolbar,
        border: Border(bottom: BorderSide(color: _C.border)),
      ),
      child: Row(
        children: [
          const _Eyebrow('DEVICE'),
          const SizedBox(width: 10),
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<String>(
              key: const Key('device-dropdown'),
              initialValue: _selectedSerial,
              isExpanded: true,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(horizontal: 11),
              ),
              items: _devices
                  .map(
                    (device) => DropdownMenuItem(
                      value: device.serial,
                      child: Text(
                        '${device.model} · ${device.serial}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _attached
                  ? null
                  : (value) => setState(() => _selectedSerial = value),
            ),
          ),
          IconButton(
            tooltip: 'Refresh devices',
            onPressed: _busy || _attached
                ? null
                : () => unawaited(_refreshDevices()),
            icon: const Icon(Icons.refresh, size: 17),
          ),
          const SizedBox(width: 5),
          const _Eyebrow('APPLICATION ID'),
          const SizedBox(width: 10),
          SizedBox(
            width: 260,
            child: TextField(
              key: const Key('package-field'),
              controller: _packageController,
              enabled: !_attached,
              style: _C.monoBody,
              decoration: const InputDecoration(
                hintText: 'com.example.app',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 36,
            child: _attached
                ? OutlinedButton(
                    key: const Key('detach-button'),
                    onPressed: _busy ? null : _detach,
                    style: _outlineButtonStyle(),
                    child: const Text('Detach'),
                  )
                : FilledButton(
                    key: const Key('attach-button'),
                    onPressed: !_backendReady || _busy || _devices.isEmpty
                        ? null
                        : _attach,
                    style: _filledButtonStyle(),
                    child: Text(_busy ? 'Attaching…' : 'Attach'),
                  ),
          ),
          const Spacer(),
          _Dot(color: _attached ? _C.positive : _C.muted),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _attached
                  ? 'PID ${_status?.pid} · Compose ${_status?.composeVersion}'
                  : selected?.foregroundPackage == null
                  ? 'Detached'
                  : 'Foreground: ${selected!.foregroundPackage}',
              overflow: TextOverflow.ellipsis,
              style: _C.monoSubtle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: _C.toolbar,
        border: Border(bottom: BorderSide(color: _C.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 132,
            height: 35,
            child: _tracking
                ? FilledButton.icon(
                    key: const Key('pause-button'),
                    onPressed: _busy ? null : _stopTracking,
                    style: _dangerButtonStyle().copyWith(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                    icon: const Icon(Icons.pause_rounded, size: 13),
                    label: const Text(
                      'Pause capture',
                      maxLines: 1,
                      softWrap: false,
                    ),
                  )
                : FilledButton.icon(
                    key: const Key('resume-button'),
                    onPressed: !_attached || _busy ? null : _startTracking,
                    style: _filledButtonStyle().copyWith(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 13),
                    label: const Text(
                      'Resume capture',
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 35,
            child: OutlinedButton(
              onPressed: !_attached || _busy ? null : _resetCounts,
              style: _outlineButtonStyle(),
              child: const Text('Reset counts'),
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 24, color: _C.border),
          const SizedBox(width: 12),
          _Segmented(
            leftLabel: 'Tree order',
            rightLabel: 'Hottest first',
            rightSelected: _sort == NodeSort.activity,
            onLeft: () => setState(() => _sort = NodeSort.tree),
            onRight: () => setState(() => _sort = NodeSort.activity),
          ),
          const SizedBox(width: 10),
          FilterChip(
            selected: _hideFramework,
            showCheckmark: true,
            label: const Text('Hide framework layers'),
            labelStyle: const TextStyle(fontSize: 11),
            onSelected: !_attached
                ? null
                : (value) {
                    setState(() => _hideFramework = value);
                    unawaited(_pollSnapshot());
                  },
          ),
          const Spacer(),
          SizedBox(
            width: 165,
            height: 34,
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(
                hintText: 'Filter composables',
                prefixIcon: Icon(Icons.search, size: 16),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: _C.control,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _C.border),
            ),
            child: Row(
              children: [
                const _Eyebrow('SESSION'),
                const SizedBox(width: 9),
                Text(_elapsed, style: _C.monoBody),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHierarchy() {
    final visibleRows = _visibleRows;
    final maxDepth = visibleRows.fold<int>(
      0,
      (deepest, row) => math.max(deepest, _treeDepth(row.node)),
    );
    final extraIndent = math.max(0, maxDepth - 8) * 13.0;
    return _buildHierarchyTable(visibleRows, extraIndent);
  }

  Widget _buildHierarchyTable(
    List<HierarchyRowData> visibleRows,
    double extraIndent,
  ) {
    final horizontalOffset = _treeHorizontalController.hasClients
        ? _treeHorizontalController.offset
        : 0.0;
    return Column(
      children: [
        _TableHeader(
          collapseEnabled: _collapseEnabled && _attached,
          onExpandAll: _expandAllNodes,
          onCollapseAll: _collapseAllNodes,
        ),
        Expanded(
          child: !_attached
              ? const _EmptyState(
                  icon: Icons.link,
                  title: 'Attach a debuggable Compose app',
                  message:
                      'Select a device and application ID, then attach to inspect its live hierarchy.',
                )
              : visibleRows.isEmpty
              ? const _EmptyState(
                  icon: Icons.account_tree_outlined,
                  title: 'No composables to show',
                  message:
                      'Take a snapshot or adjust the filter to populate the hierarchy.',
                )
              : ListView.builder(
                  key: const Key('hierarchy-list'),
                  controller: _treeVerticalController,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: visibleRows.length,
                  itemExtent: 38,
                  itemBuilder: (context, index) {
                    final row = visibleRows[index];
                    final node = row.node;
                    return _HierarchyRow(
                      key: ValueKey('hierarchy-${node.identity}'),
                      node: node,
                      depth: _treeDepth(node),
                      horizontalOffset: horizontalOffset,
                      extraContentWidth: extraIndent,
                      onHorizontalScroll: _scrollTreeHorizontally,
                      hasChildren: row.hasChildren,
                      expanded: !_collapsedNodeIdentities.contains(
                        node.identity,
                      ),
                      collapseEnabled: _collapseEnabled,
                      onToggleExpansion: () => _toggleNodeExpansion(node),
                      selected: node.identity == _selectedNodeIdentity,
                      onTap: () => setState(() {
                        _selectionInitialized = true;
                        _selectedNodeIdentity = node.identity;
                      }),
                    );
                  },
                ),
        ),
        if (extraIndent > 0)
          SizedBox(
            height: 12,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Scrollbar(
                        controller: _treeHorizontalController,
                        scrollbarOrientation: ScrollbarOrientation.bottom,
                        thumbVisibility: true,
                        thickness: 5,
                        radius: const Radius.circular(3),
                        child: SingleChildScrollView(
                          controller: _treeHorizontalController,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: constraints.maxWidth + extraIndent,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 312),
              ],
            ),
          ),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: _C.toolbar,
            border: Border(top: BorderSide(color: _C.border)),
          ),
          child: Row(
            children: [
              Text(
                '${_nodes.length} composables tracked',
                style: _C.subtleText,
              ),
              if (visibleRows.length != _nodes.length) ...[
                const _FooterDot(),
                Text('${visibleRows.length} shown', style: _C.subtleText),
              ],
              const _FooterDot(),
              Text(
                '${_nodes.where((node) => node.recompositions > 0).length} recomposed',
                style: _C.subtleText,
              ),
              const _FooterDot(),
              Text(
                _recovering
                    ? 'Recovering'
                    : _tracking
                    ? 'Recording'
                    : _attached
                    ? 'Capture stopped'
                    : 'Detached',
                style: TextStyle(
                  fontSize: 11,
                  color: _recovering
                      ? _C.warning
                      : _tracking
                      ? _C.positive
                      : _C.subtle,
                ),
              ),
              const Spacer(),
              if (_lastCapture != null)
                Text(
                  'updated ${_formatTime(_lastCapture!)}',
                  style: _C.monoSubtle,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Size? _previewCoordinateSize() {
    // Compose layout bounds are expressed in display pixels. Prefer the actual
    // display size over a root composable's size because app roots can exclude
    // system bars or shrink when insets change.
    final preview = _previewSession;
    final deviceWidth = preview?.deviceWidth;
    final deviceHeight = preview?.deviceHeight;
    if (deviceWidth != null && deviceHeight != null) {
      final frameWidth = preview?.frameWidth;
      final frameHeight = preview?.frameHeight;
      final frameIsLandscape =
          frameWidth != null && frameHeight != null && frameWidth > frameHeight;
      final deviceIsLandscape = deviceWidth > deviceHeight;
      if (frameIsLandscape != deviceIsLandscape) {
        return Size(deviceHeight.toDouble(), deviceWidth.toDouble());
      }
      return Size(deviceWidth.toDouble(), deviceHeight.toDouble());
    }

    ComposableNode? largestRoot;
    var largestArea = 0;
    for (final node in _nodes) {
      if (node.depth != 0 || node.width <= 0 || node.height <= 0) continue;
      final area = node.width * node.height;
      if (area > largestArea) {
        largestArea = area;
        largestRoot = node;
      }
    }
    if (largestRoot != null) {
      return Size(largestRoot.width.toDouble(), largestRoot.height.toDouble());
    }
    return null;
  }

  Widget _buildDevicePreview(ComposableNode? selected) {
    final preview = _previewSession!;
    final frameWidth = preview.frameWidth;
    final frameHeight = preview.frameHeight;
    final hasVideo =
        frameWidth != null &&
        frameHeight != null &&
        preview.status == ScrcpyStatus.streaming;
    final coordinateSize = _previewCoordinateSize();
    final (statusLabel, statusColor) = switch (preview.status) {
      ScrcpyStatus.idle => ('IDLE', _C.subtle),
      ScrcpyStatus.starting => ('STARTING', _C.warning),
      ScrcpyStatus.streaming => ('LIVE', _C.positive),
      ScrcpyStatus.stopping => ('STOPPING', _C.warning),
      ScrcpyStatus.error => ('ERROR', _C.negative),
    };

    return ColoredBox(
      color: _C.toolbar,
      child: Column(
        children: [
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _C.border)),
            ),
            child: Row(
              children: [
                const Icon(Icons.phone_android_rounded, size: 17),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'DEVICE PREVIEW',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                ),
                _Dot(color: statusColor),
                const SizedBox(width: 6),
                Text(statusLabel, style: _C.monoSmall),
                if (preview.status == ScrcpyStatus.error && _attached)
                  IconButton(
                    tooltip: 'Retry device preview',
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    onPressed: () {
                      final serial = _status?.device ?? _selectedSerial;
                      if (serial != null) unawaited(preview.start(serial));
                    },
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.all(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: _C.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewportSize = constraints.biggest;
                      final directController = preview.directVideoController;
                      final videoFrameSize = hasVideo
                          ? Size(frameWidth.toDouble(), frameHeight.toDouble())
                          : null;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (preview.isDirect && directController != null)
                            ScrcpyVideo(
                              controller: directController,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.low,
                            )
                          else
                            Video(
                              controller: preview.videoController,
                              fit: BoxFit.contain,
                              fill: Colors.black,
                              controls: NoVideoControls,
                              pauseUponEnteringBackgroundMode: false,
                            ),
                          if (videoFrameSize != null && coordinateSize != null)
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) => _selectNodeFromPreview(
                                  position: details.localPosition,
                                  viewportSize: viewportSize,
                                  frameSize: videoFrameSize,
                                  coordinateSize: coordinateSize,
                                ),
                              ),
                            ),
                          if (videoFrameSize != null &&
                              selected != null &&
                              coordinateSize != null)
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _ComposableHighlightPainter(
                                  node: selected,
                                  frameSize: videoFrameSize,
                                  coordinateSize: coordinateSize,
                                ),
                              ),
                            ),
                          if (!hasVideo)
                            _PreviewPlaceholder(
                              status: preview.status,
                              message: preview.message,
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _C.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selected == null
                        ? 'Click the preview to select and highlight a composable'
                        : '${selected.name} · Click the preview to select and highlight',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _C.subtleText,
                  ),
                ),
                if (hasVideo)
                  Text(
                    '${preview.isDirect ? 'DIRECT' : 'COMPAT'}  '
                    '$frameWidth×$frameHeight',
                    style: _C.monoSubtle,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetails(ComposableNode? node) {
    if (node == null) {
      return const ColoredBox(
        color: _C.toolbar,
        child: _EmptyState(
          icon: Icons.ads_click,
          title: 'Select a composable',
          message: 'Runtime details and activity will appear here.',
        ),
      );
    }
    final diagnosis = _diagnosis(node);
    return ColoredBox(
      color: _C.toolbar,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Eyebrow('SELECTED'),
                const SizedBox(height: 6),
                Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  node.source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _C.monoSubtle,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        label: 'RECOMPOSITIONS',
                        value: '${node.recompositions}',
                        suffix: ' total',
                        valueColor: node.recompositions > 0
                            ? _C.accent
                            : _C.high,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MetricCard(
                        label: 'SKIPS',
                        value: '${node.skips}',
                        suffix: ' total',
                        valueColor: _C.blue,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        label: 'RECENT CHANGE',
                        value: '+${node.recompositionDelta}',
                        suffix: ' recomposes',
                        valueColor: node.recompositionDelta > 0
                            ? _C.negative
                            : _C.high,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MetricCard(
                        label: 'LAYOUT SIZE',
                        value: '${node.width}×${node.height}',
                        suffix: ' px',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _Eyebrow('RECOMPOSITIONS · LAST 60'),
                    const Spacer(),
                    Text(
                      _tracking ? '1s live samples' : 'capture stopped',
                      style: TextStyle(
                        fontFamily: 'IBM Plex Mono',
                        fontSize: 9,
                        color: _tracking ? _C.positive : _C.subtle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _ActivityChart(values: _activityHistory),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Eyebrow('RUNTIME DETAILS'),
                const SizedBox(height: 12),
                _DetailLine(label: 'source', value: node.source),
                _DetailLine(label: 'bounds', value: node.bounds),
                _DetailLine(label: 'anchor', value: '${node.anchorHash}'),
                _DetailLine(
                  label: 'kind',
                  value: node.isSystem ? 'framework' : 'application',
                  tagColor: node.isSystem ? _C.blue : _C.positive,
                ),
                const SizedBox(height: 8),
                Text(node.path, style: _C.monoSubtle.copyWith(height: 1.5)),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Eyebrow('DIAGNOSIS'),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: diagnosis.color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: diagnosis.color.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        diagnosis.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: diagnosis.color,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        diagnosis.body,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: _C.medium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Recomposition counts are signals, not proof of a performance bug. Correlate them with the interaction, composable cost, and frame timing.',
                  style: TextStyle(fontSize: 11, height: 1.5, color: _C.subtle),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ({String title, String body, Color color}) _diagnosis(ComposableNode node) {
    if (node.recompositionDelta >= 8) {
      return (
        title: 'High activity in the latest sample',
        body:
            'This composable recomposed ${node.recompositionDelta} times during the most recent capture interval. Reproduce the target interaction and verify whether that rate persists.',
        color: _C.negative,
      );
    }
    if (node.recompositions == 0 && node.skips > 0) {
      return (
        title: 'Skipping correctly',
        body:
            'Compose skipped this node ${node.skips} times since reset and recorded no recompositions. That usually means its inputs remained eligible for skipping.',
        color: _C.positive,
      );
    }
    if (node.recompositions > 0) {
      return (
        title: 'Recomposition observed',
        body:
            'This node has recomposed ${node.recompositions} times since reset. Inspect it during a specific interaction before deciding whether the count is unexpected.',
        color: _C.warning,
      );
    }
    return (
      title: 'No activity recorded',
      body:
          'No recompositions or skips have been recorded for this node since the last reset.',
      color: _C.subtle,
    );
  }

  String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}

// Small presentation components shared by the workspace panels. Keeping these
// stateless prevents inspector lifecycle state from leaking into row/card UI.

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder({required this.status, this.message});

  final ScrcpyStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final loading = status == ScrcpyStatus.starting;
    final error = status == ScrcpyStatus.error;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.9),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                Icon(
                  error
                      ? Icons.videocam_off_outlined
                      : Icons.phone_android_rounded,
                  size: 42,
                  color: error ? _C.negative : _C.muted,
                ),
              const SizedBox(height: 14),
              Text(
                loading
                    ? 'Starting device preview…'
                    : error
                    ? 'Preview unavailable'
                    : 'Attach to start preview',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _C.medium,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 7),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: _C.monoSubtle,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposableHighlightPainter extends CustomPainter {
  const _ComposableHighlightPainter({
    required this.node,
    required this.frameSize,
    required this.coordinateSize,
  });

  final ComposableNode node;
  final Size frameSize;
  final Size coordinateSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty ||
        frameSize.isEmpty ||
        coordinateSize.isEmpty ||
        node.width <= 0 ||
        node.height <= 0) {
      return;
    }

    final videoRect = containedVideoRect(
      frameSize: frameSize,
      viewportSize: size,
    );
    final highlight = mapDeviceBoundsToVideo(
      deviceBounds: Rect.fromLTWH(
        node.x.toDouble(),
        node.y.toDouble(),
        node.width.toDouble(),
        node.height.toDouble(),
      ),
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: size,
    );
    if (highlight == null) return;

    canvas.save();
    canvas.clipRect(videoRect);
    final dimmed = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(videoRect)
      ..addRRect(RRect.fromRectAndRadius(highlight, const Radius.circular(3)));
    canvas.drawPath(
      dimmed,
      Paint()..color = Colors.black.withValues(alpha: 0.48),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(highlight, const Radius.circular(3)),
      Paint()
        ..color = _C.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    final label = TextPainter(
      text: TextSpan(
        text: node.name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(40, videoRect.width - 16));
    final labelTop = highlight.top - label.height - 10 >= videoRect.top
        ? highlight.top - label.height - 8
        : math.min(highlight.bottom + 4, videoRect.bottom - label.height - 8);
    final labelLeft = highlight.left.clamp(
      videoRect.left + 4,
      math.max(videoRect.left + 4, videoRect.right - label.width - 12),
    );
    final labelRect = Rect.fromLTWH(
      labelLeft.toDouble() - 4,
      labelTop,
      label.width + 8,
      label.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = _C.accent,
    );
    label.paint(canvas, Offset(labelRect.left + 4, labelRect.top + 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ComposableHighlightPainter oldDelegate) =>
      oldDelegate.node.identity != node.identity ||
      oldDelegate.node.x != node.x ||
      oldDelegate.node.y != node.y ||
      oldDelegate.node.width != node.width ||
      oldDelegate.node.height != node.height ||
      oldDelegate.frameSize != frameSize ||
      oldDelegate.coordinateSize != coordinateSize;
}

class _C {
  static const canvas = Color(0xFF06080A);
  static const header = Color(0xFF0C1013);
  static const toolbar = Color(0xFF090C0F);
  static const control = Color(0xFF14181D);
  static const rowSelected = Color(0x14F5A624);
  static const border = Color(0x14FFFFFF);
  static const accent = Color(0xFFF5A624);
  static const negative = Color(0xFFFF5C50);
  static const positive = Color(0xFF34D399);
  static const warning = Color(0xFFF5A624);
  static const blue = Color(0xFF7AA7FF);
  static const high = Color(0xFFF0F0F0);
  static const medium = Color(0xFFBDBDBD);
  static const subtle = Color(0xFF949494);
  static const muted = Color(0xFF6B6B6B);

  static const monoSmall = TextStyle(
    fontFamily: 'IBM Plex Mono',
    fontSize: 10,
    color: subtle,
  );
  static const monoBody = TextStyle(
    fontFamily: 'IBM Plex Mono',
    fontSize: 11,
    color: high,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const monoSubtle = TextStyle(
    fontFamily: 'IBM Plex Mono',
    fontSize: 10,
    color: subtle,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const subtleText = TextStyle(fontSize: 11, color: subtle);
}

ButtonStyle _filledButtonStyle() => FilledButton.styleFrom(
  backgroundColor: _C.accent,
  foregroundColor: Colors.white,
  disabledBackgroundColor: _C.control,
  padding: const EdgeInsets.symmetric(horizontal: 14),
  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
);

ButtonStyle _dangerButtonStyle() => FilledButton.styleFrom(
  backgroundColor: const Color(0x29FF5C50),
  foregroundColor: const Color(0xFFFFA096),
  side: const BorderSide(color: Color(0x80FF5C50)),
  padding: const EdgeInsets.symmetric(horizontal: 12),
  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
);

ButtonStyle _outlineButtonStyle() => OutlinedButton.styleFrom(
  foregroundColor: _C.high,
  side: const BorderSide(color: _C.border),
  backgroundColor: _C.control,
  padding: const EdgeInsets.symmetric(horizontal: 14),
  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
);

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      fontFamily: 'IBM Plex Mono',
      fontSize: 9,
      letterSpacing: 1.05,
      color: _C.subtle,
    ),
  );
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.leftLabel,
    required this.rightLabel,
    required this.rightSelected,
    required this.onLeft,
    required this.onRight,
  });
  final String leftLabel;
  final String rightLabel;
  final bool rightSelected;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: _C.control,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        _Segment(label: leftLabel, selected: !rightSelected, onTap: onLeft),
        _Segment(label: rightLabel, selected: rightSelected, onTap: onRight),
      ],
    ),
  );
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0x24FFFFFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: selected ? _C.high : _C.subtle,
        ),
      ),
    ),
  );
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({
    required this.collapseEnabled,
    required this.onExpandAll,
    required this.onCollapseAll,
  });

  final bool collapseEnabled;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;

  @override
  Widget build(BuildContext context) => Container(
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: const BoxDecoration(
      color: _C.toolbar,
      border: Border(bottom: BorderSide(color: _C.border)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Row(
            children: [
              const _Eyebrow('COMPOSABLE'),
              const Spacer(),
              _HierarchyHeaderButton(
                key: const Key('collapse-all-nodes'),
                tooltip: 'Collapse all',
                icon: Icons.unfold_less_rounded,
                onPressed: collapseEnabled ? onCollapseAll : null,
              ),
              _HierarchyHeaderButton(
                key: const Key('expand-all-nodes'),
                tooltip: 'Expand all',
                icon: Icons.unfold_more_rounded,
                onPressed: collapseEnabled ? onExpandAll : null,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        const SizedBox(
          width: 104,
          child: Align(
            alignment: Alignment.centerRight,
            child: _Eyebrow('RECOMPOSITIONS'),
          ),
        ),
        const SizedBox(
          width: 88,
          child: Align(
            alignment: Alignment.centerRight,
            child: _Eyebrow('SKIPS'),
          ),
        ),
        const SizedBox(
          width: 104,
          child: Align(
            alignment: Alignment.centerRight,
            child: _Eyebrow('RECENT Δ'),
          ),
        ),
      ],
    ),
  );
}

class _HierarchyHeaderButton extends StatelessWidget {
  const _HierarchyHeaderButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 16),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 27, height: 27),
    visualDensity: VisualDensity.compact,
  );
}

class _HierarchyRow extends StatelessWidget {
  const _HierarchyRow({
    super.key,
    required this.node,
    required this.depth,
    required this.horizontalOffset,
    required this.extraContentWidth,
    required this.onHorizontalScroll,
    required this.hasChildren,
    required this.expanded,
    required this.collapseEnabled,
    required this.onToggleExpansion,
    required this.selected,
    required this.onTap,
  });
  final ComposableNode node;
  final int depth;
  final double horizontalOffset;
  final double extraContentWidth;
  final ValueChanged<double> onHorizontalScroll;
  final bool hasChildren;
  final bool expanded;
  final bool collapseEnabled;
  final VoidCallback onToggleExpansion;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hot = node.recompositionDelta >= 8;
    final active = node.recompositionDelta > 0;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? _C.rowSelected : _C.canvas,
          border: Border(
            left: BorderSide(
              width: 2,
              color: selected ? _C.accent : Colors.transparent,
            ),
          ),
        ),
        padding: const EdgeInsets.only(left: 14, right: 16),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent &&
                        event.scrollDelta.dx != 0) {
                      onHorizontalScroll(event.scrollDelta.dx);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: extraContentWidth > 0
                        ? (details) => onHorizontalScroll(-details.delta.dx)
                        : null,
                    child: ClipRect(
                      child: Stack(
                        children: [
                          Positioned(
                            left: -horizontalOffset,
                            top: 0,
                            bottom: 0,
                            width: constraints.maxWidth + extraContentWidth,
                            child: Padding(
                              padding: EdgeInsets.only(left: depth * 13.0),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 30,
                                    child: hasChildren && collapseEnabled
                                        ? IconButton(
                                            key: ValueKey(
                                              'toggle-${node.identity}',
                                            ),
                                            tooltip: expanded
                                                ? 'Collapse ${node.name}'
                                                : 'Expand ${node.name}',
                                            onPressed: onToggleExpansion,
                                            icon: Icon(
                                              expanded
                                                  ? Icons
                                                        .keyboard_arrow_down_rounded
                                                  : Icons
                                                        .keyboard_arrow_right_rounded,
                                              size: 16,
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 18,
                                                  height: 30,
                                                ),
                                            splashRadius: 13,
                                            color: _C.subtle,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    node.isSystem
                                        ? Icons.settings_outlined
                                        : Icons.widgets_outlined,
                                    size: 14,
                                    color: node.isSystem ? _C.blue : _C.accent,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      node.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: active ? _C.high : _C.medium,
                                      ),
                                    ),
                                  ),
                                  if (node.isSystem)
                                    const _TinyTag('SYS', color: _C.blue),
                                  if (hot)
                                    const _TinyTag('HOT', color: _C.negative),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 104,
              child: Text(
                '${node.recompositions}',
                textAlign: TextAlign.right,
                style: _countStyle(active ? _C.accent : _C.subtle),
              ),
            ),
            SizedBox(
              width: 88,
              child: Text(
                '${node.skips}',
                textAlign: TextAlign.right,
                style: _countStyle(node.skips > 0 ? _C.blue : _C.subtle),
              ),
            ),
            SizedBox(
              width: 104,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (node.recompositionDelta > 0)
                    Container(
                      width: math.min(34, 4 + node.recompositionDelta * 3),
                      height: 5,
                      decoration: BoxDecoration(
                        color: hot ? _C.negative : _C.accent,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 30,
                    child: Text(
                      '+${node.recompositionDelta}',
                      textAlign: TextAlign.right,
                      style: _countStyle(
                        node.recompositionDelta > 0
                            ? hot
                                  ? _C.negative
                                  : _C.accent
                            : _C.subtle,
                        size: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _countStyle(Color color, {double size = 11}) => TextStyle(
    fontFamily: 'IBM Plex Mono',
    fontSize: size,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

class _TinyTag extends StatelessWidget {
  const _TinyTag(this.label, {required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontFamily: 'IBM Plex Mono',
        fontSize: 8,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.suffix,
    this.valueColor = _C.high,
  });
  final String label;
  final String value;
  final String suffix;
  final Color valueColor;

  @override
  Widget build(BuildContext context) => Container(
    height: 76,
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: _C.control,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Eyebrow(label),
        const Spacer(),
        RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: valueColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              TextSpan(
                text: suffix,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: _C.subtle,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ActivityChart extends StatelessWidget {
  const _ActivityChart({required this.values});
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final padded = [
      ...List<int>.filled(math.max(0, 60 - values.length), 0),
      ...values,
    ];
    final maximum = math.max(1, padded.fold<int>(0, math.max));
    return SizedBox(
      height: 84,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: padded.map((value) {
          final height = value == 0 ? 2.0 : 4 + (value / maximum) * 76;
          final color = value >= 8
              ? _C.negative
              : value > 0
              ? _C.accent
              : _C.border;
          return Expanded(
            child: Container(
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(2),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value, this.tagColor});
  final String label;
  final String value;
  final Color? tagColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0x14FFFFFF))),
    ),
    child: Row(
      children: [
        Expanded(child: Text(label, style: _C.monoBody)),
        Flexible(
          child: Container(
            padding: tagColor == null
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: tagColor == null
                ? null
                : BoxDecoration(
                    color: tagColor!.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(99),
                  ),
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: _C.monoSubtle.copyWith(color: tagColor),
            ),
          ),
        ),
      ],
    ),
  );
}

class _FooterDot extends StatelessWidget {
  const _FooterDot();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 10),
    child: Text('·', style: TextStyle(color: _C.muted)),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: _C.muted),
          const SizedBox(height: 13),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, height: 1.5, color: _C.subtle),
          ),
        ],
      ),
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});
  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: const Color(0x1FFF5C50),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
    child: Row(
      children: [
        const Icon(Icons.error_outline, size: 16, color: Color(0xFFFFA096)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFFFFB9B2)),
          ),
        ),
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 15),
          visualDensity: VisualDensity.compact,
        ),
      ],
    ),
  );
}

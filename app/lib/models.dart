class DeviceInfo {
  const DeviceInfo({
    required this.serial,
    required this.model,
    this.product,
    this.foregroundPackage,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    serial: json['serial'] as String,
    model: (json['model'] as String?) ?? json['serial'] as String,
    product: json['product'] as String?,
    foregroundPackage: json['foreground_package'] as String?,
  );

  final String serial;
  final String model;
  final String? product;
  final String? foregroundPackage;
}

class InspectorStatus {
  const InspectorStatus({
    required this.attached,
    required this.tracking,
    this.device,
    this.package,
    this.pid,
    this.abi,
    this.composeVersion,
    this.rootViewIds = const [],
  });

  factory InspectorStatus.fromJson(Map<String, dynamic> json) =>
      InspectorStatus(
        attached: json['attached'] as bool? ?? false,
        tracking: json['tracking'] as bool? ?? false,
        device: json['device'] as String?,
        package: json['package'] as String?,
        pid: json['pid'] as int?,
        abi: json['abi'] as String?,
        composeVersion: json['compose_version'] as String?,
        rootViewIds: (json['root_view_ids'] as List<dynamic>? ?? const [])
            .cast<num>()
            .map((value) => value.toInt())
            .toList(),
      );

  final bool attached;
  final bool tracking;
  final String? device;
  final String? package;
  final int? pid;
  final String? abi;
  final String? composeVersion;
  final List<int> rootViewIds;

  InspectorStatus copyWith({bool? tracking}) => InspectorStatus(
    attached: attached,
    tracking: tracking ?? this.tracking,
    device: device,
    package: package,
    pid: pid,
    abi: abi,
    composeVersion: composeVersion,
    rootViewIds: rootViewIds,
  );
}

class ComposableNode {
  const ComposableNode({
    required this.anchorHash,
    required this.id,
    required this.rootViewId,
    required this.parentAnchorHash,
    required this.treeIndex,
    required this.depth,
    required this.name,
    required this.path,
    required this.recompositions,
    required this.skips,
    required this.recompositionDelta,
    required this.skipDelta,
    this.file,
    this.line,
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.isSystem = false,
  });

  factory ComposableNode.fromJson(Map<String, dynamic> json) {
    final bounds = json['bounds'] as Map<String, dynamic>? ?? const {};
    return ComposableNode(
      anchorHash: (json['anchor_hash'] as num?)?.toInt() ?? 0,
      id: (json['id'] as num?)?.toInt() ?? 0,
      rootViewId: (json['root_view_id'] as num?)?.toInt() ?? 0,
      parentAnchorHash: (json['parent_anchor_hash'] as num?)?.toInt(),
      treeIndex: (json['tree_index'] as num?)?.toInt() ?? 0,
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '<unknown>',
      path: json['path'] as String? ?? '',
      file: json['file'] as String?,
      line: (json['line'] as num?)?.toInt(),
      recompositions: (json['recompositions'] as num?)?.toInt() ?? 0,
      skips: (json['skips'] as num?)?.toInt() ?? 0,
      recompositionDelta: (json['recomposition_delta'] as num?)?.toInt() ?? 0,
      skipDelta: (json['skip_delta'] as num?)?.toInt() ?? 0,
      x: (bounds['x'] as num?)?.toInt() ?? 0,
      y: (bounds['y'] as num?)?.toInt() ?? 0,
      width: (bounds['width'] as num?)?.toInt() ?? 0,
      height: (bounds['height'] as num?)?.toInt() ?? 0,
      isSystem: json['is_system'] as bool? ?? false,
    );
  }

  final int anchorHash;
  final int id;
  final int rootViewId;
  final int? parentAnchorHash;
  final int treeIndex;
  final int depth;
  final String name;
  final String path;
  final String? file;
  final int? line;
  final int recompositions;
  final int skips;
  final int recompositionDelta;
  final int skipDelta;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool isSystem;

  // An anchor identifies a composable call site, so repeated instances such
  // as LazyColumn rows can share it. The node id identifies the concrete
  // inspector instance and remains stable while that instance moves.
  String get identity => '$rootViewId:node:$id';
  String get source => file == null
      ? 'Source unavailable'
      : '$file${line == null ? '' : ':$line'}';
  String get bounds => '$width×$height at $x,$y';
}

enum NodeSort { tree, activity, recompositions, skips, name }

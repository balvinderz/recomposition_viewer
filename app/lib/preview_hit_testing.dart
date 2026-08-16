import 'package:flutter/widgets.dart';

import 'models.dart';
import 'preview_geometry.dart';

ComposableNode? findClosestComposableAtPreviewPoint({
  required Iterable<ComposableNode> nodes,
  required Offset position,
  required Size coordinateSize,
  required Size frameSize,
  required Size viewportSize,
}) {
  final videoRect = containedVideoRect(
    frameSize: frameSize,
    viewportSize: viewportSize,
  );
  if (!videoRect.contains(position)) return null;

  final candidates = <_HitCandidate>[];
  for (final node in nodes) {
    if (node.width <= 0 || node.height <= 0) continue;
    final bounds = mapDeviceBoundsToVideo(
      deviceBounds: Rect.fromLTWH(
        node.x.toDouble(),
        node.y.toDouble(),
        node.width.toDouble(),
        node.height.toDouble(),
      ),
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: viewportSize,
    );
    if (bounds == null) continue;
    candidates.add(
      _HitCandidate(
        node: node,
        bounds: bounds,
        distanceSquared: _distanceSquaredToRect(position, bounds),
      ),
    );
  }
  if (candidates.isEmpty) return null;

  final containing = candidates
      .where((candidate) => candidate.bounds.contains(position))
      .toList();
  final pool = containing.isEmpty ? candidates : containing;
  pool.sort((a, b) {
    if (containing.isEmpty) {
      final distance = a.distanceSquared.compareTo(b.distanceSquared);
      if (distance != 0) return distance;
    }
    final area = a.bounds.size.longestSide == 0
        ? 0.0
        : a.bounds.width * a.bounds.height;
    final otherArea = b.bounds.size.longestSide == 0
        ? 0.0
        : b.bounds.width * b.bounds.height;
    final areaOrder = area.compareTo(otherArea);
    if (areaOrder != 0) return areaOrder;
    final depthOrder = b.node.depth.compareTo(a.node.depth);
    if (depthOrder != 0) return depthOrder;
    return b.node.treeIndex.compareTo(a.node.treeIndex);
  });
  return pool.first.node;
}

double _distanceSquaredToRect(Offset point, Rect rect) {
  final dx = point.dx < rect.left
      ? rect.left - point.dx
      : point.dx > rect.right
      ? point.dx - rect.right
      : 0.0;
  final dy = point.dy < rect.top
      ? rect.top - point.dy
      : point.dy > rect.bottom
      ? point.dy - rect.bottom
      : 0.0;
  return dx * dx + dy * dy;
}

class _HitCandidate {
  const _HitCandidate({
    required this.node,
    required this.bounds,
    required this.distanceSquared,
  });

  final ComposableNode node;
  final Rect bounds;
  final double distanceSquared;
}

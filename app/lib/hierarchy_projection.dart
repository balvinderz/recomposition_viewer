import 'models.dart';

class HierarchyRowData {
  const HierarchyRowData({required this.node, required this.hasChildren});

  final ComposableNode node;
  final bool hasChildren;
}

/// Orders nodes by the recomposition activity shown in the `Recent Δ` column.
/// Skips are excluded because they represent work the runtime avoided, not
/// recomposition heat.
int compareNodesByRecompositionHeat(ComposableNode a, ComposableNode b) {
  final recent = b.recompositionDelta.compareTo(a.recompositionDelta);
  if (recent != 0) return recent;

  final cumulative = b.recompositions.compareTo(a.recompositions);
  if (cumulative != 0) return cumulative;

  final root = a.rootViewId.compareTo(b.rootViewId);
  if (root != 0) return root;
  return a.treeIndex.compareTo(b.treeIndex);
}

/// Projects the inspector's pre-order flat node list into the rows that should
/// be rendered. Depth ranges are used instead of anchor hashes because lazy and
/// repeated composables may share an anchor hash.
List<HierarchyRowData> projectHierarchyRows({
  required Iterable<ComposableNode> nodes,
  required Set<String> collapsedNodeIdentities,
  bool applyCollapse = true,
}) {
  final ordered = nodes.toList()
    ..sort((a, b) => a.treeIndex.compareTo(b.treeIndex));
  final rows = <HierarchyRowData>[];
  int? hiddenRootViewId;
  int? hiddenBelowDepth;

  for (var index = 0; index < ordered.length; index++) {
    final node = ordered[index];
    final next = index + 1 < ordered.length ? ordered[index + 1] : null;
    final hasChildren =
        next != null &&
        next.rootViewId == node.rootViewId &&
        next.depth > node.depth;

    if (hiddenBelowDepth != null) {
      if (node.rootViewId == hiddenRootViewId &&
          node.depth > hiddenBelowDepth) {
        continue;
      }
      hiddenRootViewId = null;
      hiddenBelowDepth = null;
    }

    rows.add(HierarchyRowData(node: node, hasChildren: hasChildren));
    if (applyCollapse &&
        hasChildren &&
        collapsedNodeIdentities.contains(node.identity)) {
      hiddenRootViewId = node.rootViewId;
      hiddenBelowDepth = node.depth;
    }
  }
  return rows;
}

/// Returns ancestors from the root down to the selected node's direct parent.
List<String> hierarchyAncestorIdentities(
  Iterable<ComposableNode> nodes,
  String nodeIdentity,
) {
  final ordered = nodes.toList()
    ..sort((a, b) => a.treeIndex.compareTo(b.treeIndex));
  final ancestors = <ComposableNode>[];
  int? currentRootViewId;

  for (final node in ordered) {
    if (currentRootViewId != node.rootViewId) {
      currentRootViewId = node.rootViewId;
      ancestors.clear();
    }
    while (ancestors.isNotEmpty && ancestors.last.depth >= node.depth) {
      ancestors.removeLast();
    }
    if (node.identity == nodeIdentity) {
      return ancestors.map((ancestor) => ancestor.identity).toList();
    }
    ancestors.add(node);
  }
  return const [];
}

import 'package:flutter_test/flutter_test.dart';
import 'package:recomposition_inspector/hierarchy_projection.dart';
import 'package:recomposition_inspector/models.dart';

void main() {
  test('a collapsed row hides its complete depth range', () {
    final nodes = [
      _node(id: 1, root: 1, index: 0, depth: 0),
      _node(id: 2, root: 1, index: 1, depth: 1),
      _node(id: 3, root: 1, index: 2, depth: 2),
      _node(id: 4, root: 1, index: 3, depth: 1),
    ];

    final rows = projectHierarchyRows(
      nodes: nodes,
      collapsedNodeIdentities: {nodes[1].identity},
    );

    expect(rows.map((row) => row.node.id), [1, 2, 4]);
    expect(rows.map((row) => row.hasChildren), [true, true, false]);
  });

  test('collapse never crosses into another Compose root', () {
    final firstRoot = _node(id: 1, root: 1, index: 0, depth: 0);
    final nodes = [
      firstRoot,
      _node(id: 2, root: 1, index: 1, depth: 1),
      _node(id: 1, root: 2, index: 2, depth: 0),
      _node(id: 2, root: 2, index: 3, depth: 1),
    ];

    final rows = projectHierarchyRows(
      nodes: nodes,
      collapsedNodeIdentities: {firstRoot.identity},
    );

    expect(rows.map((row) => row.node.identity), [
      '1:node:1',
      '2:node:1',
      '2:node:2',
    ]);
  });

  test('ancestor lookup uses order and depth rather than shared anchors', () {
    final nodes = [
      _node(id: 1, root: 1, index: 0, depth: 0, anchor: 7),
      _node(id: 2, root: 1, index: 1, depth: 1, anchor: 9),
      _node(id: 3, root: 1, index: 2, depth: 2, anchor: 9),
    ];

    expect(hierarchyAncestorIdentities(nodes, nodes.last.identity), [
      nodes[0].identity,
      nodes[1].identity,
    ]);
  });

  test('collapse can be bypassed while search results are shown', () {
    final root = _node(id: 1, root: 1, index: 0, depth: 0);
    final child = _node(id: 2, root: 1, index: 1, depth: 1);

    final rows = projectHierarchyRows(
      nodes: [root, child],
      collapsedNodeIdentities: {root.identity},
      applyCollapse: false,
    );

    expect(rows.map((row) => row.node.id), [1, 2]);
  });

  test(
    'recomposition heat ignores skips and uses cumulative count for ties',
    () {
      final nodes = [
        _node(
          id: 1,
          root: 1,
          index: 0,
          depth: 0,
          recompositions: 100,
          recompositionDelta: 0,
          skipDelta: 500,
        ),
        _node(
          id: 2,
          root: 1,
          index: 1,
          depth: 0,
          recompositions: 20,
          recompositionDelta: 4,
        ),
        _node(
          id: 3,
          root: 1,
          index: 2,
          depth: 0,
          recompositions: 30,
          recompositionDelta: 4,
        ),
      ]..sort(compareNodesByRecompositionHeat);

      expect(nodes.map((node) => node.id), [3, 2, 1]);
    },
  );
}

ComposableNode _node({
  required int id,
  required int root,
  required int index,
  required int depth,
  int anchor = 1,
  int recompositions = 0,
  int recompositionDelta = 0,
  int skipDelta = 0,
}) => ComposableNode(
  anchorHash: anchor,
  id: id,
  rootViewId: root,
  parentAnchorHash: null,
  treeIndex: index,
  depth: depth,
  name: 'Node$id',
  path: 'Node$id',
  recompositions: recompositions,
  skips: 0,
  recompositionDelta: recompositionDelta,
  skipDelta: skipDelta,
);

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recomposition_inspector/models.dart';
import 'package:recomposition_inspector/preview_hit_testing.dart';

void main() {
  const coordinateSize = Size(1000, 2000);
  const frameSize = Size(500, 1000);
  const viewportSize = Size(500, 1000);

  test('selects the smallest containing composable', () {
    final root = _node(id: 1, depth: 0, x: 0, y: 0, width: 1000, height: 2000);
    final card = _node(
      id: 2,
      depth: 4,
      x: 100,
      y: 200,
      width: 800,
      height: 400,
    );
    final text = _node(
      id: 3,
      depth: 8,
      x: 200,
      y: 300,
      width: 300,
      height: 100,
    );

    final selected = findClosestComposableAtPreviewPoint(
      nodes: [root, card, text],
      position: const Offset(150, 175),
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: viewportSize,
    );

    expect(selected?.id, 3);
  });

  test('distinguishes repeated instances sharing an anchor', () {
    final first = _node(
      id: 11,
      anchorHash: 42,
      depth: 5,
      x: 0,
      y: 200,
      width: 1000,
      height: 200,
    );
    final second = _node(
      id: 12,
      anchorHash: 42,
      depth: 5,
      x: 0,
      y: 600,
      width: 1000,
      height: 200,
    );

    final selected = findClosestComposableAtPreviewPoint(
      nodes: [first, second],
      position: const Offset(250, 350),
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: viewportSize,
    );

    expect(selected?.id, 12);
  });

  test('selects the nearest visible node when none contains the point', () {
    final top = _node(id: 1, depth: 2, x: 100, y: 100, width: 200, height: 100);
    final bottom = _node(
      id: 2,
      depth: 2,
      x: 100,
      y: 1000,
      width: 200,
      height: 100,
    );

    final selected = findClosestComposableAtPreviewPoint(
      nodes: [top, bottom],
      position: const Offset(100, 350),
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: viewportSize,
    );

    expect(selected?.id, 2);
  });

  test('ignores clicks in the letterbox outside the video', () {
    final selected = findClosestComposableAtPreviewPoint(
      nodes: [_node(id: 1, depth: 0, x: 0, y: 0, width: 1000, height: 2000)],
      position: const Offset(10, 500),
      coordinateSize: coordinateSize,
      frameSize: frameSize,
      viewportSize: const Size(700, 1000),
    );

    expect(selected, isNull);
  });
}

ComposableNode _node({
  required int id,
  int anchorHash = 1,
  required int depth,
  required int x,
  required int y,
  required int width,
  required int height,
}) => ComposableNode(
  anchorHash: anchorHash,
  id: id,
  rootViewId: 1,
  parentAnchorHash: null,
  treeIndex: id,
  depth: depth,
  name: 'Node$id',
  path: 'Root/Node$id',
  recompositions: 0,
  skips: 0,
  recompositionDelta: 0,
  skipDelta: 0,
  x: x,
  y: y,
  width: width,
  height: height,
);

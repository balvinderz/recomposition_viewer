import 'package:flutter_test/flutter_test.dart';
import 'package:recomposition_inspector/models.dart';

void main() {
  test('repeated composables use their concrete node id for selection', () {
    final first = _node(id: 11, anchorHash: 42, y: 100);
    final second = _node(id: 12, anchorHash: 42, y: 300);

    expect(first.identity, isNot(second.identity));
  });

  test('a composable keeps its selection identity when its bounds move', () {
    final beforeScroll = _node(id: 11, anchorHash: 42, y: 700);
    final afterScroll = _node(id: 11, anchorHash: 42, y: 250);

    expect(afterScroll.identity, beforeScroll.identity);
    expect(afterScroll.y, isNot(beforeScroll.y));
  });
}

ComposableNode _node({
  required int id,
  required int anchorHash,
  required int y,
}) => ComposableNode(
  anchorHash: anchorHash,
  id: id,
  rootViewId: 1,
  parentAnchorHash: null,
  treeIndex: 0,
  depth: 0,
  name: 'RepeatedRow',
  path: 'Screen/RepeatedRow',
  recompositions: 0,
  skips: 0,
  recompositionDelta: 0,
  skipDelta: 0,
  x: 0,
  y: y,
  width: 100,
  height: 50,
);

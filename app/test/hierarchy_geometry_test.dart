import 'package:flutter_test/flutter_test.dart';
import 'package:recomposition_inspector/hierarchy_geometry.dart';

void main() {
  test('centers a selected hierarchy row in the viewport', () {
    final offset = centeredItemScrollOffset(
      index: 40,
      itemExtent: 38,
      leadingPadding: 6,
      viewportExtent: 380,
      minScrollExtent: 0,
      maxScrollExtent: 2000,
    );

    expect(offset, 1355);
  });

  test('clamps rows near the beginning and end', () {
    expect(
      centeredItemScrollOffset(
        index: 0,
        itemExtent: 38,
        leadingPadding: 6,
        viewportExtent: 380,
        minScrollExtent: 0,
        maxScrollExtent: 1000,
      ),
      0,
    );
    expect(
      centeredItemScrollOffset(
        index: 99,
        itemExtent: 38,
        leadingPadding: 6,
        viewportExtent: 380,
        minScrollExtent: 0,
        maxScrollExtent: 1000,
      ),
      1000,
    );
  });

  test('reveals a deeply indented selected label', () {
    final offset = selectedLabelHorizontalOffset(
      depth: 30,
      indentExtent: 13,
      labelLeadingExtent: 22,
      viewportExtent: 320,
      minScrollExtent: 0,
      maxScrollExtent: 500,
    );

    // Label starts at 412 and is moved to 25% of the 320 px viewport.
    expect(offset, 332);
  });

  test('keeps shallow labels at the start and clamps the deepest label', () {
    expect(
      selectedLabelHorizontalOffset(
        depth: 2,
        indentExtent: 13,
        labelLeadingExtent: 22,
        viewportExtent: 320,
        minScrollExtent: 0,
        maxScrollExtent: 500,
      ),
      0,
    );
    expect(
      selectedLabelHorizontalOffset(
        depth: 80,
        indentExtent: 13,
        labelLeadingExtent: 22,
        viewportExtent: 320,
        minScrollExtent: 0,
        maxScrollExtent: 700,
      ),
      700,
    );
  });
}

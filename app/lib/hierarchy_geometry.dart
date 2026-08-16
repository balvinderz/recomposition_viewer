double centeredItemScrollOffset({
  required int index,
  required double itemExtent,
  required double leadingPadding,
  required double viewportExtent,
  required double minScrollExtent,
  required double maxScrollExtent,
}) {
  if (index < 0 || itemExtent <= 0 || viewportExtent <= 0) {
    return minScrollExtent;
  }
  final itemCenter = leadingPadding + index * itemExtent + itemExtent / 2;
  return (itemCenter - viewportExtent / 2).clamp(
    minScrollExtent,
    maxScrollExtent,
  );
}

double selectedLabelHorizontalOffset({
  required int depth,
  required double indentExtent,
  required double labelLeadingExtent,
  required double viewportExtent,
  required double minScrollExtent,
  required double maxScrollExtent,
}) {
  if (depth < 0 ||
      indentExtent <= 0 ||
      viewportExtent <= 0 ||
      maxScrollExtent <= minScrollExtent) {
    return minScrollExtent;
  }
  final labelStart = depth * indentExtent + labelLeadingExtent;
  final preferredVisibleStart = (viewportExtent * 0.25).clamp(24.0, 96.0);
  return (labelStart - preferredVisibleStart).clamp(
    minScrollExtent,
    maxScrollExtent,
  );
}

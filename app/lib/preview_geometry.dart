import 'package:flutter/widgets.dart';

Rect? mapDeviceBoundsToVideo({
  required Rect deviceBounds,
  required Size coordinateSize,
  required Size frameSize,
  required Size viewportSize,
}) {
  if (deviceBounds.isEmpty ||
      coordinateSize.isEmpty ||
      frameSize.isEmpty ||
      viewportSize.isEmpty) {
    return null;
  }
  final fitted = applyBoxFit(BoxFit.contain, frameSize, viewportSize);
  final videoRect = Alignment.center.inscribe(
    fitted.destination,
    Offset.zero & viewportSize,
  );
  final mapped = Rect.fromLTWH(
    videoRect.left + deviceBounds.left * videoRect.width / coordinateSize.width,
    videoRect.top + deviceBounds.top * videoRect.height / coordinateSize.height,
    deviceBounds.width * videoRect.width / coordinateSize.width,
    deviceBounds.height * videoRect.height / coordinateSize.height,
  );
  final visible = mapped.intersect(videoRect);
  return visible.isEmpty ? null : visible;
}

Rect containedVideoRect({required Size frameSize, required Size viewportSize}) {
  final fitted = applyBoxFit(BoxFit.contain, frameSize, viewportSize);
  return Alignment.center.inscribe(
    fitted.destination,
    Offset.zero & viewportSize,
  );
}

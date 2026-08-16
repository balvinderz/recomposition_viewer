import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recomposition_inspector/preview_geometry.dart';

void main() {
  test('maps device bounds into a portrait letterboxed video', () {
    const frame = Size(991, 1920);
    const coordinates = Size(1080, 2092);
    const viewport = Size(360, 700);
    const deviceBounds = Rect.fromLTWH(108, 209.2, 540, 418.4);

    final video = containedVideoRect(frameSize: frame, viewportSize: viewport);
    final mapped = mapDeviceBoundsToVideo(
      deviceBounds: deviceBounds,
      coordinateSize: coordinates,
      frameSize: frame,
      viewportSize: viewport,
    )!;

    expect(mapped.left, closeTo(video.left + video.width * 0.1, 0.001));
    expect(mapped.top, closeTo(video.top + video.height * 0.1, 0.001));
    expect(mapped.width, closeTo(video.width * 0.5, 0.001));
    expect(mapped.height, closeTo(video.height * 0.2, 0.001));
  });

  test('clips partially off-screen composable bounds to the video', () {
    final mapped = mapDeviceBoundsToVideo(
      deviceBounds: const Rect.fromLTWH(-100, -100, 300, 300),
      coordinateSize: const Size(1000, 2000),
      frameSize: const Size(500, 1000),
      viewportSize: const Size(500, 1000),
    )!;

    expect(mapped, const Rect.fromLTWH(0, 0, 100, 100));
  });
}

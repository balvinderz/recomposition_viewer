import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_video_view/scrcpy_video_view.dart';

void main() {
  test('published scrcpy package parses authorized adb devices', () {
    final devices = ScrcpyDevice.parseAdbOutput('''
List of devices attached
emulator-5554 device product:sdk model:Pixel_9 transport_id:1
offline-device offline
''');

    expect(devices, hasLength(1));
    expect(devices.single.serial, 'emulator-5554');
    expect(devices.single.displayName, 'Pixel 9');
  });

  test('published scrcpy package keeps low-latency defaults', () {
    const configuration = ScrcpyVideoConfiguration();

    expect(configuration.maxSize, 1920);
    expect(configuration.maxFps, 60);
    expect(configuration.videoBitRate, 8000000);
  });
}

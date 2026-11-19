import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

const String _outDir =
    '/Users/jfan/.gemini/antigravity/brain/13820410-8533-40f5-908f-5a94bd0eae1b/scratch/screenshots/phone';

Future<void> main() async {
  Directory(_outDir).createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes, [Map<String, Object?>? args]) async {
      final outPath = '$_outDir/$screenshotName.png';
      await File(outPath).writeAsBytes(screenshotBytes);
      return true;
    },
  );
}

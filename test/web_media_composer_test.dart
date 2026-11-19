import 'dart:typed_data';

import 'package:bluebubbles/helpers/network/metadata/network/preview_image_downloader.dart';
import 'package:bluebubbles/helpers/types/extensions/extensions.dart';
import 'package:bluebubbles/services/network/api/attachment_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AttachmentApi.buildDownloadQueryParams', () {
    test('omits original on web for HEIC/HEIF/TIFF', () {
      for (final mime in ['image/heic', 'image/HEIF', 'image/tiff', 'image/heic-sequence']) {
        final params = AttachmentApi.buildDownloadQueryParams(
          original: true,
          mimeType: mime,
          isWeb: true,
        );
        expect(params.containsKey('original'), isFalse, reason: 'mime=$mime');
      }
    });

    test('keeps original on native or web-supported mimes and passes width/quality', () {
      final nativeHeic = AttachmentApi.buildDownloadQueryParams(
        original: true,
        mimeType: 'image/heic',
        isWeb: false,
      );
      expect(nativeHeic['original'], isTrue);

      final webThumb = AttachmentApi.buildDownloadQueryParams(
        original: false,
        mimeType: 'image/jpeg',
        width: 800,
        quality: 'better',
        isWeb: true,
      );
      expect(webThumb, {'original': false, 'width': 800, 'quality': 'better'});
    });
  });

  test('hasUrl matches URLs', () {
    expect('Check https://bluebubbles.app out'.hasUrl, isTrue);
    expect('just plain text'.hasUrl, isFalse);
  });

  test('CachedPreviewImage supports in-memory bytes for web', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final img = CachedPreviewImage(path: '', hash: 'abc', fromDisk: false, bytes: bytes);
    expect(img.bytes, bytes);
  });
}

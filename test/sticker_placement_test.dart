import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_drop_target.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_reactions.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/library_sticker.dart';
import 'package:bluebubbles/models/models.dart' show StickerPlacement;
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _SilentLogger extends BaseLogger {
  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _TestSettings extends Settings {
  @override
  Future<Settings> saveManyAsync(List<String> keys) async => this;
}

class _FakeStickerLibraryService extends StickerLibraryService {
  _FakeStickerLibraryService(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> imageForSending(LibrarySticker sticker) async => bytes;
}

class _QueuedStickerCall {
  _QueuedStickerCall({
    required this.chat,
    required this.selected,
    required this.part,
    required this.bytes,
    required this.fileName,
    required this.placement,
  });

  final Chat chat;
  final Message selected;
  final int part;
  final Uint8List bytes;
  final String fileName;
  final StickerPlacement placement;
}

class _FakeOutgoingMessageHandler extends OutgoingMessageHandler {
  final List<_QueuedStickerCall> placed = [];

  @override
  Future<void> queuePlacedSticker({
    required Chat chat,
    required Message selected,
    required int part,
    required Uint8List bytes,
    required String fileName,
    required StickerPlacement placement,
  }) async {
    placed.add(_QueuedStickerCall(
      chat: chat,
      selected: selected,
      part: part,
      bytes: bytes,
      fileName: fileName,
      placement: placement,
    ));
  }
}

void _registerTestServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = _TestSettings());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<StickerLibraryService>()) {
    GetIt.I.registerSingleton<StickerLibraryService>(_FakeStickerLibraryService(_kPng1x1));
  }
  if (!GetIt.I.isRegistered<OutgoingMessageHandler>()) {
    GetIt.I.registerSingleton<OutgoingMessageHandler>(_FakeOutgoingMessageHandler());
  }
}

// Valid 1x1 transparent PNG bytes for synchronous in-memory StickerHolder decode tests.
final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Message _makeStickerMessage({
  required String guid,
  required int attachmentId,
  required int partId,
  required Map<String, dynamic>? placement,
  Uint8List? bytes,
}) {
  final attachment = Attachment(
    id: attachmentId,
    guid: 'at_0_$guid',
    mimeType: 'image/png',
    transferName: 'sticker.png',
    stickerPlacement: placement,
    bytes: bytes ?? _kPng1x1,
  );
  final msg = Message(
    guid: guid,
    associatedMessageGuid: 'PARENT-GUID',
    associatedMessageType: 'sticker',
    associatedMessagePart: partId,
    dateCreated: DateTime(2026, 1, 1, 12, 0, partId),
  );
  msg.dbAttachments.add(attachment);
  return msg;
}

void main() {
  group('StickerPlacement.tryParse & toMap', () {
    test('parses numeric (spv>=1) and string (spv=0) Apple placement maps', () {
      final fromStrings = StickerPlacement.tryParse({
        'xScalar': '0.64425055',
        'yScalar': '0.28432214',
        'scale': '1.07218242',
        'rotation': '0.00623223',
        'parentPreviewWidth': '160',
      });
      expect(fromStrings, isNotNull);
      expect(fromStrings!.xScalar, closeTo(0.64425055, 1e-9));
      expect(fromStrings.yScalar, closeTo(0.28432214, 1e-9));
      expect(fromStrings.scale, closeTo(1.07218242, 1e-9));
      expect(fromStrings.rotation, closeTo(0.00623223, 1e-9));
      expect(fromStrings.parentPreviewWidth, closeTo(160.0, 1e-9));

      // Preserves overhanging negative xScalar and negative rotation radians
      final overhanging = StickerPlacement.tryParse({
        'xScalar': -1.69753147,
        'yScalar': 1.4608,
        'scale': 0.48,
        'rotation': -0.16404237,
        'parentPreviewWidth': 54.0,
      });
      expect(overhanging, isNotNull);
      expect(overhanging!.xScalar, closeTo(-1.69753147, 1e-9));
      expect(overhanging.rotation, closeTo(-0.16404237, 1e-9));
      expect(StickerPlacement.tryParse(overhanging.toMap()), equals(overhanging));
    });

    test('rejects invalid scale, negative width, non-finite numbers, and missing keys', () {
      expect(StickerPlacement.tryParse(null), isNull);
      expect(
        StickerPlacement.tryParse({
          'xScalar': 0.5,
          'yScalar': 0.5,
          'scale': 0,
          'rotation': 0,
          'parentPreviewWidth': 200,
        }),
        isNull,
      );
      expect(
        StickerPlacement.tryParse({
          'xScalar': 0.5,
          'yScalar': 0.5,
          'scale': -0.5,
          'rotation': 0,
          'parentPreviewWidth': 200,
        }),
        isNull,
      );
      expect(
        StickerPlacement.tryParse({
          'xScalar': 0.5,
          'yScalar': 0.5,
          'scale': 1.0,
          'rotation': 0,
          'parentPreviewWidth': -1,
        }),
        isNull,
      );
      expect(
        StickerPlacement.tryParse({
          'xScalar': double.nan,
          'yScalar': 0.5,
          'scale': 1.0,
          'rotation': 0,
          'parentPreviewWidth': 200,
        }),
        isNull,
      );
      expect(
        StickerPlacement.tryParse({
          'xScalar': 0.5,
          'yScalar': 0.5,
          'scale': 1.0,
          'rotation': 0,
        }),
        isNull,
      );
    });

    test('Attachment.fromMap round-trips valid stickerPlacement and drops invalid values', () {
      final valid = Attachment.fromMap({
        'guid': 'at_0_VALID',
        'stickerPlacement': {
          'xScalar': 0.91605839,
          'yScalar': 0.72125813,
          'scale': 0.58042599,
          'rotation': 0.1569,
          'parentPreviewWidth': 277.13,
        },
      });
      expect(StickerPlacement.tryParse(valid.stickerPlacement), isNotNull);
      expect(valid.toMap()['stickerPlacement'], equals(valid.stickerPlacement));

      final invalid = Attachment.fromMap({
        'guid': 'at_0_INVALID',
        'stickerPlacement': {'xScalar': 0.5, 'scale': -1},
      });
      expect(invalid.stickerPlacement, isNull);
    });
  });

  group('Apple CKTranscriptStickerCell geometry & Material/iOS parity', () {
    test('placedCenter and placementAt are exact inverses for iOS and Material, both sides', () {
      const bubble = Size(240, 80);
      const center = Offset(137.5, 42.25);

      for (final isFromMe in [true, false]) {
        for (final tailGutter in [true, false]) {
          final p = StickerHolder.placementAt(center, bubble, isFromMe, tailGutter);
          final roundTrip = StickerHolder.placedCenter(p, bubble, isFromMe, tailGutter);
          expect(roundTrip.dx, closeTo(center.dx, 1e-9), reason: 'isFromMe=$isFromMe tailGutter=$tailGutter');
          expect(roundTrip.dy, closeTo(center.dy, 1e-9), reason: 'isFromMe=$isFromMe tailGutter=$tailGutter');
        }
      }
    });

    test('Material & media-collection bubbles (tailGutter=false) center symmetrically for both sides', () {
      const bubble = Size(200, 100);
      const mid = StickerPlacement(xScalar: 0.5, yScalar: 0.5, scale: 1, rotation: 0, parentPreviewWidth: 200);

      final outgoing = StickerHolder.placedCenter(mid, bubble, true, false);
      final incoming = StickerHolder.placedCenter(mid, bubble, false, false);
      expect(outgoing, equals(const Offset(100, 50)));
      expect(incoming, equals(const Offset(100, 50)));

      // iOS tailGutter=true keeps 12px tail gutter + 4px opposite body inset
      final iosOut = StickerHolder.placedCenter(mid, bubble, true, true);
      final iosIn = StickerHolder.placedCenter(mid, bubble, false, true);
      expect(iosOut.dx, closeTo(4 + 0.5 * (200 - 16), 1e-9)); // 96
      expect(iosIn.dx, closeTo(12 + 0.5 * (200 - 16), 1e-9)); // 104

      // Narrow bubble (<16px) never produces a negative body width
      final narrow = StickerHolder.placedCenter(mid, const Size(10, 40), true, true);
      expect(narrow.dx, closeTo(4.0, 1e-9));
    });

    test('drawScale & placedRect match Apple scaling, rotation, and 200pt maxPoints cap', () {
      // Live chat.db row 16079: 140x300px, ssa=2.4, spw=252.67 -> 300/3*2.4 = 240pt -> capped to 200pt
      const tallPlacement = StickerPlacement(
        xScalar: 0.5,
        yScalar: 0.5,
        scale: 2.4,
        rotation: 0,
        parentPreviewWidth: 252.67,
      );
      final rectCapped = StickerHolder.placedRect(
        const PlacedSticker(tallPlacement, Size(140, 300)),
        const Size(252.67, 100),
        true,
        false,
      );
      expect(rectCapped.height, closeTo(StickerHolder.maxPoints, 1e-6));
      expect(rectCapped.width, closeTo(StickerHolder.maxPoints * (140 / 300), 1e-6));

      // Live chat.db row 68527: 505x900px, spv=1, sro=0.7577 rad, ssa=0.3857, spw=273.94
      const rotated = StickerPlacement(
        xScalar: 0.9,
        yScalar: 0.4,
        scale: 0.3857,
        rotation: 0.7577,
        parentPreviewWidth: 273.94,
      );
      const bubble = Size(220, 120);
      final scale = StickerHolder.drawScale(rotated, bubble);
      expect(scale, closeTo(0.3857 * 220 / 273.94, 1e-9));

      final w = 505 / 3 * scale;
      final h = 900 / 3 * scale;
      final cos = math.cos(0.7577).abs();
      final sin = math.sin(0.7577).abs();
      final rectRot = StickerHolder.placedRect(
        const PlacedSticker(rotated, Size(505, 900)),
        bubble,
        false,
        true,
      );
      expect(rectRot.width, closeTo(w * cos + h * sin, 1e-6));
      expect(rectRot.height, closeTo(w * sin + h * cos, 1e-6));

      // Zero parentPreviewWidth falls back to raw scale; non-positive scale yields 0
      expect(
        StickerHolder.drawScale(
          const StickerPlacement(xScalar: 0.5, yScalar: 0.5, scale: 0.8, rotation: 0, parentPreviewWidth: 0),
          bubble,
        ),
        closeTo(0.8, 1e-9),
      );
      expect(
        StickerHolder.drawScale(
          const StickerPlacement(xScalar: 0.5, yScalar: 0.5, scale: 0, rotation: 0, parentPreviewWidth: 200),
          bubble,
        ),
        equals(0),
      );
    });

    test('StickerHolder.space reserves overhang and clamps to available column width', () {
      // Overhanging sticker on the right edge of an outgoing bubble
      const overhangRight = StickerPlacement(
        xScalar: 1.25,
        yScalar: -0.1,
        scale: 0.75,
        rotation: 0,
        parentPreviewWidth: 200,
      );
      final room = StickerHolder.space(
        [const PlacedSticker(overhangRight, Size(300, 300))],
        const Size(200, 60),
        true,
        false,
        240,
      );
      // Sticker center at (250, -6), half-size 37.5 -> top=-43.5, right=287.5 (overhang 87.5)
      // Clamped horizontal room: columnWidth - bubble.width = 40
      expect(room.top, closeTo(43.5, 1e-6));
      expect(room.right, closeTo(40.0, 1e-6));
      expect(room.left, equals(0));
      expect(room.bottom, equals(0));
    });
  });

  group('StickerHolder & CollectionAttachmentStickers widget rendering', () {
    setUpAll(_registerTestServices);
    tearDownAll(() async {
      await GetIt.I.reset();
    });
    testWidgets('renders placed sticker with exact center/rotation/scale and measures size synchronously',
        (tester) async {
      const placement = StickerPlacement(
        xScalar: 0.75,
        yScalar: 0.25,
        scale: 0.9,
        rotation: 0.42,
        parentPreviewWidth: 200,
      );
      final stickerMsg = _makeStickerMessage(
        guid: 'STICKER-1',
        attachmentId: 0, // tests unsaved / web-style fallback keying by guid
        partId: 0,
        placement: placement.toMap(),
      );
      final parentMsg = Message(guid: 'PARENT-GUID', text: 'hello', isFromMe: true);
      parentMsg.associatedMessages.add(stickerMsg);
      final state = MessageState(parentMsg);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 80,
                child: MessageStateScope(
                  messageState: state,
                  child: StickerHolder(
                    stickerMessages: [stickerMsg],
                    controller: null,
                    isFromMe: true,
                    tailGutter: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final positioned = tester.widget<Positioned>(find.byKey(const ValueKey<Object>('at_0_STICKER-1')));
      expect(positioned.left, closeTo(150.0, 1e-6));
      expect(positioned.top, closeTo(20.0, 1e-6));

      final rotate = tester.widget<Transform>(
        find.descendant(of: find.byKey(const ValueKey<Object>('at_0_STICKER-1')), matching: find.byType(Transform)).first,
      );
      expect(rotate.transform.entry(0, 0), closeTo(math.cos(0.42), 1e-6));
      expect(rotate.transform.entry(1, 0), closeTo(math.sin(0.42), 1e-6));

      // Decoded 1x1 PNG size was reported cleanly to MessageState for StickerSpace
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(state.stickerSizes['at_0_STICKER-1'], equals(const Size(1, 1)));
    });

    testWidgets('CollectionAttachmentStickers renders p:3 and p:5 stickers only on their matching photo cards',
        (tester) async {
      // Mirrors live chat.db parent 6724A661-... (4-photo collection) with stickers on p:3 and p:5
      final p0 = MessagePart(part: 0, attachments: [Attachment(guid: 'photo_0', mimeType: 'image/jpeg')]);
      final p1 = MessagePart(part: 1, attachments: [Attachment(guid: 'photo_1', mimeType: 'image/jpeg')]);
      final p3 = MessagePart(part: 3, attachments: [Attachment(guid: 'photo_3', mimeType: 'image/jpeg')]);
      final p5 = MessagePart(part: 5, attachments: [Attachment(guid: 'photo_5', mimeType: 'image/jpeg')]);
      final collection = MessagePart.collapseMediaCollections([p0, p1, p3, p5]).single;

      final stickerP3 = _makeStickerMessage(
        guid: 'STICKER-P3',
        attachmentId: 301,
        partId: 3,
        placement: const StickerPlacement(
          xScalar: 0.64425055,
          yScalar: 0.28432214,
          scale: 1.07218242,
          rotation: 0.00623223,
          parentPreviewWidth: 160,
        ).toMap(),
      );
      final stickerP5 = _makeStickerMessage(
        guid: 'STICKER-P5',
        attachmentId: 501,
        partId: 5,
        placement: const StickerPlacement(
          xScalar: 0.586,
          yScalar: 0.471,
          scale: 0.95,
          rotation: -0.1,
          parentPreviewWidth: 160,
        ).toMap(),
      );
      final parentMsg = Message(guid: 'PARENT-GUID', isFromMe: true);
      parentMsg.associatedMessages.addAll([stickerP3, stickerP5]);
      final state = MessageState(parentMsg);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageStateScope(
              messageState: state,
              child: Row(
                children: [
                  for (var i = 0; i < 4; i++)
                    SizedBox(
                      key: ValueKey('card_$i'),
                      width: 160,
                      height: 160,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CollectionAttachmentStickers(collectionPart: collection, attachmentIndex: i),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Cards 0 and 1 have no placed stickers
      expect(find.descendant(of: find.byKey(const ValueKey('card_0')), matching: find.byType(StickerHolder)), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('card_1')), matching: find.byType(StickerHolder)), findsNothing);

      // Card 2 (p:3) renders only STICKER-P3 at (0.64425055 * 160, 0.28432214 * 160)
      final card2Sticker =
          find.descendant(of: find.byKey(const ValueKey('card_2')), matching: find.byKey(const ValueKey<Object>(301)));
      expect(card2Sticker, findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('card_2')), matching: find.byKey(const ValueKey<Object>(501))),
        findsNothing,
      );
      final pos3 = tester.widget<Positioned>(card2Sticker);
      expect(pos3.left, closeTo(0.64425055 * 160, 1e-5));
      expect(pos3.top, closeTo(0.28432214 * 160, 1e-5));

      // Card 3 (p:5) renders only STICKER-P5 at (0.586 * 160, 0.471 * 160)
      final card3Sticker =
          find.descendant(of: find.byKey(const ValueKey('card_3')), matching: find.byKey(const ValueKey<Object>(501)));
      expect(card3Sticker, findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('card_3')), matching: find.byKey(const ValueKey<Object>(301))),
        findsNothing,
      );
      final pos5 = tester.widget<Positioned>(card3Sticker);
      expect(pos5.left, closeTo(0.586 * 160, 1e-5));
      expect(pos5.top, closeTo(0.471 * 160, 1e-5));
    });

    testWidgets('StickerSpace inflates bubble for overhang on Material & iOS, and skips outer inflation on media collections',
        (tester) async {
      final stickerMsg = _makeStickerMessage(
        guid: 'STICKER-OVERHANG',
        attachmentId: 777,
        partId: 0,
        placement: const StickerPlacement(
          xScalar: 1.0,
          yScalar: 0.0,
          scale: 1.0,
          rotation: 0.0,
          parentPreviewWidth: 200,
        ).toMap(),
      );
      final parentMsg = Message(guid: 'PARENT-OVERHANG', text: 'hi', isFromMe: false);
      parentMsg.associatedMessages.add(stickerMsg);
      final state = MessageState(parentMsg);
      state.updateStickerSizeInternal('at_0_STICKER-OVERHANG', const Size(300, 300));

      final textPart = MessagePart(part: 0, text: 'hi');

      // Material skin: tailGutter=false -> symmetric horizontal overhang around 200x60 bubble
      SettingsSvc.settings.skin.value = Skins.Material;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MessageStateScope(
                messageState: state,
                child: StickerSpace(
                  key: const ValueKey('sticker_space_mat'),
                  part: textPart,
                  columnWidth: 360,
                  child: const SizedBox(width: 200, height: 60),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final matSize = tester.getSize(find.byKey(const ValueKey('sticker_space_mat')));
      // Center at x=200, y=0; 100x100pt sticker -> top overhang 50pt, bottom 0, right overhang 50pt -> 250x110
      expect(matSize.width, closeTo(250.0, 1e-4));
      expect(matSize.height, closeTo(110.0, 1e-4));

      // Media collection: StickerSpace returns child directly without bogus outer inflation
      final p0 = MessagePart(part: 0, attachments: [Attachment(guid: 'a0', mimeType: 'image/jpeg')]);
      final p1 = MessagePart(part: 1, attachments: [Attachment(guid: 'a1', mimeType: 'image/jpeg')]);
      final collection = MessagePart.collapseMediaCollections([p0, p1]).single;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MessageStateScope(
                messageState: state,
                child: StickerSpace(
                  key: const ValueKey('sticker_space_col'),
                  part: collection,
                  columnWidth: 360,
                  child: const SizedBox(width: 240, height: 180),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final colSize = tester.getSize(find.byKey(const ValueKey('sticker_space_col')));
      expect(colSize, equals(const Size(240, 180)));
    });

    testWidgets('renders optimistically sent temp* placed sticker immediately from in-memory bytes', (tester) async {
      const placement = StickerPlacement(
        xScalar: 0.35,
        yScalar: 0.65,
        scale: 1.2,
        rotation: -0.35,
        parentPreviewWidth: 240,
      );
      final tempSticker = _makeStickerMessage(
        guid: 'temp-STICKER-OPT',
        attachmentId: 0,
        partId: 0,
        placement: placement.toMap(),
      );
      final parentMsg = Message(guid: 'PARENT-GUID', text: 'optimistic', isFromMe: true);
      parentMsg.associatedMessages.add(tempSticker);
      final state = MessageState(parentMsg);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: 90,
                child: MessageStateScope(
                  messageState: state,
                  child: StickerHolder(
                    stickerMessages: [tempSticker],
                    controller: null,
                    isFromMe: true,
                    tailGutter: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final positioned = tester.widget<Positioned>(find.byKey(const ValueKey<Object>('at_0_temp-STICKER-OPT')));
      // tailGutter=true, isFromMe=true => 4 + 0.35 * (240 - 16) = 82.4
      expect(positioned.left, closeTo(82.4, 1e-6));
      expect(positioned.top, closeTo(58.5, 1e-6));

      final rotate = tester.widget<Transform>(
        find
            .descendant(
              of: find.byKey(const ValueKey<Object>('at_0_temp-STICKER-OPT')),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(rotate.transform.entry(0, 0), closeTo(math.cos(-0.35), 1e-6));
      expect(rotate.transform.entry(1, 0), closeTo(math.sin(-0.35), 1e-6));

      await tester.pump(const Duration(milliseconds: 750));
    });
  });

  group('StickerDropTarget peel-and-place drag-drop & live ghost/transform affordance', () {
    setUpAll(_registerTestServices);
    tearDownAll(() async {
      await GetIt.I.reset();
    });

    testWidgets('shows live ghost preview + transform readout on hover, adjusts scale/rotation, and queues placed sticker on drop',
        (tester) async {
      final outgoing = GetIt.I<OutgoingMessageHandler>() as _FakeOutgoingMessageHandler;
      outgoing.placed.clear();

      const sticker = LibrarySticker(
        identifier: 'st-heart',
        shelf: 'saved',
        mimeType: 'image/png',
        longestSide: 300,
      );
      final dragData = StickerDrag(sticker);
      final targetMsg = Message(guid: 'MSG-TARGET-1', text: 'drop here', isFromMe: true);
      final chat = Chat(guid: 'iMessage;-;+15550001111');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 20,
                  child: Draggable<StickerDrag>(
                    data: dragData,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: const SizedBox(width: 40, height: 40),
                    child: const ColoredBox(
                      key: ValueKey('drag_source'),
                      color: Colors.blue,
                      child: SizedBox(width: 48, height: 48),
                    ),
                  ),
                ),
                Positioned(
                  left: 100,
                  top: 120,
                  width: 240,
                  height: 80,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const SizedBox.expand(),
                      Positioned.fill(
                        child: StickerDropTarget(
                          message: targetMsg,
                          part: 1,
                          chat: chat,
                          tailGutter: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final sourceCenter = tester.getCenter(find.byKey(const ValueKey('drag_source')));
      final targetOrigin = tester.getTopLeft(find.byType(StickerDropTarget));
      final dropPoint = targetOrigin + const Offset(160, 40);

      final gesture = await tester.startGesture(sourceCenter);
      await tester.pump();
      // Break drag touch slop so _DragAvatar starts, then move over the bubble
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveTo(dropPoint);
      await tester.pump();

      // Live ghost preview & restrained transform pill appear while hovering
      expect(find.text('100% · 0°'), findsOneWidget);

      // Scroll-wheel / keyboard scale & rotation adjust the live transform while hovering
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.pump();
      expect(dragData.transform.value.scale, closeTo(1.12, 1e-6));
      expect(dragData.transform.value.rotation, closeTo(math.pi / 12, 1e-6));
      expect(find.text('112% · 15°'), findsOneWidget);

      // Pointer scroll further adjusts scale
      tester.binding.handlePointerEvent(PointerScrollEvent(
        position: dropPoint,
        scrollDelta: const Offset(0, -100),
      ));
      await tester.pump();
      expect(dragData.transform.value.scale, closeTo(1.27, 1e-6));

      // Drop onto the bubble
      await gesture.up();
      await tester.pumpAndSettle();

      // Hover overlay clears after drop and OutgoingMsgHandler queues the exact normalized placement
      expect(find.textContaining('% · '), findsNothing);
      expect(outgoing.placed, hasLength(1));
      final call = outgoing.placed.single;
      expect(call.selected.guid, equals('MSG-TARGET-1'));
      expect(call.part, equals(1));
      expect(call.fileName, equals('sticker.png'));
      expect(call.bytes, equals(_kPng1x1));
      expect(call.placement.xScalar, closeTo(160 / 240, 1e-6));
      expect(call.placement.yScalar, closeTo(40 / 80, 1e-6));
      expect(call.placement.parentPreviewWidth, closeTo(240, 1e-6));
      expect(
        call.placement.scale,
        closeTo(StickerHolder.scaleForPoints(StickerLibraryTile.dragSize * 1.27, 300), 1e-6),
      );
      expect(call.placement.rotation, closeTo(math.pi / 12, 1e-6));
    });

    testWidgets('rejects drops on unsent temp* messages without highlighting or queueing', (tester) async {
      final outgoing = GetIt.I<OutgoingMessageHandler>() as _FakeOutgoingMessageHandler;
      outgoing.placed.clear();

      const sticker = LibrarySticker(
        identifier: 'st-temp-reject',
        shelf: 'saved',
        mimeType: 'image/png',
        longestSide: 300,
      );
      final dragData = StickerDrag(sticker);
      final tempTarget = Message(guid: 'temp-MSG-UNSENT', text: 'pending', isFromMe: true);
      final chat = Chat(guid: 'iMessage;-;+15550001111');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 20,
                  child: Draggable<StickerDrag>(
                    data: dragData,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: const SizedBox(width: 40, height: 40),
                    child: const ColoredBox(
                      key: ValueKey('drag_source_reject'),
                      color: Colors.blue,
                      child: SizedBox(width: 48, height: 48),
                    ),
                  ),
                ),
                Positioned(
                  left: 100,
                  top: 120,
                  width: 200,
                  height: 60,
                  child: StickerDropTarget(
                    message: tempTarget,
                    part: 0,
                    chat: chat,
                    tailGutter: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('drag_source_reject'))));
      await tester.pump();
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(StickerDropTarget)));
      await tester.pump();

      expect(find.textContaining('% · '), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(outgoing.placed, isEmpty);
    });
  });

  group('Sticker crash guards & unified fallback', () {
    test('StickerHolder geometry guards zero, negative, NaN, and Infinity sizes without throwing', () {
      const invalidPlacement = StickerPlacement(
        xScalar: double.nan,
        yScalar: double.infinity,
        scale: 1.0,
        rotation: 0.0,
        parentPreviewWidth: 200,
      );
      expect(invalidPlacement.isValid, isFalse);
      expect(StickerPlacement.centeredDefault.isValid, isTrue);

      expect(StickerHolder.placedCenter(invalidPlacement, const Size(200, 80), false, false), Offset.zero);
      expect(StickerHolder.placedCenter(StickerPlacement.centeredDefault, Size.zero, false, true), Offset.zero);
      expect(StickerHolder.placedCenter(StickerPlacement.centeredDefault, Size.infinite, true, true), Offset.zero);

      expect(
        StickerHolder.placementAt(const Offset(double.nan, 10), const Size(200, 80), false, false),
        StickerPlacement.centeredDefault,
      );
      expect(
        StickerHolder.placementAt(const Offset(10, 10), Size.zero, false, false),
        StickerPlacement.centeredDefault,
      );

      expect(StickerHolder.drawScale(invalidPlacement, const Size(200, 80)), 0);
      expect(StickerHolder.drawScale(StickerPlacement.centeredDefault, Size.zero), 0);
      expect(StickerHolder.drawScale(StickerPlacement.centeredDefault, Size.infinite), 0);

      expect(
        StickerHolder.placedRect(const PlacedSticker(StickerPlacement.centeredDefault, Size.zero), const Size(200, 80), false, false),
        Rect.zero,
      );
      expect(
        StickerHolder.space(
          const [PlacedSticker(StickerPlacement.centeredDefault, Size(300, 300))],
          Size.zero,
          false,
          true,
          double.infinity,
        ),
        EdgeInsets.zero,
      );
    });

    test('Message.fromMap parses bp:p:0/GUID and string associatedMessagePart safely', () {
      final msg = Message.fromMap({
        'guid': 'STICKER-1',
        'associatedMessageGuid': 'bp:p:2/TARGET-GUID',
        'associatedMessageType': 'sticker',
        'isFromMe': false,
        'dateCreated': 1700000000000,
      });
      expect(msg.associatedMessageGuid, 'TARGET-GUID');
      expect(msg.associatedMessagePart, 2);

      final msgNoPart = Message.fromMap({
        'guid': 'STICKER-2',
        'associatedMessageGuid': 'TARGET-GUID',
        'associatedMessageType': 'sticker',
        'isFromMe': true,
        'dateCreated': 1700000000000,
      });
      expect(msgNoPart.associatedMessageGuid, 'TARGET-GUID');
      expect(msgNoPart.associatedMessagePart, isNull);
    });

    testWidgets('StickerHolder renders ancient sticker without placement via centeredDefault and survives zero-size constraints', (tester) async {
      final attachment = Attachment(
        guid: 'ancient-sticker-1',
        mimeType: 'image/png',
        bytes: _kPng1x1,
        stickerPlacement: null,
      );
      final stickerMsg = Message(
        guid: 'STICKER-ANCIENT-1',
        associatedMessageType: 'sticker',
        associatedMessagePart: 0,
        dateCreated: DateTime.now(),
      )..dbAttachments.add(attachment);

      // Zero-size constraints must not crash layout
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.fromSize(
              size: Size.zero,
              child: StickerHolder(
                stickerMessages: [stickerMsg],
                isFromMe: false,
                tailGutter: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Normal bubble renders centeredDefault at (100, 40) inside 200x80 bubble
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 80,
                child: StickerHolder(
                  stickerMessages: [stickerMsg],
                  isFromMe: false,
                  tailGutter: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pos = tester.widget<Positioned>(find.byType(Positioned));
      expect(pos.left, closeTo(100, 1e-6));
      expect(pos.top, closeTo(40, 1e-6));
    });
  });
}

import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/collections/collection_attachment_card.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_reactions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/widgets/reaction_details.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/sticker_tapback_image.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/tapback_icon.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_server_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:defer_pointer/defer_pointer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
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

class _FakePrefsThemeActions extends SharedPreferencesThemeActions {
  _FakePrefsThemeActions(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsServerActions extends SharedPreferencesServerActions {
  _FakePrefsServerActions(super.service);
}

class _FakePrefsMessagingActions extends SharedPreferencesMessagingActions {
  _FakePrefsMessagingActions(super.service);

  @override
  List<String> getRecentTapbackEmojis({String? chatGuid}) => const [];
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
    server = _FakePrefsServerActions(this);
    messaging = _FakePrefsMessagingActions(this);
  }
}

void _registerTestServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    final settingsService = SettingsService()..settings = _TestSettings();
    GetIt.I.registerSingleton<SettingsService>(settingsService);
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
}

ThemeData _testTheme({Brightness brightness = Brightness.light}) {
  final scheme = ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
  );
}

Message _rxn({
  required String guid,
  required String type,
  String? emoji,
  bool isFromMe = false,
  int handleId = 1,
  String? handleAddress,
  Attachment? stickerAttachment,
}) {
  final m = Message(
    guid: guid,
    associatedMessageGuid: 'p:0/parent-1',
    associatedMessageType: type,
    associatedMessageEmoji: emoji,
    isFromMe: isFromMe,
    handleId: isFromMe ? 0 : handleId,
    dateCreated: DateTime(2026, 1, 1, 12, 0),
    hasAttachments: stickerAttachment != null,
  );
  if (!isFromMe && handleAddress != null) {
    m.handle = Handle(address: handleAddress, originalROWID: handleId);
  }
  if (stickerAttachment != null) {
    m.dbAttachments.add(stickerAttachment);
  }
  return m;
}

Widget _wrapWithScope({
  required MessageState state,
  required Widget child,
  Brightness brightness = Brightness.light,
}) {
  return MaterialApp(
    theme: _testTheme(brightness: brightness),
    home: Scaffold(
      body: DeferredPointerHandler(
        child: Center(
          child: MessageStateScope(
            messageState: state,
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(_registerTestServices);

  tearDown(() {
    SettingsSvc.settings.skin.value = Skins.Material;
  });

  group('Material Google Messages reactions', () {
    testWidgets('single Apple tapback renders 28dp emoji pill with surface cutout & tonal fill (light/dark)',
        (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;

      for (final brightness in [Brightness.light, Brightness.dark]) {
        final parent = Message(guid: 'parent-1', text: 'Hi', isFromMe: false, dateCreated: DateTime(2026));
        final love = _rxn(guid: 'r-love', type: ReactionTypes.LOVE, handleId: 10);
        parent.associatedMessages.add(love);
        final part = MessagePart(part: 0, text: 'Hi');
        final state = MessageState(parent)..parts.add(part);

        await tester.pumpWidget(_wrapWithScope(
          state: state,
          brightness: brightness,
          child: ReactionHolder(reactions: [love]),
        ));
        await tester.pumpAndSettle();

        expect(find.text('❤️'), findsOneWidget);
        expect(find.byType(TapbackIcon), findsNothing);

        final rxnSize = tester.getSize(find.byType(ReactionWidget));
        expect(rxnSize, const Size(28.0, 28.0));

        final badgeContainer = tester.widgetList<Container>(find.descendant(
          of: find.byType(ReactionWidget),
          matching: find.byType(Container),
        )).firstWhere((c) => c.decoration is ShapeDecoration);
        final dec = badgeContainer.decoration! as ShapeDecoration;
        expect(dec.shape, isA<MaterialReactionBadgeShape>());
        final shape = dec.shape as MaterialReactionBadgeShape;
        expect(shape.hasCount, isFalse);
        expect(shape.side.width, ReactionWidget.materialCutoutBorderWidth);

        final cs = _testTheme(brightness: brightness).colorScheme;
        final expectedFill =
            brightness == Brightness.dark ? cs.surfaceContainerHighest : cs.surfaceContainerLowest;
        expect(dec.color, expectedFill);
        expect(shape.side.color, ReactionWidget.materialBorderColor(cs, brightness));
      }
    });

    testWidgets('self-reaction highlights with primaryContainer fill and themed primary hairline border', (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-1', text: 'Hi', isFromMe: false, dateCreated: DateTime(2026));
      final ownLike = _rxn(guid: 'r-own', type: ReactionTypes.LIKE, isFromMe: true);
      parent.associatedMessages.add(ownLike);
      final state = MessageState(parent)..parts.add(MessagePart(part: 0, text: 'Hi'));

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: ReactionHolder(reactions: [ownLike]),
      ));
      await tester.pumpAndSettle();

      expect(find.text('👍'), findsOneWidget);
      final badgeContainer = tester.widgetList<Container>(find.descendant(
        of: find.byType(ReactionWidget),
        matching: find.byType(Container),
      )).firstWhere((c) => c.decoration is ShapeDecoration);
      final dec = badgeContainer.decoration! as ShapeDecoration;
      final cs = _testTheme().colorScheme;
      expect(dec.color, cs.primaryContainer);
      expect((dec.shape as MaterialReactionBadgeShape).side.color,
          ReactionWidget.materialBorderColor(cs, Brightness.light, isOwn: true));
      // When custom wallpaper is active, fill alpha matches TextBubble (0.86).
      expect(
        ReactionWidget.materialFillColor(cs, Brightness.dark, hasWallpaper: true).a,
        closeTo(ReactionWidget.materialWallpaperAlpha, 0.001),
      );
      expect(
        ReactionWidget.materialFillColor(cs, Brightness.light, isOwn: true, hasWallpaper: true).a,
        closeTo(ReactionWidget.materialWallpaperAlpha, 0.001),
      );
    });

    testWidgets('multi-reaction merges matching emoji into 36x28 fused count lobe and renders distinct pills side-by-side',
        (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-1', text: 'Hi', isFromMe: true, dateCreated: DateTime(2026));
      final r1 = _rxn(guid: 'r1', type: ReactionTypes.LOVE, handleId: 1);
      final r2 = _rxn(guid: 'r2', type: ReactionTypes.EMOJI, emoji: '❤️', isFromMe: true);
      final r3 = _rxn(guid: 'r3', type: ReactionTypes.EMOJI, emoji: '🔥', handleId: 2);
      parent.associatedMessages.addAll([r1, r2, r3]);
      final state = MessageState(parent)..parts.add(MessagePart(part: 0, text: 'Hi'));

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: ReactionHolder(reactions: [r1, r2, r3]),
      ));
      await tester.pumpAndSettle();

      // Standard Apple `love` + custom `❤️` merge into one 36x28 pill with count '2'; `🔥` is 28x28.
      expect(find.byType(ReactionWidget), findsNWidgets(2));
      expect(find.text('❤️'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);

      final rect0 = tester.getRect(find.byType(ReactionWidget).at(0));
      final rect1 = tester.getRect(find.byType(ReactionWidget).at(1));
      expect(rect0.size, const Size(36.0, 28.0));
      expect(rect1.size, const Size(28.0, 28.0));
      // 4dp horizontal gap, non-overlapping.
      expect(rect1.left - rect0.right, closeTo(ReactionHolder.materialBadgeGap, 0.01));
    });

    testWidgets('overflow truncates beyond 5 unique groups with +N pill', (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-1', text: 'Hi', isFromMe: false, dateCreated: DateTime(2026));
      final emojis = ['❤️', '😂', '🔥', '🎉', '🙌', '👀'];
      final list = [
        for (int i = 0; i < emojis.length; i++)
          _rxn(guid: 'r-$i', type: ReactionTypes.EMOJI, emoji: emojis[i], handleId: i + 1),
      ];
      parent.associatedMessages.addAll(list);
      final state = MessageState(parent)..parts.add(MessagePart(part: 0, text: 'Hi'));

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: ReactionHolder(reactions: list),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ReactionWidget), findsNWidgets(4));
      expect(find.byType(MaterialReactionOverflowBadge), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('sticker tapback scales to 36x36 (1.3x) and renders StickerTapbackImage', (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-1', text: 'Hi', isFromMe: false, dateCreated: DateTime(2026));
      final sticker = _rxn(
        guid: 'r-sticker',
        type: ReactionTypes.STICKER,
        handleId: 3,
        stickerAttachment: Attachment(guid: 'att-sticker-1', transferName: 'sticker.png', mimeType: 'image/png'),
      );
      parent.associatedMessages.add(sticker);
      final part = MessagePart(part: 0, text: 'Hi');
      final state = MessageState(parent)..parts.add(part);

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: MaterialReactionBubble(
          part: part,
          child: const SizedBox(key: Key('bubble'), width: 140, height: 44),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(StickerTapbackImage), findsOneWidget);
      expect(tester.getSize(find.byType(ReactionWidget)), const Size(36.0, 36.0));
      // Clearance: 44 + (36 - 9 + 2) = 73dp
      expect(tester.getSize(find.byType(MaterialReactionBubble)).height, closeTo(73.0, 0.01));
    });

    testWidgets('MaterialReactionBubble positions pill at bottom-end (-9dp overlap, +2dp pad) and hit-tests protruding area to open Reaction Summary sheet',
        (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-1', text: 'Hello world', isFromMe: true, dateCreated: DateTime(2026));
      final ownLove = _rxn(guid: 'r-own', type: ReactionTypes.LOVE, isFromMe: true);
      final otherFire = _rxn(
        guid: 'r-other',
        type: ReactionTypes.EMOJI,
        emoji: '🔥',
        handleId: 4,
        handleAddress: '+15551234567',
      );
      parent.associatedMessages.addAll([ownLove, otherFire]);
      final part = MessagePart(part: 0, text: 'Hello world');
      final state = MessageState(parent)..parts.add(part);

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: MaterialReactionBubble(
          part: part,
          child: const SizedBox(key: Key('bubble'), width: 180, height: 48),
        ),
      ));
      await tester.pumpAndSettle();

      final bubbleRect = tester.getRect(find.byKey(const Key('bubble')));
      final holderRect = tester.getRect(find.byType(ReactionHolder));
      final wrapperRect = tester.getRect(find.byType(MaterialReactionBubble));

      // Overlaps bottom edge by 9dp and reserves 28 - 9 + 2 = 21dp below bubble.
      expect(holderRect.top, closeTo(bubbleRect.bottom - 9.0, 0.01));
      expect(wrapperRect.height, closeTo(48.0 + 21.0, 0.01));
      expect(holderRect.right, closeTo(bubbleRect.right - 4.0, 0.01));

      // Tap strictly BELOW bubbleRect.bottom (inside the protruding bottom half of the pill).
      final tapPoint = Offset(holderRect.left + 14.0, bubbleRect.bottom + 10.0);
      expect(tapPoint.dy, greaterThan(bubbleRect.bottom));
      await tester.tapAt(tapPoint);
      await tester.pumpAndSettle();

      // Google Messages vertical Reaction Summary sheet opened.
      expect(find.text('Reactions'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Tap to remove'), findsOneWidget);
    });

    testWidgets('ReactionDetails Material sheet filters by emoji and invokes onRemoveOwnReaction', (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final ownLove = _rxn(guid: 'r-own', type: ReactionTypes.LOVE, isFromMe: true);
      final otherFire = _rxn(
        guid: 'r-other',
        type: ReactionTypes.EMOJI,
        emoji: '🔥',
        handleId: 9,
        handleAddress: 'alice@example.com',
      );
      Message? removed;

      await tester.pumpWidget(MaterialApp(
        theme: _testTheme(),
        home: Scaffold(
          body: ReactionDetails(
            reactions: [ownLove, otherFire],
            onRemoveOwnReaction: (m) => removed = m,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Reactions'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);

      // Filter to 🔥 only -> hides 'You'.
      await tester.tap(find.text('🔥 1'));
      await tester.pumpAndSettle();
      expect(find.text('You'), findsNothing);
      expect(find.text('alice@example.com'), findsOneWidget);

      // Back to All, then tap own row to remove.
      await tester.tap(find.text('All 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tap to remove'));
      await tester.pumpAndSettle();
      expect(removed?.guid, 'r-own');
    });

    testWidgets('CollectionAttachmentReactions insets badges at bottom-right in Material and preserves top overhang in iOS',
        (tester) async {
      final parent = Message(guid: 'parent-1', text: '', isFromMe: false, dateCreated: DateTime(2026));
      final love = _rxn(guid: 'r1', type: ReactionTypes.LOVE, handleId: 1);
      parent.associatedMessages.add(love);
      final colPart = MessagePart(
        part: 0,
        attachments: [Attachment(guid: 'att-col-0', transferName: 'photo.jpg', mimeType: 'image/jpeg')],
      );
      final state = MessageState(parent)..parts.add(colPart);

      // Material
      SettingsSvc.settings.skin.value = Skins.Material;
      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.grey)),
              CollectionAttachmentReactions(collectionPart: colPart, attachmentIndex: 0),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final matPos = tester.widget<Positioned>(find
          .descendant(
            of: find.byType(CollectionAttachmentReactions),
            matching: find.byType(Positioned),
          )
          .first);
      expect(matPos.bottom, 6.0);
      expect(matPos.right, 6.0);
      expect(matPos.top, isNull);

      // iOS
      SettingsSvc.settings.skin.value = Skins.iOS;
      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.grey)),
              CollectionAttachmentReactions(collectionPart: colPart, attachmentIndex: 0),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final iosPos = tester.widget<Positioned>(find
          .descendant(
            of: find.byType(CollectionAttachmentReactions),
            matching: find.byType(Positioned),
          )
          .first);
      expect(iosPos.top, ReactionHolder.bubbleOverhangTop);
      expect(iosPos.right, ReactionHolder.bubbleOverhangSide);
    });
  });

  group('iOS skin reactions preserved intact', () {
    testWidgets('iOS renders TapbackIcon SVG thought-bubble (35x40), top ReactionSpacing=15, and frosted ReactionDetails',
        (tester) async {
      SettingsSvc.settings.skin.value = Skins.iOS;
      final parent = Message(guid: 'parent-1', text: 'Hello', isFromMe: true, dateCreated: DateTime(2026));
      final love = _rxn(guid: 'r-ios', type: ReactionTypes.LOVE, handleId: 1);
      parent.associatedMessages.add(love);
      final part = MessagePart(part: 0, text: 'Hello');
      final state = MessageState(parent)..parts.add(part);

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReactionSpacing(part: part),
            SizedBox(
              width: 160,
              height: 44,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.blue)),
                  ReactionObserver(part: part, chatGuid: 'chat-1'),
                ],
              ),
            ),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(ReactionSpacing)).height, 15.0);
      expect(find.byType(TapbackIcon), findsOneWidget);
      final pos = tester.widget<Positioned>(find
          .descendant(
            of: find.byType(ReactionObserver),
            matching: find.byType(Positioned),
          )
          .first);
      expect(pos.top, ReactionHolder.bubbleOverhangTop);
      expect(pos.left, ReactionHolder.bubbleOverhangSide);

      // iOS ReactionDetails renders BackdropFilter horizontal sheet, not Material "Reactions" title.
      await tester.pumpWidget(MaterialApp(
        theme: _testTheme(),
        home: Scaffold(body: ReactionDetails(reactions: [love])),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('Reactions'), findsNothing);
    });
  });

  group('MaterialReactionBubble inside StickerSpace seam', () {
    testWidgets('anchors reaction pill to bubble edge rather than sticker overhang padding', (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-sticker-rxn', text: 'Hi', isFromMe: true, dateCreated: DateTime(2026));
      final love = _rxn(guid: 'r-seam', type: ReactionTypes.LOVE, handleId: 1);
      final sticker = Message(
        guid: 's-overhang',
        associatedMessageGuid: 'p:0/parent-sticker-rxn',
        associatedMessageType: 'sticker',
        associatedMessagePart: 0,
        dateCreated: DateTime(2026),
        isFromMe: false,
        handleId: 1,
        hasAttachments: true,
      );
      sticker.dbAttachments.add(Attachment(
        guid: 'att-overhang',
        mimeType: 'image/png',
        width: 300,
        height: 300,
        stickerPlacement: {
          'xScalar': 0.5,
          'yScalar': 1.4,
          'scale': 1.0,
          'rotation': 0.0,
          'parentPreviewWidth': 160.0,
        },
      ));
      parent.associatedMessages.addAll([love, sticker]);
      final part = MessagePart(part: 0, text: 'Hi');
      final state = MessageState(parent)..parts.add(part);
      state.updateStickerSizeInternal('att-overhang', const Size(300, 300));

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: Center(
          child: StickerSpace(
            part: part,
            columnWidth: 320,
            child: MaterialReactionBubble(
              part: part,
              child: const SizedBox(
                key: ValueKey('seam-bubble'),
                width: 160,
                height: 44,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final spaceRect = tester.getRect(find.byType(StickerSpace));
      final bubbleRect = tester.getRect(find.byKey(const ValueKey('seam-bubble')));
      final badgeRect = tester.getRect(find.byType(ReactionHolder));
      // Prove StickerSpace genuinely added bottom overhang padding beyond the reaction clearance.
      expect(spaceRect.bottom, greaterThan(bubbleRect.bottom + 25.0));
      // Reaction pill must still overlap the actual bubble bottom by -9dp (not float in sticker overhang).
      expect(badgeRect.top, closeTo(bubbleRect.bottom - ReactionHolder.materialBubbleOverlap, 0.5));
      expect(badgeRect.right, closeTo(bubbleRect.right - 4.0, 0.5));
    });

    testWidgets('centers Material tapback glyph and count lobe inside cutout border', (tester) async {
      SettingsSvc.settings.skin.value = Skins.Material;
      final parent = Message(guid: 'parent-center', text: 'Hi', isFromMe: false, dateCreated: DateTime(2026));
      final r1 = _rxn(guid: 'r-c1', type: ReactionTypes.LOVE, handleId: 1);
      final r2 = _rxn(guid: 'r-c2', type: ReactionTypes.EMOJI, emoji: '❤️', isFromMe: true);
      final r3 = _rxn(guid: 'r-c3', type: ReactionTypes.LIKE, handleId: 2);
      parent.associatedMessages.addAll([r1, r2, r3]);
      final state = MessageState(parent)..parts.add(MessagePart(part: 0, text: 'Hi'));

      await tester.pumpWidget(_wrapWithScope(
        state: state,
        child: ReactionHolder(reactions: [r1, r2, r3]),
      ));
      await tester.pumpAndSettle();

      // Single badge (👍): 28x28 — emoji center must match badge center (not shifted by 1.5px border inset).
      final likeWidget = find.ancestor(of: find.text('👍'), matching: find.byType(ReactionWidget));
      final likeBadgeRect = tester.getRect(likeWidget);
      final likeGlyphCenter = tester.getCenter(find.text('👍'));
      expect(likeGlyphCenter.dx, closeTo(likeBadgeRect.center.dx, 0.1));
      expect(likeGlyphCenter.dy, closeTo(likeBadgeRect.center.dy, 0.1));

      // Multi badge (❤️ x2): 36x28 — emoji centered in left 28x28 circle, count centered in top-right 14x14 ear.
      final loveWidget = find.ancestor(of: find.text('❤️'), matching: find.byType(ReactionWidget));
      final loveBadgeRect = tester.getRect(loveWidget);
      final loveGlyphCenter = tester.getCenter(find.text('❤️'));
      expect(loveGlyphCenter.dx, closeTo(loveBadgeRect.left + ReactionWidget.materialBadgeSize / 2, 0.1));
      expect(loveGlyphCenter.dy, closeTo(loveBadgeRect.top + ReactionWidget.materialBadgeSize / 2, 0.1));

      final countCenter = tester.getCenter(find.text('2'));
      const earSize = ReactionWidget.materialBadgeSize / 2;
      expect(countCenter.dx, closeTo(loveBadgeRect.right - earSize / 2, 0.1));
      expect(countCenter.dy, closeTo(loveBadgeRect.top + earSize / 2, 0.1));
    });
  });
}

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/parts/resolved_file_content.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/reply_bubble_section.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/bubble_effects.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
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

class _FakePrefsThemeActions extends SharedPreferencesThemeActions {
  _FakePrefsThemeActions(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsMessagingActions extends SharedPreferencesMessagingActions {
  _FakePrefsMessagingActions(super.service);

  @override
  List<String> getRecentTapbackEmojis({required String chatGuid}) => const [];
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
    messaging = _FakePrefsMessagingActions(this);
  }
}

void _registerTestServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
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
  if (!GetIt.I.isRegistered<CacheService>()) {
    GetIt.I.registerSingleton<CacheService>(CacheService());
  }
  if (!GetIt.I.isRegistered<LifecycleService>()) {
    GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
  if (!GetIt.I.isRegistered<HttpService>()) {
    GetIt.I.registerSingleton<HttpService>(HttpService());
  }
}

Message _msg({
  required String guid,
  required String text,
  required DateTime createdAt,
  bool isFromMe = false,
  String? threadOriginatorGuid,
  String? threadOriginatorPart,
  bool hasAttachments = false,
}) {
  return Message(
    guid: guid,
    text: text,
    dateCreated: createdAt,
    isFromMe: isFromMe,
    handleId: isFromMe ? 0 : 1,
    hasAttachments: hasAttachments,
    threadOriginatorGuid: threadOriginatorGuid,
    threadOriginatorPart: threadOriginatorPart,
  );
}

Widget _wrapApp({
  required Widget child,
  required Chat chat,
  required Skins skin,
}) {
  SettingsSvc.settings.skin.value = skin;
  final theme = ThemesService.materialYouTheme(skin == Skins.iOS ? Brightness.dark : Brightness.light);
  final chatState = ChatsSvc.getOrCreateChatState(chat);
  ChatsSvc.activeChat = chatState;
  return MaterialApp(
    theme: theme,
    home: ChatStateScope(
      chatState: chatState,
      child: Scaffold(
        body: child,
      ),
    ),
  );
}

Future<ByteData> _rasterize(Size size, void Function(Canvas canvas) draw) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.ceil(), size.height.ceil());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!;
}

int _maxAlphaInColumn(ByteData rgba, int width, int height, int x) {
  var maxA = 0;
  for (var y = 0; y < height; y++) {
    final idx = (y * width + x) * 4 + 3;
    final a = rgba.getUint8(idx);
    if (a > maxA) maxA = a;
  }
  return maxA;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    _registerTestServices();
  });

  group('Thread line: shorter rendered width, right fade, unchanged hit area', () {
    test('Material compactHook renders shorter fading line while preserving full-width hit area', () async {
      const size = Size(500, 44);
      final fullTipX = ReplyLinePainter.compactHookTipX(
        Offset.zero,
        size,
        isFromMe: true,
        bubbleWidth: 100,
      );
      expect(fullTipX, closeTo(392.0, 0.01));
      final visualTipX = ReplyLinePainter.visualArmEndX(18.0, fullTipX, minArmAfterCurve: 22.0);
      expect(visualTipX, lessThan(fullTipX - 200));

      final rgba = await _rasterize(size, (canvas) {
        ReplyLinePainter.paintConnector(
          canvas: canvas,
          offset: Offset.zero,
          size: size,
          isFromMe: true,
          connectUpper: true,
          connectLower: false,
          color: const Color(0xFF4488FF),
          bubbleWidth: 100,
          compactHook: true,
        );
      });

      final alphaAtStem = _maxAlphaInColumn(rgba, 500, 44, 18);
      final alphaMidArm = _maxAlphaInColumn(rgba, 500, 44, 55);
      final alphaNearTip = _maxAlphaInColumn(rgba, 500, 44, visualTipX.round() - 2);
      final alphaBeyondVisualTip = _maxAlphaInColumn(rgba, 500, 44, 250);

      expect(alphaAtStem, greaterThan(200));
      expect(alphaMidArm, inInclusiveRange(20, alphaAtStem - 10));
      expect(alphaNearTip, lessThan(alphaMidArm));
      expect(alphaBeyondVisualTip, equals(0));

      // Hit testing must still cover the full original clickable span up to the bubble edge.
      expect(
        ReplyLinePainter.hitTestCompactHook(
          const Offset(250, 22),
          size,
          isFromMe: true,
          connectUpper: true,
          bubbleWidth: 100,
        ),
        isTrue,
      );
      expect(
        ReplyLinePainter.hitTestCompactHook(
          Offset(fullTipX, 22),
          size,
          isFromMe: true,
          connectUpper: true,
          bubbleWidth: 100,
        ),
        isTrue,
      );
    });

    test('iOS ReplyLinePainter renders shorter fading horizontal arm while hitTestConnector stays full-width', () async {
      const size = Size(500, 44);
      final rgba = await _rasterize(size, (canvas) {
        ReplyLinePainter.paintConnector(
          canvas: canvas,
          offset: Offset.zero,
          size: size,
          isFromMe: true,
          connectUpper: true,
          connectLower: false,
          color: const Color(0xFF888888),
          bubbleWidth: 100,
          compactHook: false,
        );
      });

      final visualTipX = ReplyLinePainter.visualArmEndX(35.0, 392.0, minArmAfterCurve: 30.0);
      expect(visualTipX, lessThan(200));
      final alphaAtStem = _maxAlphaInColumn(rgba, 500, 44, 35);
      final alphaMidArm = _maxAlphaInColumn(rgba, 500, 44, 70);
      final alphaBeyondVisualTip = _maxAlphaInColumn(rgba, 500, 44, 250);

      expect(alphaAtStem, greaterThan(200));
      expect(alphaMidArm, inInclusiveRange(20, alphaAtStem - 10));
      expect(alphaBeyondVisualTip, equals(0));

      // Clickable hit area still spans all the way to the reply bubble on iOS.
      expect(
        ReplyLinePainter.hitTestConnector(
          const Offset(250, 22),
          size,
          isFromMe: true,
          connectUpper: true,
          connectLower: false,
          compactHook: false,
          bubbleWidth: 100,
        ),
        isTrue,
      );
    });

    test('ReplyQuoteHookPainter shortens painted arm and fades out while hitTestHook keeps full span', () async {
      const size = Size(400, 44);
      final fullPath = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: true,
        replyFromMe: false,
        quotedBubbleWidth: 120,
        quotedBubbleHeight: 36,
      );
      final shortPath = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: true,
        replyFromMe: false,
        quotedBubbleWidth: 120,
        quotedBubbleHeight: 36,
        shortenArm: true,
      );

      expect(shortPath.getBounds().right, lessThan(fullPath.getBounds().right - 100));

      final rgba = await _rasterize(size, (canvas) {
        ReplyQuoteHookPainter.paintHook(
          canvas,
          size,
          quotedFromMe: true,
          replyFromMe: false,
          color: const Color(0xFF4488FF),
          quotedBubbleWidth: 120,
          quotedBubbleHeight: 36,
        );
      });

      expect(_maxAlphaInColumn(rgba, 400, 44, 18), greaterThan(200));
      expect(_maxAlphaInColumn(rgba, 400, 44, 55), inInclusiveRange(20, 220));
      expect(_maxAlphaInColumn(rgba, 400, 44, 200), equals(0));

      expect(
        ReplyQuoteHookPainter.hitTestHook(
          const Offset(200, 18),
          size,
          quotedFromMe: true,
          replyFromMe: false,
          quotedBubbleWidth: 120,
          quotedBubbleHeight: 36,
        ),
        isTrue,
      );
    });

    testWidgets('Material & iOS thread lines remain tappable beyond shortened visual tip', (tester) async {
      for (final skin in [Skins.Material, Skins.iOS]) {
        final chat = Chat(guid: 'iMessage;-;hit-${skin.name}', chatIdentifier: 'hit-${skin.name}');
        final service = ensureMessagesSvc(chat.guid);
        final cvController = ConversationViewController(chat);
        Get.put<ConversationViewController>(cvController, tag: chat.guid);

        final t0 = DateTime(2026, 11, 18, 12, 0, 0);
        final orig = _msg(guid: 'orig-${skin.name}', text: 'Originator', createdAt: t0, isFromMe: false);
        final reply = _msg(
          guid: 'reply-${skin.name}',
          text: 'Hi',
          createdAt: t0.add(const Duration(minutes: 1)),
          isFromMe: true,
          threadOriginatorGuid: orig.guid,
          threadOriginatorPart: '0:0:0',
        );
        service.struct.addMessages([orig, reply]);

        await tester.pumpWidget(
          _wrapApp(
            chat: chat,
            skin: skin,
            child: Center(
              child: SizedBox(
                width: 480,
                child: MessageHolder(
                  cvController: cvController,
                  message: reply,
                  oldMessage: orig,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final boxRect = tester.getRect(find.byType(ReplyLineBox).last);
        // Tap mid-row along the invisible extended horizontal span (~200px from left edge).
        await tester.tapAt(Offset(boxRect.left + 200, boxRect.center.dy));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Close thread'), findsOneWidget);

        // Dismiss popup and unmount before deleting GetX services.
        await tester.tap(find.byTooltip('Close thread'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
    });
  });

  group('Ghost message bubble: uniform 4-corner rounding across skins & modes', () {
    test('TailClipper with showTail=false and connectUpper/Lower=false rounds all 4 corners symmetrically', () {
      const size = Size(200, 60);
      for (final isIOS in [false, true]) {
        SettingsSvc.settings.skin.value = isIOS ? Skins.iOS : Skins.Material;
        for (final isFromMe in [false, true]) {
          final clipper = TailClipper(
            isFromMe: isFromMe,
            showTail: false,
            connectUpper: false,
            connectLower: false,
          );
          final path = clipper.getClip(size);
          final bounds = path.getBounds();
          final xLeft = bounds.left;
          final xRight = bounds.right;

          // Symmetric top vs bottom corner rounding: corners at inset 2px must be outside the rounded path,
          // and top/bottom curvature at inset 8px must match.
          expect(path.contains(Offset(xLeft + 2, 2)), isFalse);
          expect(path.contains(Offset(xRight - 2, 2)), isFalse);
          expect(path.contains(Offset(xLeft + 2, size.height - 2)), isFalse);
          expect(path.contains(Offset(xRight - 2, size.height - 2)), isFalse);
          expect(
            path.contains(Offset(xLeft + 8, 8)),
            equals(path.contains(Offset(xLeft + 8, size.height - 8))),
          );
          expect(
            path.contains(Offset(xRight - 8, 8)),
            equals(path.contains(Offset(xRight - 8, size.height - 8))),
          );
        }
      }
    });

    testWidgets('Material & Samsung inline ReplyBubbleSection uses uniform 20px radius on all 4 corners', (tester) async {
      for (final skin in [Skins.Material, Skins.Samsung]) {
        for (final quotedFromMe in [false, true]) {
          final chat = Chat(guid: 'iMessage;-;mat-ghost-${skin.name}-$quotedFromMe', chatIdentifier: 'g');
          final service = ensureMessagesSvc(chat.guid);
          final cvController = ConversationViewController(chat);
          Get.put<ConversationViewController>(cvController, tag: chat.guid);

          final t0 = DateTime(2026, 11, 18, 13, 0, 0);
          final orig = _msg(guid: 'orig', text: 'Quoted ghost', createdAt: t0, isFromMe: quotedFromMe);
          final reply = _msg(
            guid: 'reply',
            text: 'Reply text',
            createdAt: t0.add(const Duration(minutes: 1)),
            isFromMe: !quotedFromMe,
            threadOriginatorGuid: 'orig',
            threadOriginatorPart: '0:0:0',
          );
          service.struct.addMessages([orig, reply]);

          await tester.pumpWidget(
            _wrapApp(
              chat: chat,
              skin: skin,
              child: MessageHolder(cvController: cvController, message: reply, oldMessage: null),
            ),
          );
          await tester.pumpAndSettle();

          final section = find.byType(ReplyBubbleSection);
          expect(section, findsOneWidget);
          final clipRRect = tester.widget<ClipRRect>(
            find.descendant(of: section, matching: find.byType(ClipRRect)).first,
          );
          final br = clipRRect.borderRadius as BorderRadius;
          expect(br.topLeft, const Radius.circular(20));
          expect(br.topRight, const Radius.circular(20));
          expect(br.bottomLeft, const Radius.circular(20));
          expect(br.bottomRight, const Radius.circular(20));

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          Get.delete<ConversationViewController>(tag: chat.guid, force: true);
          Get.delete<MessagesService>(tag: chat.guid, force: true);
        }
      }
    });

    testWidgets('iOS inline ReplyBubble (incoming & outgoing, text & attachment) disables tail & rounds all 4 corners',
        (tester) async {
      for (final quotedFromMe in [false, true]) {
        final chat = Chat(guid: 'iMessage;-;ios-ghost-$quotedFromMe', chatIdentifier: 'ios-g');
        final service = ensureMessagesSvc(chat.guid);
        final cvController = ConversationViewController(chat);
        Get.put<ConversationViewController>(cvController, tag: chat.guid);

        final t0 = DateTime(2026, 11, 18, 14, 0, 0);
        final orig = _msg(guid: 'orig', text: 'Quoted iOS ghost', createdAt: t0, isFromMe: quotedFromMe);
        final reply = _msg(
          guid: 'reply',
          text: 'iOS reply',
          createdAt: t0.add(const Duration(minutes: 1)),
          isFromMe: quotedFromMe,
          threadOriginatorGuid: 'orig',
          threadOriginatorPart: '0:0:0',
        );
        service.struct.addMessages([orig, reply]);

        await tester.pumpWidget(
          _wrapApp(
            chat: chat,
            skin: Skins.iOS,
            child: MessageHolder(cvController: cvController, message: reply, oldMessage: null),
          ),
        );
        await tester.pumpAndSettle();

        final replyBubbleFinder = find.byType(ReplyBubble);
        expect(replyBubbleFinder, findsOneWidget);

        final clipPaths = tester.widgetList<ClipPath>(
          find.descendant(of: replyBubbleFinder, matching: find.byType(ClipPath)),
        );
        expect(clipPaths, isNotEmpty);
        for (final cp in clipPaths) {
          final clipper = cp.clipper! as TailClipper;
          expect(clipper.showTail, isFalse);
          expect(clipper.connectUpper, isFalse);
          expect(clipper.connectLower, isFalse);
        }

        final customPaints = tester.widgetList<CustomPaint>(
          find.descendant(of: replyBubbleFinder, matching: find.byType(CustomPaint)),
        );
        for (final cp in customPaints) {
          if (cp.painter is TailPainter) {
            expect((cp.painter! as TailPainter).showTail, isFalse);
          }
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }

      // Verify AttachmentHolder inside ReplyScope & GhostBubbleScope forces uniform 4-corner rounding.
      final chat = Chat(guid: 'iMessage;-;att-ghost', chatIdentifier: 'att-g');
      final service = ensureMessagesSvc(chat.guid);
      final cvController = ConversationViewController(chat);
      Get.put<ConversationViewController>(cvController, tag: chat.guid);
      final attachment = Attachment(
        guid: 'att-1',
        mimeType: 'image/png',
        transferName: 'photo.png',
        totalBytes: 1024,
      );
      final msg = _msg(
        guid: 'att-msg',
        text: '',
        createdAt: DateTime(2026, 11, 18, 14, 5, 0),
        isFromMe: true,
        hasAttachments: true,
      );
      msg.dbAttachments.add(attachment);
      service.struct.addMessages([msg]);
      final ms = service.getOrCreateState(msg);
      ms.cvController = cvController;
      // Give ms a newer grouped message that would normally tighten bottom corners / show tail.
      ms.newMessage = _msg(
        guid: 'att-next',
        text: 'Grouped follow-up',
        createdAt: DateTime(2026, 11, 18, 14, 5, 10),
        isFromMe: true,
      );
      final prevAutoDownload = SettingsSvc.settings.autoDownload.value;
      SettingsSvc.settings.autoDownload.value = false;
      final attState = ms.getOrCreateAttachmentState(attachment.guid!, attachment: attachment);
      attState.resolvedFile.value = PlatformFile(name: 'photo.png', size: 1024, path: '/nonexistent/photo.png');

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.Material,
          child: MessageStateScope(
            messageState: ms,
            child: ReplyScope(
              child: AttachmentHolder(
                message: MessagePart(part: 0, attachments: [attachment]),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final resolvedContent = tester.widget<ResolvedFileContent>(find.byType(ResolvedFileContent));
      expect(resolvedContent.forceAllCornersRounded, isTrue);

      SettingsSvc.settings.autoDownload.value = prevAutoDownload;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('Reply thread popup originator ghost bubble disables tail & connectLower even if grouped in main chat',
        (tester) async {
      for (final skin in [Skins.Material, Skins.iOS]) {
        final chat = Chat(guid: 'iMessage;-;popup-ghost-${skin.name}', chatIdentifier: 'pg-${skin.name}');
        final service = ensureMessagesSvc(chat.guid);
        final cvController = ConversationViewController(chat);
        Get.put<ConversationViewController>(cvController, tag: chat.guid);

        final t0 = DateTime(2026, 11, 18, 15, 0, 0);
        final orig = _msg(guid: 'orig', text: 'Originator message', createdAt: t0, isFromMe: true);
        final nextInMainChat = _msg(
          guid: 'main-next',
          text: 'Follow up in main chat',
          createdAt: t0.add(const Duration(seconds: 10)),
          isFromMe: true,
        );
        final threadReply = _msg(
          guid: 'thread-r1',
          text: 'Thread reply',
          createdAt: t0.add(const Duration(minutes: 1)),
          isFromMe: false,
          threadOriginatorGuid: 'orig',
          threadOriginatorPart: '0:0:0',
        );
        service.struct.addMessages([orig, nextInMainChat, threadReply]);

        // Simulate main-chat MessageState already having stale oldMessage/newMessage assigned.
        final origState = service.getOrCreateState(orig);
        origState.oldMessage = _msg(
          guid: 'main-prev',
          text: 'Earlier grouped',
          createdAt: t0.subtract(const Duration(seconds: 5)),
          isFromMe: true,
        );
        origState.newMessage = nextInMainChat;

        await tester.pumpWidget(
          _wrapApp(
            chat: chat,
            skin: skin,
            child: Column(
              children: [
                MessageHolder(
                  cvController: cvController,
                  message: orig,
                  oldMessage: null,
                  newMessage: threadReply,
                  isReplyThread: true,
                  replyPart: 0,
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        final clipPaths = tester.widgetList<ClipPath>(find.byType(ClipPath));
        expect(clipPaths, isNotEmpty);
        for (final cp in clipPaths) {
          if (cp.clipper is TailClipper) {
            final clipper = cp.clipper! as TailClipper;
            expect(clipper.showTail, isFalse);
            expect(clipper.connectUpper, isFalse);
            expect(clipper.connectLower, isFalse);
          }
        }
        final effects = tester.widget<BubbleEffects>(find.byType(BubbleEffects));
        expect(effects.showTail, isFalse);
        expect(find.byType(GhostBubbleScope), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
    });
  });
}

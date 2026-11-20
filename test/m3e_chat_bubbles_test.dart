import 'dart:io';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/components/m3e/m3e_shapes.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/text/text_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/delivered_indicator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/typing/typing_indicator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/send_button.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_component.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {
  final Rx<ServerDetails> fakeDetails = const ServerDetails(
    macOSVersion: 14,
    macOSMinorVersion: 0,
    serverVersion: '1.9.0',
    serverVersionCode: 10900,
  ).obs;

  @override
  ServerDetails get serverDetails => fakeDetails.value;
}

void _registerServices(_FakeSettingsService settingsService) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settingsService);
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
}

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    _registerServices(settingsService);
  });

  group('P0-1 TypingIndicator Material pill', () {
    testWidgets('renders surfaceContainerHigh pill with 20dp radius, 28dp avatar, and 6.5dp dots', (tester) async {
      final chat = Chat(guid: 'iMessage;-;+15551234567', chatIdentifier: '+15551234567');
      chat.handles.add(Handle(address: '+15551234567'));
      final chatState = ChatState(chat);
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData(useMaterial3: true, colorScheme: scheme),
          home: ChatStateScope(
            chatState: chatState,
            child: const Scaffold(
              body: TypingIndicator(visible: true),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final avatar = tester.widget<ContactAvatarWidget>(find.byType(ContactAvatarWidget));
      expect(avatar.size, 28);

      final pillContainer = tester.widgetList<Container>(find.byType(Container)).firstWhere(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).borderRadius == M3EShapes.radiusLgIncreased,
      );
      expect((pillContainer.decoration as BoxDecoration).color, scheme.surfaceContainerHigh);
      expect(pillContainer.constraints?.minHeight, 38);

      expect(find.byType(AnimatedDot), findsNWidgets(3));
      final dotSize = tester.getSize(find.byType(AnimatedDot).first);
      // 6.5dp dot + 5dp horizontal margin
      expect(dotSize.height, closeTo(6.5, 0.1));
    });
  });

  group('P0-4 SendButton & TextFieldComponent transport + zero emoji rule', () {
    test('resolveMaterialStyle picks distinct container colors and compact badges by service', () {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);

      final imsg = SendButton.resolveMaterialStyle(scheme, isIMessage: true, isRCS: false);
      expect(imsg.container, scheme.primaryContainer);
      expect(imsg.foreground, scheme.onPrimaryContainer);
      expect(imsg.badge, 'iMsg');

      final rcs = SendButton.resolveMaterialStyle(scheme, isIMessage: false, isRCS: true);
      expect(rcs.container, scheme.tertiaryContainer);
      expect(rcs.foreground, scheme.onTertiaryContainer);
      expect(rcs.badge, 'RCS');

      final sms = SendButton.resolveMaterialStyle(scheme, isIMessage: false, isRCS: false);
      expect(sms.container, scheme.secondaryContainer);
      expect(sms.foreground, scheme.onSecondaryContainer);
      expect(sms.badge, 'SMS');

      final none = SendButton.resolveMaterialStyle(scheme, isIMessage: false, isRCS: false, hasChat: false);
      expect(none.container, scheme.primaryContainer);
      expect(none.badge, isNull);
    });

    testWidgets('SendButton renders RCS/SMS/iMsg badge and schedule icon when scheduled', (tester) async {
      final rcsChat = Chat(guid: 'RCS;-;+15551234567', chatIdentifier: '+15551234567');
      final chatState = ChatState(rcsChat);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: ChatStateScope(
            chatState: chatState,
            child: Scaffold(
              body: SendButton(
                onLongPress: () {},
                sendMessage: () {},
                isScheduled: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('RCS'), findsOneWidget);
      expect(find.byIcon(Icons.schedule_send_rounded), findsOneWidget);
    });

    testWidgets('TextFieldComponent has zero emoji button in Material compose bar', (tester) async {
      final focus = FocusNode();
      final textCtrl = MentionTextEditingController(focusNode: focus);
      final subjCtrl = SpellCheckTextEditingController(focusNode: focus);
      addTearDown(() {
        textCtrl.dispose();
        subjCtrl.dispose();
        focus.dispose();
      });

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TextFieldComponent(
                subjectTextController: subjCtrl,
                textController: textCtrl,
                controller: null,
                recorderController: null,
                focusNode: focus,
                sendMessage: ({String? effect}) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);
      expect(find.byIcon(Icons.emoji_emotions), findsNothing);
      expect(find.byIcon(Icons.sentiment_satisfied_alt), findsNothing);
      expect(find.byTooltip('Emoji'), findsNothing);
    });
  });

  group('P1-3 Outgoing tonal gradient & TailClipper M3EShapes.lgIncreased', () {
    test('outgoingTonalGradient preserves dark/light contrast direction and alpha', () {
      const darkBase = Color(0xFF0B57D0);
      final darkGradient = TextBubble.outgoingTonalGradient(darkBase, alpha: 0.86);
      expect(darkGradient.length, 2);
      expect(darkGradient[0].a, closeTo(0.86, 0.01));
      expect(darkGradient[1].a, closeTo(0.86, 0.01));
      expect(darkGradient[1].computeLuminance(), lessThanOrEqualTo(darkGradient[0].computeLuminance()));

      const lightBase = Color(0xFFD3E3FD);
      final lightGradient = TextBubble.outgoingTonalGradient(lightBase);
      expect(lightGradient.length, 2);
      expect(lightGradient[1].computeLuminance(), greaterThanOrEqualTo(lightGradient[0].computeLuminance()));
    });

    test('TailClipper uses M3EShapes.lgIncreased (20dp) on Material skin', () {
      final clipper = TailClipper(
        isFromMe: true,
        showTail: true,
        connectUpper: false,
        connectLower: false,
      );
      final path = clipper.getClip(const Size(120, 60));
      // Corner at (1, 1) lies outside a 20dp rounded rect (since 20*(1 - 1/sqrt(2)) ~ 5.86 > 1)
      expect(path.contains(const Offset(1, 1)), isFalse);
      // Point at (6, 6) lies inside a 20dp rounded rect (5.86 < 6), whereas 22dp radius (6.44) would exclude it
      expect(path.contains(const Offset(6, 6)), isTrue);
    });
  });

  group('P1-5 DeliveredIndicator Material checkmarks & tap-to-expand', () {
    testWidgets('always shows Read icon and detail text when active, and expands older bubbles on forceShow',
        (tester) async {
      final now = DateTime(2026, 11, 19, 14, 14);
      final message = Message(
        guid: 'msg-1',
        text: 'Hello',
        isFromMe: true,
        dateCreated: now,
        dateDelivered: now,
        dateRead: now,
      );
      final messageState = MessageState(message)..showReadIndicator.value = true;
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);

      Widget buildWidget(bool forceShow) {
        return GetMaterialApp(
          theme: ThemeData(useMaterial3: true, colorScheme: scheme),
          home: MessageStateScope(
            messageState: messageState,
            child: Scaffold(
              body: DeliveredIndicator(forceShow: forceShow),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildWidget(false));
      await tester.pumpAndSettle();

      final readPainter = tester
          .widget<CustomPaint>(find.descendant(of: find.bySemanticsLabel('Read'), matching: find.byType(CustomPaint)));
      expect(readPainter.size, const Size(18, 12));
      expect((readPainter.painter as dynamic).color, scheme.primary);
      expect(find.textContaining('Read · ', findRichText: true), findsOneWidget);

      // Older message (indicator flag false) is hidden until tapped (forceShow: true).
      messageState.showReadIndicator.value = false;
      await tester.pumpWidget(buildWidget(false));
      await tester.pumpAndSettle();
      expect(find.textContaining('Read', findRichText: true), findsNothing);

      await tester.pumpWidget(buildWidget(true));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Read'), findsOneWidget);
      expect(find.textContaining('Read · ', findRichText: true), findsOneWidget);
    });

    testWidgets('shows schedule icon while sending and Sent status painter when Sent with forceShow', (tester) async {
      final now = DateTime(2026, 11, 19, 14, 15);
      final sendingMsg = Message(guid: 'msg-2', text: 'Sending', isFromMe: true, dateCreated: now);
      final sendingState = MessageState(sendingMsg)..isSending.value = true;

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MessageStateScope(
            messageState: sendingState,
            child: const Scaffold(body: DeliveredIndicator(forceShow: false)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.textContaining('Sending', findRichText: true), findsOneWidget);

      final sentMsg = Message(guid: 'msg-3', text: 'Sent', isFromMe: true, dateCreated: now);
      final sentState = MessageState(sentMsg);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MessageStateScope(
            messageState: sentState,
            child: const Scaffold(body: DeliveredIndicator(key: ValueKey('sent'), forceShow: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sentPainter = tester
          .widget<CustomPaint>(find.descendant(of: find.bySemanticsLabel('Sent'), matching: find.byType(CustomPaint)));
      expect(sentPainter.size, const Size(12, 12));
      expect(find.textContaining('Sent', findRichText: true), findsOneWidget);
    });
  });

  group('Group chat avatar-to-bubble gap', () {
    test('BubbleConnect.incomingAvatarIndent clears 35dp Material avatar at left 5dp with 6dp gap', () {
      // Material/Samsung avatar sits at left 5.0 with rendered diameter (35 * scale).roundToDouble().
      expect(BubbleConnect.incomingAvatarIndent(isIOS: false, avatarScale: 1.0), 46.0);
      expect(BubbleConnect.incomingAvatarIndent(isIOS: false, avatarScale: 1.2), 53.0);
      // iOS keeps its 35 * scale indent where the 10dp tail gutter already separates avatar from bubble body.
      expect(BubbleConnect.incomingAvatarIndent(isIOS: true, avatarScale: 1.0), 35.0);
    });
  });
}

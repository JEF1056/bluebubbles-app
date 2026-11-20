import 'dart:async';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/address_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

class _FakePendingCallTab extends PendingCallTab {
  bool closed = false;
  String? navigatedUrl;

  @override
  bool get isOpen => !closed;

  @override
  bool navigate(String url) {
    if (closed) return false;
    navigatedUrl = url;
    return true;
  }

  @override
  void close() {
    closed = true;
  }
}

Chat _chat({
  required String guid,
  required List<Handle> handles,
  String? chatIdentifier,
  int style = 45,
}) {
  final chat = Chat(
    guid: guid,
    chatIdentifier: chatIdentifier ?? (handles.isNotEmpty ? handles.first.address : null),
    style: style,
  );
  chat.handles.addAll(handles);
  return chat;
}

void main() {
  late SettingsService settingsService;

  setUp(() async {
    await GetIt.I.reset();
    settingsService = SettingsService();
    settingsService.settings = Settings();
    settingsService.settings.enablePrivateAPI.value = true;
    settingsService.serverDetailsChanges.value = const ServerDetails(
      macOSVersion: 14,
      macOSMinorVersion: 0,
      serverVersion: '1.9.9',
      serverVersionCode: 100,
      supportsFaceTimeCallsFlag: true,
    );
    GetIt.I.registerSingleton<SettingsService>(settingsService);
  });

  tearDown(() async {
    await GetIt.I.reset();
  });

  group('Unified video call routing', () {
    test('iMessage 1:1 requires FaceTime support and never falls back to Meet', () {
      final chat = _chat(
        guid: 'iMessage;-;+15551234567',
        handles: [Handle(address: '+15551234567')],
      );

      expect(canFaceTime(chat), isTrue);
      expect(canVideoCall(chat, isDesktop: false), isTrue);

      settingsService.serverDetailsChanges.value = const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.9',
        serverVersionCode: 100,
        supportsFaceTimeCallsFlag: false,
      );
      expect(canFaceTime(chat), isFalse);
      expect(canVideoCall(chat, isDesktop: false), isFalse);

      settingsService.serverDetailsChanges.value = const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.9',
        serverVersionCode: 100,
        supportsFaceTimeCallsFlag: true,
      );
      settingsService.settings.enablePrivateAPI.value = false;
      expect(canVideoCall(chat, isDesktop: false), isFalse);
    });

    test('SMS and RCS 1:1 route to Meet only when dialable phone exists and not desktop', () {
      final smsPhone = _chat(
        guid: 'SMS;-;+15551234567',
        handles: [Handle(address: '+15551234567', service: 'SMS')],
      );
      final rcsPhone = _chat(
        guid: 'RCS;-;+15551234567',
        handles: [Handle(address: '+15551234567', service: 'RCS')],
      );
      final smsEmailOnly = _chat(
        guid: 'SMS;-;alice@example.com',
        handles: [Handle(address: 'alice@example.com', service: 'SMS')],
      );
      final bizChat = _chat(
        guid: 'SMS;-;urn:biz:12345',
        chatIdentifier: 'urn:biz:12345',
        handles: [Handle(address: '+15551234567', service: 'SMS')],
      );

      expect(canVideoCall(smsPhone, isDesktop: false), isTrue);
      expect(canVideoCall(smsPhone, isDesktop: true), isFalse);
      expect(canVideoCall(rcsPhone, isDesktop: false), isTrue);
      expect(canVideoCall(smsEmailOnly, isDesktop: false), isFalse);
      expect(canVideoCall(bizChat, isDesktop: false), isFalse);
    });

    test('group chats hide chat-level Video button but support per-participant Video', () {
      final imPhone = Handle(address: '+15551234567', service: 'iMessage');
      final imEmail = Handle(address: 'alice@example.com', service: 'iMessage');
      final smsPhone = Handle(address: '+15551234567', service: 'SMS');
      final smsEmail = Handle(address: 'alice@example.com', service: 'SMS');
      final iMessageGroup = _chat(
        guid: 'iMessage;+;chat123',
        style: 43,
        handles: [imPhone, imEmail],
      );
      final smsGroup = _chat(
        guid: 'SMS;+;chat456',
        style: 43,
        handles: [smsPhone, smsEmail],
      );

      expect(canVideoCall(iMessageGroup, isDesktop: false), isFalse);
      expect(canVideoCall(smsGroup, isDesktop: false), isFalse);

      expect(canVideoCallHandle(iMessageGroup, imPhone, isDesktop: false), isTrue);
      expect(canVideoCallHandle(iMessageGroup, imEmail, isDesktop: false), isTrue);
      expect(canVideoCallHandle(smsGroup, smsPhone, isDesktop: false), isTrue);
      expect(canVideoCallHandle(smsGroup, smsEmail, isDesktop: false), isFalse);
    });
  });

  group('launchIntent video behavior', () {
    test('rejects email addresses for video without launching mailto', () async {
      final launched = <Uri>[];
      var duoCalled = false;

      await launchIntent(
        true,
        'alice@example.com',
        isWeb: false,
        launchUrlFn: (u) async {
          launched.add(u);
          return true;
        },
        googleDuoFn: (_) async {
          duoCalled = true;
          return true;
        },
      );

      expect(launched, isEmpty);
      expect(duoCalled, isFalse);
    });

    test('Android native launches googleDuo with normalized phone and shows install error on false', () async {
      final duoNumbers = <String>[];
      final snackbars = <String>[];

      await launchIntent(
        true,
        '+1 (555) 123-4567',
        isWeb: false,
        googleDuoFn: (number) async {
          duoNumbers.add(number);
          return false;
        },
        showSnackbarFn: (title, message, {type = SnackbarType.info}) {
          snackbars.add('$title: $message ($type)');
        },
      );

      expect(duoNumbers, ['+15551234567']);
      expect(snackbars, ['Google Meet: Install Google Meet to place video calls (${SnackbarType.error})']);
    });

    test('Android mobile web launches tachyon intent URI with Meet fallback', () async {
      final launched = <Uri>[];

      await launchIntent(
        true,
        '+1 (555) 123-4567',
        isWeb: true,
        isAndroidWebOverride: true,
        launchUrlFn: (uri) async {
          launched.add(uri);
          return true;
        },
      );

      expect(launched, hasLength(1));
      final raw = launched.single.toString();
      expect(raw, contains('scheme=tel'));
      expect(raw, contains('package=com.google.android.apps.tachyon'));
      expect(raw, contains('action=com.google.android.apps.tachyon.action.CALL'));
      expect(raw, contains('B.com.google.android.apps.tachyon.extra.IS_AUDIO_ONLY=false'));
      expect(raw, contains('S.browser_fallback_url=https%3A%2F%2Fduo.google.com%2F'));
    });

    test('desktop web copies normalized phone, opens duo.google.com, and shows snackbar', () async {
      final launched = <Uri>[];
      final copied = <String>[];
      final snackbars = <String>[];

      await launchIntent(
        true,
        '+1 (555) 123-4567',
        isWeb: true,
        isAndroidWebOverride: false,
        launchUrlFn: (uri) async {
          launched.add(uri);
          return true;
        },
        copyClipboardFn: (text) async => copied.add(text),
        showSnackbarFn: (title, message, {type = SnackbarType.info}) => snackbars.add('$title: $message'),
      );

      expect(copied, ['+15551234567']);
      expect(launched, [Uri.parse('https://duo.google.com/')]);
      expect(snackbars, ['Google Meet: Copied +15551234567 — paste in Google Meet to ring']);
    });
  });

  group('OutgoingFaceTimeSheet web popup-blocker handling', () {
    testWidgets('redirects pre-opened tab when server call resolves', (tester) async {
      final tab = _FakePendingCallTab();
      final controller = ActiveCallController();
      addTearDown(controller.dispose);
      var fallbackOpenCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => OutgoingFaceTimeSheet(
                      callerName: 'Alice',
                      initialVideo: true,
                      callController: controller,
                      initialPendingTab: tab,
                      checkTelecomEnabled: () async => true,
                      onOpenCallingAccounts: () async {},
                      requestCallPermissions: () async => true,
                      onPlaceNativeAudioCall: () async => false,
                      onStartServerCall: (_) async => const PlacedFaceTimeCall(
                        link: 'https://facetime.apple.com/join#abc',
                        call: FaceTimeCall(callUuid: 'uuid-tab-1'),
                      ),
                      onTryOpenJoinLink: (_) async {
                        fallbackOpenCalled = true;
                        return true;
                      },
                      onOpenJoinLink: (_) async => fallbackOpenCalled = true,
                      onHangUpRingingCall: (_) async {},
                    ),
                  );
                },
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(tab.navigatedUrl, 'https://facetime.apple.com/join#abc');
      expect(tab.closed, isFalse);
      expect(fallbackOpenCalled, isFalse);
      expect(find.byType(OutgoingFaceTimeSheet), findsNothing);
    });

    testWidgets('closes pre-opened tab on Cancel call', (tester) async {
      final tab = _FakePendingCallTab();
      final pending = Completer<PlacedFaceTimeCall>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutgoingFaceTimeSheet(
              callerName: 'Bob',
              initialVideo: true,
              initialPendingTab: tab,
              checkTelecomEnabled: () async => true,
              onOpenCallingAccounts: () async {},
              requestCallPermissions: () async => true,
              onPlaceNativeAudioCall: () async => false,
              onStartServerCall: (_) => pending.future,
              onOpenJoinLink: (_) async {},
              onHangUpRingingCall: (_) async {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Cancel call'));
      await tester.pumpAndSettle();

      expect(tab.closed, isTrue);
      expect(tab.navigatedUrl, isNull);
    });

    testWidgets('keeps sheet open in Ringing — Join FaceTime state when popup is blocked', (tester) async {
      final controller = ActiveCallController();
      addTearDown(controller.dispose);
      String? joinedLink;
      String? hungUpUuid;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutgoingFaceTimeSheet(
              callerName: 'Carol',
              initialVideo: true,
              callController: controller,
              checkTelecomEnabled: () async => true,
              onOpenCallingAccounts: () async {},
              requestCallPermissions: () async => true,
              onPlaceNativeAudioCall: () async => false,
              onStartServerCall: (_) async => const PlacedFaceTimeCall(
                link: 'https://facetime.apple.com/join#blocked',
                call: FaceTimeCall(callUuid: 'uuid-blocked-1'),
              ),
              onTryOpenJoinLink: (_) async => false,
              onOpenJoinLink: (link) async => joinedLink = link,
              onHangUpRingingCall: (uuid) async => hungUpUuid = uuid,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ringing — Join FaceTime'), findsOneWidget);
      expect(find.text('Join Call'), findsOneWidget);
      expect(find.text('Hang Up'), findsOneWidget);

      await tester.tap(find.text('Join Call'));
      await tester.pumpAndSettle();

      expect(joinedLink, 'https://facetime.apple.com/join#blocked');
      expect(hungUpUuid, isNull);
    });
  });

  group('canAudioCall / canAudioCallHandle', () {
    test('allows phone SMS/RCS, iMessage phone, and iMessage email when not desktop', () {
      final smsChat = _chat(
        guid: 'SMS;-;+15551234567',
        handles: [Handle(address: '+15551234567', service: 'SMS')],
      );
      final iMsgEmail = _chat(
        guid: 'iMessage;-;alice@icloud.com',
        handles: [Handle(address: 'alice@icloud.com')],
      );
      final bizChat = _chat(
        guid: 'iMessage;-;urn:biz:123',
        chatIdentifier: 'urn:biz:123',
        handles: [Handle(address: 'urn:biz:123')],
      );

      expect(canAudioCall(smsChat, isDesktop: false), isTrue);
      expect(canAudioCall(smsChat, isDesktop: true), isFalse);
      expect(canAudioCall(iMsgEmail, isDesktop: false), isTrue);
      expect(canAudioCall(iMsgEmail, isDesktop: true), isTrue);
      expect(canAudioCall(bizChat, isDesktop: false), isFalse);
      expect(canAudioCallHandle(smsChat, Handle(address: 'alice@icloud.com'), isDesktop: false), isFalse);
    });
  });
}

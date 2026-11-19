import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/failed_to_connect_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/manual_entry_dialog.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:integration_test/integration_test.dart';

class _FakeSettingsService extends SettingsService {}

class _FakeSocketService extends SocketService {}

final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void _registerServices(Skins skin) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  final svc = _FakeSettingsService()..settings = Settings();
  svc.settings.skin.value = skin;
  GetIt.I.registerSingleton<SettingsService>(svc);

  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(_FakeSocketService());
  }
}

Widget _appShell({
  required Brightness brightness,
  required WidgetBuilder bodyBuilder,
  Widget? overlay,
}) {
  final isDark = brightness == Brightness.dark;
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF0A84FF),
      brightness: brightness,
    ),
  );
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: const Text('Messages')),
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [Color(0xFF0F172A), Color(0xFF1E293B), Color(0xFF0B3B5A)]
                    : const [Color(0xFFE0F2FE), Color(0xFFF8FAFC), Color(0xFFDBEAFE)],
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MockBubble('Alex Lin', 'Just landed! Meet at Gate B12?', true, isDark),
                _MockBubble('Maya Jordan', 'Can you review the PR before 5pm?', false, isDark),
                _MockBubble('Samira Patel', 'Dinner at 7:30 sounds great', true, isDark),
                const SizedBox(height: 24),
                Builder(builder: bodyBuilder),
              ],
            ),
          ),
        ),
        if (overlay != null) overlay,
      ],
    ),
  );
}

class _MockBubble extends StatelessWidget {
  const _MockBubble(this.name, this.text, this.isMe, this.isDark);
  final String name;
  final String text;
  final bool isMe;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF0A84FF)
              : (isDark ? const Color(0xFF2C2C2E) : Colors.white),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isMe ? Colors.white70 : (isDark ? Colors.white60 : Colors.black54),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var converted = false;
  setUp(() => converted = false);

  Future<void> snap(WidgetTester tester, String name, {bool settle = true}) async {
    if (settle) {
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (!converted) {
      await binding.convertFlutterSurfaceToImage();
      converted = true;
    }
    await tester.pump(const Duration(milliseconds: 200));
    await binding.takeScreenshot(name);
  }

  Future<void> closeModal(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final nav = Navigator.of(tester.element(find.byType(Scaffold)), rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
    }
  }

  testWidgets('Visual QA: Material Dark & Light Modals', (tester) async {
    _registerServices(Skins.Material);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      final tag = brightness == Brightness.dark ? 'm3_dark' : 'm3_light';
      late BuildContext ctx;
      await tester.pumpWidget(_appShell(
        brightness: brightness,
        bodyBuilder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      // 1. showBBDialog
      unawaited(showBBDialog<void>(
        context: ctx,
        icon: Icons.mark_chat_read_outlined,
        title: 'Mark All as Read?',
        body: 'This will clear unread badges across 14 conversations.',
        actions: [
          BBDialogAction(text: 'Cancel', onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
          BBDialogAction(text: 'Mark Read', isDefault: true, onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
        ],
      ));
      await snap(tester, '${tag}_dialog');
      await closeModal(tester);

      // 2. showAreYouSure destructive
      unawaited(showAreYouSure(
        ctx,
        title: 'Delete Conversation?',
        content: const Text('All messages and attachments in this thread will be permanently removed.'),
        yesText: 'Delete',
        noText: 'Cancel',
        yesIsDestructive: true,
        onNo: () => Navigator.of(ctx, rootNavigator: true).pop(),
        onYes: () => Navigator.of(ctx, rootNavigator: true).pop(),
      ));
      await snap(tester, '${tag}_are_you_sure');
      await closeModal(tester);

      // 3. showBBInputDialog with validation error
      unawaited(showBBInputDialog(
        context: ctx,
        title: 'Rename Group Chat',
        body: 'Choose a name visible to all participants.',
        hintText: 'Weekend Trip',
        labelText: 'Group Name',
        validator: (v) => (v == null || v.trim().length < 3) ? 'Enter at least 3 characters.' : null,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await snap(tester, '${tag}_input_error');
      await closeModal(tester);

      // 4. showBBBottomSheet
      unawaited(showBBBottomSheet<void>(
        context: ctx,
        title: 'Chat Actions',
        subtitle: 'Alex Lin • iMessage',
        builder: (_) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Mute Alerts'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Pin Conversation'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Delete Thread', style: TextStyle(color: Colors.redAccent)),
              onTap: () {},
            ),
          ],
        ),
      ));
      await snap(tester, '${tag}_bottom_sheet');
      await closeModal(tester);
    }

    // Material-only extras: showBBListSelector + BBProgressDialog
    late BuildContext ctx;
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    unawaited(showBBListSelector<String>(
      context: ctx,
      title: 'Send As',
      message: 'Choose which service to use for this message.',
      options: const [
        BBListSelectorOption(label: 'iMessage', value: 'imessage', icon: Icons.chat_bubble_outline),
        BBListSelectorOption(label: 'SMS / Text', value: 'sms', icon: Icons.sms_outlined),
        BBListSelectorOption(label: 'Cancel Draft', value: 'cancel', icon: Icons.delete_outline, isDestructive: true),
      ],
    ));
    await snap(tester, 'm3_dark_list_selector');
    await closeModal(tester);

    unawaited(showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => BBProgressDialog(
        title: 'Syncing Attachments…',
        progress: 0.65,
        actions: [
          BBDialogAction(text: 'Hide', onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
        ],
      ),
    ));
    await snap(tester, 'm3_dark_progress_dialog');
    await closeModal(tester);
  });

  testWidgets('Visual QA: iOS Frosted Glass Modals', (tester) async {
    _registerServices(Skins.iOS);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      final tag = brightness == Brightness.dark ? 'ios_dark' : 'ios_light';
      late BuildContext ctx;
      await tester.pumpWidget(_appShell(
        brightness: brightness,
        bodyBuilder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      unawaited(showBBDialog<void>(
        context: ctx,
        title: 'Mark All as Read?',
        body: 'This will clear unread badges across 14 conversations.',
        actions: [
          BBDialogAction(text: 'Cancel', onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
          BBDialogAction(text: 'Mark Read', isDefault: true, onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
        ],
      ));
      await snap(tester, '${tag}_dialog');
      await closeModal(tester);

      if (brightness == Brightness.dark) {
        unawaited(showAreYouSure(
          ctx,
          title: 'Delete Conversation?',
          content: const Text('All messages and attachments in this thread will be permanently removed.'),
          yesText: 'Delete',
          noText: 'Cancel',
          yesIsDestructive: true,
          onNo: () => Navigator.of(ctx, rootNavigator: true).pop(),
          onYes: () => Navigator.of(ctx, rootNavigator: true).pop(),
        ));
        await snap(tester, '${tag}_are_you_sure');
        await closeModal(tester);

        unawaited(showBBInputDialog(
          context: ctx,
          title: 'Rename Group Chat',
          body: 'Choose a name visible to all participants.',
          hintText: 'Weekend Trip',
          validator: (v) => (v == null || v.trim().length < 3) ? 'Enter at least 3 characters.' : null,
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await snap(tester, '${tag}_input_error');
        await closeModal(tester);

        unawaited(showBBBottomSheet<void>(
          context: ctx,
          title: 'Chat Actions',
          subtitle: 'Alex Lin • iMessage',
          builder: (_) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Mute Alerts'),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Pin Conversation'),
                onTap: () {},
              ),
            ],
          ),
        ));
        await snap(tester, '${tag}_bottom_sheet');
        await closeModal(tester);
      }
    }
  });

  testWidgets('Visual QA: Wave 2 Migrated Setup Modals', (tester) async {
    _registerServices(Skins.Material);
    late BuildContext ctx;
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    unawaited(FailedToConnectDialog.show(ctx, onDismiss: () => Navigator.of(ctx, rootNavigator: true).pop()));
    await snap(tester, 'wave2_failed_to_connect');
    await closeModal(tester);

    unawaited(showDialog<void>(
      context: ctx,
      builder: (_) => ManualEntryDialog(
        onConnect: () {},
        onClose: () => Navigator.of(ctx, rootNavigator: true).pop(),
      ),
    ));
    await snap(tester, 'wave2_manual_entry');
    await closeModal(tester);
  });

  testWidgets('Visual QA: FaceTime & Ongoing Call UI', (tester) async {
    _registerServices(Skins.Material);

    // 1. Incoming Video
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: IncomingFaceTimeScreen(
          callUuid: 'ft-vid-1',
          callerName: 'Alex Lin',
          avatarBytes: _samplePng,
          isAudio: false,
          onAnswerVideo: () {},
          onAnswerAudio: () {},
          onDecline: () {},
        ),
      ),
    ));
    await snap(tester, 'ft_incoming_video');

    // 2. Incoming Audio
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: IncomingFaceTimeScreen(
          callUuid: 'ft-aud-1',
          callerName: 'Maya Jordan',
          isAudio: true,
          onAnswerAudio: () {},
          onDecline: () {},
        ),
      ),
    ));
    await snap(tester, 'ft_incoming_audio');

    // 3. Connecting state (tap Answer Audio)
    await tester.tap(find.bySemanticsLabel('Answer Audio'));
    await snap(tester, 'ft_connecting', settle: false);

    // 4. Outgoing FaceTime Sheet - mode chooser
    late BuildContext ctx;
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    unawaited(showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutgoingFaceTimeSheet(
        callerName: 'Alex Lin',
        callerAddress: '+1 (415) 555-0192',
        isAndroid: true,
        checkTelecomEnabled: () async => true,
        onOpenCallingAccounts: () async {},
        requestCallPermissions: () async => true,
        onPlaceNativeAudioCall: () async => true,
        onStartServerCall: (bool isAudio) async => const PlacedFaceTimeCall(
          call: FaceTimeCall(callUuid: 'out-1', isVideo: true),
          link: 'https://facetime.apple.com/join#mock',
        ),
        onOpenJoinLink: (_) async {},
        onHangUpRingingCall: (_) async {},
      ),
    ));
    await snap(tester, 'ft_outgoing_sheet_choose');
    await closeModal(tester);

    // 5. Outgoing FaceTime Sheet - Telecom banner
    unawaited(showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutgoingFaceTimeSheet(
        callerName: 'Alex Lin',
        callerAddress: '+1 (415) 555-0192',
        isAndroid: true,
        initialVideo: false,
        checkTelecomEnabled: () async => false,
        onOpenCallingAccounts: () async {},
        requestCallPermissions: () async => true,
        onPlaceNativeAudioCall: () async => true,
        onStartServerCall: (bool isAudio) async => const PlacedFaceTimeCall(
          call: FaceTimeCall(callUuid: 'out-1', isVideo: true),
          link: 'https://facetime.apple.com/join#mock',
        ),
        onOpenJoinLink: (_) async {},
        onHangUpRingingCall: (_) async {},
      ),
    ));
    await snap(tester, 'ft_outgoing_sheet_telecom');
    await closeModal(tester);

    // 6. Ongoing Call Pill (expanded + collapsed) over app background
    final callCtrl = ActiveCallController(
      onReturnToCall: (_, __) async {},
      onEndCall: (_, __) async {},
    )..startOngoing(
        callUuid: 'ongoing-1',
        callerName: 'Alex Lin',
        isVideo: true,
        joinLink: 'https://facetime.apple.com/join#mock',
      );
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (_) => const SizedBox.shrink(),
      overlay: OngoingCallPillOverlay(controller: callCtrl),
    ));
    await snap(tester, 'ft_ongoing_pill_expanded');

    // Collapse the pill by tapping the chevron/collapse button if present
    final collapseBtn = find.byIcon(Icons.keyboard_arrow_up_rounded);
    if (collapseBtn.evaluate().isNotEmpty) {
      await tester.tap(collapseBtn.first);
      await snap(tester, 'ft_ongoing_pill_collapsed');
    }
  });
}

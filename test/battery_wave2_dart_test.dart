import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:bluebubbles/app/components/charts/section_skeleton.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/effects/send_effect_picker.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_nearby_sheet.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/backend/lifecycle/lifecycle_port_io.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

class _FakeFindMyBleService extends FindMyBleService {
  _FakeFindMyBleService(this._streamControllerFactory, {this.specFuture}) : super(isSupportedOverride: true);

  final StreamController<FindMyBleScanEvent> Function() _streamControllerFactory;
  final Future<FindMyBleSpec?>? specFuture;
  int scanStartCount = 0;
  int scanCancelCount = 0;

  @override
  Future<bool> checkPermissions() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> isBluetoothEnabled() async => true;

  @override
  Future<FindMyBleSpec?> getBleSpec(String deviceId, {bool forceRefresh = false}) async {
    if (specFuture != null) return specFuture;
    return FindMyBleSpec(
      deviceId: 'dev-1',
      rawId: 'dev-1',
      provider: 'gfind',
      serviceUuid: '0000fe2c-0000-1000-8000-00805f9b34fb',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      supportsUwb: false,
    );
  }

  @override
  Future<bool> canLaunchUwbApp(FindMyBleSpec spec) async => false;

  @override
  Stream<FindMyBleScanEvent> scanStream(FindMyBleSpec spec) {
    scanStartCount++;
    final controller = _streamControllerFactory();
    final origCancel = controller.onCancel;
    controller.onCancel = () async {
      scanCancelCount++;
      await origCancel?.call();
    };
    return controller.stream;
  }
}

void _registerServices() {
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<bb_events.EventDispatcher>()) {
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    final settings = SettingsService()..settings = Settings();
    GetIt.I.registerSingleton<SettingsService>(settings);
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    final prefs = SharedPreferencesService();
    prefs.theme = _FakePrefsThemeActions(prefs);
    prefs.messaging = _FakePrefsMessagingActions(prefs);
    GetIt.I.registerSingleton<SharedPreferencesService>(prefs);
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
}

class _EffectHost extends StatefulWidget {
  const _EffectHost({required this.onReady});

  final void Function(BuildContext context, TickerProvider vsync) onReady;

  @override
  State<_EffectHost> createState() => _EffectHostState();
}

class _EffectHostState extends State<_EffectHost> with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: () => widget.onReady(context, this),
      child: const Text('Open'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Get.testMode = true;
    _registerServices();
  });

  group('Wave 2 battery fixes', () {
    test('createFakeBgIsolatePort replaces previous ReceivePort mapping', () {
      addTearDown(() => IsolateNameServer.removePortNameMapping('bg_isolate'));

      createFakeBgIsolatePort();
      final firstPort = IsolateNameServer.lookupPortByName('bg_isolate');
      expect(firstPort, isNotNull);

      createFakeBgIsolatePort();
      final secondPort = IsolateNameServer.lookupPortByName('bg_isolate');
      expect(secondPort, isNotNull);
      expect(secondPort, isNot(equals(firstPort)));
    });

    testWidgets('SectionSkeleton stops repeating animation when disableAnimations is true', (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(home: Scaffold(body: SectionSkeleton())),
        ),
      );
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: false),
          child: MaterialApp(home: Scaffold(body: SectionSkeleton())),
        ),
      );
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(home: Scaffold(body: SectionSkeleton())),
        ),
      );
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });

    testWidgets('FindMyNearbySheet gates pulse animation and cancels scan on background/timeout', (tester) async {
      late StreamController<FindMyBleScanEvent> streamCtrl;
      final ble = _FakeFindMyBleService(() {
        streamCtrl = StreamController<FindMyBleScanEvent>.broadcast();
        return streamCtrl;
      });
      final controller = FindMyController(autoFetch: false);
      final device = FindMyDevice.fromJson({
        'id': 'dev-1',
        'name': 'Keys',
        'deviceClass': 'Accessory',
        'isConsideredAccessory': true,
        'features': {
          'TRACKER_PROVIDER': 'gfind',
          'CAN_RING': true,
          'CAN_FIND_NEARBY': true,
        },
      });

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: GetMaterialApp(
            home: Scaffold(
              body: FindMyNearbySheet(device: device, controller: controller, bleService: ble),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(ble.scanStartCount, 1);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      // Enable animations -> pulse starts while scanning
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: GetMaterialApp(
            home: Scaffold(
              body: FindMyNearbySheet(device: device, controller: controller, bleService: ble),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));

      // Backgrounding cancels scan subscription and stops pulse animation
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(ble.scanCancelCount, 1);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      // Resuming re-subscribes and restarts pulse
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(ble.scanStartCount, 2);
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));

      // Timeout cancels scan subscription and stops pulse
      streamCtrl.add(const FindMyBleScanEvent(timedOut: true));
      await tester.pump();
      expect(ble.scanCancelCount, 2);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      await streamCtrl.close();
    });

    testWidgets('FindMyNearbySheet skips scan start if lifecycle paused during spec fetch', (tester) async {
      final specCompleter = Completer<FindMyBleSpec?>();
      late StreamController<FindMyBleScanEvent> streamCtrl;
      final ble = _FakeFindMyBleService(() {
        streamCtrl = StreamController<FindMyBleScanEvent>.broadcast();
        return streamCtrl;
      }, specFuture: specCompleter.future);
      final controller = FindMyController(autoFetch: false);
      final device = FindMyDevice.fromJson({
        'id': 'dev-1',
        'name': 'Keys',
        'deviceClass': 'Accessory',
        'isConsideredAccessory': true,
        'features': {
          'TRACKER_PROVIDER': 'gfind',
          'CAN_RING': true,
          'CAN_FIND_NEARBY': true,
        },
      });

      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: GetMaterialApp(
            home: Scaffold(
              body: FindMyNearbySheet(device: device, controller: controller, bleService: ble),
            ),
          ),
        ),
      );
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      specCompleter.complete(
        FindMyBleSpec(
          deviceId: 'dev-1',
          rawId: 'dev-1',
          provider: 'gfind',
          serviceUuid: '0000fe2c-0000-1000-8000-00805f9b34fb',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          supportsUwb: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(ble.scanStartCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(ble.scanStartCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await streamCtrl.close();
    });

    testWidgets('sendEffectAction disposes all effect controllers on route pop', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SettingsSvc.settings.enablePrivateAPI.value = true;
      addTearDown(() => SettingsSvc.settings.enablePrivateAPI.value = false);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData(extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))]),
          home: Scaffold(
            body: _EffectHost(
              onReady: (ctx, vsync) {
                sendEffectAction(
                  ctx,
                  vsync,
                  'hello',
                  '',
                  null,
                  null,
                  'chat-1',
                  ({String? effect}) async {},
                  const [],
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Send with effect'), findsOneWidget);

      // Switch to Screen tab and trigger fireworks, then pop before the 1s stop timer completes.
      await tester.tap(find.text('Screen'));
      await tester.pump();
      await tester.tap(find.text('FIREWORKS'));
      await tester.pump();

      Navigator.of(tester.element(find.text('Send with effect'))).pop();
      await tester.pumpAndSettle();

      // Unmount host with TickerProviderStateMixin; if any controller leaked onto host, dispose throws.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });
  });
}

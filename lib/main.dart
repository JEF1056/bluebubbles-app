import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:async_task/async_task_extension.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/components/app_notice_bar.dart';
import 'package:bluebubbles/app/components/custom/custom_error_box.dart';
import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/app/components/sync_indicator.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/platform/shims/desktop_window.dart';
import 'package:bluebubbles/platform/shims/native_misc.dart'
    show SecureApplication, SecureApplicationProvider, SecureGate;
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:bluebubbles/services/network/http_overrides.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/utils/media_kit_hot_restart_fix.dart'
    if (dart.library.js_interop) 'package:bluebubbles/utils/media_kit_hot_restart_fix_web.dart';
import 'package:bluebubbles/utils/linux_launcher_badge.dart'
    if (dart.library.js_interop) 'package:bluebubbles/utils/linux_launcher_badge_web.dart';
import 'package:bluebubbles/utils/window_effects.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/startup/failure_to_start.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/layouts/startup/splash_screen.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/web_shortcuts_and_routing.dart';
import 'package:bluebubbles/database/html/web_tab_lock.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/lifecycle/web_lifecycle_interop_stub.dart'
    if (dart.library.js_interop) 'package:bluebubbles/services/backend/lifecycle/web_lifecycle_interop_web.dart';
import 'package:bluebubbles/services/backend/notifications/web_notifications_interop_stub.dart'
    if (dart.library.js_interop) 'package:bluebubbles/services/backend/notifications/web_notifications_interop_web.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' hide Priority;
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:universal_io/io.dart';

bool isAuthing = false;
bool _blockedTabSocketGuardInstalled = false;

void _installBlockedTabSocketGuard() {
  if (_blockedTabSocketGuardInstalled || !GetIt.I.isRegistered<SocketService>()) return;
  _blockedTabSocketGuardInstalled = true;
  ever<SocketState>(SocketSvc.state, (state) {
    if (!WebTabLock.instance.isBlocked) return;
    if (state != SocketState.disconnected) {
      SocketSvc.disconnect();
    }
    if (GetIt.I.isRegistered<ChatsService>()) {
      ChatsSvc.setActiveToDead();
    }
    if (GetIt.I.isRegistered<SyncService>()) {
      SyncSvc.onNetworkOnlineChanged(false);
    }
  });
}

@pragma('vm:entry-point')
//ignore: prefer_void_to_null
Future<Null> main(List<String> arguments) async {
  await initApp(false, arguments);
}

@pragma('vm:entry-point')
// ignore: prefer_void_to_null
Future<Null> bubble() async {
  logNamePrefix = 'Bubble';
  await initApp(true, []);
}

//ignore: prefer_void_to_null
Future<Null> initApp(bool bubble, List<String> arguments) async {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    if (kIsWeb) {
      WebTabLock.instance.onRelinquish = () async {
        _installBlockedTabSocketGuard();
        if (GetIt.I.isRegistered<SocketService>()) {
          SocketSvc.disconnect();
        }
        if (GetIt.I.isRegistered<ChatsService>()) {
          ChatsSvc.setActiveToDead();
        }
        if (GetIt.I.isRegistered<SyncService>()) {
          SyncSvc.onNetworkOnlineChanged(false);
        }
      };
      final acquired = await WebTabLock.instance.acquireOnStartup();
      if (!acquired) {
        runApp(_WebTabBlockedApp(
          onUseHere: () async {
            await WebTabLock.instance.takeOver();
            await _bootApp(bubble, arguments);
          },
        ));
        return;
      }
    }

    await _bootApp(bubble, arguments);
  }, (dynamic error, StackTrace stackTrace) {
    print("Failure during app initialization: $error");
    print(stackTrace);
    Logger.error("Unhandled Exception", trace: stackTrace, error: error);
  });
}

Future<void> _bootApp(bool bubble, List<String> arguments) async {
    /* ----- DESKTOP NATIVE SPLASH STATUS ----- */
    // Pushes startup status to the native splash; detached once it's dismissed.
    void Function()? detachSplashStatus;
    if (kIsDesktop && !bubble && arguments.firstOrNull != "minimized") {
      const splashChannel = MethodChannel('bluebubbles/splash');
      bool titleBarApplied = false;
      void pushStatus() {
        splashChannel.invokeMethod('setStatus', StartupTasks.status.value).catchError((_) => null);

        // Keyed on the service being ready rather than on a status string, so
        // adding or renaming startup steps can't make this fire too early.
        if (Platform.isLinux && !titleBarApplied && GetIt.I.isRegistered<SettingsService>()) {
          titleBarApplied = true;
          unawaited(() async {
            await windowManager.ensureInitialized();
            await windowManager.setTitleBarStyle(SettingsSvc.settings.titleBarStyle.value == BBTitleBarStyle.native
                ? TitleBarStyle.normal
                : TitleBarStyle.hidden);
          }());
        }
      }

      void pushProgress() {
        splashChannel.invokeMethod('setProgress', StartupTasks.progress.value).catchError((_) => null);
      }

      StartupTasks.status.addListener(pushStatus);
      StartupTasks.progress.addListener(pushProgress);
      pushStatus();
      detachSplashStatus = () {
        StartupTasks.status.removeListener(pushStatus);
        StartupTasks.progress.removeListener(pushProgress);
      };
    }

    /* ----- RANDOM STUFF INITIALIZATION ----- */
    if (!kIsWeb) {
      HttpOverrides.global = CustomHttpContext();
    }
    dynamic exception;
    StackTrace? stacktrace;

    try {
      await StartupTasks.initStartupServices(isBubble: bubble);

      FlutterError.onError = (details) {
        Logger.error("Rendering Error: ${details.exceptionAsString()}", error: details.exception, trace: details.stack);
      };

      // Once all the services are initialized, we need to perform some
      // startup tasks to ensure that the app has the information it needs.
      StartupTasks.onStartup().then((_) {
        Logger.info("Startup tasks completed");
      }).catchError((e, s) {
        Logger.error("Failed to complete startup tasks!", error: e, trace: s);
      });

      /* ----- DATE FORMATTING INITIALIZATION ----- */
      Future.microtask(() => initializeDateFormatting());

      /* ----- MEDIAKIT INITIALIZATION ----- */
      clearLeakedMpvWakeupCallbacks(); // must run first — see media_kit_hot_restart_fix.dart
      MediaKit.ensureInitialized();

      /* ----- SPLASH SCREEN INITIALIZATION ----- */
      if (!SettingsSvc.settings.finishedSetup.value && !kIsWeb && !kIsDesktop) {
        runApp(MaterialApp(
            home: const SplashScreen(shouldNavigate: false),
            theme: ThemeData(
              fontFamily: kDefaultAppFontFamily,
              colorScheme: ColorScheme.fromSwatch(
                  backgroundColor:
                      PlatformDispatcher.instance.platformBrightness == Brightness.dark ? Colors.black : Colors.white),
            )));
      }

      /* ----- WEB CONTEXT MENU SUPPRESSION ----- */
      if (kIsWeb) {
        suppressBrowserContextMenu();
        try {
          await BrowserContextMenu.disableContextMenu();
        } catch (_) {}
      }

      /* ----- TIME ZONE INITIALIZATION ----- */
      if (!kIsWeb) {
        tz.initializeTimeZones();
        try {
          tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
        } catch (_) {}
      }

      /* ----- ANDROID SPECIFIC INITIALIZATION ----- */
      if (!kIsWeb && !kIsDesktop) {
        /* ----- MLKIT INITIALIZATION ----- */
        // Defer MLKit model check - not critical for startup
        Future.microtask(() async {
          if (!await EntityExtractorModelManager().isModelDownloaded(EntityExtractorLanguage.english.name)) {
            EntityExtractorModelManager().downloadModel(EntityExtractorLanguage.english.name, isWifiRequired: false);
          }
        });
      }

      /* ----- DESKTOP SPECIFIC INITIALIZATION ----- */
      if (kIsDesktop) {
        /* ----- WINDOW INITIALIZATION ----- */
        await windowManager.ensureInitialized();
        await windowManager.setPreventClose(SettingsSvc.settings.closeToTray.value);
        await windowManager.setTitle('BlueBubbles');
        await Window.initialize();
        if (Platform.isWindows) {
          await Window.hideWindowControls();
        } else if (Platform.isLinux) {
          await windowManager.setTitleBarStyle(SettingsSvc.settings.titleBarStyle.value == BBTitleBarStyle.native
              ? TitleBarStyle.normal
              : TitleBarStyle.hidden);
        }
        windowManager.addListener(DesktopWindowListener.instance);
        doWhenWindowReady(() async {
          await windowManager.setMinimumSize(const Size(300, 300));
          Display primary = await ScreenRetriever.instance.getPrimaryDisplay();

          double width = PrefsSvc.desktop.getWindowWidth() ?? 1280;
          double height = PrefsSvc.desktop.getWindowHeight() ?? 720;

          width = width.clamp(300, max(300, primary.size.width));
          height = height.clamp(300, max(300, primary.size.height));

          if (isWaylandSession) {
            // Wayland forbids a client from positioning itself, so only restore
            // the size and leave placement to the compositor.
            await windowManager.setSize(Size(width, height));
          } else {
            // Restore position otherwise
            final centered = await calcWindowPosition(Size(width, height), Alignment.center);
            double posX = PrefsSvc.desktop.getWindowX() ?? centered.dx;
            double posY = PrefsSvc.desktop.getWindowY() ?? centered.dy;
            posX = posX.clamp(0, max(0, primary.size.width - width));
            posY = posY.clamp(0, max(0, primary.size.height - height));
            await windowManager.setBounds(Rect.fromLTWH(posX, posY, width, height));
            await PrefsSvc.desktop.setWindowOffsets(x: posX, y: posY);
          }
          await PrefsSvc.desktop.setWindowDimensions(width: width, height: height);

          await windowManager.setTitle('BlueBubbles');
          if (arguments.firstOrNull != "minimized") {
            await windowManager.show();
          } else {
            await windowManager.hide();
          }
          try {
            await const MethodChannel('bluebubbles/splash').invokeMethod('closeSplash');
          } catch (_) {}
          detachSplashStatus?.call();
          unawaited(ThemeSvc.initDynamicColorsDeferred()); // Linux: deferred past splash
          bool shouldAuthenticate =
              !Platform.isLinux && SettingsSvc.canAuthenticate && SettingsSvc.settings.shouldSecure.value;
          if (!shouldAuthenticate) {
            ChatsSvc.init();
            SocketSvc.init();
          }
        });

        await dotenv.load();
      }

      /* ----- EMOJI FONT INITIALIZATION ----- */
      Future.microtask(() => FilesystemSvc.checkFont());
    } catch (e, s) {
      print(s.toString());
      if (GetIt.I.isRegistered<BaseLogger>()) {
        Logger.error("Failure during app initialization!", error: e, trace: s);
      }
      exception = e;
      stacktrace = s;
    }

    if (exception == null) {
      /* ----- THEME INITIALIZATION ----- */
      ThemeData light = ThemeStruct.getLightTheme().data;
      ThemeData dark = ThemeStruct.getDarkTheme().data;

      final pair = ThemeSvc.getStructsFromData(light, dark);
      light = pair.light;
      dark = pair.dark;

      runApp(MaterialApp(
          onNavigationNotification: (_) => true,
          home: Main(
        lightTheme: light,
        darkTheme: dark,
        savedThemeMode: await AdaptiveTheme.getThemeMode(),
      )));
    } else {
      runApp(FailureToStart(e: exception, s: stacktrace));
      throw Exception("$exception $stacktrace");
    }
}

bool get isWaylandSession =>
    Platform.isLinux &&
    (Platform.environment['XDG_SESSION_TYPE'] == 'wayland' || Platform.environment.containsKey('WAYLAND_DISPLAY'));

class DesktopWindowListener extends WindowListener {
  DesktopWindowListener._();

  static final DesktopWindowListener instance = DesktopWindowListener._();

  @override
  void onWindowFocus() {
    if (_desktopWindowHidden) {
      updateSystemTrayToggle(windowHidden: false);
    }
    _desktopWindowMinimized = false;
    _updateDesktopTickerInactive();
    LifecycleSvc.windowFocused = true;
    LifecycleSvc.open();
  }

  @override
  void onWindowBlur() {
    LifecycleSvc.close();
  }

  // A drag fires these dozens of times a second; only the final geometry needs saving.
  @override
  void onWindowResized() {
    EasyDebounce.debounce('save-window-size', const Duration(milliseconds: 500), () async {
      Size size = await windowManager.getSize();
      await PrefsSvc.desktop.setWindowDimensions(width: size.width, height: size.height);
    });
  }

  @override
  void onWindowMoved() {
    EasyDebounce.debounce('save-window-position', const Duration(milliseconds: 500), () async {
      Offset offset = await windowManager.getPosition();
      await PrefsSvc.desktop.setWindowOffsets(x: offset.dx, y: offset.dy);
    });
  }

  @override
  void onWindowEvent(String eventName) async {
    switch (eventName) {
      case "hide":
        updateSystemTrayToggle(windowHidden: true);
        break;
      case "show":
        updateSystemTrayToggle(windowHidden: false);
        break;
      case "minimize":
        _desktopWindowMinimized = true;
        _updateDesktopTickerInactive();
        break;
      case "restore":
        _desktopWindowMinimized = false;
        _updateDesktopTickerInactive();
        break;
    }
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    } else if (Platform.isLinux) {
      exit(0);
    }
  }
}

class _WebTabBlockedApp extends StatelessWidget {
  const _WebTabBlockedApp({required this.onUseHere});

  final Future<void> Function() onUseHere;

  @override
  Widget build(BuildContext context) {
    final brightness = PlatformDispatcher.instance.platformBrightness;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BlueBubbles',
      theme: ThemeData(
        fontFamily: kDefaultAppFontFamily,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        fontFamily: kDefaultAppFontFamily,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: _WebTabBlockedView(onUseHere: onUseHere),
    );
  }
}

class _WebTabBlockedView extends StatefulWidget {
  const _WebTabBlockedView({required this.onUseHere});

  final Future<void> Function() onUseHere;

  @override
  State<_WebTabBlockedView> createState() => _WebTabBlockedViewState();
}

class _WebTabBlockedViewState extends State<_WebTabBlockedView> {
  bool _switching = false;

  Future<void> _handleUseHere() async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      await widget.onUseHere();
    } catch (_) {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.tab_rounded,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'BlueBubbles is open in another tab',
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Only one tab can access the local message database at a time to keep your messages in sync.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _switching ? null : _handleUseHere,
                      child: _switching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Use here'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Main extends StatefulWidget {
  final ThemeData darkTheme;
  final ThemeData lightTheme;
  final AdaptiveThemeMode? savedThemeMode;

  const Main({super.key, required this.lightTheme, required this.darkTheme, this.savedThemeMode});

  @override
  State<Main> createState() => _MainState();
}

class _MainState extends State<Main> {
  bool _webHidden = kIsWeb && isWebDocumentHidden;
  VoidCallback? _disposeWebLifecycle;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _disposeWebLifecycle = listenWebLifecycle(
        onVisibilityChange: (hidden) {
          if (mounted && _webHidden != hidden) {
            setState(() => _webHidden = hidden);
          }
        },
        onOnlineChange: (_) {},
      );
    }
  }

  @override
  void dispose() {
    _disposeWebLifecycle?.call();
    super.dispose();
  }

  Widget _withBackAction(BuildContext context, Widget? navigator) =>
      Actions(actions: {GoBackIntent: GoBackAction(context)}, child: navigator ?? Container());

  @override
  Widget build(BuildContext context) {
    const appPageTransitionsTheme = PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    );
    return ValueListenableBuilder<bool>(
      valueListenable: _desktopWindowHiddenNotifier,
      builder: (context, desktopHidden, child) => TickerMode(
        enabled: !(desktopHidden || _webHidden),
        child: child!,
      ),
      child: AdaptiveTheme(
        light: widget.lightTheme.copyWith(
            textSelectionTheme: TextSelectionThemeData(selectionColor: widget.lightTheme.colorScheme.primary)),
        dark: widget.darkTheme
            .copyWith(textSelectionTheme: TextSelectionThemeData(selectionColor: widget.darkTheme.colorScheme.primary)),
        initial: widget.savedThemeMode ?? AdaptiveThemeMode.system,
        builder: (theme, darkTheme) => GetMaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'BlueBubbles',
        theme: theme.withEmojiFallback.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(elevation: 0.0),
          pageTransitionsTheme: appPageTransitionsTheme,
          dialogTheme: DialogThemeData(
            barrierColor: theme.colorScheme.shadow.withValues(alpha: 0.6),
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          bottomSheetTheme: BottomSheetThemeData(
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            modalBackgroundColor: theme.colorScheme.surfaceContainerHigh,
            modalBarrierColor: theme.colorScheme.shadow.withValues(alpha: 0.45),
            surfaceTintColor: Colors.transparent,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
        ),
        darkTheme: darkTheme.withEmojiFallback.copyWith(
          appBarTheme: darkTheme.appBarTheme.copyWith(elevation: 0.0),
          pageTransitionsTheme: appPageTransitionsTheme,
          dialogTheme: DialogThemeData(
            barrierColor: darkTheme.colorScheme.shadow.withValues(alpha: 0.6),
            backgroundColor: darkTheme.colorScheme.surfaceContainerHighest,
          ),
          bottomSheetTheme: BottomSheetThemeData(
            backgroundColor: darkTheme.colorScheme.surfaceContainerHigh,
            modalBackgroundColor: darkTheme.colorScheme.surfaceContainerHigh,
            modalBarrierColor: darkTheme.colorScheme.shadow.withValues(alpha: 0.45),
            surfaceTintColor: Colors.transparent,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
          ),
        ),
        navigatorKey: NavigationSvc.key,
        navigatorObservers: [NavigationSvc.sectionObserver],
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          // Specifically for GNU/Linux, Android-x86, and Web so mouse/touch/trackpad drag all work consistently.
          dragDevices:
              kIsWeb || Platform.isLinux || Platform.isAndroid ? PointerDeviceKind.values.toSet() : null,
          // Prevent scrolling with multiple fingers accelerating the scrolling
          multitouchDragStrategy: MultitouchDragStrategy.latestPointer,
        ),
        home: const Home(),
        shortcuts: {
          if (!kIsWeb) LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma): const OpenSettingsIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.comma): const OpenSettingsIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.comma): const OpenSettingsIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyN): const OpenNewChatCreatorIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK): const OpenNewChatCreatorIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyK): const OpenNewChatCreatorIntent(),
          if (kIsDesktop || kIsWeb)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyN): const OpenNewChatCreatorIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyN): const OpenNewChatCreatorIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF): const OpenSearchIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF): const OpenSearchIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyF): const OpenSearchIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyR): const ReplyRecentIntent(),
          if (kIsDesktop) LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyR): const ReplyRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowDown): const OpenNextChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowDown): const OpenNextChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.period): const OpenNextChatIntent(),
          if (kIsDesktop || kIsWeb)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.tab): const OpenNextChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowUp): const OpenPreviousChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowUp): const OpenPreviousChatIntent(),
          if (kIsWeb)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma): const OpenPreviousChatIntent(),
          if (kIsDesktop || kIsWeb)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.tab):
                const OpenPreviousChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.slash): const ShowKeyboardShortcutsIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.slash): const ShowKeyboardShortcutsIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyI): const ToggleInspectorIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape): const GoBackIntent(),
        },
        // Above the navigator so back reaches pages pushed over Home; GetMaterialApp ignores its actions parameter
        builder: (context, navigator) => SafeArea(
          top: false,
          bottom: false,
          // secure_application has no Linux implementation; mounting it (and the
          // SecureGate below) throws MissingPluginException on every lifecycle
          // event, which breaks window close/hide once the app is past setup.
          // Bypass the secure wrapper entirely on Linux.
          child: (kIsWeb || Platform.isLinux)
              ? ValueListenableBuilder<bool>(
                  valueListenable: WebTabLock.instance.blockedListenable,
                  builder: (context, blocked, child) {
                    if (kIsWeb && blocked) {
                      return _WebTabBlockedView(
                        onUseHere: () async {
                          await WebTabLock.instance.takeOver();
                          WebTabLock.instance.reloadPage();
                        },
                      );
                    }
                    return child!;
                  },
                  child: TitleBarWrapper(
                    child: AppShellFrame(
                      navigator: _withBackAction(context, navigator),
                    ),
                  ),
                )
              : SecureApplication(
                  child: Builder(
                    builder: (context) {
                      if (SettingsSvc.canAuthenticate && (!LifecycleSvc.isAlive || !StartupTasks.uiReady.isCompleted)) {
                        if (SettingsSvc.settings.shouldSecure.value) {
                          SecureApplicationProvider.of(context, listen: false)!.lock();
                          if (SettingsSvc.settings.securityLevel.value == SecurityLevel.locked_and_secured) {
                            SecureApplicationProvider.of(context, listen: false)!.secure();
                          }
                        }
                      }
                      return TitleBarWrapper(
                        child: SecureGate(
                          blurr: 5,
                          opacity: 0,
                          lockedBuilder: (context, controller) {
                            final localAuth = LocalAuthentication();
                            if (!isAuthing) {
                              isAuthing = true;
                              try {
                                localAuth
                                    .authenticate(
                                  localizedReason: 'Please authenticate to unlock BlueBubbles',
                                  persistAcrossBackgrounding: true,
                                )
                                    .then((result) {
                                  if (result) {
                                    if (!context.mounted) return;
                                    SecureApplicationProvider.of(context, listen: false)?.authSuccess(unlock: true);
                                    if (kIsDesktop) {
                                      Future.delayed(Duration.zero, () {
                                        ChatsSvc.init();
                                        SocketSvc.init();
                                      });
                                    }
                                  }
                                }).catchError((e, s) {
                                  Logger.warn("Biometric authentication failed", error: e, trace: s);
                                }).whenComplete(() {
                                  isAuthing = false;
                                });
                              } catch (e, s) {
                                isAuthing = false;
                                Logger.warn("Biometric authentication threw", error: e, trace: s);
                              }
                            }
                            return Container(
                              color: context.theme.colorScheme.surface,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 20.0),
                                      child: Text(
                                        "BlueBubbles is currently locked. Please unlock to access your messages.",
                                        style: context.theme.textTheme.titleLarge,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    Container(height: 20.0),
                                    ClipOval(
                                      child: Material(
                                        color: context.theme.colorScheme.primary, // button color
                                        child: InkWell(
                                          child: SizedBox(
                                              width: 60,
                                              height: 60,
                                              child: Icon(Icons.lock_open, color: context.theme.colorScheme.onPrimary)),
                                          onTap: () async {
                                            if (isAuthing) return;
                                            isAuthing = true;
                                            try {
                                              final localAuth = LocalAuthentication();
                                              bool didAuthenticate = await localAuth.authenticate(
                                                localizedReason: 'Please authenticate to unlock BlueBubbles',
                                                persistAcrossBackgrounding: true,
                                              );
                                              if (didAuthenticate) {
                                                controller?.authSuccess(unlock: true);
                                                if (kIsDesktop) {
                                                  Future.delayed(Duration.zero, () {
                                                    ChatsSvc.init();
                                                    SocketSvc.init();
                                                  });
                                                }
                                              }
                                            } catch (e, s) {
                                              Logger.warn("Biometric authentication failed", error: e, trace: s);
                                            } finally {
                                              isAuthing = false;
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                          child: AppShellFrame(
                            navigator: _withBackAction(context, navigator),
                          ),
                        ),
                      );
                    },
                  ),
                ),
          ),
        defaultTransition: Transition.cupertino,
      ),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  bool serverCompatible = true;
  bool fullyLoaded = false;
  Worker? _chatUrlWorker;
  Worker? _settingsUrlWorker;
  Worker? _webBadgeWorker;
  Worker? _setupFinishedWorker;
  Worker? _windowsUnreadWorker;
  StreamSubscription? _refreshAllSub;
  StreamSubscription? _themeUpdateSub;
  StreamSubscription<int>? _linuxUnreadSub;
  bool _webPostSetupInitialized = false;
  bool _syncingFromUrl = false;
  bool _handledShareTarget = false;
  String? _lastPushedHashPath;
  String? _pendingWebHashRoute;
  Worker? _pendingHashRouteWorker;

  void _pushWebHashRoute({bool replace = false}) => _lastPushedHashPath = pushWebHashRoute(
        syncingFromUrl: _syncingFromUrl,
        lastPushedHashPath: _lastPushedHashPath,
        replace: replace,
      );

  Future<void> _applyWebHashRoute(String rawLocation) async {
    if (!kIsWeb || !mounted || !SettingsSvc.settings.finishedSetup.value) return;
    final navContext = NavigationSvc.key.currentContext ?? context;
    final target = parseWebHashRoute(rawLocation);
    if (target.kind == WebHashRouteKind.chat && !ChatsSvc.loadedFirstChatBatch.value) {
      _pendingWebHashRoute = rawLocation;
      _pendingHashRouteWorker?.dispose();
      _pendingHashRouteWorker = ever(ChatsSvc.loadedFirstChatBatch, (loaded) {
        if (!loaded) return;
        _pendingHashRouteWorker?.dispose();
        _pendingHashRouteWorker = null;
        if (!mounted || _pendingWebHashRoute != rawLocation) return;
        _pendingWebHashRoute = null;
        unawaited(_applyWebHashRoute(rawLocation));
      });
      return;
    }
    _pendingWebHashRoute = null;
    _syncingFromUrl = true;
    try {
      switch (target.kind) {
        case WebHashRouteKind.settings:
          _lastPushedHashPath = '/settings';
          if (!NavigationSvc.isSettingsOpen.value) {
            NavigationSvc.closeAllConversationView(navContext);
            await ChatsSvc.setAllInactive();
            if (!mounted || !navContext.mounted) return;
            NavigationSvc.openSettings();
          }
          break;
        case WebHashRouteKind.chat:
          final guid = target.chatGuid!;
          _lastPushedHashPath = '/chat/${Uri.encodeComponent(guid)}';
          if (NavigationSvc.isSettingsOpen.value) {
            NavigationSvc.closeSections();
          }
          if (ChatsSvc.activeChatGuid.value != guid) {
            final chat =
                ChatsSvc.allChats.firstWhereOrNull((c) => c.guid == guid) ?? await Chat.findOneWeb(guid: guid);
            if (chat != null && mounted && navContext.mounted) {
              await NavigationSvc.pushAndRemoveUntil(
                navContext,
                ConversationView(chat: chat),
                (route) => route.isFirst,
              );
            }
          }
          break;
        case WebHashRouteKind.home:
          _lastPushedHashPath = '/';
          if (NavigationSvc.isSettingsOpen.value) {
            NavigationSvc.closeSections();
          }
          if (ChatsSvc.activeChat != null && mounted) {
            NavigationSvc.closeAllConversationView(navContext);
            await ChatsSvc.setAllInactive();
          }
          break;
      }
    } finally {
      _syncingFromUrl = false;
    }
  }

  @override
  void initState() {
    super.initState();

    // Bind the lifecycle events
    WidgetsBinding.instance.addObserver(this);

    /* ----- APP REFRESH LISTENER INITIALIZATION ----- */
    _refreshAllSub = EventDispatcherSvc.stream.listen((event) {
      if (event.type == 'refresh-all' && mounted) {
        setState(() {});
      }
    });

    SchedulerBinding.instance.addPostFrameCallback((_) async {
      if (!StartupTasks.uiReady.isCompleted) {
        StartupTasks.uiReady.complete();
      }

      if (!LifecycleSvc.isBubble && !kIsWeb && !kIsDesktop) {
        LifecycleSvc.createFakePort();
      }

      ErrorWidget.builder = (FlutterErrorDetails error) {
        Logger.error("An unexpected error occurred when rendering.", error: error.exception, trace: error.stack);
        return CustomErrorWidget(
          "An unexpected error occurred when rendering.",
        );
      };
      /* ----- SERVER VERSION CHECK ----- */
      if (kIsWeb) {
        if (SettingsSvc.settings.finishedSetup.value) {
          _initWebPostSetup();
        } else {
          _setupFinishedWorker ??= ever<bool>(SettingsSvc.settings.finishedSetup, (finished) {
            if (finished && mounted) {
              _setupFinishedWorker?.dispose();
              _setupFinishedWorker = null;
              _initWebPostSetup();
            }
          });
        }
      }

      if (kIsDesktop) {
        if (Platform.isLinux) {
          /* ----- BADGE ICON LISTENER ----- */
          Future<void> updateBadge(int count) =>
              LinuxLauncherBadge.update(SettingsSvc.settings.windowsTaskbarBadge.value ? count : 0);

          unawaited(updateBadge(ChatsSvc.unreadCount.value));
          _linuxUnreadSub = ChatsSvc.unreadCount.listen(updateBadge);
        }

        if (Platform.isWindows) {
          /* ----- CONTACT IMAGE CACHE DELETION ----- */
          Directory temp = FilesystemSvc.appTemp;
          if (await temp.exists()) await temp.delete(recursive: true);

          /* ----- BADGE ICON LISTENER ----- */
          Future<void> updateBadge(int count) async {
            try {
              if (count == 0 || !SettingsSvc.settings.windowsTaskbarBadge.value) {
                await WindowsTaskbar.resetOverlayIcon();
              } else if (count <= 9) {
                await WindowsTaskbar.setOverlayIcon(ThumbnailToolbarAssetIcon('assets/badges/badge-$count.ico'));
              } else {
                await WindowsTaskbar.setOverlayIcon(ThumbnailToolbarAssetIcon('assets/badges/badge-10.ico'));
              }
            } catch (_) {}
          }

          unawaited(updateBadge(ChatsSvc.unreadCount.value));
          // Each update is a shell COM call on the platform thread; syncs and mark-all-read change the count in bursts.
          _windowsUnreadWorker = debounce<int>(ChatsSvc.unreadCount, updateBadge, time: const Duration(milliseconds: 250));

          /* ----- WINDOW EFFECT INITIALIZATION ----- */
          _themeUpdateSub = EventDispatcherSvc.stream.listen((event) async {
            if (event.type == 'theme-update') {
              EasyDebounce.debounce('window-effect', const Duration(milliseconds: 500), () async {
                if (mounted) {
                  await WindowEffects.setEffect(color: context.theme.colorScheme.surface);
                }
              });
            }
          });

          Future(() => EventDispatcherSvc.emit("theme-update", null));
        }

        /* ----- SYSTEM TRAY INITIALIZATION ----- */
        initSystemTray();
      }

      if (!mounted) return;
      if (!SettingsSvc.settings.finishedSetup.value) {
        setState(() {
          fullyLoaded = true;
        });
      } else {
        if ((FilesystemSvc.androidInfo?.version.sdkInt ?? 0) >= 33) {
          Permission.notification.request();
        }
      }
    });
  }

  void _initWebPostSetup() {
    if (_webPostSetupInitialized || !kIsWeb || !mounted) return;
    _webPostSetupInitialized = true;
    final serverDetails = SettingsSvc.getServerDetails();
    if (!serverDetails.minimumWebSupportedVersion) {
      setState(() {
        serverCompatible = false;
      });
    }

    /* ----- CTRL-F & CONTEXT MENU OVERRIDE ----- */
    suppressBrowserFindShortcut();
    suppressBrowserContextMenu();

    /* ----- HASH URL SYNC ----- */
    _chatUrlWorker ??= ever(ChatsSvc.activeChatGuid, (_) => _pushWebHashRoute());
    _settingsUrlWorker ??= ever(NavigationSvc.isSettingsOpen, (_) => _pushWebHashRoute());
    updateWebTitleAndBadge(ChatsSvc.unreadCount.value);
    _webBadgeWorker ??= ever<int>(ChatsSvc.unreadCount, updateWebTitleAndBadge);

    // Handle PWA share_target (title/text/url) without touching setup/auth params.
    final qp = Uri.base.queryParameters;
    final sharedText = [qp['title'], qp['text'], qp['url']]
        .where((v) => v != null && v.trim().isNotEmpty)
        .map((v) => v!.trim())
        .join('\n');
    if (sharedText.isNotEmpty && !_handledShareTarget && SettingsSvc.settings.finishedSetup.value) {
      _handledShareTarget = true;
      unawaited(ChatsSvc.loadedAllChats.future.then((_) {
        if (!mounted) return;
        final navContext = NavigationSvc.key.currentContext ?? context;
        if (!navContext.mounted) return;
        NavigationSvc.pushAndRemoveUntil(
          navContext,
          NewChatCreator(initialText: sharedText),
          (route) => route.isFirst,
        );
      }));
    }

    final initialFragment = Uri.base.fragment;
    if (initialFragment.isNotEmpty) {
      unawaited(ChatsSvc.loadedAllChats.future.then((_) async {
        if (!mounted) return;
        await _applyWebHashRoute(initialFragment);
      }));
    } else if (ChatsSvc.activeChatGuid.value != null) {
      _pushWebHashRoute(replace: true);
    }
  }

  @override
  void dispose() {
    _refreshAllSub?.cancel();
    _themeUpdateSub?.cancel();
    _linuxUnreadSub?.cancel();
    _windowsUnreadWorker?.dispose();
    _chatUrlWorker?.dispose();
    _settingsUrlWorker?.dispose();
    _webBadgeWorker?.dispose();
    _setupFinishedWorker?.dispose();
    _pendingHashRouteWorker?.dispose();
    // Clean up observer when app is fully closed
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(DesktopWindowListener.instance);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    if (kIsWeb && SettingsSvc.settings.finishedSetup.value) {
      await _applyWebHashRoute(routeInformation.uri.toString());
      return true;
    }
    return super.didPushRouteInformation(routeInformation);
  }

  /// Just in case the theme doesn't change automatically
  /// Workaround for adaptive_theme issue #32
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (AdaptiveTheme.maybeOf(context)?.mode == AdaptiveThemeMode.system) {
      if (AdaptiveTheme.maybeOf(context)?.brightness == Brightness.light) {
        AdaptiveTheme.maybeOf(context)?.setLight();
      } else {
        AdaptiveTheme.maybeOf(context)?.setDark();
      }
      AdaptiveTheme.maybeOf(context)?.setSystem();

      EventDispatcherSvc.emit("theme-update", null);
    }
  }

  /// Render
  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        OpenSettingsIntent: OpenSettingsAction(context),
        OpenNewChatCreatorIntent: OpenNewChatCreatorAction(context),
        OpenSearchIntent: OpenSearchAction(context),
        OpenNextChatIntent: OpenNextChatAction(context),
        OpenPreviousChatIntent: OpenPreviousChatAction(context),
        ReplyRecentIntent: CallbackAction<ReplyRecentIntent>(
          onInvoke: (intent) {
            final guid = ChatsSvc.activeChatGuid.value;
            if (guid != null && SettingsSvc.settings.enablePrivateAPI.value) {
              return ReplyRecentAction(guid).invoke(intent);
            }
            return null;
          },
        ),
        ShowKeyboardShortcutsIntent: CallbackAction<ShowKeyboardShortcutsIntent>(
          onInvoke: (_) {
            showKeyboardShortcutsDialog(context);
            return null;
          },
        ),
        ToggleInspectorIntent: CallbackAction<ToggleInspectorIntent>(
          onInvoke: (_) {
            NavigationSvc.toggleInspectorDrawer();
            return null;
          },
        ),
        GoBackIntent: GoBackAction(context),
      },
      child: Obx(() {
        final showChatList =
            SettingsSvc.settings.finishedSetup.value && !Get.isRegistered<SetupViewController>();
        return BBScaffold(
            backgroundColor: context.theme.colorScheme.surface.themeOpacity(context),
            resizeToAvoidBottomInset: !showChatList,
            safeAreaBottom: showChatList ? false : null,
            body: Builder(
              builder: (BuildContext context) {
                if (showChatList) {
                  if (!serverCompatible && kIsWeb) {
                    return const FailureToStart(
                      otherTitle: "Server version too low, please upgrade!",
                      e: "Required Server Version: v0.2.0",
                    );
                  }
                  return ConversationList(
                    showArchivedChats: false,
                    showUnknownSenders: false,
                  );
                } else {
                  return PopScope(
                    canPop: false,
                    child: kIsWeb || kIsDesktop ? const SetupView() : SplashScreen(shouldNavigate: fullyLoaded),
                  );
                }
              },
            ),
          );
      }),
    );
  }
}

// Kept for the app's lifetime: a garbage-collected TrayIcon removes the icon, and a collected MenuItem drops its
// click listener.
final List<Object> _trayHandles = [];
MenuItem? _trayToggleItem;
bool _trayWindowHidden = false;
bool _desktopWindowHidden = false;
bool _desktopWindowMinimized = false;
final ValueNotifier<bool> _desktopWindowHiddenNotifier = ValueNotifier<bool>(false);

void _updateDesktopTickerInactive() {
  final inactive = _desktopWindowHidden || _desktopWindowMinimized;
  if (_desktopWindowHiddenNotifier.value != inactive) {
    _desktopWindowHiddenNotifier.value = inactive;
  }
}

void initSystemTray() {
  // Each call creates another icon, so a second one (Home's state rebuilt) would show two. Set only on success, so a
  // failed attempt can be retried.
  if (_trayToggleItem != null) return;

  final trayIcon = TrayIcon.create();
  final menu = Menu.create();
  final toggleItem = MenuItem.createWithLabelAndType('Hide App', MenuItemType.normal);
  final closeItem = MenuItem.createWithLabelAndType('Close App', MenuItemType.normal);
  if (trayIcon == null || menu == null || toggleItem == null || closeItem == null) {
    Logger.error("Failed to create the system tray icon", tag: "SystemTray");
    return;
  }

  // The icon reaches the panel as pixel data, so a path inside the flatpak or snap sandbox works.
  trayIcon.icon = ImageAsset.fromAsset(Platform.isWindows ? 'assets/icon/icon.ico' : 'assets/icon/icon.png');
  trayIcon.setTooltip("BlueBubbles");
  trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
  trayIcon.addListener((event) async {
    if (event is TrayIconClickedEvent) await showAndFocusWindow();
  });

  toggleItem.addListener((event) async {
    if (event is! MenuItemClickedEvent) return;
    if (_trayWindowHidden) {
      await showAndFocusWindow();
    } else {
      await windowManager.hide();
    }
  });
  closeItem.addListener((event) async {
    if (event is! MenuItemClickedEvent) return;
    if (Platform.isLinux) exit(0);
    await windowManager.setPreventClose(false);
    await windowManager.close();
  });

  menu
    ..addItem(toggleItem)
    ..addSeparator()
    ..addItem(closeItem);
  trayIcon.setContextMenu(menu);
  trayIcon.setVisible(true);

  _trayHandles.addAll([trayIcon, menu, closeItem]);
  _trayToggleItem = toggleItem;
  updateSystemTrayToggle(windowHidden: !appWindow.isVisible);
}

void updateSystemTrayToggle({required bool windowHidden}) {
  _trayWindowHidden = windowHidden;
  _desktopWindowHidden = windowHidden;
  if (!windowHidden) {
    _desktopWindowMinimized = false;
  }
  _updateDesktopTickerInactive();
  _trayToggleItem?.label = windowHidden ? 'Show App' : 'Hide App';
}

/// Layout-integrated app-shell frame that places active call bars, sync error
/// strips, and top notices in a `Column` above [navigator] (absorbing status-bar
/// `SafeArea` padding and removing it from [navigator] so app bars below never
/// double-pad or get overlapped), while keeping the 2px syncing hairline and
/// wide-desktop bottom-left info/success toast non-blocking.
class AppShellFrame extends StatelessWidget {
  final Widget navigator;
  final ActiveCallController? callController;
  final SyncStatusSnapshot? syncStatusOverride;
  final bool? showSyncIndicatorOverride;

  const AppShellFrame({
    super.key,
    required this.navigator,
    this.callController,
    this.syncStatusOverride,
    this.showSyncIndicatorOverride,
  });

  @override
  Widget build(BuildContext context) {
    final activeCall = callController ?? ActiveCallController.instance;

    Widget buildWithSync(SyncStatusSnapshot syncSnapshot, bool allowSyncIndicator) {
      return ListenableBuilder(
        listenable: activeCall,
        builder: (context, _) {
          return ValueListenableBuilder<AppNoticeData?>(
            valueListenable: AppNoticeController.instance.current,
            builder: (context, notice, _) {
              final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
              final viewportWidth = MediaQuery.sizeOf(context).width;
              final hasCallBanner = activeCall.state.phase != ActiveCallPhase.idle;
              final hasSyncFailedBanner = GlobalSyncStatusOverlay.hasBannerFor(syncSnapshot);
              final hasTopNoticeBanner = appNoticeUsesTopSlot(notice, viewportWidth);
              final hasCornerToast = notice != null && !hasTopNoticeBanner;
              final hasTopBanner = hasCallBanner || hasSyncFailedBanner || hasTopNoticeBanner;
              final showSyncingHairline = !hasSyncFailedBanner && syncSnapshot.showSyncing && allowSyncIndicator;
              final hasWindowEffect = GetIt.I.isRegistered<SettingsService>() &&
                  SettingsSvc.settings.windowEffect.value != WindowEffect.disabled;

              return Stack(
                fit: StackFit.expand,
                children: [
                  if (hasTopBanner && !hasWindowEffect)
                    Positioned.fill(
                      child: ColoredBox(color: Theme.of(context).colorScheme.surface),
                    ),
                  Column(
                    key: const ValueKey('shell-body'),
                    children: [
                      AnimatedSize(
                        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: hasTopBanner
                            ? Material(
                                type: MaterialType.transparency,
                                child: SafeArea(
                                  bottom: false,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (hasCallBanner) OngoingCallPillOverlay(controller: activeCall),
                                      if (hasSyncFailedBanner)
                                        GlobalSyncStatusOverlay(
                                          statusOverride: syncStatusOverride,
                                          showSyncIndicatorOverride: showSyncIndicatorOverride,
                                        ),
                                      if (hasTopNoticeBanner && notice != null)
                                        AppNoticeTopBar(
                                          notice: notice,
                                          onDismiss: () => AppNoticeController.instance.dismiss(explicit: true),
                                        ),
                                    ],
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity, height: 0),
                      ),
                      Expanded(
                        // Isolate route-level BlockSemantics inside Navigator so shell banners stay accessible.
                        child: Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: MediaQuery.removePadding(
                            context: context,
                            removeTop: hasTopBanner,
                            child: navigator,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (showSyncingHairline)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        bottom: false,
                        child: GlobalSyncStatusOverlay(
                          statusOverride: syncStatusOverride,
                          showSyncIndicatorOverride: showSyncIndicatorOverride,
                        ),
                      ),
                    ),
                  if (hasCornerToast)
                    Positioned(
                      left: 16,
                      bottom: 16,
                      child: SafeArea(
                        top: false,
                        right: false,
                        child: AppNoticeCornerToast(
                          notice: notice,
                          onDismiss: () => AppNoticeController.instance.dismiss(explicit: true),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      );
    }

    Widget content;
    if (syncStatusOverride != null) {
      content = buildWithSync(syncStatusOverride!, showSyncIndicatorOverride ?? true);
    } else if (GetIt.I.isRegistered<SyncService>()) {
      content = Obx(() {
        final finishedSetup =
            !GetIt.I.isRegistered<SettingsService>() || SettingsSvc.settings.finishedSetup.value;
        final snapshot = finishedSetup ? SyncSvc.status.value : SyncStatusSnapshot.idle;
        final allowSync = showSyncIndicatorOverride ??
            (!GetIt.I.isRegistered<SettingsService>() || SettingsSvc.settings.showSyncIndicator.value);
        return buildWithSync(snapshot, allowSync);
      });
    } else {
      content = buildWithSync(SyncStatusSnapshot.idle, showSyncIndicatorOverride ?? true);
    }

    return Overlay.wrap(
      child: AppNoticeHost(child: content),
    );
  }
}

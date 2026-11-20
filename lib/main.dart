import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:async_task/async_task_extension.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/components/custom/custom_error_box.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
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
import 'package:bluebubbles/utils/window_effects.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/settings/settings_page.dart';
import 'package:bluebubbles/app/layouts/startup/failure_to_start.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/layouts/startup/splash_screen.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
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

    await StartupTasks.initStartupServices(isBubble: bubble);

    /* ----- RANDOM STUFF INITIALIZATION ----- */
    if (!kIsWeb) {
      HttpOverrides.global = CustomHttpContext();
    }
    dynamic exception;
    StackTrace? stacktrace;

    FlutterError.onError = (details) {
      Logger.error("Rendering Error: ${details.exceptionAsString()}", error: details.exception, trace: details.stack);
    };

    try {
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
      Logger.error("Failure during app initialization!", error: e, trace: s);
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
  }, (dynamic error, StackTrace stackTrace) {
    print("Failure during app initialization: $error");
    print(stackTrace);
    Logger.error("Unhandled Exception", trace: stackTrace, error: error);
  });
}

bool get isWaylandSession =>
    Platform.isLinux &&
    (Platform.environment['XDG_SESSION_TYPE'] == 'wayland' || Platform.environment.containsKey('WAYLAND_DISPLAY'));

class DesktopWindowListener extends WindowListener {
  DesktopWindowListener._();

  static final DesktopWindowListener instance = DesktopWindowListener._();

  @override
  void onWindowFocus() {
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

class Main extends StatelessWidget {
  final ThemeData darkTheme;
  final ThemeData lightTheme;
  final AdaptiveThemeMode? savedThemeMode;

  const Main({super.key, required this.lightTheme, required this.darkTheme, this.savedThemeMode});

  @override
  Widget build(BuildContext context) {
    return AdaptiveTheme(
      light: lightTheme.copyWith(
          textSelectionTheme: TextSelectionThemeData(selectionColor: lightTheme.colorScheme.primary)),
      dark:
          darkTheme.copyWith(textSelectionTheme: TextSelectionThemeData(selectionColor: darkTheme.colorScheme.primary)),
      initial: savedThemeMode ?? AdaptiveThemeMode.system,
      builder: (theme, darkTheme) => GetMaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'BlueBubbles',
        theme: theme.withEmojiFallback.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(elevation: 0.0),
          dialogTheme: DialogThemeData(
            barrierColor: theme.colorScheme.shadow.withValues(alpha: 0.6),
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        darkTheme: darkTheme.withEmojiFallback.copyWith(
          appBarTheme: darkTheme.appBarTheme.copyWith(elevation: 0.0),
          dialogTheme: DialogThemeData(
            barrierColor: darkTheme.colorScheme.shadow.withValues(alpha: 0.6),
            backgroundColor: darkTheme.colorScheme.surfaceContainerHighest,
          ),
        ),
        navigatorKey: NavigationSvc.key,
        navigatorObservers: [routeObserver],
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
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.slash): const _ShowKeyboardShortcutsIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.slash): const _ShowKeyboardShortcutsIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyI): const ToggleInspectorIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape): const GoBackIntent(),
        },
        // A route only reports its own pop state, so a pushed page could tell Android nothing handles back and the
        // gesture left the app. Back always goes through Flutter instead, which still exits when nothing can pop.
        builder: (context, child) => NotificationListener<NavigationNotification>(
          onNotification: (notification) {
            if (notification.canHandlePop) return false;
            const NavigationNotification(canHandlePop: true).dispatch(context);
            return true;
          },
          child: SafeArea(
          top: false,
          bottom: false,
          // secure_application has no Linux implementation; mounting it (and the
          // SecureGate below) throws MissingPluginException on every lifecycle
          // event, which breaks window close/hide once the app is past setup.
          // Bypass the secure wrapper entirely on Linux.
          child: (kIsWeb || Platform.isLinux)
              ? TitleBarWrapper(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      child ?? Container(),
                      const OngoingCallPillOverlay(),
                    ],
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
                              localAuth
                                  .authenticate(
                                localizedReason: 'Please authenticate to unlock BlueBubbles',
                                persistAcrossBackgrounding: true,
                              )
                                  .then((result) {
                                isAuthing = false;
                                if (result) {
                                  if (!context.mounted) return;
                                  SecureApplicationProvider.of(context, listen: false)!.authSuccess(unlock: true);
                                  if (kIsDesktop) {
                                    Future.delayed(Duration.zero, () {
                                      ChatsSvc.init();
                                      SocketSvc.init();
                                    });
                                  }
                                }
                              });
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
                                            final localAuth = LocalAuthentication();
                                            bool didAuthenticate = await localAuth.authenticate(
                                              localizedReason: 'Please authenticate to unlock BlueBubbles',
                                              persistAcrossBackgrounding: true,
                                            );
                                            if (didAuthenticate) {
                                              controller!.authSuccess(unlock: true);
                                              if (kIsDesktop) {
                                                Future.delayed(Duration.zero, () {
                                                  ChatsSvc.init();
                                                  SocketSvc.init();
                                                });
                                              }
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
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              child ?? Container(),
                              const OngoingCallPillOverlay(),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
          ),
        ),
        defaultTransition: Transition.cupertino,
      ),
    );
  }
}

class ToggleInspectorIntent extends Intent {
  const ToggleInspectorIntent();
}

class _ShowKeyboardShortcutsIntent extends Intent {
  const _ShowKeyboardShortcutsIntent();
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
  bool _syncingFromUrl = false;
  bool _handledShareTarget = false;
  String? _lastPushedHashPath;

  void _pushWebHashRoute({bool replace = false}) {
    if (!kIsWeb || _syncingFromUrl || !SettingsSvc.settings.finishedSetup.value) return;
    final uri = buildWebHashRouteUri(
      settingsOpen: NavigationSvc.isSettingsOpen.value,
      activeChatGuid: ChatsSvc.activeChatGuid.value,
    );
    if (_lastPushedHashPath == uri.path) return;
    _lastPushedHashPath = uri.path;
    SystemNavigator.routeInformationUpdated(uri: uri, replace: replace);
  }

  Future<void> _applyWebHashRoute(String rawLocation) async {
    if (!kIsWeb || !mounted || !SettingsSvc.settings.finishedSetup.value) return;
    final navContext = NavigationSvc.key.currentContext ?? context;
    final target = parseWebHashRoute(rawLocation);
    _syncingFromUrl = true;
    try {
      switch (target.kind) {
        case WebHashRouteKind.settings:
          _lastPushedHashPath = '/settings';
          if (!NavigationSvc.isSettingsOpen.value) {
            NavigationSvc.closeAllConversationView(navContext);
            await ChatsSvc.setAllInactive();
            if (!mounted || !navContext.mounted) return;
            await NavigationSvc.pushAndRemoveUntil(
              navContext,
              const SettingsPage(),
              (route) => route.isFirst,
            );
          }
          break;
        case WebHashRouteKind.chat:
          final guid = target.chatGuid!;
          _lastPushedHashPath = '/chat/${Uri.encodeComponent(guid)}';
          if (NavigationSvc.isSettingsOpen.value) {
            NavigationSvc.closeSettings(navContext);
          }
          if (ChatsSvc.activeChatGuid.value != guid) {
            final chat = Chat.findOne(guid: guid);
            if (chat != null && mounted) {
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
            NavigationSvc.closeSettings(navContext);
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
    EventDispatcherSvc.stream.listen((event) {
      if (event.type == 'refresh-all') {
        setState(() {});
      }
    });

    SchedulerBinding.instance.addPostFrameCallback((_) async {
      StartupTasks.uiReady.complete();

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
      if (kIsWeb && SettingsSvc.settings.finishedSetup.value) {
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
        _chatUrlWorker = ever(ChatsSvc.activeChatGuid, (_) => _pushWebHashRoute());
        _settingsUrlWorker = ever(NavigationSvc.isSettingsOpen, (_) => _pushWebHashRoute());
        updateWebTitleAndBadge(ChatsSvc.unreadCount.value);
        _webBadgeWorker = ever<int>(ChatsSvc.unreadCount, updateWebTitleAndBadge);

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

      if (kIsDesktop) {
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
          debounce<int>(ChatsSvc.unreadCount, updateBadge, time: const Duration(milliseconds: 250));

          /* ----- WINDOW EFFECT INITIALIZATION ----- */
          EventDispatcherSvc.stream.listen((event) async {
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

  @override
  void dispose() {
    _chatUrlWorker?.dispose();
    _settingsUrlWorker?.dispose();
    _webBadgeWorker?.dispose();
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

  void _showKeyboardShortcutsDialog(BuildContext context) {
    final navContext = NavigationSvc.key.currentContext ?? context;
    if (!navContext.mounted) return;
    showDialog<void>(
      context: navContext,
      builder: (dlgContext) {
        final cs = Theme.of(dlgContext).colorScheme;
        final tt = Theme.of(dlgContext).textTheme;
        Widget row(String keys, String label) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(child: Text(label, style: tt.bodyMedium)),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      keys,
                      style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface),
                    ),
                  ),
                ],
              ),
            );
        return AlertDialog(
          title: const Text('Keyboard shortcuts'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: SingleChildScrollView(
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final twoCol = constraints.maxWidth >= 460;
                  final navCol = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Navigation', style: tt.titleSmall?.copyWith(color: cs.primary)),
                      const SizedBox(height: 8),
                      row('Ctrl/Cmd + K', 'New conversation'),
                      row('Ctrl + . / Ctrl + Tab', 'Next conversation'),
                      row(
                        kIsWeb ? 'Ctrl + , / Ctrl + Shift + Tab' : 'Ctrl + Shift + Tab',
                        'Previous conversation',
                      ),
                      row('Ctrl/Cmd + F', 'Search messages'),
                    ],
                  );
                  final actCol = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Messaging & Actions', style: tt.titleSmall?.copyWith(color: cs.primary)),
                      const SizedBox(height: 8),
                      row('Alt + R', 'Reply to recent message'),
                      row('Alt + I', 'Toggle chat details'),
                      row('Alt + ,', 'Open settings'),
                      row('Ctrl/Cmd + /', 'Show keyboard shortcuts'),
                      row('Esc', 'Close / Go back'),
                    ],
                  );
                  if (!twoCol) {
                    return Column(mainAxisSize: MainAxisSize.min, children: [navCol, const SizedBox(height: 16), actCol]);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: navCol),
                      const SizedBox(width: 24),
                      Expanded(child: actCol),
                    ],
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dlgContext).pop(), child: const Text('Close')),
          ],
        );
      },
    );
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
        _ShowKeyboardShortcutsIntent: CallbackAction<_ShowKeyboardShortcutsIntent>(
          onInvoke: (_) {
            _showKeyboardShortcutsDialog(context);
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
      child: Obx(() => BBScaffold(
            backgroundColor: context.theme.colorScheme.surface.themeOpacity(context),
            body: Builder(
              builder: (BuildContext context) {
                if (SettingsSvc.settings.finishedSetup.value) {
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
          )),
    );
  }
}

// Kept for the app's lifetime: a garbage-collected TrayIcon removes the icon, and a collected MenuItem drops its
// click listener.
final List<Object> _trayHandles = [];
MenuItem? _trayToggleItem;
bool _trayWindowHidden = false;

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
  _trayToggleItem?.label = windowHidden ? 'Show App' : 'Hide App';
}

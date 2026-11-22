import 'dart:math' as math;

import 'package:bluebubbles/app/components/wallpaper/wallpaper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/cupertino_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/shared_contact_banner.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/messages_view_components.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/wrappers/gradient_background_wrapper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/messages_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/effects/screen_effects_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/window_effect.dart';
import 'package:get/get.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.chat,
    this.customService,
    this.initialScrollToGuid,
    this.fromChatCreator = false,
    this.autoOpened = false,
  });

  final Chat chat;
  final MessagesService? customService;
  final String? initialScrollToGuid;
  final bool fromChatCreator;
  final bool autoOpened;

  /// Builds the conversation body layout and keyboard-inset wrapper.
  ///
  /// When [floatingComposer] is true (Material skin on Android & Web), [messagesArea]
  /// extends underneath [composer] while [scrollDownButton] and [onComposerHeightChanged]
  /// adapt synchronously as [composer] expands on multiline text, replies, or attachments.
  @visibleForTesting
  static Widget buildBodyLayout({
    required Widget messagesArea,
    required Widget composer,
    Widget? scrollDownButton,
    bool floatingComposer = false,
    ValueChanged<double>? onComposerHeightChanged,
  }) {
    if (!floatingComposer) {
      final Widget stackedMessages = scrollDownButton != null
          ? Stack(children: [messagesArea, scrollDownButton])
          : messagesArea;
      final Widget bodyChild = LayoutBuilder(
        builder: (context, constraints) {
          final topPadding = MediaQuery.paddingOf(context).top;
          final usableHeight = math.max(0.0, constraints.maxHeight - topPadding);
          final maxComposerHeight = usableHeight > 260.0
              ? math.max(180.0, usableHeight - 80.0)
              : usableHeight;
          return Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Expanded(child: stackedMessages),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxComposerHeight),
                child: composer,
              ),
            ],
          );
        },
      );
      return Builder(
        builder: (context) {
          final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
          final bottomInset =
              viewInsetsBottom > 0 ? viewInsetsBottom : MediaQuery.viewPaddingOf(context).bottom;
          return Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: bodyChild,
          );
        },
      );
    }

    return Builder(
      builder: (context) {
        final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
        final bottomSafeInset =
            math.max(0.0, MediaQuery.viewPaddingOf(context).bottom - viewInsetsBottom);
        final topPadding = MediaQuery.paddingOf(context).top;
        return Padding(
          padding: EdgeInsets.only(bottom: viewInsetsBottom),
          child: CustomMultiChildLayout(
            delegate: _FloatingComposerLayoutDelegate(
              topPadding: topPadding,
              bottomSafeInset: bottomSafeInset,
              onComposerHeightChanged: onComposerHeightChanged,
            ),
            children: [
              LayoutId(id: _FloatingComposerSlot.messages, child: messagesArea),
              if (scrollDownButton != null)
                LayoutId(id: _FloatingComposerSlot.scrollDown, child: scrollDownButton),
              LayoutId(id: _FloatingComposerSlot.composer, child: composer),
            ],
          ),
        );
      },
    );
  }

  /// Seed resting bottom padding for the floating composer before frame 0 so
  /// edge-to-edge Android (non-zero `viewPadding.bottom`) does not jump after layout.
  @visibleForTesting
  static double initialComposerBottomPadding(
    BuildContext context, {
    double baseComposerHeight = 68.0,
  }) {
    final mq = context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    if (mq == null) return baseComposerHeight;
    final bottomSafeInset = math.max(0.0, mq.viewPadding.bottom - mq.viewInsets.bottom);
    return baseComposerHeight + bottomSafeInset;
  }

  /// Updates [bottomPadding] to [targetHeight] and compensates [scrollController]
  /// so bottom messages stay visible near the bottom (`offset <= 24.0`) and
  /// scrolled history does not jump (`offset > 24.0`).
  @visibleForTesting
  static void applyComposerBottomPadding({
    required ValueNotifier<double> bottomPadding,
    required double targetHeight,
    ScrollController? scrollController,
    double nearBottomThreshold = 24.0,
  }) {
    final delta = targetHeight - bottomPadding.value;
    if (delta.abs() <= 0.5) return;
    bottomPadding.value = targetHeight;

    if (scrollController == null || !scrollController.hasClients || scrollController.positions.length != 1) {
      return;
    }
    final offset = scrollController.offset;
    if (offset <= nearBottomThreshold) {
      if (delta > 0 && offset > 0.0) {
        scrollController.jumpTo(0.0);
      } else if (delta < 0 && offset > 0.0) {
        scrollController.jumpTo(math.max(0.0, offset + delta));
      }
    } else {
      scrollController.jumpTo(math.max(0.0, offset + delta));
    }
  }

  @override
  ConversationViewState createState() => ConversationViewState();
}

class ConversationViewState extends State<ConversationView> with ThemeHelpers<ConversationView>, RouteAware {
  late final ConversationViewController controller = cvc(chat, tag: widget.customService?.tag);

  // Cache actions map to avoid rebuilding on every frame
  late final Map<Type, Action<Intent>> _actionsMap;

  // Cached stable widget subtrees. ConversationView.build() runs on every keyboard
  // animation frame because Scaffold/SafeArea subscribe to MediaQuery. Flutter
  // checks widget identity (child.widget == newWidget) before calling update() on
  // a child element — passing the same object instance skips the State rebuild
  // entirely, so MessagesView, GradientBackground, ConversationTextField, and the
  // header widgets will not rebuild on keyboard frames.
  late final Widget _bodyContent;
  late final PreferredSizeWidget _appBar;
  final ValueNotifier<int> _unreadWhileScrolledCount = ValueNotifier<int>(0);
  // Matches resting single-line Material composer height (48px pill + 20px vertical padding)
  // so frame 0 has no visible jump before the first layout callback reports exact height.
  final ValueNotifier<double> _composerBottomPadding = ValueNotifier<double>(68.0);
  double? _pendingComposerHeight;
  bool _didInitComposerPadding = false;

  void _onComposerHeightChanged(double height) {
    if ((height - _composerBottomPadding.value).abs() <= 0.5) return;
    if (_pendingComposerHeight == height) return;
    _pendingComposerHeight = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _pendingComposerHeight;
      _pendingComposerHeight = null;
      if (target != null) {
        ConversationView.applyComposerBottomPadding(
          bottomPadding: _composerBottomPadding,
          targetHeight: target,
          scrollController: controller.scrollController,
        );
      }
    });
  }

  Chat get chat => widget.chat;

  void _onPanUpdate(DragUpdateDetails details) {
    if (!mounted) return;
    if (SettingsSvc.settings.swipeToCloseKeyboard.value && details.delta.dy > 0 && controller.keyboardOpen) {
      controller.focusNode.unfocus();
      controller.subjectFocusNode.unfocus();
    } else if (SettingsSvc.settings.swipeToOpenKeyboard.value && details.delta.dy < 0 && !controller.keyboardOpen) {
      controller.focusNode.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    controller.viewOwner = this;
    controller.fromChatCreator = widget.fromChatCreator;
    controller.fromSearchResult = widget.initialScrollToGuid != null;
    controller.autoOpened = widget.autoOpened;
    ChatsSvc.setActiveChatSync(chat, clearNotifications: !widget.autoOpened);
    _sectionWorker = ever(NavigationSvc.openSection, (_) => _updateCovered());
    _updateCovered();
    ChatsSvc.activeChat?.controller = controller;
    if (kIsWeb && NavigationSvc.showInspectorDrawer.value) {
      NavigationSvc.showInspectorDrawer.value = false;
    }
    Logger.debug("Conversation View initialized for ${chat.guid}");

    controller.loadReplyToMessageState(); // P224b

    // Build actions map once
    _buildActionsMap();

    // Cache the stable appBar and body subtrees. See field comments above.
    _appBar = _buildAppBar();
    _bodyContent = _buildBodyContent();

    // Warm the image cache for the custom background so it's ready on first paint.
    final bgPath = ChatsSvc.getChatState(chat.guid)?.customBackgroundPath.value;
    if (bgPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Same resize parameters as GradientBackgroundWrapper, or this warms a
        // cache entry the wrapper never reads and the file decodes twice. The
        // entry is deliberately left in the cache on close so reopening the chat
        // paints the background on its first frame; the LRU cap and the
        // on-background purge decide when it goes.
        precacheImage(chatBackgroundImageProvider(bgPath, context), context);
      });
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: Size(
        double.infinity, // width is ignored by Scaffold
        (kIsDesktop ? (!iOS ? 25 : 5) : 0) +
            90 * (iOS ? SettingsSvc.settings.avatarScale.value : 0) +
            (!iOS ? kToolbarHeight : 0),
      ),
      child: iOS ? CupertinoHeader(controller: controller) : MaterialHeader(controller: controller),
    );
  }

  Widget _buildBodyContent() {
    // Built once so keyboard animation frames only rebuild the padding
    final composer = GestureDetector(
      onPanUpdate: _onPanUpdate,
      child: ConversationTextField(
        parentController: controller,
      ),
    );
    final floatingComposer = !iOS && !samsung;
    final bodyLayout = ConversationView.buildBodyLayout(
      messagesArea: MessagesView(
        key: Key(chat.guid),
        customService: widget.customService,
        initialScrollToGuid: widget.initialScrollToGuid,
        controller: controller,
        bottomPaddingListenable: floatingComposer ? _composerBottomPadding : null,
        unreadWhileScrolledCount: _unreadWhileScrolledCount,
      ),
      scrollDownButton: ScrollDownButton(
        controller: controller,
        unreadWhileScrolledCount: _unreadWhileScrolledCount,
      ),
      composer: composer,
      floatingComposer: floatingComposer,
      onComposerHeightChanged: floatingComposer ? _onComposerHeightChanged : null,
    );
    final content = GradientBackground(
      controller: controller,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(child: ScreenEffectsWidget()),
          bodyLayout,
          // Painted above bodyLayout so messages passing behind the gesture bar do not
          // show through underneath an open attachment or game picker tray.
          Builder(
            builder: (context) {
              final bottomInset = MediaQuery.paddingOf(context).bottom;
              if (bottomInset <= 0) return const SizedBox.shrink();
              return Obx(() => Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: bottomInset,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: controller.showAttachmentPicker.value ||
                                controller.showGamePicker.value ||
                                controller.showTextFormattingPanel.value
                            ? context.theme.colorScheme.surface
                            : Colors.transparent,
                      ),
                    ),
                  ));
            },
          ),
          // The body extends behind the header, whose height is in the top padding
          Builder(
            builder: (context) => Positioned(
              top: MediaQuery.paddingOf(context).top,
              left: 0,
              right: 0,
              child: SharedContactBanner(chat: chat),
            ),
          ),
        ],
      ),
    );
    if (iOS || samsung) return content;
    return Builder(
      builder: (context) => Material(
        color: SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
            ? Colors.transparent
            : context.theme.colorScheme.surface,
        child: content,
      ),
    );
  }

  void _buildActionsMap() {
    _actionsMap = {
      if (SettingsSvc.settings.enablePrivateAPI.value) ReplyRecentIntent: ReplyRecentAction(widget.chat.guid),
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didInitComposerPadding) {
      _didInitComposerPadding = true;
      _composerBottomPadding.value = ConversationView.initialComposerBottomPadding(context);
    }
    final route = ModalRoute.of(context);
    if (route != null) NavigationSvc.paneRouteObserver.subscribe(this, route);
  }

  bool _pageOver = false;
  late final Worker _sectionWorker;

  void _updateCovered() => ChatsSvc.getOrCreateChatState(chat)
      .updateCoveredInternal(_pageOver || NavigationSvc.openSection.value != null);

  @override
  void didPushNext() {
    // A route was pushed on top of the conversation view (e.g. ConversationDetails).
    controller.showingSubRoute = true;
    _pageOver = true;
    _updateCovered();
  }

  @override
  void didPopNext() {
    // The route above was popped — conversation view is visible again.
    controller.showingSubRoute = false;
    _pageOver = false;
    _updateCovered();
  }

  @override
  void dispose() {
    _unreadWhileScrolledCount.dispose();
    _composerBottomPadding.dispose();
    _sectionWorker.dispose();
    NavigationSvc.paneRouteObserver.unsubscribe(this);
    controller.saveReplyToMessageState(); // P8bda
    // A replacement view may already have taken this controller over; deleting it would dispose the focus nodes
    // and text controllers its composer is using
    if (identical(controller.viewOwner, this)) {
      controller.deleteIfCurrent();
      if (controller.isClosed) controller.disposeComposer();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final windowEffect = SettingsSvc.settings.windowEffect.value;
    final chatState = ChatsSvc.getOrCreateChatState(chat);
    return ChatStateScope(
      chatState: chatState,
      child: Obx(() {
        final isDark = ThemeSvc.inDarkMode(context);
        chatState.themeVersion.value;
        final themeName = isDark ? chatState.customThemeDark.value : chatState.customThemeLight.value;
        final baseTheme = ThemeStruct.resolveByName(themeName, isDark ? Brightness.dark : Brightness.light).data;

        final colorScheme = baseTheme.colorScheme;
        final bubbleColors = baseTheme.extensions[BubbleColors] as BubbleColors?;
        final bubbleColor = bubbleColors != null
            ? (chat.isIMessage
                ? bubbleColors.iMessageBubbleColor ?? colorScheme.iMessageBubble
                : bubbleColors.smsBubbleColor ?? colorScheme.smsBubble)
            : colorScheme.bubble(context, chat.isIMessage);
        final onBubbleColor = bubbleColors != null
            ? (chat.isIMessage
                ? bubbleColors.oniMessageBubbleColor ?? colorScheme.oniMessageBubble
                : bubbleColors.onSmsBubbleColor ?? colorScheme.onSmsBubble)
            : colorScheme.onBubble(context, chat.isIMessage);

        return Theme(
          data: baseTheme.withEmojiFallback.copyWith(
            // Override primary color with our custom bubble color.
            primaryColor: bubbleColor,
            colorScheme: colorScheme.copyWith(
              primary: bubbleColor,
              onPrimary: onBubbleColor,
            ),
          ),
          child: Obx(() {
            final canPop = !LifecycleSvc.isBubble &&
                !controller.inSelectMode.value &&
                !controller.showAttachmentPicker.value &&
                !controller.showGamePicker.value &&
                !controller.showTextFormattingPanel.value;
            return PopScope(
              canPop: canPop,
              onPopInvokedWithResult: <T>(bool didPop, T? result) async {
                if (didPop) {
                  controller.close();
                  return;
                }
                if (controller.inSelectMode.value) {
                  controller.inSelectMode.value = false;
                  controller.selected.clear();
                  return;
                }
                // Back from the picker's Genmoji or sticker library goes to its photos first.
                if (controller.showAttachmentPicker.value &&
                    (controller.showGenmojiLibrary.value || controller.showStickerLibrary.value)) {
                  controller.showGenmojiLibrary.value = false;
                  controller.showStickerLibrary.value = false;
                  return;
                }
                if (controller.showAttachmentPicker.value) {
                  controller.showAttachmentPicker.value = false;
                  controller.updateWidgets<ConversationTextField>(null);
                  return;
                }
                if (controller.showGamePicker.value) {
                  controller.showGamePicker.value = false;
                  return;
                }
                if (controller.showTextFormattingPanel.value) {
                  // Unfocused first, or the field taking input again brings the keyboard up in the panel's place
                  controller.focusNode.unfocus();
                  controller.showTextFormattingPanel.value = false;
                  return;
                }
                if (LifecycleSvc.isBubble) {
                  SystemNavigator.pop();
                  controller.close();
                }
              },
              child: BBScaffold(
                backgroundColor: windowEffect != WindowEffect.disabled
                    ? Colors.transparent
                    : colorScheme.surface,
                extendBodyBehindAppBar: true,
                resizeToAvoidBottomInset: false,
                appBar: _appBar,
                body: RepaintBoundary(
                  child: Actions(
                    actions: _actionsMap,
                    child: _bodyContent,
                  ),
                ),
              ),
            );
          }),
        );
      }),
    );
  }
}

enum _FloatingComposerSlot { messages, scrollDown, composer }

class _FloatingComposerLayoutDelegate extends MultiChildLayoutDelegate {
  _FloatingComposerLayoutDelegate({
    required this.topPadding,
    required this.bottomSafeInset,
    this.onComposerHeightChanged,
  });

  final double topPadding;
  final double bottomSafeInset;
  final ValueChanged<double>? onComposerHeightChanged;

  @override
  void performLayout(Size size) {
    final usableHeight = math.max(0.0, size.height - topPadding - bottomSafeInset);
    final maxComposerHeight = math.min(
      math.max(0.0, size.height - bottomSafeInset),
      usableHeight > 260.0 ? math.max(180.0, usableHeight - 80.0) : usableHeight,
    );

    Size composerSize = Size.zero;
    if (hasChild(_FloatingComposerSlot.composer)) {
      composerSize = layoutChild(
        _FloatingComposerSlot.composer,
        BoxConstraints(
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: 0,
          maxHeight: maxComposerHeight,
        ),
      );
      positionChild(
        _FloatingComposerSlot.composer,
        Offset(0, math.max(0.0, size.height - bottomSafeInset - composerSize.height)),
      );
    }

    final bottomObstruction = composerSize.height + bottomSafeInset;
    onComposerHeightChanged?.call(bottomObstruction);

    if (hasChild(_FloatingComposerSlot.messages)) {
      layoutChild(_FloatingComposerSlot.messages, BoxConstraints.tight(size));
      positionChild(_FloatingComposerSlot.messages, Offset.zero);
    }

    if (hasChild(_FloatingComposerSlot.scrollDown)) {
      final aboveComposer = math.max(0.0, size.height - bottomObstruction);
      final scrollDownSize = layoutChild(
        _FloatingComposerSlot.scrollDown,
        BoxConstraints.loose(Size(size.width, aboveComposer)),
      );
      positionChild(
        _FloatingComposerSlot.scrollDown,
        Offset(
          (size.width - scrollDownSize.width) / 2,
          math.max(0.0, aboveComposer - scrollDownSize.height),
        ),
      );
    }
  }

  @override
  bool shouldRelayout(_FloatingComposerLayoutDelegate oldDelegate) {
    return topPadding != oldDelegate.topPadding ||
        bottomSafeInset != oldDelegate.bottomSafeInset ||
        onComposerHeightChanged != oldDelegate.onComposerHeightChanged;
  }
}

import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:bluebubbles/app/components/m3e/m3e_motion.dart';
import 'package:bluebubbles/app/components/m3e/m3e_shapes.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/media_actions.dart'
    as popup_media_actions;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/message_actions.dart'
    as popup_message_actions;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/navigation_actions.dart'
    as popup_navigation_actions;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/text_actions.dart'
    as popup_text_actions;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/details_menu_action.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/reaction_picker_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/widgets/emoji_tapback_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/widgets/reaction_details.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_pin_clipper.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/shared/message_clone_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide BackButton;
import 'package:flutter/physics.dart';
import 'package:bluebubbles/database/models.dart' hide PayloadType;
import 'package:flutter/services.dart';
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/tapback_icon.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

export 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart'
    show MessagePopupServerDetails;

class MessagePopup extends StatefulWidget {
  final Offset childPosition;
  final Size size;
  final Widget child;
  final MessagePart part;
  final MessageState controller;
  final ConversationViewController cvController;
  final MessagePopupServerDetails serverDetails;
  final Function([String? type, int? part, String? emoji]) sendTapback;
  final BuildContext? Function() widthContext;

  const MessagePopup({
    super.key,
    required this.childPosition,
    required this.size,
    required this.child,
    required this.part,
    required this.controller,
    required this.cvController,
    required this.serverDetails,
    required this.sendTapback,
    required this.widthContext,
  });

  @override
  State<StatefulWidget> createState() => _MessagePopupState();
}

class _MessagePopupState extends State<MessagePopup> with TickerProviderStateMixin, ThemeHelpers {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: M3EMotion.effectsFast.duration,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final AnimationController _tapbackSpringController = AnimationController.unbounded(
    vsync: this,
    value: 1.0,
  );
  late final AnimationController _toolbarController = AnimationController(
    vsync: this,
    duration: M3EMotion.spatialDefault.duration,
  );
  final double itemHeight = kIsDesktop || kIsWeb ? 56 : 48;

  List<Message> reactions = [];
  late double messageOffset = Get.height - widget.childPosition.dy - widget.size.height;
  late double materialOffset = widget.childPosition.dy +
      EdgeInsets.fromViewPadding(
        View.of(context).viewInsets,
        View.of(context).devicePixelRatio,
      ).bottom;
  late int numberToShow = 5;
  late Chat? dmChat = ChatsSvc.allChats.firstWhereOrNull((chat) =>
      !chat.isGroup &&
      chat.handles.firstWhereOrNull((handle) => handle.address == message.handleRelation.target?.address) != null);
  String? selfReaction;
  String? selfEmoji;
  // Emoji you've reacted with, newest first (not the pickers' typed-emoji recents)
  late final List<String> recentEmojis = PrefsSvc.messaging.getRecentTapbackEmojis(chatGuid: chat.guid);
  String? currentlySelectedReaction = "init";
  final GlobalKey _childKey = GlobalKey();
  final GlobalKey _detailsKey = GlobalKey();
  final GlobalKey _menuKey = GlobalKey();
  double? _measuredChildHeight;
  double? _measuredChildWidth;
  double? _measuredMenuHeight;

  ConversationViewController get cvController => widget.cvController;

  MessagesService get service => MessagesSvc(chat.guid);

  Chat get chat => widget.cvController.chat;

  MessagePart get part => widget.part;

  Message get message => widget.controller.message;

  bool get isSent {
    final isSending = widget.controller.isSending.value;
    final hasError = widget.controller.hasError.value;
    return !isSending && !hasError;
  }

  // A Genmoji part is a text bubble, so attachment actions don't apply to it
  bool get showDownload =>
      (isSent &&
          part.attachments.isNotEmpty &&
          !part.hasInlineAttachments &&
          part.attachments.where((element) => AttachmentsSvc.hasLocalFile(element)).isNotEmpty) ||
      isEmbeddedMedia;

  bool get showRefreshPreview =>
      message.isLegacyUrlPreview || message.payloadData?.type == PayloadType.url || message.isPhotoSlideshow;

  bool get canOpenInImageViewer =>
      part.attachments.length == 1 && !part.hasInlineAttachments && part.attachments.first.mimeStart == "image";

  late bool isEmbeddedMedia = (message.balloonBundleId == "com.apple.Handwriting.HandwritingProvider" ||
          message.balloonBundleId == "com.apple.DigitalTouchBalloonProvider") &&
      File(message.interactiveMediaPath!).existsSync();

  bool get minSierra => widget.serverDetails.minSierra;

  bool get minBigSur => widget.serverDetails.minBigSur;

  bool get supportsOriginalDownload => widget.serverDetails.supportsOriginalDownload;

  bool get _supportsTapbackAndReply =>
      chat.isIMessage ||
      chat.isRCS ||
      (ChatServiceType.fromServiceName(message.service)?.supportsTapbackAndReply ?? false);

  bool get _hasCustomWallpaper => ChatsSvc.getChatState(chat.guid)?.hasCustomWallpaper ?? false;

  BuildContext get widthContext => widget.widthContext.call() ?? context;

  @override
  void initState() {
    super.initState();
    controller.forward();
    if (!iOS) {
      _toolbarController.forward();
    }
    _triggerTapbackSpring();
    if (iOS) {
      _fitMenu();
    } else {
      // Potentially make this dynamic in the future
      numberToShow = 5;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final measuredSize = _childKey.currentContext?.size;
      currentlySelectedReaction = null;
      reactions = getUniqueReactionMessages(message.associatedMessages
          .where((e) =>
              ReactionTypes.isTapbackType(e.associatedMessageType) &&
              (e.associatedMessagePart ?? 0) == part.part)
          .toList());
      final selfMessage = reactions.firstWhereOrNull((e) => e.isFromMe!);
      final self = selfMessage?.associatedMessageType;
      if (self != null && !ReactionTypes.isRemoval(self)) {
        selfReaction = self;
        selfEmoji = selfMessage!.associatedMessageEmoji;
        currentlySelectedReaction = selfReaction;
      }
      setState(() {
        if (measuredSize != null) {
          _measuredChildHeight = measuredSize.height;
          _measuredChildWidth = measuredSize.width;
        }
        if (iOS) {
          _measuredMenuHeight = _menuKey.currentContext?.size?.height;
          _fitMenu();
          messageOffset = _messageOffset();
        }
      });
      // The reaction details and refitted menu only lay out after the setState above, so fit again with their heights
      if (iOS) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _measuredMenuHeight = _menuKey.currentContext?.size?.height;
            _fitMenu();
            messageOffset = _messageOffset();
          });
        });
      }
    });
  }

  void _triggerTapbackSpring({double from = 0.72}) {
    if (!mounted) return;
    _tapbackSpringController.stop();
    _tapbackSpringController.animateWith(
      SpringSimulation(M3EMotion.springSpatialFast, from, 1.0, 2.0),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    _tapbackSpringController.dispose();
    _toolbarController.dispose();
    super.dispose();
  }

  /// How many actions fit under the message on iOS without covering the reaction details; the rest go under "More...".
  void _fitMenu() {
    final childHeight = _measuredChildHeight ?? widget.size.height;
    final detailsHeight = reactions.isEmpty ? 0.0 : _detailsKey.currentContext?.size?.height ?? 0;
    final remainingHeight =
        max(Get.height - Get.statusBarHeight - 135 - childHeight - detailsHeight, itemHeight);
    numberToShow = min(remainingHeight ~/ itemHeight, 5);
  }

  /// Lifts the preview above the details menu, but keeps it below the status bar.
  double _messageOffset() {
    final previewHeight = _measuredChildHeight ?? widget.size.height;
    final maxBottom = Get.height - Get.statusBarHeight - 8 - previewHeight;
    return min(_menuHeight + 40, max(40.0, maxBottom));
  }

  /// The details menu as laid out: its rows aren't always [itemHeight] tall
  double get _menuHeight => _measuredMenuHeight ?? itemHeight * numberToShow;

  void _remeasureChild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _childKey.currentContext?.size;
      if (size == null) return;
      if (size.height != _measuredChildHeight || size.width != _measuredChildWidth) {
        setState(() {
          _measuredChildHeight = size.height;
          _measuredChildWidth = size.width;
        });
      }
    });
  }

  /// Where the tapback picker's box sits, from the bottom of the screen.
  double _pickerBottom(BuildContext context, bool narrowScreen) => (iOS
          ? _menuHeight + 35 + (_measuredChildHeight ?? widget.size.height)
          : context.height - materialOffset)
      .clamp(0, context.height - (narrowScreen ? 200 : 125));

  Future<void> _pickEmojiTapback() async {
    final picked = await showEmojiTapbackPicker(context);
    if (picked != null && mounted) _sendEmojiTapback(picked);
  }

  /// Sends [emoji] as your tapback, or takes it back when it's already yours, as Messages does.
  void _sendEmojiTapback(String emoji) {
    HapticFeedback.lightImpact();
    final removing = selfReaction == ReactionTypes.EMOJI && emoji == selfEmoji;
    if (!removing) unawaited(PrefsSvc.messaging.addRecentTapbackEmoji(emoji, chatGuid: chat.guid));
    widget.sendTapback(removing ? ReactionTypes.REMOVED_EMOJI : ReactionTypes.EMOJI, part.part, emoji);
    popDetails();
  }


  // Drawn like ReactionWidget._customGlyph, which centres emoji correctly. 26, not the icons' 22, so they read the same
  Widget _emojiTapbackGlyph(String emoji) => SizedBox.square(
        dimension: 26,
        child: FittedBox(
          child: Text(emoji,
              style: const TextStyle(
                  height: 1, leadingDistribution: TextLeadingDistribution.even, fontFamily: 'Apple Color Emoji')),
        ),
      );

  /// Fades the row's edges, so an item scrolled half out of view fades rather than being cut.
  Widget _fadeScrollEdges(Widget child) => ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final edge = min(12 / max(bounds.width, 1), 0.5);
          return LinearGradient(
            colors: const [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, edge, 1 - edge, 1],
          ).createShader(bounds);
        },
        child: child,
      );

  static const double _addEmojiCircleSize = 45;
  static const double _addEmojiCircleGap = 6;
  static const double _addEmojiCircleRoom = _addEmojiCircleSize + _addEmojiCircleGap;

  /// The tapback panel with the add-emoji circle beside it, on the side away from the screen edge it's pinned to.
  Widget _withAddEmojiCircle(Widget panel) {
    if (!SettingsSvc.serverDetails.supportsEmojiTapbacks) return panel;
    // Level with the panel's pill; ReactionPickerClipper keeps its bottom 15 for the thought-bubble dots
    final circle = Padding(
      padding: const EdgeInsets.only(top: 5),
      child: _addEmojiCircle(context),
    );
    const gap = SizedBox(width: _addEmojiCircleGap);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: message.isFromMe! ? [circle, gap, panel] : [panel, gap, circle],
    );
  }

  Color _tapbackPanelColor(BuildContext context) => context.theme.colorScheme.surfaceContainerHighest
      .withValues(alpha: iOS ? 150 / 255 : (_hasCustomWallpaper ? 0.86 : 1.0))
      .lightenOrDarken(iOS ? 0 : 10);

  // On iOS this "shadow" is the panel's own colour laid under it, which gives it its density
  Shadow _tapbackPanelShadow(BuildContext context) => iOS
      ? BoxShadow(color: _tapbackPanelColor(context))
      : BoxShadow(color: context.theme.colorScheme.shadow, blurRadius: 2);

  /// Opens the full emoji picker. Drawn exactly like the tapback panel, so the two read as a set.
  Widget _addEmojiCircle(BuildContext context) {
    return ClipShadowPath(
      shadow: _tapbackPanelShadow(context),
      clipper: const _CircleClipper(),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Material(
          color: _tapbackPanelColor(context),
          child: InkWell(
            onTap: _pickEmojiTapback,
            child: SizedBox.square(
              dimension: _addEmojiCircleSize,
              child: Icon(iOS ? cupertino.CupertinoIcons.add : Icons.add,
                  size: 24, color: context.theme.colorScheme.outline),
            ),
          ),
        ),
      ),
    );
  }

  void popDetails({bool returnVal = true}) {
    Navigator.popUntil(context, (route) => route is! DialogRoute);
    Navigator.of(context).pop(returnVal);
  }

  /// Gap kept between the popup's overlays / preview and the screen edges.
  static const double _edgeMargin = 15;

  /// Incoming overlay X so tapback / details stay on-screen; may shift the iOS preview.
  ({double clampedOverlayLeft, double clampedChildLeft}) _clampedHorizontalLayout({
    required double screenWidth,
    required double paneWidth,
    required double pickerWidth,
  }) {
    const margin = _edgeMargin;
    final preferredOverlayLeft = widget.childPosition.dx + 10;
    // Sized from the pane, as the details menu itself is
    final detailsMenuWidth = iOS ? min(max(paneWidth * 3 / 5, 200), paneWidth * 4 / 5) : 0.0;
    final overlayWidth = max(pickerWidth, detailsMenuWidth);
    final maxLeft = max(margin, screenWidth - overlayWidth - margin);
    final clampedOverlayLeft = preferredOverlayLeft.clamp(margin, maxLeft).toDouble();
    final shift = preferredOverlayLeft - clampedOverlayLeft;
    final clampedChildLeft = max(margin, widget.childPosition.dx - shift);
    return (clampedOverlayLeft: clampedOverlayLeft, clampedChildLeft: clampedChildLeft);
  }

  /// Keep a left-anchored (received) preview fully on-screen when it grows past the cell width.
  double _clampReceivedPreviewLeft({
    required double screenWidth,
    required double preferredLeft,
  }) {
    const margin = _edgeMargin;
    final previewWidth = _measuredChildWidth ?? max(widget.size.width, screenWidth * 0.5);
    final maxLeft = max(margin, screenWidth - previewWidth - margin);
    return preferredLeft.clamp(margin, maxLeft).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    // Decide whether the tapback row needs to wrap to a second line by comparing its actual
    // content width (derived from the fixed per-item padding/icon sizes used below) against the
    // real horizontal space available at the picker's anchor position, rather than guessing from
    // overall screen width. widget.childPosition.dx already reflects any avatar space the bubble
    // was pushed past, so no avatar/group special-casing is needed here.
    final double screenWidth = NavigationSvc.width(widthContext);
    // childPosition is relative to the whole window on iOS and to the conversation pane elsewhere
    final double popupWidth = iOS ? context.width : screenWidth;
    final double reactionPickerAvailableWidth = message.isFromMe!
        ? screenWidth - _edgeMargin - _edgeMargin
        : popupWidth - (widget.childPosition.dx + 10) - _edgeMargin;
    final double reactionItemWidth = iOS ? 45.0 : 44.0; // icon/emoji + its fixed padding, see item build below
    // Emoji tapbacks need a v2 server and macOS 15. As in Messages: one scrolling row of tapbacks, yours, then recents
    final emojiTapbacks = SettingsSvc.serverDetails.supportsEmojiTapbacks;
    final ownEmoji = selfReaction == ReactionTypes.EMOJI ? selfEmoji : null;
    final tapbackItems = [
      ...ReactionTypes.toList(),
      if (emojiTapbacks) ...{?ownEmoji, ...recentEmojis},
    ];
    final double reactionRowContentWidth = reactionItemWidth * tapbackItems.length + 10;
    // A scrolling row never needs to wrap
    bool narrowScreen = !emojiTapbacks && reactionRowContentWidth > reactionPickerAvailableWidth;
    // At most about 7.5 items, so the half item shows the row scrolls
    final double emojiRowMaxWidth =
        max(min(reactionPickerAvailableWidth - 10 - _addEmojiCircleRoom, reactionItemWidth * 7.5), 0);
    final double pickerWidth = narrowScreen
        ? reactionItemWidth * 3 + 10
        : emojiTapbacks
            ? min(reactionRowContentWidth, emojiRowMaxWidth + 10) + _addEmojiCircleRoom
            : reactionRowContentWidth;
    final isFromMe = message.isFromMe!;
    final clampedLayout = isFromMe
        ? null
        : _clampedHorizontalLayout(screenWidth: popupWidth, paneWidth: screenWidth, pickerWidth: pickerWidth);
    final clampedOverlayLeft = clampedLayout?.clampedOverlayLeft;
    // From-me: pin the preview's right edge to the cell's right edge so growth stays on-screen.
    // Received: left-anchor, then clamp using measured/estimated preview width.
    const margin = _edgeMargin;
    final double? previewRight =
        isFromMe ? max(margin, popupWidth - widget.childPosition.dx - widget.size.width) : null;
    final double? previewLeft = isFromMe
        ? null
        : _clampReceivedPreviewLeft(
            screenWidth: popupWidth,
            preferredLeft: clampedLayout?.clampedChildLeft ?? widget.childPosition.dx,
          );

    final double screenHeight = MediaQuery.sizeOf(context).height;
    final double topSafe = MediaQuery.paddingOf(context).top + (kIsDesktop ? 40.0 : 12.0);
    final bool showTapbacks = SettingsSvc.settings.enablePrivateAPI.value && isSent && minSierra && _supportsTapbackAndReply;
    final double tapbackReserved = showTapbacks ? (narrowScreen ? 108.0 : 64.0) : 0.0;
    final double bottomReserved = MediaQuery.paddingOf(context).bottom + 92.0;
    final double bubbleHeight = _measuredChildHeight ?? widget.size.height;
    final double minBubbleTop = topSafe + tapbackReserved;
    final double maxBubbleTop = max(minBubbleTop, screenHeight - bottomReserved - bubbleHeight);
    final double clampedMaterialBubbleTop = materialOffset.clamp(minBubbleTop, maxBubbleTop).toDouble();
    final double maxMaterialBubbleHeight = max(80.0, screenHeight - bottomReserved - minBubbleTop);
    final double maxMaterialBubbleWidth = max(widget.size.width, popupWidth * 0.78);

    return Theme(
      data: context.theme.copyWith(
        // in case some components still use legacy theming
        primaryColor: context.theme.colorScheme.bubble(context, chat.isIMessage),
        colorScheme: context.theme.colorScheme.copyWith(
          primary: context.theme.colorScheme.bubble(context, chat.isIMessage),
          onPrimary: context.theme.colorScheme.onBubble(context, chat.isIMessage),
          surface: ThemeSvc.isMaterialYouActive(context)
              ? null
              : (context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor,
          onSurface: ThemeSvc.isMaterialYouActive(context)
              ? null
              : (context.theme.extensions[BubbleColors] as BubbleColors?)?.onReceivedBubbleColor,
        ),
      ),
      child: TitleBarWrapper(
          child: BBScaffold(
              extendBodyBehindAppBar: true,
              safeAreaLeft: false,
              safeAreaRight: false,
              safeAreaBottom: iOS ? null : false,
              // The popup opens over a still-collapsing keyboard. Keep the body
              // full-screen and its bottom edge fixed so Positioned offsets are
              // screen-anchored and don't ride the inset animation down.
              resizeToAvoidBottomInset: false,
              safeAreaMaintainBottomViewPadding: true,
              backgroundColor: kIsDesktop && iOS && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                  ? context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
                  : Colors.transparent,
              appBar: null,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: popDetails,
                    child: iOS
                        ? (SettingsSvc.settings.highPerfMode.value
                            ? Container(color: context.theme.colorScheme.surface.withValues(alpha: 0.5))
                            : BackdropFilter(
                                filter: ImageFilter.blur(
                                    sigmaX:
                                        kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                                            ? 10
                                            : 30,
                                    sigmaY:
                                        kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                                            ? 10
                                            : 30),
                                child: Container(
                                  color: Colors.transparent.withValues(alpha: 0.1),
                                ),
                              ))
                        : FadeTransition(
                            opacity: controller,
                            child: Container(
                              color: context.theme.colorScheme.scrim.withValues(alpha: 0.45),
                            ),
                          ),
                  ),
                  if (iOS)
                    AnimatedPositioned(
                      duration: M3EMotion.spatialFast.duration,
                      curve: M3EMotion.spatialOvershoot,
                      left: previewLeft,
                      right: previewRight,
                      bottom: messageOffset,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.8, end: 1),
                        curve: M3EMotion.spatialOvershoot,
                        duration: M3EMotion.spatialDefault.duration,
                        child: NotificationListener<SizeChangedLayoutNotification>(
                          onNotification: (_) {
                            _remeasureChild();
                            return false;
                          },
                          child: SizeChangedLayoutNotifier(
                            child: ConstrainedBox(
                              key: _childKey,
                              constraints: BoxConstraints(
                                maxWidth: max(
                                  widget.size.width,
                                  NavigationSvc.width(widthContext) * 0.5,
                                ),
                              ),
                              // Marked as a clone so anything inside that
                              // reacts to shared state by doing work (URL
                              // preview refreshes, say) knows not to — this
                              // copy and the real bubble both see every signal.
                              child: MessageCloneScope(
                                child: MessageStateScope(
                                  messageState: widget.controller,
                                  child: widget.child,
                                ),
                              ),
                            ),
                          ),
                        ),
                        builder: (context, size, child) {
                          return Transform.scale(
                            scale: size.clamp(1, double.infinity),
                            alignment: isFromMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: child,
                          );
                        },
                      ),
                    ),
                  if (!iOS)
                    AnimatedPositioned(
                      duration: M3EMotion.spatialFast.duration,
                      curve: M3EMotion.spatialOvershoot,
                      left: previewLeft,
                      right: previewRight,
                      top: clampedMaterialBubbleTop,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.94, end: 1.0),
                        curve: M3EMotion.spatialOvershoot,
                        duration: M3EMotion.spatialDefault.duration,
                        builder: (context, scale, child) {
                          return Transform.scale(
                            scale: scale,
                            alignment: isFromMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: child,
                          );
                        },
                        child: NotificationListener<SizeChangedLayoutNotification>(
                          onNotification: (_) {
                            _remeasureChild();
                            return false;
                          },
                          child: SizeChangedLayoutNotifier(
                            child: ConstrainedBox(
                              key: _childKey,
                              constraints: BoxConstraints(
                                maxWidth: maxMaterialBubbleWidth,
                                maxHeight: maxMaterialBubbleHeight,
                              ),
                              child: SingleChildScrollView(
                                physics: const ClampingScrollPhysics(),
                                child: MessageCloneScope(
                                  child: MessageStateScope(
                                    messageState: widget.controller,
                                    child: widget.child,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (iOS)
                    Positioned(
                      top: 40,
                      left: 15,
                      right: 15,
                      child: AnimatedSize(
                        duration: M3EMotion.spatialDefault.duration,
                        curve: M3EMotion.spatialOvershoot,
                        alignment: Alignment.center,
                        child: reactions.isNotEmpty
                            ? KeyedSubtree(key: _detailsKey, child: ReactionDetails(reactions: reactions))
                            : const SizedBox.shrink(),
                      ),
                    ),
                  if (showTapbacks && iOS)
                    Positioned(
                      bottom: _pickerBottom(context, narrowScreen),
                      right: isFromMe ? 15 : null,
                      left: !isFromMe ? clampedOverlayLeft : null,
                      child: AnimatedSize(
                        curve: M3EMotion.spatialFast.curve,
                        alignment: isFromMe ? Alignment.centerRight : Alignment.centerLeft,
                        duration: M3EMotion.spatialFast.duration,
                        child: currentlySelectedReaction == "init"
                            ? const SizedBox(height: 80)
                            : _withAddEmojiCircle(
                                ClipShadowPath(
                                  shadow: _tapbackPanelShadow(context),
                                  clipper: ReactionPickerClipper(
                                    messageSize: widget.size,
                                    isFromMe: message.isFromMe!,
                                  ),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                    child: Container(
                                      padding: const EdgeInsets.all(5).add(const EdgeInsets.only(bottom: 15)),
                                      color: _tapbackPanelColor(context),
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              message.isFromMe! ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                          children: [
                                            ...List.generate(narrowScreen ? 2 : 1, (index) {
                                            final row = Row(
                                              mainAxisSize: MainAxisSize.min,
                                              mainAxisAlignment: MainAxisAlignment.start,
                                              children: tapbackItems
                                                  .slice(narrowScreen && index == 1 ? 3 : 0,
                                                      narrowScreen && index == 0 ? 3 : null)
                                                  .map((e) {
                                                final isEmoji = !ReactionTypes.toList().contains(e);
                                                return Padding(
                                                  padding: const EdgeInsets.all(5.0),
                                                  child: Material(
                                                    color: (isEmoji ? e == ownEmoji : currentlySelectedReaction == e)
                                                        ? context.theme.colorScheme.primary
                                                        : Colors.transparent,
                                                    borderRadius: BorderRadius.circular(20),
                                                    child: SizedBox(
                                                      width: 35,
                                                      height: 35,
                                                      child: InkWell(
                                                        borderRadius: BorderRadius.circular(20),
                                                        onTap: () async {
                                                          if (isEmoji) return _sendEmojiTapback(e);
                                                          if (currentlySelectedReaction == e) {
                                                            currentlySelectedReaction = null;
                                                          } else {
                                                            currentlySelectedReaction = e;
                                                          }
                                                          setState(() {});
                                                          HapticFeedback.lightImpact();
                                                          widget.sendTapback(selfReaction == e ? "-$e" : e, part.part);
                                                          popDetails();
                                                        },
                                                        child: Padding(
                                                          // Emoji ink covers less of its box than the tapback icons do
                                                          padding: EdgeInsets.all(isEmoji ? 4.5 : 6.5)
                                                              .add(EdgeInsets.only(right: e == "emphasize" ? 2.5 : 0)),
                                                          child: isEmoji
                                                              ? Center(child: _emojiTapbackGlyph(e))
                                                              : TapbackIcon(e),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }).toList(),
                                            );
                                            if (!emojiTapbacks) return row;
                                            return ConstrainedBox(
                                              constraints: BoxConstraints(maxWidth: emojiRowMaxWidth),
                                              child: _fadeScrollEdges(SingleChildScrollView(
                                                  scrollDirection: Axis.horizontal, child: row)),
                                            );
                                          }),
                                          ]),
                                    ),
                                  ),
                                )),
                      ),
                    ),
                  if (showTapbacks && !iOS)
                    Positioned(
                      bottom: (screenHeight - clampedMaterialBubbleTop + 10.0)
                          .clamp(0.0, max(0.0, screenHeight - 64.0)),
                      right: isFromMe ? 15 : null,
                      left: !isFromMe ? clampedOverlayLeft : null,
                      child: ScaleTransition(
                        scale: _tapbackSpringController,
                        alignment: isFromMe ? Alignment.bottomRight : Alignment.bottomLeft,
                        child: _buildMaterialTapbackPill(
                          context,
                          narrowScreen: narrowScreen,
                          emojiTapbacks: emojiTapbacks,
                          ownEmoji: ownEmoji,
                          tapbackItems: tapbackItems,
                          emojiRowMaxWidth: emojiRowMaxWidth,
                        ),
                      ),
                    ),
                  if (iOS)
                    Positioned(
                      right: isFromMe ? 15 : null,
                      left: !isFromMe ? clampedOverlayLeft : null,
                      bottom: 30,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.8, end: 1),
                        curve: M3EMotion.spatialOvershoot,
                        duration: M3EMotion.spatialDefault.duration,
                        child: FadeTransition(
                          opacity: CurvedAnimation(
                            parent: controller,
                            curve: Interval(0.0, .9, curve: M3EMotion.effectsFast.curve),
                            reverseCurve: Easing.standardAccelerate,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 5),
                              KeyedSubtree(key: _menuKey, child: buildDetailsMenu(context)),
                            ],
                          ),
                        ),
                        builder: (context, size, child) {
                          return Transform.scale(
                            scale: size,
                            child: child,
                          );
                        },
                      ),
                    ),
                  if (!iOS)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: MediaQuery.paddingOf(context).bottom + 12,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: FadeTransition(
                            opacity: CurvedAnimation(
                              parent: _toolbarController,
                              curve: M3EMotion.effectsFast.curve,
                            ),
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.28),
                                end: Offset.zero,
                              ).animate(CurvedAnimation(
                                parent: _toolbarController,
                                curve: M3EMotion.spatialOvershoot,
                              )),
                              child: _buildMaterialDockedToolbar(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ))),
    );
  }

  MessagePopupActionContext _buildActionContext(DetailsMenuAction action) {
    return MessagePopupActionContext(
      context: context,
      widthContext: widthContext,
      cvController: cvController,
      messageState: widget.controller,
      message: message,
      part: part,
      chat: chat,
      service: service,
      serverDetails: widget.serverDetails,
      action: action,
      popDetails: ({bool returnVal = true}) => popDetails(returnVal: returnVal),
      showSnack: showSnackbar,
      dmChat: dmChat,
      isEmbeddedMedia: isEmbeddedMedia,
    );
  }

  List<DetailsMenuActionWidget> get _allActions {
    final canEdit = (message.dateCreated?.toUtc().isWithin(DateTime.now().toUtc(), minutes: 15) ?? false);
    final canUnsend = (message.dateCreated?.toUtc().isWithin(DateTime.now().toUtc(), minutes: 2) ?? false);
    return [
      if (SettingsSvc.settings.enablePrivateAPI.value && minBigSur && _supportsTapbackAndReply && isSent)
        DetailsMenuActionWidget(
          onTap: () => popup_navigation_actions.reply(_buildActionContext(DetailsMenuAction.Reply)),
          action: DetailsMenuAction.Reply,
        ),
      if (showDownload)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.downloadAttachment(_buildActionContext(DetailsMenuAction.Save)),
          action: DetailsMenuAction.Save,
        ),
      if (canOpenInImageViewer)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.openInImageViewer(_buildActionContext(DetailsMenuAction.OpenInImageViewer)),
          action: DetailsMenuAction.OpenInImageViewer,
        ),
      if ((part.text?.hasUrl ?? false) && !LifecycleSvc.isBubble)
        DetailsMenuActionWidget(
          onTap: () => popup_text_actions.openLink(_buildActionContext(DetailsMenuAction.OpenInBrowser)),
          action: DetailsMenuAction.OpenInBrowser,
        ),
      if (showDownload && part.attachments.firstOrNull?.webUrl != null)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.openAttachmentWeb(_buildActionContext(DetailsMenuAction.OpenInNewTab)),
          action: DetailsMenuAction.OpenInNewTab,
        ),
      if (!isNullOrEmptyString(part.fullText))
        DetailsMenuActionWidget(
          onTap: () => popup_text_actions.copyText(_buildActionContext(DetailsMenuAction.CopyText)),
          action: DetailsMenuAction.CopyText,
        ),
      if (showDownload)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.copyAttachment(_buildActionContext(DetailsMenuAction.CopyAttachment)),
          action: DetailsMenuAction.CopyAttachment,
        ),
      if (showDownload &&
          supportsOriginalDownload &&
          part.attachments
              .where((element) =>
                  (element.uti?.contains("heic") ?? false) ||
                  (element.uti?.contains("heif") ?? false) ||
                  (element.uti?.contains("quicktime") ?? false) ||
                  (element.uti?.contains("coreaudio") ?? false) ||
                  (element.uti?.contains("tiff") ?? false))
              .isNotEmpty)
        DetailsMenuActionWidget(
          onTap: () =>
              popup_media_actions.downloadOriginalAttachments(_buildActionContext(DetailsMenuAction.SaveOriginal)),
          action: DetailsMenuAction.SaveOriginal,
        ),
      if (showDownload && part.attachments.where((e) => e.hasLivePhoto).isNotEmpty)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.downloadLivePhoto(_buildActionContext(DetailsMenuAction.SaveLivePhoto)),
          action: DetailsMenuAction.SaveLivePhoto,
        ),
      if (chat.isGroup && !message.isFromMe! && dmChat != null && !LifecycleSvc.isBubble)
        DetailsMenuActionWidget(
          onTap: () => popup_navigation_actions.openDm(_buildActionContext(DetailsMenuAction.OpenDirectMessage)),
          action: DetailsMenuAction.OpenDirectMessage,
        ),
      if (message.threadOriginatorGuid != null ||
          service.struct.threads(message.guid!, part.part, returnOriginator: false).isNotEmpty)
        DetailsMenuActionWidget(
          onTap: () => popup_navigation_actions.showThread(_buildActionContext(DetailsMenuAction.ViewThread)),
          action: DetailsMenuAction.ViewThread,
        ),
      if (part.attachments.isNotEmpty || !isNullOrEmpty(part.text))
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.sharePart(_buildActionContext(DetailsMenuAction.Share)),
          action: DetailsMenuAction.Share,
        ),
      if (showDownload)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.redownload(_buildActionContext(DetailsMenuAction.ReDownloadFromServer)),
          action: DetailsMenuAction.ReDownloadFromServer,
        ),
      DetailsMenuActionWidget(
        onTap: () => popup_message_actions.remindLater(_buildActionContext(DetailsMenuAction.RemindLater)),
        action: DetailsMenuAction.RemindLater,
      ),
      if (!message.isFromMe! &&
          message.handleRelation.target != null &&
          message.handleRelation.target!.contactsV2.isEmpty)
        DetailsMenuActionWidget(
          onTap: () => popup_message_actions.createContact(_buildActionContext(DetailsMenuAction.CreateContact)),
          action: DetailsMenuAction.CreateContact,
        ),
      if (SettingsSvc.serverDetails.isMinVentura &&
          message.isFromMe! &&
          !widget.controller.isSending.value &&
          SettingsSvc.serverDetails.supportsEditAndUnsend)
        DetailsMenuActionWidget(
          onTap: () => popup_message_actions.unsend(_buildActionContext(DetailsMenuAction.UndoSend)),
          customTitle: canUnsend ? 'Undo Send' : 'Undo Send (too old)',
          shouldDisableBtn: !canUnsend,
          action: DetailsMenuAction.UndoSend,
        ),
      if (message.isFromMe! && widget.controller.isSending.value && OutgoingMsgHandler.hasPendingMessage(message.guid!))
        DetailsMenuActionWidget(
          onTap: () => popup_message_actions.cancelSend(_buildActionContext(DetailsMenuAction.CancelSend)),
          action: DetailsMenuAction.CancelSend,
        ),
      if (SettingsSvc.serverDetails.isMinVentura &&
          message.isFromMe! &&
          !widget.controller.isSending.value &&
          SettingsSvc.serverDetails.supportsEditAndUnsend &&
          (part.text?.isNotEmpty ?? false) &&
          // Its text holds a U+FFFC per Genmoji, which an edit would send as plain text
          !part.hasInlineAttachments)
        DetailsMenuActionWidget(
          onTap: () => popup_message_actions.edit(_buildActionContext(DetailsMenuAction.Edit)),
          customTitle: canEdit ? 'Edit' : 'Edit (too old)',
          shouldDisableBtn: !canEdit,
          action: DetailsMenuAction.Edit,
        ),
      if (!LifecycleSvc.isBubble && !message.isInteractive)
        DetailsMenuActionWidget(
          onTap: () => popup_navigation_actions.forward(_buildActionContext(DetailsMenuAction.Forward)),
          action: DetailsMenuAction.Forward,
        ),
      if (chat.isGroup && !message.isFromMe! && dmChat == null && !LifecycleSvc.isBubble)
        DetailsMenuActionWidget(
          onTap: () => popup_navigation_actions.newConvo(_buildActionContext(DetailsMenuAction.StartConversation)),
          action: DetailsMenuAction.StartConversation,
        ),
      if (!isNullOrEmptyString(part.fullText))
        DetailsMenuActionWidget(
          onTap: () => popup_text_actions.copySelection(_buildActionContext(DetailsMenuAction.CopySelection)),
          action: DetailsMenuAction.CopySelection,
        ),
      DetailsMenuActionWidget(
        onTap: () => popup_message_actions.delete(_buildActionContext(DetailsMenuAction.Delete)),
        action: DetailsMenuAction.Delete,
      ),
      DetailsMenuActionWidget(
        onTap: () => popup_message_actions.toggleBookmark(_buildActionContext(DetailsMenuAction.Bookmark)),
        action: DetailsMenuAction.Bookmark,
        customTitle: message.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
      ),
      DetailsMenuActionWidget(
        onTap: () => popup_message_actions.selectMultiple(_buildActionContext(DetailsMenuAction.SelectMultiple)),
        action: DetailsMenuAction.SelectMultiple,
      ),
      DetailsMenuActionWidget(
        onTap: () => popup_message_actions.messageInfo(_buildActionContext(DetailsMenuAction.MessageInfo)),
        action: DetailsMenuAction.MessageInfo,
      ),
      if (showRefreshPreview)
        DetailsMenuActionWidget(
          onTap: () => popup_media_actions.refreshPreview(_buildActionContext(DetailsMenuAction.RefreshPreview)),
          action: DetailsMenuAction.RefreshPreview,
        ),
    ].where((a) => a.action.isPlatformSupported).sorted((a, b) => SettingsSvc.settings.detailsMenuActions
        .indexOf(a.action)
        .compareTo(SettingsSvc.settings.detailsMenuActions.indexOf(b.action)));
  }

  Widget buildDetailsMenu(BuildContext context) {
    double maxMenuWidth =
        min(max(NavigationSvc.width(widthContext) * 3 / 5, 200), NavigationSvc.width(widthContext) * 4 / 5);

    List<DetailsMenuActionWidget> allActions = _allActions;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          color: context.theme.colorScheme.surfaceContainerHighest.withAlpha(150),
          width: maxMenuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: allActions.cast<CustomDetailsMenuActionWidget>().sublist(0, numberToShow - 1)
              ..add(
                CustomDetailsMenuActionWidget(
                  onTap: () async {
                    Widget content = Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: allActions.sublist(numberToShow - 1),
                    );
                    showBBDialog(
                      useRootNavigator: false,
                      context: context,
                      content: content,
                    );
                  },
                  title: 'More...',
                  iosIcon: cupertino.CupertinoIcons.ellipsis,
                  nonIosIcon: Icons.more_vert,
                ),
              ),
          ),
        ),
      ),
    );
  }

  Widget _buildMaterialTapbackPill(
    BuildContext context, {
    required bool narrowScreen,
    required bool emojiTapbacks,
    required String? ownEmoji,
    required List<String> tapbackItems,
    required double emojiRowMaxWidth,
  }) {
    if (currentlySelectedReaction == "init") {
      return const SizedBox(height: 52);
    }

    final colorScheme = context.theme.colorScheme;
    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: message.isFromMe! ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: List.generate(narrowScreen ? 2 : 1, (index) {
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: tapbackItems
              .slice(narrowScreen && index == 1 ? 3 : 0, narrowScreen && index == 0 ? 3 : null)
              .map((e) {
            final isEmoji = !ReactionTypes.toList().contains(e);
            final isSelected = isEmoji ? e == ownEmoji : currentlySelectedReaction == e;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AnimatedScale(
                scale: isSelected ? 1.12 : 1.0,
                duration: M3EMotion.spatialFast.duration,
                curve: M3EMotion.spatialOvershoot,
                child: AnimatedContainer(
                  duration: M3EMotion.effectsFast.duration,
                  curve: M3EMotion.effectsFast.curve,
                  decoration: BoxDecoration(
                    color: isSelected ? colorScheme.primaryContainer : Colors.transparent,
                    borderRadius: BorderRadius.circular(M3EShapes.xl),
                    border: isSelected ? Border.all(color: colorScheme.primary, width: 1.5) : null,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(M3EShapes.xl),
                      onTap: () async {
                        if (isEmoji) return _sendEmojiTapback(e);
                        setState(() {
                          currentlySelectedReaction = currentlySelectedReaction == e ? null : e;
                        });
                        HapticFeedback.lightImpact();
                        widget.sendTapback(selfReaction == e ? "-$e" : e, part.part);
                        popDetails();
                      },
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: isEmoji
                              ? _emojiTapbackGlyph(e)
                              : Builder(builder: (context) {
                                  final text = Text(
                                    ReactionTypes.reactionToEmoji[e] ?? "X",
                                    style: const TextStyle(fontSize: 20, fontFamily: 'Apple Color Emoji'),
                                    textAlign: TextAlign.center,
                                  );
                                  // rotate thumbs down to match iOS
                                  if (e == "dislike") {
                                    return Transform(
                                      transform: Matrix4.identity()..rotateY(pi),
                                      alignment: FractionalOffset.center,
                                      child: text,
                                    );
                                  }
                                  return text;
                                }),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
        if (!emojiTapbacks) return row;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: emojiRowMaxWidth),
          child: _fadeScrollEdges(SingleChildScrollView(scrollDirection: Axis.horizontal, child: row)),
        );
      }),
    );

    return Material(
      color: _hasCustomWallpaper
          ? colorScheme.surfaceContainerHigh.withValues(alpha: 0.94)
          : colorScheme.surfaceContainerHigh,
      elevation: 6,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(M3EShapes.xl),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            rows,
            if (emojiTapbacks) ...[
              Container(
                width: 1,
                height: 24,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
              Tooltip(
                message: 'More reactions',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(M3EShapes.xl),
                    onTap: _pickEmojiTapback,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.add_reaction_outlined, size: 22, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMaterialDockedToolbar(BuildContext context) {
    final List<DetailsMenuActionWidget> allActions = _allActions;
    if (allActions.isEmpty) return const SizedBox.shrink();

    final colorScheme = context.theme.colorScheme;
    final bool hasOverflow = allActions.length > 5;
    final List<DetailsMenuActionWidget> visibleActions = hasOverflow ? allActions.sublist(0, 4) : allActions;
    final List<DetailsMenuActionWidget> overflowActions =
        hasOverflow ? allActions.sublist(4) : const <DetailsMenuActionWidget>[];

    return Material(
      color: _hasCustomWallpaper
          ? colorScheme.surfaceContainerHigh.withValues(alpha: 0.94)
          : colorScheme.surfaceContainerHigh,
      elevation: 6,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(M3EShapes.xl),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            ...visibleActions.map((action) {
              final bool isDisabled = action.shouldDisableBtn ?? false;
              final Color itemColor = isDisabled
                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
                  : action.action == DetailsMenuAction.Delete
                      ? colorScheme.error
                      : colorScheme.onSurfaceVariant;
              return Expanded(
                child: Tooltip(
                  message: action.title,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(M3EShapes.lg),
                      onTap: isDisabled ? null : action.onTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(action.nonIosIcon, size: 22, color: itemColor),
                            const SizedBox(height: 4),
                            Text(
                              action.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: context.theme.textTheme.labelSmall?.copyWith(
                                color: itemColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
            if (overflowActions.isNotEmpty)
              Expanded(
                child: PopupMenuButton<int>(
                  tooltip: 'More actions',
                  color: _hasCustomWallpaper
                      ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.94)
                      : colorScheme.surfaceContainerHighest,
                  shape: const RoundedRectangleBorder(borderRadius: M3EShapes.radiusLg),
                  onSelected: (int index) {
                    final selected = overflowActions[index];
                    if (!(selected.shouldDisableBtn ?? false)) {
                      selected.onTap?.call();
                    }
                  },
                  itemBuilder: (context) {
                    return overflowActions.mapIndexed((index, action) {
                      final bool isDisabled = action.shouldDisableBtn ?? false;
                      final Color itemColor = isDisabled
                          ? colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
                          : action.action == DetailsMenuAction.Delete
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant;
                      return PopupMenuItem<int>(
                        value: index,
                        enabled: !isDisabled,
                        child: Row(
                          children: [
                            Icon(action.nonIosIcon, size: 20, color: itemColor),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                action.title,
                                style: context.textTheme.bodyMedium?.copyWith(color: itemColor),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.more_horiz, size: 22, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 4),
                        Text(
                          'More',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CircleClipper extends CustomClipper<Path> {
  const _CircleClipper();

  @override
  Path getClip(Size size) => Path()..addOval(Offset.zero & size);

  @override
  bool shouldReclip(_CircleClipper oldClipper) => false;
}

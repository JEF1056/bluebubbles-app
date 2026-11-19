import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/app/layouts/conversation_details/material/chat_detail_theme.dart';
import 'package:bluebubbles/app/layouts/conversation_details/material/material_chat_header.dart';
import 'package:bluebubbles/app/layouts/conversation_details/material/material_chat_options.dart';
import 'package:bluebubbles/app/layouts/conversation_details/material/material_participants_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/attachments_loader.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_info.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_options.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/participants_list.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/documents/documents_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/links/links_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/media/media_grid_section.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class TabletModeWrapper extends StatefulWidget {
  final Widget left;
  final Widget right;
  final double initialRatio;
  final double dividerWidth;
  final double minRatio;
  final double maxRatio;
  final bool allowResize;
  final double? minWidthLeft;
  final double? maxWidthLeft;
  final bool enableInspector;
  final VoidCallback? onNarrowTransition;
  final VoidCallback? onWideTransition;

  const TabletModeWrapper(
      {super.key,
      required this.left,
      required this.right,
      this.initialRatio = 0.5,
      this.allowResize = true,
      this.dividerWidth = 7.0,
      this.minRatio = 0,
      this.maxRatio = 0,
      this.minWidthLeft,
      this.maxWidthLeft,
      this.enableInspector = true,
      this.onNarrowTransition,
      this.onWideTransition})
      : assert(initialRatio >= 0),
        assert(initialRatio <= 1);

  @override
  State<TabletModeWrapper> createState() => _TabletModeWrapperState();
}

class _TabletModeWrapperState extends State<TabletModeWrapper> with ThemeHelpers {
  //from 0-1
  late final RxDouble _ratio;
  double? _maxWidth;
  bool? altLayoutCache;
  bool _preserveRightOneFrame = false;
  StreamSubscription? _eventSub;

  double get _width1 => max(
      min(_ratio * _maxWidth!, widget.maxWidthLeft ?? double.infinity), widget.minWidthLeft ?? double.negativeInfinity);

  double get _width2 => _maxWidth! - _width1;

  @override
  void initState() {
    super.initState();
    _ratio =
        RxDouble((PrefsSvc.desktop.getSplitRatio() ?? widget.initialRatio).clamp(widget.minRatio, widget.maxRatio));
    _eventSub = EventDispatcherSvc.stream.listen((event) {
      if (!mounted) return;
      if (event.type == 'split-refresh') {
        _ratio.value = PrefsSvc.desktop.getSplitRatio() ?? _ratio.value;
        setState(() {});
      } else if (event.type == 'override-split') {
        _ratio.value = event.data;
        setState(() {});
      }
    });
    debounce<double>(_ratio, (val) async {
      await PrefsSvc.desktop.setSplitRatio(val);
      EventDispatcherSvc.emit('split-refresh', null);
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  void _scheduleNarrowTransition() {
    if (widget.onNarrowTransition != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || showAltLayout) return;
        widget.onNarrowTransition!();
      });
      return;
    }
    if (ChatsSvc.activeChat == null) return;
    _preserveRightOneFrame = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || showAltLayout) {
        if (mounted && _preserveRightOneFrame) setState(() => _preserveRightOneFrame = false);
        return;
      }
      final active = ChatsSvc.activeChat?.chat;
      if (active != null && !NavigationSvc.hasNarrowChatRoute) {
        NavigationSvc.pushAndRemoveUntil(
          context,
          ConversationView(chat: active),
          (route) => route.isFirst,
          closeActiveChat: false,
        );
      }
      // Keep the nested pane mounted for one more frame so the root ConversationView
      // takes controller.viewOwner before the nested one disposes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _preserveRightOneFrame) {
          setState(() => _preserveRightOneFrame = false);
        }
      });
    });
  }

  void _scheduleWideTransition() {
    if (widget.onWideTransition != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !showAltLayout) return;
        widget.onWideTransition!();
      });
      return;
    }
    if (ChatsSvc.activeChat == null || !NavigationSvc.hasNarrowChatRoute) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !showAltLayout) return;
      final active = ChatsSvc.activeChat?.chat;
      if (active == null) return;
      await NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(chat: active),
        (route) => route.isFirst,
        closeActiveChat: false,
      );
      if (mounted) {
        NavigationSvc.removeNarrowChatRoute(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!showAltLayout) {
      if (altLayoutCache ?? false) {
        altLayoutCache = false;
        _scheduleNarrowTransition();
      }
      final leftPane = TitleBarWrapper(child: widget.left);
      if (_preserveRightOneFrame) {
        return Stack(
          children: [
            Positioned.fill(child: Offstage(offstage: true, child: widget.right)),
            leftPane,
          ],
        );
      }
      return leftPane;
    }
    if (altLayoutCache == false) {
      _scheduleWideTransition();
    }
    altLayoutCache = true;
    _preserveRightOneFrame = false;
    return LayoutBuilder(
      builder: (context, BoxConstraints constraints) {
        _maxWidth = constraints.maxWidth - widget.dividerWidth;
        final canShowInspector = widget.enableInspector && (kIsDesktop || kIsWeb) && constraints.maxWidth > 1024;
        return TitleBarWrapper(
          child: SizedBox(
            width: constraints.maxWidth,
            child: Obx(() {
              final activeGuid = canShowInspector ? ChatsSvc.activeChatGuid.value : null;
              final inspectorOpen = canShowInspector ? NavigationSvc.showInspectorDrawer.value : false;
              final activeChat = activeGuid != null ? ChatsSvc.activeChat?.chat : null;
              final showInspectorPane = canShowInspector && activeChat != null && inspectorOpen;
              final showInspectorToggle = canShowInspector && activeChat != null && !inspectorOpen;
              final inspectorReserved = showInspectorPane ? 321.0 : (showInspectorToggle ? 29.0 : 0.0);
              final rightWidth = max(0.0, _width2 - inspectorReserved);

              return Row(
                children: <Widget>[
                  SizedBox(
                    width: _width1,
                    child: widget.left,
                  ),
                  (widget.allowResize)
                      ? MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            child: Container(
                              color: context.theme.colorScheme.surfaceContainerHighest,
                              width: widget.dividerWidth,
                              height: constraints.maxHeight,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                      height: 4,
                                      width: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(25),
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      )),
                                  const SizedBox(height: 20),
                                  Container(
                                      height: 4,
                                      width: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(25),
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      )),
                                  const SizedBox(height: 20),
                                  Container(
                                      height: 4,
                                      width: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(25),
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      )),
                                ],
                              ),
                            ),
                            onPanUpdate: (DragUpdateDetails details) {
                              _ratio.value =
                                  (_ratio.value + (details.delta.dx / _maxWidth!)).clamp(widget.minRatio, widget.maxRatio);
                              NavigationSvc.listener.refresh();
                            },
                          ),
                        )
                      : Container(
                          width: widget.dividerWidth,
                          height: constraints.maxHeight,
                          color: context.theme.colorScheme.surfaceContainerHighest),
                  SizedBox(
                    width: rightWidth,
                    child: widget.right,
                  ),
                  if (showInspectorPane) ...[
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                    SizedBox(
                      width: 320,
                      height: constraints.maxHeight,
                      child: _ChatInspectorPane(
                        key: ValueKey(activeChat.guid),
                        chat: activeChat,
                        onClose: NavigationSvc.toggleInspectorDrawer,
                      ),
                    ),
                  ] else if (showInspectorToggle) ...[
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                    SizedBox(
                      width: 28,
                      height: constraints.maxHeight,
                      child: Material(
                        color: context.theme.colorScheme.surface,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              tooltip: 'Show chat details (Alt+I)',
                              icon: Icon(
                                Icons.chevron_left_rounded,
                                size: 18,
                                color: context.theme.colorScheme.onSurfaceVariant,
                              ),
                              onPressed: NavigationSvc.toggleInspectorDrawer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            }),
          ),
        );
      },
    );
  }
}

class _ChatInspectorPane extends StatefulWidget {
  const _ChatInspectorPane({
    super.key,
    required this.chat,
    required this.onClose,
  });

  final Chat chat;
  final VoidCallback onClose;

  @override
  State<_ChatInspectorPane> createState() => _ChatInspectorPaneState();
}

class _ChatInspectorPaneState extends State<_ChatInspectorPane> {
  List<Attachment> media = <Attachment>[];
  List<Attachment> docs = <Attachment>[];
  final RxList<String> selected = <String>[].obs;
  bool isLoadingAttachments = true;

  void _onAttachmentsLoaded(
    List<Attachment> loadedMedia,
    List<Attachment> loadedDocs,
    List<Attachment> _,
  ) {
    if (!mounted) return;
    setState(() {
      media = loadedMedia;
      docs = loadedDocs;
      isLoadingAttachments = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ChatsSvc.getOrCreateChatState(widget.chat);
    return ChatStateScope(
      chatState: chatState,
      child: Obx(() {
        final chatDetailTheme = ChatDetailTheme.resolve(context, widget.chat);
        final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;

        return Theme(
          data: chatDetailTheme.theme,
          child: Material(
            color: chatDetailTheme.theme.colorScheme.surface,
            child: Column(
              children: [
                Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: chatDetailTheme.headerColor,
                    border: Border(
                      bottom: BorderSide(
                        color: chatDetailTheme.theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Details',
                        style: chatDetailTheme.theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Hide chat details (Alt+I)',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: isIOS ? ChatInfo(chat: widget.chat) : ExpressiveChatHeader(chat: widget.chat),
                      ),
                      isIOS
                          ? ParticipantsList(chat: widget.chat)
                          : ExpressiveParticipantsSection(chat: widget.chat),
                      SliverToBoxAdapter(
                        child: AttachmentsLoader(
                          chat: widget.chat,
                          onAttachmentsLoaded: _onAttachmentsLoaded,
                        ),
                      ),
                      isIOS ? ChatOptions(chat: widget.chat) : ExpressiveChatOptions(chat: widget.chat),
                      MediaGridSection(
                        chat: widget.chat,
                        media: media,
                        selected: selected,
                        isLoading: isLoadingAttachments,
                      ),
                      LinksSection(chat: widget.chat),
                      DocumentsSection(
                        chat: widget.chat,
                        docs: docs,
                        isLoading: isLoadingAttachments,
                      ),
                      const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

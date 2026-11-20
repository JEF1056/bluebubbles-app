import 'dart:ui';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:collection/collection.dart';
import 'package:defer_pointer/defer_pointer.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

typedef RootReplyTarget = ({String? guid, Message? message, int part});

Message? _safeFindMessageByGuid(String guid) {
  try {
    return Message.findOne(guid: guid);
  } catch (_) {
    return null;
  }
}

/// Resolves the root thread originator and part index for [message].
///
/// Walks `threadOriginatorGuid` upward (with cycle protection) so replying to
/// a reply always attaches to the root thread originator and its target part.
RootReplyTarget resolveRootReplyTarget(
  Message message,
  int partIndex, {
  MessagesService? service,
  bool useDb = true,
}) {
  if (message.threadOriginatorGuid == null) {
    return (guid: message.guid, message: message, part: partIndex);
  }

  final visited = <String>{};
  if (message.guid != null) {
    visited.add(message.guid!);
  }

  Message current = message;
  String rootGuid = current.threadOriginatorGuid!;
  int rootPart = current.normalizedThreadPart;

  while (current.threadOriginatorGuid != null) {
    final parentGuid = current.threadOriginatorGuid!;
    rootGuid = parentGuid;
    rootPart = current.normalizedThreadPart;
    if (!visited.add(parentGuid)) {
      break;
    }

    final parent = service?.struct.getThreadOriginator(parentGuid) ??
        service?.struct.getMessage(parentGuid) ??
        (useDb ? _safeFindMessageByGuid(parentGuid) : null);
    if (parent == null) {
      return (guid: rootGuid, message: null, part: rootPart);
    }
    if (parent.threadOriginatorGuid == null || visited.contains(parent.threadOriginatorGuid)) {
      return (guid: parent.guid ?? rootGuid, message: parent, part: rootPart);
    }
    current = parent;
  }

  return (guid: rootGuid, message: null, part: rootPart);
}

/// Collects the full thread for [message] across [partIds] in chronological
/// order, including the root originator (when [includeOriginator] is true),
/// chained replies, and in-flight `temp-` replies.
List<Message> collectThreadMessages(
  Message message,
  Iterable<int> partIds,
  MessagesService service, {
  bool includeOriginator = true,
  bool useDb = true,
}) {
  final defaultPart = partIds.isEmpty ? 0 : partIds.first;
  final root = resolveRootReplyTarget(message, defaultPart, service: service, useDb: useDb);
  final rootGuid = root.guid;
  if (rootGuid == null) {
    return includeOriginator ? <Message>[message] : <Message>[];
  }

  final targetParts = message.threadOriginatorGuid != null ? <int>{root.part} : partIds.toSet();
  final byKey = <String, Message>{};

  void addMessage(Message m) {
    final key = m.guid ?? '${identityHashCode(m)}';
    byKey.putIfAbsent(key, () => m);
  }

  if (targetParts.isNotEmpty) {
    for (final m in service.struct.threadsForParts(rootGuid, targetParts, returnOriginator: includeOriginator)) {
      addMessage(m);
    }
  } else {
    for (final m in service.struct.threads(rootGuid, root.part, returnOriginator: includeOriginator)) {
      addMessage(m);
    }
  }

  // Also include in-flight temp- replies and chained replies from struct.messages
  // (in-memory only so build-time callers never trigger synchronous DB reads).
  for (final m in service.struct.messages) {
    if (m.associatedMessageGuid != null || m.threadOriginatorGuid == null) continue;
    if (m.threadOriginatorGuid == rootGuid) {
      if (targetParts.isEmpty || targetParts.contains(m.normalizedThreadPart)) {
        addMessage(m);
      }
      continue;
    }
    final mRoot = resolveRootReplyTarget(m, m.normalizedThreadPart, service: service, useDb: false);
    if (mRoot.guid == rootGuid && (targetParts.isEmpty || targetParts.contains(mRoot.part))) {
      addMessage(m);
    }
  }

  if (includeOriginator) {
    final originator = root.message ??
        service.struct.getThreadOriginator(rootGuid) ??
        service.struct.getMessage(rootGuid) ??
        (useDb ? _safeFindMessageByGuid(rootGuid) : null);
    if (originator != null) {
      addMessage(originator);
    }
  }

  final result = byKey.values.toList()..sort((a, b) => Message.sort(a, b, descending: false));
  return result;
}

String formatReplyCountLabel(int count) => "$count Repl${count == 1 ? 'y' : 'ies'}";

void showReplyThread(BuildContext context, Message message, MessagePart part, MessagesService service,
    ConversationViewController cvController) {
  final root = resolveRootReplyTarget(message, part.part, service: service);
  final originatorGuid = root.guid;
  final originatorPart = root.part;
  final partIds = message.threadOriginatorGuid != null ? <int>{originatorPart} : part.coveredPartIds.toSet();
  final initialMessages = collectThreadMessages(message, partIds, service);
  _buildThreadView(
    initialMessages,
    originatorPart,
    cvController,
    context,
    originatorGuid: originatorGuid,
    partIds: partIds,
    service: service,
    anchorMessage: message,
  );
}

void showBookmarksThread(ConversationViewController cvController, BuildContext context) async {
  final _messages = (Database.messages.query(Message_.isBookmarked.equals(true))
        ..link(Message_.chat, Chat_.guid.equals(cvController.chat.guid))
        ..order(Message_.dateCreated, flags: Order.descending))
      .build()
      .find();
  if (_messages.isEmpty) {
    return showSnackbar("Error", "There are no bookmarked messages in this chat!", type: SnackbarType.error);
  }
  for (Message m in _messages) {
    m.realAttachments;
    m.fetchAssociatedMessages();
  }
  _messages.sort((a, b) => Message.sort(a, b, descending: false));
  _buildThreadView(_messages, null, cvController, context);
}

void _buildThreadView(
  List<Message> initialMessages,
  int? originatorPart,
  ConversationViewController cvController,
  BuildContext context, {
  String? originatorGuid,
  Set<int> partIds = const <int>{},
  MessagesService? service,
  Message? anchorMessage,
}) {
  // Capture the conversation's theme before pushing the route — if adaptive
  // theming is active, context.theme is already the per-chat theme.
  final capturedTheme = context.theme;
  final capturedIsM3 = ThemeSvc.isMaterialYouActive(context);
  final capturedBubbleExt = capturedTheme.extensions[BubbleColors] as BubbleColors?;
  // Capture the ChatState so it can be re-provided inside the new route,
  // which has its own widget tree without a ChatStateScope.
  final capturedChatState = ChatsSvc.getOrCreateChatState(cvController.chat);
  Navigator.push(
    context,
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (routeCtx, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: ChatStateScope(
            chatState: capturedChatState,
            child: Theme(
              data: capturedTheme.copyWith(
                // in case some components still use legacy theming
                primaryColor: capturedBubbleExt?.iMessageBubbleColor ?? capturedTheme.colorScheme.primary,
                colorScheme: capturedTheme.colorScheme.copyWith(
                  primary: capturedBubbleExt?.iMessageBubbleColor ?? capturedTheme.colorScheme.primary,
                  onPrimary: capturedBubbleExt?.oniMessageBubbleColor ?? capturedTheme.colorScheme.onPrimary,
                  surface: capturedIsM3 ? null : capturedBubbleExt?.receivedBubbleColor,
                  onSurface: capturedIsM3 ? null : capturedBubbleExt?.onReceivedBubbleColor,
                ),
              ),
              child: DeferredPointerHandler(
                child: _ReplyThreadView(
                  initialMessages: initialMessages,
                  originatorPart: originatorPart,
                  cvController: cvController,
                  originatorGuid: originatorGuid,
                  partIds: partIds,
                  service: service,
                  anchorMessage: anchorMessage,
                ),
              ),
            ),
          ),
        );
      },
      fullscreenDialog: true,
      opaque: false,
    ),
  ).then((_) {
    if (kIsDesktop || kIsWeb) {
      cvController.focusNode.requestFocus();
    }
  });
}

class _ReplyThreadView extends StatefulWidget {
  const _ReplyThreadView({
    required this.initialMessages,
    required this.originatorPart,
    required this.cvController,
    this.originatorGuid,
    this.partIds = const <int>{},
    this.service,
    this.anchorMessage,
  });

  final List<Message> initialMessages;
  final int? originatorPart;
  final ConversationViewController cvController;
  final String? originatorGuid;
  final Set<int> partIds;
  final MessagesService? service;
  final Message? anchorMessage;

  @override
  State<_ReplyThreadView> createState() => _ReplyThreadViewState();
}

class _ReplyThreadViewState extends State<_ReplyThreadView> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  int _lastRenderedCount = 0;
  bool _hasText = false;
  bool _sending = false;

  bool get _isInteractiveThread => widget.originatorGuid != null && widget.service != null;

  @override
  void initState() {
    super.initState();
    _lastRenderedCount = widget.initialMessages.length;
    _textController.addListener(_onTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(jump: true));
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final nextHasText = _textController.text.trim().isNotEmpty;
    if (nextHasText != _hasText) {
      setState(() => _hasText = nextHasText);
    }
  }

  void _scrollToBottom({bool jump = false}) {
    if (!mounted || !_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (jump) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  List<Message> _resolveMessages() {
    if (!_isInteractiveThread) {
      return widget.initialMessages;
    }
    final service = widget.service!;
    // Observe reactive update triggers so incoming/outgoing/confirmed replies update live.
    final guid = widget.originatorGuid!;
    service.messageUpdateTrigger[guid];
    service.messageUpdateTrigger.length;
    service.getMessageStateIfExists(guid)?.threadReplyCount.value;

    final anchor = widget.anchorMessage ??
        service.struct.getThreadOriginator(guid) ??
        service.struct.getMessage(guid) ??
        widget.initialMessages.firstOrNull;
    if (anchor == null) {
      return widget.initialMessages;
    }
    final resolved = collectThreadMessages(anchor, widget.partIds, service);
    return resolved.isEmpty ? widget.initialMessages : resolved;
  }

  Future<void> _sendReply() async {
    if (!_isInteractiveThread || _sending) return;
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    _textController.clear();
    try {
      await widget.cvController.send(
        SendData(
          attachments: const [],
          text: text,
          subject: "",
          replyGuid: widget.originatorGuid,
          replyPart: widget.originatorPart ?? 0,
        ),
      );
      widget.service?.triggerMessageUpdate(widget.originatorGuid!);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _focusNode.requestFocus();
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    }
  }

  void _dismiss() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent ?? true) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
    final blurDisabled = kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled;

    Widget constrainDesktop(Widget child) {
      if (!kIsWeb && !kIsDesktop) return child;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: child,
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
      },
      child: Focus(
        autofocus: true,
        child: BBScaffold(
          backgroundColor: blurDisabled ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9) : Colors.transparent,
          safeAreaTop: false,
          safeAreaBottom: false,
          safeAreaLeft: false,
          safeAreaRight: false,
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismiss,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: blurDisabled ? 0 : 30,
                    sigmaY: blurDisabled ? 0 : 30,
                  ),
                  child: Container(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  ),
                ),
              ),
              SafeArea(
                left: false,
                right: false,
                child: Column(
                  children: [
                    if (_isInteractiveThread) constrainDesktop(_buildHeader(context, theme, isIOS)),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _dismiss,
                        child: Center(
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 5.0),
                            child: constrainDesktop(
                              _isInteractiveThread
                                  ? Obx(() => _buildMessageList(context, _resolveMessages()))
                                  : _buildMessageList(context, widget.initialMessages),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_isInteractiveThread) constrainDesktop(_buildComposer(context, theme, isIOS)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme, bool isIOS) {
    return Obx(() {
      final messages = _resolveMessages();
      final replyCount = messages.where((m) => m.threadOriginatorGuid != null).length;
      final title = replyCount > 0 ? formatReplyCountLabel(replyCount) : "Thread";

      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
        child: Row(
          children: [
            const SizedBox(width: 48),
            Expanded(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    textHeightBehavior: const TextHeightBehavior(
                      applyHeightToFirstAscent: true,
                      applyHeightToLastDescent: true,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close thread',
              onPressed: _dismiss,
              icon: Icon(
                isIOS ? CupertinoIcons.xmark_circle_fill : Icons.close,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildMessageList(BuildContext context, List<Message> messages) {
    if (messages.length != _lastRenderedCount) {
      final grew = messages.length > _lastRenderedCount;
      _lastRenderedCount = messages.length;
      if (grew) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: messages.mapIndexed((index, e) {
        final messageHolder = MessageHolder(
          cvController: widget.cvController,
          message: messages[index],
          oldMessage: index > 0 ? messages[index - 1] : null,
          newMessage: index < messages.length - 1 ? messages[index + 1] : null,
          isReplyThread: true,
          replyPart: index == 0 ? widget.originatorPart : null,
        );

        // Interactive reply threads keep bubbles interactive (links, selection, taps) while preventing background dismiss.
        if (_isInteractiveThread) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: messageHolder,
          );
        }

        return GestureDetector(
          onTap: () {
            _dismiss();
            if (widget.originatorPart == null && SettingsSvc.settings.skin.value == Skins.iOS) {
              // pop twice to remove convo details page
              Navigator.of(context).pop();
            }
            if (e.guid != null) {
              MessagesSvc(widget.cvController.chat.guid).jumpToMessage.call(e.guid!);
            }
          },
          child: AbsorbPointer(
            absorbing: true,
            child: messageHolder,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildComposer(BuildContext context, ThemeData theme, bool isIOS) {
    final canSend = _hasText && !_sending;
    final fillColor = isIOS
        ? theme.colorScheme.surface.withValues(alpha: 0.92)
        : theme.colorScheme.surfaceContainerHigh;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                alignment: Alignment.centerLeft,
                constraints: const BoxConstraints(minHeight: 40),
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(isIOS ? 22 : 24),
                  border: isIOS
                      ? Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65), width: 1)
                      : null,
                ),
                child: Focus(
                  skipTraversal: true,
                  onKeyEvent: (node, event) {
                    if ((kIsWeb || kIsDesktop) &&
                        event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
                      final hw = HardwareKeyboard.instance;
                      if (!hw.isShiftPressed && !hw.isControlPressed && !hw.isMetaPressed && !hw.isAltPressed) {
                        _sendReply();
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: (kIsWeb || kIsDesktop) ? TextInputAction.newline : TextInputAction.send,
                    textAlignVertical: TextAlignVertical.center,
                    onSubmitted: (kIsWeb || kIsDesktop) ? null : (_) => _sendReply(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.25,
                      leadingDistribution: TextLeadingDistribution.even,
                      color: theme.colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: isIOS ? 'Reply in thread...' : 'Reply...',
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.25,
                        leadingDistribution: TextLeadingDistribution.even,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Material(
                color: canSend ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: canSend ? _sendReply : null,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: Center(
                      child: Icon(
                        isIOS ? CupertinoIcons.arrow_up : Icons.send_rounded,
                        size: 19,
                        color: canSend ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
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

import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:collection/collection.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/buttons/text_field_button.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/open_pigeon_view.dart';
import 'package:bluebubbles/app/components/custom/custom_bouncing_scroll_physics.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/dialogs/custom_mention_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/attachment_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/desktop_attachment_menu.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/emoji_picker_popover.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/gmsg_camera_gallery_sheet.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/text_field_attachment_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/formatting_bar.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/picked_attachments_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/reply_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_effect_overlay.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_effect_picker.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/html_runs.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_fork_widgets.dart' as fork;

export 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_fork_widgets.dart'
    show NativeSpeechDictation, hintTextForService;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';
import 'package:universal_io/io.dart';
import 'handlers/emoji_autocomplete_handler.dart';
import 'handlers/mention_autocomplete_handler.dart';
import 'handlers/keyboard_shortcut_handler.dart';
import 'handlers/clipboard_paste_handler.dart';
import 'handlers/web_input_interop.dart';

class TextFieldComponent extends StatefulWidget {
  const TextFieldComponent({
    super.key,
    this.subjectTextController,
    required this.textController,
    required this.controller,
    required this.recorderController,
    required this.sendMessage,
    this.audioRecorder,
    this.focusNode,
    this.initialAttachments = const [],
    this.alwaysShowSend = false,
    this.hideMediaPicker = false,
    this.hintText,
  });

  final SpellCheckTextEditingController? subjectTextController;
  final MentionTextEditingController textController;
  final ConversationViewController? controller;
  final RecorderController? recorderController;
  final AudioRecorder? audioRecorder;
  final Future<void> Function({String? effect}) sendMessage;
  final FocusNode? focusNode;

  final List<PlatformFile> initialAttachments;

  /// When true the send button is always shown even with no text/attachments.
  /// Used by the chat creator when an existing chat has been resolved.
  final bool alwaysShowSend;

  /// When true, the camera, attachment picker, and GIF icons are hidden.
  /// Used by the chat creator when no existing chat has been matched yet.
  final bool hideMediaPicker;

  /// Overrides the placeholder, e.g. for the chat creator to name the service it will send with.
  final String? hintText;

  @override
  State<StatefulWidget> createState() => TextFieldComponentState();
}

class TextFieldComponentState extends State<TextFieldComponent> {
  late ConversationViewController? controller;
  late final FocusNode? focusNode;
  late final RecorderController? recorderController;
  late final List<PlatformFile> initialAttachments;
  late final MentionTextEditingController textController;
  late final SpellCheckTextEditingController? subjectTextController;
  late final Future<void> Function({String? effect}) sendMessage;

  late final ValueNotifier<bool> isRecordingNotifier;
  EmojiAutocompleteHandler? emojiHandler;
  MentionAutocompleteHandler? mentionHandler;
  KeyboardShortcutHandler? keyboardHandler;
  ClipboardPasteHandler? clipboardHandler;
  StreamSubscription<void>? _webPasteSub;
  Worker? _recordingWorker;

  TextFieldComponentState() : isRecordingNotifier = ValueNotifier<bool>(false);

  void _updateRecordingState() {
    isRecordingNotifier.value =
        (controller?.showRecording.value ?? false) || (recorderController?.isRecording ?? false);
  }

  @override
  void initState() {
    super.initState();
    controller = widget.controller;
    focusNode = widget.focusNode;
    recorderController = widget.recorderController;
    initialAttachments = widget.initialAttachments;
    textController = widget.textController;
    subjectTextController = widget.subjectTextController;
    sendMessage = widget.sendMessage;

    recorderController?.addListener(_updateRecordingState);

    _configureHandlers();
    _fieldFocusNode = controller?.focusNode ?? focusNode;
    _fieldFocusNode?.addListener(_onFieldFocusChange);
    if (kIsWeb) {
      _webPasteSub = listenWebPaste(
        shouldHandle: () =>
            mounted &&
            ((_fieldFocusNode?.hasFocus ?? false) || (controller?.subjectFocusNode.hasFocus ?? false)),
        onFiles: (files) {
          if (!mounted) return;
          clipboardHandler?.handleWebPastedFiles(files);
        },
      );
    }

    assert(!(subjectTextController == null &&
        !isChatCreator &&
        SettingsSvc.settings.enablePrivateAPI.value &&
        SettingsSvc.settings.privateSubjectLine.value &&
        chat!.isIMessage));
  }

  FocusNode? _fieldFocusNode;

  /// The formatting panel and the chat creator's attachment picker both stand in for the keyboard: the panel goes
  /// when the field loses focus, and focusing the field closes the picker
  void _onFieldFocusChange() {
    if (!_fieldFocusNode!.hasFocus) controller?.showTextFormattingPanel.value = false;
    if (_fieldFocusNode!.hasFocus && _showAttachmentPickerLocal) setState(() => _showAttachmentPickerLocal = false);
  }

  @override
  void dispose() {
    _webPasteSub?.cancel();
    _recordingWorker?.dispose();
    recorderController?.removeListener(_updateRecordingState);
    _fieldFocusNode?.removeListener(_onFieldFocusChange);
    // dispose of the ValueNotifier when the state is disposed
    isRecordingNotifier.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TextFieldComponent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      controller = widget.controller;
      _configureHandlers();
    }
  }

  void _configureHandlers() {
    _recordingWorker?.dispose();
    _recordingWorker = null;
    final ctrl = controller;
    clipboardHandler = ClipboardPasteHandler(controller: ctrl, textController: ctrl?.textController ?? textController);
    if (ctrl == null) {
      emojiHandler = null;
      mentionHandler = null;
      keyboardHandler = null;
      _updateRecordingState();
      return;
    }

    _updateRecordingState();
    _recordingWorker = ever(ctrl.showRecording, (_) => _updateRecordingState());

    emojiHandler = EmojiAutocompleteHandler(controller: ctrl, textField: textController);
    mentionHandler = MentionAutocompleteHandler(controller: ctrl, textField: textController);
    keyboardHandler = KeyboardShortcutHandler(
      controller: ctrl,
      sendMessage: sendMessage,
      subjectTextController: subjectTextController ?? textController,
      messageTextController: textController,
      isChatCreator: focusNode != null,
    );
  }

  bool get iOS => SettingsSvc.settings.skin.value == Skins.iOS;

  bool get material => SettingsSvc.settings.skin.value == Skins.Material;

  bool get samsung => SettingsSvc.settings.skin.value == Skins.Samsung;

  Chat? get chat => controller?.chat;

  bool get isChatCreator => focusNode != null;

  static String hintTextForService({
    required bool material,
    required bool isRCS,
    required bool isIMessage,
  }) =>
      fork.hintTextForService(
        material: material,
        isRCS: isRCS,
        isIMessage: isIMessage,
      );

  String _hintText(bool isRecording) {
    if (widget.hintText != null) return widget.hintText!;
    if (isChatCreator) return material ? "Text message" : "New Message";
    if (isRecording) return "";
    final currentChat = chat;
    if (currentChat == null) return material ? "Text message" : "iMessage";
    if (SettingsSvc.settings.recipientAsPlaceholder.value) {
      return ChatsSvc.getChatState(currentChat.guid)?.title.value ?? currentChat.getTitle();
    }
    return hintTextForService(
      material: material,
      isRCS: currentChat.isRCS,
      isIMessage: currentChat.isIMessage,
    );
  }

  bool _showAttachmentPickerLocal = false;
  bool _pasteHandledOnKeyDown = false;
  final _fieldKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final txtController = controller?.textController ?? textController;
    final subjController = controller?.subjectTextController ?? subjectTextController;
    final showIcons = isChatCreator && !widget.hideMediaPicker && controller != null;
    // Captured here because contextMenuBuilder receives its own `context` that shadows this
    // one and may not have the dark theme properly applied (it's a detached overlay context).
    final outerTheme = Theme.of(context);
    Widget focusWidget = Focus(
      onKeyEvent: (node, ev) => handleKey(node, ev, context, isChatCreator),
      child: ValueListenableBuilder<bool>(
          valueListenable: isRecordingNotifier,
          builder: (context, isRecording, child) {
            final chatState = chat != null ? ChatsSvc.getChatState(chat!.guid) : null;
            Widget buildPill(bool hasBackground) => Container(
              // Border is placed in the foregroundDecoration so it paints on top of
              // child content (ReplyHolder, attachments, etc.) and remains visible
              // at all corners instead of being covered by opaque children.
              foregroundDecoration: iOS
                  ? BoxDecoration(
                      border: Border.fromBorderSide(BorderSide(
                        color: (isRecording && iOS)
                            ? context.theme.colorScheme.primary.withValues(alpha: 1.0)
                            : context.theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
                        width: 1,
                      )),
                      borderRadius: BorderRadius.circular(20),
                    )
                  : null,
              decoration: BoxDecoration(
                color: (!iOS || hasBackground)
                    ? (iOS
                            ? context.theme.colorScheme.surfaceContainerHighest
                            : context.theme.colorScheme.surfaceContainerHigh)
                        .withValues(alpha: hasBackground ? 0.86 : 1.0)
                    : null,
                borderRadius: BorderRadius.circular(iOS ? 20 : (kIsWeb && material ? 26 : 28)),
              ),
              clipBehavior: Clip.antiAlias,
              // Fills its width so only height animates: the Stack above loosens it, and an animated width trailed the
              // buttons beside it. The TextField inside already needs a bounded width
              child: SizedBox(
                width: double.infinity,
                child: LayoutBuilder(builder: (context, pillConstraints) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.controller != null) ComposerSuggestions(controller: widget.controller!),
                      Flexible(
                        fit: FlexFit.loose,
                        child: SingleChildScrollView(
                          reverse: true,
                          physics: const ClampingScrollPhysics(),
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 250),
                            alignment: Alignment.bottomCenter,
                            curve: Curves.easeOut,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.controller != null) ReplyHolder(controller: widget.controller!),
                    if (initialAttachments.isNotEmpty || !isChatCreator || widget.controller != null)
                      PickedAttachmentsHolder(
                        controller: widget.controller,
                        textController: txtController,
                        initialAttachments: initialAttachments,
                      ),
                    if (widget.controller != null) OpenPigeonPendingGame(controller: widget.controller!),
                    FormattingBar(
                      controller: txtController,
                      focusNode: (controller?.focusNode ?? focusNode)!,
                      conversation: controller,
                    ),
                    if (!isChatCreator)
                      Obx(() {
                        if (controller!.pickedAttachments.isNotEmpty && iOS) {
                          return Divider(
                            height: 1.5,
                            thickness: 1.5,
                            color: context.theme.colorScheme.surfaceContainerHighest,
                          );
                        }
                        return const SizedBox.shrink();
                      }),
                    if (!isChatCreator &&
                        SettingsSvc.settings.enablePrivateAPI.value &&
                        SettingsSvc.settings.privateSubjectLine.value &&
                        chat!.isIMessage)
                      TextField(
                        textCapitalization: TextCapitalization.sentences,
                        focusNode: controller!.subjectFocusNode,
                        autocorrect: true,
                        controller: subjController,
                        scrollPhysics: const CustomBouncingScrollPhysics(),
                        textAlignVertical: iOS ? null : TextAlignVertical.center,
                        style: context.theme.extension<BubbleText>()!.bubbleText.copyWith(
                              fontSize: material ? 14.0 : null,
                              fontWeight: FontWeight.bold,
                              leadingDistribution: !iOS ? TextLeadingDistribution.even : null,
                            ),
                        keyboardType: TextInputType.multiline,
                        maxLines: 14,
                        minLines: 1,
                        enableSuggestions: true,
                        enableIMEPersonalizedLearning: !SettingsSvc.settings.incognitoKeyboard.value,
                        textInputAction: TextInputAction.next,
                        cursorColor: context.theme.colorScheme.primary,
                        cursorHeight: (material ? 14.0 : context.theme.extension<BubbleText>()!.bubbleText.fontSize!) * 1.25,
                        decoration: InputDecoration(
                          contentPadding: iOS && !kIsDesktop && !kIsWeb
                              ? const EdgeInsets.all(10)
                              : (material
                                  ? const EdgeInsets.fromLTRB(16, 8, 16, 8)
                                  : const EdgeInsets.all(12.5)),
                          isDense: true,
                          isCollapsed: true,
                          hintText: "Subject",
                          enabledBorder: InputBorder.none,
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          fillColor: Colors.transparent,
                          hintStyle: context.theme
                              .extension<BubbleText>()!
                              .bubbleText
                              .copyWith(
                                  fontSize: material ? 14.0 : null,
                                  color: material
                                      ? context.theme.colorScheme.onSurfaceVariant
                                      : context.theme.colorScheme.outline,
                                  fontWeight: FontWeight.bold,
                                  leadingDistribution: !iOS ? TextLeadingDistribution.even : null),
                          suffixIconConstraints: const BoxConstraints(minHeight: 0),
                        ),
                        onTap: () {
                          HapticFeedback.selectionClick();
                        },
                        onSubmitted: (String value) {
                          controller?.subjectFocusNode.requestFocus();
                        },
                        contentInsertionConfiguration:
                            ContentInsertionConfiguration(onContentInserted: onContentCommit),
                      ),
                    if (!isChatCreator &&
                        SettingsSvc.settings.enablePrivateAPI.value &&
                        SettingsSvc.settings.privateSubjectLine.value &&
                        chat!.isIMessage &&
                        (iOS || material))
                      iOS
                          ? Divider(
                              height: 1.5,
                              thickness: 1.5,
                              indent: 10,
                              color: context.theme.colorScheme.surfaceContainerHighest,
                            )
                          : Divider(
                              height: 1,
                              thickness: 1,
                              indent: 16,
                              endIndent: 16,
                              color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                            ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    Obx(() {
                      final baseBubbleText = context.theme.extension<BubbleText>()!.bubbleText;
                      final effectiveBodyStyle = material
                          ? baseBubbleText.copyWith(fontSize: 16.0, leadingDistribution: TextLeadingDistribution.even)
                          : (!iOS
                              ? baseBubbleText.copyWith(leadingDistribution: TextLeadingDistribution.even)
                              : baseBubbleText);
                      final fontSize = effectiveBodyStyle.fontSize ?? 16.0;
                      final lineHeight = MediaQuery.textScalerOf(context).scale(
                        fontSize * (effectiveBodyStyle.height ?? 1.4),
                      );
                      final hasUpperContent = (!isChatCreator &&
                              controller != null &&
                              (controller!.pickedAttachments.isNotEmpty ||
                                  controller!.pendingGame.value != null ||
                                  controller!.replyToMessage != null ||
                                  (SettingsSvc.settings.enablePrivateAPI.value &&
                                      SettingsSvc.settings.privateSubjectLine.value &&
                                      (chat?.isIMessage ?? false)))) ||
                          initialAttachments.isNotEmpty;
                      final verticalChrome = (iOS && !kIsDesktop && !kIsWeb ? 10.0 : (material ? 8.0 : 13.0)) * 2 + 4.0;
                      final int bodyMaxLines;
                      if (pillConstraints.hasBoundedHeight) {
                        final budget = pillConstraints.maxHeight * (hasUpperContent ? 0.5 : 0.95);
                        bodyMaxLines = ((budget - verticalChrome) / lineHeight).floor().clamp(1, 14);
                      } else {
                        bodyMaxLines = 14;
                      }
                      final useBottomAlignedRow = material && !isChatCreator && controller != null;
                      final field = TextField(
                        textCapitalization: TextCapitalization.sentences,
                        focusNode: controller?.focusNode ?? focusNode,
                        autocorrect: true,
                        controller: txtController,
                        scrollPhysics: const CustomBouncingScrollPhysics(),
                        textAlignVertical: iOS ? null : TextAlignVertical.center,
                        style: effectiveBodyStyle,
                        keyboardType: TextInputType.multiline,
                        // With the formatting panel up, selection changes would otherwise bring the keyboard back.
                        // Turning it off again (a tap closes the panel) reopens the input, and the keyboard with it.
                        readOnly: controller?.showTextFormattingPanel.value ?? false,
                        maxLines: bodyMaxLines,
                        minLines: 1,
                        autofocus: (kIsWeb || kIsDesktop) && !isChatCreator,
                        enableSuggestions: true,
                        enableIMEPersonalizedLearning: !SettingsSvc.settings.incognitoKeyboard.value,
                        textInputAction: SettingsSvc.settings.sendWithReturn.value && !kIsWeb && !kIsDesktop
                            ? TextInputAction.send
                            : TextInputAction.newline,
                        cursorColor: context.theme.colorScheme.primary,
                        cursorHeight: fontSize * 1.25,
                        decoration: InputDecoration(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: iOS ? 10 : (useBottomAlignedRow ? 4 : 16),
                            vertical: iOS && !kIsDesktop && !kIsWeb ? 10 : (material ? 8 : 13),
                          ),
                          isDense: true,
                          isCollapsed: true,
                          hintText: _hintText(isRecording),
                          enabledBorder: InputBorder.none,
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: (isRecording && iOS),
                          fillColor: (isRecording && iOS)
                              ? context.theme.colorScheme.primary.withValues(alpha: 0.16)
                              : Colors.transparent,
                          hintStyle: effectiveBodyStyle.copyWith(
                            color: material
                                ? context.theme.colorScheme.onSurfaceVariant
                                : context.theme.colorScheme.outline,
                          ),
                          suffixIconConstraints: useBottomAlignedRow
                              ? null
                              : BoxConstraints(minHeight: iOS ? 0 : 48),
                          suffixIcon: useBottomAlignedRow
                              ? null
                              : samsung && !isChatCreator
                                  ? null
                                  : Padding(
                                      padding: EdgeInsets.only(right: iOS ? 0.0 : 4.0),
                                      child: TextFieldSuffix(
                                        subjectTextController: subjController,
                                        textController: txtController,
                                        controller: controller,
                                        recorderController: recorderController,
                                        audioRecorder: widget.audioRecorder,
                                        sendMessage: sendMessage,
                                        isChatCreator: isChatCreator,
                                        alwaysShowSend: widget.alwaysShowSend,
                                        hasInitialAttachments: initialAttachments.isNotEmpty,
                                      ),
                                    ),
                        ),
                        contextMenuBuilder: (BuildContext context, EditableTextState editableTextState) {
                          final selection = editableTextState.textEditingValue.selection;
                          final touching = txtController.mentionRuns
                              .where((r) => r.range[0] <= selection.end && r.range[0] + r.range[1] >= selection.start)
                              .toList();
                          final mention = touching.length == 1 ? touching.single : null;

                          final items = [
                            // Mention actions first: what doesn't fit goes to the overflow menu at the end
                            if (mention != null) ...[
                                ContextMenuButtonItem(
                                  onPressed: () {
                                    txtController.removeMention(mention);
                                    editableTextState.hideToolbar();
                                  },
                                  label: "Remove Mention",
                                ),
                                ContextMenuButtonItem(
                                  onPressed: () async {
                                    // The toolbar's own context dies with the toolbar once the dialog takes focus
                                    editableTextState.hideToolbar();
                                    if (kIsDesktop || kIsWeb) {
                                      controller?.showingOverlays = true;
                                    }
                                    final current = txtController.text
                                        .substring(mention.range[0], mention.range[0] + mention.range[1]);
                                    final changed = await showCustomMentionDialog(
                                        this.context, txtController.mentionableFor(mention),
                                        initial: current);
                                    if (kIsDesktop || kIsWeb) {
                                      controller?.showingOverlays = false;
                                    }
                                    // The run may have shifted while the dialog was open
                                    final live = txtController.mentionRuns.firstWhereOrNull((r) =>
                                        r.attributes?.mention == mention.attributes?.mention &&
                                        txtController.text.substring(r.range[0], r.range[0] + r.range[1]) == current);
                                    if (!isNullOrEmpty(changed) && live != null) txtController.renameMention(live, changed!);
                                  },
                                  label: "Custom Mention",
                                ),
                              ],
                            for (final item in editableTextState.contextMenuButtonItems)
                              item.type == ContextMenuButtonType.copy || item.type == ContextMenuButtonType.cut
                                  ? item.copyWith(onPressed: () {
                                      txtController.rememberSelection();
                                      item.onPressed?.call();
                                    })
                                  : item,
                            if (!kIsDesktop && !kIsWeb && controller != null && txtController.allowFormatting)
                              ContextMenuButtonItem(
                                onPressed: () {
                                  editableTextState.hideToolbar();
                                  openTextFormattingPanel(controller!);
                                },
                                label: "Text Effects",
                              ),
                          ];

                          // The stock paste item only exists when the clipboard has text, and only pastes text.
                          // Replace it (or add one) with our handler, which handles media and falls back to text.
                          if (kIsDesktop || kIsWeb) {
                            final pasteItem = ContextMenuButtonItem(
                              type: ContextMenuButtonType.paste,
                              onPressed: () {
                                clipboardHandler?.handlePasteEvent();
                                editableTextState.hideToolbar();
                              },
                            );
                            final pasteIndex =
                                items.indexWhere((item) => item.type == ContextMenuButtonType.paste);
                            if (pasteIndex == -1) {
                              items.add(pasteItem);
                            } else {
                              items[pasteIndex] = pasteItem;
                            }
                          } else {
                            final pasteIndex =
                                items.indexWhere((item) => item.type == ContextMenuButtonType.paste);
                            if (pasteIndex != -1) {
                              items[pasteIndex] = ContextMenuButtonItem(
                                type: ContextMenuButtonType.paste,
                                onPressed: () async {
                                  editableTextState.hideToolbar();
                                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                                  if (data?.text == null) return;
                                  final html = await clipboardHtml();
                                  txtController.pasteText(
                                    data!.text!,
                                    htmlRuns: html == null ? const [] : htmlRuns(html, data.text!),
                                  );
                                },
                              );
                            }
                          }

                          final toolbar = AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems: items,
                          );

                          // Use outerTheme (captured from the real build context) because the
                          // contextMenuBuilder's own `context` parameter shadows the build context
                          // and may not have the dark theme applied (it's a detached overlay context).
                          return Theme(
                            data: outerTheme.copyWith(
                              cardColor: outerTheme.colorScheme.surfaceContainerHighest,
                              colorScheme: outerTheme.colorScheme.copyWith(
                                surface: outerTheme.colorScheme.surfaceContainerHighest,
                              ),
                            ),
                            child: toolbar,
                          );
                        },
                        onTap: () {
                          HapticFeedback.selectionClick();
                          // The field brings the keyboard back on a tap, in the panel's place
                          controller?.showTextFormattingPanel.value = false;
                        },
                        onSubmitted: (String value) {
                          controller?.focusNode.requestFocus();
                          if (isNullOrEmpty(value) &&
                              (controller?.pickedAttachments.isEmpty ?? false) &&
                              controller?.pendingGame.value == null) {
                            return;
                          }
                          sendMessage.call();
                        },
                        contentInsertionConfiguration:
                            ContentInsertionConfiguration(onContentInserted: onContentCommit),
                      );
                      final fieldStack = Stack(
                        children: [
                          KeyedSubtree(key: _fieldKey, child: field),
                          Positioned.fill(
                            child: TextEffectOverlay(
                              controller: txtController,
                              fieldKey: _fieldKey,
                              style: effectiveBodyStyle,
                            ),
                          ),
                        ],
                      );
                      if (!useBottomAlignedRow) return fieldStack;
                      // Keep inline Material actions bottom-aligned with the external Send button
                      // when the composer expands onto multiple lines (InputDecoration centers them).
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SizedBox(
                            height: 56,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(start: 4.0),
                                child: (kIsDesktop || kIsWeb)
                                    ? DesktopAttachmentMenu(
                                        controller: controller!,
                                        inRow: SettingsSvc.settings.textFieldButtons,
                                        builder: (_, toggle) => IconButton(
                                          tooltip: 'Add attachment',
                                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                          padding: EdgeInsets.zero,
                                          icon: Icon(
                                            Icons.add_circle_outline,
                                            color: context.theme.colorScheme.onSurfaceVariant,
                                            size: 24,
                                          ),
                                          onPressed: toggle,
                                        ),
                                      )
                                    : Obx(() {
                                        final isOpen = controller!.showAttachmentPicker.value;
                                        return IconButton(
                                          tooltip: isOpen ? 'Close attachments' : 'Add attachment',
                                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                          padding: EdgeInsets.zero,
                                          icon: isOpen
                                              ? Container(
                                                  width: 28,
                                                  height: 28,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: context.theme.colorScheme.surfaceContainerHighest,
                                                  ),
                                                  child: Icon(
                                                    Icons.close_rounded,
                                                    color: context.theme.colorScheme.onSurfaceVariant,
                                                    size: 18,
                                                  ),
                                                )
                                              : Icon(
                                                  Icons.add_circle_outline,
                                                  color: context.theme.colorScheme.onSurfaceVariant,
                                                  size: 24,
                                                ),
                                          onPressed: () {
                                            if (!isOpen) {
                                              controller!.focusNode.unfocus();
                                              controller!.subjectFocusNode.unfocus();
                                            } else {
                                              controller!.showGenmojiLibrary.value = false;
                                            }
                                            controller!.showAttachmentPicker.value = !isOpen;
                                          },
                                        );
                                      }),
                              ),
                            ),
                          ),
                          Expanded(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 56),
                              child: Center(child: fieldStack),
                            ),
                          ),
                          SizedBox(
                            height: 56,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(end: 4.0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (kIsWeb || kIsDesktop)
                                      Builder(
                                        builder: (buttonContext) => IconButton(
                                          tooltip: 'Emoji',
                                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                          padding: EdgeInsets.zero,
                                          icon: Icon(
                                            Icons.emoji_emotions_outlined,
                                            color: context.theme.colorScheme.onSurfaceVariant,
                                            size: 24,
                                          ),
                                          onPressed: () => showEmojiPickerPopover(buttonContext, controller!),
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: 'Gallery',
                                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                      padding: EdgeInsets.zero,
                                      icon: Icon(
                                        Icons.image_outlined,
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                        size: 24,
                                      ),
                                      onPressed: () {
                                        if (kIsDesktop || kIsWeb) {
                                          AttachmentActions.pickFiles(controller!);
                                        } else {
                                          controller!.focusNode.unfocus();
                                          controller!.subjectFocusNode.unfocus();
                                          controller!.showAttachmentPicker.value = false;
                                          showGmsgCameraGallerySheet(context, controller!);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                );
              }),
            ),
          );
            return chatState != null ? Obx(() => buildPill(chatState.hasCustomWallpaper)) : buildPill(false);
          }),
    );
    // On Windows, wrap with Shortcuts/Actions to intercept Ctrl+V on KeyDown.
    // This prevents Win+V (clipboard history) from double-firing a paste.
    Widget textInput;
    if (!kIsWeb && Platform.isWindows) {
      textInput = Shortcuts(
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.keyV, control: true, includeRepeats: false): const _PasteIntent(),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true, includeRepeats: false):
              const _PasteIntent(plain: true),
        },
        child: Actions(
          actions: {
            _PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (intent) {
              _pasteHandledOnKeyDown = true;
              clipboardHandler?.handlePasteEvent(plain: intent.plain);
              return null;
            }),
          },
          child: focusWidget,
        ),
      );
    } else {
      textInput = focusWidget;
    }
    if (!showIcons) return textInput;
    return LayoutBuilder(builder: (context, constraints) {
      final maxPickerHeight = constraints.hasBoundedHeight
          ? math.max(0.0, constraints.maxHeight - 72.0)
          : null;
      Widget pickerChild = _showAttachmentPickerLocal
          ? AttachmentPicker(controller: controller!)
          : SizedBox(width: NavigationSvc.width(context));
      if (maxPickerHeight != null && _showAttachmentPickerLocal) {
        pickerChild = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxPickerHeight),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: pickerChild,
          ),
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: Builder(builder: (context) {
                  Widget button(VoidCallback onPressed) => IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: iOS
                              ? context.theme.colorScheme.outline.withValues(alpha: 0.2)
                              : context.theme.colorScheme.surfaceContainerHigh,
                          shape: const CircleBorder(),
                          padding: EdgeInsets.zero,
                          minimumSize: iOS ? const Size(36, 36) : const Size(48, 48),
                          fixedSize: iOS ? const Size(36, 36) : const Size(48, 48),
                        ),
                        icon: Icon(
                          Icons.add,
                          color: iOS ? context.theme.colorScheme.outline : context.theme.colorScheme.onSurfaceVariant,
                          size: iOS ? 22 : 24,
                        ),
                        visualDensity: iOS && Platform.isAndroid ? VisualDensity.compact : null,
                        onPressed: onPressed,
                      );
                  // Desktop and web have no attachment sheet: `+` opens a menu of the same actions instead.
                  if (kIsDesktop || kIsWeb) {
                    return DesktopAttachmentMenu(
                      controller: controller!,
                      // The chat creator has no button row, and no messages to drop stickers on; this keeps these out of its
                      // menu
                      inRow: const [TextFieldButton.Gif, TextFieldButton.Emoji, TextFieldButton.Stickers],
                      builder: (_, toggle) => button(toggle),
                    );
                  }
                  return button(() {
                    if (!_showAttachmentPickerLocal) FocusScope.of(context).unfocus();
                    setState(() => _showAttachmentPickerLocal = !_showAttachmentPickerLocal);
                  });
                }),
              ),
              Expanded(child: textInput),
            ]),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeIn,
            alignment: Alignment.bottomCenter,
            child: pickerChild,
          ),
        ],
      );
    });
  }

  void onContentCommit(KeyboardInsertedContent content) async {
    // Delegate to clipboard handler
    clipboardHandler?.handleKeyboardInsertedContent(content);
  }

  KeyEventResult handleKey(FocusNode _, KeyEvent ev, BuildContext context, bool isChatCreator) {
    // Windows: Win+V clipboard history sends Ctrl on KeyUp, not KeyDown.
    // The Shortcuts widget handles normal Ctrl+V on KeyDown; this catches Win+V.
    if (!kIsWeb && Platform.isWindows) {
      if (ev is KeyUpEvent && ev.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
        if (_pasteHandledOnKeyDown) {
          _pasteHandledOnKeyDown = false;
          return KeyEventResult.ignored;
        }
        clipboardHandler?.handlePasteEvent();
        return KeyEventResult.handled;
      }
    }

    if (ev is! KeyDownEvent) return KeyEventResult.ignored;

    // Handle clipboard paste (Ctrl+V) on Linux
    if (!kIsWeb &&
        Platform.isLinux &&
        (ev.physicalKey == PhysicalKeyboardKey.keyV || ev.logicalKey == LogicalKeyboardKey.keyV) &&
        HardwareKeyboard.instance.isControlPressed) {
      final handler = clipboardHandler;
      if (handler != null) {
        unawaited(handler.handlePasteEvent(plain: HardwareKeyboard.instance.isShiftPressed));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Ctrl+Shift+V on a hardware keyboard (Ctrl+V is the field's own paste, which keeps formatting)
    if (!kIsWeb &&
        Platform.isAndroid &&
        ev.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isShiftPressed &&
        clipboardHandler != null) {
      unawaited(clipboardHandler!.handlePasteEvent(plain: true));
      return KeyEventResult.handled;
    }

    // The subject field shares this handler, and has no formatting
    final inMessageField = _fieldFocusNode?.hasFocus ?? false;
    if (inMessageField && (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      // Let the field copy or cut as usual, with the formatting remembered for a paste
      if (!shift && (ev.logicalKey == LogicalKeyboardKey.keyC || ev.logicalKey == LogicalKeyboardKey.keyX)) {
        (controller?.textController ?? textController).rememberSelection();
      }
      final style = switch (ev.logicalKey) {
        LogicalKeyboardKey.keyB when !shift => 'bold',
        LogicalKeyboardKey.keyI when !shift => 'italic',
        LogicalKeyboardKey.keyU when !shift => 'underline',
        LogicalKeyboardKey.keyX when shift => 'strikethrough',
        _ => null,
      };
      // Not in a brand-new chat (no controller yet), or where formatting can't be sent; the key then does what it did
      if (style != null && controller != null && controller!.textController.allowFormatting) {
        controller!.textController.toggleStyle(MentionTextEditingController.styleAttributes[style]!);
        return KeyEventResult.handled;
      }
    }

    if (HardwareKeyboard.instance.isAltPressed ||
        ((HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed) &&
            ev.logicalKey != LogicalKeyboardKey.enter)) {
      return KeyEventResult.ignored;
    }

    // Calculate movement indices for emoji/mention pickers
    int maxShown = context.height / 3 ~/ 40;
    int upMovementIndex = maxShown ~/ 3;
    int downMovementIndex = maxShown * 2 ~/ 3;

    // Check which key was pressed
    final isEscapeKey = ev.logicalKey == LogicalKeyboardKey.escape;
    final isTabOrEnter = ev.logicalKey == LogicalKeyboardKey.tab || ev.logicalKey == LogicalKeyboardKey.enter;
    final isDownArrow = ev.logicalKey == LogicalKeyboardKey.arrowDown;
    final isUpArrow = ev.logicalKey == LogicalKeyboardKey.arrowUp;

    // Try emoji handler first (emoji matches have priority over mentions if both active)
    bool handledByEmoji = emojiHandler?.handleKeyEvent(
          logicalKey: ev.logicalKey,
          isEscapeKey: isEscapeKey,
          isTabOrEnter: isTabOrEnter,
          isDownArrow: isDownArrow,
          isUpArrow: isUpArrow,
          maxShown: maxShown,
          upMovementIndex: upMovementIndex,
          downMovementIndex: downMovementIndex,
        ) ??
        false;
    if (handledByEmoji) return KeyEventResult.handled;

    // Try mention handler
    bool handledByMention = mentionHandler?.handleKeyEvent(
          logicalKey: ev.logicalKey,
          isEscapeKey: isEscapeKey,
          isTabOrEnter: isTabOrEnter,
          isDownArrow: isDownArrow,
          isUpArrow: isUpArrow,
          maxShown: maxShown,
          upMovementIndex: upMovementIndex,
          downMovementIndex: downMovementIndex,
        ) ??
        false;
    if (handledByMention) return KeyEventResult.handled;

    // Try keyboard shortcut handler (escape, enter, etc.)
    KeyEventResult shortcutResult = keyboardHandler?.handleKeyEvent(ev) ?? KeyEventResult.ignored;
    if (shortcutResult == KeyEventResult.handled) return KeyEventResult.handled;

    // Escape: dismiss active composer panels/overlays without wiping pickedAttachments
    if (isEscapeKey) {
      final ctrl = controller;
      if (ctrl == null) return KeyEventResult.ignored;

      if (ctrl.showAttachmentPicker.value) {
        ctrl.showAttachmentPicker.value = false;
        return KeyEventResult.handled;
      }
      if (ctrl.showGamePicker.value) {
        ctrl.showGamePicker.value = false;
        return KeyEventResult.handled;
      }
      if (ctrl.showTextFormattingPanel.value) {
        ctrl.showTextFormattingPanel.value = false;
        return KeyEventResult.handled;
      }
      if (ctrl.scheduledDate.value != null) {
        ctrl.scheduledDate.value = null;
        return KeyEventResult.handled;
      }
      if (ctrl.showRecording.value) {
        ctrl.showRecording.value = false;
        if (kIsWeb) {
          unawaited(widget.audioRecorder?.stop().then((path) {
            if (path != null) revokeWebObjectUrl(path);
          }).catchError((_) {}));
        } else {
          unawaited(recorderController?.stop().catchError((_) => null));
        }
        return KeyEventResult.handled;
      }
      if (ctrl.replyToMessage != null) {
        ctrl.replyToMessage = null;
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }
}

class _PasteIntent extends Intent {
  const _PasteIntent({this.plain = false});

  /// Ctrl+Shift+V: without the text's formatting
  final bool plain;
}

import 'dart:async';

import 'package:bluebubbles/app/components/wallpaper/dynamic_wallpaper_view.dart';
import 'package:bluebubbles/app/components/wallpaper/theme_wallpaper_palette.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/composer_popover.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/genmoji.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Opens the Genmoji creator: the user describes a Genmoji, the server's Mac draws it with
/// Apple Intelligence, and the user discards it, draws another, or attaches it.
///
/// Resolves to the image to attach, or null when the user backs out. Only call this when
/// `ServerDetails.supportsGenmoji` is true — the routes are v2-only.
Future<GenmojiImage?> showGenmojiDialog(BuildContext context, {required bool isIMessage}) async {
  final isWide = MediaQuery.sizeOf(context).width >= 600;
  final scheme = context.theme.colorScheme;

  if (!isWide) {
    return showModalBottomSheet<GenmojiImage>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: GenmojiDialog(isIMessage: isIMessage),
          ),
        ),
      ),
    );
  }

  final chat = ChatStateScope.maybeChatOf(context);
  final controller = chat != null && Get.isRegistered<ConversationViewController>(tag: chat.guid)
      ? Get.find<ConversationViewController>(tag: chat.guid)
      : null;

  GenmojiImage? picked;
  Widget buildCard(BuildContext _) => ComposerPopoverCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: SingleChildScrollView(
            child: GenmojiDialog(
              isIMessage: isIMessage,
              onResult: (image) => picked = image,
            ),
          ),
        ),
      );

  if (controller != null) {
    final wasShowingOverlays = controller.showingOverlays;
    final anchorContext = controller.textFieldKey.currentContext ?? context;
    await showComposerPopover(
      anchorContext,
      controller,
      width: 380,
      height: 500,
      builder: buildCard,
    );
    controller.showingOverlays = wasShowingOverlays;
    return picked;
  }

  final themes = InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: true).context);
  await Navigator.of(context, rootNavigator: true).push(
    RawDialogRoute<void>(
      barrierDismissible: true,
      barrierLabel: "Dismiss",
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (routeContext, _, _) => SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(routeContext).bottom),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380, maxHeight: 500),
              child: themes.wrap(Builder(builder: buildCard)),
            ),
          ),
        ),
      ),
    ),
  );
  return picked;
}

enum _GenmojiPhase { checking, unavailable, prompt, generating, result, failed }

class GenmojiDialog extends StatefulWidget {
  const GenmojiDialog({super.key, required this.isIMessage, this.onResult});

  /// Seeds the nebula's colors from the chat's bubble color.
  final bool isIMessage;
  final ValueChanged<GenmojiImage?>? onResult;

  @override
  State<GenmojiDialog> createState() => _GenmojiDialogState();
}

class _GenmojiDialogState extends State<GenmojiDialog> with ThemeHelpers {
  final TextEditingController _promptController = TextEditingController();
  final FocusNode _promptFocus = FocusNode();
  final FocusNode _generatingFocus = FocusNode();

  _GenmojiPhase _phase = _GenmojiPhase.checking;
  int _maxLength = GenmojiSupport.defaultMaximumDescriptionLength;
  String? _message;
  bool _canRetryStatus = false;
  GenmojiImage? _image;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _promptController.addListener(_onPromptChanged);
    _checkStatus();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _promptController.removeListener(_onPromptChanged);
    _promptController.dispose();
    _promptFocus.dispose();
    _generatingFocus.dispose();
    super.dispose();
  }

  /// Rebuilds the actions so Generate enables/disables as the prompt fills and empties.
  void _onPromptChanged() {
    if (mounted) setState(() {});
  }

  bool get _hasPrompt => _promptController.text.trim().isNotEmpty;

  void _setPhase(_GenmojiPhase phase, {String? message, bool canRetryStatus = false}) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _message = message;
      _canRetryStatus = canRetryStatus;
    });
  }

  /// Asks the Mac whether it can draw at all before offering the prompt, so a Mac that can't
  /// (too old, Apple Intelligence off, no subscription) says why up front.
  Future<void> _checkStatus() async {
    _setPhase(_GenmojiPhase.checking);
    try {
      final support = await HttpSvc.genmoji.status();
      if (!mounted) return;
      if (!support.available) {
        return _setPhase(
          _GenmojiPhase.unavailable,
          message: support.detail ?? "Genmoji can't be created on your server's Mac right now.",
        );
      }
      _maxLength = support.maximumDescriptionLength;
      _setPhase(_GenmojiPhase.prompt);
      _promptFocus.requestFocus();
    } on GenmojiException catch (e) {
      Logger.warn("Genmoji unavailable: ${e.reason ?? e.statusCode}", tag: 'Genmoji');
      _setPhase(_GenmojiPhase.unavailable, message: e.message);
    } catch (e, s) {
      Logger.error("Failed to check Genmoji support", error: e, trace: s, tag: 'Genmoji');
      _setPhase(
        _GenmojiPhase.unavailable,
        message: "Couldn't reach your server to check Genmoji support.",
        canRetryStatus: true,
      );
    }
  }

  Future<void> _generate() async {
    final description = _promptController.text.trim();
    if (description.isEmpty) return;

    // Keep focus inside GenmojiDialog so our CallbackShortcuts intercepts Escape during generation.
    _generatingFocus.requestFocus();
    final token = CancelToken();
    _cancelToken = token;
    _setPhase(_GenmojiPhase.generating);

    try {
      final images = await HttpSvc.genmoji.create(description, cancelToken: token);
      if (!mounted || token.isCancelled) return;
      if (images.isEmpty) {
        return _setPhase(_GenmojiPhase.failed, message: "No Genmoji came back. Try describing it differently.");
      }
      _image = images.first;
      _setPhase(_GenmojiPhase.result);
    } on GenmojiException catch (e) {
      Logger.warn("Genmoji refused: ${e.reason ?? e.statusCode}", tag: 'Genmoji');
      _setPhase(_GenmojiPhase.failed, message: e.message);
    } on DioException catch (e, s) {
      if (CancelToken.isCancel(e)) return;
      Logger.error("Genmoji request failed", error: e, trace: s, tag: 'Genmoji');
      _setPhase(_GenmojiPhase.failed, message: "Couldn't reach your server. Check your connection and try again.");
    } catch (e, s) {
      Logger.error("Genmoji request failed", error: e, trace: s, tag: 'Genmoji');
      _setPhase(_GenmojiPhase.failed, message: "Something went wrong creating your Genmoji.");
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  void _stopGenerating() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _setPhase(_image != null ? _GenmojiPhase.result : _GenmojiPhase.prompt);
  }

  void _close([GenmojiImage? result]) {
    _cancelToken?.cancel();
    if (widget.onResult != null) {
      widget.onResult!(result);
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pop(result);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  List<({String label, VoidCallback? onPressed, bool isDefault, bool isDestructive})> get _actions {
    switch (_phase) {
      case _GenmojiPhase.checking:
        return [(label: "Cancel", onPressed: _close, isDefault: false, isDestructive: false)];
      case _GenmojiPhase.unavailable:
        return [
          (label: "Close", onPressed: _close, isDefault: !_canRetryStatus, isDestructive: false),
          if (_canRetryStatus) (label: "Retry", onPressed: _checkStatus, isDefault: true, isDestructive: false),
        ];
      case _GenmojiPhase.prompt:
        return [
          (label: "Cancel", onPressed: _close, isDefault: false, isDestructive: false),
          (label: "Generate", onPressed: _hasPrompt ? _generate : null, isDefault: true, isDestructive: false),
        ];
      case _GenmojiPhase.generating:
        return [(label: "Stop", onPressed: _stopGenerating, isDefault: false, isDestructive: false)];
      case _GenmojiPhase.failed:
        return [
          (label: "Cancel", onPressed: _close, isDefault: false, isDestructive: false),
          (label: "Try Again", onPressed: _hasPrompt ? _generate : null, isDefault: true, isDestructive: false),
        ];
      case _GenmojiPhase.result:
        return [
          (label: "Discard", onPressed: _close, isDefault: false, isDestructive: true),
          (label: "New", onPressed: _hasPrompt ? _generate : null, isDefault: false, isDestructive: false),
          (label: "Attach", onPressed: () => _close(_image), isDefault: true, isDestructive: false),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    const minSize = Size(64, 48);
    const btnPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 10);
    const shape = StadiumBorder();
    final generating = _phase == _GenmojiPhase.generating;

    return PopScope(
      canPop: !generating,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!generating) _close();
          },
        },
        child: Focus(
          focusNode: _generatingFocus,
          child: Column(
            mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 22, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Genmoji",
                    style: context.theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildContent(context),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: _actions.map((a) {
                if (a.isDefault) {
                  return FilledButton(
                    onPressed: a.onPressed,
                    style: FilledButton.styleFrom(
                      backgroundColor: a.isDestructive ? scheme.error : scheme.primary,
                      foregroundColor: a.isDestructive ? scheme.onError : scheme.onPrimary,
                      minimumSize: minSize,
                      padding: btnPadding,
                      shape: shape,
                    ),
                    child: Text(a.label),
                  );
                }
                return TextButton(
                  onPressed: a.onPressed,
                  style: TextButton.styleFrom(
                    foregroundColor: a.isDestructive ? scheme.error : scheme.primary,
                    minimumSize: minSize,
                    padding: btnPadding,
                    shape: shape,
                  ),
                  child: Text(a.label),
                );
              }).toList(),
            ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final showPrompt = _phase != _GenmojiPhase.checking && _phase != _GenmojiPhase.unavailable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.45)),
                ),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOutCubic,
                  child: KeyedSubtree(key: ValueKey(_phase), child: _buildCanvas(context)),
                ),
              ),
            ),
          ),
        ),
        if (showPrompt) ...[const SizedBox(height: 14), _buildPromptField(context)],
      ],
    );
  }

  /// The square above the prompt: the nebula while drawing, the Genmoji once drawn, and a
  /// message in between.
  Widget _buildCanvas(BuildContext context) {
    final scheme = context.theme.colorScheme;
    switch (_phase) {
      case _GenmojiPhase.generating:
        return _GenmojiNebula(isIMessage: widget.isIMessage);
      case _GenmojiPhase.result:
        return ColoredBox(
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Image.memory(_image!.png, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        );
      case _GenmojiPhase.checking:
        return ColoredBox(
          color: scheme.surface,
          child: Center(child: iOS ? const CupertinoActivityIndicator() : const CircularProgressIndicator()),
        );
      case _GenmojiPhase.prompt:
        return _CanvasMessage(
          icon: Icons.auto_awesome_rounded,
          message: "Describe an emoji and your Mac will create it.",
          color: scheme.primary,
        );
      case _GenmojiPhase.unavailable:
      case _GenmojiPhase.failed:
        return _CanvasMessage(
          icon: Icons.error_outline_rounded,
          message: _message ?? "Something went wrong.",
          color: scheme.error,
        );
    }
  }

  Widget _buildPromptField(BuildContext context) {
    final enabled = _phase != _GenmojiPhase.generating;
    void onSubmitted(String _) {
      if (enabled && _hasPrompt) _generate();
    }

    if (iOS) {
      return CupertinoTextField(
        controller: _promptController,
        focusNode: _promptFocus,
        enabled: enabled,
        maxLength: _maxLength,
        minLines: 1,
        maxLines: 3,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.sentences,
        placeholder: "Describe a Genmoji",
        style: context.theme.textTheme.bodyLarge,
        onSubmitted: onSubmitted,
      );
    }

    return TextField(
      controller: _promptController,
      focusNode: _promptFocus,
      enabled: enabled,
      maxLength: _maxLength,
      minLines: 1,
      maxLines: 3,
      textInputAction: TextInputAction.done,
      textCapitalization: TextCapitalization.sentences,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: "Describe a Genmoji",
        // The 500-character cap is a backstop, not something worth a counter under every prompt.
        counterText: "",
        filled: true,
        fillColor: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.theme.colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        isDense: true,
      ),
    );
  }
}

class _CanvasMessage extends StatelessWidget {
  const _CanvasMessage({required this.icon, required this.message, required this.color});

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 12),
            // The server's refusal sentences can run to a few lines (e.g. `needs_app`), more than
            // the square holds at larger text scales — scroll rather than clip them.
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.onSurface),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "drawing" state: the Particles wallpaper's Nebula preset in the chat's theme colors,
/// run denser and faster than a wallpaper would be, under a pulsing sparkle.
class _GenmojiNebula extends StatefulWidget {
  const _GenmojiNebula({required this.isIMessage});

  final bool isIMessage;

  @override
  State<_GenmojiNebula> createState() => _GenmojiNebulaState();
}

class _GenmojiNebulaState extends State<_GenmojiNebula> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  Map<String, dynamic>? _config;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_pulse.isAnimating) _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
    // Built once per showing: the particle set is keyed on its config, so recomputing it on
    // every rebuild would restart the animation.
    _config ??= {
      'preset': 'nebula',
      'count': 30,
      'speed': 2.0,
      'colors': ThemeWallpaperPalette.fromContext(
        context,
        isIMessage: widget.isIMessage,
      ).take(4).map((c) => c.toARGB32()).toList(),
    };
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        DynamicWallpaperView(wallpaperId: 'particles', config: _config),
        Center(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_pulse.value);
              return Opacity(
                opacity: 0.55 + 0.45 * t,
                child: Transform.scale(scale: 0.9 + 0.2 * t, child: child),
              );
            },
            child: Icon(Icons.auto_awesome_rounded, size: 48, color: scheme.primary),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 14,
          child: Text(
            "Creating Genmoji…",
            textAlign: TextAlign.center,
            style: context.theme.textTheme.labelLarge!.copyWith(color: scheme.onSurface),
          ),
        ),
      ],
    );
  }
}

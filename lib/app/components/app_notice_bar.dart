import 'dart:async';
import 'dart:ui';

import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// Threshold at which wide desktop/web layouts render non-error notices as a
/// compact bottom-left toast in the list pane instead of a top-shell strip.
const double kAppNoticeWideBreakpoint = 840.0;

@immutable
class AppNoticeData {
  final int id;
  final String title;
  final String message;
  final SnackbarType type;
  final int durationMs;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? issueKey;
  final bool hasExplicitKey;

  const AppNoticeData({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.durationMs,
    this.actionLabel,
    this.onAction,
    this.issueKey,
    this.hasExplicitKey = false,
  });

  bool get isError => type == SnackbarType.error;

  String get conciseText {
    final cleanTitle = title.trim();
    final cleanMessage = message.trim();
    if (cleanTitle.isEmpty) return cleanMessage;
    final lower = cleanTitle.toLowerCase();
    if (lower == 'error' || lower == 'notice' || lower == 'success' || lower == 'info') {
      return cleanMessage.isNotEmpty ? cleanMessage : cleanTitle;
    }
    if (cleanMessage.isEmpty) return cleanTitle;
    return '$cleanTitle: $cleanMessage';
  }
}

class AppNoticeController {
  AppNoticeController._();

  static final AppNoticeController instance = AppNoticeController._();

  final ValueNotifier<AppNoticeData?> current = ValueNotifier<AppNoticeData?>(null);

  int _nextId = 1;
  int _hostCount = 0;
  Timer? _autoCloseTimer;
  void Function(String key)? _onAutoClosed;
  void Function(String key, bool hasExplicitKey)? _onExplicitDismiss;

  bool get hasMountedHost => _hostCount > 0;

  void registerHost() {
    _hostCount++;
  }

  void unregisterHost() {
    if (_hostCount > 0) _hostCount--;
  }

  void show({
    required String title,
    required String message,
    required SnackbarType type,
    required int durationMs,
    String? actionLabel,
    VoidCallback? onAction,
    String? issueKey,
    bool hasExplicitKey = false,
    void Function(String key)? onAutoClosed,
    void Function(String key, bool hasExplicitKey)? onExplicitDismiss,
  }) {
    _autoCloseTimer?.cancel();
    final id = _nextId++;
    _onAutoClosed = onAutoClosed;
    _onExplicitDismiss = onExplicitDismiss;

    final notice = AppNoticeData(
      id: id,
      title: title,
      message: message,
      type: type,
      durationMs: durationMs,
      actionLabel: actionLabel,
      onAction: onAction,
      issueKey: issueKey,
      hasExplicitKey: hasExplicitKey,
    );
    current.value = notice;

    _autoCloseTimer = Timer(Duration(milliseconds: durationMs), () {
      final active = current.value;
      if (active == null || active.id != id) return;
      _autoCloseTimer?.cancel();
      _autoCloseTimer = null;
      current.value = null;
      final key = active.issueKey;
      if (key != null) {
        _onAutoClosed?.call(key);
      }
    });
  }

  void dismiss({bool explicit = false}) {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
    final active = current.value;
    current.value = null;
    if (active == null) return;
    final key = active.issueKey;
    if (key == null) return;
    if (explicit) {
      _onExplicitDismiss?.call(key, active.hasExplicitKey);
    } else {
      _onAutoClosed?.call(key);
    }
  }

  void resetForTest() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
    _onAutoClosed = null;
    _onExplicitDismiss = null;
    current.value = null;
  }
}

/// Registers an integrated [AppNoticeController] host in the widget tree.
class AppNoticeHost extends StatefulWidget {
  final Widget child;

  const AppNoticeHost({super.key, required this.child});

  @override
  State<AppNoticeHost> createState() => _AppNoticeHostState();
}

class _AppNoticeHostState extends State<AppNoticeHost> {
  @override
  void initState() {
    super.initState();
    AppNoticeController.instance.registerHost();
  }

  @override
  void dispose() {
    AppNoticeController.instance.unregisterHost();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Returns true when [notice] should occupy the top app-shell slot rather than
/// the wide-desktop bottom-left corner toast.
bool appNoticeUsesTopSlot(AppNoticeData? notice, double viewportWidth) {
  if (notice == null) return false;
  return notice.isError || viewportWidth < kAppNoticeWideBreakpoint;
}

({Color fill, Color border}) _frostedNoticeSurface(ThemeData theme, Color tone, {bool floating = false}) {
  final isDark = theme.brightness == Brightness.dark;
  final colorScheme = theme.colorScheme;
  final tintAlpha = isDark ? 0.14 : 0.08;
  final surfaceAlpha = floating ? (isDark ? 0.74 : 0.78) : (isDark ? 0.72 : 0.76);
  final base = Color.alphaBlend(tone.withValues(alpha: tintAlpha), colorScheme.surfaceContainerHigh);
  final border = Color.alphaBlend(
    tone.withValues(alpha: 0.24),
    isDark ? Colors.white : colorScheme.outline,
  ).withValues(alpha: isDark ? 0.18 : 0.16);
  return (fill: base.withValues(alpha: surfaceAlpha), border: border);
}

/// Integrated top-slot notice strip (frosted glass tonal surface + 1px hairline).
class AppNoticeTopBar extends StatelessWidget {
  final AppNoticeData notice;
  final VoidCallback onDismiss;

  const AppNoticeTopBar({
    super.key,
    required this.notice,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isIOS = GetIt.I.isRegistered<SettingsService>() && SettingsSvc.settings.skin.value == Skins.iOS;

    final Color iconColor = switch (notice.type) {
      SnackbarType.error => colorScheme.error,
      SnackbarType.success => isDark ? const Color(0xFF4ADE80) : const Color(0xFF1E8E3E),
      SnackbarType.info => colorScheme.primary,
    };
    final surface = _frostedNoticeSurface(theme, iconColor);
    final IconData iconData = switch (notice.type) {
      SnackbarType.error => isIOS ? CupertinoIcons.exclamationmark_circle : Icons.error_outline_rounded,
      SnackbarType.success => isIOS ? CupertinoIcons.checkmark_circle : Icons.check_circle_outline_rounded,
      SnackbarType.info => isIOS ? CupertinoIcons.info_circle : Icons.info_outline_rounded,
    };

    return Dismissible(
      key: ValueKey('app_notice_top_${notice.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDismiss(),
      child: Semantics(
        liveRegion: true,
        container: true,
        label: notice.conciseText,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: surface.fill,
                  border: Border(
                    bottom: BorderSide(color: surface.border, width: 1),
                  ),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Row(
                      children: [
                        Icon(iconData, size: 16, color: iconColor),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            notice.conciseText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (notice.actionLabel != null && notice.onAction != null)
                          TextButton(
                            onPressed: () {
                              notice.onAction?.call();
                              onDismiss();
                            },
                            style: TextButton.styleFrom(
                              minimumSize: const Size(40, 40),
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(notice.actionLabel!),
                          ),
                        if (notice.isError)
                          IconButton(
                            key: const Key('snackbar_dismiss_button'),
                            tooltip: 'Dismiss',
                            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              isIOS ? CupertinoIcons.xmark : Icons.close_rounded,
                              size: 18,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            onPressed: onDismiss,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Non-blocking bottom-left toast for info/success notices on wide desktop/web (>=840px).
class AppNoticeCornerToast extends StatelessWidget {
  final AppNoticeData notice;
  final VoidCallback onDismiss;

  const AppNoticeCornerToast({
    super.key,
    required this.notice,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isIOS = GetIt.I.isRegistered<SettingsService>() && SettingsSvc.settings.skin.value == Skins.iOS;

    final Color iconColor = notice.type == SnackbarType.success
        ? (isDark ? const Color(0xFF4ADE80) : const Color(0xFF1E8E3E))
        : colorScheme.primary;
    final surface = _frostedNoticeSurface(theme, iconColor, floating: true);
    final IconData iconData = notice.type == SnackbarType.success
        ? (isIOS ? CupertinoIcons.checkmark_circle : Icons.check_circle_outline_rounded)
        : (isIOS ? CupertinoIcons.info_circle : Icons.info_outline_rounded);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Dismissible(
        key: ValueKey('app_notice_corner_${notice.id}'),
        direction: DismissDirection.horizontal,
        onDismissed: (_) => onDismiss(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: colorScheme.shadow.withValues(alpha: isDark ? 0.28 : 0.12),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Material(
                type: MaterialType.transparency,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: surface.fill,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: surface.border, width: 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(iconData, size: 16, color: iconColor),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            notice.conciseText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (notice.actionLabel != null && notice.onAction != null) ...[
                          const SizedBox(width: 6),
                          TextButton(
                            onPressed: () {
                              notice.onAction?.call();
                              onDismiss();
                            },
                            style: TextButton.styleFrom(
                              minimumSize: const Size(40, 40),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(notice.actionLabel!),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

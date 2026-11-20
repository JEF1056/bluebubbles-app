import 'dart:async';
import 'dart:ui';

import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

/// Unified app-shell status indicator for background sync progress and sticky
/// sync/connection failures.
///
/// Designed to sit cleanly in the app-shell top chrome (or standalone in tests)
/// without overlapping headers, search bars, or action buttons:
/// - Syncing: 2px primary indeterminate hairline along the top edge (`IgnorePointer`).
/// - Failed / Offline / Auth: slim single-row Google Messages tonal strip with
///   inline `Retry` and `×` dismiss buttons.
class GlobalSyncStatusOverlay extends StatelessWidget {
  final SyncStatusSnapshot? statusOverride;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;
  final bool? showSyncIndicatorOverride;

  const GlobalSyncStatusOverlay({
    super.key,
    this.statusOverride,
    this.onRetry,
    this.onDismiss,
    this.showSyncIndicatorOverride,
  });

  /// Whether [snapshot] requires layout space as a failed/offline/auth strip.
  static bool hasBannerFor(SyncStatusSnapshot snapshot) => snapshot.showFailed;

  @override
  Widget build(BuildContext context) {
    if (statusOverride != null) {
      return _buildAnimatedContent(context, statusOverride!);
    }

    return Obx(() {
      if (GetIt.I.isRegistered<SettingsService>() && !SettingsSvc.settings.finishedSetup.value) {
        return const SizedBox.shrink();
      }
      final snapshot = GetIt.I.isRegistered<SyncService>() ? SyncSvc.status.value : SyncStatusSnapshot.idle;
      return _buildAnimatedContent(context, snapshot);
    });
  }

  Widget _buildAnimatedContent(BuildContext context, SyncStatusSnapshot snapshot) {
    final allowSyncing = showSyncIndicatorOverride ??
        (GetIt.I.isRegistered<SettingsService>() ? SettingsSvc.settings.showSyncIndicator.value : true);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduceMotion ? Duration.zero : const Duration(milliseconds: 180);

    final Widget child;
    if (snapshot.showFailed) {
      child = _SyncFailedStrip(
        key: ValueKey('sync_failed:${snapshot.issueKey ?? 'default'}'),
        snapshot: snapshot,
        onRetry: onRetry ?? _defaultRetry,
        onDismiss: onDismiss ?? () => _defaultDismiss(snapshot.issueKey),
      );
    } else if (snapshot.showSyncing && allowSyncing) {
      child = _SyncingHairline(
        key: const ValueKey('sync_syncing'),
        label: snapshot.message?.isNotEmpty == true ? snapshot.message! : 'Syncing…',
      );
    } else {
      child = const SizedBox.shrink(key: ValueKey('sync_idle'));
    }

    return IgnorePointer(
      ignoring: !snapshot.showFailed,
      child: AnimatedSize(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          transitionBuilder: (child, animation) =>
              reduceMotion ? child : FadeTransition(opacity: animation, child: child),
          child: child,
        ),
      ),
    );
  }

  void _defaultRetry() {
    if (GetIt.I.isRegistered<SyncService>()) {
      unawaited(SyncSvc.retryNow());
    }
  }

  void _defaultDismiss(String? issueKey) {
    if (GetIt.I.isRegistered<SyncService>()) {
      SyncSvc.dismissIssue(issueKey);
    }
  }
}

class _SyncingHairline extends StatelessWidget {
  final String label;

  const _SyncingHairline({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: label,
        child: SizedBox(
          width: double.infinity,
          height: 2,
          child: LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

class _SyncFailedStrip extends StatelessWidget {
  final SyncStatusSnapshot snapshot;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _SyncFailedStrip({
    super.key,
    required this.snapshot,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final label = snapshot.message?.isNotEmpty == true ? snapshot.message! : 'Sync failed';
    final isOffline = label.toLowerCase().contains('offline');
    final isIOS = GetIt.I.isRegistered<SettingsService>() && SettingsSvc.settings.skin.value == Skins.iOS;
    final tone = isOffline
        ? (isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706))
        : colorScheme.error;
    final fillColor = Color.alphaBlend(
      tone.withValues(alpha: isDark ? 0.14 : 0.08),
      colorScheme.surfaceContainerHigh,
    ).withValues(alpha: isDark ? 0.72 : 0.76);
    final borderColor = Color.alphaBlend(
      tone.withValues(alpha: 0.24),
      isDark ? Colors.white : colorScheme.outline,
    ).withValues(alpha: isDark ? 0.18 : 0.16);

    return Semantics(
      liveRegion: true,
      container: true,
      label: label,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fillColor,
                border: Border(
                  bottom: BorderSide(color: borderColor, width: 1),
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      if (snapshot.retrying)
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.75,
                            valueColor: AlwaysStoppedAnimation<Color>(tone),
                          ),
                        )
                      else
                        Icon(
                          isIOS
                              ? (isOffline ? CupertinoIcons.wifi_slash : CupertinoIcons.exclamationmark_circle)
                              : (isOffline ? Icons.cloud_off_rounded : Icons.error_outline_rounded),
                          size: 16,
                          color: tone,
                        ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Semantics(
                        button: true,
                        enabled: !snapshot.retrying,
                        label: 'Retry sync',
                        child: TextButton(
                          onPressed: snapshot.retrying ? null : onRetry,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(44, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            'Retry',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: 'Dismiss sync error',
                        child: IconButton(
                          key: const Key('sync_dismiss_button'),
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
                      ),
                    ],
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

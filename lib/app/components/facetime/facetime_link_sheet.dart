import 'dart:async';

import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Creates a standalone FaceTime link session and presents an M3E sheet to copy, share, or join.
Future<void> createAndShareFaceTimeLink(
  BuildContext context, {
  String? displayName,
  String? chatGuid,
  List<String>? addresses,
  Future<PlacedFaceTimeCall> Function()? onCreateSession,
}) async {
  if (!context.mounted) return;
  final reducedMotion = facetimeReducedMotionOf(context);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
    builder: (_) => FaceTimeLinkSheet(
      displayName: displayName,
      chatGuid: chatGuid,
      addresses: addresses,
      onCreateSession: onCreateSession,
    ),
  );
}

class FaceTimeLinkSheet extends StatefulWidget {
  const FaceTimeLinkSheet({
    super.key,
    this.displayName,
    this.chatGuid,
    this.addresses,
    this.onCreateSession,
  });

  final String? displayName;
  final String? chatGuid;
  final List<String>? addresses;
  final Future<PlacedFaceTimeCall> Function()? onCreateSession;

  @override
  State<FaceTimeLinkSheet> createState() => _FaceTimeLinkSheetState();
}

class _FaceTimeLinkSheetState extends State<FaceTimeLinkSheet> {
  bool _loading = true;
  String? _link;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generateLink();
  }

  Future<void> _generateLink() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final placed = widget.onCreateSession != null
          ? await widget.onCreateSession!()
          : await HttpSvc.faceTime.createFaceTimeSession(
              displayName: widget.displayName,
              chatGuid: widget.chatGuid,
              addresses: widget.addresses,
            );
      if (!mounted) return;
      final link = placed.link?.trim();
      if (link == null || link.isEmpty) {
        setState(() {
          _loading = false;
          _error = "Couldn't create a FaceTime link.";
        });
        return;
      }
      setState(() {
        _loading = false;
        _link = link;
      });
    } on FaceTimeException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't reach the server.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final reducedMotion = facetimeReducedMotionOf(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final sheetSurface = isDark ? FaceTimePalette.darkSurface : colors.surfaceContainerLow;
    final borderColor = isDark ? FaceTimePalette.hairline : colors.outlineVariant.withValues(alpha: 0.5);
    final titleColor = isDark ? FaceTimePalette.onCanvas : colors.onSurface;
    final subtitleColor = isDark ? FaceTimePalette.secondaryText : colors.onSurfaceVariant;
    final accent = isDark ? FaceTimePalette.blueDark : FaceTimePalette.blue;

    return SafeArea(
      top: true,
      bottom: false,
      child: Container(
        decoration: BoxDecoration(
          color: sheetSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
          border: Border(top: BorderSide(color: borderColor, width: 1)),
        ),
        padding: EdgeInsets.fromLTRB(
          FaceTimeDims.contactSideMargin,
          12,
          FaceTimeDims.contactSideMargin,
          FaceTimeDims.contactSideMargin + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: subtitleColor.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'FaceTime Link',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontSize: 22,
                color: titleColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              Text('Creating FaceTime link…', style: theme.textTheme.bodyMedium?.copyWith(color: subtitleColor)),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: reducedMotion ? 0.6 : null,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.2),
                ),
              ),
            ] else if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: colors.onErrorContainer),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            foregroundColor: isDark ? FaceTimePalette.onCanvas : colors.onErrorContainer,
                            minimumSize: const Size(88, FaceTimeDims.actionButtonSize),
                          ),
                          child: const Text('Close'),
                        ),
                        FilledButton.tonal(
                          onPressed: _generateLink,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(112, FaceTimeDims.actionButtonSize),
                            shape: const StadiumBorder(),
                          ),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark ? FaceTimePalette.darkElevated : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                  border: Border.all(color: borderColor),
                ),
                child: SelectableText(
                  _link!,
                  maxLines: 2,
                  style: theme.textTheme.bodyMedium?.copyWith(color: titleColor, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _link!));
                      showSnackbar('FaceTime', 'Copied FaceTime link');
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isDark ? FaceTimePalette.onCanvas : null,
                      side: isDark ? BorderSide(color: FaceTimePalette.secondaryText.withValues(alpha: 0.4)) : null,
                      minimumSize: const Size(0, FaceTimeDims.actionButtonSize),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(SharePlus.instance.share(ShareParams(text: _link!))),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, FaceTimeDims.actionButtonSize),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      final link = _link!;
                      final nav = Navigator.of(context, rootNavigator: true);
                      Navigator.of(context).pop();
                      unawaited(openFaceTimeJoinLink(link, context: nav.mounted ? nav.context : null));
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: FaceTimePalette.blue,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, FaceTimeDims.actionButtonSize),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.videocam_rounded, size: 18),
                    label: const Text('Join'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

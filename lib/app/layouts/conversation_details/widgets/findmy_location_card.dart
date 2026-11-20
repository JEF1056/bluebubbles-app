import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Cohesive M3 tonal card displaying a 1:1 contact's Find My location in Details / Inspector.
/// Hides cleanly (`SizedBox.shrink()`) for group chats, redacted mode, or unavailable coordinates.
class FindMyLocationCard extends StatefulWidget {
  const FindMyLocationCard({super.key, required this.chat});

  final Chat chat;

  @override
  State<FindMyLocationCard> createState() => _FindMyLocationCardState();
}

class _FindMyLocationCardState extends State<FindMyLocationCard> {
  late final FindMyController _fm;

  @override
  void initState() {
    super.initState();
    _fm = FindMyController.ensure();
    if (!widget.chat.isGroup) {
      unawaited(_fm.ensureFriendsLoaded());
    }
  }

  @override
  void didUpdateWidget(covariant FindMyLocationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat.guid != widget.chat.guid && !widget.chat.isGroup) {
      unawaited(_fm.ensureFriendsLoaded());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chat.isGroup) return const SizedBox.shrink();
    return Obx(() {
      final loc = _fm.locationForChat(widget.chat);
      if (loc == null) return const SizedBox.shrink();

      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final address = loc.fullAddress.isNotEmpty ? loc.fullAddress : loc.shortLabel;
      final metaParts = <String>[
        if (loc.freshness.isNotEmpty) loc.freshness,
        if (loc.distanceLabel != null && loc.distanceLabel!.isNotEmpty) loc.distanceLabel!,
      ];

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Material(
          color: cs.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _fm.openForChat(context, widget.chat),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.location_on_rounded, size: 19, color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Location',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (loc.isLive) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Live',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: Colors.green.shade700,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          address,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (metaParts.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            metaParts.join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, size: 20, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

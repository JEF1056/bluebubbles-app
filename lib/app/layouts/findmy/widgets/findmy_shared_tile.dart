import 'package:flutter/material.dart';
import 'package:get/get.dart';

class FindMySharedTile extends StatelessWidget {
  final bool isSelected;
  final Key cardKey;
  final Widget leadingExpanded;
  final Widget leadingCollapsed;
  final String displayName;
  final String? modelSubtitle;
  final String locationLine;
  final bool showStatusDot;
  final String statusText;
  final bool statusActive;
  final String? statusSuffix;
  final bool isBusyExpanded;
  final Key? busyIndicatorKey;
  final VoidCallback onClearSelection;
  final VoidCallback onShowDetails;
  final VoidCallback? onLaunchDirections;
  final String directionsLabel;
  final Widget secondaryButton;
  final String rowSubtitle;
  final bool isLocatingRow;
  final String proximity;
  final bool showLiveDotInRow;
  final VoidCallback? onTapRow;
  final VoidCallback? onLongPress;

  const FindMySharedTile({
    super.key,
    required this.isSelected,
    required this.cardKey,
    required this.leadingExpanded,
    required this.leadingCollapsed,
    required this.displayName,
    this.modelSubtitle,
    required this.locationLine,
    required this.showStatusDot,
    required this.statusText,
    required this.statusActive,
    this.statusSuffix,
    required this.isBusyExpanded,
    this.busyIndicatorKey,
    required this.onClearSelection,
    required this.onShowDetails,
    required this.onLaunchDirections,
    required this.directionsLabel,
    required this.secondaryButton,
    required this.rowSubtitle,
    required this.isLocatingRow,
    required this.proximity,
    required this.showLiveDotInRow,
    required this.onTapRow,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final tt = context.theme.textTheme;

    if (isSelected) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Material(
          key: cardKey,
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onClearSelection,
            onLongPress: onLongPress,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      leadingExpanded,
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (modelSubtitle != null) ...[
                              const SizedBox(height: 1),
                              Text(
                                modelSubtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                              const SizedBox(height: 1),
                            ] else
                              const SizedBox(height: 2),
                            Text(
                              locationLine,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                if (showStatusDot) ...[
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF22C55E),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Text(
                                  statusText,
                                  style: tt.labelMedium?.copyWith(
                                    color: statusActive ? const Color(0xFF22C55E) : cs.onSurfaceVariant,
                                    fontWeight: statusActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                if (statusSuffix != null)
                                  Text(
                                    statusSuffix!,
                                    style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (isBusyExpanded) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 34,
                          child: Center(
                            child: SizedBox(
                              key: busyIndicatorKey,
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: IconButton.filledTonal(
                          key: const ValueKey('findmy-inline-more'),
                          padding: EdgeInsets.zero,
                          tooltip: 'Details',
                          onPressed: onShowDetails,
                          icon: const Icon(Icons.more_horiz, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(shape: const StadiumBorder()),
                            onPressed: onLaunchDirections,
                            icon: const Icon(Icons.directions_outlined, size: 18),
                            label: Text(
                              directionsLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(height: 44, child: secondaryButton),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListTile(
      mouseCursor: MouseCursor.defer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: leadingCollapsed,
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        rowSubtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: isLocatingRow
          ? SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant),
                ),
              ),
            )
          : (proximity.isNotEmpty
              ? (showLiveDotInRow
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: Color(0xFF22C55E),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          proximity,
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      proximity,
                      style: tt.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ))
              : null),
      onTap: onTapRow,
      onLongPress: onLongPress,
    );
  }
}

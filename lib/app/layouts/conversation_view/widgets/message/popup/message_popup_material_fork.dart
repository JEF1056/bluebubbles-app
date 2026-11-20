import 'dart:math';

import 'package:bluebubbles/app/components/m3e/m3e_motion.dart';
import 'package:bluebubbles/app/components/m3e/m3e_shapes.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/details_menu_action.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

Widget buildMaterialTapbackPill(
  BuildContext context, {
  required bool narrowScreen,
  required bool emojiTapbacks,
  required String? ownEmoji,
  required List<String> tapbackItems,
  required double emojiRowMaxWidth,
  required String? currentlySelectedReaction,
  required bool isFromMe,
  required bool hasCustomWallpaper,
  required Widget Function(String emoji) emojiTapbackGlyph,
  required Widget Function(Widget child) fadeScrollEdges,
  required void Function(String emoji) onSendEmojiTapback,
  required VoidCallback onPickEmojiTapback,
  required void Function(String reaction) onSelectReaction,
}) {
  if (currentlySelectedReaction == "init") {
    return const SizedBox(height: 52);
  }

  final colorScheme = context.theme.colorScheme;
  final rows = Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: isFromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
                    onTap: () {
                      if (isEmoji) {
                        onSendEmojiTapback(e);
                        return;
                      }
                      onSelectReaction(e);
                    },
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Center(
                        child: isEmoji
                            ? emojiTapbackGlyph(e)
                            : Builder(builder: (context) {
                                final text = Text(
                                  ReactionTypes.reactionToEmoji[e] ?? "X",
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontFamilyFallback: ["Apple Color Emoji", "Noto Color Emoji", "Segoe UI Emoji"],
                                  ),
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
        child: fadeScrollEdges(SingleChildScrollView(scrollDirection: Axis.horizontal, child: row)),
      );
    }),
  );

  return buildMaterialSurfaceCard(
    colorScheme,
    hasCustomWallpaper: hasCustomWallpaper,
    shadowAlpha: 0.22,
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
                onTap: onPickEmojiTapback,
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
  );
}

Widget buildMaterialSurfaceCard(
  ColorScheme colorScheme, {
  required bool hasCustomWallpaper,
  required double shadowAlpha,
  required Widget child,
}) =>
    Material(
      color: hasCustomWallpaper
          ? colorScheme.surfaceContainerHigh.withValues(alpha: 0.94)
          : colorScheme.surfaceContainerHigh,
      elevation: 6,
      shadowColor: colorScheme.shadow.withValues(alpha: shadowAlpha),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(M3EShapes.xl),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: child),
    );

Widget buildMaterialDockedToolbar(
  BuildContext context, {
  required List<DetailsMenuActionWidget> allActions,
  required bool hasCustomWallpaper,
}) {
  if (allActions.isEmpty) return const SizedBox.shrink();

  final colorScheme = context.theme.colorScheme;
  final bool hasOverflow = allActions.length > 5;
  final visibleActions = hasOverflow ? allActions.sublist(0, 4) : allActions;
  final overflowActions = hasOverflow ? allActions.sublist(4) : const <DetailsMenuActionWidget>[];

  Color actionColor(DetailsMenuActionWidget a) => (a.shouldDisableBtn ?? false)
      ? colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
      : a.action == DetailsMenuAction.Delete
          ? colorScheme.error
          : colorScheme.onSurfaceVariant;

  Widget toolbarLabel(IconData icon, String title, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: context.theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );

  return buildMaterialSurfaceCard(
    colorScheme,
    hasCustomWallpaper: hasCustomWallpaper,
    shadowAlpha: 0.25,
    child: Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        ...visibleActions.map((action) {
          final isDisabled = action.shouldDisableBtn ?? false;
          return Expanded(
            child: Tooltip(
              message: action.title,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(M3EShapes.lg),
                  onTap: isDisabled ? null : action.onTap,
                  child: toolbarLabel(action.nonIosIcon, action.title, actionColor(action)),
                ),
              ),
            ),
          );
        }),
        if (overflowActions.isNotEmpty)
          Expanded(
            child: PopupMenuButton<int>(
              tooltip: 'More actions',
              color: hasCustomWallpaper
                  ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.94)
                  : colorScheme.surfaceContainerHighest,
              shape: const RoundedRectangleBorder(borderRadius: M3EShapes.radiusLg),
              onSelected: (index) {
                final selected = overflowActions[index];
                if (!(selected.shouldDisableBtn ?? false)) selected.onTap?.call();
              },
              itemBuilder: (context) => overflowActions.mapIndexed((index, action) {
                final color = actionColor(action);
                return PopupMenuItem<int>(
                  value: index,
                  enabled: !(action.shouldDisableBtn ?? false),
                  child: Row(
                    children: [
                      Icon(action.nonIosIcon, size: 20, color: color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(action.title, style: context.textTheme.bodyMedium?.copyWith(color: color)),
                      ),
                    ],
                  ),
                );
              }).toList(),
              child: toolbarLabel(Icons.more_horiz, 'More', colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    ),
  );
}

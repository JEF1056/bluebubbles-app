import 'dart:math';
import 'dart:ui';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/components/m3e/m3e_shapes.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/sticker_tapback_image.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/tapback_icon.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Opens Google Messages' vertical Reaction Summary sheet (`eyov.java`, `apda.java`, `apdk.java`)
/// for Material skin (Android & Web/Desktop).
Future<void> showMaterialReactionDetailsSheet(
  BuildContext context, {
  required List<Message> reactions,
  ValueChanged<Message>? onRemoveOwnReaction,
}) {
  final capturedTheme = context.theme;
  final isWide = MediaQuery.sizeOf(context).width >= 600;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: isWide ? const BoxConstraints(maxWidth: 440) : null,
    builder: (sheetContext) => Theme(
      data: capturedTheme,
      child: Padding(
        padding: isWide ? const EdgeInsets.only(bottom: 16) : EdgeInsets.zero,
        child: ReactionDetails(
          reactions: reactions,
          onRemoveOwnReaction: onRemoveOwnReaction != null
              ? (own) {
                  Navigator.of(sheetContext).pop();
                  onRemoveOwnReaction(own);
                }
              : null,
        ),
      ),
    ),
  );
}

class ReactionDetails extends StatefulWidget {
  const ReactionDetails({
    super.key,
    required this.reactions,
    this.onRemoveOwnReaction,
  });

  final List<Message> reactions;
  final ValueChanged<Message>? onRemoveOwnReaction;

  @override
  State<ReactionDetails> createState() => _ReactionDetailsState();
}

class _ReactionDetailsState extends State<ReactionDetails> {
  /// Selected reaction filter key in Material summary sheet (`null` = All).
  String? _selectedFilterKey;

  String _groupKey(Message m) {
    final type = m.associatedMessageType ?? '';
    return ReactionTypes.isStickerTapback(type) ? 'sticker:${m.guid}' : 'emoji:${ReactionTypes.emojiFor(m)}';
  }

  String _displayNameFor(Message message) {
    if (message.isFromMe ?? false) {
      return 'You';
    }
    final handle = message.handle ?? message.handleRelation.target;
    if (handle != null) {
      final name = HandleSvc.getOrCreateHandleState(handle).reactionDisplayName.value;
      if (name != null && name.isNotEmpty) return name;
      if (handle.displayName.isNotEmpty) return handle.displayName;
      if (handle.address.isNotEmpty) return handle.address;
    }
    return 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (CurrentSkin.material) {
        return _buildMaterial(context);
      }
      return _buildCupertino(context);
    });
  }

  /// Google Messages Reaction Summary sheet (`eyov.java#L73-340`, `apda.java#L15`, `apdk.java`).
  Widget _buildMaterial(BuildContext context) {
    final theme = context.theme;
    final cs = theme.colorScheme;
    final isWide = MediaQuery.sizeOf(context).width >= 600;
    final reactions = widget.reactions;

    // Build ordered reaction groups for optional filter chips when >1 unique type exists.
    final Map<String, List<Message>> groups = {};
    for (final m in reactions) {
      groups.putIfAbsent(_groupKey(m), () => []).add(m);
    }
    final activeFilter = _selectedFilterKey != null && groups.containsKey(_selectedFilterKey)
        ? _selectedFilterKey
        : null;
    final visible = activeFilter == null ? reactions : groups[activeFilter]!;

    final sheetRadius = isWide
        ? BorderRadius.circular(M3EShapes.xl)
        : const BorderRadius.vertical(top: Radius.circular(M3EShapes.xl));

    final maxListHeight = min(380.0, MediaQuery.sizeOf(context).height * 0.5);

    return Material(
      color: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      borderRadius: sheetRadius,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // M3 drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            // Header ("Reactions" + total count pill, apda.java#L15)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Reactions',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${reactions.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Filter pills only when multiple distinct reaction types exist (skip redundant chrome for 1 type)
            if (groups.length > 1)
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _FilterChipPill(
                      selected: activeFilter == null,
                      label: 'All ${reactions.length}',
                      onTap: () => setState(() => _selectedFilterKey = null),
                    ),
                    for (final entry in groups.entries) ...[
                      const SizedBox(width: 8),
                      _FilterChipPill(
                        selected: activeFilter == entry.key,
                        isSticker: ReactionTypes.isStickerTapback(entry.value.first.associatedMessageType),
                        stickerAttachment: entry.value.first.dbAttachments.firstOrNull,
                        label: ReactionTypes.isStickerTapback(entry.value.first.associatedMessageType)
                            ? (entry.value.length > 1 ? '${entry.value.length}' : '')
                            : '${ReactionTypes.emojiFor(entry.value.first)} ${entry.value.length}',
                        onTap: () => setState(() => _selectedFilterKey = entry.key),
                      ),
                    ],
                  ],
                ),
              ),
            if (groups.length > 1) const SizedBox(height: 8),
            // Vertical sender list (eyov.b / eyov.d: 40dp avatar, sender name, optional "Tap to remove", trailing glyph)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                physics: ThemeSwitcher.getScrollPhysics(),
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final message = visible[index];
                  final handle = message.handle ?? message.handleRelation.target;
                  final isOwn = message.isFromMe ?? false;
                  final isSticker = ReactionTypes.isStickerTapback(message.associatedMessageType);
                  final canRemove = isOwn && widget.onRemoveOwnReaction != null;

                  return InkWell(
                    key: ValueKey('material-rxn-row-${message.guid ?? index}'),
                    onTap: canRemove ? () => widget.onRemoveOwnReaction!(message) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Row(
                        children: [
                          ContactAvatarWidget(
                            handle: handle,
                            size: 40,
                            borderThickness: 0,
                            editable: false,
                            fontSize: 16,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _displayNameFor(message),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: cs.onSurface,
                                    fontWeight: isOwn ? FontWeight.w500 : FontWeight.w400,
                                  ),
                                ),
                                if (canRemove)
                                  Text(
                                    'Tap to remove',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (isSticker)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(M3EShapes.md),
                              child: SizedBox.square(
                                dimension: 48,
                                child: StickerTapbackImage(attachment: message.dbAttachments.firstOrNull),
                              ),
                            )
                          else
                            Text(
                              ReactionTypes.emojiFor(message),
                              textScaler: TextScaler.noScaling,
                              style: const TextStyle(
                                fontSize: 24,
                                height: 1.0,
                                fontFamilyFallback: ['Noto Color Emoji', 'Apple Color Emoji', 'Segoe UI Emoji'],
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Preserved iOS / Samsung frosted horizontal reaction inspector.
  Widget _buildCupertino(BuildContext context) {
    final reactions = widget.reactions;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          alignment: Alignment.center,
          height: 120,
          color: context.theme.colorScheme.surfaceContainerHighest
              .withAlpha(SettingsSvc.settings.skin.value == Skins.iOS ? 150 : 255),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            child: ListView.separated(
              shrinkWrap: true,
              physics: ThemeSwitcher.getScrollPhysics(),
              scrollDirection: Axis.horizontal,
              findChildIndexCallback: (key) => findChildIndexByKey(reactions, key, (item) => item.guid),
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final message = reactions[index];
                final handle = message.handleRelation.target;
                // A failed removal is drawn as the tapback it was taking back
                final type = ReactionTypes.addedType(message.associatedMessageType);
                final svg = ReactionTypes.toList().contains(type);
                String? reactionName;
                if (!SettingsSvc.settings.hideNamesForReactions.value) {
                  if (message.isFromMe!) {
                    reactionName = SettingsSvc.settings.userName.value;
                  } else if (handle != null) {
                    reactionName = HandleSvc.getOrCreateHandleState(handle).reactionDisplayName.value;
                  }
                }
                return Column(
                  key: ValueKey(message.guid!),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 25.0, vertical: 10),
                      child: ContactAvatarWidget(
                        handle: handle,
                        borderThickness: 0.1,
                        editable: false,
                        fontSize: 22,
                      ),
                    ),
                    if (reactionName != null && reactionName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          reactionName,
                          style: context.theme.textTheme.bodySmall!
                              .copyWith(color: context.theme.colorScheme.onSurfaceVariant),
                        ),
                      )
                    else
                      const SizedBox(height: 8),
                    Container(
                      height: 28,
                      width: 28,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(100),
                        color: message.isFromMe!
                            ? context.theme.colorScheme.primary
                            : context.theme.colorScheme.surfaceContainerHighest,
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 1.0,
                            color: context.theme.colorScheme.outline,
                          )
                        ],
                      ),
                      child: Padding(
                        padding: svg
                            ? const EdgeInsets.only(top: 8.0, left: 7.0, right: 7.0, bottom: 7.0)
                                .add(EdgeInsets.only(right: type == "emphasize" ? 1 : 0))
                            : EdgeInsets.zero,
                        child: svg
                            ? TapbackIcon(type!)
                            : Center(
                                child: Builder(builder: (context) {
                                  if (ReactionTypes.isStickerTapback(message.associatedMessageType)) {
                                    return StickerTapbackImage(attachment: message.dbAttachments.firstOrNull);
                                  }
                                  return Text(
                                    ReactionTypes.emojiFor(message),
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontFamilyFallback: ["Apple Color Emoji", "Noto Color Emoji", "Segoe UI Emoji"],
                                    ),
                                    textAlign: TextAlign.center,
                                  );
                                }),
                              ),
                      ),
                    )
                  ],
                );
              },
              itemCount: reactions.length,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterChipPill extends StatelessWidget {
  const _FilterChipPill({
    required this.selected,
    required this.label,
    required this.onTap,
    this.isSticker = false,
    this.stickerAttachment,
  });

  final bool selected;
  final String label;
  final VoidCallback onTap;
  final bool isSticker;
  final Attachment? stickerAttachment;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final cs = theme.colorScheme;
    final bg = selected ? cs.secondaryContainer : cs.surfaceContainerHighest;
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSticker) ...[
                ClipOval(
                  child: SizedBox.square(
                    dimension: 20,
                    child: StickerTapbackImage(attachment: stickerAttachment),
                  ),
                ),
                if (label.isNotEmpty) const SizedBox(width: 4),
              ],
              if (label.isNotEmpty)
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    fontFamilyFallback: const ['Noto Color Emoji', 'Apple Color Emoji', 'Segoe UI Emoji'],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

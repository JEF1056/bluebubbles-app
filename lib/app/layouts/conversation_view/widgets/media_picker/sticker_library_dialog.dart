import 'dart:async';

import 'package:bluebubbles/app/components/subscription_required.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/attachment_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/composer_popover.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_tile.dart';
import 'package:bluebubbles/models/library_sticker.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// The desktop/Web composer's Stickers popover above [anchorContext]. Tap a sticker to send it standalone, or drag a
/// sticker out onto a message bubble to peel and place it there; the popover hides once the drag leaves it and closes
/// when it ends. Only open this when `ServerDetails.supportsStickers`.
Future<void> showStickerLibraryPopover(BuildContext anchorContext, ConversationViewController controller) async {
  if (isStickerSubscriptionLocked) {
    return showSubscriptionRequired(
      anchorContext,
      feature: ProFeature.stickers,
      onUnlocked: () => anchorContext.mounted ? showStickerLibraryPopover(anchorContext, controller) : null,
    );
  }
  // The cached library draws at once; this brings it up to date behind it
  unawaited(StickerLibrarySvc.sync());
  await showComposerPopover(
    anchorContext,
    controller,
    builder: (context) => ComposerPopoverCard(
      child: StickerLibraryView(
        controller: controller,
        onPicked: (sticker) {
          Navigator.of(context).pop();
          unawaited(AttachmentActions.sendStandaloneSticker(controller, sticker));
        },
        onClose: () => Navigator.of(context).pop(),
        draggable: true,
        // Hidden rather than closed while the drag is out: closing would cancel it
        onDragUpdate: (details) {
          final hidden = ComposerPopoverScope.of(context);
          // `context` is the popover's own box
          final box = context.findRenderObject() as RenderBox?;
          if (hidden == null || hidden.value || box == null || !box.attached) return;
          if (!(box.localToGlobal(Offset.zero) & box.size).contains(details.globalPosition)) hidden.value = true;
        },
        // Escape closes the popover mid-drag, which cancels the drag (navigating cancels pointers): then it's no
        // longer the current route, and popping again would close the conversation
        onDragEnd: () {
          if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) return;
          if (ComposerPopoverScope.of(context)?.value ?? false) Navigator.of(context).pop();
        },
      ),
    ),
  );
}

/// The library itself: Recents and All Stickers shelves, with a `+ Add Sticker` button. [onPicked], when set,
/// overrides tapping a sticker (otherwise tapping sends it standalone via [controller]). Without [title] it leaves the
/// heading to its container (the emoji tapback picker's Stickers tab). [showHeader] hides the top bar when embedded in
/// a drawer that provides its own controls. [onClose] adds a close button. [draggable] lets stickers be dragged onto
/// messages ([StickerDropTarget]), calling [onDragUpdate] and [onDragEnd].
class StickerLibraryView extends StatefulWidget {
  const StickerLibraryView({
    super.key,
    this.controller,
    this.onPicked,
    this.title = true,
    this.showHeader = true,
    this.onClose,
    this.draggable = false,
    this.onDragUpdate,
    this.onDragEnd,
    this.onAddSticker,
  });

  final ConversationViewController? controller;
  final ValueChanged<LibrarySticker>? onPicked;
  final bool title;
  final bool showHeader;
  final VoidCallback? onClose;
  final bool draggable;
  final DragUpdateCallback? onDragUpdate;
  final VoidCallback? onDragEnd;
  final Future<void> Function()? onAddSticker;

  @override
  State<StickerLibraryView> createState() => _StickerLibraryViewState();
}

class _StickerLibraryViewState extends State<StickerLibraryView> {
  Future<void> _handleAddSticker() => (widget.onAddSticker ?? pickAndAddSticker)();

  void _handleStickerTap(LibrarySticker sticker) {
    if (widget.onPicked != null) {
      widget.onPicked!(sticker);
    } else if (widget.controller != null) {
      unawaited(AttachmentActions.sendStandaloneSticker(widget.controller!, sticker));
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = StickerLibrarySvc;
    return Column(
      children: [
        if (widget.showHeader && (widget.title || widget.onClose != null || !isStickerSubscriptionLocked))
          _header(),
        Expanded(
          child: Obx(() {
            // The cached library stays on disk for when the subscription comes back
            if (isStickerSubscriptionLocked) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SubscriptionRequiredCard(feature: ProFeature.stickers),
                      if (SubscriptionSvc.offline)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: TextButton(onPressed: retrySubscriptionCheck, child: Text("Retry")),
                        )
                      else if (SubscriptionSvc.purchaseUrl.value != null)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: TextButton(onPressed: openSubscriptionPage, child: Text("Learn More")),
                        ),
                    ],
                  ),
                ),
              );
            }
            final stickers = svc.entries.toList();
            if (stickers.isEmpty) {
              if (!svc.loaded.value || svc.syncing.value) return const Center(child: CircularProgressIndicator());
              final error = svc.syncError.value;
              if (error != null) {
                return _message(
                  error,
                  actionLabel: "Retry",
                  onAction: svc.sync,
                );
              }
              return _message(
                svc.unavailableReason.value ?? "No stickers yet",
                actionLabel: canEditStickers ? "Add Sticker" : null,
                onAction: canEditStickers ? _handleAddSticker : null,
              );
            }
            final recent = stickers.where((s) => !s.isSaved).toList();
            final saved = stickers.where((s) => s.isSaved).toList();
            final hairline = context.theme.colorScheme.outlineVariant.withValues(alpha: 0.45);
            return CustomScrollView(
              slivers: [
                if (recent.isNotEmpty) ..._section("Recents", recent),
                if (recent.isNotEmpty && saved.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Divider(height: 1, thickness: 1, color: hairline),
                    ),
                  ),
                if (saved.isNotEmpty) ..._section("All Stickers", saved),
                const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _header() {
    final scheme = context.theme.colorScheme;
    final hairline = scheme.outlineVariant.withValues(alpha: 0.45);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final titleWidget = widget.title
                  ? Text(
                      "Stickers",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    )
                  : const SizedBox();
              final refreshWidget = !isStickerSubscriptionLocked
                  ? Obx(
                      () => StickerLibrarySvc.syncing.value
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              icon: Icon(Icons.refresh_rounded, size: 24, color: scheme.onSurfaceVariant),
                              tooltip: "Refresh",
                              onPressed: StickerLibrarySvc.sync,
                            ),
                    )
                  : null;
              final addWidget = canEditStickers
                  ? Obx(
                      () => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: StickerLibrarySvc.adding.value
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : TextButton.icon(
                                onPressed: _handleAddSticker,
                                style: TextButton.styleFrom(
                                  backgroundColor: scheme.primary.withValues(alpha: 0.12),
                                  foregroundColor: scheme.primary,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  minimumSize: const Size(48, 48),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                icon: const Icon(Icons.add_rounded, size: 18),
                                label: const Text("Add Sticker", maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                      ),
                    )
                  : null;
              final closeWidget = widget.onClose != null
                  ? IconButton(
                      icon: Icon(Icons.close_rounded, size: 24, color: scheme.onSurfaceVariant),
                      tooltip: "Close",
                      onPressed: widget.onClose,
                    )
                  : null;

              final stackAddRow = widget.title && addWidget != null && constraints.maxWidth < MediaQuery.textScalerOf(context).scale(260);
              if (stackAddRow) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: titleWidget),
                        ?refreshWidget,
                        ?closeWidget,
                      ],
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: addWidget,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: titleWidget),
                  ?refreshWidget,
                  if (addWidget != null) Flexible(child: addWidget),
                  ?closeWidget,
                ],
              );
            },
          ),
        ),
        Divider(height: 1, thickness: 1, color: hairline),
      ],
    );
  }

  Widget _message(String text, {String? actionLabel, VoidCallback? onAction}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: context.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(actionLabel == "Retry" ? Icons.refresh_rounded : Icons.add_rounded, size: 18),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    ),
  );

  List<Widget> _section(String title, List<LibrarySticker> stickers) => [
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      sliver: SliverToBoxAdapter(
        child: Text(
          title,
          style: context.textTheme.labelMedium!.copyWith(
            color: context.theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 76,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: stickers.length,
        itemBuilder: (context, i) => Tooltip(
          message: stickers[i].label ?? "",
          child: StickerLibraryTile(
            key: ValueKey("sticker-tile-${stickers[i].identifier}"),
            sticker: stickers[i],
            onTap: (widget.onPicked != null || widget.controller != null)
                ? () => _handleStickerTap(stickers[i])
                : null,
            draggable: widget.draggable,
            onDragUpdate: widget.onDragUpdate,
            onDragEnd: widget.onDragEnd,
          ),
        ),
      ),
    ),
  ];
}

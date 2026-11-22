import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/attachment_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/buttons/text_field_button.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/buttons/text_field_button_drag.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// The desktop composer's `+` menu: every supported [TextFieldButton] that isn't already in
/// the composer row ([inRow]). Items drag out onto the row to move them there; a row button dragged over `+` opens
/// the menu with the button previewed where it would go ([TextFieldButtonDrag]).
///
/// Wraps the `+` button: [builder] gets a callback that opens or closes the menu. The menu
/// opens above the button when there's no room below (always, in the composer) and scrolls
/// when the window is too short for it.
class DesktopAttachmentMenu extends StatefulWidget {
  const DesktopAttachmentMenu({
    super.key,
    required this.controller,
    required this.builder,
    required this.inRow,
    this.arrangeable = false,
  });

  final ConversationViewController controller;
  final List<TextFieldButton> inRow;

  /// Whether its items drag to and from a button row. The chat creator's menu has no row to drag to
  final bool arrangeable;
  final Widget Function(BuildContext context, VoidCallback toggle) builder;

  @override
  State<DesktopAttachmentMenu> createState() => _DesktopAttachmentMenuState();
}

const Map<TextFieldButton, IconData> desktopMenuIcons = {
  TextFieldButton.Files: Icons.folder_rounded,
  TextFieldButton.Genmoji: Icons.add_reaction_rounded,
  TextFieldButton.Stickers: Icons.sticky_note_2_rounded,
  TextFieldButton.Handwritten: Icons.draw_rounded,
  TextFieldButton.Schedule: Icons.schedule_rounded,
  TextFieldButton.Location: Icons.location_on_rounded,
  TextFieldButton.Gif: Icons.gif_box_rounded,
  TextFieldButton.Emoji: Icons.emoji_emotions_rounded,
};

/// A menu item as the menu draws it, for a flight landing in the menu when it couldn't snapshot the real one.
/// [width] is the real one's, when known.
Widget desktopMenuTileLook(BuildContext context, TextFieldButton b, {double? width}) =>
    SizedBox(width: width, child: _menuItem(context, b, () {}));

Widget _menuItem(BuildContext context, TextFieldButton b, VoidCallback onPressed) {
  final icon = desktopMenuIcons[b]!;
  final scheme = context.theme.colorScheme;
  return MenuItemButton(
    onPressed: onPressed,
    style: MenuItemButton.styleFrom(
      minimumSize: const Size(220, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    leadingIcon: Icon(icon, size: 24, color: scheme.onSurfaceVariant),
    child: Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(b.label, style: context.theme.textTheme.bodyLarge),
    ),
  );
}

class _DesktopAttachmentMenuState extends State<DesktopAttachmentMenu> {
  final MenuController _menu = MenuController();

  /// Opened by a button dragged over `+`, so it closes again when that drag ends anywhere but in it
  bool _openedByDrag = false;
  Timer? _leaveTimer;
  late final Worker _dragEnded;

  ConversationViewController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Not on leaving it: crossing from `+` into the menu, or a stray move off it, would close it under the drag
    _dragEnded = ever(TextFieldButtonDrag.dragged, (TextFieldButton? b) {
      if (b != null || !_openedByDrag) return;
      _openedByDrag = false;
      _menu.close();
    });
  }

  @override
  void dispose() {
    _leaveTimer?.cancel();
    _dragEnded.dispose();
    super.dispose();
  }

  /// Runs [action] once the menu has closed, so a dialog it opens isn't fighting the menu's
  /// focus scope.
  void _run(FutureOr<void> Function() action) {
    _menu.close();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await action();
    });
  }

  void _enter() {
    _leaveTimer?.cancel();
    TextFieldButtonDrag.enterMenu();
    if (!_menu.isOpen) {
      _menu.open();
      _openedByDrag = true;
    }
  }

  // Delayed, so crossing the gap from `+` up into the menu doesn't close the preview and open it again. Entering the
  // row moves the preview there at once, so this only lingers over empty space
  void _leave() {
    _leaveTimer?.cancel();
    _leaveTimer = Timer(const Duration(milliseconds: 250), TextFieldButtonDrag.leaveMenu);
  }

  Widget _target(Widget child) => !widget.arrangeable ? child : DragTarget<TextFieldButton>(
    onWillAcceptWithDetails: (_) {
      _enter();
      return true;
    },
    onLeave: (_) => _leave(),
    onAcceptWithDetails: (details) {
      _leaveTimer?.cancel();
      _openedByDrag = false;
      TextFieldButtonDrag.dropOnMenu(context, details.offset);
    },
    builder: (_, _, _) => child,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    return Obx(() {
      // Read here: DragTarget builders run outside this Obx's tracking
      final dragged = TextFieldButtonDrag.dragged.value;
      final overMenu = TextFieldButtonDrag.overMenu.value;
      final inRowPreview = TextFieldButtonDrag.rowIndex.value != null;
      final flying = TextFieldButtonDrag.flying.value;
      final snapping = TextFieldButtonDrag.snap.value;
      bool shown(TextFieldButton b) => widget.inRow.contains(b)
          ? b == dragged && overMenu
          // A menu item dragged to the row leaves the menu while it's previewed there
          : !(b == dragged && inRowPreview);
      // Nothing to show (the last item dragged out, or a preview that left): no empty panel. Hovering `+` reopens it
      if (_menu.isOpen && !TextFieldButton.values.platformSupportedButtons.any(shown)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _menu.close();
        });
      }
      return MenuAnchor(
        controller: _menu,
        alignmentOffset: const Offset(0, 6),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          elevation: const WidgetStatePropertyAll(2),
          // The padding is the spacers below, so a drag over it is still over the menu
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
            ),
          ),
        ),
        menuChildren: [
          _target(const SizedBox(width: 220, height: 8)),
          // Every button has a place, open or closed, so a dragged one's preview slides open in its own spot
          for (final b in TextFieldButton.values.platformSupportedButtons)
            TextFieldButtonDrag.slides(
              key: ValueKey(b),
              snapping: snapping,
              alignment: Alignment.topCenter,
              _entry(
                b,
                dragged: b == dragged,
                flying: flying,
                show: shown(b),
              ),
            ),
          _target(const SizedBox(width: 220, height: 8)),
        ],
        builder: (context, menu, _) => _target(widget.builder(context, () {
          if (menu.isOpen) {
            menu.close();
            return;
          }
          // Anchor above the top edge of the composer pill when multiline text expands it.
          final anchorBox = context.findRenderObject() as RenderBox?;
          final composerBox = controller.textFieldKey.currentContext?.findRenderObject() as RenderBox?;
          if (anchorBox != null && anchorBox.attached && composerBox != null && composerBox.attached) {
            final anchorTop = anchorBox.localToGlobal(Offset.zero).dy;
            final composerTop = composerBox.localToGlobal(Offset.zero).dy;
            final dy = composerTop - anchorTop;
            if (dy < -1.0) {
              menu.open(position: Offset(0, dy - 6.0));
              return;
            }
          }
          menu.open();
        })),
      );
    });
  }

  Widget _entry(TextFieldButton b, {required bool dragged, required bool flying, required bool show}) {
    if (!show) return const SizedBox(width: 220);
    final item = _menuItem(context, b, () => _run(() => AttachmentActions.run(b, context, controller)));
    // Faded where a drop would put it: a row button previewed here, or a menu item dragged nowhere yet. Shown from
    // the drag state rather than as childWhenDragging, so it stays until the drop's flight lands
    if (dragged) {
      return _target(
        Opacity(
          opacity: flying ? 0 : 0.3,
          // Inside the fade, so a drop's flight can snapshot the item as it lands
          child: RepaintBoundary(key: TextFieldButtonDrag.menuSlot, child: item),
        ),
      );
    }
    if (!widget.arrangeable) return item;
    // Held, like the row's buttons: a plain drag starts on a pixel of movement and would eat shaky clicks
    return _target(
      LongPressDraggable<TextFieldButton>(
        data: b,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: centeredDragFeedback(Icon(b.icon, size: 28, color: context.theme.colorScheme.outline)),
        onDragStarted: () => TextFieldButtonDrag.start(b),
        // These run even though the faded entry replaces this
        onDraggableCanceled: (_, offset) => TextFieldButtonDrag.cancel(context, offset),
        child: item,
      ),
    );
  }
}

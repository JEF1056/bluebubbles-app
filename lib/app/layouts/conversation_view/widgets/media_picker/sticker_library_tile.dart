import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/attachment_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/library_sticker.dart';
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

/// Whether the sticker subscription gate is active (safe in tests where [SubscriptionService] isn't registered).
bool get isStickerSubscriptionLocked => GetIt.I.isRegistered<SubscriptionService>() && SubscriptionSvc.locked;

/// Whether stickers can be added to or removed from the Mac's library here.
bool get canEditStickers =>
    (SettingsSvc.settings.enablePrivateAPI.value || SettingsSvc.getServerDetails().privateApiEnabled != false) &&
    !isStickerSubscriptionLocked;

/// Picks an image on Mobile or Web and adds it to the Mac's sticker library, where it lands in Recents. A refusal
/// shows the server's reason.
Future<void> pickAndAddSticker({
  Future<({Uint8List bytes, String name})?> Function()? onPickImage,
}) async {
  Uint8List? bytes;
  String? name;
  if (onPickImage != null) {
    final picked = await onPickImage();
    if (picked == null) return;
    bytes = picked.bytes;
    name = picked.name;
  } else {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return;
    bytes = await file.readAsBytes();
    name = file.name;
  }
  try {
    await StickerLibrarySvc.add(bytes, name);
  } catch (e, s) {
    Logger.warn("Failed to add a sticker to the library", error: e, trace: s, tag: "StickerLibrary");
    showSnackbar("Error", stickerRefusal(e).message ?? "Couldn't add the sticker", type: SnackbarType.error);
  }
}

/// Whether stickers can be removed from the Mac's library here: the server's Private API does it.
bool get canRemoveStickers => canEditStickers;

/// Builds a sticker thumbnail widget using in-memory bytes (Web / tests) or on-disk file cache (native).
Widget buildStickerThumbnailImage(
  String identifier, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  Widget? errorWidget,
}) {
  final memBytes = StickerLibrarySvc.thumbnailBytes(identifier);
  if (memBytes != null) {
    return Image.memory(
      memBytes,
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => errorWidget ?? const SizedBox.shrink(),
    );
  }
  if (!kIsWeb) {
    return Image.file(
      StickerLibrarySvc.thumbnailFile(identifier),
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => errorWidget ?? const SizedBox.shrink(),
    );
  }
  return errorWidget ?? const SizedBox.shrink();
}

/// Asks, then removes [sticker] from the Mac's library. A refusal shows the server's reason.
Future<void> confirmRemoveSticker(BuildContext context, LibrarySticker sticker) async {
  final confirmed = Completer<bool>();
  await showAreYouSure(
    context,
    title: "Remove Sticker?",
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (StickerLibrarySvc.cachedThumbnails.contains(sticker.identifier)) ...[
          buildStickerThumbnailImage(sticker.identifier, width: 88, height: 88),
          const SizedBox(height: 12),
        ],
        const Text("This sticker will be removed from your Mac's stickers.", textAlign: TextAlign.center),
      ],
    ),
    noText: "Cancel",
    yesText: "Remove",
    yesIsDestructive: true,
    yesColor: context.theme.colorScheme.error,
    onNo: () {
      Navigator.of(context, rootNavigator: true).pop();
      confirmed.complete(false);
    },
    onYes: () {
      Navigator.of(context, rootNavigator: true).pop();
      confirmed.complete(true);
    },
  );
  // Dismissed by tapping outside: neither button ran
  if (!confirmed.isCompleted || !await confirmed.future) return;
  try {
    await StickerLibrarySvc.delete(sticker);
  } catch (e, s) {
    Logger.warn("Failed to remove a sticker from the library", error: e, trace: s, tag: "StickerLibrary");
    showSnackbar("Couldn't Remove Sticker", stickerRefusal(e).message ?? "Couldn't reach your server to remove it.",
        type: SnackbarType.error);
    // The listing may be stale, which can be why it failed
    unawaited(StickerLibrarySvc.sync());
  }
}

/// A library sticker being dragged onto a message ([StickerDropTarget]), with the scale and rotation a second finger
/// has given it on the way.
class StickerDrag {
  StickerDrag(this.sticker);

  final LibrarySticker sticker;
  final ValueNotifier<({double scale, double rotation})> transform = ValueNotifier((scale: 1, rotation: 0));
}

/// One sticker from the Mac's library, drawn from the on-disk thumbnail cache ([StickerLibrarySvc]), with a
/// placeholder until it's there. Right-click, or on mobile a long press released without moving, offers to remove it
/// ([confirmRemoveSticker]) where that's possible.
class StickerLibraryTile extends StatefulWidget {
  const StickerLibraryTile({
    super.key,
    required this.sticker,
    this.onTap,
    this.draggable = false,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final LibrarySticker sticker;
  final VoidCallback? onTap;

  /// Lets it be dragged onto a message ([StickerDropTarget]), centered on the pointer: at once with a mouse, and after
  /// a long press on mobile, where a second finger scales and rotates it.
  final bool draggable;
  final DragUpdateCallback? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// The dragged sticker's size, about as large as one placed at scale 1
  static const double dragSize = 96;

  @override
  State<StickerLibraryTile> createState() => _StickerLibraryTileState();
}

class _StickerLibraryTileState extends State<StickerLibraryTile> {
  late StickerDrag _drag = StickerDrag(sticker);

  /// How far the current drag has gone, to tell a long press released in place (remove) from a drag
  double _dragDistance = 0;

  // The two fingers of a pinch during a mobile drag: the one dragging, and the one that came down after it
  int? _dragPointer;
  Offset _dragPosition = Offset.zero;
  int? _pinchPointer;
  Offset _pinchPosition = Offset.zero;

  /// The pinch's start: the fingers' distance and angle, and the sticker's transform then
  ({double distance, double angle, double scale, double rotation})? _pinchStart;

  LibrarySticker get sticker => widget.sticker;

  @override
  void didUpdateWidget(StickerLibraryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sticker.identifier != sticker.identifier) _drag = StickerDrag(sticker);
  }

  @override
  void dispose() {
    _stopPinching();
    super.dispose();
  }

  bool _pinching = false;

  void _startPinching() {
    if (_pinching) return;
    _pinching = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void _stopPinching() {
    if (_pinching) GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _pinching = false;
    _pinchPointer = null;
    _pinchStart = null;
  }

  // No larger than placed stickers draw, so it lands as it looked, on every device
  void _setTransform(double scale, double rotation) => _drag.transform.value =
      (scale: scale.clamp(0.4, StickerHolder.maxPoints / StickerLibraryTile.dragSize), rotation: rotation);

  // Sees every pointer on screen while dragging, so a second finger anywhere can pinch the sticker
  void _onPointer(PointerEvent event) {
    final t = _drag.transform.value;
    if (event.pointer == _dragPointer) {
      if (event is PointerMoveEvent) _dragPosition = event.position;
    } else if (event is PointerDownEvent && _pinchPointer == null) {
      _pinchPointer = event.pointer;
      _pinchPosition = event.position;
      final span = _pinchPosition - _dragPosition;
      _pinchStart = (distance: span.distance, angle: span.direction, scale: t.scale, rotation: t.rotation);
    } else if (event.pointer == _pinchPointer) {
      if (event is PointerMoveEvent) {
        _pinchPosition = event.position;
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        _pinchPointer = null;
        _pinchStart = null;
        return;
      }
    } else {
      return;
    }
    final start = _pinchStart;
    if (start == null || start.distance < 1) return;
    final span = _pinchPosition - _dragPosition;
    _setTransform(start.scale * span.distance / start.distance, start.rotation + span.direction - start.angle);
  }

  @override
  Widget build(BuildContext context) {
    final tile = _tile(context);
    if (!widget.draggable) return tile;
    final feedback = FractionalTranslation(
      translation: const Offset(-0.5, -0.5),
      child: ValueListenableBuilder(
        valueListenable: _drag.transform,
        builder: (_, t, child) => Transform.rotate(
          angle: t.rotation,
          child: Transform.scale(scale: t.scale, child: child),
        ),
        child: buildStickerThumbnailImage(
          sticker.identifier,
          width: StickerLibraryTile.dragSize,
          height: StickerLibraryTile.dragSize,
          fit: BoxFit.contain,
          errorWidget: const SizedBox.square(dimension: StickerLibraryTile.dragSize),
        ),
      ),
    );
    void onStarted() {
      _dragDistance = 0;
      _drag.transform.value = (scale: 1, rotation: 0);
    }

    void onUpdate(DragUpdateDetails details) {
      _dragDistance += details.delta.distance;
      _dragPosition = details.globalPosition;
      widget.onDragUpdate?.call(details);
    }

    if (kIsDesktop || kIsWeb) {
      return Draggable<StickerDrag>(
        data: _drag,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: onStarted,
        onDragUpdate: onUpdate,
        onDragEnd: (_) => widget.onDragEnd?.call(),
        feedback: feedback,
        childWhenDragging: Opacity(opacity: 0.4, child: tile),
        child: tile,
      );
    }
    return Listener(
      onPointerDown: (event) {
        _dragPointer = event.pointer;
        _dragPosition = event.position;
      },
      child: LongPressDraggable<StickerDrag>(
        data: _drag,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          onStarted();
          _startPinching();
        },
        onDragUpdate: onUpdate,
        onDragEnd: (_) {
          _stopPinching();
          widget.onDragEnd?.call();
        },
        onDraggableCanceled: (_, _) {
          final t = _drag.transform.value;
          final untouched = _dragDistance < 12 && t.scale == 1 && t.rotation == 0;
          if (untouched && canRemoveStickers && mounted) confirmRemoveSticker(context, sticker);
        },
        feedback: feedback,
        childWhenDragging: Opacity(opacity: 0.4, child: tile),
        child: tile,
      ),
    );
  }

  Widget _tile(BuildContext context) {
    final scheme = context.theme.colorScheme;
    final hairline = scheme.outlineVariant.withValues(alpha: 0.45);
    final placeholder = Center(
      child: Icon(Icons.sticky_note_2_outlined, size: 24, color: scheme.onSurfaceVariant.withValues(alpha: 0.45)),
    );
    return Obx(() {
      final sending = AttachmentActions.sendingStickers.contains(sticker.identifier);
      return Semantics(
        button: widget.onTap != null,
        label: sticker.label ?? "Sticker",
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Material(
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: sending ? null : widget.onTap,
              // A mobile draggable tile's long press starts the drag, and offers removal when released in place.
              // On desktop/Web or non-draggable tiles, long-press or right-click removes directly.
              onLongPress: canRemoveStickers && (!widget.draggable || kIsDesktop || kIsWeb)
                  ? () => confirmRemoveSticker(context, sticker)
                  : null,
              onSecondaryTap: canRemoveStickers ? () => confirmRemoveSticker(context, sticker) : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: StickerLibrarySvc.cachedThumbnails.contains(sticker.identifier)
                        ? buildStickerThumbnailImage(
                            sticker.identifier,
                            fit: BoxFit.contain,
                            errorWidget: placeholder,
                          )
                        : placeholder,
                  ),
                  if (sending)
                    ColoredBox(
                      color: scheme.scrim.withValues(alpha: 0.25),
                      child: const Center(child: CupertinoActivityIndicator()),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

class StickerAddTile extends StatelessWidget {
  const StickerAddTile({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    return Semantics(
      button: true,
      label: "Add Sticker",
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Material(
          color: scheme.primaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Obx(() {
            final adding = StickerLibrarySvc.adding.value;
            return InkWell(
              onTap: adding ? null : (onTap ?? pickAndAddSticker),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    adding
                        ? CupertinoActivityIndicator(color: scheme.onPrimaryContainer)
                        : Icon(Icons.add_photo_alternate_rounded, color: scheme.onPrimaryContainer, size: 24),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        "Add Sticker",
                        maxLines: 1,
                        style: context.theme.textTheme.labelMedium!.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

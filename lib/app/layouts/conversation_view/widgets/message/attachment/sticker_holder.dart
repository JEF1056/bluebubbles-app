import 'dart:math';

import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show StickerPlacement;
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';

/// A placed sticker as [StickerHolder.space] lays it out: where its sender put it, and its image's size in pixels
@immutable
class PlacedSticker {
  const PlacedSticker(this.placement, this.pixels);

  final StickerPlacement placement;
  final Size pixels;

  /// [attachment] as placed, or null when its image hasn't downloaded and decoded yet, so the
  /// bubble doesn't move for a sticker that isn't drawing. Falls back to [StickerPlacement.centeredDefault]
  /// if an ancient sticker lacks placement metadata.
  static PlacedSticker? of(Attachment attachment, Size? decoded) {
    if (decoded == null || !decoded.isFinite || decoded.width <= 0 || decoded.height <= 0) return null;
    final placement = StickerPlacement.tryParse(attachment.stickerPlacement) ?? StickerPlacement.centeredDefault;
    return PlacedSticker(placement, decoded);
  }

  @override
  bool operator ==(Object other) => other is PlacedSticker && other.placement == placement && other.pixels == pixels;

  @override
  int get hashCode => Object.hash(placement, pixels);
}

class StickerHolder extends StatefulWidget {
  const StickerHolder({
    super.key,
    required this.stickerMessages,
    this.controller,
    this.hidden = false,
    this.isFromMe = false,
    this.tailGutter = true,
  });
  final Iterable<Message> stickerMessages;
  final ConversationViewController? controller;

  /// Which side of the parent bubble its tail is on
  final bool isFromMe;

  /// Shrink the stickers out of view, e.g. while the message's details menu is open
  final bool hidden;

  /// Whether the parent bubble keeps a gutter for its tail. Media collections aren't clipped by [TailClipper], so
  /// they don't.
  final bool tailGutter;

  /// Where a sticker placed at [p] has its center, relative to a [bubble] of that size
  static Offset placedCenter(StickerPlacement p, Size bubble, bool isFromMe, bool tailGutter) {
    if (!bubble.isFinite || bubble.width <= 0 || bubble.height <= 0 || !p.xScalar.isFinite || !p.yScalar.isFinite) {
      return Offset.zero;
    }
    // The bubble's body: not the gutter its tail draws in (see TailClipper), and inset a little on the other side.
    // Material and media-collection bubbles have no tail, so their body spans the full bubble width symmetrically.
    final gutter = tailGutter ? _tailGutter : 0.0;
    final inset = tailGutter ? _bodyInset : 0.0;
    final left = isFromMe ? inset : gutter;
    final bodyWidth = max(0.0, bubble.width - gutter - inset);
    return Offset(left + p.xScalar * bodyWidth, p.yScalar * bubble.height);
  }

  /// The placement scale that draws a sticker image whose longest side is [pixels] at [points] on its longest side
  static double scaleForPoints(double points, double pixels) {
    final safePixels = (pixels.isFinite && pixels > 0) ? pixels : fallbackPixels;
    return points * _stickerPixelRatio / safePixels;
  }

  /// The inverse of [placedCenter]: the placement that centers an unrotated sticker at [center] in [bubble]
  static StickerPlacement placementAt(Offset center, Size bubble, bool isFromMe, bool tailGutter) {
    if (!bubble.isFinite || bubble.width <= 0 || bubble.height <= 0 || !center.dx.isFinite || !center.dy.isFinite) {
      return StickerPlacement.centeredDefault;
    }
    final gutter = tailGutter ? _tailGutter : 0.0;
    final inset = tailGutter ? _bodyInset : 0.0;
    final left = isFromMe ? inset : gutter;
    return StickerPlacement(
      xScalar: (center.dx - left) / max(1.0, bubble.width - gutter - inset),
      yScalar: center.dy / max(1.0, bubble.height),
      scale: 1,
      rotation: 0,
      parentPreviewWidth: bubble.width,
    );
  }

  /// [p]'s scale on a [bubble] of that size: it was placed on one [StickerPlacement.parentPreviewWidth] wide, and
  /// grows and shrinks with the bubble as Messages draws it
  static double drawScale(StickerPlacement p, Size bubble) {
    if (!p.isValid || !bubble.isFinite || bubble.width <= 0 || bubble.height <= 0) return 0;
    final scale = p.parentPreviewWidth > 0 ? p.scale * bubble.width / p.parentPreviewWidth : p.scale;
    return scale.isFinite && scale > 0 ? scale : 0;
  }

  /// Where a placed sticker draws (its rotated bounding box) relative to a [bubble] of that size
  static Rect placedRect(PlacedSticker sticker, Size bubble, bool isFromMe, bool tailGutter) {
    if (!bubble.isFinite ||
        bubble.width <= 0 ||
        bubble.height <= 0 ||
        !sticker.pixels.isFinite ||
        sticker.pixels.width <= 0 ||
        sticker.pixels.height <= 0) {
      return Rect.zero;
    }
    final p = sticker.placement;
    final rawScale = drawScale(p, bubble);
    if (rawScale <= 0) return Rect.zero;
    final scale = rawScale / _stickerPixelRatio;
    final cap = min(1.0, maxPoints / max(1.0, max(sticker.pixels.width, sticker.pixels.height) * scale));
    final w = sticker.pixels.width * scale * cap;
    final h = sticker.pixels.height * scale * cap;
    final cosA = cos(p.rotation).abs(), sinA = sin(p.rotation).abs();
    return Rect.fromCenter(
      center: placedCenter(p, bubble, isFromMe, tailGutter),
      width: w * cosA + h * sinA,
      height: w * sinA + h * cosA,
    );
  }

  /// Room [StickerSpace] adds around a [bubble] so it covers all of its placed [stickers]. On the column-edge side
  /// this moves the bubble inward (as Messages does), as far as the column allows.
  static EdgeInsets space(
      Iterable<PlacedSticker> stickers, Size bubble, bool isFromMe, bool tailGutter, double columnWidth) {
    if (!bubble.isFinite || bubble.width <= 0 || bubble.height <= 0 || !columnWidth.isFinite || columnWidth <= 0) {
      return EdgeInsets.zero;
    }
    double left = 0, top = 0, right = 0, bottom = 0;
    for (final sticker in stickers) {
      final rect = placedRect(sticker, bubble, isFromMe, tailGutter);
      if (rect.isEmpty || !rect.isFinite) continue;
      left = max(left, -rect.left);
      top = max(top, -rect.top);
      right = max(right, rect.right - bubble.width);
      bottom = max(bottom, rect.bottom - bubble.height);
    }
    final room = max(0.0, columnWidth - bubble.width);
    if (isFromMe) {
      right = min(right, room);
      left = min(left, room - right);
    } else {
      left = min(left, room);
      right = min(right, room - left);
    }
    return EdgeInsets.fromLTRB(left, top, right, bottom);
  }

  /// Size assumed for a sticker image whose dimensions the server didn't send
  static const double fallbackPixels = 300;

  /// Longest side a placed sticker draws at, however large its image or placement scale
  static const double maxPoints = 200;

  /// Pixels per point of a sticker image at scale 1, as Messages draws it on an iPhone
  static const double _stickerPixelRatio = 3;

  /// Kept clear on the tail side of a bubble: [TailClipper] draws its tail in the outer 10, and 2 more matched by eye
  /// against an iPhone's placement of the same stickers
  static const double _tailGutter = 12;

  /// Matched by eye against an iPhone's placement of the same stickers
  static const double _bodyInset = 4;

  @override
  State<StickerHolder> createState() => _StickerHolderState();
}

class _ActiveStickerDrag {
  _ActiveStickerDrag({
    required this.initial,
    required this.current,
    required this.startFocalPoint,
    required this.initialCenter,
  });

  final StickerPlacement initial;
  StickerPlacement current;
  final Offset startFocalPoint;
  final Offset initialCenter;
  bool changed = false;
}

class _StickerHolderState extends State<StickerHolder> {
  /// This holder's sticker attachments, in the order their messages were sent, so later stickers draw on top
  List<Attachment> _stickers = const [];

  /// Owning sticker [Message] per attachment [_keyOf], for ownership/GUID checks and DB persistence
  final Map<Object, Message> _messageByKey = {};

  /// Live placements while an own placed sticker is being dragged/scaled/rotated or awaiting the server reply
  final Map<Object, StickerPlacement> _dragging = {};

  /// Active scale-gesture tracking state keyed by [_keyOf]
  final Map<Object, _ActiveStickerDrag> _activeDrags = {};

  /// Keys ([_keyOf]) of the stickers whose image is on disk (or in memory on web), ready to draw
  final Set<Object> _ready = {};

  /// Cached sticker bytes for web / in-memory rendering, keyed by [_keyOf]
  final Map<Object, Uint8List> _bytes = {};

  /// Guids being downloaded, so an update doesn't add another callback to the same download. Keyed by guid rather
  /// than [_keyOf], since the guid names the file being fetched.
  final Set<String> _downloading = {};

  /// Keys whose image has drawn, so a new provider for the same sticker (its moved file) doesn't pop it in again
  final Set<Object> _shown = {};

  /// Where [_measure] reports each placed sticker's decoded size, for [StickerSpace]
  MessageState? _state;

  /// Guids of the placed stickers whose image size is being or has been read
  final Set<String> _measured = {};

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = MessageStateScope.maybeOf(context);
    if (!_loaded) {
      _loaded = true;
      loadStickers(inLifecycle: true);
    } else if (_state != null) {
      for (final attachment in _stickers) {
        if (_ready.contains(_keyOf(attachment))) _measure(attachment);
      }
    }
  }

  @override
  void didUpdateWidget(StickerHolder oldWidget) {
    super.didUpdateWidget(oldWidget);
    loadStickers(inLifecycle: true);
  }

  Future<void> loadStickers({bool inLifecycle = false}) async {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final messages = widget.stickerMessages.toList()
      ..sort((a, b) {
        final byDate = (a.dateCreated ?? epoch).compareTo(b.dateCreated ?? epoch);
        return byDate != 0 ? byDate : (a.id ?? 0).compareTo(b.id ?? 0);
      });
    // Rebuilt from the current messages each time, so a sticker that left (unsent) stops drawing here.
    // One per attachment row, in case two copies of a message link the same one; each key draws one widget.
    final byKey = <Object, Attachment>{};
    _messageByKey.clear();
    for (final message in messages) {
      for (final attachment in message.dbAttachments) {
        if (attachment.guid == null) continue;
        final key = _keyOf(attachment);
        byKey[key] = attachment;
        _messageByKey[key] = message;
      }
    }
    _stickers = byKey.values.toList();
    _rehydrateMissingPlacements(messages);
    final keys = _stickers.map(_keyOf).toSet();
    _ready.retainAll(keys);
    _bytes.removeWhere((k, _) => !keys.contains(k));
    _dragging.removeWhere((k, _) => !keys.contains(k));
    _activeDrags.removeWhere((k, _) => !keys.contains(k));

    bool awaited = false;
    for (final attachment in List.of(_stickers)) {
      final guid = attachment.guid!;
      final key = _keyOf(attachment);
      if (_ready.contains(key)) {
        _measure(attachment);
        continue;
      }
      if (_downloading.contains(guid)) continue;
      final inMemory = _bytes[key] ?? attachment.bytes;
      if (inMemory != null && inMemory.isNotEmpty) {
        _bytes[key] = inMemory;
        attachment.bytes ??= inMemory;
        _markReady(key, attachment, notify: !inLifecycle || awaited);
        continue;
      }
      if (kIsWeb) {
        Uint8List? bytes;
        try {
          awaited = true;
          bytes = await WebMediaCache.instance.get(WebMediaCache.attachmentsStore, guid);
        } catch (_) {}
        if (!mounted || _ready.contains(key) || _downloading.contains(guid)) continue;
        if (bytes != null && bytes.isNotEmpty) {
          _bytes[key] = bytes;
          attachment.bytes ??= bytes;
          _markReady(key, attachment);
        } else if (!guid.startsWith("temp")) {
          _downloading.add(guid);
          AttachmentDownloader.startDownload(
            attachment,
            onComplete: (file) {
              _downloading.remove(guid);
              final downloaded = file.bytes ?? attachment.bytes;
              if (downloaded != null && downloaded.isNotEmpty) {
                _bytes[key] = downloaded;
                attachment.bytes ??= downloaded;
                _markReady(key, attachment);
              }
            },
            onError: () => _downloading.remove(guid),
          );
        }
        continue;
      }
      awaited = true;
      final exists = await FileSystemEntity.type(attachment.path) != FileSystemEntityType.notFound;
      if (!mounted || _ready.contains(key) || _downloading.contains(guid)) continue;
      if (exists) {
        _markReady(key, attachment);
      } else {
        _downloading.add(guid);
        AttachmentDownloader.startDownload(
          attachment,
          onComplete: (_) {
            _downloading.remove(guid);
            _markReady(key, attachment);
          },
          onError: () => _downloading.remove(guid),
        );
      }
    }
  }

  /// A sent sticker keeps its attachment row id when the server's copy replaces it, so saved rows key on id
  /// while unsaved/web-only attachments fall back to guid.
  Object _keyOf(Attachment attachment) =>
      (attachment.id != null && attachment.id != 0) ? attachment.id! : attachment.guid!;

  void _markReady(Object key, Attachment attachment, {bool notify = true}) {
    if (!mounted) return;
    if (notify) {
      setState(() => _ready.add(key));
    } else {
      _ready.add(key);
    }
    _measure(attachment);
  }

  /// Reports a placed sticker's decoded size, so the room [StickerSpace] keeps for it matches what draws even when
  /// the attachment has no dimensions. It resolves the same provider [_image] draws, so it shares the decode.
  void _measure(Attachment attachment) {
    final state = _state;
    final guid = attachment.guid;
    if (state == null || guid == null || !_measured.add(guid)) return;
    final stream = _provider(attachment, StickerHolder._stickerPixelRatio).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronousCall) {
        final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
        info.dispose();
        stream.removeListener(listener);
        if (synchronousCall) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) state.updateStickerSizeInternal(guid, size);
          });
        } else {
          state.updateStickerSizeInternal(guid, size);
        }
      },
      onError: (_, _) {
        _measured.remove(guid);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  // Stickers ignore input unless they are own placed stickers being repositioned
  Widget _shrinkable(Widget child, {bool ignorePointer = true}) {
    final scaled = AnimatedScale(
      scale: widget.hidden ? 0 : 1,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      child: child,
    );
    return ignorePointer ? IgnorePointer(child: scaled) : scaled;
  }

  @override
  Widget build(BuildContext context) {
    final ready = _stickers
        .where((a) => _ready.contains(_keyOf(a)) && (!kIsWeb || (_bytes[_keyOf(a)] ?? a.bytes) != null))
        .toList();
    if (ready.isEmpty) return const SizedBox.shrink();
    return _buildPlaced(ready);
  }

  // The position is a fraction of the parent's size, so it's scaled by ours. `scale` applies to the sticker's own size.
  Widget _buildPlaced(List<Attachment> ready) {
    return LayoutBuilder(builder: (stackContext, constraints) {
      final bubble = constraints.biggest;
      if (!bubble.isFinite || bubble.width <= 0 || bubble.height <= 0) {
        return const SizedBox.shrink();
      }
      return Stack(
        clipBehavior: Clip.none,
        children: [
          for (final attachment in ready)
            _placed(
              attachment,
              StickerPlacement.tryParse(attachment.stickerPlacement) ?? StickerPlacement.centeredDefault,
              bubble,
              stackContext,
            ),
        ],
      );
    });
  }

  Widget _placed(Attachment attachment, StickerPlacement p, Size bubble, BuildContext stackContext) {
    final key = _keyOf(attachment);
    final effective = _dragging[key] ?? p;
    final scale = StickerHolder.drawScale(effective, bubble);
    if (!scale.isFinite || scale <= 0) return const SizedBox.shrink();
    final center = StickerHolder.placedCenter(effective, bubble, widget.isFromMe, widget.tailGutter);
    if (!center.dx.isFinite || !center.dy.isFinite) return const SizedBox.shrink();
    final maxConstraint = StickerHolder.maxPoints / max(0.01, scale);
    if (!maxConstraint.isFinite || maxConstraint <= 0) return const SizedBox.shrink();
    final message = _messageByKey[key];
    final msgGuid = message?.guid;
    final chat = widget.controller?.chat ?? ChatStateScope.maybeChatOf(context) ?? message?.chat.target;
    final isAttachmentTemp = attachment.guid?.startsWith("temp") ?? false;
    final isTemp = isAttachmentTemp ||
        msgGuid == null ||
        msgGuid.isEmpty ||
        msgGuid.startsWith("temp") ||
        msgGuid.startsWith("error");
    final canReposition = !widget.hidden &&
        !isTemp &&
        (message?.isFromMe ?? false) &&
        (chat?.isIMessage ?? false) &&
        (chat?.guid.isNotEmpty ?? false);

    final content = Transform.rotate(
      angle: effective.rotation,
      child: _shrinkable(
        Transform.scale(
          scale: scale,
          // Before the scale, so the cap is what draws
          child: ConstrainedBox(
            constraints: BoxConstraints.loose(Size.square(maxConstraint)),
            // Only a sticker still sending is new here: the one just dropped. It sticks rather than popping in.
            child: _StickIn(
              play: isAttachmentTemp && !_shown.contains(key),
              child: _image(
                attachment,
                FilterQuality.medium,
                StickerHolder._stickerPixelRatio,
                !isAttachmentTemp,
              ),
            ),
          ),
        ),
        ignorePointer: !canReposition,
      ),
    );

    return Positioned(
      key: ValueKey(key),
      left: center.dx,
      top: center.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: canReposition
            ? GestureDetector(
                onScaleStart: (details) =>
                    _onRepositionStart(key, effective, details.focalPoint, bubble, stackContext),
                onScaleUpdate: (details) => _onRepositionUpdate(key, details, bubble, stackContext),
                onScaleEnd: (_) => _onRepositionEnd(
                  key: key,
                  message: message!,
                  attachment: attachment,
                  chatGuid: chat!.guid,
                ),
                child: content,
              )
            : content,
      ),
    );
  }

  Offset _focalInBubble(BuildContext stackContext, Offset globalFocalPoint) {
    final box = stackContext.findRenderObject();
    return box is RenderBox ? box.globalToLocal(globalFocalPoint) : globalFocalPoint;
  }

  void _onRepositionStart(
    Object key,
    StickerPlacement placement,
    Offset globalFocalPoint,
    Size bubble,
    BuildContext stackContext,
  ) {
    _activeDrags[key] = _ActiveStickerDrag(
      initial: placement,
      current: placement,
      startFocalPoint: _focalInBubble(stackContext, globalFocalPoint),
      initialCenter: StickerHolder.placedCenter(placement, bubble, widget.isFromMe, widget.tailGutter),
    );
  }

  void _onRepositionUpdate(Object key, ScaleUpdateDetails details, Size bubble, BuildContext stackContext) {
    final drag = _activeDrags[key];
    if (drag == null) return;
    // Measure focal delta in the stationary Stack coordinate frame so moving Positioned doesn't shift the frame
    final nextCenter = drag.initialCenter + (_focalInBubble(stackContext, details.focalPoint) - drag.startFocalPoint);
    final at = StickerHolder.placementAt(nextCenter, bubble, widget.isFromMe, widget.tailGutter);
    final nextScale = (drag.initial.scale * details.scale).clamp(0.25, 4.0).toDouble();
    final nextRotation = drag.initial.rotation + details.rotation;
    final parentPreviewWidth = drag.initial.parentPreviewWidth > 0 ? drag.initial.parentPreviewWidth : bubble.width;
    final next = StickerPlacement(
      xScalar: at.xScalar,
      yScalar: at.yScalar,
      scale: nextScale,
      rotation: nextRotation,
      parentPreviewWidth: parentPreviewWidth,
    );
    if (!next.isValid) return;
    drag.current = next;
    drag.changed = drag.changed || next != drag.initial;
    setState(() => _dragging[key] = next);
  }

  Future<void> _onRepositionEnd({
    required Object key,
    required Message message,
    required Attachment attachment,
    required String chatGuid,
  }) async {
    final drag = _activeDrags.remove(key);
    if (drag == null || !drag.changed || drag.current == drag.initial) {
      if (_dragging.containsKey(key) && mounted) {
        setState(() => _dragging.remove(key));
      }
      return;
    }
    final next = drag.current;
    final messageGuid = message.guid;
    if (messageGuid == null || messageGuid.isEmpty || !GetIt.I.isRegistered<HttpService>()) {
      if (mounted && !_activeDrags.containsKey(key) && _dragging[key] == next) {
        setState(() => _dragging.remove(key));
      }
      return;
    }
    try {
      await HttpSvc.sticker.reposition(
        chatGuid: chatGuid,
        messageGuid: messageGuid,
        placement: next,
      );
      final map = next.toMap();
      attachment.stickerPlacement = map;
      Message updatedMsg = message;
      if (Database.boxesOpened) {
        Database.runInTransaction(TxMode.write, () {
          final current = message.id != null ? Database.messages.get(message.id!) : null;
          final target = current?.dbAttachments.firstWhereOrNull((a) => a.guid == attachment.guid) ??
              (attachment.id != null ? Database.attachments.get(attachment.id!) : null) ??
              attachment;
          target.stickerPlacement = map;
          Database.attachments.put(target);
          if (current != null) updatedMsg = current;
        });
      }
      final parentGuid = updatedMsg.associatedMessageGuid;
      final svcState = parentGuid != null ? maybeFindMessagesSvc(chatGuid)?.getMessageStateIfExists(parentGuid) : null;
      (svcState ?? _state)?.addAssociatedMessageInternal(updatedMsg);
      if (mounted && !_activeDrags.containsKey(key) && _dragging[key] == next) {
        setState(() => _dragging.remove(key));
      }
    } catch (e, s) {
      Logger.warn("Failed to reposition sticker", error: e, trace: s, tag: "StickerHolder");
      if (mounted && !_activeDrags.containsKey(key) && _dragging[key] == next) {
        setState(() => _dragging.remove(key));
      }
      showSnackbar("Error", stickerRefusal(e).message ?? "Couldn't reposition the sticker", type: SnackbarType.error);
    }
  }

  // shortcut: refetches once per session for stickers the server can't supply placement for; persist a "checked" marker if this shows up in network logs
  static final Set<String> _rehydratedGuids = {};

  static void _rehydrateMissingPlacements(Iterable<Message> messages) {
    if (!GetIt.I.isRegistered<HttpService>() ||
        !GetIt.I.isRegistered<SettingsService>() ||
        !SettingsSvc.serverDetails.isV2Server) {
      return;
    }
    for (final m in messages) {
      final guid = m.guid;
      if (guid == null || guid.startsWith("temp") || guid.startsWith("error")) continue;
      if (!m.dbAttachments.any((a) => a.stickerPlacement == null)) continue;
      if (!_rehydratedGuids.add(guid)) continue;
      _fetchAndPersistPlacement(m);
    }
  }

  static Future<void> _fetchAndPersistPlacement(Message stickerMsg) async {
    try {
      final response = await HttpSvc.message.fetchOne(stickerMsg.guid!, withQuery: "attachment");
      final remote = (((response.data['data'] as Map?)?['attachments'] as List?) ?? const [])
          .whereType<Map>()
          .map((a) => Attachment.fromMap(a.cast<String, dynamic>()))
          .toList();
      if (remote.isEmpty || stickerMsg.id == null) return;
      var changed = false;
      final updated = Database.runInTransaction(TxMode.write, () {
        final current = Database.messages.get(stickerMsg.id!);
        if (current == null) return null;
        for (final a in current.dbAttachments) {
          final placement = remote.firstWhereOrNull((r) => r.guid == a.guid)?.stickerPlacement;
          if (a.stickerPlacement != null || placement == null) continue;
          a.stickerPlacement = placement;
          Database.attachments.put(a);
          changed = true;
        }
        return current;
      });
      if (!changed || updated == null) return;
      final chatGuid = updated.chat.target?.guid;
      final parentGuid = updated.associatedMessageGuid;
      if (chatGuid != null && parentGuid != null) {
        maybeFindMessagesSvc(chatGuid)?.getMessageStateIfExists(parentGuid)?.addAssociatedMessageInternal(updated);
      }
    } catch (_) {
      // Best-effort lazy re-hydration for old cached stickers; centeredDefault still renders them
    }
  }

  ImageProvider _provider(Attachment attachment, double scale) {
    final bytes = _bytes[_keyOf(attachment)] ?? attachment.bytes;
    if (kIsWeb || bytes != null) {
      return MemoryImage(bytes ?? Uint8List(0), scale: scale);
    }
    return FileImage(File(attachment.path), scale: scale);
  }

  Widget _image(
    Attachment attachment, [
    FilterQuality quality = FilterQuality.medium,
    double scale = 1,
    bool popIn = true,
  ]) => Image(
        image: _provider(attachment, scale),
        gaplessPlayback: true,
        filterQuality: quality,
        // Pops in once it has loaded; a sticker already in the image cache is just drawn, so scrolling doesn't replay
        // it, and one that has drawn before under another file (see [_keyOf]) keeps showing
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          final key = _keyOf(attachment);
          if (frame != null) _shown.add(key);
          if (wasSynchronouslyLoaded) return child;
          return AnimatedScale(
            scale: frame == null && popIn && !_shown.contains(key) ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutBack,
            child: child,
          );
        },
      );
}

/// A sticker landing on a bubble: it presses down from a little larger as a highlight sweeps across it.
class _StickIn extends StatefulWidget {
  const _StickIn({required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  State<_StickIn> createState() => _StickInState();
}

class _StickInState extends State<_StickIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _scale = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.15, end: 0.96).chain(CurveTween(curve: Curves.easeIn)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 0.96, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 25),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
  ]).animate(_controller);
  late final Animation<double> _sweep = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.3, 1, curve: Curves.easeInOut),
  );

  @override
  void initState() {
    super.initState();
    // Settled already unless it's the one just dropped
    widget.play ? _controller.forward() : _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Always the same widgets, so the image under it is never rebuilt from scratch
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _sweep.value;
        return Transform.scale(
          scale: _scale.value,
          child: ShaderMask(
            // srcATop keeps the highlight to the sticker's own pixels
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment(-1 + 3 * t - 1, -1),
              end: Alignment(-1 + 3 * t, 1),
              colors: [
                Colors.transparent,
                Colors.white.withValues(alpha: t == 0 || t == 1 ? 0 : 0.55),
                Colors.transparent,
              ],
            ).createShader(rect),
            child: child,
          ),
        );
      },
    );
  }
}

/// Placed stickers for one attachment inside a media collection, positioned over that card's own bounds.
class CollectionAttachmentStickers extends StatelessWidget {
  const CollectionAttachmentStickers({
    super.key,
    required this.collectionPart,
    required this.attachmentIndex,
  });

  final MessagePart collectionPart;
  final int attachmentIndex;

  @override
  Widget build(BuildContext context) {
    final state = MessageStateScope.of(context);
    final partId = collectionPart.partIdForAttachment(attachmentIndex);
    return Positioned.fill(
      child: Obx(() {
        final placed = state.associatedMessages
            .where((s) => s.associatedMessageType == "sticker" && (s.associatedMessagePart ?? 0) == partId)
            .toList();
        if (placed.isEmpty) return const SizedBox.shrink();
        return StickerHolder(
          stickerMessages: placed,
          controller: state.cvController,
          hidden: state.showingPopup.value,
          isFromMe: state.isFromMe.value,
          tailGutter: false,
        );
      }),
    );
  }
}

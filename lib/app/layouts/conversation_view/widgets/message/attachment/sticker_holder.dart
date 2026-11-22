import 'dart:math';

import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/models/models.dart' show StickerPlacement;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

/// A placed sticker as [StickerHolder.space] lays it out: where its sender put it, and its image's size in pixels
@immutable
class PlacedSticker {
  const PlacedSticker(this.placement, this.pixels);

  final StickerPlacement placement;
  final Size pixels;

  /// [attachment] as placed, or null when it has no placement or its image hasn't downloaded and decoded yet, so the
  /// bubble doesn't move for a sticker that isn't drawing
  static PlacedSticker? of(Attachment attachment, Size? decoded) {
    final placement = StickerPlacement.tryParse(attachment.stickerPlacement);
    if (placement == null || decoded == null) return null;
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
    this.placed = false,
    this.hidden = false,
    this.isFromMe = false,
    this.tailGutter = true,
  });
  final Iterable<Message> stickerMessages;
  final ConversationViewController? controller;

  /// Which side of the parent bubble its tail is on
  final bool isFromMe;

  /// Draw each sticker where its sender put it, relative to the parent bubble this fills
  final bool placed;

  /// Shrink the stickers out of view, e.g. while the message's details menu is open
  final bool hidden;

  /// Whether the parent bubble keeps a gutter for its tail. Media collections aren't clipped by [TailClipper], so
  /// they don't.
  final bool tailGutter;

  /// Where a sticker placed at [p] has its center, relative to a [bubble] of that size
  static Offset placedCenter(StickerPlacement p, Size bubble, bool isFromMe, bool tailGutter) {
    // The bubble's body: not the gutter its tail draws in (see TailClipper), and inset a little on the other side.
    // Material and media-collection bubbles have no tail, so their body spans the full bubble width symmetrically.
    final gutter = tailGutter ? _tailGutter : 0.0;
    final inset = tailGutter ? _bodyInset : 0.0;
    final left = isFromMe ? inset : gutter;
    final bodyWidth = max(0.0, bubble.width - gutter - inset);
    return Offset(left + p.xScalar * bodyWidth, p.yScalar * bubble.height);
  }

  /// The placement scale that draws a sticker image whose longest side is [pixels] at [points] on its longest side
  static double scaleForPoints(double points, double pixels) => points * _stickerPixelRatio / max(1.0, pixels);

  /// The inverse of [placedCenter]: the placement that centers an unrotated sticker at [center] in [bubble]
  static StickerPlacement placementAt(Offset center, Size bubble, bool isFromMe, bool tailGutter) {
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
    if (p.scale <= 0) return 0;
    return p.parentPreviewWidth > 0 ? p.scale * bubble.width / p.parentPreviewWidth : p.scale;
  }

  /// Where a placed sticker draws (its rotated bounding box) relative to a [bubble] of that size
  static Rect placedRect(PlacedSticker sticker, Size bubble, bool isFromMe, bool tailGutter) {
    final p = sticker.placement;
    final scale = drawScale(p, bubble) / _stickerPixelRatio;
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
    double left = 0, top = 0, right = 0, bottom = 0;
    for (final sticker in stickers) {
      final rect = placedRect(sticker, bubble, isFromMe, tailGutter);
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

class _StickerHolderState extends State<StickerHolder> {
  /// This holder's sticker attachments, in the order their messages were sent, so later stickers draw on top
  List<Attachment> _stickers = const [];

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
    } else if (widget.placed && _state != null) {
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
    // Rebuilt from the current messages each time, so a sticker that left (unsent, or moved to the other holder once
    // its placement arrived) stops drawing here. One per attachment row, in case two copies of a message link the same
    // one; each key draws one widget.
    _stickers = <Object, Attachment>{
      for (final message in messages)
        for (final attachment in message.dbAttachments)
          if (attachment.guid != null &&
              (!widget.placed || StickerPlacement.tryParse(attachment.stickerPlacement) != null))
            _keyOf(attachment): attachment,
    }.values.toList();
    final keys = _stickers.map(_keyOf).toSet();
    _ready.retainAll(keys);
    _bytes.removeWhere((k, _) => !keys.contains(k));

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
    if (!widget.placed || state == null || guid == null || !_measured.add(guid)) return;
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

  // Stickers never take input, so they can't block interaction with the message under them
  Widget _shrinkable(Widget child) => IgnorePointer(
        child: AnimatedScale(
          scale: widget.hidden ? 0 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutBack,
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ready = _stickers
        .where((a) => _ready.contains(_keyOf(a)) && (!kIsWeb || (_bytes[_keyOf(a)] ?? a.bytes) != null))
        .toList();
    if (ready.isEmpty) return const SizedBox.shrink();
    if (widget.placed) return _buildPlaced(ready);

    return _shrinkable(
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: NavigationSvc.width(context) * 0.6),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: ready
              .map(
                (attachment) => ConstrainedBox(
                  key: ValueKey(_keyOf(attachment)),
                  constraints: const BoxConstraints(maxWidth: 100, maxHeight: 100),
                  child: _image(attachment),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  // The position is a fraction of the parent's size, so it's scaled by ours. `scale` applies to the sticker's own size.
  Widget _buildPlaced(List<Attachment> ready) {
    return LayoutBuilder(builder: (context, constraints) {
      final bubble = constraints.biggest;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          for (final attachment in ready)
            if (StickerPlacement.tryParse(attachment.stickerPlacement) case final p?) _placed(attachment, p, bubble),
        ],
      );
    });
  }

  Widget _placed(Attachment attachment, StickerPlacement p, Size bubble) {
    final scale = StickerHolder.drawScale(p, bubble);
    if (scale <= 0) return const SizedBox.shrink();
    final center = StickerHolder.placedCenter(p, bubble, widget.isFromMe, widget.tailGutter);
    return Positioned(
      key: ValueKey(_keyOf(attachment)),
      left: center.dx,
      top: center.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Transform.rotate(
          angle: p.rotation,
          child: _shrinkable(
            Transform.scale(
              scale: scale,
              // Before the scale, so the cap is what draws
              child: ConstrainedBox(
                constraints: BoxConstraints.loose(Size.square(StickerHolder.maxPoints / max(0.01, scale))),
                // Only a sticker still sending is new here: the one just dropped. It sticks rather than popping in.
                child: _StickIn(
                  play: attachment.guid!.startsWith("temp") && !_shown.contains(_keyOf(attachment)),
                  child: _image(
                    attachment,
                    FilterQuality.medium,
                    StickerHolder._stickerPixelRatio,
                    !attachment.guid!.startsWith("temp"),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
            .where((s) =>
                s.associatedMessageType == "sticker" &&
                (s.associatedMessagePart ?? 0) == partId &&
                s.dbAttachments.any((a) => StickerPlacement.tryParse(a.stickerPlacement) != null))
            .toList();
        if (placed.isEmpty) return const SizedBox.shrink();
        return StickerHolder(
          stickerMessages: placed,
          controller: state.cvController,
          placed: true,
          hidden: state.showingPopup.value,
          isFromMe: state.isFromMe.value,
          tailGutter: false,
        );
      }),
    );
  }
}

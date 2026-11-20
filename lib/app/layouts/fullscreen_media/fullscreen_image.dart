import 'dart:async';

import 'package:bluebubbles/app/components/m3e/m3e.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/live_photo_mixin.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/dialogs/metadata_dialog.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/interfaces/image_interface.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart' as intl;
import 'package:photo_view/photo_view.dart';
import 'package:universal_io/io.dart';

class FullscreenImage extends StatefulWidget {
  const FullscreenImage({
    super.key,
    required this.file,
    required this.attachment,
    required this.showInteractions,
    required this.updatePhysics,
    this.onOverlayToggle,
    this.onOpenCollectionGallery,
    this.pageIndex = 0,
    this.zoomCommand,
  });

  final PlatformFile file;
  final Attachment attachment;
  final bool showInteractions;
  final Function(ScrollPhysics) updatePhysics;
  final Function(bool)? onOverlayToggle;
  final VoidCallback? onOpenCollectionGallery;
  final int pageIndex;
  final ValueListenable<({int seq, int index, double? factor})?>? zoomCommand;

  @override
  State<FullscreenImage> createState() => _FullscreenImageState();
}

class _FullscreenImageState extends State<FullscreenImage>
    with AutomaticKeepAliveClientMixin, LivePhotoMixin, ThemeHelpers {
  final PhotoViewController controller = PhotoViewController();
  final PhotoViewScaleStateController scaleStateController = PhotoViewScaleStateController();
  bool showOverlay = true;
  bool hasError = false;
  Uint8List? bytes;
  String? compatiblePath; // For converted HEIC/TIFF files
  int _lastHandledZoomSeq = -1;

  PlatformFile get file => widget.file;
  Attachment get attachment => widget.attachment;
  Message? get message => attachment.message.target;

  // Implement required getter for LivePhotoMixin
  @override
  Attachment get livePhotoAttachment => attachment;

  @override
  void initState() {
    super.initState();
    _setFullscreen(true);
    widget.zoomCommand?.addListener(_onZoomCommand);
    initBytes();
  }

  void _onZoomCommand() {
    final cmd = widget.zoomCommand?.value;
    if (cmd == null || cmd.index != widget.pageIndex || cmd.seq == _lastHandledZoomSeq) return;
    _lastHandledZoomSeq = cmd.seq;
    _applyZoom(cmd.factor);
  }

  void _applyZoom(double? factor) {
    if (factor == null) {
      scaleStateController.reset();
      return;
    }
    final currentScale = controller.scale ?? 1.0;
    final nextScale = (currentScale * factor).clamp(0.5, 10.0);
    controller.scale = nextScale;
  }

  void _setFullscreen(bool fullscreen) {
    if (kIsWeb) return;
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> initBytes() async {
    // For web, we need bytes in memory
    if (kIsWeb || file.path == null) {
      if (file.bytes != null && file.bytes!.isNotEmpty) {
        if (attachment.mimeType?.contains("image/tif") ?? false) {
          bytes = await ImageInterface.convertToPng(file);
        } else {
          bytes = file.bytes;
        }
        if (mounted) setState(() {});
        return;
      }
      if (attachment.guid != null) {
        AttachmentsSvc.redownloadAttachment(
          attachment,
          onComplete: (newFile) async {
            if (!mounted) return;
            if (attachment.mimeType?.contains("image/tif") ?? false) {
              bytes = await ImageInterface.convertToPng(newFile);
            } else {
              bytes = newFile.bytes;
            }
            if (mounted) setState(() {});
          },
          onError: () {
            if (mounted) setState(() => hasError = true);
          },
        );
      } else {
        if (mounted) setState(() => hasError = true);
      }
      return;
    }

    // For non-web platforms, ensure we have a compatible image path
    // but don't load bytes into memory - let Image.file handle it
    compatiblePath = await AttachmentsSvc.ensureImageCompatibility(attachment, actualPath: file.path!);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.zoomCommand?.removeListener(_onZoomCommand);
    _setFullscreen(false);
    controller.dispose();
    scaleStateController.dispose();
    super.dispose();
  }

  void _saveImage() {
    final currentBytes = bytes;
    if (kIsWeb && (widget.file.bytes == null || widget.file.bytes!.isEmpty)) {
      if (currentBytes != null && currentBytes.isNotEmpty) {
        AttachmentsSvc.saveToDisk(PlatformFile(
          name: widget.file.name,
          size: currentBytes.length,
          bytes: currentBytes,
        ));
        return;
      }
      if (widget.attachment.guid != null) {
        AttachmentsSvc.redownloadAttachment(
          widget.attachment,
          onComplete: (downloaded) {
            if (mounted) setState(() => bytes = downloaded.bytes);
            AttachmentsSvc.saveToDisk(downloaded);
          },
        );
        return;
      }
    }
    AttachmentsSvc.saveToDisk(widget.file);
  }

  void refreshAttachment() {
    setState(() {
      bytes = null;
      compatiblePath = null;
      hasError = false;
    });
    AttachmentsSvc.redownloadAttachment(
      widget.attachment,
      onComplete: (newFile) {
        if (!mounted) return;
        if (kIsWeb || newFile.path == null) {
          setState(() {
            bytes = newFile.bytes;
          });
        } else {
          initBytes();
        }
      },
      onError: () {
        if (!mounted) return;
        setState(() {
          hasError = true;
        });
      },
    );
  }

  Widget _buildPhotoView(BuildContext context) {
    if (bytes == null && compatiblePath == null) {
      return hasError
          ? Center(child: Text("Failed to load image", style: context.theme.textTheme.bodyLarge))
          : Center(child: buildProgressIndicator(context));
    }

    // No orientation handling here: the decoder applies EXIF orientation
    // itself, so the provider's reported size is already display-space and
    // PhotoViewComputedScale.contained reads it correctly.
    Widget viewer = PhotoView(
      gaplessPlayback: true,
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.contained * 10,
      controller: controller,
      scaleStateController: scaleStateController,
      imageProvider: bytes != null
          ? MemoryImage(bytes!) as ImageProvider
          : FileImage(File(compatiblePath ?? file.path!)),
      loadingBuilder: (BuildContext context, ImageChunkEvent? ev) {
        return Center(child: buildProgressIndicator(context));
      },
      scaleStateChangedCallback: (scale) {
        if (scale == PhotoViewScaleState.zoomedIn ||
            scale == PhotoViewScaleState.covering ||
            scale == PhotoViewScaleState.originalSize) {
          widget.updatePhysics(const NeverScrollableScrollPhysics());
        } else {
          widget.updatePhysics(ThemeSwitcher.getScrollPhysics());
        }
      },
      errorBuilder: (context, object, stacktrace) =>
          Center(child: Text("Failed to display image", style: context.theme.textTheme.bodyLarge)),
      filterQuality: FilterQuality.high,
    );

    if (kIsWeb || kIsDesktop) {
      viewer = Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
            _applyZoom(event.scrollDelta.dy < 0 ? 1.15 : 0.87);
          }
        },
        child: viewer,
      );
    }

    return viewer;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      color: Colors.black,
      child: GestureDetector(
        onTap: () {
          if (!widget.showInteractions) return;
          bool newVal = !showOverlay;
          setState(() {
            showOverlay = newVal;
          });

          if (widget.onOverlayToggle != null) {
            widget.onOverlayToggle!(newVal);
          }

          // eventDispatcher.emit('overlay-toggle', newVal);
        },
        onLongPress: () {
          if (attachment.hasLivePhoto && !isDownloadingLivePhoto.value) {
            handleLivePhotoTap();
          }
        },
        child: Stack(
          children: [
            _buildPhotoView(context),
            // Live photo video overlay
            if (attachment.hasLivePhoto) buildLivePhotoOverlay(),
            if (!iOS)
              AnimatedOpacity(
                opacity: showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 125),
                child: Container(
                  width: NavigationSvc.width(context),
                  color: context.theme.colorScheme.shadow.withValues(alpha: samsung ? 1 : 0.65),
                  child: SafeArea(
                    left: false,
                    right: false,
                    bottom: false,
                    child: SizedBox(
                      height: kIsWeb ? 64.0 : (kIsDesktop ? 80.0 : 56.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 5),
                                child: iOS
                                    ? CupertinoButton(
                                        padding: const EdgeInsets.symmetric(horizontal: 5),
                                        onPressed: () async {
                                          Navigator.of(context).pop();
                                        },
                                        child: const Icon(Icons.close, color: Colors.white),
                                      )
                                    : IconButton(
                                        padding: const EdgeInsets.symmetric(horizontal: 5),
                                        onPressed: () async {
                                          Navigator.of(context).pop();
                                        },
                                        icon: const Icon(Icons.close, color: Colors.white),
                                      ),
                              ),
                              if (widget.showInteractions)
                                Padding(
                                  padding: const EdgeInsets.only(left: 5.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        (message?.isFromMe ?? false)
                                            ? SettingsSvc.effectiveUserName
                                            : message?.handleRelation.target?.displayName ?? "Unknown",
                                        style: context.theme.textTheme.titleLarge!.copyWith(color: Colors.white),
                                      ),
                                      if (message?.dateCreated != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2.0),
                                          child: Text(
                                            samsung
                                                ? intl.DateFormat.jm().add_MMMd().format(message!.dateCreated!)
                                                : intl.DateFormat('EEE').add_jm().format(message!.dateCreated!),
                                            style: context.theme.textTheme.bodyLarge!.copyWith(
                                              color: samsung ? Colors.grey : Colors.white,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          !widget.showInteractions
                              ? const SizedBox.shrink()
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (widget.onOpenCollectionGallery != null)
                                      iOS
                                          ? CupertinoButton(
                                              padding: const EdgeInsets.symmetric(horizontal: 5),
                                              onPressed: widget.onOpenCollectionGallery,
                                              child: Icon(
                                                iOS ? CupertinoIcons.square_grid_2x2 : Icons.grid_view_outlined,
                                                color: Colors.white,
                                              ),
                                            )
                                          : IconButton(
                                              padding: const EdgeInsets.symmetric(horizontal: 5),
                                              onPressed: widget.onOpenCollectionGallery,
                                              icon: const Icon(
                                                Icons.grid_view_outlined,
                                                color: Colors.white,
                                              ),
                                            ),
                                    iOS
                                        ? CupertinoButton(
                                            padding: const EdgeInsets.symmetric(horizontal: 5),
                                            onPressed: () async {
                                              showMetadataDialog(widget.attachment, context);
                                            },
                                            child: const Icon(Icons.info_outlined, color: Colors.white),
                                          )
                                        : IconButton(
                                            padding: const EdgeInsets.symmetric(horizontal: 5),
                                            onPressed: () async {
                                              showMetadataDialog(widget.attachment, context);
                                            },
                                            icon: const Icon(Icons.info_outlined, color: Colors.white),
                                          ),
                                    iOS
                                        ? CupertinoButton(
                                            padding: const EdgeInsets.symmetric(horizontal: 5),
                                            onPressed: () async {
                                              refreshAttachment();
                                            },
                                            child: const Icon(Icons.refresh, color: Colors.white),
                                          )
                                        : IconButton(
                                            padding: const EdgeInsets.symmetric(horizontal: 5),
                                            onPressed: () async {
                                              refreshAttachment();
                                            },
                                            icon: const Icon(Icons.refresh, color: Colors.white),
                                          ),
                                  ],
                                ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // Bottom actions bar (iOS style)
            if (widget.showInteractions && iOS)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: showOverlay ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    decoration: BoxDecoration(
                      color: samsung
                          ? Colors.black
                          : context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                    ),
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: 60,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: Icon(
                                CupertinoIcons.cloud_download,
                                color: samsung ? Colors.white : context.theme.colorScheme.primary,
                              ),
                              onPressed: _saveImage,
                            ),
                            if (!kIsWeb && !kIsDesktop)
                              IconButton(
                                icon: Icon(
                                  CupertinoIcons.share,
                                  color: samsung ? Colors.white : context.theme.colorScheme.primary,
                                ),
                                onPressed: () {
                                  if (widget.file.path != null) {
                                    Share.files([widget.file.path!]);
                                  }
                                },
                              ),
                            IconButton(
                              icon: Icon(
                                CupertinoIcons.info,
                                color: samsung ? Colors.white : context.theme.colorScheme.primary,
                              ),
                              onPressed: () => showMetadataDialog(widget.attachment, context),
                            ),
                            IconButton(
                              icon: Icon(
                                CupertinoIcons.refresh,
                                color: samsung ? Colors.white : context.theme.colorScheme.primary,
                              ),
                              onPressed: () => refreshAttachment(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Floating M3E dark tonal bottom action pill (!iOS)
            if (widget.showInteractions && !iOS)
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: IgnorePointer(
                  ignoring: !showOverlay,
                  child: AnimatedOpacity(
                    opacity: showOverlay ? 1.0 : 0.0,
                    duration: M3EMotion.effectsFast.duration,
                    curve: M3EMotion.effectsFast.curve,
                    child: SafeArea(
                      top: false,
                      child: Center(
                        child: FullscreenMediaActionPill(
                          onSave: _saveImage,
                          onShare: (!kIsWeb && !kIsDesktop)
                              ? () {
                                  if (widget.file.path != null) {
                                    Share.files([widget.file.path!]);
                                  }
                                }
                              : null,
                          onDetails: () => showMetadataDialog(widget.attachment, context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if ((kIsWeb || kIsDesktop) && !iOS)
              Positioned(
                right: 20,
                bottom: MediaQuery.sizeOf(context).width < 600 ? 78 : 24,
                child: IgnorePointer(
                  ignoring: !showOverlay,
                  child: AnimatedOpacity(
                    opacity: showOverlay ? 1.0 : 0.0,
                    duration: M3EMotion.effectsFast.duration,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: M3EShapes.radiusXl,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Zoom out (-)',
                            icon: const Icon(Icons.remove, color: Colors.white, size: 20),
                            onPressed: () => _applyZoom(0.8),
                          ),
                          IconButton(
                            tooltip: 'Reset zoom (0)',
                            icon: const Icon(Icons.fit_screen, color: Colors.white, size: 18),
                            onPressed: () => _applyZoom(null),
                          ),
                          IconButton(
                            tooltip: 'Zoom in (+)',
                            icon: const Icon(Icons.add, color: Colors.white, size: 20),
                            onPressed: () => _applyZoom(1.25),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class FullscreenMediaActionPill extends StatelessWidget {
  const FullscreenMediaActionPill({
    super.key,
    required this.onSave,
    this.onShare,
    required this.onDetails,
  });

  final VoidCallback onSave;
  final VoidCallback? onShare;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final darkScheme = scheme.brightness == Brightness.dark
        ? scheme
        : ColorScheme.fromSeed(seedColor: scheme.primary, brightness: Brightness.dark);

    return Material(
      color: darkScheme.surfaceContainerHigh.withValues(alpha: 0.92),
      borderRadius: M3EShapes.radiusXl,
      elevation: 6,
      shadowColor: Colors.black54,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: M3EShapes.radiusXl,
          border: Border.all(
            color: darkScheme.outlineVariant.withValues(alpha: 0.28),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PillActionButton(
                icon: Icons.file_download_outlined,
                label: 'Save',
                color: darkScheme.onSurface,
                onPressed: onSave,
              ),
              if (onShare != null)
                _PillActionButton(
                  icon: Icons.share_outlined,
                  label: 'Share',
                  color: darkScheme.onSurface,
                  onPressed: onShare!,
                ),
              _PillActionButton(
                icon: Icons.info_outline,
                label: 'Details',
                color: darkScheme.onSurface,
                onPressed: onDetails,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillActionButton extends StatelessWidget {
  const _PillActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: M3EShapes.radiusXl,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

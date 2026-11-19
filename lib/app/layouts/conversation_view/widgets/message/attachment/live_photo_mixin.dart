import 'package:universal_io/io.dart';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_video_player.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/filesystem/web_media_cache.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

/// Mixin that provides live photo functionality for image viewers
/// Handles downloading, caching, and playback of live photos
mixin LivePhotoMixin<T extends StatefulWidget> on State<T> {
  // Live photo state - using GetX observables to minimize re-renders
  final RxBool isDownloadingLivePhoto = false.obs;
  final RxDouble livePhotoProgress = 0.0.obs;
  PlatformFile? livePhotoFile;
  Player? livePhotoPlayer;
  VideoController? livePhotoController;
  WebVideoController? _webVideoController;
  final RxBool isPlayingLivePhoto = false.obs;
  final RxDouble livePhotoOpacity = 0.0.obs;

  // Must be implemented by the using class
  Attachment get livePhotoAttachment;

  @override
  void dispose() {
    livePhotoPlayer?.dispose();
    _webVideoController?.dispose();
    super.dispose();
  }

  /// Get the persistent path for the live photo stored alongside the attachment
  String getLivePhotoPath() {
    // Store in same directory as attachment: {appDocDir}/attachments/{guid}/{name}.mov
    final nameSplit = livePhotoAttachment.transferName!.split(".");
    final fileName = "${nameSplit.take(nameSplit.length - 1).join(".")}.mov";
    return "${livePhotoAttachment.directory}/$fileName";
  }

  String _webLivePhotoName(String guid) {
    final tn = livePhotoAttachment.transferName;
    if (tn == null || tn.isEmpty) return '$guid.mov';
    final dot = tn.lastIndexOf('.');
    return '${dot > 0 ? tn.substring(0, dot) : tn}.mov';
  }

  Future<void> _handleWebLivePhotoTap() async {
    if (isDownloadingLivePhoto.value) return;
    final guid = livePhotoAttachment.guid;
    if (guid == null) return;

    if (isPlayingLivePhoto.value) {
      livePhotoOpacity.value = 0.0;
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) {
        isPlayingLivePhoto.value = false;
        await _webVideoController?.pause();
      }
      return;
    }

    if (livePhotoFile?.bytes != null) {
      isPlayingLivePhoto.value = true;
      await Future.delayed(const Duration(milliseconds: 50));
      if (mounted) livePhotoOpacity.value = 1.0;
      await _webVideoController?.seek(Duration.zero);
      await _webVideoController?.play();
      return;
    }

    final cacheKey = '${guid}_live';
    try {
      final cached = await WebMediaCache.instance.get(WebMediaCache.attachmentsStore, cacheKey);
      if (cached != null && cached.isNotEmpty) {
        livePhotoFile = PlatformFile(
          name: _webLivePhotoName(guid),
          size: cached.length,
          bytes: cached,
        );
        if (mounted) {
          isPlayingLivePhoto.value = true;
          await Future.delayed(const Duration(milliseconds: 50));
          if (mounted) livePhotoOpacity.value = 1.0;
        }
        return;
      }
    } catch (_) {}

    isDownloadingLivePhoto.value = true;
    livePhotoProgress.value = 0.0;
    try {
      final response = await HttpSvc.attachment.downloadLivePhoto(
        guid,
        onReceiveProgress: (count, total) {
          if (mounted) {
            livePhotoProgress.value = total > 0 ? count / total : 0.0;
          }
        },
      );
      final bytes = response.data is Uint8List
          ? response.data as Uint8List
          : Uint8List.fromList(List<int>.from(response.data as List));
      try {
        await WebMediaCache.instance.put(WebMediaCache.attachmentsStore, cacheKey, bytes);
      } catch (_) {}
      livePhotoFile = PlatformFile(
        name: _webLivePhotoName(guid),
        size: bytes.length,
        bytes: bytes,
      );
      isDownloadingLivePhoto.value = false;
      if (mounted) {
        isPlayingLivePhoto.value = true;
        await Future.delayed(const Duration(milliseconds: 50));
        if (mounted) livePhotoOpacity.value = 1.0;
      }
    } catch (ex) {
      Logger.error("Failed to download/play web live photo", error: ex);
      if (mounted) isDownloadingLivePhoto.value = false;
      showSnackbar("Error", "Failed to load live photo", type: SnackbarType.error);
    }
  }

  Future<void> handleLivePhotoTap() async {
    if (kIsWeb) {
      return _handleWebLivePhotoTap();
    }
    if (isDownloadingLivePhoto.value || isPlayingLivePhoto.value) {
      // If already playing, stop it with fade out
      if (isPlayingLivePhoto.value) {
        livePhotoOpacity.value = 0.0;
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) {
          isPlayingLivePhoto.value = false;
          await livePhotoPlayer?.pause();
        }
      }
      return;
    }

    // Check if we already have the live photo cached in memory
    if (livePhotoFile != null && livePhotoPlayer != null) {
      // Seek to start and wait for player to be ready
      await livePhotoPlayer!.seek(Duration.zero);

      // Start playing (but keep hidden while loading)
      await livePhotoPlayer!.play();

      // Wait a bit for the video to buffer the first frame
      await Future.delayed(const Duration(milliseconds: 100));

      if (mounted) {
        isPlayingLivePhoto.value = true;

        // Fade in
        await Future.delayed(const Duration(milliseconds: 50));
        if (mounted) {
          livePhotoOpacity.value = 1.0;
        }
      }

      // Auto-hide after video ends with fade out
      Future.delayed(Duration(milliseconds: livePhotoPlayer!.state.duration.inMilliseconds + 100), () async {
        if (mounted && isPlayingLivePhoto.value) {
          // Fade out
          livePhotoOpacity.value = 0.0;
          // Wait for fade animation to complete
          await Future.delayed(const Duration(milliseconds: 200));
          if (mounted) {
            isPlayingLivePhoto.value = false;
          }
        }
      });
      return;
    }

    // Get persistent storage path
    final livePhotoPath = getLivePhotoPath();
    final livePhotoFileOnDisk = File(livePhotoPath);

    // Check if live photo already exists on disk
    if (await livePhotoFileOnDisk.exists()) {
      // Initialize and play existing file
      try {
        final fileInfo = await livePhotoFileOnDisk.stat();
        livePhotoFile = PlatformFile(
          name: p.basename(livePhotoPath),
          size: fileInfo.size,
          path: livePhotoPath,
        );

        livePhotoPlayer = Player();
        livePhotoController = VideoController(livePhotoPlayer!);
        await livePhotoPlayer!.setPlaylistMode(PlaylistMode.none);
        await livePhotoPlayer!.open(Media(livePhotoPath), play: false);

        // Start playing and wait for first frame to be ready
        await livePhotoPlayer!.play();
        await Future.delayed(const Duration(milliseconds: 100));

        if (mounted) {
          isPlayingLivePhoto.value = true;

          // Fade in
          await Future.delayed(const Duration(milliseconds: 50));
          if (mounted) {
            livePhotoOpacity.value = 1.0;
          }
        }

        // Auto-hide after video ends with fade out
        Future.delayed(Duration(milliseconds: livePhotoPlayer!.state.duration.inMilliseconds + 100), () async {
          if (mounted && isPlayingLivePhoto.value) {
            // Fade out
            livePhotoOpacity.value = 0.0;
            // Wait for fade animation to complete
            await Future.delayed(const Duration(milliseconds: 200));
            if (mounted) {
              isPlayingLivePhoto.value = false;
            }
          }
        });
      } catch (ex) {
        Logger.error("Failed to play existing live photo", error: ex);
        showSnackbar("Error", "Failed to play live photo", type: SnackbarType.error);
      }
      return;
    }

    // Download the live photo
    isDownloadingLivePhoto.value = true;
    livePhotoProgress.value = 0.0;

    try {
      final response = await HttpSvc.attachment.downloadLivePhoto(
        livePhotoAttachment.guid!,
        onReceiveProgress: (count, total) {
          if (mounted) {
            livePhotoProgress.value = total > 0 ? count / total : 0.0;
          }
        },
      );

      // Save to persistent location alongside attachment
      // Create directory if it doesn't exist
      await livePhotoFileOnDisk.parent.create(recursive: true);
      await livePhotoFileOnDisk.writeAsBytes(response.data);

      livePhotoFile = PlatformFile(
        name: p.basename(livePhotoPath),
        size: response.data.length,
        path: livePhotoPath,
      );

      // Initialize video player
      livePhotoPlayer = Player();
      livePhotoController = VideoController(livePhotoPlayer!);
      await livePhotoPlayer!.setPlaylistMode(PlaylistMode.none);
      await livePhotoPlayer!.open(Media(livePhotoPath), play: false);

      isDownloadingLivePhoto.value = false;

      // Start playback and wait for first frame to be ready
      await livePhotoPlayer!.play();
      await Future.delayed(const Duration(milliseconds: 100));

      if (mounted) {
        isPlayingLivePhoto.value = true;

        // Fade in
        await Future.delayed(const Duration(milliseconds: 50));
        if (mounted) {
          livePhotoOpacity.value = 1.0;
        }
      }

      // Auto-hide after video ends with fade out
      Future.delayed(Duration(milliseconds: livePhotoPlayer!.state.duration.inMilliseconds + 100), () async {
        if (mounted && isPlayingLivePhoto.value) {
          // Fade out
          livePhotoOpacity.value = 0.0;
          // Wait for fade animation to complete
          await Future.delayed(const Duration(milliseconds: 200));
          if (mounted) {
            isPlayingLivePhoto.value = false;
          }
        }
      });
    } catch (ex) {
      Logger.error("Failed to download/play live photo", error: ex);
      if (mounted) {
        isDownloadingLivePhoto.value = false;
      }
      showSnackbar("Error", "Failed to load live photo", type: SnackbarType.error);
    }
  }

  /// Build the live photo indicator widget
  Widget buildLivePhotoIndicator({required bool isFromMe}) {
    return GestureDetector(
      onTap: handleLivePhotoTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Obx(() => Stack(
              alignment: Alignment.center,
              children: [
                if (isDownloadingLivePhoto.value)
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      value: livePhotoProgress.value,
                      strokeWidth: 2,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                    ),
                  )
                else if (isPlayingLivePhoto.value)
                  const Icon(
                    CupertinoIcons.pause_fill,
                    color: Colors.white,
                    size: 16,
                  )
                else
                  const Icon(
                    CupertinoIcons.smallcircle_circle,
                    color: Colors.white,
                    size: 20,
                  ),
              ],
            )),
      ),
    );
  }

  /// Build the live photo video overlay
  Widget buildLivePhotoOverlay() {
    return Obx(() {
      if (kIsWeb) {
        if (!isPlayingLivePhoto.value || livePhotoFile?.bytes == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: AnimatedOpacity(
            opacity: livePhotoOpacity.value,
            duration: const Duration(milliseconds: 200),
            child: WebVideoPlayer(
              file: livePhotoFile,
              controller: _webVideoController ??= WebVideoController(),
              autoplay: true,
              muted: true,
              controls: false,
              fit: BoxFit.contain,
              onEnded: () async {
                if (!mounted || !isPlayingLivePhoto.value) return;
                livePhotoOpacity.value = 0.0;
                await Future.delayed(const Duration(milliseconds: 200));
                if (mounted) {
                  isPlayingLivePhoto.value = false;
                }
              },
            ),
          ),
        );
      }

      if (!isPlayingLivePhoto.value || livePhotoController == null) {
        return const SizedBox.shrink();
      }

      return Positioned.fill(
        child: AnimatedOpacity(
          opacity: livePhotoOpacity.value,
          duration: const Duration(milliseconds: 200),
          child: Video(
            controller: livePhotoController!,
            fit: BoxFit.contain,
            controls: null,
          ),
        ),
      );
    });
  }
}

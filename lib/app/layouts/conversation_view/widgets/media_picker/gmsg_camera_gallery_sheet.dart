import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';

/// Adds [path] to [controller.pickedAttachments] if [size] <= 1 GB (returns false otherwise).
Future<bool> addPickedAttachmentIfUnderLimit(
  ConversationViewController controller, {
  required String path,
  String? name,
  required int size,
  FutureOr<Uint8List?> Function()? readBytes,
  bool toggleIfPresent = false,
}) async {
  if (size / 1024000 > 1000) {
    showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.", type: SnackbarType.error);
    return false;
  }
  if (toggleIfPresent) {
    final existingIdx = controller.pickedAttachments.indexWhere((e) => e.path == path);
    if (existingIdx >= 0) {
      controller.pickedAttachments.removeAt(existingIdx);
      return true;
    }
  }
  controller.pickedAttachments.add(PlatformFile(
    path: path,
    name: (name != null && name.isNotEmpty) ? name : path.split('/').last,
    size: size,
    bytes: readBytes != null ? await readBytes() : null,
  ));
  return true;
}

/// Opens the Google Messages-style split live camera + recent gallery sheet.
Future<void> showGmsgCameraGallerySheet(
  BuildContext context,
  ConversationViewController controller,
) {
  FocusManager.instance.primaryFocus?.unfocus();
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  final rootMq = MediaQuery.maybeOf(rootContext) ?? MediaQuery.maybeOf(context);
  final topInset = rootMq != null ? math.max(rootMq.padding.top, rootMq.viewPadding.top) : 0.0;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: false,
    enableDrag: false,
    backgroundColor: Colors.black,
    builder: (_) => GmsgCameraGallerySheet(controller: controller, topInset: topInset),
  );
}

enum _CameraStatus { loading, ready, permissionDenied, permanentlyDenied, unavailable }

class GmsgCameraGallerySheet extends StatefulWidget {
  const GmsgCameraGallerySheet({super.key, required this.controller, this.topInset});

  final ConversationViewController controller;
  final double? topInset;

  /// Resolves the top status-bar / cutout inset even inside [showModalBottomSheet]
  /// routes where Flutter strips `MediaQuery.padding.top` and `viewPadding.top`.
  static double resolveTopInset(BuildContext context, double? callerTopInset) {
    final mq = MediaQuery.maybeOf(context);
    final localTop = mq != null ? math.max(mq.padding.top, mq.viewPadding.top) : 0.0;
    if (localTop > 0) return localTop;
    if (callerTopInset != null && callerTopInset > 0) return callerTopInset;
    final view = View.maybeOf(context);
    if (view != null && view.devicePixelRatio > 0) {
      return view.padding.top / view.devicePixelRatio;
    }
    return 0.0;
  }

  @override
  State<GmsgCameraGallerySheet> createState() => _GmsgCameraGallerySheetState();
}

class _GmsgCameraGallerySheetState extends State<GmsgCameraGallerySheet> with WidgetsBindingObserver {
  static const int _pageSize = 60;
  static const MethodChannel _androidCameraChannel = MethodChannel('com.bluebubbles.messaging/gmsg_camera');
  static const String _androidPreviewViewType = 'com.bluebubbles.messaging/gmsg_camera_preview';

  CameraController? _cameraController;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  _CameraStatus _cameraStatus = _CameraStatus.loading;
  FlashMode _flashMode = FlashMode.off;
  bool _isVideoMode = false;
  bool _isRecording = false;
  bool _isCapturing = false;
  bool _micGranted = false;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;

  bool _androidPermissionGranted = false;
  int? _androidViewId;
  String _androidLensFacing = 'back';
  bool _androidHasBackCamera = false;
  bool _androidHasFrontCamera = false;
  bool _androidHasFlash = false;

  AssetPathEntity? _recentAlbum;
  final List<AssetEntity> _assets = [];
  // Persisted across sheet reopens so pre-selected attachments keep their badge.
  static final RxMap<String, String> _resolvedAssetPaths = <String, String>{}.obs;
  bool _loadingPhotos = true;
  bool _loadingMorePhotos = false;
  bool _hasMorePhotos = true;
  bool _photoPermissionDenied = false;
  bool _photoPermissionPermanentlyDenied = false;
  bool _isLimitedAccess = false;
  int _nextPageStart = 0;

  ConversationViewController get controller => widget.controller;
  bool get _useAndroidNativeCamera => !kIsWeb && Platform.isAndroid;
  bool get _canSwitchCamera =>
      _useAndroidNativeCamera ? (_androidHasBackCamera && _androidHasFrontCamera) : _cameras.length > 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initCamera());
    unawaited(_loadRecentPhotos(reset: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    unawaited(_disposeCamera());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_useAndroidNativeCamera) {
      if (!_androidPermissionGranted) return;
      if (state == AppLifecycleState.inactive) {
        _recordingTimer?.cancel();
        _isRecording = false;
        if (mounted) setState(() => _cameraStatus = _CameraStatus.loading);
        unawaited(_disposeCamera());
      } else if (state == AppLifecycleState.resumed) {
        unawaited(_initCamera(preferredIndex: _cameraIndex));
      }
      return;
    }

    if (state == AppLifecycleState.resumed) {
      if (_cameraController == null && _cameraStatus == _CameraStatus.ready) {
        unawaited(_initCamera(preferredIndex: _cameraIndex));
      }
      return;
    }

    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _recordingTimer?.cancel();
      _isRecording = false;
      unawaited(_disposeCamera());
    }
  }

  Future<void> _disposeCamera() async {
    if (_useAndroidNativeCamera) {
      try {
        await _androidCameraChannel.invokeMethod<void>('dispose');
      } catch (_) {}
      return;
    }
    final cam = _cameraController;
    _cameraController = null;
    if (cam != null) {
      try {
        await cam.dispose();
      } catch (_) {}
    }
  }

  String _flashModeKey(FlashMode mode) => switch (mode) {
    FlashMode.auto => 'auto',
    FlashMode.always => 'always',
    _ => 'off',
  };

  Future<void> _bindAndroidCamera(int viewId) async {
    if (mounted && _cameraStatus != _CameraStatus.ready) {
      setState(() => _cameraStatus = _CameraStatus.loading);
    }
    try {
      final info = await _androidCameraChannel.invokeMapMethod<String, dynamic>('initialize', {
        'viewId': viewId,
        'lensFacing': _androidLensFacing,
        'videoMode': _isVideoMode,
        'flashMode': _flashModeKey(_flashMode),
      });
      if (!mounted || info == null) return;
      final minZoom = (info['minZoom'] as num?)?.toDouble() ?? 1.0;
      final maxZoom = (info['maxZoom'] as num?)?.toDouble() ?? 1.0;
      setState(() {
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _currentZoom = 1.0.clamp(minZoom, maxZoom);
        _androidHasFlash = info['hasFlash'] as bool? ?? false;
        _androidHasBackCamera = info['hasBackCamera'] as bool? ?? false;
        _androidHasFrontCamera = info['hasFrontCamera'] as bool? ?? false;
        _androidLensFacing = (info['lensFacing'] as String?) ?? _androidLensFacing;
        if (!_androidHasFlash) _flashMode = FlashMode.off;
        _cameraStatus = _CameraStatus.ready;
      });
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') return;
      Logger.warn("Android CameraX init failed: ${e.code} ${e.message}");
      if (!mounted) return;
      final denied = e.code == 'CameraAccessDenied';
      setState(() {
        _cameraStatus = denied ? _CameraStatus.permissionDenied : _CameraStatus.unavailable;
      });
    } catch (e, s) {
      Logger.error("Android CameraX init error", error: e, trace: s);
      if (mounted) setState(() => _cameraStatus = _CameraStatus.unavailable);
    }
  }

  Future<void> _initCamera({int? preferredIndex}) async {
    if (mounted) setState(() => _cameraStatus = _CameraStatus.loading);

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final camPerm = await Permission.camera.request();
      if (!camPerm.isGranted) {
        if (mounted) {
          setState(() {
            _androidPermissionGranted = false;
            _cameraStatus = camPerm.isPermanentlyDenied
                ? _CameraStatus.permanentlyDenied
                : _CameraStatus.permissionDenied;
          });
        }
        return;
      }
      if (_isVideoMode) {
        _micGranted = (await Permission.microphone.request()).isGranted;
      } else {
        _micGranted = await Permission.microphone.isGranted;
      }
    }

    if (_useAndroidNativeCamera) {
      if (mounted && !_androidPermissionGranted) {
        setState(() => _androidPermissionGranted = true);
      } else {
        _androidPermissionGranted = true;
      }
      if (_androidViewId != null) {
        await _bindAndroidCamera(_androidViewId!);
      }
      return;
    }

    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _cameraStatus = _CameraStatus.unavailable);
        return;
      }

      if (preferredIndex != null) {
        _cameraIndex = preferredIndex % _cameras.length;
      } else {
        final backIdx = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
        _cameraIndex = backIdx >= 0 ? backIdx : 0;
      }

      await _disposeCamera();
      if (!mounted) return;

      final nextController = CameraController(
        _cameras[_cameraIndex],
        ResolutionPreset.high,
        enableAudio: _isVideoMode && _micGranted,
      );
      _cameraController = nextController;
      await nextController.initialize();
      if (!mounted || _cameraController != nextController) {
        await nextController.dispose();
        return;
      }

      try {
        await nextController.setFlashMode(_flashMode);
      } catch (_) {
        _flashMode = FlashMode.off;
      }

      try {
        _minZoom = await nextController.getMinZoomLevel();
        _maxZoom = await nextController.getMaxZoomLevel();
        _currentZoom = 1.0.clamp(_minZoom, _maxZoom);
        await nextController.setZoomLevel(_currentZoom);
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
      }

      if (mounted) setState(() => _cameraStatus = _CameraStatus.ready);
    } on CameraException catch (e) {
      Logger.warn("Camera init failed: ${e.code} ${e.description}");
      if (!mounted) return;
      final denied = e.code == 'CameraAccessDenied' ||
          e.code == 'CameraAccessDeniedWithoutPrompt' ||
          e.code == 'CameraAccessRestricted';
      setState(() {
        _cameraStatus = denied ? _CameraStatus.permissionDenied : _CameraStatus.unavailable;
      });
    } catch (e, s) {
      Logger.error("Camera init error", error: e, trace: s);
      if (mounted) setState(() => _cameraStatus = _CameraStatus.unavailable);
    }
  }

  Future<void> _switchCamera() async {
    if (_isRecording || !_canSwitchCamera) return;
    if (_useAndroidNativeCamera) {
      _androidLensFacing = _androidLensFacing == 'back' ? 'front' : 'back';
      if (_androidViewId != null) {
        await _bindAndroidCamera(_androidViewId!);
      }
      return;
    }
    final currentDir = _cameras[_cameraIndex].lensDirection;
    final targetDir = currentDir == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    int nextIdx = _cameras.indexWhere((c) => c.lensDirection == targetDir);
    if (nextIdx < 0) nextIdx = (_cameraIndex + 1) % _cameras.length;
    await _initCamera(preferredIndex: nextIdx);
  }

  Future<void> _setVideoMode(bool video) async {
    if (_isVideoMode == video || _isRecording) return;
    setState(() => _isVideoMode = video);
    if (_useAndroidNativeCamera) {
      if (video && !_micGranted) {
        _micGranted = (await Permission.microphone.request()).isGranted;
      }
      if (_androidViewId != null) {
        await _bindAndroidCamera(_androidViewId!);
      }
      return;
    }
    // Re-initialize only if switching to video needs audio enabled on the active controller.
    if (video && !_micGranted) {
      await _initCamera(preferredIndex: _cameraIndex);
    }
  }

  Future<void> _cycleFlashMode() async {
    if (_useAndroidNativeCamera) {
      if (_cameraStatus != _CameraStatus.ready || !_androidHasFlash) return;
      final next = switch (_flashMode) {
        FlashMode.off => FlashMode.auto,
        FlashMode.auto => FlashMode.always,
        _ => FlashMode.off,
      };
      try {
        await _androidCameraChannel.invokeMethod<void>('setFlashMode', {'mode': _flashModeKey(next)});
        if (mounted) setState(() => _flashMode = next);
      } catch (_) {}
      return;
    }

    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) return;
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    try {
      await cam.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (_) {
      // Front/virtual cameras often have no flash unit.
    }
  }

  Future<void> _setZoom(double zoom) async {
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    if (_useAndroidNativeCamera) {
      if (_cameraStatus != _CameraStatus.ready) return;
      try {
        final applied = (await _androidCameraChannel.invokeMethod<num>('setZoom', {'zoom': clamped}))?.toDouble();
        if (mounted) setState(() => _currentZoom = applied ?? clamped);
      } catch (_) {}
      return;
    }

    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) return;
    try {
      await cam.setZoomLevel(clamped);
      if (mounted) setState(() => _currentZoom = clamped);
    } catch (_) {}
  }

  Future<void> _onShutterPressed() async {
    if (_isCapturing) return;
    final cam = _cameraController;
    if (_useAndroidNativeCamera ? _cameraStatus != _CameraStatus.ready : (cam == null || !cam.value.isInitialized)) {
      return;
    }

    if (!_isVideoMode) {
      setState(() => _isCapturing = true);
      try {
        final XFile? file;
        if (_useAndroidNativeCamera) {
          final path = await _androidCameraChannel.invokeMethod<String>('takePicture');
          file = (path != null && path.isNotEmpty) ? XFile(path) : null;
        } else {
          file = await cam!.takePicture();
        }
        if (file != null) await _attachXFileAndClose(file);
      } catch (e, s) {
        Logger.error("Failed to take picture", error: e, trace: s);
        showSnackbar("Error", "Failed to capture photo", type: SnackbarType.error);
      } finally {
        if (mounted) setState(() => _isCapturing = false);
      }
      return;
    }

    if (_isRecording) {
      setState(() => _isCapturing = true);
      _recordingTimer?.cancel();
      try {
        final XFile? file;
        if (_useAndroidNativeCamera) {
          final path = await _androidCameraChannel.invokeMethod<String>('stopVideoRecording');
          file = (path != null && path.isNotEmpty) ? XFile(path) : null;
        } else {
          file = await cam!.stopVideoRecording();
        }
        if (mounted) setState(() => _isRecording = false);
        if (file != null) await _attachXFileAndClose(file);
      } catch (e, s) {
        Logger.error("Failed to stop video recording", error: e, trace: s);
        showSnackbar("Error", "Failed to save video", type: SnackbarType.error);
        if (mounted) setState(() => _isRecording = false);
      } finally {
        if (mounted) setState(() => _isCapturing = false);
      }
    } else {
      try {
        if (_useAndroidNativeCamera) {
          await _androidCameraChannel.invokeMethod<void>('startVideoRecording', {'enableAudio': _micGranted});
        } else {
          await cam!.startVideoRecording();
        }
        _recordingTimer?.cancel();
        setState(() {
          _isRecording = true;
          _recordingSeconds = 0;
        });
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() => _recordingSeconds++);
        });
      } catch (e, s) {
        Logger.error("Failed to start video recording", error: e, trace: s);
        showSnackbar("Error", "Failed to start recording", type: SnackbarType.error);
      }
    }
  }

  Future<void> _attachXFileAndClose(XFile file) async {
    final added = await addPickedAttachmentIfUnderLimit(
      controller,
      path: file.path,
      name: file.name,
      size: await file.length(),
      readBytes: kIsWeb ? file.readAsBytes : null,
    );
    if (added && mounted) Navigator.of(context).pop();
  }

  Future<void> _loadRecentPhotos({bool reset = false}) async {
    if (kIsDesktop || kIsWeb) {
      if (mounted) {
        setState(() {
          _loadingPhotos = false;
          _hasMorePhotos = false;
        });
      }
      return;
    }

    if (reset) {
      setState(() {
        _loadingPhotos = true;
        _nextPageStart = 0;
        _hasMorePhotos = true;
      });
    } else {
      if (_loadingMorePhotos || !_hasMorePhotos || _recentAlbum == null) return;
      setState(() => _loadingMorePhotos = true);
    }

    try {
      if (reset) {
        final ps = await PhotoManager.requestPermissionExtend();
        if (!ps.hasAccess) {
          if (mounted) {
            setState(() {
              _photoPermissionDenied = true;
              _photoPermissionPermanentlyDenied = ps == PermissionState.denied;
              _loadingPhotos = false;
            });
          }
          return;
        }
        _photoPermissionDenied = false;
        _photoPermissionPermanentlyDenied = false;
        _isLimitedAccess = ps == PermissionState.limited;

        final albums = await PhotoManager.getAssetPathList(
          onlyAll: true,
          filterOption: FilterOptionGroup(
            orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
          ),
        );
        _recentAlbum = albums.isNotEmpty ? albums.first : null;
        _assets.clear();
      }

      if (_recentAlbum == null) {
        if (mounted) {
          setState(() {
            _hasMorePhotos = false;
            _loadingPhotos = false;
            _loadingMorePhotos = false;
          });
        }
        return;
      }

      final page = await _recentAlbum!.getAssetListRange(
        start: _nextPageStart,
        end: _nextPageStart + _pageSize,
      );
      if (mounted) {
        setState(() {
          _assets.addAll(page);
          _nextPageStart += page.length;
          _hasMorePhotos = page.length == _pageSize;
          _loadingPhotos = false;
          _loadingMorePhotos = false;
        });
      }
    } catch (e, s) {
      Logger.error("Failed to load recent photos", error: e, trace: s);
      if (mounted) {
        setState(() {
          _loadingPhotos = false;
          _loadingMorePhotos = false;
        });
      }
    }
  }

  Future<void> _pickFromSystemGallery() async {
    if (kIsDesktop || kIsWeb) return;
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return;
    for (final file in files) {
      await addPickedAttachmentIfUnderLimit(
        controller,
        path: file.path,
        size: await file.length(),
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleAsset(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null) return;
    if (!_resolvedAssetPaths.containsKey(asset.id) && _resolvedAssetPaths.length >= 500) {
      _resolvedAssetPaths.remove(_resolvedAssetPaths.keys.first);
    }
    _resolvedAssetPaths[asset.id] = file.path;
    await addPickedAttachmentIfUnderLimit(
      controller,
      path: file.path,
      size: await file.length(),
      readBytes: kIsWeb ? file.readAsBytes : null,
      toggleIfPresent: true,
    );
  }

  List<double> get _zoomSteps {
    final steps = <double>[];
    if (_minZoom <= 0.65) steps.add(0.6);
    steps.add(1.0);
    if (_maxZoom >= 2.0) steps.add(2.0);
    return steps;
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Material(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: screenHeight * 0.56,
            child: _buildCameraSection(context),
          ),
          Positioned.fill(
            child: DraggableScrollableSheet(
              initialChildSize: 0.48,
              minChildSize: 0.46,
              maxChildSize: 0.92,
              snap: true,
              snapSizes: const [0.48, 0.92],
              builder: (context, scrollController) => _buildGallerySheet(context, scrollController),
            ),
          ),
          Positioned(
            bottom: 16,
            right: 16,
            child: SafeArea(
              top: false,
              child: Obx(() {
                final count = controller.pickedAttachments.length;
                if (count == 0) return const SizedBox.shrink();
                return FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text('Attach ($count)'),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraSection(BuildContext context) {
    final cam = _cameraController;
    final hasPreview = _useAndroidNativeCamera
        ? (_cameraStatus == _CameraStatus.ready && _androidViewId != null)
        : (_cameraStatus == _CameraStatus.ready && cam != null && cam.value.isInitialized);
    final topInset = GmsgCameraGallerySheet.resolveTopInset(context, widget.topInset);

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_useAndroidNativeCamera) ...[
          if (_androidPermissionGranted)
            AndroidView(
              viewType: _androidPreviewViewType,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: (id) {
                _androidViewId = id;
                unawaited(_bindAndroidCamera(id));
              },
            ),
          if (!hasPreview) _buildCameraFallback(context),
        ] else if (hasPreview)
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: 1,
                // CameraController aspectRatio is landscape (w/h); invert in portrait so it matches sensor orientation.
                height: MediaQuery.orientationOf(context) == Orientation.portrait
                    ? cam!.value.aspectRatio
                    : 1 / cam!.value.aspectRatio,
                child: CameraPreview(cam),
              ),
            ),
          )
        else
          _buildCameraFallback(context),

        // Subtle top gradient scrim so white status-bar icons stay legible over bright scenes
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topInset + 56,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.45),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),

        // Top controls: Close (x), Recording timer, Flash toggle
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, topInset + 8, 12, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _circleOverlayButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  onTap: () => Navigator.of(context).pop(),
                ),
                if (_isRecording)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${(_recordingSeconds ~/ 60)}:${(_recordingSeconds % 60).toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                if (hasPreview)
                  _circleOverlayButton(
                    icon: switch (_flashMode) {
                      FlashMode.auto => Icons.flash_auto_rounded,
                      FlashMode.always => Icons.flash_on_rounded,
                      _ => Icons.flash_off_rounded,
                    },
                    tooltip: 'Flash',
                    onTap: _cycleFlashMode,
                  )
                else
                  const SizedBox(width: 40),
              ],
            ),
          ),
        ),

        // Bottom camera controls positioned cleanly above the gallery sheet's 4% overlap
        if (hasPreview)
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.sizeOf(context).height * 0.04 + 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_zoomSteps.length > 1) ...[
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final zoom in _zoomSteps)
                          GestureDetector(
                            onTap: () => _setZoom(zoom),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: (_currentZoom - zoom).abs() < 0.15
                                    ? Colors.white.withValues(alpha: 0.25)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                (_currentZoom - zoom).abs() < 0.15
                                    ? '${zoom.toStringAsFixed(1)}x'
                                    : zoom.toStringAsFixed(1),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 68),
                    GestureDetector(
                      onTap: _onShutterPressed,
                      child: Container(
                        width: 66,
                        height: 66,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3.5),
                        ),
                        alignment: Alignment.center,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: _isRecording ? 26 : 52,
                          height: _isRecording ? 26 : 52,
                          decoration: BoxDecoration(
                            color: _isVideoMode ? Colors.redAccent : Colors.white,
                            borderRadius: BorderRadius.circular(_isRecording ? 6 : 26),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    if (_canSwitchCamera)
                      _circleOverlayButton(
                        icon: Icons.cameraswitch_outlined,
                        tooltip: 'Switch camera',
                        size: 48,
                        onTap: _switchCamera,
                      )
                    else
                      const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _modePill('Photo', active: !_isVideoMode, onTap: () => _setVideoMode(false)),
                      _modePill('Video', active: _isVideoMode, onTap: () => _setVideoMode(true)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCameraFallback(BuildContext context) {
    if (_cameraStatus == _CameraStatus.loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator.adaptive()),
      );
    }

    final isDenied =
        _cameraStatus == _CameraStatus.permissionDenied || _cameraStatus == _CameraStatus.permanentlyDenied;
    return ColoredBox(
      color: const Color(0xFF141416),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDenied ? Icons.no_photography_outlined : Icons.videocam_off_outlined,
                color: Colors.white70,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                isDenied
                    ? 'Camera permission is needed for live preview.'
                    : 'Live camera preview is unavailable on this device.',
                textAlign: TextAlign.center,
                style: context.theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              if (isDenied) ...[
                const SizedBox(height: 14),
                FilledButton.tonal(
                  onPressed: () async {
                    if (_cameraStatus == _CameraStatus.permanentlyDenied) {
                      await openAppSettings();
                    }
                    await _initCamera();
                  },
                  child: Text(
                    _cameraStatus == _CameraStatus.permanentlyDenied ? 'Open Settings' : 'Allow Camera',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleOverlayButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 40,
  }) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _modePill(String label, {required bool active, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white.withValues(alpha: 0.22) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildGallerySheet(BuildContext context, ScrollController scrollController) {
    final scheme = context.theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels >= notification.metrics.maxScrollExtent - 300) {
            unawaited(_loadRecentPhotos());
          }
          return false;
        },
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 10),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            if (_isLimitedAccess)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Showing selected photos only',
                          style: context.theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          if (!kIsWeb && Platform.isAndroid) {
                            await openAppSettings();
                          } else {
                            await PhotoManager.presentLimited();
                          }
                          await _loadRecentPhotos(reset: true);
                        },
                        child: const Text('Manage'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loadingPhotos)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator.adaptive()),
              )
            else if (_photoPermissionDenied)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildGalleryStatus(
                  context,
                  icon: Icons.photo_library_outlined,
                  message: 'Allow photo access to browse recent photos & videos.',
                  primaryLabel: _photoPermissionPermanentlyDenied ? 'Open Settings' : 'Allow Access',
                  onPrimary: () async {
                    if (_photoPermissionPermanentlyDenied) {
                      await openAppSettings();
                    }
                    await _loadRecentPhotos(reset: true);
                  },
                ),
              )
            else if (_assets.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildGalleryStatus(
                  context,
                  icon: Icons.photo_library_outlined,
                  message: kIsWeb || kIsDesktop
                      ? 'Use system gallery to attach photos.'
                      : 'No recent photos or videos found.',
                  primaryLabel: 'Browse Gallery',
                  onPrimary: _pickFromSystemGallery,
                ),
              )
            else ...[
              SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final asset = _assets[index];
                    return _GmsgPhotoGridTile(
                      key: ValueKey(asset.id),
                      asset: asset,
                      controller: controller,
                      resolvedAssetPaths: _resolvedAssetPaths,
                      onTap: () => _toggleAsset(asset),
                    );
                  },
                  childCount: _assets.length,
                ),
              ),
              if (_loadingMorePhotos)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator.adaptive()),
                  ),
                ),
            ],
            SliverPadding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom + 84),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryStatus(
    BuildContext context, {
    required IconData icon,
    required String message,
    required String primaryLabel,
    required VoidCallback onPrimary,
  }) {
    final scheme = context.theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.tonal(onPressed: onPrimary, child: Text(primaryLabel)),
                if (!kIsWeb && !kIsDesktop && _photoPermissionDenied)
                  OutlinedButton(onPressed: _pickFromSystemGallery, child: const Text('System Gallery')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GmsgPhotoGridTile extends StatefulWidget {
  const _GmsgPhotoGridTile({
    super.key,
    required this.asset,
    required this.controller,
    required this.resolvedAssetPaths,
    required this.onTap,
  });

  final AssetEntity asset;
  final ConversationViewController controller;
  final RxMap<String, String> resolvedAssetPaths;
  final VoidCallback onTap;

  @override
  State<_GmsgPhotoGridTile> createState() => _GmsgPhotoGridTileState();
}

class _GmsgPhotoGridTileState extends State<_GmsgPhotoGridTile> {
  Uint8List? _thumbBytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadThumbnail());
  }

  Future<void> _loadThumbnail() async {
    try {
      final bytes = await widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(300));
      if (mounted) {
        setState(() {
          _thumbBytes = bytes;
          _loading = false;
        });
      }
    } catch (_) {
      // Render fallback tile cleanly on any decode/IO failure.
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    return Obx(() {
      final hideAttachments =
          SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideAttachments.value;
      final resolvedPath = widget.resolvedAssetPaths[widget.asset.id];
      final selected = resolvedPath != null && widget.controller.pickedAttachments.any((e) => e.path == resolvedPath);
      final isVideo = widget.asset.type == AssetType.video;

      return InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_loading || hideAttachments || _thumbBytes == null)
              ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: isVideo ? Icon(Icons.videocam_outlined, color: scheme.onSurfaceVariant) : null,
              )
            else
              Image.memory(
                _thumbBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
                ),
              ),
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 3),
                  color: Colors.black26,
                ),
              ),
            if (isVideo)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
                ),
              ),
            if (selected)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Icon(Icons.check_rounded, size: 15, color: scheme.onPrimary),
                ),
              ),
          ],
        ),
      );
    });
  }
}

import 'dart:math' as math;
import 'dart:ui';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/wrappers/trackpad_bug_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/route_transition_helpers.dart';
import 'package:bluebubbles/platform/shims/desktop_window.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:maplibre/maplibre.dart' as maplibre;
import 'package:url_launcher/url_launcher.dart';

/// Orders markers for back-to-front painting in 2D and tilted 3D views:
/// 0 = unselected friends/devices, 1 = self location (`current`), 2 = selected pin.
/// Within the same rank, markers further away along the camera's forward look
/// vector ([bearingDegrees] clockwise from North) draw first (underneath) so
/// closer pins cleanly overlap farther ones.
List<maplibre.Marker> orderFindMyMarkers(
  Iterable<maplibre.Marker> markers, {
  String? selectedFriendId,
  String? selectedDeviceId,
  double bearingDegrees = 0.0,
}) {
  final list = markers.toList(growable: false);
  if (list.length <= 1) return list;

  final selectedFriendKey = selectedFriendId != null ? 'friend-$selectedFriendId' : null;
  final selectedDeviceKey = selectedDeviceId != null ? 'device-$selectedDeviceId' : null;

  int rankFor(maplibre.Marker marker) {
    final key = marker.child.key;
    if (key is ValueKey<String>) {
      final v = key.value;
      if (v == selectedFriendKey || v == selectedDeviceKey) return 2;
      if (v == 'current') return 1;
    }
    return 0;
  }

  final bearingRad = bearingDegrees * math.pi / 180.0;
  final sinB = math.sin(bearingRad);
  final cosB = math.cos(bearingRad);

  double depthAlongBearing(maplibre.Marker marker) {
    final lat = marker.point.lat;
    final lon = marker.point.lon;
    final cosLat = math.cos(lat * math.pi / 180.0);
    return (lon * cosLat) * sinB + lat * cosB;
  }

  final indexed = [
    for (var i = 0; i < list.length; i++)
      (index: i, marker: list[i], rank: rankFor(list[i]), depth: depthAlongBearing(list[i])),
  ];
  indexed.sort((a, b) {
    final r = a.rank.compareTo(b.rank);
    if (r != 0) return r;
    final depthDiff = b.depth - a.depth;
    if (depthDiff.abs() > 1e-9) {
      return depthDiff > 0 ? 1 : -1;
    }
    return a.index.compareTo(b.index);
  });
  return [for (final item in indexed) item.marker];
}

/// Hit-tests back-to-front [orderedMarkers] at [screenPoint] using their
/// corresponding projected [screenOffsets]. Keeps pointer pass-through intact
/// on [maplibre.WidgetLayer] (`allowInteraction: false`) so touching a pin
/// never blocks map pinch-to-zoom or pan gestures.
String? hitTestFindMyMarkerKey(
  List<maplibre.Marker> orderedMarkers,
  List<Offset> screenOffsets,
  Offset screenPoint,
) {
  if (orderedMarkers.isEmpty || orderedMarkers.length != screenOffsets.length) {
    return null;
  }
  for (var i = orderedMarkers.length - 1; i >= 0; i--) {
    final marker = orderedMarkers[i];
    final offset = screenOffsets[i];
    if (!offset.dx.isFinite || !offset.dy.isFinite) continue;
    final key = marker.child.key;
    if (key is! ValueKey<String>) continue;
    final keyStr = key.value;

    final Rect hitRect;
    if (keyStr.startsWith('friend-') || keyStr.startsWith('device-')) {
      // Visual medallion (40px) + stem + anchor dot sit centered above offset.
      hitRect = Rect.fromLTWH(offset.dx - 28.0, offset.dy - 64.0, 56.0, 64.0);
    } else if (keyStr == 'current') {
      hitRect = Rect.fromCenter(center: offset, width: 48.0, height: 48.0);
    } else {
      final left = offset.dx - marker.size.width * ((marker.alignment.x + 1.0) * 0.5);
      final top = offset.dy - marker.size.height * ((marker.alignment.y + 1.0) * 0.5);
      hitRect = Rect.fromLTWH(left, top, marker.size.width, marker.size.height);
    }

    if (hitRect.contains(screenPoint)) {
      return keyStr;
    }
  }
  return null;
}

bool _isMapLibreSupportedPlatform() {
  final bindingName = WidgetsBinding.instance.runtimeType.toString();
  if (bindingName.contains('TestWidgetsFlutterBinding')) {
    return false;
  }
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
}

class FindMyMapWidget extends StatefulWidget {
  const FindMyMapWidget({
    super.key,
    required this.controller,
    this.onSelectFriend,
    this.onSelectDevice,
    this.debugForceFallbackMap,
  });

  final FindMyController controller;
  final ValueChanged<FindMyFriend>? onSelectFriend;
  final ValueChanged<FindMyDevice>? onSelectDevice;
  @visibleForTesting
  final bool? debugForceFallbackMap;

  @override
  State<FindMyMapWidget> createState() => _FindMyMapWidgetState();
}

class _FindMyMapWidgetState extends State<FindMyMapWidget> with TickerProviderStateMixin {
  AnimationController? _cameraAnim;
  final Map<String, AnimationController> _pinAnims = {};
  maplibre.CameraChangeReason _lastCameraChangeReason = maplibre.CameraChangeReason.programmatic;
  bool _pendingPostFrameComplete = false;
  maplibre.CameraUpdate? _initialMapCamera;

  FindMyController get controller => widget.controller;

  bool get _useFallbackMap => widget.debugForceFallbackMap ?? !_isMapLibreSupportedPlatform();

  @override
  void initState() {
    super.initState();
    controller.registerCamera3DAnimator(_animateCamera);
    controller.registerPinInterpolator(_interpolatePin);
    if (_useFallbackMap) {
      _completeFallbackReadyPostFrame();
    }
  }

  @override
  void didUpdateWidget(covariant FindMyMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.registerCamera3DAnimator(null);
      oldWidget.controller.registerPinInterpolator(null);
      widget.controller.registerCamera3DAnimator(_animateCamera);
      widget.controller.registerPinInterpolator(_interpolatePin);
      _initialMapCamera = null;
    }
  }

  void _completeFallbackReadyPostFrame() {
    if (controller.completer.isCompleted || _pendingPostFrameComplete) return;
    _pendingPostFrameComplete = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingPostFrameComplete = false;
      if (mounted && !controller.completer.isCompleted) {
        controller.completer.complete();
      }
    });
  }

  @override
  void dispose() {
    controller.registerCamera3DAnimator(null);
    controller.registerPinInterpolator(null);
    _cameraAnim?.dispose();
    for (final anim in _pinAnims.values) {
      anim.dispose();
    }
    _pinAnims.clear();
    super.dispose();
  }

  bool _reduceMotion(BuildContext context) {
    final highPerf = GetIt.I.isRegistered<SettingsService>() && SettingsSvc.settings.highPerfMode.value;
    return highPerf || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  void _animateCamera(
    LatLng destCenter,
    double destZoom, {
    Offset offset = Offset.zero,
    double? pitch,
    double? bearing,
    EdgeInsets? padding,
    bool fly = false,
  }) {
    final targetPitch = (pitch ?? controller.cameraPitch.value).clamp(0.0, 60.0);
    final targetBearing = ((bearing ?? controller.cameraBearing.value) % 360.0 + 360.0) % 360.0;
    final targetPadding = padding ?? EdgeInsets.zero;

    if (!_useFallbackMap) {
      final mlController = controller.mapLibreController;
      if (mlController != null) {
        final update = maplibre.CameraUpdate.position(
          center: toGeographic(destCenter),
          zoom: destZoom,
          pitch: targetPitch,
          bearing: targetBearing,
          padding: targetPadding,
        );
        final animation = fly
            ? const maplibre.CameraAnimation.fly(duration: Duration(milliseconds: 780), curve: Curves.easeOutCubic)
            : const maplibre.CameraAnimation.ease(duration: Duration(milliseconds: 480), curve: Curves.easeOutCubic);
        mlController.animateCamera(update, animation: animation);
        return;
      }
    }

    if (!mounted || _reduceMotion(context)) {
      controller.cameraCenter.value = destCenter;
      controller.cameraZoom.value = destZoom;
      controller.cameraPitch.value = targetPitch;
      controller.cameraBearing.value = targetBearing;
      controller.markerOrderBearing.value = targetBearing;
      controller.cameraPadding = targetPadding;
      return;
    }

    _cameraAnim?.stop();
    _cameraAnim?.dispose();

    final startCenter = controller.cameraCenter.value;
    final startZoom = controller.cameraZoom.value;
    final startPitch = controller.cameraPitch.value;
    final startBearing = controller.cameraBearing.value;
    final startTime = DateTime.now();
    // Avoid unused field warnings while keeping immediate test compatibility
    assert(startTime.millisecondsSinceEpoch >= 0);

    final anim = AnimationController(
      duration: Duration(milliseconds: fly ? 780 : 480),
      vsync: this,
    );
    _cameraAnim = anim;

    final latTween = Tween<double>(begin: startCenter.latitude, end: destCenter.latitude);
    final lngTween = Tween<double>(begin: startCenter.longitude, end: destCenter.longitude);
    final zoomTween = Tween<double>(begin: startZoom, end: destZoom);
    final pitchTween = Tween<double>(begin: startPitch, end: targetPitch);
    var bearingDelta = ((targetBearing - startBearing + 540.0) % 360.0) - 180.0;
    final bearingTween = Tween<double>(begin: startBearing, end: startBearing + bearingDelta);
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);

    anim.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      controller.cameraCenter.value = LatLng(latTween.transform(t), lngTween.transform(t));
      controller.cameraZoom.value = zoomTween.transform(t);
      controller.cameraPitch.value = pitchTween.transform(t);
      controller.cameraBearing.value = ((bearingTween.transform(t) % 360.0) + 360.0) % 360.0;
    });
    anim.addStatusListener((status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        if (mounted && status == AnimationStatus.completed) {
          controller.markerOrderBearing.value = targetBearing;
        }
        if (identical(_cameraAnim, anim)) {
          _cameraAnim = null;
        }
        anim.dispose();
      }
    });
    anim.forward();
  }

  void _interpolatePin(String key, LatLng from, LatLng to, void Function(LatLng) onStep) {
    if (!mounted || _reduceMotion(context)) {
      onStep(to);
      return;
    }

    _pinAnims[key]?.stop();
    _pinAnims[key]?.dispose();

    final anim = AnimationController(
      duration: const Duration(milliseconds: 650),
      vsync: this,
    );
    _pinAnims[key] = anim;

    final latTween = Tween<double>(begin: from.latitude, end: to.latitude);
    final lngTween = Tween<double>(begin: from.longitude, end: to.longitude);
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);

    void listener() {
      if (!mounted) return;
      final t = curved.value;
      onStep(LatLng(latTween.transform(t), lngTween.transform(t)));
    }

    void statusListener(AnimationStatus status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        anim.removeListener(listener);
        anim.removeStatusListener(statusListener);
        if (identical(_pinAnims[key], anim)) {
          _pinAnims.remove(key);
        }
        anim.dispose();
      }
    }

    anim.addListener(listener);
    anim.addStatusListener(statusListener);
    anim.forward(from: 0);
  }

  void _handleMarkerTap(String keyStr) {
    if (keyStr == 'current') {
      controller.recenterToUser();
      return;
    }

    if (keyStr.startsWith('friend-')) {
      final stableId = keyStr.substring('friend-'.length);
      final friend = controller.friends.firstWhereOrNull((e) => e.stableId == stableId);
      if (friend == null) return;
      if (widget.onSelectFriend != null) {
        widget.onSelectFriend!(friend);
      } else {
        controller.focusFriend(friend);
      }
      return;
    }

    if (keyStr.startsWith('device-')) {
      final deviceId = keyStr.substring('device-'.length);
      final device = controller.devices.firstWhereOrNull((e) => (e.id ?? '') == deviceId);
      if (device == null) return;
      if (widget.onSelectDevice != null) {
        widget.onSelectDevice!(device);
      } else {
        controller.focusDevice(device);
      }
    }
  }

  maplibre.Marker _wrapInteractiveMarker(maplibre.Marker marker) {
    final childKey = marker.child.key;
    if (childKey is! ValueKey<String>) return marker;
    final keyStr = childKey.value;
    return maplibre.Marker(
      point: marker.point,
      size: marker.size,
      alignment: marker.alignment,
      rotate: marker.rotate,
      child: MouseRegion(
        key: childKey,
        cursor: SystemMouseCursors.click,
        onEnter: (_) => controller.hoveredMarkerKey.value = keyStr,
        onExit: (_) {
          if (controller.hoveredMarkerKey.value == keyStr) {
            controller.hoveredMarkerKey.value = null;
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _handleMarkerTap(keyStr),
          child: KeyedSubtree(
            key: ValueKey('inner-$keyStr'),
            child: marker.child,
          ),
        ),
      ),
    );
  }

  List<maplibre.Marker> _orderedMarkers({required bool interactive, bool liveBearing = false}) {
    final ordered = orderFindMyMarkers(
      controller.markers.values,
      selectedFriendId: controller.selectedFriendId.value,
      selectedDeviceId: controller.selectedDeviceId.value,
      bearingDegrees: liveBearing ? controller.cameraBearing.value : controller.markerOrderBearing.value,
    );
    if (!interactive) return ordered;
    return [for (final m in ordered) _wrapInteractiveMarker(m)];
  }

  String? _hitTestMarkerAt(Offset screenPoint, List<maplibre.Marker> orderedMarkers) {
    final mlController = controller.mapLibreController;
    if (mlController == null || orderedMarkers.isEmpty) return null;
    try {
      final offsets = mlController.toScreenLocations([
        for (final m in orderedMarkers) m.point,
      ]);
      return hitTestFindMyMarkerKey(orderedMarkers, offsets, screenPoint);
    } catch (_) {
      return null;
    }
  }

  ({LatLng center, double radiusMeters})? _selectedAccuracyTarget() {
    final friendId = controller.selectedFriendId.value;
    if (friendId != null) {
      final friend = controller.friends.firstWhereOrNull((f) => f.stableId == friendId);
      final acc = friend?.horizontalAccuracy;
      if (friend != null &&
          (friend.latitude ?? 0) != 0 &&
          (friend.longitude ?? 0) != 0 &&
          acc != null &&
          acc.isFinite &&
          acc > 0) {
        final key = friend.stableId ?? friend.title ?? 'friend';
        return (
          center: controller.animatedPoints[key] ?? controller.markerPointForFriend(friend),
          radiusMeters: acc,
        );
      }
    }
    final deviceId = controller.selectedDeviceId.value;
    if (deviceId != null) {
      final device = controller.devices.firstWhereOrNull((d) => d.id == deviceId);
      final acc = device?.location?.horizontalAccuracy;
      if (device != null &&
          device.location?.latitude != null &&
          device.location?.longitude != null &&
          acc != null &&
          acc.isFinite &&
          acc > 0) {
        final key = device.id ?? device.name ?? 'device';
        return (
          center: controller.animatedPoints[key] ?? controller.markerPointForDevice(device),
          radiusMeters: acc,
        );
      }
    }
    return null;
  }

  double _safeDesktopTitleBarHeight() {
    if (!kIsDesktop || _isInWidgetTest) return 0.0;
    try {
      return appWindow.titleBarHeight;
    } catch (_) {
      return 0.0;
    }
  }

  bool get _isInWidgetTest =>
      WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding');

  Widget _buildMapLibreSurface({
    required Brightness brightness,
    required Color primaryColor,
  }) {
    // Capture initial camera outside Obx so 60-120Hz camera updates do not rebuild MapLibreMap.
    _initialMapCamera ??= maplibre.CameraUpdate.position(
      center: toGeographic(controller.cameraCenter.value),
      zoom: controller.cameraZoom.value,
      pitch: controller.cameraPitch.value,
      bearing: controller.cameraBearing.value,
      padding: controller.cameraPadding,
    );

    final mapWidget = Obx(() {
      final style = controller.mapStyle.value;
      final styleUrl = resolveFindMyStyleUrl(style, brightness);
      final accuracyTarget = _selectedAccuracyTarget();
      final accuracyPolygons = accuracyTarget == null
          ? const <maplibre.Feature<maplibre.Polygon>>[]
          : <maplibre.Feature<maplibre.Polygon>>[
              buildFindMyAccuracyFeature(
                accuracyTarget.center,
                accuracyTarget.radiusMeters,
              ),
            ];

      return maplibre.MapLibreMap(
        options: maplibre.MapOptions(
          style: maplibre.MapStyle.url(styleUrl),
          initCamera: _initialMapCamera!,
          minZoom: 1.5,
          maxZoom: 19.0,
          minPitch: 0.0,
          maxPitch: 60.0,
        ),
        onMapCreated: (mapController) {
          controller.mapLibreController = mapController;
          if (!controller.completer.isCompleted) {
            controller.completer.complete();
          }
        },
        onStyleLoaded: (styleController) {
          controller.mapStyleController = styleController;
          controller.sync3DBuildingsLayer(brightness: brightness);
        },
        onClick: (event) {
          final hitKey = _hitTestMarkerAt(event.screenPoint, _orderedMarkers(interactive: false, liveBearing: true));
          if (hitKey != null) {
            _handleMarkerTap(hitKey);
          } else {
            controller.clearSelection();
          }
        },
        onPointerMove: (event) {
          final hitKey = _hitTestMarkerAt(event.screenPoint, _orderedMarkers(interactive: false, liveBearing: true));
          if (controller.hoveredMarkerKey.value != hitKey) {
            controller.hoveredMarkerKey.value = hitKey;
          }
        },
        onPointerLeave: (_) {
          if (controller.hoveredMarkerKey.value != null) {
            controller.hoveredMarkerKey.value = null;
          }
        },
        onCameraMoveStart: (event) {
          _lastCameraChangeReason = event.reason;
        },
        onCameraMove: (event) {
          controller.onMapCameraChanged(
            center: fromGeographic(event.camera.center),
            zoom: event.camera.zoom,
            pitch: event.camera.pitch,
            bearing: event.camera.bearing,
            reason: _lastCameraChangeReason,
            settled: false,
          );
        },
        onCameraMoveEnd: (event) {
          controller.onMapCameraChanged(
            center: fromGeographic(event.camera.center),
            zoom: event.camera.zoom,
            pitch: event.camera.pitch,
            bearing: event.camera.bearing,
            reason: _lastCameraChangeReason,
            settled: true,
          );
        },
        layers: [
          if (accuracyPolygons.isNotEmpty)
            maplibre.PolygonLayer(
              polygons: accuracyPolygons,
              color: maplibre.Expression.literal(primaryColor.withValues(alpha: 0.14)),
              outlineColor: maplibre.Expression.literal(primaryColor.withValues(alpha: 0.55)),
            ),
        ],
        children: [
          // Keep markers translucent to pointer hit-testing so pinching
          // or panning never gets swallowed when a finger starts on a pin.
          Obx(
            () => maplibre.WidgetLayer(
              allowInteraction: false,
              markers: _orderedMarkers(interactive: false),
            ),
          ),
        ],
      );
    });

    return Obx(
      () => MouseRegion(
        cursor: controller.hoveredMarkerKey.value != null ? SystemMouseCursors.click : MouseCursor.defer,
        child: mapWidget,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopTop = _safeDesktopTitleBarHeight();
    final brightness = Theme.of(context).brightness;
    final primaryColor = context.theme.colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite &&
            constraints.maxHeight.isFinite &&
            constraints.maxWidth > 0 &&
            constraints.maxHeight > 0) {
          controller.mapViewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        }

        return TrackpadBugWrapper(
          builder: (context, bugDetected) {
            final useFallback = _useFallbackMap;
            return Stack(
              children: [
                Positioned.fill(
                  child: Obx(
                    () => ColoredBox(
                      color: resolveFindMyMapBackgroundColor(controller.mapStyle.value, brightness),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: useFallback
                      ? _ProjectedFallbackMap(
                          controller: controller,
                          orderedMarkersBuilder: () => _orderedMarkers(interactive: true, liveBearing: true),
                          accuracyTargetBuilder: _selectedAccuracyTarget,
                          brightness: brightness,
                          primaryColor: primaryColor,
                        )
                      : _buildMapLibreSurface(
                          brightness: brightness,
                          primaryColor: primaryColor,
                        ),
                ),
                // Top-right floating map controls (3D/2D, Compass, Zoom, Locate, Fit-All, Style)
                Positioned(
                  top: 12 + MediaQuery.of(context).padding.top + desktopTop,
                  right: 14,
                  child: _FloatingMapControls(controller: controller),
                ),
                // OpenFreeMap + OpenMapTiles + OSM attribution chip
                Positioned(
                  left: 14,
                  bottom: context.isPhone ? 156 : 12,
                  child: Obx(
                    () => _AttributionChip(
                      style: controller.mapStyle.value,
                      brightness: brightness,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ProjectedFallbackMap extends StatelessWidget {
  const _ProjectedFallbackMap({
    required this.controller,
    required this.orderedMarkersBuilder,
    required this.accuracyTargetBuilder,
    required this.brightness,
    required this.primaryColor,
  });

  final FindMyController controller;
  final List<maplibre.Marker> Function() orderedMarkersBuilder;
  final ({LatLng center, double radiusMeters})? Function() accuracyTargetBuilder;
  final Brightness brightness;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.clearSelection,
      child: Obx(() {
        final style = controller.mapStyle.value;
        final bgColor = resolveFindMyMapBackgroundColor(style, brightness);
        final markers = orderedMarkersBuilder();
        final accuracyTarget = accuracyTargetBuilder();
        final center = controller.cameraCenter.value;
        final zoom = controller.cameraZoom.value;
        final bearing = controller.cameraBearing.value;
        final pitch = controller.cameraPitch.value;
        final viewport = controller.mapViewportSize;
        final dark = isDarkFindMyMapStyle(style, brightness);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _FallbackGridPainter(
                  backgroundColor: bgColor,
                  gridColor: (dark ? Colors.white : Colors.black).withValues(alpha: 0.05),
                  center: center,
                  zoom: zoom,
                  pitchDegrees: pitch,
                  accuracyCenter: accuracyTarget?.center,
                  accuracyRadiusMeters: accuracyTarget?.radiusMeters,
                  accuracyColor: primaryColor,
                ),
              ),
            ),
            for (final marker in markers)
              () {
                final pos = projectLatLngToScreenOffset(
                  fromGeographic(marker.point),
                  center: center,
                  zoom: zoom,
                  viewportSize: viewport,
                  bearingDegrees: bearing,
                );
                final left = pos.dx - marker.size.width * ((marker.alignment.x + 1.0) * 0.5);
                final top = pos.dy - marker.size.height * ((marker.alignment.y + 1.0) * 0.5);
                return Positioned(
                  left: left,
                  top: top,
                  width: marker.size.width,
                  height: marker.size.height,
                  child: marker.child,
                );
              }(),
          ],
        );
      }),
    );
  }
}

class _FallbackGridPainter extends CustomPainter {
  const _FallbackGridPainter({
    required this.backgroundColor,
    required this.gridColor,
    required this.center,
    required this.zoom,
    required this.pitchDegrees,
    required this.accuracyCenter,
    required this.accuracyRadiusMeters,
    required this.accuracyColor,
  });

  final Color backgroundColor;
  final Color gridColor;
  final LatLng center;
  final double zoom;
  final double pitchDegrees;
  final LatLng? accuracyCenter;
  final double? accuracyRadiusMeters;
  final Color accuracyColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (accuracyCenter != null && accuracyRadiusMeters != null && accuracyRadiusMeters! > 0) {
      final ring = buildGeodesicCircleRing(accuracyCenter!, accuracyRadiusMeters!, segments: 36);
      final path = Path();
      for (var i = 0; i < ring.length; i++) {
        final pt = projectLatLngToScreenOffset(
          ring[i],
          center: center,
          zoom: zoom,
          viewportSize: size,
        );
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = accuracyColor.withValues(alpha: 0.14)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = accuracyColor.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FallbackGridPainter oldDelegate) =>
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.center != center ||
      oldDelegate.zoom != zoom ||
      oldDelegate.pitchDegrees != pitchDegrees ||
      oldDelegate.accuracyCenter != accuracyCenter ||
      oldDelegate.accuracyRadiusMeters != accuracyRadiusMeters;
}

class _AttributionChip extends StatelessWidget {
  const _AttributionChip({required this.style, required this.brightness});

  final FindMyMapStyle style;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final dark = isDarkFindMyMapStyle(style, brightness);
    return Material(
      color: (dark ? Colors.black : Colors.white).withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => launchUrl(Uri.parse(style.attributionUrl)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            style.attribution,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: dark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingMapControls extends StatelessWidget {
  const _FloatingMapControls({required this.controller});

  final FindMyController controller;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final hasSettings = GetIt.I.isRegistered<SettingsService>();
    final highPerf = hasSettings && SettingsSvc.settings.highPerfMode.value;
    final useCupertinoIcons = hasSettings && context.iOS;
    final pill = Container(
      width: 44,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.38)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 3D / 2D toggle
          Obx(() {
            final enabled3D = controller.is3DEnabled.value;
            return Tooltip(
              message: enabled3D ? 'Switch to 2D Map' : 'Switch to 3D Map',
              child: InkWell(
                key: const ValueKey('findmy-3d-toggle'),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                onTap: () => controller.toggle3D(),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: enabled3D ? cs.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        enabled3D ? '3D' : '2D',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          color: enabled3D ? cs.onPrimary : cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
          // Dynamic Compass (shows bearing & smoothly resets North)
          Obx(() {
            final bearing = controller.cameraBearing.value;
            final pitch = controller.cameraPitch.value;
            final isRotated = bearing.abs() > 0.5 && (360.0 - bearing).abs() > 0.5;
            return IconButton(
              key: const ValueKey('findmy-compass'),
              tooltip: 'Reset North',
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 42),
              onPressed: controller.resetNorth,
              icon: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.002)
                  ..rotateX((pitch * 0.45) * math.pi / 180.0)
                  ..rotateZ(-bearing * math.pi / 180.0),
                child: Icon(
                  useCupertinoIcons ? CupertinoIcons.compass : Icons.explore_outlined,
                  color: isRotated ? cs.primary : cs.onSurface,
                ),
              ),
            );
          }),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
          // Map style switcher
          PopupMenuButton<FindMyMapStyle>(
            key: const ValueKey('findmy-style-picker'),
            tooltip: 'Map Style',
            padding: EdgeInsets.zero,
            onSelected: controller.setMapStyle,
            itemBuilder: (context) => [
              for (final style in FindMyMapStyle.values)
                PopupMenuItem<FindMyMapStyle>(
                  value: style,
                  child: Obx(
                    () => Row(
                      children: [
                        Icon(
                          controller.mapStyle.value == style ? Icons.check_circle : Icons.circle_outlined,
                          size: 18,
                          color: controller.mapStyle.value == style ? cs.primary : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Text(style.label),
                      ],
                    ),
                  ),
                ),
            ],
            child: SizedBox(
              width: 44,
              height: 42,
              child: Icon(
                useCupertinoIcons ? CupertinoIcons.map : Icons.layers_outlined,
                size: 20,
                color: cs.onSurface,
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
          // Zoom in
          IconButton(
            key: const ValueKey('findmy-zoom-in'),
            tooltip: 'Zoom In',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
            onPressed: () => controller.zoomBy(1.0),
            icon: Icon(Icons.add, color: cs.onSurface),
          ),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
          // Zoom out
          IconButton(
            key: const ValueKey('findmy-zoom-out'),
            tooltip: 'Zoom Out',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
            onPressed: () => controller.zoomBy(-1.0),
            icon: Icon(Icons.remove, color: cs.onSurface),
          ),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
          // Locate me
          Obx(
            () => IconButton(
              key: const ValueKey('findmy-locate-me'),
              tooltip: 'My Location',
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 42),
              onPressed: () => controller.recenterToUser(),
              icon: Icon(
                useCupertinoIcons ? CupertinoIcons.location_fill : Icons.my_location,
                color: controller.location.value != null ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
          // Fit all pins
          IconButton(
            key: const ValueKey('findmy-fit-all'),
            tooltip: 'Fit All Pins',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: () => controller.fitAllPins(),
            icon: Icon(
              useCupertinoIcons ? CupertinoIcons.fullscreen : Icons.fit_screen_outlined,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: RouteSettledBackdropFilter(
        enabled: !highPerf,
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: pill,
      ),
    );
  }
}

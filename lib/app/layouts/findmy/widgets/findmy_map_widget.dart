import 'dart:ui';

import 'package:bluebubbles/platform/shims/desktop_window.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/wrappers/trackpad_bug_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_popup/flutter_map_marker_popup.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart' show FindMyLiveBadge;

class FindMyMapWidget extends StatefulWidget {
  final FindMyController controller;
  final void Function(FindMyFriend friend)? onSelectFriend;
  final void Function(FindMyDevice device)? onSelectDevice;

  const FindMyMapWidget({
    super.key,
    required this.controller,
    this.onSelectFriend,
    this.onSelectDevice,
  });

  @override
  State<FindMyMapWidget> createState() => _FindMyMapWidgetState();
}

class _FindMyMapWidgetState extends State<FindMyMapWidget> with TickerProviderStateMixin {
  late final AnimationController _cameraAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  final Map<String, AnimationController> _pinAnims = {};
  VoidCallback? _activeCameraListener;

  FindMyController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.registerCameraAnimator(_animateCamera);
    controller.registerPinInterpolator(_interpolatePin);
  }

  @override
  void didUpdateWidget(covariant FindMyMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.registerCameraAnimator(null);
      oldWidget.controller.registerPinInterpolator(null);
      controller.registerCameraAnimator(_animateCamera);
      controller.registerPinInterpolator(_interpolatePin);
    }
  }

  @override
  void dispose() {
    controller.registerCameraAnimator(null);
    controller.registerPinInterpolator(null);
    if (_activeCameraListener != null) {
      _cameraAnim.removeListener(_activeCameraListener!);
    }
    _cameraAnim.dispose();
    for (final anim in _pinAnims.values) {
      anim.dispose();
    }
    _pinAnims.clear();
    super.dispose();
  }

  void _animateCamera(LatLng targetCenter, double targetZoom, {Offset offset = Offset.zero}) {
    if (!mounted) return;
    LatLng startCenter;
    double startZoom;
    try {
      startCenter = controller.mapController.camera.center;
      startZoom = controller.mapController.camera.zoom;
    } catch (_) {
      return;
    }

    if (_activeCameraListener != null) {
      _cameraAnim.removeListener(_activeCameraListener!);
    }
    _cameraAnim.stop();

    final latTween = Tween<double>(begin: startCenter.latitude, end: targetCenter.latitude);
    final lngTween = Tween<double>(begin: startCenter.longitude, end: targetCenter.longitude);
    final zoomTween = Tween<double>(begin: startZoom, end: targetZoom);
    final curve = CurvedAnimation(parent: _cameraAnim, curve: Curves.easeOutCubic);

    _activeCameraListener = () {
      if (!mounted) return;
      final t = curve.value;
      try {
        controller.mapController.move(
          LatLng(latTween.transform(t), lngTween.transform(t)),
          zoomTween.transform(t),
          offset: Offset(offset.dx * t, offset.dy * t),
        );
      } catch (_) {}
    };

    _cameraAnim.addListener(_activeCameraListener!);
    _cameraAnim.forward(from: 0);
  }

  void _interpolatePin(String key, LatLng from, LatLng to, void Function(LatLng) onStep) {
    if (!mounted) {
      onStep(to);
      return;
    }
    final anim = _pinAnims.putIfAbsent(
      key,
      () => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 450),
      ),
    );
    anim.stop();
    final latTween = Tween<double>(begin: from.latitude, end: to.latitude);
    final lngTween = Tween<double>(begin: from.longitude, end: to.longitude);
    final curve = CurvedAnimation(parent: anim, curve: Curves.easeInOutCubic);

    void listener() {
      if (!mounted) return;
      final t = curve.value;
      onStep(LatLng(latTween.transform(t), lngTween.transform(t)));
    }

    void statusListener(AnimationStatus status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        anim.removeListener(listener);
        anim.removeStatusListener(statusListener);
      }
    }

    anim.addListener(listener);
    anim.addStatusListener(statusListener);
    anim.forward(from: 0);
  }

  void _handleMarkerTap(PopupSpec popupSpec, PopupState popupState, PopupController popupController) {
    final key = popupSpec.marker.key;
    if (key is! ValueKey<String>) return;
    final keyStr = key.value;

    if (keyStr == 'current') {
      popupController.hideAllPopups();
      controller.recenterToUser();
      return;
    }

    if (keyStr.startsWith('friend-')) {
      final stableId = keyStr.substring('friend-'.length);
      final friend = controller.friends.firstWhereOrNull((e) => e.stableId == stableId);
      if (friend == null) return;
      popupController.hideAllPopups();
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
      popupController.hideAllPopups();
      if (widget.onSelectDevice != null) {
        widget.onSelectDevice!(device);
      } else {
        controller.focusDevice(device);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktopTop = kIsDesktop ? appWindow.titleBarHeight : 0.0;

    return TrackpadBugWrapper(builder: (context, bugDetected) {
      return Stack(
        children: [
          Obx(() {
            final style = controller.mapStyle.value;
            final brightness = Theme.of(context).brightness;
            final applyDarkFilter = shouldApplyDarkMapFilter(style, brightness);
            final tileUrl = resolveFindMyTileUrl(style, brightness);
            final mapBg = resolveFindMyMapBackgroundColor(style, brightness);
            final attribution = applyDarkFilter ? FindMyMapStyle.dark : style;

            return FlutterMap(
              mapController: controller.mapController,
              options: MapOptions(
                initialZoom: 5.0,
                minZoom: 1.0,
                maxZoom: 18.0,
                backgroundColor: mapBg,
                initialCenter: controller.location.value == null
                    ? const LatLng(0, 0)
                    : LatLng(controller.location.value!.latitude, controller.location.value!.longitude),
                onTap: (_, _) {
                  controller.popupController.hideAllPopups();
                  controller.clearSelection();
                },
                keepAlive: true,
                interactionOptions: InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  forceOnlySinglePinchGesture: bugDetected,
                ),
                onMapReady: () {
                  if (!controller.completer.isCompleted) {
                    controller.completer.complete();
                  }
                },
              ),
              children: [
                TileLayer(
                  key: ValueKey('${style.name}-${brightness.name}'),
                  urlTemplate: tileUrl,
                  userAgentPackageName: 'com.bluebubbles.app',
                  tileBuilder: applyDarkFilter
                      ? (context, tileWidget, tile) => ColorFiltered(
                            colorFilter: findMyDarkNavyColorFilter,
                            child: tileWidget,
                          )
                      : null,
                ),
                CircleLayer(
                  circles: _buildSelectedAccuracyCircles(context),
                ),
                PopupMarkerLayer(
                  options: PopupMarkerLayerOptions(
                    popupController: controller.popupController,
                    markers: _orderedMarkers(),
                    markerTapBehavior: MarkerTapBehavior.custom(_handleMarkerTap),
                  ),
                ),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      attribution.attributionText,
                      onTap: () => launchUrl(Uri.parse(attribution.attributionUrl)),
                    ),
                  ],
                ),
              ],
            );
          }),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: 10 + desktopTop, left: 76, right: 76),
              child: Align(
                alignment: Alignment.topCenter,
                child: _buildStatusPill(context),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(top: 10 + desktopTop, right: 16),
                child: _FloatingMapControls(controller: controller),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildStatusPill(BuildContext context) {
    return Obx(() {
      controller.freshnessTick.value;
      final isRefreshing = controller.refreshing.value || controller.refreshing2.value;
      final feedback = controller.lastRefreshFeedback.value;
      final cs = context.theme.colorScheme;

      if (isRefreshing) {
        return _StatusPillContainer(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
              ),
              const SizedBox(width: 6),
              Text(
                'Refreshing...',
                textAlign: TextAlign.center,
                style: context.theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }

      if (feedback != null && feedback.isNotEmpty) {
        return _StatusPillContainer(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, size: 14, color: Color(0xFF16A34A)),
              const SizedBox(width: 6),
              Text(
                feedback,
                textAlign: TextAlign.center,
                style: context.theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }

      return const SizedBox.shrink();
    });
  }

  List<Marker> _orderedMarkers() {
    final all = controller.markers.values.toList();
    final selectedKey = controller.selectedFriendId.value != null
        ? 'friend-${controller.selectedFriendId.value}'
        : (controller.selectedDeviceId.value != null ? 'device-${controller.selectedDeviceId.value}' : null);
    if (selectedKey == null) return all;
    // Paint the selected pin last so its pill and badge stay above overlapping pins.
    all.sort((a, b) {
      final aSelected = a.key is ValueKey<String> && (a.key as ValueKey<String>).value == selectedKey;
      final bSelected = b.key is ValueKey<String> && (b.key as ValueKey<String>).value == selectedKey;
      if (aSelected == bSelected) return 0;
      return aSelected ? 1 : -1;
    });
    return all;
  }

  List<CircleMarker> _buildSelectedAccuracyCircles(BuildContext context) {
    if (shouldRedactFindMyContactInfo()) return const [];
    final primary = context.theme.colorScheme.primary;
    final circles = <CircleMarker>[];

    final userPos = controller.location.value;
    if (userPos != null && userPos.accuracy > 0) {
      circles.add(
        CircleMarker(
          point: LatLng(userPos.latitude, userPos.longitude),
          radius: userPos.accuracy,
          useRadiusInMeter: true,
          color: primary.withValues(alpha: 0.08),
          borderColor: primary.withValues(alpha: 0.25),
          borderStrokeWidth: 1,
        ),
      );
    }

    final friend = controller.selectedFriend;
    final friendAccuracy = friend?.horizontalAccuracy;
    if (friend != null &&
        (friend.latitude ?? 0) != 0 &&
        (friend.longitude ?? 0) != 0 &&
        friendAccuracy != null &&
        friendAccuracy > 0) {
      final key = friend.stableId ?? friend.title ?? 'friend';
      final center = controller.animatedPoints[key] ?? controller.markerPointForFriend(friend);
      circles.add(
        CircleMarker(
          point: center,
          radius: friendAccuracy,
          useRadiusInMeter: true,
          color: primary.withValues(alpha: 0.15),
          borderColor: primary.withValues(alpha: 0.5),
          borderStrokeWidth: 1.5,
        ),
      );
      return circles;
    }

    final device = controller.selectedDevice;
    final deviceAccuracy = device?.location?.horizontalAccuracy;
    if (device != null &&
        device.location?.latitude != null &&
        device.location?.longitude != null &&
        deviceAccuracy != null &&
        deviceAccuracy > 0) {
      final key = device.id ?? device.name ?? 'device';
      final center = controller.animatedPoints[key] ?? controller.markerPointForDevice(device);
      circles.add(
        CircleMarker(
          point: center,
          radius: deviceAccuracy,
          useRadiusInMeter: true,
          color: primary.withValues(alpha: 0.15),
          borderColor: primary.withValues(alpha: 0.5),
          borderStrokeWidth: 1.5,
        ),
      );
    }

    return circles;
  }
}

class _StatusPillContainer extends StatelessWidget {
  const _StatusPillContainer({
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.55),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _FloatingMapControls extends StatelessWidget {
  const _FloatingMapControls({required this.controller});

  final FindMyController controller;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    return ClipRRect(
      key: const ValueKey('findmy-map-controls'),
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: 44,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.38)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(() {
                final currentStyle = controller.mapStyle.value;
                return PopupMenuButton<String>(
                  key: const ValueKey('findmy-map-style'),
                  tooltip: 'Map Layers',
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'fit-all') {
                      controller.fitAllPins();
                      return;
                    }
                    final picked = FindMyMapStyle.values.firstWhereOrNull((s) => s.name == value);
                    if (picked != null) controller.setMapStyle(picked);
                  },
                  itemBuilder: (context) => [
                    ...FindMyMapStyle.values.map(
                      (style) => PopupMenuItem<String>(
                        value: style.name,
                        child: Row(
                          children: [
                            Icon(
                              style == currentStyle ? Icons.check : Icons.map_outlined,
                              size: 18,
                              color: style == currentStyle ? cs.primary : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Text(style.label),
                          ],
                        ),
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem<String>(
                      value: 'fit-all',
                      child: Row(
                        children: [
                          Icon(Icons.fit_screen_outlined, size: 18, color: cs.onSurfaceVariant),
                          const SizedBox(width: 10),
                          const Text('Fit All Pins'),
                        ],
                      ),
                    ),
                  ],
                  icon: Icon(Icons.map_outlined, size: 20, color: cs.onSurface),
                );
              }),
              Divider(
                height: 1,
                thickness: 0.8,
                indent: 10,
                endIndent: 10,
                color: cs.outlineVariant.withValues(alpha: 0.35),
              ),
              IconButton(
                key: const ValueKey('findmy-map-locate'),
                tooltip: 'Locate Me',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 42),
                onPressed: () => controller.recenterToUser(),
                icon: Icon(Icons.near_me_outlined, size: 20, color: cs.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/findmy/findmy_location_clipper.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_popup/flutter_map_marker_popup.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';
import 'package:universal_io/io.dart';

bool shouldSupersedeFriendLocation(FindMyFriend? existing, FindMyFriend incoming) {
  if (existing == null) return true;

  final existingTs = existing.lastUpdated;
  final incomingTs = incoming.lastUpdated;
  if (existingTs != null && incomingTs != null) {
    if (incomingTs.isAfter(existingTs)) return true;
    if (incomingTs.isBefore(existingTs)) return false;
  } else if (incomingTs != null && existingTs == null) {
    return true;
  } else if (existingTs != null && incomingTs == null) {
    return false;
  }

  if (incoming.locatingInProgress) return true;
  if (existing.status == null) return true;
  return LocationStatus.values.indexOf(existing.status!) <=
      LocationStatus.values.indexOf(incoming.status ?? LocationStatus.legacy);
}

bool shouldSupersedeDeviceLocation(FindMyDevice? existing, FindMyDevice incoming) {
  if (existing == null) return true;
  final existingTs = existing.location?.timeStamp;
  final incomingTs = incoming.location?.timeStamp;
  if (existingTs != null && incomingTs != null) {
    if (incomingTs > existingTs) return true;
    if (incomingTs < existingTs) return false;
  } else if (incomingTs != null && existingTs == null) {
    return true;
  } else if (existingTs != null && incomingTs == null) {
    return false;
  }
  return incoming.isLocatingInProgress || incomingTs == existingTs;
}

typedef FindMyFriendsRefreshFn = Future<Response> Function({
  String? handle,
  bool force,
  bool live,
  CancelToken? cancelToken,
});

typedef FindMyLiveStartFn = Future<Response> Function({
  required String handle,
  CancelToken? cancelToken,
});

typedef FindMyLiveStopFn = Future<Response> Function({
  String? handle,
  CancelToken? cancelToken,
});

typedef FindMyReverseGeocodeFn = Future<String?> Function(double latitude, double longitude);

@visibleForTesting
String formatNominatimAddress(Map<String, dynamic> data) {
  final addr = data['address'];
  if (addr is Map) {
    final house = addr['house_number']?.toString().trim() ?? '';
    final road = (addr['road'] ?? addr['pedestrian'] ?? addr['footway'] ?? addr['path'])?.toString().trim() ?? '';
    final street = [house, road].where((p) => p.isNotEmpty).join(' ');
    final city = (addr['city'] ??
            addr['town'] ??
            addr['village'] ??
            addr['hamlet'] ??
            addr['suburb'] ??
            addr['municipality'])
        ?.toString()
        .trim() ??
        '';
    final state = addr['state']?.toString().trim() ?? '';
    final formatted = [street, city, state].where((p) => p.isNotEmpty).join(', ');
    if (formatted.isNotEmpty) return formatted;
  }
  return data['display_name']?.toString().trim() ?? '';
}

class FindMyController extends GetxController {
  FindMyController({
    DateTime Function()? now,
    this.autoFetch = true,
    FindMyFriendsRefreshFn? refreshFriendsRequest,
    FindMyLiveStartFn? startLiveFriendRequest,
    FindMyLiveStopFn? stopLiveFriendRequest,
    FindMyReverseGeocodeFn? reverseGeocodeRequest,
    Duration? livePollInterval,
    Duration? liveFallbackInterval,
    Duration? liveKeepaliveInterval,
    Duration? geocodeMinInterval,
  })  : _now = now ?? DateTime.now,
        _refreshFriendsFn = refreshFriendsRequest,
        _startLiveFriendFn = startLiveFriendRequest,
        _stopLiveFriendFn = stopLiveFriendRequest,
        _reverseGeocodeFn = reverseGeocodeRequest,
        _livePollInterval = livePollInterval ?? const Duration(seconds: 5),
        _liveFallbackInterval = liveFallbackInterval ?? const Duration(seconds: 25),
        _liveKeepaliveInterval = liveKeepaliveInterval ?? const Duration(minutes: 3),
        _geocodeMinInterval = geocodeMinInterval ?? const Duration(seconds: 1);

  final DateTime Function() _now;
  final bool autoFetch;
  final FindMyFriendsRefreshFn? _refreshFriendsFn;
  final FindMyLiveStartFn? _startLiveFriendFn;
  final FindMyLiveStopFn? _stopLiveFriendFn;
  final FindMyReverseGeocodeFn? _reverseGeocodeFn;
  final Duration _livePollInterval;
  final Duration _liveFallbackInterval;
  final Duration _liveKeepaliveInterval;
  final Duration _geocodeMinInterval;

  DateTime get currentTime => _now();
  // Scroll Controllers
  final ScrollController devicesController = ScrollController();
  final ScrollController itemsController = ScrollController();
  final ScrollController friendsController = ScrollController();

  // Map & Panel Controllers
  final PopupController popupController = PopupController();
  final MapController mapController = MapController();
  final PanelController panelController = PanelController();
  final completer = Completer<void>();

  // Tab Controller (needs to be created with vsync in the widget)
  TabController? tabController;

  // Observable state variables
  final RxInt tabIndex = 0.obs;
  final RxList<FindMyDevice> devices = <FindMyDevice>[].obs;
  final RxList<FindMyFriend> friends = <FindMyFriend>[].obs;
  final RxList<FindMyFriend> friendsWithLocation = <FindMyFriend>[].obs;
  final RxList<FindMyFriend> friendsWithoutLocation = <FindMyFriend>[].obs;
  final RxMap<String, Marker> markers = <String, Marker>{}.obs;
  final RxMap<String, LatLng> animatedPoints = <String, LatLng>{}.obs;
  final Rxn<Position> location = Rxn<Position>();
  final Rxn<bool> fetching = Rxn<bool>(true);
  final RxBool refreshing = false.obs;
  final Rxn<bool> fetching2 = Rxn<bool>(true);
  final RxBool refreshing2 = false.obs;
  final RxBool canRefresh = true.obs;
  final RxBool hasMovedToCurrentLocation = false.obs;
  final RxnString selectedFriendId = RxnString();
  final RxnString selectedDeviceId = RxnString();
  final RxnString locatingFriendId = RxnString();
  final RxInt freshnessTick = 0.obs;
  final RxInt livePulseNonce = 0.obs;
  final Rx<FindMyMapStyle> mapStyle = FindMyMapStyle.standard.obs;
  final RxBool liveTrackingEnabled = true.obs;
  final RxnString lastRefreshFeedback = RxnString();

  /// Reverse-geocoded addresses for friends whose server payload carries none
  /// (the macOS 14.4+ decryption path can't persist address strings). Keyed by
  /// the friend's stable id; populated asynchronously by [resolveFriendAddress].
  final RxMap<String, String> friendAddresses = <String, String>{}.obs;

  /// ~100m location cells already attempted this controller lifetime, so the 30s
  /// poll doesn't re-hit the platform geocoder for the same spot.
  final Set<String> _geocodeAttempts = {};
  final Map<String, String> _webGeocodeCache = {};
  Future<void> _webGeocodeTail = Future.value();
  DateTime? _lastWebGeocodeAt;
  static final Dio _nominatimDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));

  bool _refreshFriendsInFlight = false;
  bool _refreshDevicesInFlight = false;
  bool _hardRefreshInFlight = false;
  DateTime? _lastHardRefreshAt;
  DateTime? _lastFriendsRefreshAt;
  DateTime? _lastDevicesRefreshAt;
  bool _isForeground = true;
  bool _forcedLiveForSelection = false;
  CancelToken? _friendRefreshCancelToken;
  int _friendRefreshSeq = 0;
  String? _selectedFriendTargetHandle;
  CancelToken? _liveStartCancelToken;
  int _liveStreamSeq = 0;
  String? _activeLiveStreamHandle;
  DateTime? _lastLiveStreamStartAt;
  DateTime? _lastLiveStreamUpdateAt;

  void Function(LatLng center, double zoom, {Offset offset})? _cameraAnimator;
  void Function(String key, LatLng from, LatLng to, void Function(LatLng) onStep)? _pinInterpolator;
  VoidCallback? onRequestDetailSheetOpen;
  VoidCallback? onRequestDetailSheetClose;
  double Function()? detailSheetOffsetProvider;

  StreamSubscription? locationSub;
  Timer? _hardRefreshDebounceTimer;
  Timer? _refreshFeedbackTimer;
  Timer? _stalenessTimer;
  Timer? _liveHeartbeatTimer;
  StreamSubscription? _redactedModeListener;
  StreamSubscription? _hideContactInfoListener;
  StreamSubscription? _findMyLocationListener;
  StreamSubscription? _findMyDeviceListener;

  @override
  void onInit() {
    super.onInit();
    if (autoFetch) {
      getLocations(refreshFriends: true, refreshDevices: true);

      // Listen via the event dispatcher rather than the socket itself — the socket is
      // torn down and rebuilt on every restart (backgrounding, a server URL refresh),
      // and a listener bound to the old instance would just stop receiving updates.
      if (GetIt.I.isRegistered<EventDispatcher>()) {
        _findMyLocationListener = EventDispatcherSvc.stream.listen((event) {
          if (event.type == 'new-findmy-location') {
            handleNewFindMyLocation(event.data);
          } else if (event.type == 'new-findmy-device') {
            handleNewFindMyDevice(event.data);
          }
        });
      }
    }

    _stalenessTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_isAlive) return;
      freshnessTick.value++;
    });
    _setupRedactionListeners();
  }

  bool get _isAlive => !isClosed;

  FindMyFriend? get selectedFriend {
    final id = selectedFriendId.value;
    if (id == null) return null;
    return friends.firstWhereOrNull((e) => e.stableId == id);
  }

  FindMyDevice? get selectedDevice {
    final id = selectedDeviceId.value;
    if (id == null) return null;
    return devices.firstWhereOrNull((e) => e.id == id);
  }

  void registerCameraAnimator(void Function(LatLng center, double zoom, {Offset offset})? animator) {
    _cameraAnimator = animator;
  }

  void registerPinInterpolator(
    void Function(String key, LatLng from, LatLng to, void Function(LatLng) onStep)? interpolator,
  ) {
    _pinInterpolator = interpolator;
  }

  void animateCameraTo(LatLng center, double zoom, {Offset offset = Offset.zero}) {
    if (_cameraAnimator != null) {
      _cameraAnimator!(center, zoom, offset: offset);
      return;
    }
    try {
      mapController.move(center, zoom, offset: offset);
    } catch (_) {
      // MapController may not be attached yet in tests or early mount.
    }
  }

  void setMapStyle(FindMyMapStyle style) {
    mapStyle.value = style;
  }

  String? _selectedFriendHandle() {
    final id = selectedFriendId.value;
    if (id == null) return null;
    final friend = friends.firstWhereOrNull((e) => e.stableId == id);
    return friend?.handle?.address ?? friend?.handleAddress;
  }

  bool get _canRefreshFriends => autoFetch || _refreshFriendsFn != null;
  bool get _canStartLiveFriend => autoFetch || _startLiveFriendFn != null;
  bool get _canStopLiveFriend => autoFetch || _stopLiveFriendFn != null;

  Future<Response> _performRefreshFriends({
    String? handle,
    bool force = false,
    bool live = false,
    CancelToken? cancelToken,
  }) {
    if (_refreshFriendsFn != null) {
      return _refreshFriendsFn(
        handle: handle,
        force: force,
        live: live,
        cancelToken: cancelToken,
      );
    }
    return HttpSvc.icloud.refreshFriends(
      handle: handle,
      force: force,
      live: live,
      cancelToken: cancelToken,
    );
  }

  Future<Response> _performStartLiveFriend({
    required String handle,
    CancelToken? cancelToken,
  }) {
    if (_startLiveFriendFn != null) {
      return _startLiveFriendFn(handle: handle, cancelToken: cancelToken);
    }
    return HttpSvc.icloud.startLiveFindMyFriend(handle, cancelToken: cancelToken);
  }

  Future<Response> _performStopLiveFriend({
    String? handle,
    CancelToken? cancelToken,
  }) {
    if (_stopLiveFriendFn != null) {
      return _stopLiveFriendFn(handle: handle, cancelToken: cancelToken);
    }
    return HttpSvc.icloud.stopLiveFindMyFriend(handle: handle, cancelToken: cancelToken);
  }

  Future<void> _startLiveFriendStream({
    required String? friendId,
    required String handle,
    bool showLocating = true,
  }) async {
    if (!_isAlive || !_canStartLiveFriend || handle.trim().isEmpty) return;
    final trimmed = handle.trim();
    final previousHandle = _activeLiveStreamHandle;
    if (previousHandle != null && previousHandle.toLowerCase() != trimmed.toLowerCase()) {
      unawaited(_stopLiveFriendStream(handle: previousHandle));
    }

    _liveStartCancelToken?.cancel('Superseded by newer live friend stream');
    final seq = ++_liveStreamSeq;
    final cancelToken = CancelToken();
    _liveStartCancelToken = cancelToken;
    _activeLiveStreamHandle = trimmed;
    final now = _now();
    _lastLiveStreamStartAt = now;
    if (showLocating || _lastLiveStreamUpdateAt == null) {
      _lastLiveStreamUpdateAt = now;
    }
    if (showLocating && friendId != null) {
      locatingFriendId.value = friendId;
    }

    try {
      final response = await _performStartLiveFriend(handle: trimmed, cancelToken: cancelToken);
      if (!_isAlive ||
          cancelToken.isCancelled ||
          seq != _liveStreamSeq ||
          (friendId != null && selectedFriendId.value != friendId)) {
        return;
      }

      final payload = response.data is Map ? response.data['data'] : null;
      final rawLocations = payload is Map ? payload['locations'] : (payload is List ? payload : null);
      if (rawLocations is List) {
        _applyFriendsList(rawLocations, targeted: true);
      }
      final updatedFriend = friendId != null ? friends.firstWhereOrNull((e) => e.stableId == friendId) : null;
      if (updatedFriend != null &&
          updatedFriend.status == LocationStatus.live &&
          !updatedFriend.locatingInProgress &&
          locatingFriendId.value == friendId) {
        locatingFriendId.value = null;
      }
    } on DioException catch (e, s) {
      if (CancelToken.isCancel(e) || cancelToken.isCancelled) return;
      if (_isAlive && seq == _liveStreamSeq) {
        _logWarn("Live friend start failed, falling back to targeted refresh", error: e, trace: s);
        if (_canRefreshFriends && selectedFriendId.value == friendId) {
          unawaited(_refreshTargetedFriend(
            friendId: friendId,
            handle: trimmed,
            showLocating: true,
            force: true,
          ));
        }
      }
    } catch (e, s) {
      if (cancelToken.isCancelled) return;
      if (_isAlive && seq == _liveStreamSeq) {
        _logWarn("Live friend start failed, falling back to targeted refresh", error: e, trace: s);
        if (_canRefreshFriends && selectedFriendId.value == friendId) {
          unawaited(_refreshTargetedFriend(
            friendId: friendId,
            handle: trimmed,
            showLocating: true,
            force: true,
          ));
        }
      }
    } finally {
      if (identical(_liveStartCancelToken, cancelToken)) {
        _liveStartCancelToken = null;
      }
    }
  }

  Future<void> _stopLiveFriendStream({String? handle}) async {
    _liveStreamSeq++;
    final token = _liveStartCancelToken;
    _liveStartCancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('Stopped live friend stream');
    }
    final targetHandle = handle ?? _activeLiveStreamHandle;
    if (handle == null ||
        _activeLiveStreamHandle == null ||
        _activeLiveStreamHandle!.toLowerCase() == handle.trim().toLowerCase()) {
      _activeLiveStreamHandle = null;
      _lastLiveStreamStartAt = null;
      _lastLiveStreamUpdateAt = null;
    }
    if (targetHandle == null || targetHandle.trim().isEmpty || !_canStopLiveFriend) return;
    try {
      await _performStopLiveFriend(handle: targetHandle.trim());
    } catch (_) {
      // Best-effort stop; server also enforces an idle auto-stop timeout.
    }
  }

  void _cancelPendingFriendRefresh() {
    _friendRefreshSeq++;
    final token = _friendRefreshCancelToken;
    _friendRefreshCancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('Superseded by newer FindMy friend selection or cancellation');
    }
    _refreshFriendsInFlight = false;
    locatingFriendId.value = null;
  }

  void selectFriend(FindMyFriend friend) {
    final targetId = friend.stableId;
    final targetHandle = friend.handle?.address ?? friend.handleAddress;
    final changed = selectedFriendId.value != targetId || selectedDeviceId.value != null;
    if (_activeLiveStreamHandle != null &&
        (targetHandle == null || _activeLiveStreamHandle!.toLowerCase() != targetHandle.trim().toLowerCase())) {
      unawaited(_stopLiveFriendStream(handle: _activeLiveStreamHandle));
    }
    selectedFriendId.value = targetId;
    selectedDeviceId.value = null;
    _selectedFriendTargetHandle = targetHandle;
    if (changed) {
      _forcedLiveForSelection = liveTrackingEnabled.value;
      _cancelPendingFriendRefresh();
    }
    _syncLiveHeartbeat();
    if (_canStartLiveFriend &&
        liveTrackingEnabled.value &&
        targetHandle != null &&
        targetHandle.trim().isNotEmpty) {
      if (changed ||
          _activeLiveStreamHandle?.toLowerCase() != targetHandle.trim().toLowerCase() ||
          locatingFriendId.value != targetId) {
        unawaited(_startLiveFriendStream(friendId: targetId, handle: targetHandle));
      }
      return;
    }
    if (_canRefreshFriends && (changed || locatingFriendId.value != targetId)) {
      unawaited(_refreshTargetedFriend(
        friendId: targetId,
        handle: targetHandle,
        showLocating: true,
        force: true,
      ));
    }
  }

  void selectDevice(FindMyDevice device) {
    final changed = selectedDeviceId.value != device.id || selectedFriendId.value != null;
    if (selectedFriendId.value != null || _activeLiveStreamHandle != null) {
      _cancelPendingFriendRefresh();
      _selectedFriendTargetHandle = null;
      unawaited(_stopLiveFriendStream());
    }
    selectedDeviceId.value = device.id;
    selectedFriendId.value = null;
    if (changed) _forcedLiveForSelection = false;
    _syncLiveHeartbeat();
    if (autoFetch) {
      refreshOnView(
        refreshFriends: false,
        refreshDevices: true,
        focusedDeviceId: device.id,
      );
    }
  }

  void _scrollToTop(ScrollController scrollController) {
    if (!scrollController.hasClients) return;
    for (final position in scrollController.positions) {
      if (position.pixels > 0) {
        position.jumpTo(0);
      }
    }
  }

  void focusFriend(FindMyFriend friend, {double? sheetOffsetPx, double minZoom = 14.5}) {
    selectFriend(friend);
    if (tabIndex.value != 0) {
      tabIndex.value = 0;
      tabController?.animateTo(0);
    }
    _scrollToTop(friendsController);
    onRequestDetailSheetOpen?.call();
    if ((friend.latitude ?? 0) != 0 && (friend.longitude ?? 0) != 0) {
      final key = friend.stableId ?? friend.title ?? 'friend';
      final pt = animatedPoints[key] ?? markerPointForFriend(friend);
      final targetZoom = _targetFocusZoom(minZoom);
      final offsetY = sheetOffsetPx ?? detailSheetOffsetProvider?.call() ?? 0;
      animateCameraTo(pt, targetZoom, offset: Offset(0, -offsetY));
    }
  }

  void focusDevice(FindMyDevice device, {double? sheetOffsetPx, double minZoom = 14.5}) {
    selectDevice(device);
    final targetTab = device.isConsideredAccessory ? 2 : 1;
    if (tabIndex.value != targetTab) {
      tabIndex.value = targetTab;
      tabController?.animateTo(targetTab);
    }
    _scrollToTop(device.isConsideredAccessory ? itemsController : devicesController);
    onRequestDetailSheetOpen?.call();
    if (device.location?.latitude != null && device.location?.longitude != null) {
      final key = device.id ?? device.name ?? 'device';
      final pt = animatedPoints[key] ?? markerPointForDevice(device);
      final targetZoom = _targetFocusZoom(minZoom);
      final offsetY = sheetOffsetPx ?? detailSheetOffsetProvider?.call() ?? 0;
      animateCameraTo(pt, targetZoom, offset: Offset(0, -offsetY));
    }
  }

  double _targetFocusZoom(double minZoom) {
    try {
      return math.max(mapController.camera.zoom, minZoom);
    } catch (_) {
      return minZoom;
    }
  }

  void clearSelection() {
    if (selectedFriendId.value == null &&
        selectedDeviceId.value == null &&
        locatingFriendId.value == null &&
        _activeLiveStreamHandle == null) {
      return;
    }
    selectedFriendId.value = null;
    selectedDeviceId.value = null;
    _selectedFriendTargetHandle = null;
    _forcedLiveForSelection = false;
    _cancelPendingFriendRefresh();
    unawaited(_stopLiveFriendStream());
    popupController.hideAllPopups();
    _syncLiveHeartbeat();
    onRequestDetailSheetClose?.call();
  }

  Future<void> recenterToUser({double zoom = 14.5}) async {
    final current = location.value;
    if (current != null) {
      animateCameraTo(LatLng(current.latitude, current.longitude), _targetFocusZoom(zoom));
      return;
    }
    if (!autoFetch || (Platform.isLinux && !kIsWeb)) return;
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (!_isAlive) return;
      if (perm == LocationPermission.whileInUse || perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition();
        if (!_isAlive) return;
        location.value = pos;
        buildLocationMarker(pos);
        animateCameraTo(LatLng(pos.latitude, pos.longitude), zoom);
      }
    } catch (e, s) {
      _logWarn("Failed to get current location for recenter", error: e, trace: s);
    }
  }

  void fitAllPins({EdgeInsets padding = const EdgeInsets.fromLTRB(48, 96, 48, 120)}) {
    final pts = <LatLng>[];
    for (final f in friendsWithLocation) {
      final key = f.stableId ?? f.title ?? 'friend';
      pts.add(animatedPoints[key] ?? markerPointForFriend(f));
    }
    for (final d in devices) {
      if (d.location?.latitude != null && d.location?.longitude != null) {
        final key = d.id ?? d.name ?? 'device';
        pts.add(animatedPoints[key] ?? markerPointForDevice(d));
      }
    }
    final loc = location.value;
    if (loc != null) {
      pts.add(LatLng(loc.latitude, loc.longitude));
    }
    final bounds = computeFindMyBounds(pts);
    if (bounds == null) return;
    if (pts.length == 1 ||
        (bounds.north == bounds.south && bounds.east == bounds.west)) {
      animateCameraTo(bounds.center, 14.0);
      return;
    }
    try {
      final fitted = CameraFit.bounds(
        bounds: bounds,
        padding: padding,
        maxZoom: 15.0,
      ).fit(mapController.camera);
      animateCameraTo(fitted.center, fitted.zoom);
    } catch (_) {
      animateCameraTo(bounds.center, 12.0);
    }
  }

  Future<void> toggleLiveTracking() async {
    final next = !liveTrackingEnabled.value;
    liveTrackingEnabled.value = next;
    _forcedLiveForSelection = next && (selectedFriendId.value != null || selectedDeviceId.value != null);
    if (!next) {
      unawaited(_stopLiveFriendStream());
    }
    _syncLiveHeartbeat();
    if (next) {
      final friendId = selectedFriendId.value;
      final handle = _selectedFriendHandle() ?? _selectedFriendTargetHandle;
      if (friendId != null && handle != null && handle.trim().isNotEmpty && _canStartLiveFriend) {
        await _startLiveFriendStream(friendId: friendId, handle: handle);
        return;
      }
      await refreshSelected();
    }
  }

  Future<void> refreshSelected() async {
    final friendId = selectedFriendId.value;
    if (friendId != null && selectedDeviceId.value == null && _canRefreshFriends) {
      await _refreshTargetedFriend(
        friendId: friendId,
        handle: _selectedFriendHandle() ?? _selectedFriendTargetHandle,
        showLocating: true,
        force: true,
      );
      return;
    }
    await hardRefresh(
      focusedHandle: _selectedFriendHandle(),
      focusedDeviceId: selectedDeviceId.value,
    );
  }

  void _setRefreshFeedback(String message) {
    lastRefreshFeedback.value = message;
    _refreshFeedbackTimer?.cancel();
    _refreshFeedbackTimer = Timer(const Duration(seconds: 3), () {
      if (_isAlive) lastRefreshFeedback.value = null;
    });
  }

  void onTabChanged(int index) {
    if (index != 0 && selectedFriendId.value != null) {
      clearSelection();
    } else if (index == 0 && selectedDeviceId.value != null) {
      clearSelection();
    } else if ((index == 1 || index == 2) && selectedDeviceId.value != null) {
      final selected = selectedDevice;
      final belongsToTab = selected != null &&
          (index == 2 ? selected.isConsideredAccessory : !selected.isConsideredAccessory);
      if (!belongsToTab) {
        clearSelection();
      }
    }
    if (!autoFetch) return;
    if (index == 0) {
      refreshOnView(refreshFriends: true, refreshDevices: false);
    } else if (index == 1 || index == 2) {
      refreshOnView(refreshFriends: false, refreshDevices: true);
    }
  }

  double? distanceMetersTo(double? lat, double? lng) {
    final userPos = location.value;
    if (userPos == null || lat == null || lng == null || (lat == 0 && lng == 0)) return null;
    return distanceMetersBetween(LatLng(userPos.latitude, userPos.longitude), LatLng(lat, lng));
  }

  String proximityLabelForFriend(FindMyFriend friend) {
    if (shouldRedactFindMyContactInfo()) return "";
    return formatFindMyProximity(distanceMetersTo(friend.latitude, friend.longitude));
  }

  String proximityLabelForDevice(FindMyDevice device) {
    if (shouldRedactFindMyContactInfo()) return "";
    return formatFindMyProximity(
      distanceMetersTo(device.location?.latitude, device.location?.longitude),
      deviceWithYou: device.deviceWithYou ?? false,
      isThisDevice: device.thisDevice ?? false,
    );
  }

  String etaLabelForFriend(FindMyFriend friend) {
    if (shouldRedactFindMyContactInfo()) return "";
    return formatFindMyEta(distanceMetersTo(friend.latitude, friend.longitude));
  }

  void onAppPaused() {
    _isForeground = false;
    _liveHeartbeatTimer?.cancel();
    _liveHeartbeatTimer = null;
    if (_activeLiveStreamHandle != null) {
      unawaited(_stopLiveFriendStream());
    }
  }

  void onAppResumed() {
    _isForeground = true;
    final friendId = selectedFriendId.value;
    final handle = _selectedFriendHandle() ?? _selectedFriendTargetHandle;
    if (friendId != null &&
        handle != null &&
        handle.trim().isNotEmpty &&
        liveTrackingEnabled.value &&
        _canStartLiveFriend) {
      unawaited(_startLiveFriendStream(friendId: friendId, handle: handle));
    }
    _syncLiveHeartbeat();
    if (autoFetch) {
      refreshOnView(
        refreshFriends: true,
        refreshDevices: true,
        focusedHandle: _selectedFriendHandle(),
        focusedDeviceId: selectedDeviceId.value,
      );
    }
  }

  Future<void> _refreshTargetedFriend({
    required String? friendId,
    required String? handle,
    bool showLocating = false,
    bool force = true,
  }) async {
    if (!_isAlive || !_canRefreshFriends) return;
    if (showLocating) {
      _cancelPendingFriendRefresh();
    } else if (_refreshFriendsInFlight) {
      return;
    }

    final seq = ++_friendRefreshSeq;
    final cancelToken = CancelToken();
    _friendRefreshCancelToken = cancelToken;
    _refreshFriendsInFlight = true;
    if (showLocating && friendId != null) {
      locatingFriendId.value = friendId;
    }

    try {
      final response = await _performRefreshFriends(
        handle: handle,
        force: force,
        live: liveTrackingEnabled.value,
        cancelToken: cancelToken,
      );
      if (!_isAlive ||
          cancelToken.isCancelled ||
          seq != _friendRefreshSeq ||
          (friendId != null && selectedFriendId.value != friendId)) {
        return;
      }
      _lastFriendsRefreshAt = _now();
      _applyRefreshedFriendsResponse(response, targeted: true);
    } on DioException catch (e, s) {
      if (CancelToken.isCancel(e) || cancelToken.isCancelled) return;
      if (_isAlive && seq == _friendRefreshSeq) {
        _logWarn("Live friend refresh failed", error: e, trace: s);
      }
    } catch (e, s) {
      if (cancelToken.isCancelled) return;
      if (_isAlive && seq == _friendRefreshSeq) {
        _logWarn("Live friend refresh failed", error: e, trace: s);
      }
    } finally {
      if (seq == _friendRefreshSeq) {
        _refreshFriendsInFlight = false;
        if (identical(_friendRefreshCancelToken, cancelToken)) {
          _friendRefreshCancelToken = null;
        }
        if (locatingFriendId.value == friendId || selectedFriendId.value != friendId) {
          locatingFriendId.value = null;
        }
      }
    }
  }

  void _applyRefreshedFriendsResponse(Response response, {bool targeted = false}) {
    if (response.statusCode != 200 || response.data == null || response.data['data'] == null) {
      fetching2.value = false;
      refreshing2.value = false;
      return;
    }
    final rawData = response.data['data'];
    if (rawData is! List) {
      fetching2.value = false;
      refreshing2.value = false;
      return;
    }
    _applyFriendsList(rawData, targeted: targeted);
  }

  void _applyFriendsList(List<dynamic> rawData, {bool targeted = false}) {
    try {
      final incomingList = rawData.map((e) => FindMyFriend.fromJson(e)).toList().cast<FindMyFriend>();
      var anyUpdated = false;
      if (!targeted) {
        friends.value = incomingList;
        anyUpdated = true;
      } else {
        for (final incoming in incomingList) {
          final existingIndex = incoming.stableId == null
              ? -1
              : friends.indexWhere((e) => e.stableId == incoming.stableId);
          final existing = existingIndex == -1 ? null : friends[existingIndex];
          if (existingIndex == -1) {
            friends.add(incoming);
            anyUpdated = true;
          } else if (shouldSupersedeFriendLocation(existing, incoming)) {
            friends[existingIndex] = incoming;
            anyUpdated = true;
          }
        }
      }

      if (anyUpdated) {
        friendsWithLocation.value =
            friends.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0).toList();
        friendsWithoutLocation.value =
            friends.where((item) => (item.latitude ?? 0) == 0 && (item.longitude ?? 0) == 0).toList();

        final toBuild = targeted
            ? incomingList.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0)
            : friendsWithLocation;
        for (final e in toBuild) {
          buildFriendMarker(e);
          unawaited(resolveFriendAddress(e));
        }
        livePulseNonce.value++;
      }
      fetching2.value = false;
      refreshing2.value = false;
      _syncLiveHeartbeat();
    } catch (e, s) {
      _logWarn("Failed to parse FindMy Friends location data!", error: e, trace: s);
      fetching2.value = null;
      refreshing2.value = false;
    }
  }

  void _syncLiveHeartbeat() {
    _liveHeartbeatTimer?.cancel();
    _liveHeartbeatTimer = null;
    if (!_isAlive || !_isForeground || !liveTrackingEnabled.value) return;

    final friendId = selectedFriendId.value;
    if (friendId != null) {
      if (!_canRefreshFriends && !_canStartLiveFriend) return;
      final friend = friends.firstWhereOrNull((e) => e.stableId == friendId);
      final handle = friend?.handle?.address ?? friend?.handleAddress ?? _selectedFriendTargetHandle;
      if (friend == null && handle == null) return;
      if (_canStartLiveFriend) {
        // True live mode streams pushed `new-findmy-location` events from FindMy.app;
        // renew the server's 5-minute idle timer periodically while actively viewing, and
        // only fall back to a gentle refresh if the stream stays silent past _liveFallbackInterval.
        final tickInterval = _liveKeepaliveInterval < _liveFallbackInterval
            ? _liveKeepaliveInterval
            : _liveFallbackInterval;
        _liveHeartbeatTimer = Timer.periodic(tickInterval, (_) {
          if (!_isAlive || !_isForeground || !liveTrackingEnabled.value) return;
          if (selectedFriendId.value != friendId) return;
          final currentTime = _now();
          final lastStart = _lastLiveStreamStartAt;
          if (handle != null &&
              handle.trim().isNotEmpty &&
              (lastStart == null || currentTime.difference(lastStart) >= _liveKeepaliveInterval)) {
            unawaited(_startLiveFriendStream(
              friendId: friendId,
              handle: handle,
              showLocating: false,
            ));
          }
          if (!_canRefreshFriends) return;
          final lastUpdate = _lastLiveStreamUpdateAt;
          if (lastUpdate != null && currentTime.difference(lastUpdate) < _liveFallbackInterval) return;
          unawaited(_refreshTargetedFriend(
            friendId: friendId,
            handle: handle,
            showLocating: false,
            force: true,
          ));
        });
        return;
      }
      _liveHeartbeatTimer = Timer.periodic(_livePollInterval, (_) {
        if (!_isAlive || !_isForeground || !liveTrackingEnabled.value) return;
        if (selectedFriendId.value != friendId) return;
        unawaited(_refreshTargetedFriend(
          friendId: friendId,
          handle: handle,
          showLocating: false,
          force: true,
        ));
      });
      return;
    }

    if (!autoFetch) return;
    final deviceId = selectedDeviceId.value;
    if (deviceId != null) {
      final device = devices.firstWhereOrNull((e) => e.id == deviceId);
      final inLiveMode = device != null &&
          (_forcedLiveForSelection || device.isLiveFresh(_now()) || device.isLocatingInProgress);
      if (!inLiveMode) return;
      _liveHeartbeatTimer = Timer.periodic(const Duration(seconds: 18), (_) async {
        if (!_isAlive || !_isForeground || _refreshDevicesInFlight) return;
        _refreshDevicesInFlight = true;
        try {
          await HttpSvc.icloud.refreshDevices(deviceId: deviceId, force: true);
          _lastDevicesRefreshAt = _now();
        } catch (e, s) {
          _logWarn("Live heartbeat device refresh failed", error: e, trace: s);
        } finally {
          _refreshDevicesInFlight = false;
        }
      });
    }
  }

  Future<void> hardRefresh({String? focusedHandle, String? focusedDeviceId}) async {
    if (!_isAlive || _hardRefreshInFlight) return;
    final now = _now();
    if (_lastHardRefreshAt != null && now.difference(_lastHardRefreshAt!) < const Duration(seconds: 3)) {
      return;
    }

    _hardRefreshInFlight = true;
    _lastHardRefreshAt = now;
    canRefresh.value = false;
    refreshing.value = true;
    refreshing2.value = true;

    try {
      await getLocations(
        refreshFriends: true,
        refreshDevices: true,
        force: true,
        focusedHandle: focusedHandle ?? _selectedFriendHandle(),
        focusedDeviceId: focusedDeviceId ?? selectedDeviceId.value,
      );
      if (_isAlive) {
        livePulseNonce.value++;
        _setRefreshFeedback("Updated just now");
      }
    } finally {
      _hardRefreshInFlight = false;
      if (_isAlive) {
        refreshing.value = false;
        refreshing2.value = false;
        _hardRefreshDebounceTimer?.cancel();
        _hardRefreshDebounceTimer = Timer(const Duration(seconds: 3), () {
          if (_isAlive) canRefresh.value = true;
        });
      }
    }
  }

  Future<void> refreshOnView({
    bool refreshFriends = true,
    bool refreshDevices = true,
    String? focusedHandle,
    String? focusedDeviceId,
  }) async {
    if (!_isAlive) return;
    final now = _now();
    final doFriends = refreshFriends &&
        !_refreshFriendsInFlight &&
        (_lastFriendsRefreshAt == null || now.difference(_lastFriendsRefreshAt!) >= const Duration(seconds: 10));
    final doDevices = refreshDevices &&
        !_refreshDevicesInFlight &&
        (_lastDevicesRefreshAt == null || now.difference(_lastDevicesRefreshAt!) >= const Duration(seconds: 10));
    if (!doFriends && !doDevices) return;

    await getLocations(
      refreshFriends: doFriends,
      refreshDevices: doDevices,
      skipFetchWhenNotRefreshing: true,
      focusedHandle: focusedHandle,
      focusedDeviceId: focusedDeviceId,
    );
  }

  void _setupRedactionListeners() {
    _redactedModeListener?.cancel();
    _hideContactInfoListener?.cancel();
    if (!GetIt.I.isRegistered<SettingsService>()) return;
    _redactedModeListener = SettingsSvc.settings.redactedMode.listen((_) => _rebuildAllMarkers());
    _hideContactInfoListener = SettingsSvc.settings.hideContactInfo.listen((_) => _rebuildAllMarkers());
  }

  void _rebuildAllMarkers() {
    if (!_isAlive) return;
    for (final friend in friendsWithLocation) {
      buildFriendMarker(friend, animate: false);
    }
    for (final device in devices.where((e) => e.location?.latitude != null && e.location?.longitude != null)) {
      buildDeviceMarker(device, animate: false);
    }
    markers.refresh();
  }

  LatLng markerPointForFriend(FindMyFriend friend) => resolveFindMyMarkerPoint(
        stableKey: friend.stableId ?? friend.title ?? 'friend',
        latitude: friend.latitude!,
        longitude: friend.longitude!,
      );

  String _addressKeyForFriend(FindMyFriend friend) =>
      friend.stableId ?? friend.title ?? '${friend.latitude},${friend.longitude}';

  /// The friend's display address: the payload's own address when present, otherwise
  /// a reverse-geocoded one once [resolveFriendAddress] has populated it.
  String? addressForFriend(FindMyFriend friend, {bool preferLong = false}) {
    final own = preferLong
        ? friend.longAddress ?? friend.shortAddress
        : friend.shortAddress ?? friend.longAddress;
    return own ?? friendAddresses[_addressKeyForFriend(friend)];
  }

  /// Reverse-geocodes a friend's coordinates when the server sent no address.
  /// Best-effort: unsupported platforms and geocoder failures leave the map empty.
  Future<void> resolveFriendAddress(FindMyFriend friend) async {
    if (friend.shortAddress != null || friend.longAddress != null) return;
    if (shouldRedactFindMyContactInfo()) return;
    final lat = friend.latitude;
    final lng = friend.longitude;
    if (lat == null || lng == null || (lat == 0 && lng == 0)) return;

    final key = _addressKeyForFriend(friend);
    if (friendAddresses.containsKey(key)) return;

    if (kIsWeb || _reverseGeocodeFn != null) {
      await _resolveFriendAddressWeb(friend, key, lat, lng);
      return;
    }

    // The geocoding plugin implements Android/iOS/macOS only.
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return;
    if (!_geocodeAttempts.add('${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}')) return;

    try {
      final geocoding = Geocoding();
      if (!await geocoding.isPresent()) return;
      final placemarks = await geocoding.placemarkFromCoordinates(lat, lng);
      if (!_isAlive || placemarks.isEmpty) return;
      final address = formatPlacemarkAddress(placemarks.first);
      if (address.isNotEmpty) friendAddresses[key] = address;
    } catch (e, s) {
      _logWarn("Failed to reverse-geocode Find My friend location", error: e, trace: s);
    }
  }

  Future<void> _resolveFriendAddressWeb(FindMyFriend friend, String key, double lat, double lng) async {
    final cell = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    final cached = _webGeocodeCache[cell];
    if (cached != null) {
      friendAddresses[key] = cached;
      return;
    }
    if (!_geocodeAttempts.add(cell)) {
      await _webGeocodeTail;
      final hit = _webGeocodeCache[cell];
      if (_isAlive && hit != null) friendAddresses[key] = hit;
      return;
    }

    // shortcut: OSM Nominatim reverse-geocode (~1 req/s, 4-decimal RAM cache); upgrade to server geocoder if rate-limited.
    final next = _webGeocodeTail.then((_) async {
      if (!_isAlive) return;
      final hit = _webGeocodeCache[cell];
      if (hit != null) {
        friendAddresses[key] = hit;
        return;
      }
      if (_lastWebGeocodeAt != null && _geocodeMinInterval > Duration.zero) {
        final elapsed = _now().difference(_lastWebGeocodeAt!);
        if (elapsed < _geocodeMinInterval) {
          await Future.delayed(_geocodeMinInterval - elapsed);
        }
      }
      if (!_isAlive) return;
      _lastWebGeocodeAt = _now();
      try {
        final String? address;
        if (_reverseGeocodeFn != null) {
          address = await _reverseGeocodeFn(lat, lng);
        } else {
          final response = await _nominatimDio.get<Map<String, dynamic>>(
            'https://nominatim.openstreetmap.org/reverse',
            queryParameters: {
              'format': 'jsonv2',
              'lat': lat.toStringAsFixed(6),
              'lon': lng.toStringAsFixed(6),
              'zoom': '18',
              'addressdetails': '1',
            },
          );
          final data = response.data;
          address = data != null ? formatNominatimAddress(data) : null;
        }
        if (_isAlive && address != null && address.trim().isNotEmpty) {
          final clean = address.trim();
          _webGeocodeCache[cell] = clean;
          friendAddresses[key] = clean;
        }
      } catch (e, s) {
        _logWarn("Failed to reverse-geocode Find My friend location", error: e, trace: s);
      }
    });
    _webGeocodeTail = next.catchError((_) {});
    await next;
  }

  LatLng markerPointForDevice(FindMyDevice device) => resolveFindMyMarkerPoint(
        stableKey: device.id ?? device.name ?? 'device',
        latitude: device.location!.latitude!,
        longitude: device.location!.longitude!,
      );

  void _logInfo(String message) {
    if (GetIt.I.isRegistered<BaseLogger>()) {
      Logger.info(message);
    }
  }

  void _logWarn(String message, {Object? error, StackTrace? trace}) {
    if (GetIt.I.isRegistered<BaseLogger>()) {
      Logger.warn(message, error: error, trace: trace, tag: 'FindMyController');
    }
  }

  void handleNewFindMyLocation(dynamic data) {
    if (!_isAlive || data == null) return;
    try {
      final friend = data is FindMyFriend ? data : FindMyFriend.fromJson(data);
      _logInfo("Received new location for ${friend.handle?.address}");
      if ((friend.latitude ?? 0) == 0 && (friend.longitude ?? 0) == 0) return;

      final existingFriendIndex = friends.indexWhere((e) => e.stableId != null && e.stableId == friend.stableId);
      final existingFriend = existingFriendIndex == -1 ? null : friends[existingFriendIndex];

      if (shouldSupersedeFriendLocation(existingFriend, friend)) {
        _logInfo("Updating map for ${friend.stableId}");
        if (existingFriendIndex == -1) {
          friends.add(friend);
        } else {
          friends[existingFriendIndex] = friend;
        }

        friendsWithLocation.value =
            friends.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0).toList();
        friendsWithoutLocation.value =
            friends.where((item) => (item.latitude ?? 0) == 0 && (item.longitude ?? 0) == 0).toList();

        buildFriendMarker(friend);
        livePulseNonce.value++;
        unawaited(resolveFriendAddress(friend));
        if (selectedFriendId.value != null && selectedFriendId.value == friend.stableId) {
          _lastLiveStreamUpdateAt = _now();
          if (!friend.locatingInProgress && locatingFriendId.value == friend.stableId) {
            locatingFriendId.value = null;
          }
          _syncLiveHeartbeat();
        }
      }
    } catch (e, s) {
      _logWarn("Failed to fetch FindMy locations", error: e, trace: s);
    }
  }

  void handleNewFindMyDevice(dynamic data) {
    if (!_isAlive || data == null) return;
    try {
      final items = data is List ? data : [data];
      var anyUpdated = false;
      for (final raw in items) {
        final FindMyDevice device;
        if (raw is FindMyDevice) {
          device = raw;
        } else if (raw is Map<String, dynamic>) {
          device = FindMyDevice.fromJson(raw);
        } else {
          continue;
        }
        if (device.safeLocations.isNotEmpty && device.safeLocations.first.name != null) {
          device.address?.label = device.safeLocations.first.name;
        }

        final existingIndex = devices.indexWhere((e) => e.id != null && e.id == device.id);
        final existing = existingIndex == -1 ? null : devices[existingIndex];
        if (!shouldSupersedeDeviceLocation(existing, device)) continue;

        anyUpdated = true;
        if (existingIndex == -1) {
          devices.add(device);
        } else {
          devices[existingIndex] = device;
        }
        if (device.location?.latitude != null && device.location?.longitude != null) {
          buildDeviceMarker(device);
        }
        if (selectedDeviceId.value != null && selectedDeviceId.value == device.id) {
          _syncLiveHeartbeat();
        }
      }
      if (anyUpdated) {
        livePulseNonce.value++;
      }
    } catch (e, s) {
      _logWarn("Failed to handle FindMy device update", error: e, trace: s);
    }
  }

  /// Fetches the FindMy data from the server.
  Future<void> getLocations({
    bool refreshFriends = true,
    bool refreshDevices = true,
    bool force = false,
    bool skipFetchWhenNotRefreshing = false,
    String? focusedHandle,
    String? focusedDeviceId,
  }) async {
    if (!_isAlive) return;

    if (!(Platform.isLinux && !kIsWeb) && locationSub == null && location.value == null) {
      LocationPermission granted = await Geolocator.checkPermission();
      if (!_isAlive) return;
      if (granted == LocationPermission.denied) {
        granted = await Geolocator.requestPermission();
        if (!_isAlive) return;
      }

      if (granted == LocationPermission.whileInUse || granted == LocationPermission.always) {
        Geolocator.getCurrentPosition().then((loc) {
          if (!_isAlive) return;
          location.value = loc;
          buildLocationMarker(location.value!);
          if (!kIsDesktop) {
            locationSub = Geolocator.getPositionStream().listen((event) {
              if (!_isAlive) return;
              buildLocationMarker(event);

              if (!hasMovedToCurrentLocation.value) {
                mapController.move(LatLng(event.latitude, event.longitude), 10);
                hasMovedToCurrentLocation.value = true;
              }
            });
          }
        });
      }
    }

    // Fetch friends data
    if (refreshFriends || !skipFetchWhenNotRefreshing) {
      if (refreshFriends) _refreshFriendsInFlight = true;
      final friendSeq = _friendRefreshSeq;
      Response response2;
      try {
        response2 = refreshFriends
            ? await _performRefreshFriends(
                handle: focusedHandle,
                force: force,
                live: focusedHandle != null && liveTrackingEnabled.value,
              ).catchError((_) async {
                if (!_isAlive) return Response(requestOptions: RequestOptions(path: ''));
                refreshing2.value = false;
                showSnackbar("Error", "Something went wrong refreshing FindMy Friends data!", type: SnackbarType.error);
                return Response(requestOptions: RequestOptions(path: ''));
              })
            : await HttpSvc.icloud.getFriends().catchError((_) async {
                if (!_isAlive) return Response(requestOptions: RequestOptions(path: ''));
                fetching2.value = null;
                return Response(requestOptions: RequestOptions(path: ''));
              });
      } finally {
        if (refreshFriends && friendSeq == _friendRefreshSeq) {
          _refreshFriendsInFlight = false;
          _lastFriendsRefreshAt = _now();
        }
      }
      if (!_isAlive) return;

      _applyRefreshedFriendsResponse(
        response2,
        targeted: focusedHandle != null || friendSeq != _friendRefreshSeq,
      );
    }

    // Fetch devices data
    if (refreshDevices || !skipFetchWhenNotRefreshing) {
      if (refreshDevices) _refreshDevicesInFlight = true;
      Response response;
      try {
        response = refreshDevices
            ? await HttpSvc.icloud.refreshDevices(deviceId: focusedDeviceId, force: force).catchError((_) async {
                if (!_isAlive) return Response(requestOptions: RequestOptions(path: ''));
                refreshing.value = false;
                showSnackbar("Error", "Something went wrong refreshing FindMy Devices data!", type: SnackbarType.error);
                return Response(requestOptions: RequestOptions(path: ''));
              })
            : await HttpSvc.icloud.getDevices().catchError((_) async {
                if (!_isAlive) return Response(requestOptions: RequestOptions(path: ''));
                fetching.value = null;
                return Response(requestOptions: RequestOptions(path: ''));
              });
      } finally {
        if (refreshDevices) {
          _refreshDevicesInFlight = false;
          _lastDevicesRefreshAt = _now();
        }
      }
      if (!_isAlive) return;

      if (response.statusCode == 200 && response.data['data'] != null) {
        try {
          devices.value =
              (response.data['data'] as List).map((e) => FindMyDevice.fromJson(e)).toList().cast<FindMyDevice>();

          // Apply safe location name as the display label once, here rather than during build.
          for (final device in devices) {
            if (device.safeLocations.isNotEmpty && device.safeLocations.first.name != null) {
              device.address?.label = device.safeLocations.first.name;
            }
          }

          for (FindMyDevice e in devices.where((e) => e.location?.latitude != null && e.location?.longitude != null)) {
            buildDeviceMarker(e);
          }
          fetching.value = false;
          refreshing.value = false;
          _syncLiveHeartbeat();
        } catch (e, s) {
          _logWarn("Failed to parse FindMy Devices location data!", error: e, trace: s);
          fetching.value = null;
          refreshing.value = false;
          return;
        }
      } else {
        fetching.value = false;
        refreshing.value = false;
      }
    }
  }

  void _setOrAnimateMarkerPoint({
    required String markerKey,
    required ValueKey<String> widgetKey,
    required LatLng targetPoint,
    required Widget child,
    required bool animate,
  }) {
    final prevPoint = animatedPoints[markerKey];
    if (prevPoint == null ||
        !animate ||
        _pinInterpolator == null ||
        (prevPoint.latitude == targetPoint.latitude && prevPoint.longitude == targetPoint.longitude)) {
      animatedPoints[markerKey] = targetPoint;
      markers[markerKey] = Marker(
        key: widgetKey,
        point: targetPoint,
        width: 116,
        height: 92,
        alignment: Alignment.center,
        child: child,
      );
      return;
    }

    _pinInterpolator!(markerKey, prevPoint, targetPoint, (stepPoint) {
      if (!_isAlive) return;
      animatedPoints[markerKey] = stepPoint;
      markers[markerKey] = Marker(
        key: widgetKey,
        point: stepPoint,
        width: 116,
        height: 92,
        alignment: Alignment.center,
        child: child,
      );
    });
  }

  void buildDeviceMarker(FindMyDevice e, {bool animate = true}) {
    final markerKey = e.id ?? randomString(6);
    final targetPoint = markerPointForDevice(e);
    final child = FindMyDeviceMarker(
      key: ValueKey('device-widget-$markerKey'),
      controller: this,
      device: e,
    );
    _setOrAnimateMarkerPoint(
      markerKey: markerKey,
      widgetKey: ValueKey('device-$markerKey'),
      targetPoint: targetPoint,
      child: child,
      animate: animate,
    );
  }

  void buildFriendMarker(FindMyFriend friend, {bool animate = true}) {
    final markerKey = friend.stableId ?? randomString(6);
    final targetPoint = markerPointForFriend(friend);
    final child = FindMyFriendMarker(
      key: ValueKey('friend-widget-$markerKey'),
      controller: this,
      friend: friend,
      avatarHandle: friend.handle ??
          Handle(
            address: friend.handleAddress ?? friend.title ?? "Unknown",
            formattedAddress: friend.handleAddress != null ? formatPhoneNumber(friend.handleAddress!) : null,
          ),
    );
    _setOrAnimateMarkerPoint(
      markerKey: markerKey,
      widgetKey: ValueKey('friend-$markerKey'),
      targetPoint: targetPoint,
      child: child,
      animate: animate,
    );
  }

  void buildLocationMarker(Position pos) {
    markers['current'] = Marker(
      key: const ValueKey('current'),
      point: LatLng(pos.latitude, pos.longitude),
      width: 28,
      height: 56,
      alignment: Alignment.center,
      child: Builder(
        builder: (context) {
          final primary = context.theme.colorScheme.primary;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (pos.heading.isFinite)
                Transform.rotate(
                  angle: pos.heading,
                  child: ClipPath(
                    clipper: const FindMyLocationClipper(),
                    child: Container(
                      width: 26,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.center,
                          end: Alignment.topCenter,
                          colors: [
                            primary,
                            primary.withAlpha(50),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 6,
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(4.5),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: primary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void onClose() {
    _cancelPendingFriendRefresh();
    unawaited(_stopLiveFriendStream());
    _hardRefreshDebounceTimer?.cancel();
    _refreshFeedbackTimer?.cancel();
    _stalenessTimer?.cancel();
    _liveHeartbeatTimer?.cancel();
    _liveHeartbeatTimer = null;
    _redactedModeListener?.cancel();
    _hideContactInfoListener?.cancel();
    _findMyLocationListener?.cancel();
    _findMyDeviceListener?.cancel();
    locationSub?.cancel();
    mapController.dispose();
    popupController.dispose();
    tabController?.dispose();
    itemsController.dispose();
    devicesController.dispose();
    friendsController.dispose();
    super.onClose();
  }
}

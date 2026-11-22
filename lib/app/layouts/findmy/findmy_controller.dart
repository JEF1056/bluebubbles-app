import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as maplibre;
import 'package:sliding_up_panel2/sliding_up_panel2.dart';
import 'package:universal_io/io.dart';

int _compareOptionalTimestamps(int? existingMs, int? incomingMs) {
  if (existingMs != null && incomingMs != null) return incomingMs.compareTo(existingMs);
  if (incomingMs != null) return 1;
  if (existingMs != null) return -1;
  return 0;
}

bool shouldSupersedeFriendLocation(FindMyFriend? existing, FindMyFriend incoming) {
  if (existing == null) return true;
  final cmp = _compareOptionalTimestamps(
    existing.lastUpdated?.millisecondsSinceEpoch,
    incoming.lastUpdated?.millisecondsSinceEpoch,
  );
  if (cmp != 0) return cmp > 0;
  if (incoming.locatingInProgress || existing.status == null) return true;
  return LocationStatus.values.indexOf(existing.status!) <=
      LocationStatus.values.indexOf(incoming.status ?? LocationStatus.legacy);
}

bool shouldSupersedeDeviceLocation(FindMyDevice? existing, FindMyDevice incoming) {
  if (existing == null) return true;
  final cmp = _compareOptionalTimestamps(existing.location?.timeStamp, incoming.location?.timeStamp);
  if (cmp != 0) return cmp > 0;
  return incoming.isLocatingInProgress || incoming.location?.timeStamp == existing.location?.timeStamp;
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
typedef FindMyPrefReadListFn = List<String>? Function(String key);
typedef FindMyPrefWriteListFn = Future<void> Function(String key, List<String> values);
typedef FindMyPinnedChatHandlesFn = Iterable<String> Function();

const String kFindMyPinnedFriendsPrefKey = 'findmy_pinned_friends';
const String kFindMyUnpinnedFriendsPrefKey = 'findmy_unpinned_friends';
const String kFindMyMapStylePrefKey = 'findmy_map_style';
const String kFindMy3DEnabledPrefKey = 'findmy_3d_tilt_enabled';

/// Normalizes a phone number or email handle for reliable matching across
/// Find My friends, 1:1 chats, and persisted pin state.
String normalizeFindMyHandle(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  if (trimmed.contains('@')) return trimmed.toLowerCase();
  return trimmed.replaceAll(RegExp(r'[^0-9]'), '');
}

bool findMyHandlesMatch(String? a, String? b) {
  final na = normalizeFindMyHandle(a);
  final nb = normalizeFindMyHandle(b);
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;
  if (!na.contains('@') && !nb.contains('@') && na.length >= 10 && nb.length >= 10) {
    return na.substring(na.length - 10) == nb.substring(nb.length - 10);
  }
  return false;
}

bool _friendHasValidCoords(FindMyFriend f) =>
    f.latitude != null &&
    f.longitude != null &&
    f.latitude!.isFinite &&
    f.longitude!.isFinite &&
    !(f.latitude == 0 && f.longitude == 0);

ContactV2? _lookupContactForFindMyFriend(
  FindMyFriend friend, {
  ContactV2? Function(String address)? contactLookup,
}) {
  final linked = friend.handle?.contactsV2.firstOrNull;
  if (linked != null) return linked;
  final addr = friend.handleAddress ?? friend.handle?.address;
  if (addr == null || addr.trim().isEmpty) return null;
  if (contactLookup != null) return contactLookup(addr);
  if (GetIt.I.isRegistered<ContactServiceV2>()) {
    try {
      return ContactsSvcV2.findContactForAddressSync(addr);
    } catch (_) {}
  }
  return null;
}

bool _contactContainsAddress(ContactV2 contact, String address) =>
    contact.addresses.any((entry) => findMyHandlesMatch(entry, address));

bool _contactsRepresentSamePerson(ContactV2? a, ContactV2? b, String? addrA, String? addrB) {
  if (a != null && b != null) {
    if (identical(a, b)) return true;
    final idA = a.nativeContactId.trim();
    final idB = b.nativeContactId.trim();
    if (idA.isNotEmpty && idB.isNotEmpty && idA == idB) return true;
    if (a.id != 0 && a.id == b.id) return true;
  }
  if (a != null && addrB != null && addrB.trim().isNotEmpty && _contactContainsAddress(a, addrB)) return true;
  if (b != null && addrA != null && addrA.trim().isNotEmpty && _contactContainsAddress(b, addrA)) return true;
  return false;
}

bool _isEmailAddress(String? addr) => addr != null && addr.contains('@');

String _displayNameForDedup(FindMyFriend friend, ContactV2? contact) {
  if (contact != null) {
    final cName = contact.displayName.isNotEmpty ? contact.displayName : contact.computedDisplayName;
    if (cName.trim().isNotEmpty) return cName.trim();
  }
  return friend.resolveDisplayName(hideContactInfo: false).trim();
}

bool _isResolvedContactName(FindMyFriend friend, ContactV2? contact) {
  final name = _displayNameForDedup(friend, contact);
  if (name.isEmpty || name == 'Unknown Friend' || name.contains('@')) return false;
  if (contact != null) return true;
  final addr = friend.handleAddress ?? friend.handle?.address ?? '';
  if (addr.isNotEmpty && normalizeFindMyHandle(name) == normalizeFindMyHandle(addr)) return false;
  return friend.handle != null && friend.handle!.contactsV2.isNotEmpty;
}

int _friendIdentityScore(FindMyFriend friend, ContactV2? contact) {
  var score = 0;
  if (_isResolvedContactName(friend, contact)) score += 4;
  final addr = friend.handleAddress ?? friend.handle?.address;
  if (!_isEmailAddress(addr)) score += 2;
  if (friend.handle != null) score += 1;
  return score;
}

bool _sameAppleIdLocationAlias(
  FindMyFriend a,
  ContactV2? contactA,
  FindMyFriend b,
  ContactV2? contactB,
) {
  if (!_friendHasValidCoords(a) || !_friendHasValidCoords(b)) return false;
  // Require one unresolved raw email and one resolved contact to avoid merging distinct people nearby.
  final addrA = a.handleAddress ?? a.handle?.address;
  final addrB = b.handleAddress ?? b.handle?.address;
  final aUnresolvedEmail = _isEmailAddress(addrA) && !_isResolvedContactName(a, contactA);
  final bUnresolvedEmail = _isEmailAddress(addrB) && !_isResolvedContactName(b, contactB);
  final aResolved = _isResolvedContactName(a, contactA);
  final bResolved = _isResolvedContactName(b, contactB);
  if (!((aUnresolvedEmail && bResolved) || (bUnresolvedEmail && aResolved))) return false;

  if ((a.latitude! - b.latitude!).abs() > 1e-5 || (a.longitude! - b.longitude!).abs() > 1e-5) {
    return false;
  }
  final tsA = a.lastUpdated?.millisecondsSinceEpoch;
  final tsB = b.lastUpdated?.millisecondsSinceEpoch;
  if (tsA == null || tsB == null) return false;
  return (tsA - tsB).abs() <= 5000;
}

FindMyFriend _mergeDuplicateFriends(
  FindMyFriend a,
  ContactV2? contactA,
  FindMyFriend b,
  ContactV2? contactB,
) {
  final scoreA = _friendIdentityScore(a, contactA);
  final scoreB = _friendIdentityScore(b, contactB);
  final identity = scoreB > scoreA ? b : a;
  final otherIdentity = identical(identity, a) ? b : a;

  final aHasCoords = _friendHasValidCoords(a);
  final bHasCoords = _friendHasValidCoords(b);
  final FindMyFriend loc;
  final FindMyFriend fallbackLoc;
  if (aHasCoords && !bHasCoords) {
    loc = a;
    fallbackLoc = b;
  } else if (bHasCoords && !aHasCoords) {
    loc = b;
    fallbackLoc = a;
  } else if (shouldSupersedeFriendLocation(a, b)) {
    loc = b;
    fallbackLoc = a;
  } else {
    loc = a;
    fallbackLoc = b;
  }

  return FindMyFriend(
    latitude: loc.latitude,
    longitude: loc.longitude,
    longAddress: loc.longAddress ?? fallbackLoc.longAddress,
    shortAddress: loc.shortAddress ?? fallbackLoc.shortAddress,
    title: identity.title ?? otherIdentity.title,
    subtitle: loc.subtitle ?? fallbackLoc.subtitle,
    handle: identity.handle ?? otherIdentity.handle,
    handleAddress: identity.handleAddress ?? otherIdentity.handleAddress,
    lastUpdated: loc.lastUpdated ?? fallbackLoc.lastUpdated,
    status: loc.status ?? fallbackLoc.status,
    locatingInProgress: loc.locatingInProgress,
    isLive: loc.isLive ?? fallbackLoc.isLive,
    horizontalAccuracy: loc.horizontalAccuracy ?? fallbackLoc.horizontalAccuracy,
    verticalAccuracy: loc.verticalAccuracy ?? fallbackLoc.verticalAccuracy,
    speed: loc.speed ?? fallbackLoc.speed,
    altitude: loc.altitude ?? fallbackLoc.altitude,
    isOld: loc.isOld,
    isInaccurate: loc.isInaccurate,
    locationFinished: loc.locationFinished ?? fallbackLoc.locationFinished,
  );
}

/// Deduplicates Find My friends that represent the same person (matching handle,
/// shared contact card, or an unresolved email alias sharing identical GPS fix).
/// Prefers the resolved non-email contact entry while preserving the freshest location.
List<FindMyFriend> deduplicateFindMyFriends(
  Iterable<FindMyFriend> friends, {
  ContactV2? Function(String address)? contactLookup,
  Map<String, String>? aliasToPrimaryIdOut,
  Set<String>? droppedStableIdsOut,
}) {
  final result = <FindMyFriend>[];
  final contacts = <ContactV2?>[];

  for (final incoming in friends) {
    final incomingContact = _lookupContactForFindMyFriend(incoming, contactLookup: contactLookup);
    final incomingAddr = incoming.handleAddress ?? incoming.handle?.address;

    int matchIndex = -1;
    for (int i = 0; i < result.length; i++) {
      final existing = result[i];
      final existingContact = contacts[i];
      final existingAddr = existing.handleAddress ?? existing.handle?.address;
      final sameHandle = (existing.stableId != null && existing.stableId == incoming.stableId) ||
          findMyHandlesMatch(existingAddr, incomingAddr);
      final sameContact = _contactsRepresentSamePerson(existingContact, incomingContact, existingAddr, incomingAddr);
      final sameLocationAlias = _sameAppleIdLocationAlias(existing, existingContact, incoming, incomingContact);
      if (sameHandle || sameContact || sameLocationAlias) {
        matchIndex = i;
        break;
      }
    }

    if (matchIndex == -1) {
      result.add(incoming);
      contacts.add(incomingContact);
    } else {
      final existing = result[matchIndex];
      final existingContact = contacts[matchIndex];
      final merged = _mergeDuplicateFriends(existing, existingContact, incoming, incomingContact);
      final mergedContact = _lookupContactForFindMyFriend(merged, contactLookup: contactLookup) ??
          existingContact ??
          incomingContact;
      result[matchIndex] = merged;
      contacts[matchIndex] = mergedContact;

      final primaryId = merged.stableId;
      if (primaryId != null && primaryId.isNotEmpty) {
        for (final candidate in [existing, incoming]) {
          final cid = candidate.stableId;
          if (cid != null && cid != primaryId) {
            droppedStableIdsOut?.add(cid);
          }
          final normAddr = normalizeFindMyHandle(candidate.handleAddress ?? candidate.handle?.address);
          if (normAddr.isNotEmpty) {
            aliasToPrimaryIdOut?[normAddr] = primaryId;
          }
        }
      }
    }
  }

  return result;
}

/// Great-circle Haversine distance in meters between two WGS84 coordinates.
double haversineDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final rLat1 = lat1 * math.pi / 180.0;
  final rLat2 = lat2 * math.pi / 180.0;
  final sinHalfLat = math.sin(dLat / 2);
  final sinHalfLon = math.sin(dLon / 2);
  final a = sinHalfLat * sinHalfLat + math.cos(rLat1) * math.cos(rLat2) * sinHalfLon * sinHalfLon;
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
  return earthRadiusMeters * c;
}

/// Formats friend distance from user's real device coordinates.
/// Returns `Nearby` ONLY when <= [kFindMyNearbyMeters], otherwise formatted miles
/// (e.g. `<0.1 mi`, `1.4 mi`), or `""` when distance is unknown.
String formatFindMyFriendDistance(double? meters) {
  if (meters == null || !meters.isFinite || meters < 0) return "";
  if (meters <= kFindMyNearbyMeters) return "Nearby";
  return formatFindMyMiles(meters);
}

final RegExp _streetKeywordRegex = RegExp(
  r'\b(st|street|ave|avenue|rd|road|blvd|boulevard|dr|drive|ln|lane|way|ct|court|pl|place|pkwy|parkway|cir|circle|ter|terrace|hwy|highway|sq|square|aly|alley|trl|trail)\b',
  caseSensitive: false,
);

/// Returns true when [address] appears to include a street line rather than
/// only a city/state (e.g. `"Berkeley, CA"`).
bool hasStreetAddressLine(String? address) {
  final trimmed = address?.trim() ?? '';
  if (trimmed.isEmpty) return false;
  if (RegExp(r'\d').hasMatch(trimmed)) return true;
  if (_streetKeywordRegex.hasMatch(trimmed)) return true;
  final parts = trimmed.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).length;
  return parts >= 3;
}

bool _hasValidFriendCoords(double? lat, double? lng) =>
    lat != null && lng != null && lat.isFinite && lng.isFinite && !(lat == 0 && lng == 0);

/// Stable sort putting pinned friends first, and within each group sorting by
/// ascending Haversine distance from [userLatitude]/[userLongitude] when
/// available (friends with missing coords fall back after those with coords).
List<FindMyFriend> sortFindMyFriends(
  Iterable<FindMyFriend> friends,
  bool Function(FindMyFriend) isPinned, {
  double? userLatitude,
  double? userLongitude,
}) {
  final hasUserCoords = _hasValidFriendCoords(userLatitude, userLongitude);
  var index = 0;
  final entries = [
    for (final f in friends)
      (
        index++,
        f,
        isPinned(f) ? 0 : 1,
        hasUserCoords && _hasValidFriendCoords(f.latitude, f.longitude)
            ? haversineDistanceMeters(userLatitude!, userLongitude!, f.latitude!, f.longitude!)
            : double.infinity,
      ),
  ]..sort((a, b) {
      final pinCmp = a.$3.compareTo(b.$3);
      if (pinCmp != 0) return pinCmp;
      final distCmp = a.$4.compareTo(b.$4);
      return distCmp != 0 ? distCmp : a.$1.compareTo(b.$1);
    });
  return [for (final e in entries) e.$2];
}

class FindMyChatLocation {
  const FindMyChatLocation({
    required this.friend,
    required this.shortLabel,
    required this.fullAddress,
    required this.freshness,
    required this.isLive,
    required this.latitude,
    required this.longitude,
    this.distanceLabel,
  });

  final FindMyFriend friend;
  final String shortLabel;
  final String fullAddress;
  final String freshness;
  final bool isLive;
  final double latitude;
  final double longitude;
  final String? distanceLabel;
}

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

class FindMyController extends GetxController with WidgetsBindingObserver {
  FindMyController({
    DateTime Function()? now,
    this.autoFetch = true,
    FindMyFriendsRefreshFn? refreshFriendsRequest,
    Future<Response> Function({String? deviceId, bool force})? refreshDevicesRequest,
    FindMyLiveStartFn? startLiveFriendRequest,
    FindMyLiveStopFn? stopLiveFriendRequest,
    FindMyReverseGeocodeFn? reverseGeocodeRequest,
    Future<Position?> Function()? fetchCurrentPosition,
    Stream<Position> Function()? positionStream,
    Duration? livePollInterval,
    Duration? liveFallbackInterval,
    Duration? liveKeepaliveInterval,
    Duration? geocodeMinInterval,
    FindMyPrefReadListFn? readPrefList,
    FindMyPrefWriteListFn? writePrefList,
    FindMyPinnedChatHandlesFn? pinnedChatHandlesProvider,
  })  : _now = now ?? DateTime.now,
        _refreshFriendsFn = refreshFriendsRequest,
        _refreshDevicesFn = refreshDevicesRequest,
        _startLiveFriendFn = startLiveFriendRequest,
        _stopLiveFriendFn = stopLiveFriendRequest,
        _reverseGeocodeFn = reverseGeocodeRequest,
        _fetchCurrentPositionFn = fetchCurrentPosition,
        _positionStreamFn = positionStream,
        _livePollInterval = livePollInterval ?? const Duration(seconds: 5),
        _liveFallbackInterval = liveFallbackInterval ?? const Duration(seconds: 25),
        _liveKeepaliveInterval = liveKeepaliveInterval ?? const Duration(seconds: 45),
        _geocodeMinInterval = geocodeMinInterval ?? const Duration(seconds: 1),
        _readPrefListFn = readPrefList,
        _writePrefListFn = writePrefList,
        _pinnedChatHandlesProvider = pinnedChatHandlesProvider;

  static FindMyController ensure() {
    if (Get.isRegistered<FindMyController>()) {
      return Get.find<FindMyController>();
    }
    // Keep shared background controller permanent so popping a chat route never disposes live Find My state.
    return Get.put(FindMyController(autoFetch: false)..isBackgroundShared = true, permanent: true);
  }

  final DateTime Function() _now;
  final bool autoFetch;
  bool isBackgroundShared = false;
  final FindMyFriendsRefreshFn? _refreshFriendsFn;
  final Future<Response> Function({String? deviceId, bool force})? _refreshDevicesFn;
  final FindMyLiveStartFn? _startLiveFriendFn;
  final FindMyLiveStopFn? _stopLiveFriendFn;
  final FindMyReverseGeocodeFn? _reverseGeocodeFn;
  final Future<Position?> Function()? _fetchCurrentPositionFn;
  final Stream<Position> Function()? _positionStreamFn;
  final Duration _livePollInterval;
  final Duration _liveFallbackInterval;
  final Duration _liveKeepaliveInterval;
  final Duration _geocodeMinInterval;
  final FindMyPrefReadListFn? _readPrefListFn;
  final FindMyPrefWriteListFn? _writePrefListFn;
  final FindMyPinnedChatHandlesFn? _pinnedChatHandlesProvider;

  DateTime get currentTime => _now();
  // Scroll Controllers
  final ScrollController devicesController = ScrollController();
  final ScrollController itemsController = ScrollController();
  final ScrollController friendsController = ScrollController();

  // Map & Panel Controllers
  maplibre.MapController? mapLibreController;
  maplibre.StyleController? mapStyleController;
  final PanelController panelController = PanelController();
  final DraggableScrollableController sheetController = DraggableScrollableController();
  ScrollController? activeSheetScrollController;
  Completer<void> completer = Completer<void>();

  static const double default3DPitch = 32.0;
  static const double pitch3DSyncThreshold = 12.0;
  static const double minZoomFor3DPitch = 14.0;
  static const double defaultInitialZoom = 16.0;
  static const double defaultFocusZoom = 16.2;

  // Tab Controller (needs to be created with vsync in the widget)
  TabController? tabController;

  // Observable state variables
  final RxInt tabIndex = 0.obs;
  final RxList<FindMyDevice> devices = <FindMyDevice>[].obs;
  final RxList<FindMyFriend> friends = <FindMyFriend>[].obs;
  final RxList<FindMyFriend> friendsWithLocation = <FindMyFriend>[].obs;
  final RxList<FindMyFriend> friendsWithoutLocation = <FindMyFriend>[].obs;
  final RxMap<String, maplibre.Marker> markers = <String, maplibre.Marker>{}.obs;
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
  final RxnString ringingDeviceId = RxnString();
  final RxBool ringBusy = false.obs;
  final RxnString selectedRingComponent = RxnString();
  Timer? _ringAutoClearTimer;
  FindMyBleService bleService = FindMyBleService.instance;
  Future<Response> Function(String deviceId, {bool stop, String? component})? cloudRingOverride;
  final RxnString locatingFriendId = RxnString();
  final RxInt freshnessTick = 0.obs;
  final RxInt livePulseNonce = 0.obs;
  final Rx<FindMyMapStyle> mapStyle = FindMyMapStyle.standard.obs;
  final RxBool is3DEnabled = true.obs;
  final RxDouble cameraPitch = default3DPitch.obs;
  final RxDouble cameraBearing = 0.0.obs;
  final RxDouble cameraZoom = defaultInitialZoom.obs;
  final Rx<LatLng> cameraCenter = const LatLng(37.7749, -122.4194).obs;
  final RxnString hoveredMarkerKey = RxnString();
  EdgeInsets cameraPadding = EdgeInsets.zero;
  Size mapViewportSize = const Size(390, 844);
  final RxBool liveTrackingEnabled = true.obs;
  final RxnString lastRefreshFeedback = RxnString();
  final RxSet<String> _explicitlyPinnedKeys = <String>{}.obs;
  final RxSet<String> _explicitlyUnpinnedKeys = <String>{}.obs;
  final RxInt pinVersion = 0.obs;
  String? _pendingFocusFriendId;
  bool _pageActivated = false;
  bool get _interactive => autoFetch || _pageActivated;

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
  bool _fetchingUserLocation = false;
  bool _hasAutoFittedInitialPins = false;
  bool _waitingMapReadyForAutoFit = false;
  bool _hasUserInteractedWithMap = false;
  LatLng? _lastFollowedTargetPoint;
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
  void Function(
    LatLng center,
    double zoom, {
    Offset offset,
    double? pitch,
    double? bearing,
    EdgeInsets? padding,
    bool fly,
  })? _camera3DAnimator;
  void Function(String key, LatLng from, LatLng to, void Function(LatLng) onStep)? _pinInterpolator;
  VoidCallback? onRequestDetailSheetOpen;
  double Function()? detailSheetOffsetProvider;
  EdgeInsets Function()? fitAllPinsPaddingProvider;

  StreamSubscription? locationSub;
  Timer? _hardRefreshDebounceTimer;
  Timer? _refreshFeedbackTimer;
  Timer? _stalenessTimer;
  Timer? _liveHeartbeatTimer;
  bool _observingLifecycle = false;
  StreamSubscription? _redactedModeListener;
  StreamSubscription? _hideContactInfoListener;
  StreamSubscription? _findMyLocationListener;
  StreamSubscription? _contactsCacheListener;
  final Map<String, String> _friendAliasToPrimaryId = <String, String>{};

  @override
  void onInit() {
    super.onInit();
    try {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      _isForeground = lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    } catch (_) {
      // Pure Dart unit tests without TestWidgetsFlutterBinding don't initialize WidgetsBinding.
    }
    _loadPinPrefs();
    _loadMapPrefs();
    if (autoFetch) {
      activatePage();
    }

    _startStalenessTimer();
    _setupRedactionListeners();
  }

  bool get _isAppForegroundForTimer => _isForeground;

  void _startStalenessTimer() {
    if (_stalenessTimer != null || !_isAlive || !_isAppForegroundForTimer) return;
    _stalenessTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_isAlive || !_isAppForegroundForTimer) {
        _stopStalenessTimer();
        return;
      }
      freshnessTick.value++;
    });
  }

  void _stopStalenessTimer() {
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
  }

  /// Starts full Find My page data fetching & live socket listeners (idempotent).
  void activatePage() {
    if (_pageActivated) {
      _startStalenessTimer();
      _scheduleInitialAutoFitIfNeeded();
      refreshOnView(refreshFriends: tabIndex.value == 0, refreshDevices: tabIndex.value != 0);
      return;
    }
    _pageActivated = true;
    _startStalenessTimer();
    _scheduleInitialAutoFitIfNeeded();
    getLocations(refreshFriends: true, refreshDevices: true);

    // Listen via the event dispatcher rather than the socket itself — the socket is
    // torn down and rebuilt on every restart (backgrounding, a server URL refresh),
    // and a listener bound to the old instance would just stop receiving updates.
    if (GetIt.I.isRegistered<EventDispatcher>()) {
      _findMyLocationListener ??= EventDispatcherSvc.stream.listen((event) {
        if (event.type == 'new-findmy-location') {
          handleNewFindMyLocation(event.data);
        } else if (event.type == 'new-findmy-device') {
          handleNewFindMyDevice(event.data);
        }
      });
    }
  }

  /// Stops page-only continuous GPS streaming and resets page-scoped map state.
  void deactivatePage() {
    _pageActivated = false;
    if (!isBackgroundShared) {
      _stopStalenessTimer();
    }
    _waitingMapReadyForAutoFit = false;
    _hasAutoFittedInitialPins = false;
    _hasUserInteractedWithMap = false;
    _lastFollowedTargetPoint = null;
    hasMovedToCurrentLocation.value = false;
    locationSub?.cancel();
    locationSub = null;
    if (completer.isCompleted) {
      completer = Completer<void>();
    }
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

  void registerCamera3DAnimator(
    void Function(
      LatLng center,
      double zoom, {
      Offset offset,
      double? pitch,
      double? bearing,
      EdgeInsets? padding,
      bool fly,
    })? animator,
  ) {
    _camera3DAnimator = animator;
  }

  void registerPinInterpolator(
    void Function(String key, LatLng from, LatLng to, void Function(LatLng) onStep)? interpolator,
  ) {
    _pinInterpolator = interpolator;
  }

  static EdgeInsets _offsetToPadding(Offset offset) => EdgeInsets.fromLTRB(
        offset.dx > 0 ? offset.dx * 2.0 : 0.0,
        offset.dy > 0 ? offset.dy * 2.0 : 0.0,
        offset.dx < 0 ? -offset.dx * 2.0 : 0.0,
        offset.dy < 0 ? -offset.dy * 2.0 : 0.0,
      );

  static double _normalizeBearing(double degrees) => ((degrees % 360.0) + 360.0) % 360.0;

  void animateCameraTo(
    LatLng center,
    double zoom, {
    Offset offset = Offset.zero,
    double? pitch,
    double? bearing,
    EdgeInsets? padding,
    bool fly = false,
  }) {
    final effectivePadding = padding ?? _offsetToPadding(offset);
    final effectivePitch = (pitch ?? cameraPitch.value).clamp(0.0, 60.0);
    final effectiveBearing = _normalizeBearing(bearing ?? cameraBearing.value);
    final clampedZoom = zoom.clamp(1.0, 19.0);

    cameraCenter.value = center;
    cameraZoom.value = clampedZoom;
    cameraPitch.value = effectivePitch;
    cameraBearing.value = effectiveBearing;
    cameraPadding = effectivePadding;

    if (_cameraAnimator != null) {
      _cameraAnimator!(center, clampedZoom, offset: offset);
    }
    if (_camera3DAnimator != null) {
      _camera3DAnimator!(
        center,
        clampedZoom,
        offset: offset,
        pitch: effectivePitch,
        bearing: effectiveBearing,
        padding: effectivePadding,
        fly: fly,
      );
      return;
    }
    if (_cameraAnimator != null) return;

    final mlController = mapLibreController;
    if (mlController == null) return;
    try {
      final update = maplibre.CameraUpdate.position(
        center: toGeographic(center),
        zoom: clampedZoom,
        pitch: effectivePitch,
        bearing: effectiveBearing,
        padding: effectivePadding,
      );
      final animation = fly
          ? const maplibre.CameraAnimation.fly(duration: Duration(milliseconds: 780), curve: Curves.easeOutCubic)
          : const maplibre.CameraAnimation.ease(duration: Duration(milliseconds: 480), curve: Curves.easeOutCubic);
      unawaited(mlController.animateCamera(update, animation: animation));
    } catch (_) {
      // MapController may not be attached yet in tests or early mount.
    }
  }

  void flyToCamera(
    LatLng center,
    double zoom, {
    Offset offset = Offset.zero,
    double? pitch,
    double? bearing,
    EdgeInsets? padding,
  }) {
    final targetPitch = pitch ??
        (is3DEnabled.value && zoom >= minZoomFor3DPitch ? default3DPitch : cameraPitch.value);
    animateCameraTo(
      center,
      zoom,
      offset: offset,
      pitch: targetPitch,
      bearing: bearing,
      padding: padding,
      fly: true,
    );
  }

  void toggle3D({bool? enabled}) {
    final next = enabled ?? !is3DEnabled.value;
    if (is3DEnabled.value == next && (next ? cameraPitch.value >= pitch3DSyncThreshold : cameraPitch.value == 0.0)) {
      return;
    }
    is3DEnabled.value = next;
    _writePrefBool(kFindMy3DEnabledPrefKey, next);
    sync3DBuildingsLayer();
    animateCameraTo(
      cameraCenter.value,
      cameraZoom.value,
      pitch: next ? default3DPitch : 0.0,
      bearing: cameraBearing.value,
      padding: cameraPadding,
    );
  }

  void resetNorth() {
    animateCameraTo(
      cameraCenter.value,
      cameraZoom.value,
      pitch: cameraPitch.value,
      bearing: 0.0,
      padding: cameraPadding,
    );
  }

  void zoomBy(double delta) {
    final nextZoom = (cameraZoom.value + delta).clamp(1.0, 19.0);
    animateCameraTo(
      cameraCenter.value,
      nextZoom,
      pitch: cameraPitch.value,
      bearing: cameraBearing.value,
      padding: cameraPadding,
    );
  }

  void onMapCameraChanged({
    required LatLng center,
    required double zoom,
    required double pitch,
    required double bearing,
    maplibre.CameraChangeReason? reason,
  }) {
    cameraCenter.value = center;
    cameraZoom.value = zoom;
    cameraPitch.value = pitch.clamp(0.0, 60.0);
    cameraBearing.value = _normalizeBearing(bearing);
    if (reason == maplibre.CameraChangeReason.gesture) {
      _hasUserInteractedWithMap = true;
      if (cameraPitch.value >= pitch3DSyncThreshold && !is3DEnabled.value) {
        is3DEnabled.value = true;
        _writePrefBool(kFindMy3DEnabledPrefKey, true);
        sync3DBuildingsLayer();
      } else if (cameraPitch.value < 5.0 && is3DEnabled.value) {
        is3DEnabled.value = false;
        _writePrefBool(kFindMy3DEnabledPrefKey, false);
        sync3DBuildingsLayer();
      }
    }
  }

  void sync3DBuildingsLayer({Brightness brightness = Brightness.light}) {
    final styleCtrl = mapStyleController;
    if (styleCtrl == null) return;
    try {
      bool hasExtrusion = false;
      final layerDescriptors = <({String id, String type, String? sourceLayer})>[];
      for (final layer in styleCtrl.layers) {
        final String? sourceLayer = switch (layer) {
          maplibre.FillStyleLayer(:final sourceLayerId) => sourceLayerId,
          maplibre.LineStyleLayer(:final sourceLayerId) => sourceLayerId,
          maplibre.SymbolStyleLayer(:final sourceLayerId) => sourceLayerId,
          maplibre.FillExtrusionStyleLayer(:final sourceLayerId) => sourceLayerId,
          _ => null,
        };
        layerDescriptors.add((id: layer.id, type: layer.type, sourceLayer: sourceLayer));

        if (layer is maplibre.FillStyleLayer &&
            isFindMyBuildingFillLayer(id: layer.id, type: layer.type, sourceLayer: sourceLayer) &&
            layer.maxZoom > 14.0) {
          layer.maxZoom = 14.0;
        }

        if (layer is maplibre.FillExtrusionStyleLayer) {
          hasExtrusion = true;
          // Keep 3D building extrusions visible in both 2D and 3D modes.
          layer.visible = true;
          if (layer.id == findMy3DBuildingsLayerId) {
            layer.color = buildFindMy3DExtrusionColorExpression(mapStyle.value, brightness);
            layer.opacity = maplibre.Expression.literal(
              resolveFindMyBuildingExtrusionOpacity(mapStyle.value, brightness),
            );
          }
        }
      }
      if (!hasExtrusion && styleCtrl.sources['openmaptiles'] != null) {
        final anchorLayerId = resolveFindMy3DAnchorLayerId(layerDescriptors);
        final buildingLayer = maplibre.FillExtrusionStyleLayer(
          id: findMy3DBuildingsLayerId,
          sourceId: 'openmaptiles',
          sourceLayerId: 'building',
          minZoom: 14.0,
          visible: true,
          filter: const maplibre.Expression<bool>.raw(['!', ['has', 'hide_3d']]),
          color: buildFindMy3DExtrusionColorExpression(mapStyle.value, brightness),
          opacity: maplibre.Expression.literal(
            resolveFindMyBuildingExtrusionOpacity(mapStyle.value, brightness),
          ),
          height: const maplibre.Expression<num>.raw([
            'interpolate',
            ['linear'],
            ['zoom'],
            14,
            0,
            14.3,
            ['coalesce', ['get', 'render_height'], 0],
          ]),
          base: const maplibre.Expression<num>.raw([
            'interpolate',
            ['linear'],
            ['zoom'],
            14,
            0,
            14.3,
            ['coalesce', ['get', 'render_min_height'], 0],
          ]),
          verticalGradient: const maplibre.Expression.literal(true),
        );
        unawaited(styleCtrl.layers.add(buildingLayer, belowLayerId: anchorLayerId));
      }
    } catch (_) {
      // Style may be detached during rapid style switches or disposal.
    }
  }

  void setMapStyle(FindMyMapStyle style) {
    mapStyle.value = style;
    _writePrefString(kFindMyMapStylePrefKey, style.name);
  }

  String? _selectedFriendHandle() {
    final id = selectedFriendId.value;
    if (id == null) return null;
    final friend = friends.firstWhereOrNull((e) => e.stableId == id);
    return friend?.handle?.address ?? friend?.handleAddress;
  }

  bool get _canRefreshFriends => _interactive || _refreshFriendsFn != null;
  bool get _canStartLiveFriend => _interactive || _startLiveFriendFn != null;
  bool get _canStopLiveFriend => _interactive || _stopLiveFriendFn != null;

  Future<Response> _performRefreshFriends({
    String? handle,
    bool force = false,
    bool live = false,
    CancelToken? cancelToken,
  }) =>
      (_refreshFriendsFn ?? HttpSvc.icloud.refreshFriends)(
        handle: handle,
        force: force,
        live: live,
        cancelToken: cancelToken,
      );

  Future<Response> _performStartLiveFriend({required String handle, CancelToken? cancelToken}) =>
      _startLiveFriendFn != null
          ? _startLiveFriendFn(handle: handle, cancelToken: cancelToken)
          : HttpSvc.icloud.startLiveFindMyFriend(handle, cancelToken: cancelToken);

  Future<Response> _performStopLiveFriend({String? handle, CancelToken? cancelToken}) =>
      _stopLiveFriendFn != null
          ? _stopLiveFriendFn(handle: handle, cancelToken: cancelToken)
          : HttpSvc.icloud.stopLiveFindMyFriend(handle: handle, cancelToken: cancelToken);

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
    } catch (e, s) {
      if (cancelToken.isCancelled || (e is DioException && CancelToken.isCancel(e))) return;
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
    if (_hasValidFriendCoords(friend.latitude, friend.longitude)) {
      _lastFollowedTargetPoint = markerPointForFriend(friend);
    }
    if (changed) {
      _forcedLiveForSelection = liveTrackingEnabled.value;
      _cancelPendingFriendRefresh();
      _scrollToTop(friendsController);
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
    final devLat = device.location?.latitude;
    final devLng = device.location?.longitude;
    if (_hasValidFriendCoords(devLat, devLng)) {
      _lastFollowedTargetPoint = markerPointForDevice(device);
    }
    if (changed) {
      _forcedLiveForSelection = false;
      selectedRingComponent.value = device.ringComponents.isNotEmpty ? device.ringComponents.first : null;
      _scrollToTop(device.isConsideredAccessory ? itemsController : devicesController);
    }
    _syncLiveHeartbeat();
    if (_interactive) {
      if ((changed || device.location == null) && !_refreshDevicesInFlight && device.id != null) {
        unawaited(getLocations(
          refreshFriends: false,
          refreshDevices: true,
          force: true,
          skipFetchWhenNotRefreshing: true,
          focusedDeviceId: device.id,
        ));
      } else {
        refreshOnView(
          refreshFriends: false,
          refreshDevices: true,
          focusedDeviceId: device.id,
        );
      }
    }
  }

  void _scrollToTop(ScrollController scrollController) {
    for (final c in [scrollController, if (activeSheetScrollController != null && !identical(activeSheetScrollController, scrollController)) activeSheetScrollController]) {
      if (c == null || !c.hasClients) continue;
      for (final position in c.positions) {
        if (position.pixels > 0) {
          position.animateTo(
            0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        }
      }
    }
  }

  void focusFriend(FindMyFriend friend, {double? sheetOffsetPx, double minZoom = defaultFocusZoom}) {
    selectFriend(friend);
    final hasCoords = (friend.latitude ?? 0) != 0 && (friend.longitude ?? 0) != 0;
    final key = friend.stableId ?? friend.title ?? 'friend';
    _focusTarget(
      targetTab: 0,
      scrollController: friendsController,
      point: hasCoords ? (animatedPoints[key] ?? markerPointForFriend(friend)) : null,
      sheetOffsetPx: sheetOffsetPx,
      minZoom: minZoom,
    );
  }

  void focusDevice(FindMyDevice device, {double? sheetOffsetPx, double minZoom = defaultFocusZoom}) {
    selectDevice(device);
    final isAcc = device.isConsideredAccessory;
    final hasCoords = _hasValidFriendCoords(device.location?.latitude, device.location?.longitude);
    final key = device.id ?? device.name ?? 'device';
    _focusTarget(
      targetTab: isAcc ? 2 : 1,
      scrollController: isAcc ? itemsController : devicesController,
      point: hasCoords ? (animatedPoints[key] ?? markerPointForDevice(device)) : null,
      sheetOffsetPx: sheetOffsetPx,
      minZoom: minZoom,
    );
  }

  void _focusTarget({
    required int targetTab,
    required ScrollController scrollController,
    required LatLng? point,
    double? sheetOffsetPx,
    double minZoom = defaultFocusZoom,
  }) {
    if (tabIndex.value != targetTab) {
      tabIndex.value = targetTab;
      tabController?.animateTo(targetTab);
    }
    _scrollToTop(scrollController);
    onRequestDetailSheetOpen?.call();
    if (point != null) {
      final offsetY = sheetOffsetPx ?? detailSheetOffsetProvider?.call() ?? 0;
      final targetZoom = _targetFocusZoom(minZoom);
      flyToCamera(
        point,
        is3DEnabled.value ? math.max(targetZoom, minZoomFor3DPitch) : targetZoom,
        offset: Offset(0, -offsetY),
      );
    }
  }

  double _targetFocusZoom(double minZoom) {
    return math.max(cameraZoom.value, minZoom);
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
    _lastFollowedTargetPoint = null;
    _forcedLiveForSelection = false;
    _cancelPendingFriendRefresh();
    unawaited(_stopLiveFriendStream());
    _syncLiveHeartbeat();
  }

  Future<Position?> _fetchCurrentPosition({bool requestPermission = true}) async {
    var perm = await Geolocator.checkPermission();
    if (!_isAlive) return null;
    if (perm == LocationPermission.denied && requestPermission) {
      perm = await Geolocator.requestPermission();
      if (!_isAlive) return null;
    }
    if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) return null;
    try {
      final pos = await Geolocator.getCurrentPosition();
      return _isAlive ? pos : null;
    } catch (_) {
      if (!kIsWeb && _isAlive) {
        final lastKnown = await Geolocator.getLastKnownPosition().catchError((_) => null);
        if (lastKnown != null) return lastKnown;
      }
      rethrow;
    }
  }

  Future<Position?> _performFetchCurrentPosition({bool requestPermission = true}) =>
      _fetchCurrentPositionFn != null
          ? _fetchCurrentPositionFn()
          : _fetchCurrentPosition(requestPermission: requestPermission);

  bool get _hasAnyPins =>
      friendsWithLocation.isNotEmpty ||
      devices.any((d) => d.location?.latitude != null && d.location?.longitude != null);

  void _runWhenMapReady(VoidCallback fn) {
    if (completer.isCompleted) {
      fn();
    } else {
      unawaited(completer.future.then((_) {
        if (_isAlive) fn();
      }));
    }
  }

  LatLng? _resolveInitialFocusPoint() {
    final loc = location.value;
    if (loc != null) {
      return LatLng(loc.latitude, loc.longitude);
    }
    FindMyFriend? bestFriend;
    for (final f in friendsWithLocation) {
      if (bestFriend == null ||
          _compareOptionalTimestamps(
                bestFriend.lastUpdated?.millisecondsSinceEpoch,
                f.lastUpdated?.millisecondsSinceEpoch,
              ) >
              0) {
        bestFriend = f;
      }
    }
    if (bestFriend != null) {
      final key = bestFriend.stableId ?? bestFriend.title ?? 'friend';
      return animatedPoints[key] ?? markerPointForFriend(bestFriend);
    }
    FindMyDevice? bestDevice;
    for (final d in devices) {
      if (d.location?.latitude == null || d.location?.longitude == null) continue;
      if (bestDevice == null ||
          _compareOptionalTimestamps(bestDevice.location?.timeStamp, d.location?.timeStamp) > 0) {
        bestDevice = d;
      }
    }
    if (bestDevice != null) {
      final key = bestDevice.id ?? bestDevice.name ?? 'device';
      return animatedPoints[key] ?? markerPointForDevice(bestDevice);
    }
    return null;
  }

  void _scheduleInitialAutoFitIfNeeded() {
    if (_hasAutoFittedInitialPins || _hasUserInteractedWithMap) return;
    if (selectedFriendId.value != null || selectedDeviceId.value != null || _pendingFocusFriendId != null) return;
    // Do not consume initial camera focus on a random friend/device while initial GPS fetch is in flight.
    if (location.value == null && _fetchingUserLocation) return;
    if (location.value == null && !_hasAnyPins) return;

    void runInitialFocus() {
      if (!_isAlive || _hasAutoFittedInitialPins || _hasUserInteractedWithMap) return;
      if (selectedFriendId.value != null || selectedDeviceId.value != null || _pendingFocusFriendId != null) return;
      if (location.value == null && _fetchingUserLocation) return;
      if (location.value == null && !_hasAnyPins) return;

      final offsetY = detailSheetOffsetProvider?.call() ?? 0;
      final userLoc = location.value;
      if (userLoc != null) {
        _hasAutoFittedInitialPins = true;
        hasMovedToCurrentLocation.value = true;
        flyToCamera(
          LatLng(userLoc.latitude, userLoc.longitude),
          defaultInitialZoom,
          offset: Offset(0, -offsetY),
          pitch: is3DEnabled.value ? default3DPitch : 0.0,
        );
        return;
      }

      _hasAutoFittedInitialPins = true;
      final target = _resolveInitialFocusPoint();
      if (target != null) {
        flyToCamera(
          target,
          defaultInitialZoom,
          offset: Offset(0, -offsetY),
          pitch: is3DEnabled.value ? default3DPitch : 0.0,
        );
      } else {
        fitAllPins();
      }
    }

    if (completer.isCompleted) {
      runInitialFocus();
    } else if (!_waitingMapReadyForAutoFit) {
      _waitingMapReadyForAutoFit = true;
      unawaited(completer.future.then((_) {
        _waitingMapReadyForAutoFit = false;
        runInitialFocus();
      }));
    }
  }

  void _applyUserPosition(Position pos, bool allowAutoMove) {
    location.value = pos;
    _resortFriendsLists();
    buildLocationMarker(pos);
    if (allowAutoMove &&
        !hasMovedToCurrentLocation.value &&
        !_hasAutoFittedInitialPins &&
        !_hasUserInteractedWithMap &&
        selectedFriendId.value == null &&
        selectedDeviceId.value == null &&
        _pendingFocusFriendId == null) {
      hasMovedToCurrentLocation.value = true;
      _hasAutoFittedInitialPins = true;
      _runWhenMapReady(() {
        if (!_isAlive ||
            _hasUserInteractedWithMap ||
            selectedFriendId.value != null ||
            selectedDeviceId.value != null ||
            _pendingFocusFriendId != null) {
          return;
        }
        final offsetY = detailSheetOffsetProvider?.call() ?? 0.0;
        animateCameraTo(
          LatLng(pos.latitude, pos.longitude),
          defaultInitialZoom,
          offset: Offset(0, -offsetY),
          pitch: is3DEnabled.value ? default3DPitch : 0.0,
        );
      });
    }
  }

  void _startLocationStream() {
    if (!_isAlive || locationSub != null || (_positionStreamFn == null && kIsDesktop)) return;
    final stream = _positionStreamFn != null
        ? _positionStreamFn()
        : Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              distanceFilter: 15,
            ),
          );
    locationSub = stream.listen(
      (event) {
        if (_isAlive) _applyUserPosition(event, true);
      },
      onError: (Object error, StackTrace stack) {
        _logWarn("FindMy position stream error", error: error, trace: stack);
      },
      cancelOnError: true,
    );
  }

  Future<void> _initUserLocation({bool requestPermission = true, bool startStream = true}) async {
    if (_fetchingUserLocation || !_isAlive) return;
    _fetchingUserLocation = true;

    try {
      final loc = await _performFetchCurrentPosition(requestPermission: requestPermission);
      if (!_isAlive || loc == null) return;
      _applyUserPosition(loc, startStream);
      if (startStream && (_positionStreamFn != null || !kIsDesktop) && locationSub == null) {
        _startLocationStream();
      }
    } catch (e, s) {
      _logWarn("Failed to fetch initial FindMy location", error: e, trace: s);
    } finally {
      _fetchingUserLocation = false;
      if (_isAlive && _pageActivated && location.value == null) {
        _scheduleInitialAutoFitIfNeeded();
      }
    }
  }

  Future<void> recenterToUser({double zoom = defaultInitialZoom}) async {
    final current = location.value;
    if (current != null) {
      animateCameraTo(LatLng(current.latitude, current.longitude), _targetFocusZoom(zoom));
      return;
    }
    if (!_interactive || (Platform.isLinux && !kIsWeb)) return;
    try {
      final pos = await _performFetchCurrentPosition();
      if (!_isAlive) return;
      if (pos != null) {
        location.value = pos;
        buildLocationMarker(pos);
        hasMovedToCurrentLocation.value = true;
        animateCameraTo(LatLng(pos.latitude, pos.longitude), zoom);
      }
    } catch (e, s) {
      _logWarn("Failed to get current location for recenter", error: e, trace: s);
    }
  }

  static const EdgeInsets defaultFitAllPinsPadding = EdgeInsets.fromLTRB(48, 96, 48, 120);

  void fitAllPins({EdgeInsets? padding}) {
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
      final offsetY = detailSheetOffsetProvider?.call() ?? 0;
      flyToCamera(bounds.center, defaultInitialZoom, offset: Offset(0, -offsetY));
      return;
    }
    final rawPadding = padding ?? fitAllPinsPaddingProvider?.call() ?? defaultFitAllPinsPadding;
    final resolvedPadding = clampFindMyFitPadding(rawPadding, mapViewportSize);
    final fitted = computeFindMyFitCamera(
      bounds,
      mapViewportSize,
      resolvedPadding,
      maxZoom: 15.0,
    );
    animateCameraTo(
      fitted.center,
      fitted.zoom.isFinite ? fitted.zoom : 12.0,
      padding: resolvedPadding,
      pitch: is3DEnabled.value ? default3DPitch : 0.0,
      fly: true,
    );
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
    final devId = selectedDeviceId.value;
    if (devId != null) {
      await hardRefresh(
        refreshFriends: false,
        refreshDevices: true,
        focusedDeviceId: devId,
      );
      return;
    }
    await hardRefresh(
      focusedHandle: _selectedFriendHandle(),
      focusedDeviceId: devId,
    );
  }

  String? _extractRingResponseError(Response res) {
    final data = res.data;
    if (data is Map) {
      if (data['ok'] == false || data['error'] != null) {
        final err = data['error'];
        if (err is Map && err['message'] != null) return err['message'].toString();
        if (err != null) return err.toString();
        if (data['message'] != null) return data['message'].toString();
        return 'Ring request was rejected by the server.';
      }
      final inner = data['data'];
      if (inner is Map && (inner['ok'] == false || inner['error'] != null)) {
        return inner['error']?.toString() ?? inner['message']?.toString() ?? 'Ring request failed.';
      }
    }
    if (res.statusCode != null && res.statusCode != 200) {
      return 'Server returned HTTP ${res.statusCode}.';
    }
    return null;
  }

  String _extractRingExceptionError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final err = data['error'];
        if (err is Map && err['message'] != null) return err['message'].toString();
        if (err != null) return err.toString();
        if (data['message'] != null) return data['message'].toString();
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!.trim();
      }
    }
    return error.toString();
  }

  void _notifyUser(String title, String message, {SnackbarType type = SnackbarType.info}) {
    try {
      showSnackbar(title, message, type: type);
    } catch (_) {}
  }

  Future<bool> toggleRingDevice(FindMyDevice device, {String? component}) async {
    final deviceId = device.id;
    if (deviceId == null || deviceId.isEmpty || ringBusy.value) return false;
    final isStopping = ringingDeviceId.value == deviceId;
    ringBusy.value = true;
    try {
      bool ok = false;
      String? lastError;
      final provider = device.trackerProvider;
      final canBleRing = bleService.isSupported && device.hasBleRing && provider == 'gfind';

      Future<bool> tryCloudRing({required bool stop}) async {
        try {
          final res = await (cloudRingOverride != null
              ? cloudRingOverride!(deviceId, stop: stop, component: component)
              : HttpSvc.icloud.ringDevice(deviceId, stop: stop, component: component));
          final respErr = _extractRingResponseError(res);
          if (res.statusCode == 200 && respErr == null) {
            return true;
          }
          lastError = respErr ?? 'Ring request failed.';
        } catch (e) {
          lastError = _extractRingExceptionError(e);
        }
        return false;
      }

      Future<bool> tryGoogleBleRing({required bool stop}) async {
        if (!canBleRing) return false;
        try {
          if (!await bleService.checkPermissions() && !await bleService.requestPermissions()) {
            lastError ??= 'Bluetooth permission required for nearby ring.';
            return false;
          }
          final spec = await bleService.getBleSpec(deviceId);
          if (spec != null && spec.ringKeyHex != null && spec.ringKeyHex!.isNotEmpty) {
            final bleOk = await bleService.ringGoogleTag(
              spec: spec,
              stop: stop,
              component: component,
            );
            if (!bleOk) {
              final bleErr = bleService.lastRingError?.trim();
              lastError = (bleErr != null && bleErr.isNotEmpty)
                  ? bleErr
                  : (lastError ?? 'Nearby Bluetooth ring failed. Move closer or check Bluetooth.');
            }
            return bleOk;
          }
          lastError ??= 'Missing BLE ring key for tracker.';
        } catch (e) {
          lastError ??= _extractRingExceptionError(e);
        }
        return false;
      }

      if (isStopping) {
        if (canBleRing) {
          ok = await tryGoogleBleRing(stop: true);
        }
        if (provider != 'utag' || cloudRingOverride != null) {
          final cloudOk = await tryCloudRing(stop: true);
          ok = ok || cloudOk;
        }
        _ringAutoClearTimer?.cancel();
        _ringAutoClearTimer = null;
        ringingDeviceId.value = null;
        if (!ok && lastError != null) {
          _notifyUser('Stop Sound', lastError!, type: SnackbarType.error);
        }
        return ok;
      }

      if (provider == 'utag') {
        if (bleService.isSupported) {
          try {
            final spec = await bleService.getBleSpec(deviceId);
            if (spec != null && (spec.supportsUwb || (spec.uwbPackage?.isNotEmpty ?? false))) {
              final launched = await bleService.launchUwbApp(spec);
              if (launched) return true;
              lastError = 'Could not open SmartThings to ring this SmartTag.';
            }
          } catch (e) {
            lastError = _extractRingExceptionError(e);
          }
        }
        if (device.canRing && cloudRingOverride != null) {
          ok = await tryCloudRing(stop: false);
        } else if (lastError == null) {
          lastError = bleService.isSupported
              ? 'SmartTag ringing requires SmartThings on this device.'
              : 'SmartTag ringing is only available via SmartThings on Android.';
        }
      } else if (provider == 'gfind') {
        if (canBleRing) {
          ok = await tryGoogleBleRing(stop: false);
        }
        if (!ok && device.canRing) {
          ok = await tryCloudRing(stop: false);
        }
      } else {
        if (!device.canRing) {
          lastError = 'Playing sound is not supported for this device.';
        } else {
          ok = await tryCloudRing(stop: false);
        }
      }

      if (ok) {
        ringingDeviceId.value = deviceId;
        _ringAutoClearTimer?.cancel();
        _ringAutoClearTimer = Timer(const Duration(seconds: 60), () {
          if (ringingDeviceId.value == deviceId) {
            ringingDeviceId.value = null;
          }
        });
      } else {
        _notifyUser(
          'Play Sound',
          lastError ?? 'Could not play sound on this device.',
          type: SnackbarType.error,
        );
      }
      return ok;
    } finally {
      ringBusy.value = false;
    }
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
    if (!_interactive) return;
    if (index == 0) {
      refreshOnView(refreshFriends: true, refreshDevices: false);
    } else if (index == 1 || index == 2) {
      refreshOnView(refreshFriends: false, refreshDevices: true);
    }
  }

  double? distanceMetersTo(double? lat, double? lng) {
    final userPos = location.value;
    if (userPos == null || !_hasValidFriendCoords(userPos.latitude, userPos.longitude) || !_hasValidFriendCoords(lat, lng)) {
      return null;
    }
    return haversineDistanceMeters(userPos.latitude, userPos.longitude, lat!, lng!);
  }

  String proximityLabelForFriend(FindMyFriend friend) {
    if (shouldRedactFindMyContactInfo()) return "";
    return formatFindMyFriendDistance(distanceMetersTo(friend.latitude, friend.longitude));
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onAppResumed();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      onAppPaused();
    }
  }

  void onAppPaused() {
    _isForeground = false;
    _stopStalenessTimer();
    _liveHeartbeatTimer?.cancel();
    _liveHeartbeatTimer = null;
    locationSub?.cancel();
    locationSub = null;
    if (_activeLiveStreamHandle != null) {
      unawaited(_stopLiveFriendStream());
    }
  }

  void onAppResumed() {
    _isForeground = true;
    if (_isAlive && (_pageActivated || _interactive || isBackgroundShared)) {
      _startStalenessTimer();
    }
    if (_isAlive && _pageActivated && locationSub == null && (_positionStreamFn != null || !kIsDesktop)) {
      if (location.value == null && !_fetchingUserLocation) {
        unawaited(_initUserLocation(requestPermission: false, startStream: true));
      } else {
        _startLocationStream();
      }
    }
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
    if (_interactive) {
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
    } catch (e, s) {
      if ((e is DioException && CancelToken.isCancel(e)) || cancelToken.isCancelled) return;
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

  void _deduplicateFriendsInPlace() {
    if (friends.isEmpty) return;
    final droppedIds = <String>{};
    final deduped = deduplicateFindMyFriends(
      friends,
      aliasToPrimaryIdOut: _friendAliasToPrimaryId,
      droppedStableIdsOut: droppedIds,
    );
    friends.value = deduped;
    for (final droppedId in droppedIds) {
      markers.remove(droppedId);
      animatedPoints.remove(droppedId);
      if (selectedFriendId.value == droppedId) {
        final mapped = _friendAliasToPrimaryId[normalizeFindMyHandle(droppedId)];
        if (mapped != null) selectedFriendId.value = mapped;
      }
    }
  }

  void _applyFriendsList(List<dynamic> rawData, {bool targeted = false}) {
    try {
      final incomingList = rawData.map((e) => FindMyFriend.fromJson(e)).toList().cast<FindMyFriend>();
      var anyUpdated = false;
      if (!targeted) {
        final previousFriendIds = friends.map((e) => e.stableId).whereType<String>().toSet();
        final droppedIds = <String>{};
        friends.value = deduplicateFindMyFriends(
          incomingList,
          aliasToPrimaryIdOut: _friendAliasToPrimaryId,
          droppedStableIdsOut: droppedIds,
        );
        final nextValidFriendIds = friends
            .where((e) => _hasValidFriendCoords(e.latitude, e.longitude))
            .map((e) => e.stableId)
            .whereType<String>()
            .toSet();
        for (final staleId in {...droppedIds, ...previousFriendIds.difference(nextValidFriendIds)}) {
          markers.remove(staleId);
          animatedPoints.remove(staleId);
        }
        anyUpdated = true;
      } else {
        for (final incoming in incomingList) {
          final incomingNorm = normalizeFindMyHandle(incoming.handleAddress ?? incoming.handle?.address);
          final mappedPrimaryId = incomingNorm.isNotEmpty ? _friendAliasToPrimaryId[incomingNorm] : null;
          final existingIndex = friends.indexWhere(
            (e) =>
                (incoming.stableId != null && e.stableId == incoming.stableId) ||
                (mappedPrimaryId != null && e.stableId == mappedPrimaryId) ||
                findMyHandlesMatch(e.handleAddress ?? e.handle?.address, incoming.handleAddress ?? incoming.handle?.address),
          );
          final existing = existingIndex == -1 ? null : friends[existingIndex];
          if (existingIndex == -1) {
            friends.add(incoming);
            anyUpdated = true;
          } else if (shouldSupersedeFriendLocation(existing, incoming)) {
            friends[existingIndex] = _mergeDuplicateFriends(
              existing!,
              _lookupContactForFindMyFriend(existing),
              incoming,
              _lookupContactForFindMyFriend(incoming),
            );
            anyUpdated = true;
          }
        }
        if (anyUpdated) {
          _deduplicateFriendsInPlace();
        }
      }

      if (anyUpdated) {
        _resortFriendsLists();

        final toBuild = targeted
            ? friendsWithLocation.where(
                (item) => incomingList.any(
                  (inc) {
                    final incNorm = normalizeFindMyHandle(inc.handleAddress ?? inc.handle?.address);
                    final mapped = incNorm.isNotEmpty ? _friendAliasToPrimaryId[incNorm] : null;
                    return (inc.stableId != null && item.stableId == inc.stableId) ||
                        (mapped != null && item.stableId == mapped) ||
                        findMyHandlesMatch(item.handleAddress ?? item.handle?.address, inc.handleAddress ?? inc.handle?.address);
                  },
                ),
              )
            : friendsWithLocation;
        for (final e in toBuild) {
          buildFriendMarker(e);
          unawaited(resolveFriendAddress(e));
        }
        livePulseNonce.value++;
        _applyPendingFocusIfReady();
        if (_pageActivated) {
          _scheduleInitialAutoFitIfNeeded();
        }
        _followSelectedTargetIfNeeded();
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

  void _resortFriendsLists() {
    final userPos = location.value;
    friendsWithLocation.value = sortFindMyFriends(
      friends.where((item) => _hasValidFriendCoords(item.latitude, item.longitude)),
      isFriendPinned,
      userLatitude: userPos?.latitude,
      userLongitude: userPos?.longitude,
    );
    friendsWithoutLocation.value = sortFindMyFriends(
      friends.where((item) => !_hasValidFriendCoords(item.latitude, item.longitude)),
      isFriendPinned,
      userLatitude: userPos?.latitude,
      userLongitude: userPos?.longitude,
    );
  }

  void _applyPendingFocusIfReady() {
    final pendingId = _pendingFocusFriendId;
    if (pendingId == null || !_pageActivated) return;
    final match = friends.firstWhereOrNull((f) => f.stableId == pendingId);
    if (match == null) return;
    _pendingFocusFriendId = null;
    if (_hasValidFriendCoords(match.latitude, match.longitude)) {
      _runWhenMapReady(() {
        if (!_isAlive) return;
        focusFriend(match);
      });
    }
  }

  void consumePendingFocus() => _applyPendingFocusIfReady();

  List<String> _readPrefList(String key) {
    if (_readPrefListFn != null) {
      return _readPrefListFn(key) ?? const [];
    }
    if (!GetIt.I.isRegistered<SharedPreferencesService>()) return const [];
    try {
      final raw = PrefsSvc.admin.get(key);
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.whereType<String>().toList();
        }
      }
    } catch (_) {}
    return const [];
  }

  Future<void> _writePrefList(String key, List<String> values) async {
    if (_writePrefListFn != null) {
      await _writePrefListFn(key, values);
      return;
    }
    if (!GetIt.I.isRegistered<SharedPreferencesService>()) return;
    try {
      await PrefsSvc.admin.setString(key, jsonEncode(values));
    } catch (_) {}
  }

  String? _readPrefString(String key) {
    if (!GetIt.I.isRegistered<SharedPreferencesService>()) return null;
    try {
      final raw = PrefsSvc.admin.get(key);
      return raw is String ? raw : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePrefString(String key, String value) async {
    if (!GetIt.I.isRegistered<SharedPreferencesService>()) return;
    try {
      await PrefsSvc.admin.setString(key, value);
    } catch (_) {}
  }

  bool? _readPrefBool(String key) {
    if (!GetIt.I.isRegistered<SharedPreferencesService>()) return null;
    try {
      final raw = PrefsSvc.admin.get(key);
      return raw is bool ? raw : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePrefBool(String key, bool value) async {
    if (!GetIt.I.isRegistered<SharedPreferencesService>()) return;
    try {
      await PrefsSvc.admin.setBool(key, value);
    } catch (_) {}
  }

  void _loadMapPrefs() {
    mapStyle.value = parseFindMyMapStyle(_readPrefString(kFindMyMapStylePrefKey));
    final saved3D = _readPrefBool(kFindMy3DEnabledPrefKey) ?? true;
    is3DEnabled.value = saved3D;
    cameraPitch.value = saved3D ? default3DPitch : 0.0;
  }

  void _loadPinPrefs() {
    _explicitlyPinnedKeys.assignAll(_readPrefList(kFindMyPinnedFriendsPrefKey));
    _explicitlyUnpinnedKeys.assignAll(_readPrefList(kFindMyUnpinnedFriendsPrefKey));
    pinVersion.value++;
  }

  String pinKeyForFriend(FindMyFriend friend) {
    final candidate = friend.handle?.address ?? friend.handleAddress ?? friend.stableId ?? '';
    final normalized = normalizeFindMyHandle(candidate);
    if (normalized.isNotEmpty) return normalized;
    return (friend.stableId ?? '').trim().toLowerCase();
  }

  Iterable<String> _pinnedChatHandles() {
    if (_pinnedChatHandlesProvider != null) {
      return _pinnedChatHandlesProvider();
    }
    if (!GetIt.I.isRegistered<ChatsService>()) return const [];
    return ChatsSvc.allChats
        .where((c) => !c.isGroup && (c.isPinned ?? false))
        .expand((c) => <String>[
              if ((c.chatIdentifier ?? '').trim().isNotEmpty) c.chatIdentifier!,
              ...c.participants.map((h) => h.address),
            ]);
  }

  bool _isFriendPinnedByChat(FindMyFriend friend) {
    final friendCandidates = <String?>[
      friend.handle?.address,
      friend.handleAddress,
      friend.stableId,
    ];
    for (final chatHandle in _pinnedChatHandles()) {
      for (final fc in friendCandidates) {
        if (findMyHandlesMatch(fc, chatHandle)) return true;
      }
    }
    return false;
  }

  bool isFriendPinned(FindMyFriend friend) {
    pinVersion.value;
    final key = pinKeyForFriend(friend);
    if (key.isEmpty) return false;
    if (_explicitlyUnpinnedKeys.contains(key)) return false;
    if (_explicitlyPinnedKeys.contains(key)) return true;
    return _isFriendPinnedByChat(friend);
  }

  Future<void> setFriendPinned(FindMyFriend friend, bool pinned) async {
    final key = pinKeyForFriend(friend);
    if (key.isEmpty) return;
    if (pinned) {
      _explicitlyUnpinnedKeys.remove(key);
      _explicitlyPinnedKeys.add(key);
    } else {
      _explicitlyPinnedKeys.remove(key);
      _explicitlyUnpinnedKeys.add(key);
    }
    pinVersion.value++;
    _resortFriendsLists();
    await Future.wait([
      _writePrefList(kFindMyPinnedFriendsPrefKey, _explicitlyPinnedKeys.toList()..sort()),
      _writePrefList(kFindMyUnpinnedFriendsPrefKey, _explicitlyUnpinnedKeys.toList()..sort()),
    ]);
  }

  Future<void> toggleFriendPin(FindMyFriend friend) {
    return setFriendPinned(friend, !isFriendPinned(friend));
  }

  /// Quietly ensures friend locations are loaded in the background without
  /// showing any error snackbars (for conversation header & details lookup).
  Future<void> ensureFriendsLoaded({Duration maxAge = const Duration(minutes: 2)}) async {
    if (!_isAlive || _refreshFriendsInFlight) return;
    if (friends.isNotEmpty &&
        _lastFriendsRefreshAt != null &&
        _now().difference(_lastFriendsRefreshAt!) < maxAge) {
      return;
    }
    if (_refreshFriendsFn == null && !GetIt.I.isRegistered<HttpService>()) return;

    if (!(Platform.isLinux && !kIsWeb) &&
        location.value == null &&
        !_fetchingUserLocation &&
        (_fetchCurrentPositionFn != null || GetIt.I.isRegistered<HttpService>())) {
      unawaited(_initUserLocation(requestPermission: false, startStream: _pageActivated));
    }

    _refreshFriendsInFlight = true;
    try {
      final res = _refreshFriendsFn != null
          ? await _refreshFriendsFn(force: false, live: false)
          : await HttpSvc.icloud.getFriends();
      if (!_isAlive) return;
      final data = res.data?['data'];
      if (res.statusCode == 200 && data is List) {
        _lastFriendsRefreshAt = _now();
        _applyFriendsList(data);
      }
    } catch (e, s) {
      _logWarn("Quiet Find My friend load failed", error: e, trace: s);
    } finally {
      _refreshFriendsInFlight = false;
    }
  }

  FindMyFriend? friendForChat(Chat? chat) {
    if (chat == null || chat.isGroup) return null;
    final chatCandidates = <String>[
      if ((chat.chatIdentifier ?? '').trim().isNotEmpty) chat.chatIdentifier!,
      ...chat.participants.map((h) => h.address),
      if (chat.guid.contains(';-;')) chat.guid.split(';-;').last,
    ];
    for (final f in friends) {
      final friendCandidates = <String?>[
        f.handle?.address,
        f.handleAddress,
        f.stableId,
      ];
      for (final cc in chatCandidates) {
        for (final fc in friendCandidates) {
          if (findMyHandlesMatch(cc, fc)) return f;
        }
      }
    }
    return null;
  }

  /// Reactive lookup of accessible Find My location for a 1:1 [chat].
  /// Returns `null` for group chats, redacted mode, unmatched contacts, or zero/invalid coords.
  FindMyChatLocation? locationForChat(Chat? chat) {
    friends.length;
    friendAddresses.length;
    freshnessTick.value;
    location.value;
    if (chat == null || chat.isGroup || shouldRedactFindMyContactInfo()) return null;

    final friend = friendForChat(chat);
    if (friend == null) return null;

    final lat = friend.latitude;
    final lng = friend.longitude;
    if (lat == null || lng == null || (lat == 0 && lng == 0) || !lat.isFinite || !lng.isFinite) {
      return null;
    }

    final resolvedShort = addressForFriend(friend, preferLong: false);
    final resolvedLong = addressForFriend(friend, preferLong: true);
    if (resolvedLong == null || !hasStreetAddressLine(resolvedLong)) {
      Future.microtask(() {
        if (_isAlive) unawaited(resolveFriendAddress(friend));
      });
    }

    final now = _now();
    final distanceLabel = proximityLabelForFriend(friend);
    return FindMyChatLocation(
      friend: friend,
      shortLabel: (resolvedShort != null && resolvedShort.isNotEmpty)
          ? resolvedShort
          : '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
      fullAddress: resolvedLong ?? resolvedShort ?? '',
      freshness: friend.displayFreshness(now),
      isLive: friend.isLiveFresh(now),
      latitude: lat,
      longitude: lng,
      distanceLabel: distanceLabel.isEmpty ? null : distanceLabel,
    );
  }

  Future<void> openForFriend(BuildContext context, FindMyFriend friend) async {
    _pendingFocusFriendId = friend.stableId;
    final tc = tabController;
    if (tc != null && tc.index != 0) {
      tc.animateTo(0);
    }
    tabIndex.value = 0;
    await Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (_) => FindMyPage(),
      ),
    );
  }

  Future<void> openForChat(BuildContext context, Chat chat) async {
    final friend = friendForChat(chat);
    if (friend != null) {
      await openForFriend(context, friend);
      return;
    }
    await Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (_) => FindMyPage(),
      ),
    );
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

    if (!_interactive) return;
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

  Future<void> hardRefresh({
    String? focusedHandle,
    String? focusedDeviceId,
    bool refreshFriends = true,
    bool refreshDevices = true,
  }) async {
    if (!_isAlive || _hardRefreshInFlight) return;
    final now = _now();
    if (_lastHardRefreshAt != null && now.difference(_lastHardRefreshAt!) < const Duration(seconds: 3)) {
      return;
    }

    _hardRefreshInFlight = true;
    _lastHardRefreshAt = now;
    canRefresh.value = false;
    if (refreshDevices) refreshing.value = true;
    if (refreshFriends) refreshing2.value = true;

    try {
      await getLocations(
        refreshFriends: refreshFriends,
        refreshDevices: refreshDevices,
        force: true,
        skipFetchWhenNotRefreshing: !refreshFriends || !refreshDevices,
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
    _contactsCacheListener?.cancel();
    if (GetIt.I.isRegistered<ContactServiceV2>()) {
      _contactsCacheListener = ContactsSvcV2.cacheVersion.listen((_) {
        if (!_isAlive || friends.isEmpty) return;
        final before = friends.length;
        _deduplicateFriendsInPlace();
        if (friends.length != before) {
          _resortFriendsLists();
          _rebuildAllMarkers();
        }
      });
    }
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

  /// The friend's display address: prefers a granular street address when present,
  /// otherwise falls back to a cached reverse-geocoded street address from
  /// [resolveFriendAddress], or the payload's short city/state label.
  String? addressForFriend(FindMyFriend friend, {bool preferLong = true}) {
    final longAddr = friend.longAddress?.trim();
    final shortAddr = friend.shortAddress?.trim();
    final geocoded = friendAddresses[_addressKeyForFriend(friend)]?.trim();
    final cleanLong = (longAddr != null && longAddr.isNotEmpty) ? longAddr : null;
    final cleanShort = (shortAddr != null && shortAddr.isNotEmpty) ? shortAddr : null;
    final cleanGeocoded = (geocoded != null && geocoded.isNotEmpty) ? geocoded : null;

    if (preferLong) {
      if (cleanLong != null && hasStreetAddressLine(cleanLong)) return cleanLong;
      if (cleanGeocoded != null) return cleanGeocoded;
      return cleanLong ?? cleanShort;
    }
    return cleanShort ?? cleanLong ?? cleanGeocoded;
  }

  /// Reverse-geocodes a friend's coordinates when the server sent no granular
  /// street address. Best-effort and cached quietly.
  Future<void> resolveFriendAddress(FindMyFriend friend) async {
    if (hasStreetAddressLine(friend.longAddress) ||
        (friend.longAddress == null && hasStreetAddressLine(friend.shortAddress))) {
      return;
    }
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

  void _followSelectedTargetIfNeeded() {
    if (!_pageActivated) return;
    LatLng? target;
    final friendId = selectedFriendId.value;
    if (friendId != null) {
      final friend = friends.firstWhereOrNull((e) => e.stableId == friendId);
      if (friend != null && _hasValidFriendCoords(friend.latitude, friend.longitude)) {
        target = markerPointForFriend(friend);
      }
    } else {
      final deviceId = selectedDeviceId.value;
      if (deviceId != null) {
        final device = devices.firstWhereOrNull((e) => e.id == deviceId);
        final lat = device?.location?.latitude;
        final lng = device?.location?.longitude;
        if (device != null && _hasValidFriendCoords(lat, lng)) {
          target = markerPointForDevice(device);
        }
      }
    }
    if (target == null) return;
    final prev = _lastFollowedTargetPoint;
    if (prev != null &&
        (prev.latitude - target.latitude).abs() < 1e-6 &&
        (prev.longitude - target.longitude).abs() < 1e-6) {
      return;
    }
    _lastFollowedTargetPoint = target;
    final offsetY = detailSheetOffsetProvider?.call() ?? 0.0;
    final targetZoom = prev == null
        ? math.max(
            _targetFocusZoom(defaultFocusZoom),
            is3DEnabled.value ? minZoomFor3DPitch : defaultFocusZoom,
          )
        : cameraZoom.value;
    _runWhenMapReady(() {
      if (!_isAlive) return;
      animateCameraTo(
        target!,
        targetZoom,
        offset: Offset(0, -offsetY),
        pitch: cameraPitch.value,
        fly: prev == null,
      );
    });
  }

  void handleNewFindMyLocation(dynamic data) {
    if (!_isAlive || data == null) return;
    try {
      final friend = data is FindMyFriend ? data : FindMyFriend.fromJson(data);
      _logInfo("Received new location for ${friend.handle?.address}");
      if ((friend.latitude ?? 0) == 0 && (friend.longitude ?? 0) == 0) return;

      final incomingNorm = normalizeFindMyHandle(friend.handleAddress ?? friend.handle?.address);
      final mappedPrimaryId = incomingNorm.isNotEmpty ? _friendAliasToPrimaryId[incomingNorm] : null;
      final existingFriendIndex = friends.indexWhere(
        (e) =>
            (e.stableId != null && e.stableId == friend.stableId) ||
            (mappedPrimaryId != null && e.stableId == mappedPrimaryId) ||
            findMyHandlesMatch(e.handleAddress ?? e.handle?.address, friend.handleAddress ?? friend.handle?.address),
      );
      final existingFriend = existingFriendIndex == -1 ? null : friends[existingFriendIndex];

      if (shouldSupersedeFriendLocation(existingFriend, friend)) {
        final mergedFriend = existingFriend == null
            ? friend
            : _mergeDuplicateFriends(
                existingFriend,
                _lookupContactForFindMyFriend(existingFriend),
                friend,
                _lookupContactForFindMyFriend(friend),
              );
        _logInfo("Updating map for ${mergedFriend.stableId}");
        if (existingFriendIndex == -1) {
          friends.add(mergedFriend);
        } else {
          friends[existingFriendIndex] = mergedFriend;
        }
        _deduplicateFriendsInPlace();

        final activeFriend = friends.firstWhereOrNull(
              (e) =>
                  (mergedFriend.stableId != null && e.stableId == mergedFriend.stableId) ||
                  findMyHandlesMatch(
                      e.handleAddress ?? e.handle?.address, mergedFriend.handleAddress ?? mergedFriend.handle?.address),
            ) ??
            mergedFriend;

        _resortFriendsLists();

        buildFriendMarker(activeFriend);
        livePulseNonce.value++;
        unawaited(resolveFriendAddress(activeFriend));
        if (selectedFriendId.value != null && selectedFriendId.value == activeFriend.stableId) {
          _lastLiveStreamUpdateAt = _now();
          if (!activeFriend.locatingInProgress && locatingFriendId.value == activeFriend.stableId) {
            locatingFriendId.value = null;
          }
          _syncLiveHeartbeat();
          _followSelectedTargetIfNeeded();
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
          _followSelectedTargetIfNeeded();
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

    if (!(Platform.isLinux && !kIsWeb) &&
        locationSub == null &&
        !_fetchingUserLocation) {
      unawaited(_initUserLocation());
    }

    Response emptyResponse() => Response(requestOptions: RequestOptions(path: ''));
    Future<Response> safeFetch(Future<Response> future, void Function() onError) => future.catchError((_) {
          if (_isAlive) onError();
          return emptyResponse();
        });

    try {
      Future<void> fetchAndApplyFriends() async {
        if (refreshFriends) _refreshFriendsInFlight = true;
        final friendSeq = _friendRefreshSeq;
        Response response2;
        try {
          response2 = refreshFriends
              ? await safeFetch(
                  _performRefreshFriends(
                    handle: focusedHandle,
                    force: force,
                    live: focusedHandle != null && liveTrackingEnabled.value,
                  ),
                  () {
                    refreshing2.value = false;
                    showSnackbar("Error", "Something went wrong refreshing FindMy Friends data!", type: SnackbarType.error);
                  },
                )
              : (!GetIt.I.isRegistered<HttpService>()
                  ? emptyResponse()
                  : await safeFetch(HttpSvc.icloud.getFriends(), () => fetching2.value = null));
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

      Future<void> fetchAndApplyDevices() async {
        if (refreshDevices) _refreshDevicesInFlight = true;
        Response response;
        try {
          void onDevicesRefreshError() {
            refreshing.value = false;
            showSnackbar("Error", "Something went wrong refreshing FindMy Devices data!", type: SnackbarType.error);
          }

          if (refreshDevices && _refreshDevicesFn != null) {
            response = await safeFetch(
              _refreshDevicesFn(deviceId: focusedDeviceId, force: force),
              onDevicesRefreshError,
            );
          } else if (_refreshDevicesFn == null && !GetIt.I.isRegistered<HttpService>()) {
            response = emptyResponse();
          } else {
            response = refreshDevices
                ? await safeFetch(
                    HttpSvc.icloud.refreshDevices(deviceId: focusedDeviceId, force: force),
                    onDevicesRefreshError,
                  )
                : await safeFetch(HttpSvc.icloud.getDevices(), () => fetching.value = null);
          }
        } finally {
          if (refreshDevices) {
            _refreshDevicesInFlight = false;
            _lastDevicesRefreshAt = _now();
          }
        }
        if (!_isAlive) return;

        if (response.statusCode == 200 && response.data['data'] != null) {
          try {
            final incomingDevices =
                (response.data['data'] as List).map((e) => FindMyDevice.fromJson(e)).toList().cast<FindMyDevice>();

            // Apply safe location name as the display label once, here rather than during build.
            for (final device in incomingDevices) {
              if (device.safeLocations.isNotEmpty && device.safeLocations.first.name != null) {
                device.address?.label = device.safeLocations.first.name;
              }
            }

            if (focusedDeviceId != null) {
              var anyUpdated = false;
              for (final incoming in incomingDevices) {
                final existingIndex = incoming.id == null
                    ? -1
                    : devices.indexWhere((e) => e.id != null && e.id == incoming.id);
                final existing = existingIndex == -1 ? null : devices[existingIndex];
                if (existingIndex == -1) {
                  devices.add(incoming);
                  anyUpdated = true;
                } else if (shouldSupersedeDeviceLocation(existing, incoming)) {
                  devices[existingIndex] = incoming;
                  anyUpdated = true;
                }
              }
              if (anyUpdated) {
                devices.refresh();
              }
            } else {
              final previousDeviceIds = devices.map((e) => e.id).whereType<String>().toSet();
              devices.value = incomingDevices;
              final nextValidDeviceIds = devices
                  .where((e) => _hasValidFriendCoords(e.location?.latitude, e.location?.longitude))
                  .map((e) => e.id)
                  .whereType<String>()
                  .toSet();
              for (final staleId in previousDeviceIds.difference(nextValidDeviceIds)) {
                markers.remove(staleId);
                animatedPoints.remove(staleId);
              }
            }

            for (final e in devices.where((e) => _hasValidFriendCoords(e.location?.latitude, e.location?.longitude))) {
              buildDeviceMarker(e);
            }
            fetching.value = false;
            refreshing.value = false;
            _syncLiveHeartbeat();
            _followSelectedTargetIfNeeded();
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

      final tasks = <Future<void>>[
        if (refreshFriends || !skipFetchWhenNotRefreshing) fetchAndApplyFriends(),
        if (refreshDevices || !skipFetchWhenNotRefreshing) fetchAndApplyDevices(),
      ];
      if (tasks.isNotEmpty) {
        await Future.wait(tasks);
      }
    } finally {
      if (_isAlive) {
        _scheduleInitialAutoFitIfNeeded();
      }
    }
  }

  final Map<String, int> _markerStaggerOrder = {};

  int _staggerIndexFor(String key) =>
      _markerStaggerOrder.putIfAbsent(key, () => _markerStaggerOrder.length);

  void _setOrAnimateMarkerPoint({
    required String markerKey,
    required LatLng targetPoint,
    required Size size,
    required Alignment alignment,
    required Widget child,
    required bool animate,
  }) {
    void setMarker(LatLng pt) {
      animatedPoints[markerKey] = pt;
      markers[markerKey] = maplibre.Marker(
        point: toGeographic(pt),
        size: size,
        alignment: alignment,
        child: child,
      );
    }

    final prevPoint = animatedPoints[markerKey];
    if (prevPoint == null ||
        !animate ||
        _pinInterpolator == null ||
        (prevPoint.latitude == targetPoint.latitude && prevPoint.longitude == targetPoint.longitude)) {
      setMarker(targetPoint);
      return;
    }

    _pinInterpolator!(markerKey, prevPoint, targetPoint, (stepPoint) {
      if (_isAlive) setMarker(stepPoint);
    });
  }

  void buildDeviceMarker(FindMyDevice e, {bool animate = true}) {
    final markerKey = e.id ?? randomString(6);
    final fullKey = 'device-$markerKey';
    final staggerIndex = _staggerIndexFor(fullKey);
    final targetPoint = markerPointForDevice(e);
    final child = Obx(
      key: ValueKey(fullKey),
      () => FindMyDeviceMarker(
        key: ValueKey('device-widget-$markerKey'),
        controller: this,
        device: e,
        pitchDegrees: cameraPitch.value,
        isHovered: hoveredMarkerKey.value == fullKey,
        staggerIndex: staggerIndex,
      ),
    );
    _setOrAnimateMarkerPoint(
      markerKey: markerKey,
      targetPoint: targetPoint,
      size: const Size(96, 76),
      alignment: Alignment.bottomCenter,
      child: child,
      animate: animate,
    );
  }

  void buildFriendMarker(FindMyFriend friend, {bool animate = true}) {
    final markerKey = friend.stableId ?? randomString(6);
    final fullKey = 'friend-$markerKey';
    final staggerIndex = _staggerIndexFor(fullKey);
    final targetPoint = markerPointForFriend(friend);
    final avatarHandle = friend.handle ??
        Handle(
          address: friend.handleAddress ?? friend.title ?? "Unknown",
          formattedAddress: friend.handleAddress != null ? formatPhoneNumber(friend.handleAddress!) : null,
        );
    final child = Obx(
      key: ValueKey(fullKey),
      () => FindMyFriendMarker(
        key: ValueKey('friend-widget-$markerKey'),
        controller: this,
        friend: friend,
        avatarHandle: avatarHandle,
        pitchDegrees: cameraPitch.value,
        isHovered: hoveredMarkerKey.value == fullKey,
        staggerIndex: staggerIndex,
      ),
    );
    _setOrAnimateMarkerPoint(
      markerKey: markerKey,
      targetPoint: targetPoint,
      size: const Size(96, 76),
      alignment: Alignment.bottomCenter,
      child: child,
      animate: animate,
    );
  }

  void buildLocationMarker(Position pos) {
    final headingRadians = pos.heading.isFinite ? pos.heading : null;
    markers['current'] = maplibre.Marker(
      point: maplibre.Geographic(lon: pos.longitude, lat: pos.latitude),
      size: const Size(72, 72),
      alignment: Alignment.center,
      child: Obx(
        key: const ValueKey('current'),
        () {
          bool showAvatar = false;
          if (GetIt.I.isRegistered<SettingsService>() && GetIt.I.isRegistered<ThemesService>()) {
            final hasPath = !isNullOrEmpty(SettingsSvc.settings.userAvatarPath.value);
            final hasBytes = SettingsSvc.userAvatarBytes.value != null;
            final hasName = SettingsSvc.effectiveUserName != 'You';
            showAvatar = hasPath || hasBytes || hasName;
          }
          return FindMySelfMarker(
            key: const ValueKey('current-widget'),
            headingRadians: headingRadians,
            pitchDegrees: cameraPitch.value,
            isHovered: hoveredMarkerKey.value == 'current',
            showAvatar: showAvatar,
          );
        },
      ),
    );
  }

  @override
  void onClose() {
    if (_observingLifecycle) {
      _observingLifecycle = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    _ringAutoClearTimer?.cancel();
    _ringAutoClearTimer = null;
    _cancelPendingFriendRefresh();
    unawaited(_stopLiveFriendStream());
    _hardRefreshDebounceTimer?.cancel();
    _refreshFeedbackTimer?.cancel();
    _stopStalenessTimer();
    _liveHeartbeatTimer?.cancel();
    _liveHeartbeatTimer = null;
    _redactedModeListener?.cancel();
    _hideContactInfoListener?.cancel();
    _findMyLocationListener?.cancel();
    _contactsCacheListener?.cancel();
    locationSub?.cancel();
    mapLibreController = null;
    mapStyleController = null;
    tabController?.dispose();
    activeSheetScrollController = null;
    sheetController.dispose();
    itemsController.dispose();
    devicesController.dispose();
    friendsController.dispose();
    super.onClose();
  }
}

/// Clamps fit padding so [CameraFit.bounds] always has positive interior space.
EdgeInsets clampFindMyFitPadding(EdgeInsets padding, Size viewportSize) {
  (double, double) clampAxis(double a, double b, double extent) {
    final maxTotal = (extent - 80.0).clamp(0.0, double.infinity);
    var lo = a.clamp(0.0, maxTotal);
    var hi = b.clamp(0.0, maxTotal);
    if (lo + hi > maxTotal && lo + hi > 0) {
      final scale = maxTotal / (lo + hi);
      lo *= scale;
      hi *= scale;
    }
    return (lo, hi);
  }

  final (left, right) = clampAxis(padding.left, padding.right, viewportSize.width);
  final (top, bottom) = clampAxis(padding.top, padding.bottom, viewportSize.height);
  return EdgeInsets.fromLTRB(left, top, right, bottom);
}

/// Computes [fitAllPins] padding accounting for marker extents (116x92), top
/// map controls, and on phone viewports the sliding bottom sheet height.
EdgeInsets computeFindMyFitAllPadding({
  required Size viewportSize,
  EdgeInsets viewPadding = EdgeInsets.zero,
  required bool isPhone,
  double bottomSheetHeight = 0.0,
}) {
  if (!isPhone) {
    return clampFindMyFitPadding(
      FindMyController.defaultFitAllPinsPadding,
      viewportSize,
    );
  }
  // Markers are 116x92 (58px horizontal half, 46px vertical half); right controls sit at 14+44=58px.
  final raw = EdgeInsets.fromLTRB(
    64.0,
    viewPadding.top + 76.0,
    72.0,
    bottomSheetHeight + 52.0,
  );
  return clampFindMyFitPadding(raw, viewportSize);
}

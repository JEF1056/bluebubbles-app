import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/findmy_helpers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

FindMyFriend _friend({
  required String handleAddress,
  String? title,
  double? latitude = 37.3349,
  double? longitude = -122.009,
  String? shortAddress = 'Cupertino, CA',
  String? longAddress = '1 Apple Park Way, Cupertino, CA',
  DateTime? lastUpdated,
  LocationStatus? status = LocationStatus.live,
}) {
  return FindMyFriend(
    latitude: latitude,
    longitude: longitude,
    longAddress: longAddress,
    shortAddress: shortAddress,
    title: title ?? handleAddress,
    subtitle: null,
    handle: null,
    handleAddress: handleAddress,
    lastUpdated: lastUpdated,
    status: status,
    locatingInProgress: false,
    isOld: false,
  );
}

Map<String, dynamic> _friendJson({
  required String handle,
  double lat = 37.3349,
  double lng = -122.009,
  String? shortAddress = 'Cupertino, CA',
  String? longAddress = '1 Apple Park Way, Cupertino, CA',
  int? lastUpdatedMs,
  String status = 'live',
}) {
  return {
    'handle': handle,
    'coordinates': [lat, lng],
    'short_address': shortAddress,
    'long_address': longAddress,
    'last_updated': lastUpdatedMs,
    'status': status,
    'locating_in_progress': false,
    'is_old': false,
  };
}

void main() {
  test('normalizeFindMyHandle and findMyHandlesMatch handle phones and emails', () {
    expect(normalizeFindMyHandle(' Alice@iCloud.com '), 'alice@icloud.com');
    expect(normalizeFindMyHandle('+1 (555) 123-4567'), '15551234567');
    expect(findMyHandlesMatch('+1 (555) 123-4567', '5551234567'), isTrue);
    expect(findMyHandlesMatch('Alice@iCloud.com', 'alice@icloud.com'), isTrue);
    expect(findMyHandlesMatch('5551234567', '5559990000'), isFalse);
    expect(findMyHandlesMatch('', '5551234567'), isFalse);
  });

  test('sortFindMyFriends puts pinned friends first and preserves relative order', () {
    final a = _friend(handleAddress: 'a@example.com', title: 'Alice');
    final b = _friend(handleAddress: 'b@example.com', title: 'Bob');
    final c = _friend(handleAddress: 'c@example.com', title: 'Carol');
    final d = _friend(handleAddress: 'd@example.com', title: 'Dave');

    final sorted = sortFindMyFriends(
      [a, b, c, d],
      (f) => f.handleAddress == 'c@example.com' || f.handleAddress == 'b@example.com',
    );
    expect(sorted.map((e) => e.handleAddress).toList(), [
      'b@example.com',
      'c@example.com',
      'a@example.com',
      'd@example.com',
    ]);
  });

  test('FindMyController pins matching 1:1 pinned chats by default and persists explicit overrides', () async {
    final prefs = <String, List<String>>{};
    final now = DateTime(2026, 11, 19, 12, 0);

    final controller = FindMyController(
      now: () => now,
      autoFetch: false,
      readPrefList: (key) => prefs[key],
      writePrefList: (key, values) async => prefs[key] = List<String>.from(values),
      pinnedChatHandlesProvider: () => ['+1 (555) 222-3333'],
      refreshFriendsRequest: ({String? handle, bool force = false, bool live = false, CancelToken? cancelToken}) async {
        return Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends'),
          statusCode: 200,
          data: {
            'data': [
              _friendJson(handle: 'alice@icloud.com', lastUpdatedMs: now.millisecondsSinceEpoch),
              _friendJson(handle: '+15552223333', lastUpdatedMs: now.millisecondsSinceEpoch),
              _friendJson(handle: 'carol@icloud.com', lat: 0, lng: 0, lastUpdatedMs: now.millisecondsSinceEpoch),
            ],
          },
        );
      },
    );
    controller.onInit();
    await controller.ensureFriendsLoaded();

    // +15552223333 matches the pinned 1:1 chat so it sorts ahead of alice@icloud.com
    expect(controller.friendsWithLocation.map((f) => f.handleAddress).toList(), [
      '+15552223333',
      'alice@icloud.com',
    ]);
    expect(controller.isFriendPinned(controller.friendsWithLocation.first), isTrue);
    expect(controller.isFriendPinned(controller.friendsWithLocation.last), isFalse);

    // Explicit unpin overrides the pinned 1:1 chat and re-sorts
    await controller.setFriendPinned(controller.friendsWithLocation.first, false);
    expect(controller.friendsWithLocation.map((f) => f.handleAddress).toList(), [
      'alice@icloud.com',
      '+15552223333',
    ]);
    expect(prefs[kFindMyUnpinnedFriendsPrefKey], contains('15552223333'));

    // Explicit pin on alice moves her to top and persists
    await controller.setFriendPinned(controller.friendsWithLocation.first, true);
    expect(prefs[kFindMyPinnedFriendsPrefKey], contains('alice@icloud.com'));

    // New controller restores persisted pin/unpin state
    final restored = FindMyController(
      now: () => now,
      autoFetch: false,
      readPrefList: (key) => prefs[key],
      writePrefList: (key, values) async => prefs[key] = List<String>.from(values),
      pinnedChatHandlesProvider: () => ['+1 (555) 222-3333'],
    );
    restored.onInit();
    expect(restored.isFriendPinned(_friend(handleAddress: 'alice@icloud.com')), isTrue);
    expect(restored.isFriendPinned(_friend(handleAddress: '+15552223333')), isFalse);

    controller.onClose();
    restored.onClose();
  });

  test('locationForChat matches 1:1 chats, skips groups/zero-coords, and ensureFriendsLoaded is silent on error', () async {
    final now = DateTime(2026, 11, 19, 12, 0);
    final failingController = FindMyController(
      now: () => now,
      autoFetch: false,
      refreshFriendsRequest: ({String? handle, bool force = false, bool live = false, CancelToken? cancelToken}) async {
        throw DioException(requestOptions: RequestOptions(path: '/icloud/findmy/friends'));
      },
    );
    failingController.onInit();
    await failingController.ensureFriendsLoaded();
    expect(failingController.friends, isEmpty);
    failingController.onClose();

    final controller = FindMyController(
      now: () => now,
      autoFetch: false,
      refreshFriendsRequest: ({String? handle, bool force = false, bool live = false, CancelToken? cancelToken}) async {
        return Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends'),
          statusCode: 200,
          data: {
            'data': [
              _friendJson(
                handle: '+15551234567',
                lat: 37.3349,
                lng: -122.009,
                shortAddress: 'Cupertino, CA',
                longAddress: '1 Apple Park Way, Cupertino, CA',
                lastUpdatedMs: now.subtract(const Duration(seconds: 20)).millisecondsSinceEpoch,
              ),
              _friendJson(
                handle: 'zero@icloud.com',
                lat: 0,
                lng: 0,
              ),
            ],
          },
        );
      },
    );
    controller.onInit();
    await controller.ensureFriendsLoaded();

    final dmChat = Chat(guid: 'iMessage;-;+15551234567', chatIdentifier: '5551234567', style: 45);
    final loc = controller.locationForChat(dmChat);
    expect(loc, isNotNull);
    expect(loc!.shortLabel, 'Cupertino, CA');
    expect(loc.fullAddress, '1 Apple Park Way, Cupertino, CA');
    expect(loc.isLive, isTrue);
    expect(loc.freshness, 'Live');
    expect(loc.latitude, closeTo(37.3349, 0.0001));
    expect(loc.longitude, closeTo(-122.009, 0.0001));

    final groupChat = Chat(guid: 'iMessage;+;chat123', chatIdentifier: 'chat123', style: 43);
    expect(controller.locationForChat(groupChat), isNull);

    final zeroChat = Chat(guid: 'iMessage;-;zero@icloud.com', chatIdentifier: 'zero@icloud.com', style: 45);
    expect(controller.locationForChat(zeroChat), isNull);

    controller.onClose();
  });

  test('sortFindMyFriends sorts pinned first and ascending Haversine distance within each group', () {
    // User in Berkeley (37.8715, -122.2730)
    const userLat = 37.8715;
    const userLng = -122.2730;

    final pinFar = _friend(
      handleAddress: 'pin-far@example.com',
      latitude: 37.7749,
      longitude: -122.4194, // San Francisco (~16km)
    );
    final pinNear = _friend(
      handleAddress: 'pin-near@example.com',
      latitude: 37.8720,
      longitude: -122.2725, // ~70m
    );
    final pinMissing = _friend(
      handleAddress: 'pin-missing@example.com',
      latitude: null,
      longitude: null,
    );
    final unpinFar = _friend(
      handleAddress: 'unpin-far@example.com',
      latitude: 37.3349,
      longitude: -122.0090, // Cupertino (~64km)
    );
    final unpinMid = _friend(
      handleAddress: 'unpin-mid@example.com',
      latitude: 37.8044,
      longitude: -122.2712, // Oakland (~7.5km)
    );
    final unpinMissing = _friend(
      handleAddress: 'unpin-missing@example.com',
      latitude: 0,
      longitude: 0,
    );

    final sorted = sortFindMyFriends(
      [unpinFar, pinFar, unpinMissing, pinMissing, unpinMid, pinNear],
      (f) => f.handleAddress!.startsWith('pin-'),
      userLatitude: userLat,
      userLongitude: userLng,
    );

    expect(sorted.map((f) => f.handleAddress).toList(), [
      'pin-near@example.com',
      'pin-far@example.com',
      'pin-missing@example.com',
      'unpin-mid@example.com',
      'unpin-far@example.com',
      'unpin-missing@example.com',
    ]);
  });

  test('formatFindMyFriendDistance marks Nearby ONLY <= 20m and formats miles otherwise', () {
    expect(kFindMyNearbyMeters, 20.0);
    expect(formatFindMyFriendDistance(null), '');
    expect(formatFindMyFriendDistance(-1), '');
    expect(formatFindMyFriendDistance(0), 'Nearby');
    expect(formatFindMyFriendDistance(19.9), 'Nearby');
    expect(formatFindMyFriendDistance(20.0), 'Nearby');
    expect(formatFindMyFriendDistance(20.1), '<0.1 mi');
    expect(formatFindMyFriendDistance(80.0), '<0.1 mi');
    expect(formatFindMyFriendDistance(100.1), '0.1 mi');
    expect(formatFindMyFriendDistance(2253.0), '1.4 mi'); // ~1.4 mi, same city is NOT Nearby
    expect(formatFindMyFriendDistance(56327.0), '35 mi');
  });

  test('granularity: city-only shortAddress triggers cached quiet reverse-geocode and surfaces street address', () async {
    var geocodeCalls = 0;
    final now = DateTime(2026, 11, 19, 12, 0);
    final controller = FindMyController(
      now: () => now,
      autoFetch: false,
      geocodeMinInterval: Duration.zero,
      reverseGeocodeRequest: (lat, lng) async {
        geocodeCalls++;
        return '2150 Shattuck Ave, Berkeley, CA';
      },
      fetchCurrentPosition: () async => Position(
        latitude: 37.8715,
        longitude: -122.2730,
        timestamp: now,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
      refreshFriendsRequest: ({String? handle, bool force = false, bool live = false, CancelToken? cancelToken}) async {
        return Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends'),
          statusCode: 200,
          data: {
            'data': [
              _friendJson(
                handle: '+15551234567',
                lat: 37.8698,
                lng: -122.2678,
                shortAddress: 'Berkeley, CA',
                longAddress: null,
                lastUpdatedMs: now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
                status: 'shallow',
              ),
            ],
          },
        );
      },
    );
    controller.onInit();
    await controller.ensureFriendsLoaded();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(hasStreetAddressLine('Berkeley, CA'), isFalse);
    expect(hasStreetAddressLine('2150 Shattuck Ave, Berkeley, CA'), isTrue);
    expect(geocodeCalls, 1);

    final friend = controller.friendsWithLocation.single;
    expect(controller.addressForFriend(friend, preferLong: true), '2150 Shattuck Ave, Berkeley, CA');

    final dmChat = Chat(guid: 'iMessage;-;+15551234567', chatIdentifier: '5551234567', style: 45);
    final chatLoc = controller.locationForChat(dmChat);
    expect(chatLoc, isNotNull);
    expect(chatLoc!.fullAddress, '2150 Shattuck Ave, Berkeley, CA');
    expect(chatLoc.isLive, isFalse);
    expect(chatLoc.freshness, '4m ago');
    expect(chatLoc.distanceLabel, isNotNull);
    expect(chatLoc.distanceLabel, isNot('Nearby'));
    expect(chatLoc.distanceLabel, endsWith(' mi'));

    controller.onClose();
  });

  test('handleNewFindMyLocation re-sorts reactively by pinned-first then Haversine distance', () async {
    final now = DateTime(2026, 11, 19, 12, 0);
    final controller = FindMyController(
      now: () => now,
      autoFetch: false,
      fetchCurrentPosition: () async => Position(
        latitude: 37.8715,
        longitude: -122.2730,
        timestamp: now,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
      refreshFriendsRequest: ({String? handle, bool force = false, bool live = false, CancelToken? cancelToken}) async {
        return Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends'),
          statusCode: 200,
          data: {
            'data': [
              _friendJson(
                handle: 'alice@icloud.com',
                lat: 37.8720,
                lng: -122.2725, // ~70m (closest initially)
                lastUpdatedMs: now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
                status: 'shallow',
              ),
              _friendJson(
                handle: 'bob@icloud.com',
                lat: 37.8044,
                lng: -122.2712, // ~7.5km
                lastUpdatedMs: now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
                status: 'shallow',
              ),
            ],
          },
        );
      },
    );
    controller.onInit();
    await controller.ensureFriendsLoaded();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.friendsWithLocation.map((f) => f.handleAddress).toList(), [
      'alice@icloud.com',
      'bob@icloud.com',
    ]);

    // Socket update moves Bob right next to the user (~15m)
    controller.handleNewFindMyLocation(_friendJson(
      handle: 'bob@icloud.com',
      lat: 37.8716,
      lng: -122.2730,
      lastUpdatedMs: now.millisecondsSinceEpoch,
      status: 'live',
    ));

    expect(controller.friendsWithLocation.map((f) => f.handleAddress).toList(), [
      'bob@icloud.com',
      'alice@icloud.com',
    ]);
    expect(controller.friendsWithLocation.first.isLiveFresh(now), isTrue);
    expect(controller.proximityLabelForFriend(controller.friendsWithLocation.first), 'Nearby');

    controller.onClose();
  });

  test('null or zero lastUpdated never fakes Just now and live is independent of age', () {
    final now = DateTime(2026, 11, 19, 12, 0);
    final nullTs = FindMyFriend.fromJson({
      'handle': 'a@icloud.com',
      'coordinates': [37.87, -122.27],
      'last_updated': null,
      'status': 'shallow',
    });
    final zeroTs = FindMyFriend.fromJson({
      'handle': 'b@icloud.com',
      'coordinates': [37.87, -122.27],
      'last_updated': 0,
      'status': 'shallow',
    });
    expect(nullTs.lastUpdated, isNull);
    expect(nullTs.displayFreshness(now), '');
    expect(nullTs.isLiveFresh(now), isFalse);
    expect(zeroTs.lastUpdated, isNull);
    expect(zeroTs.displayFreshness(now), '');

    // Old timestamp with status == 'shallow' is never Live; status == 'live' is Live
    final recentShallow = FindMyFriend.fromJson({
      'handle': 'c@icloud.com',
      'coordinates': [37.87, -122.27],
      'last_updated': now.subtract(const Duration(seconds: 10)).millisecondsSinceEpoch,
      'status': 'shallow',
    });
    expect(recentShallow.isLiveFresh(now), isFalse);
    expect(recentShallow.displayFreshness(now), 'Just now');

    final olderLiveStream = FindMyFriend.fromJson({
      'handle': 'd@icloud.com',
      'coordinates': [37.87, -122.27],
      'last_updated': now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
      'status': 'live',
      'is_live': true,
    });
    expect(olderLiveStream.isLiveFresh(now), isTrue);
    expect(olderLiveStream.displayFreshness(now), 'Live');

    // Server contract #91: locating_in_progress + structured street/city/state fallback
    final structuredFriend = FindMyFriend.fromJson({
      'handle': 'e@icloud.com',
      'coordinates': [37.87, -122.27],
      'long_address': null,
      'short_address': 'Berkeley, CA',
      'street': '2150 Shattuck Ave',
      'city': 'Berkeley',
      'state': 'CA',
      'last_updated': now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch,
      'status': 'shallow',
      'is_live': false,
      'locating_in_progress': true,
    });
    expect(structuredFriend.locatingInProgress, isTrue);
    expect(structuredFriend.longAddress, '2150 Shattuck Ave, Berkeley, CA');
    expect(structuredFriend.displayFreshness(now), 'Locating… · 3m ago');
  });
}

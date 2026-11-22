import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

FindMyFriend _friend({
  required String handleAddress,
  String? title,
  double? lat = 37.3346,
  double? lng = -122.0090,
  DateTime? lastUpdated,
  LocationStatus? status = LocationStatus.shallow,
  String? longAddress,
}) {
  return FindMyFriend(
    latitude: lat,
    longitude: lng,
    longAddress: longAddress,
    shortAddress: null,
    title: title,
    subtitle: null,
    handle: null,
    handleAddress: handleAddress,
    lastUpdated: lastUpdated ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
    status: status,
    locatingInProgress: false,
  );
}

void main() {
  group('deduplicateFindMyFriends', () {
    test('deduplicates shared ContactV2 phone and email, keeping phone identity and freshest location', () {
      final phillisContact = ContactV2(
        nativeContactId: 'contact-phillis',
        displayName: 'Phillis',
        addresses: ['+14155550199', 'xinyu32008@gmail.com'],
      );
      final olderPhone = _friend(
        handleAddress: '+14155550199',
        lat: 37.3300,
        lng: -122.0000,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        status: LocationStatus.shallow,
      );
      final newerEmail = _friend(
        handleAddress: 'xinyu32008@gmail.com',
        lat: 37.3346,
        lng: -122.0090,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(1700000060000),
        status: LocationStatus.live,
        longAddress: '1 Apple Park Way, Cupertino, CA',
      );

      final aliases = <String, String>{};
      final dropped = <String>{};
      final deduped = deduplicateFindMyFriends(
        [newerEmail, olderPhone],
        contactLookup: (addr) =>
            phillisContact.addresses.any((a) => findMyHandlesMatch(a, addr)) ? phillisContact : null,
        aliasToPrimaryIdOut: aliases,
        droppedStableIdsOut: dropped,
      );

      expect(deduped, hasLength(1));
      expect(deduped.single.handleAddress, '+14155550199');
      expect(deduped.single.latitude, 37.3346);
      expect(deduped.single.status, LocationStatus.live);
      expect(deduped.single.longAddress, '1 Apple Park Way, Cupertino, CA');
      expect(aliases['xinyu32008@gmail.com'], '+14155550199');
      expect(dropped, contains('xinyu32008@gmail.com'));
    });

    test('deduplicates unresolved email alias sharing identical GPS fix with named contact', () {
      final phillisContact = ContactV2(
        nativeContactId: 'contact-phillis',
        displayName: 'Phillis',
        addresses: ['+14155550199'],
      );
      final ts = DateTime.fromMillisecondsSinceEpoch(1700000100000);
      final phillisPhone = _friend(
        handleAddress: '+14155550199',
        lat: 37.334612,
        lng: -122.009045,
        lastUpdated: ts,
      );
      final phillisEmail = _friend(
        handleAddress: 'xinyu32008@gmail.com',
        lat: 37.334612,
        lng: -122.009045,
        lastUpdated: ts,
      );

      final deduped = deduplicateFindMyFriends(
        [phillisEmail, phillisPhone],
        contactLookup: (addr) =>
            phillisContact.addresses.any((a) => findMyHandlesMatch(a, addr)) ? phillisContact : null,
      );

      expect(deduped, hasLength(1));
      expect(deduped.single.handleAddress, '+14155550199');
    });

    test('does not merge two distinct named contacts who happen to be at the same location', () {
      final phillis = ContactV2(
        nativeContactId: 'contact-phillis',
        displayName: 'Phillis',
        addresses: ['+14155550199'],
      );
      final aaron = ContactV2(
        nativeContactId: 'contact-aaron',
        displayName: 'Aaron',
        addresses: ['+14155550188'],
      );
      final ts = DateTime.fromMillisecondsSinceEpoch(1700000100000);
      final deduped = deduplicateFindMyFriends(
        [
          _friend(handleAddress: '+14155550199', lat: 37.334612, lng: -122.009045, lastUpdated: ts),
          _friend(handleAddress: '+14155550188', lat: 37.334612, lng: -122.009045, lastUpdated: ts),
        ],
        contactLookup: (addr) {
          if (phillis.addresses.any((a) => findMyHandlesMatch(a, addr))) return phillis;
          if (aaron.addresses.any((a) => findMyHandlesMatch(a, addr))) return aaron;
          return null;
        },
      );

      expect(deduped, hasLength(2));
    });

    test('deduplicates unresolved email alias sharing sub-meter GPS fix with skewed timestamps', () {
      final aaron = ContactV2(
        nativeContactId: 'contact-aaron',
        displayName: 'Aaron Lee',
        addresses: ['+19499980689'],
      );
      final phoneFriend = _friend(
        handleAddress: '+19499980689',
        lat: 37.401647314348594,
        lng: -121.93249705406014,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(1795311430933),
      );
      final emailFriend = _friend(
        handleAddress: 'aaron68lee@gmail.com',
        lat: 37.401647276344946,
        lng: -121.93249700762715,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(1795310762210),
      );

      final deduped = deduplicateFindMyFriends(
        [emailFriend, phoneFriend],
        contactLookup: (addr) => aaron.addresses.any((a) => findMyHandlesMatch(a, addr)) ? aaron : null,
      );

      expect(deduped, hasLength(1));
      expect(deduped.single.handleAddress, '+19499980689');
      expect(deduped.single.lastUpdated?.millisecondsSinceEpoch, 1795311430933);
    });

    test('deduplicates separate server and native contacts sharing displayName across phone and email without coords', () {
      final serverContact = ContactV2(
        nativeContactId: 'server-phillis',
        displayName: 'Phillis',
        addresses: ['+14849834078'],
      );
      final nativeContact = ContactV2(
        nativeContactId: 'android-phillis',
        displayName: 'Phillis',
        addresses: ['xinyu32008@gmail.com'],
      );
      final phoneFriend = _friend(
        handleAddress: '+14849834078',
        lat: 37.3346,
        lng: -122.0090,
        status: LocationStatus.live,
      );
      final emailNoLocation = _friend(
        handleAddress: 'xinyu32008@gmail.com',
        lat: null,
        lng: null,
        lastUpdated: null,
        status: LocationStatus.legacy,
      );

      final deduped = deduplicateFindMyFriends(
        [emailNoLocation, phoneFriend],
        contactLookup: (addr) {
          if (findMyHandlesMatch(addr, '+14849834078')) return serverContact;
          if (findMyHandlesMatch(addr, 'xinyu32008@gmail.com')) return nativeContact;
          return null;
        },
      );

      expect(deduped, hasLength(1));
      expect(deduped.single.handleAddress, '+14849834078');
      expect(deduped.single.latitude, 37.3346);
    });
  });
}

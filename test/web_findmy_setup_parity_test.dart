import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_details/dialogs/address_picker.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/setup/pages/sync/server_credentials.dart';
import 'package:bluebubbles/database/global/findmy_friend.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/firebase/firebase_database_service.dart';
import 'package:flutter_test/flutter_test.dart';

FindMyFriend _friend({
  required double lat,
  required double lng,
  String? handleAddress,
}) =>
    FindMyFriend(
      latitude: lat,
      longitude: lng,
      longAddress: null,
      shortAddress: null,
      title: 'Alice',
      subtitle: null,
      handle: null,
      handleAddress: handleAddress,
      lastUpdated: DateTime(2026, 11, 18),
      status: LocationStatus.shallow,
      locatingInProgress: false,
      isOld: false,
    );

void main() {
  group('FindMy web reverse-geocoding', () {
    test('formatNominatimAddress prefers street, city, state and falls back to display_name', () {
      expect(
        formatNominatimAddress({
          'address': {
            'house_number': '1',
            'road': 'Apple Park Way',
            'city': 'Cupertino',
            'state': 'California',
          },
          'display_name': 'Fallback',
        }),
        '1 Apple Park Way, Cupertino, California',
      );
      expect(
        formatNominatimAddress({
          'address': {'town': 'Los Gatos', 'state': 'California'},
        }),
        'Los Gatos, California',
      );
      expect(
        formatNominatimAddress({'display_name': 'Cupertino, CA, USA'}),
        'Cupertino, CA, USA',
      );
    });

    test('resolveFriendAddress caches 4-decimal coordinate cells and throttles sequential requests', () async {
      var calls = 0;
      var currentTime = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(
        autoFetch: false,
        now: () => currentTime,
        geocodeMinInterval: const Duration(milliseconds: 30),
        reverseGeocodeRequest: (lat, lng) async {
          calls++;
          currentTime = currentTime.add(const Duration(milliseconds: 5));
          return '1 Apple Park Way, Cupertino, CA';
        },
      );

      final a = _friend(lat: 37.33491, lng: -122.00901, handleAddress: 'a@example.com');
      final b = _friend(lat: 37.33494, lng: -122.00904, handleAddress: 'b@example.com');
      final c = _friend(lat: 37.77490, lng: -122.41940, handleAddress: 'c@example.com');

      await Future.wait([
        controller.resolveFriendAddress(a),
        controller.resolveFriendAddress(b),
        controller.resolveFriendAddress(c),
      ]);

      expect(calls, 2);
      expect(controller.friendAddresses['a@example.com'], '1 Apple Park Way, Cupertino, CA');
      expect(controller.friendAddresses['b@example.com'], '1 Apple Park Way, Cupertino, CA');
      expect(controller.friendAddresses['c@example.com'], '1 Apple Park Way, Cupertino, CA');
      controller.onClose();
    });
  });

  group('Web OAuth clientId & Mixed-Content helpers', () {
    test('resolveGoogleWebClientId uses configured ID, known origins, or null on custom origins', () {
      expect(
        resolveGoogleWebClientId(
          configuredClientId: 'custom-client.apps.googleusercontent.com',
          debug: false,
          webOrigin: 'https://chat.jessfan.com/',
        ),
        'custom-client.apps.googleusercontent.com',
      );
      expect(
        resolveGoogleWebClientId(
          configuredClientId: '',
          debug: false,
          webOrigin: 'https://chat.jessfan.com/',
        ),
        isNull,
      );
      expect(
        resolveGoogleWebClientId(
          configuredClientId: '',
          debug: false,
          webOrigin: 'https://app.bluebubbles.app/',
        ),
        '500464701389-8trcdkcj7ni5l4dn6n7l795rhb1asnh3.apps.googleusercontent.com',
      );
    });

    test('mixed-content helpers flag http:// on https:// pages while allowing localhost/http pages', () {
      expect(
        shouldShowWebMixedContentHelp('http://192.168.1.10:1234', isWeb: true, pageScheme: 'https'),
        isTrue,
      );
      expect(
        isWebMixedContentBlocked('http://192.168.1.10:1234', isWeb: true, pageScheme: 'https'),
        isTrue,
      );
      expect(
        shouldShowWebMixedContentHelp('http://localhost:1234', isWeb: true, pageScheme: 'https'),
        isTrue,
      );
      expect(
        isWebMixedContentBlocked('http://localhost:1234', isWeb: true, pageScheme: 'https'),
        isFalse,
      );
      expect(
        isWebMixedContentBlocked('http://192.168.1.10:1234', isWeb: true, pageScheme: 'http'),
        isFalse,
      );
      expect(
        shouldShowWebMixedContentHelp('https://bb.jessfan.com', isWeb: true, pageScheme: 'https'),
        isFalse,
      );
    });
  });

  group('Web address picker intent launching', () {
    test('launchIntent launches tel:, mailto:, and web Meet calling without Permission.phone', () async {
      final launched = <Uri>[];
      final copied = <String>[];
      final snackbars = <String>[];
      Future<bool> fakeLaunch(Uri uri) async {
        launched.add(uri);
        return true;
      }

      await launchIntent(false, '+15551234567', isWeb: true, launchUrlFn: fakeLaunch);
      await launchIntent(
        true,
        '+15551234567',
        isWeb: true,
        isAndroidWebOverride: false,
        launchUrlFn: fakeLaunch,
        copyClipboardFn: (text) async => copied.add(text),
        showSnackbarFn: (title, message, {type = SnackbarType.info}) => snackbars.add('$title: $message'),
      );
      await launchIntent(false, 'alice@example.com', isWeb: true, launchUrlFn: fakeLaunch);

      expect(launched, [
        Uri(scheme: 'tel', path: '+15551234567'),
        Uri.parse('https://duo.google.com/'),
        Uri(scheme: 'mailto', path: 'alice@example.com'),
      ]);
      expect(copied, ['+15551234567']);
      expect(snackbars, ['Google Meet: Copied +15551234567 — paste in Google Meet to ring']);
    });
  });

  group('Cloudflare Pages web/_headers', () {
    test('allows cross-origin map tile referrer and disables stale caching for deferred JS parts', () {
      final file = File('web/_headers');
      expect(file.existsSync(), isTrue);
      final contents = file.readAsStringSync();
      expect(contents, contains('Referrer-Policy: strict-origin-when-cross-origin'));
      expect(contents, isNot(contains('Referrer-Policy: no-referrer')));
      expect(contents, contains('/main.dart.js_*.part.js\n  Cache-Control: no-cache'));
    });
  });
}

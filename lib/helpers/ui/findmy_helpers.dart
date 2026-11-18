import 'package:bluebubbles/database/global/findmy_device.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';

enum FindMyMapStyle {
  standard(
    label: 'Standard',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attributionText: 'OpenStreetMap contributors',
    attributionUrl: 'https://openstreetmap.org/copyright',
  ),
  satellite(
    label: 'Satellite',
    urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    attributionText: 'Esri World Imagery',
    attributionUrl: 'https://www.esri.com',
  ),
  dark(
    label: 'Dark',
    // Keyless OSM tiles + findMyDarkNavyColorFilter (CartoDB now requires an API key).
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attributionText: 'OpenStreetMap contributors',
    attributionUrl: 'https://openstreetmap.org/copyright',
  );

  final String label;
  final String urlTemplate;
  final String attributionText;
  final String attributionUrl;

  const FindMyMapStyle({
    required this.label,
    required this.urlTemplate,
    required this.attributionText,
    required this.attributionUrl,
  });
}

/// Preset decoy centers spread across continents for redacted mode
const _decoyCenters = <({double lat, double lng})>[
  (lat: 40.7829, lng: -73.9654), // New York
  (lat: 41.8781, lng: -87.6298), // Chicago
  (lat: 64.1466, lng: -21.9426), // Reykjavik
  (lat: -33.8688, lng: 151.2093), // Sydney
  (lat: 19.4326, lng: -99.1332), // Mexico City
  (lat: 35.6762, lng: 139.6503), // Tokyo
  (lat: -23.5505, lng: -46.6333), // São Paulo
  (lat: 28.6139, lng: 77.2090), // New Delhi
  (lat: 52.3676, lng: 4.9041), // Amsterdam
  (lat: -1.2921, lng: 36.8219), // Nairobi
];

/// Check for whether FindMy names and coordinates should be redacted or not
bool shouldRedactFindMyContactInfo() {
  if (!GetIt.I.isRegistered<SettingsService>()) return false;
  return SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideContactInfo.value;
}

int _stableHash(String input) => input.codeUnits.fold(0, (h, c) => (h * 31 + c) & 0x7fffffff);

/// Stable pseudo-random map point for [key]. Same key always maps to the same decoy location.
LatLng redactedFindMyPoint(String key) {
  final h1 = _stableHash(key);
  final h2 = _stableHash('$key-jitter');
  final center = _decoyCenters[h1 % _decoyCenters.length];
  // ±0.05° scatter (~5 km) so markers sharing a preset don't stack exactly.
  final latJitter = ((h2 % 1000) / 1000.0 - 0.5) * 0.1;
  final lngJitter = (((h2 ~/ 1000) % 1000) / 1000.0 - 0.5) * 0.1;
  return LatLng(center.lat + latJitter, center.lng + lngJitter);
}

/// Returns [redactedFindMyPoint] when contact info is hidden, otherwise the real coordinates.
LatLng resolveFindMyMarkerPoint({
  required String stableKey,
  required double latitude,
  required double longitude,
}) {
  if (shouldRedactFindMyContactInfo()) return redactedFindMyPoint(stableKey);
  return LatLng(latitude, longitude);
}

/// Single-line address from a reverse-geocoded [Placemark], in the spirit of the
/// addresses the legacy Find My payloads carried ("Street, City, ST").
String formatPlacemarkAddress(Placemark p) {
  String clean(String? s) => (s ?? "").trim();
  final street = [clean(p.subThoroughfare), clean(p.thoroughfare)].where((e) => e.isNotEmpty).join(" ");
  final city = clean(p.locality).isNotEmpty ? clean(p.locality) : clean(p.subLocality);
  final region = clean(p.administrativeArea);
  final cityState = [city, region].where((e) => e.isNotEmpty).join(", ");
  if (street.isNotEmpty && cityState.isNotEmpty) return "$street, $cityState";
  if (street.isNotEmpty) return street;
  if (cityState.isNotEmpty) return cityState;
  return [clean(p.name), clean(p.country)].where((e) => e.isNotEmpty).join(", ");
}

const Distance _findMyDistance = Distance();

/// Geodesic distance in meters between two map coordinates.
double distanceMetersBetween(LatLng a, LatLng b) {
  return _findMyDistance.as(LengthUnit.Meter, a, b);
}

/// Human-readable distance string (e.g. "240 m away", "3.4 km away").
String formatFindMyDistance(double meters) {
  if (!meters.isFinite || meters < 0) return "";
  if (meters < 50) return "With you";
  if (meters < 1000) return "${meters.round()} m away";
  final km = meters / 1000;
  if (km < 10) return "${km.toStringAsFixed(1)} km away";
  return "${km.round()} km away";
}

/// Formats battery percentage from FindMy payload (0..1 or 0..100), or null if unavailable.
String? formatFindMyBattery(double? level, {String? status}) {
  if (level == null || !level.isFinite || level <= 0) return null;
  final pct = (level <= 1.0 ? level * 100 : level).round().clamp(1, 100);
  if (status != null && status.toLowerCase() == 'charging') {
    return "$pct% · Charging";
  }
  return "$pct%";
}

/// Computes bounding box covering all non-empty points, or null if empty.
LatLngBounds? computeFindMyBounds(Iterable<LatLng> points) {
  final valid = points.where((p) => p.latitude.isFinite && p.longitude.isFinite && !(p.latitude == 0 && p.longitude == 0)).toList();
  if (valid.isEmpty) return null;
  final bounds = LatLngBounds.fromPoints(valid);
  if ((bounds.north - bounds.south).abs() < 1e-6 && (bounds.east - bounds.west).abs() < 1e-6) {
    const pad = 0.004;
    return LatLngBounds(
      LatLng((bounds.south - pad).clamp(-85.0, 85.0), (bounds.west - pad).clamp(-180.0, 180.0)),
      LatLng((bounds.north + pad).clamp(-85.0, 85.0), (bounds.east + pad).clamp(-180.0, 180.0)),
    );
  }
  return bounds;
}

/// Hue-preserving luminance inversion + navy tint turning keyless OSM tiles into dark Apple Find My palette.
const ColorFilter findMyDarkNavyColorFilter = ColorFilter.matrix(<double>[
  0.471, -1.173, -0.118, 0.0, 219.0,
  -0.349, -0.353, -0.118, 0.0, 225.0,
  -0.349, -1.173, 0.702, 0.0, 241.0,
  0.000, 0.000, 0.000, 1.0, 0.0,
]);

/// Whether dark navy/slate tile styling should be used for [style] and [brightness].
bool shouldApplyDarkMapFilter(FindMyMapStyle style, Brightness brightness) {
  return style == FindMyMapStyle.dark ||
      (style == FindMyMapStyle.standard && brightness == Brightness.dark);
}

/// Resolves tile URL for [style] and current theme [brightness].
String resolveFindMyTileUrl(FindMyMapStyle style, Brightness brightness) {
  if (shouldApplyDarkMapFilter(style, brightness)) {
    return FindMyMapStyle.dark.urlTemplate;
  }
  return style.urlTemplate;
}

/// Map canvas background color matching the active tile theme (prevents white flash).
Color resolveFindMyMapBackgroundColor(FindMyMapStyle style, Brightness brightness) {
  if (style == FindMyMapStyle.satellite) return const Color(0xFF0E141B);
  if (shouldApplyDarkMapFilter(style, brightness)) return const Color(0xFF141E2B);
  return const Color(0xFFE8ECEF);
}

/// Compact iOS-style proximity label ("With You", "Nearby", "35 mi").
String formatFindMyProximity(
  double? meters, {
  bool deviceWithYou = false,
  bool isThisDevice = false,
}) {
  if (isThisDevice) return "";
  if (deviceWithYou || (meters != null && meters.isFinite && meters >= 0 && meters < 60)) {
    return "With You";
  }
  if (meters == null || !meters.isFinite || meters < 0) return "";
  if (meters < 805) return "Nearby";
  final miles = meters / 1609.344;
  if (miles < 10) {
    final formatted = miles.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return "$formatted mi";
  }
  return "${miles.round()} mi";
}

/// Estimated travel time label for Directions pill button (e.g. "1 hr 22 min").
String formatFindMyEta(double? meters) {
  if (meters == null || !meters.isFinite || meters < 0) return "";
  if (meters < 150) return "1 min";
  final speedMps = meters < 2000 ? 8.0 : (meters < 25000 ? 13.5 : 21.2);
  final totalMins = (meters / speedMps / 60).round().clamp(1, 9999);
  if (totalMins < 60) return "$totalMins min";
  final hrs = totalMins ~/ 60;
  final rem = totalMins % 60;
  return rem == 0 ? "$hrs hr" : "$hrs hr $rem min";
}

/// Distinct Material 3 icon for Apple device categories (iPhone, MacBook, Mac Mini, iPad, AirPods, Watch).
IconData iconForFindMyDevice(FindMyDevice device) {
  final haystack = [
    device.deviceClass ?? '',
    device.rawDeviceModel ?? '',
    device.deviceModel ?? '',
    device.modelDisplayName ?? '',
    device.deviceDisplayName ?? '',
    device.name ?? '',
  ].join(' ').toLowerCase();

  if (haystack.contains('watch')) return Icons.watch;
  if (haystack.contains('airpod') ||
      haystack.contains('headphone') ||
      haystack.contains('beats') ||
      haystack.contains('earbud')) {
    return Icons.headphones;
  }
  if (haystack.contains('ipad') || haystack.contains('tablet')) return Icons.tablet_mac;
  if (haystack.contains('mac mini') ||
      haystack.contains('macmini') ||
      haystack.contains('mac studio') ||
      haystack.contains('mac pro') ||
      haystack.contains('macpro')) {
    return Icons.dns_rounded;
  }
  if (haystack.contains('macbook') || haystack.contains('laptop')) return Icons.laptop_mac;
  if (device.isConsideredAccessory == true || haystack.contains('airtag') || haystack.contains('b389')) {
    return Icons.sell_outlined;
  }
  if (device.isMac == true || haystack.contains('imac') || haystack.contains('mac')) {
    return Icons.desktop_mac;
  }
  return Icons.phone_iphone;
}


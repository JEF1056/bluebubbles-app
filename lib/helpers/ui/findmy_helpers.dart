import 'dart:math' as math;

import 'package:bluebubbles/database/global/findmy_device.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as maplibre;

const String findMyOpenFreeMapAttributionText = 'OpenFreeMap · OpenMapTiles · OpenStreetMap';
const String findMyOpenFreeMapAttributionUrl = 'https://openfreemap.org';
const String findMy3DBuildingsLayerId = 'findmy-buildings-3d';

enum FindMyMapStyle {
  standard(
    label: 'Standard',
    styleUrl: 'https://tiles.openfreemap.org/styles/liberty',
  ),
  bright(
    label: 'Bright',
    styleUrl: 'https://tiles.openfreemap.org/styles/bright',
  ),
  positron(
    label: 'Positron',
    styleUrl: 'https://tiles.openfreemap.org/styles/positron',
  ),
  dark(
    label: 'Dark',
    styleUrl: 'https://tiles.openfreemap.org/styles/dark',
  ),
  fiord(
    label: 'Fiord',
    styleUrl: 'https://tiles.openfreemap.org/styles/fiord',
  );

  final String label;
  final String styleUrl;

  String get attributionText => findMyOpenFreeMapAttributionText;
  String get attribution => findMyOpenFreeMapAttributionText;
  String get attributionUrl => findMyOpenFreeMapAttributionUrl;

  const FindMyMapStyle({
    required this.label,
    required this.styleUrl,
  });
}

/// Parses a persisted style name, falling back safely to [FindMyMapStyle.standard]
/// for unknown or legacy values (such as removed `'satellite'`).
FindMyMapStyle parseFindMyMapStyle(String? raw) {
  if (raw == null || raw.isEmpty) return FindMyMapStyle.standard;
  final normalized = raw.trim().toLowerCase();
  for (final style in FindMyMapStyle.values) {
    if (style.name == normalized) return style;
  }
  return FindMyMapStyle.standard;
}

/// Whether [style] and [brightness] resolve to a dark-themed map canvas.
bool isDarkFindMyMapStyle(FindMyMapStyle style, Brightness brightness) {
  return style == FindMyMapStyle.dark ||
      style == FindMyMapStyle.fiord ||
      (style == FindMyMapStyle.standard && brightness == Brightness.dark);
}

/// Resolves the live OpenFreeMap vector style JSON URL for [style] and [brightness].
String resolveFindMyStyleUrl(FindMyMapStyle style, Brightness brightness) {
  if (style == FindMyMapStyle.standard && brightness == Brightness.dark) {
    return FindMyMapStyle.dark.styleUrl;
  }
  return style.styleUrl;
}

/// Map canvas background color matching the active OpenFreeMap style (prevents flash).
Color resolveFindMyMapBackgroundColor(FindMyMapStyle style, Brightness brightness) {
  if (style == FindMyMapStyle.fiord) return const Color(0xFF45516E);
  if (style == FindMyMapStyle.dark || (style == FindMyMapStyle.standard && brightness == Brightness.dark)) {
    return const Color(0xFF0C0C0C);
  }
  if (style == FindMyMapStyle.positron) return const Color(0xFFF2F3F0);
  return const Color(0xFFF8F4F0);
}

/// Subtle 3D extruded building base tint matching the active OpenFreeMap style.
Color resolveFindMyBuildingExtrusionColor(FindMyMapStyle style, Brightness brightness) {
  if (style == FindMyMapStyle.fiord) return const Color(0xFF4F5D7D);
  if (style == FindMyMapStyle.dark || (style == FindMyMapStyle.standard && brightness == Brightness.dark)) {
    return const Color(0xFF222428);
  }
  if (style == FindMyMapStyle.positron) return const Color(0xFFE3E5E1);
  return const Color(0xFFE5DFD5);
}

/// Taller-structure 3D extruded building tint for subtle height-step shading.
Color resolveFindMyBuildingExtrusionTallColor(FindMyMapStyle style, Brightness brightness) {
  if (style == FindMyMapStyle.fiord) return const Color(0xFF5D6D91);
  if (style == FindMyMapStyle.dark || (style == FindMyMapStyle.standard && brightness == Brightness.dark)) {
    return const Color(0xFF2E3138);
  }
  if (style == FindMyMapStyle.positron) return const Color(0xFFD6D9D4);
  return const Color(0xFFD8D1C6);
}

double resolveFindMyBuildingExtrusionOpacity(FindMyMapStyle style, Brightness brightness) {
  if (style == FindMyMapStyle.fiord) return 0.84;
  if (style == FindMyMapStyle.dark || (style == FindMyMapStyle.standard && brightness == Brightness.dark)) {
    return 0.88;
  }
  if (style == FindMyMapStyle.positron) return 0.78;
  return 0.80;
}

String _toHexRgb(Color color) {
  final r = (color.r * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final g = (color.g * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final b = (color.b * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#$r$g$b';
}

/// Height-interpolated fill-extrusion color expression for [style] and [brightness].
maplibre.Expression<Color> buildFindMy3DExtrusionColorExpression(
  FindMyMapStyle style,
  Brightness brightness,
) {
  final baseHex = _toHexRgb(resolveFindMyBuildingExtrusionColor(style, brightness));
  final tallHex = _toHexRgb(resolveFindMyBuildingExtrusionTallColor(style, brightness));
  return maplibre.Expression<Color>.raw([
    'interpolate',
    ['linear'],
    ['coalesce', ['get', 'render_height'], 0],
    0,
    baseHex,
    45,
    tallHex,
  ]);
}

bool isFindMyBuildingFillLayer({required String id, required String type, String? sourceLayer}) {
  if (type != 'fill') return false;
  if (sourceLayer == 'building') return true;
  final lower = id.toLowerCase();
  return lower == 'building' || lower == 'building-top' || lower.startsWith('building-');
}

bool _isFindMyInfraLayer({required String id, required String type, String? sourceLayer}) {
  if (type == 'symbol' || type == 'background') return false;
  if (sourceLayer == 'building' || sourceLayer == 'transportation' || sourceLayer == 'aeroway') {
    return true;
  }
  final lower = id.toLowerCase();
  return lower.contains('building') ||
      lower.contains('road') ||
      lower.contains('highway') ||
      lower.contains('bridge') ||
      lower.contains('tunnel') ||
      lower.contains('rail') ||
      lower.contains('aeroway') ||
      lower.contains('cablecar') ||
      lower.contains('ferry') ||
      lower.contains('pier') ||
      lower.contains('runway') ||
      lower.contains('taxiway') ||
      lower.contains('apron');
}

/// Picks the first symbol layer ID after all building and road/rail/aeroway layers
/// so 3D buildings render above flat footprints/roads and below map labels.
String? resolveFindMy3DAnchorLayerId(
  List<({String id, String type, String? sourceLayer})> layers,
) {
  int lastInfraIdx = -1;
  for (int i = 0; i < layers.length; i++) {
    final l = layers[i];
    if (_isFindMyInfraLayer(id: l.id, type: l.type, sourceLayer: l.sourceLayer)) {
      lastInfraIdx = i;
    }
  }
  for (int i = lastInfraIdx + 1; i < layers.length; i++) {
    if (layers[i].type == 'symbol') return layers[i].id;
  }
  return null;
}

maplibre.Geographic toGeographic(LatLng point) =>
    maplibre.Geographic(lon: point.longitude, lat: point.latitude);

LatLng fromGeographic(maplibre.Geographic point) => LatLng(point.lat, point.lon);

/// Lightweight geographic bounding box independent of raster map plugins.
class FindMyBounds {
  final LatLng southWest;
  final LatLng northEast;

  const FindMyBounds(this.southWest, this.northEast);

  double get south => southWest.latitude;
  double get west => southWest.longitude;
  double get north => northEast.latitude;
  double get east => northEast.longitude;

  LatLng get center => LatLng((south + north) / 2.0, (west + east) / 2.0);

  bool contains(LatLng point) =>
      point.latitude >= south &&
      point.latitude <= north &&
      point.longitude >= west &&
      point.longitude <= east;

  maplibre.GeoBox toGeoBox() => maplibre.GeoBox(west: west, south: south, east: east, north: north);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FindMyBounds && other.southWest == southWest && other.northEast == northEast;

  @override
  int get hashCode => Object.hash(southWest, northEast);
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
FindMyBounds? computeFindMyBounds(Iterable<LatLng> points) {
  final valid = points
      .where((p) => p.latitude.isFinite && p.longitude.isFinite && !(p.latitude == 0 && p.longitude == 0))
      .toList();
  if (valid.isEmpty) return null;
  var south = valid.first.latitude;
  var north = valid.first.latitude;
  var west = valid.first.longitude;
  var east = valid.first.longitude;
  for (final p in valid.skip(1)) {
    if (p.latitude < south) south = p.latitude;
    if (p.latitude > north) north = p.latitude;
    if (p.longitude < west) west = p.longitude;
    if (p.longitude > east) east = p.longitude;
  }
  if ((north - south).abs() < 1e-6 && (east - west).abs() < 1e-6) {
    const pad = 0.004;
    return FindMyBounds(
      LatLng((south - pad).clamp(-85.0, 85.0), (west - pad).clamp(-180.0, 180.0)),
      LatLng((north + pad).clamp(-85.0, 85.0), (east + pad).clamp(-180.0, 180.0)),
    );
  }
  return FindMyBounds(LatLng(south, west), LatLng(north, east));
}

/// Generates a closed spherical geodesic circle ring around [center] with [radiusMeters].
List<LatLng> buildGeodesicCircleRing(
  LatLng center,
  double radiusMeters, {
  int segments = 48,
}) {
  final safeSegments = segments.clamp(12, 128);
  final safeRadius = radiusMeters.clamp(1.0, 500000.0);
  const earthRadiusMeters = 6371000.0;
  final angularDist = safeRadius / earthRadiusMeters;
  final lat1 = center.latitude * math.pi / 180.0;
  final lon1 = center.longitude * math.pi / 180.0;
  final sinLat1 = math.sin(lat1);
  final cosLat1 = math.cos(lat1);
  final sinAng = math.sin(angularDist);
  final cosAng = math.cos(angularDist);

  final ring = <LatLng>[];
  for (var i = 0; i < safeSegments; i++) {
    final bearing = (2.0 * math.pi * i) / safeSegments;
    final sinLat2 = sinLat1 * cosAng + cosLat1 * sinAng * math.cos(bearing);
    final lat2 = math.asin(sinLat2.clamp(-1.0, 1.0));
    final lon2 = lon1 +
        math.atan2(
          math.sin(bearing) * sinAng * cosLat1,
          cosAng - sinLat1 * sinLat2,
        );
    final latDeg = (lat2 * 180.0 / math.pi).clamp(-85.05112878, 85.05112878);
    var lonDeg = lon2 * 180.0 / math.pi;
    while (lonDeg > 180.0) {
      lonDeg -= 360.0;
    }
    while (lonDeg < -180.0) {
      lonDeg += 360.0;
    }
    ring.add(LatLng(latDeg, lonDeg));
  }
  ring.add(ring.first);
  return ring;
}

/// Builds a ground-plane GeoJSON polygon feature for MapLibre [PolygonLayer].
maplibre.Feature<maplibre.Polygon> buildFindMyAccuracyFeature(
  LatLng center,
  double radiusMeters, {
  bool selected = false,
  int segments = 48,
}) {
  final ring = buildGeodesicCircleRing(center, radiusMeters, segments: segments);
  return maplibre.Feature<maplibre.Polygon>(
    geometry: maplibre.Polygon([
      maplibre.PositionSeries.from([
        for (final p in ring) maplibre.Geographic(lon: p.longitude, lat: p.latitude),
      ]),
    ]),
    properties: <String, Object?>{
      'selected': selected,
    },
  );
}

double _mercatorX(double lonDeg) => (lonDeg + 180.0) / 360.0;

double _mercatorY(double latDeg) {
  final clamped = latDeg.clamp(-85.05112878, 85.05112878);
  final sinLat = math.sin(clamped * math.pi / 180.0);
  return 0.5 - math.log((1.0 + sinLat) / (1.0 - sinLat)) / (4.0 * math.pi);
}

double _inverseMercatorX(double x) => x * 360.0 - 180.0;

double _inverseMercatorY(double y) {
  final n = math.pi - 2.0 * math.pi * y;
  return (180.0 / math.pi) * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}

/// Computes Web Mercator fit camera center & zoom accounting for overlay [padding].
({LatLng center, double zoom}) computeFindMyFitCamera(
  FindMyBounds bounds,
  Size viewportSize,
  EdgeInsets padding, {
  double maxZoom = 15.0,
  double minZoom = 1.0,
}) {
  const tileSize = 512.0;
  final usableW = math.max(16.0, viewportSize.width - padding.left - padding.right);
  final usableH = math.max(16.0, viewportSize.height - padding.top - padding.bottom);

  final x0 = _mercatorX(bounds.west);
  final x1 = _mercatorX(bounds.east);
  final y0 = _mercatorY(bounds.north);
  final y1 = _mercatorY(bounds.south);

  final dx = math.max(1e-7, (x1 - x0).abs());
  final dy = math.max(1e-7, (y1 - y0).abs());

  final zoomX = math.log(usableW / (tileSize * dx)) / math.ln2;
  final zoomY = math.log(usableH / (tileSize * dy)) / math.ln2;
  final zoom = math.min(zoomX, zoomY).clamp(minZoom, maxZoom);

  final scale = tileSize * math.pow(2.0, zoom);
  final midX = (x0 + x1) * 0.5;
  final midY = (y0 + y1) * 0.5;

  // MapLibre camera center is at the center of the padded box; shift raw world
  // midpoint opposite the asymmetric padding offset so the unpadded center lands
  // in the center of the visible area.
  final shiftPxX = (padding.left - padding.right) * 0.5;
  final shiftPxY = (padding.top - padding.bottom) * 0.5;
  final centerX = (midX - shiftPxX / scale).clamp(0.0, 1.0);
  final centerY = (midY - shiftPxY / scale).clamp(0.0, 1.0);

  return (
    center: LatLng(_inverseMercatorY(centerY), _inverseMercatorX(centerX)),
    zoom: zoom,
  );
}

/// Projects [point] to screen pixels inside [viewportSize] using Web Mercator math
/// (used for headless test verification and unsupported-platform fallback).
Offset projectLatLngToScreenOffset(
  LatLng point, {
  required Size viewportSize,
  required LatLng center,
  required double zoom,
  EdgeInsets padding = EdgeInsets.zero,
  double bearingDegrees = 0.0,
}) {
  const tileSize = 512.0;
  final scale = tileSize * math.pow(2.0, zoom);
  final dx = (_mercatorX(point.longitude) - _mercatorX(center.longitude)) * scale;
  final dy = (_mercatorY(point.latitude) - _mercatorY(center.latitude)) * scale;
  final originX = viewportSize.width * 0.5 + (padding.left - padding.right) * 0.5;
  final originY = viewportSize.height * 0.5 + (padding.top - padding.bottom) * 0.5;
  if (bearingDegrees == 0.0) {
    return Offset(originX + dx, originY + dy);
  }
  final rad = -bearingDegrees * math.pi / 180.0;
  final cosB = math.cos(rad);
  final sinB = math.sin(rad);
  return Offset(
    originX + dx * cosB - dy * sinB,
    originY + dx * sinB + dy * cosB,
  );
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

/// Distinct Material 3 icon for Apple, Google, and Samsung Find My device categories.
IconData iconForFindMyDevice(FindMyDevice device) {
  final category = (device.iconCategory ?? '').trim().toLowerCase();
  final isAppleProvider = device.trackerProvider == null;
  switch (category) {
    case 'watch':
    case 'smartwatch':
      return Icons.watch;
    case 'earbuds':
    case 'headphones':
    case 'headset':
    case 'audio':
    case 'airpods':
      return Icons.headphones;
    case 'ipad':
      return Icons.tablet_mac;
    case 'tablet':
      return isAppleProvider ? Icons.tablet_mac : Icons.tablet_android;
    case 'mac_mini':
    case 'macmini':
    case 'mac_studio':
    case 'mac_pro':
    case 'server':
      return Icons.dns_rounded;
    case 'laptop':
    case 'macbook':
      return Icons.laptop_mac;
    case 'desktop':
    case 'imac':
      return Icons.desktop_mac;
    case 'tag':
    case 'tracker':
    case 'airtag':
    case 'smarttag':
    case 'accessory':
    case 'item':
      return Icons.sell_outlined;
    case 'speaker':
    case 'homepod':
      return Icons.speaker_rounded;
    case 'tv':
    case 'appletv':
      return Icons.tv_rounded;
    case 'phone':
    case 'smartphone':
    case 'iphone':
      return isAppleProvider ? Icons.phone_iphone : Icons.phone_android;
    case 'android':
      return Icons.phone_android;
  }

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
      haystack.contains('buds') ||
      haystack.contains('earbud')) {
    return Icons.headphones;
  }
  if (haystack.contains('ipad')) return Icons.tablet_mac;
  if (haystack.contains('tablet') || haystack.contains('galaxy tab')) return Icons.tablet_android;
  if (haystack.contains('mac mini') ||
      haystack.contains('macmini') ||
      haystack.contains('mac studio') ||
      haystack.contains('mac pro') ||
      haystack.contains('macpro')) {
    return Icons.dns_rounded;
  }
  if (haystack.contains('macbook') || haystack.contains('laptop')) return Icons.laptop_mac;
  if (device.isConsideredAccessory == true ||
      haystack.contains('airtag') ||
      haystack.contains('smarttag') ||
      haystack.contains('tracker') ||
      haystack.contains('b389')) {
    return Icons.sell_outlined;
  }
  if (device.isMac == true || haystack.contains('imac') || haystack.contains('mac')) {
    return Icons.desktop_mac;
  }
  if (device.trackerProvider != null ||
      haystack.contains('android') ||
      haystack.contains('pixel') ||
      haystack.contains('galaxy')) {
    return Icons.phone_android;
  }
  return Icons.phone_iphone;
}

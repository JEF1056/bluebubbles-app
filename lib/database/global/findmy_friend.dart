import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show HandleLookupKey;
import 'package:bluebubbles/services/backend/actions/contact_v2_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/string_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

enum LocationStatus { legacy, shallow, live }

Handle? findHandleForAddress(String? address) {
  if (address == null || address.isEmpty) return null;
  try {
    // 1. iMessage
    var h = Handle.findOne(addressAndService: HandleLookupKey(address, "iMessage"));
    if (h != null) return h;
    // 2. SMS
    h = Handle.findOne(addressAndService: HandleLookupKey(address, "SMS"));
    if (h != null) return h;
    // 3. normalized phone
    final clean = cleansePhoneNumber(address);
    if (clean.isNotEmpty && clean != address) {
      h = Handle.findOne(addressAndService: HandleLookupKey(clean, "iMessage")) ??
          Handle.findOne(addressAndService: HandleLookupKey(clean, "SMS"));
      if (h != null) return h;
    }
  } catch (_) {}
  return null;
}

String resolveFriendDisplayName({
  Handle? handle,
  String? handleAddress,
  String? title,
  bool hideContactInfo = false,
  @visibleForTesting Iterable<ContactV2>? contactsOverride,
}) {
  if (hideContactInfo) {
    final handleState = handle != null ? HandleSvc.getOrCreateHandleState(handle) : null;
    return handleState?.fakeName ?? 'Contact';
  }

  // 1. Resolve via Handle (iMessage + SMS / normalized phone)
  final rawAddress = handleAddress ?? handle?.address ?? (title != null && (title.contains('@') || cleansePhoneNumber(title).length >= 7) ? title : null);
  final rawHandle = handle ?? (rawAddress != null ? findHandleForAddress(rawAddress) : null);
  final resolvedHandle = (contactsOverride == null &&
          rawHandle?.id != null &&
          GetIt.I.isRegistered<HandleService>())
      ? (HandleSvc.getHandleState(rawHandle!.id!)?.handle ?? rawHandle)
      : rawHandle;
  if (resolvedHandle != null && resolvedHandle.contactsV2.isNotEmpty) {
    final name = resolvedHandle.displayName;
    if (name.isNotEmpty && name != resolvedHandle.address) {
      return name;
    }
  }

  // 2. Device / server contacts (symmetric phone-variant & email matching, prefers contacts with avatars)
  if (rawAddress != null && rawAddress.isNotEmpty) {
    try {
      final ContactV2? matched = contactsOverride != null
          ? ContactV2Actions.matchContactForAddress(contactsOverride, rawAddress)
          : (GetIt.I.isRegistered<ContactServiceV2>()
              ? ContactsSvcV2.findContactForAddressSync(rawAddress)
              : ContactV2Actions.matchContactForAddress(Database.contactsV2.getAll(), rawAddress));
      if (matched != null) {
        final cName = matched.displayName.isNotEmpty ? matched.displayName : matched.computedDisplayName;
        if (cName.isNotEmpty) return cName;
      }
    } catch (_) {}
  }

  // 3. item.title (if non-empty and not "Unknown Friend")
  if (title != null && title.trim().isNotEmpty && title.trim() != "Unknown Friend") {
    return title.trim();
  }

  // 4. Formatted item.handleAddress (never "Unknown Friend" when handleAddress exists)
  if (rawAddress != null && rawAddress.trim().isNotEmpty) {
    if (rawAddress.contains('@')) {
      return rawAddress.trim();
    }
    final formatted = formatPhoneNumber(rawAddress.trim());
    return formatted.isNotEmpty ? formatted : rawAddress.trim();
  }

  return "Unknown Friend";
}

String formatFindMyRelativeTime(DateTime timestamp, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(timestamp);
  if (diff.inSeconds < 60) return "Just now";
  if (diff.inMinutes < 60) return "${diff.inMinutes}m ago";
  if (diff.inHours < 24) return "${diff.inHours}h ago";
  return "${diff.inDays}d ago";
}

String formatFindMyFreshness({
  required bool isLiveFresh,
  required bool locatingInProgress,
  required bool isOld,
  required DateTime? lastUpdated,
  DateTime? now,
}) {
  if (locatingInProgress) return "Locating...";
  if (isLiveFresh) return "Live";
  if (lastUpdated != null) {
    final rel = formatFindMyRelativeTime(lastUpdated, now: now);
    return isOld ? "Old · $rel" : rel;
  }
  if (isOld) return "Old";
  return "";
}

class FindMyFriend {
  FindMyFriend({
    required this.latitude,
    required this.longitude,
    required this.longAddress,
    required this.shortAddress,
    required this.title,
    required this.subtitle,
    required this.handle,
    required this.handleAddress,
    required this.lastUpdated,
    required this.status,
    required this.locatingInProgress,
    this.horizontalAccuracy,
    this.verticalAccuracy,
    this.speed,
    this.altitude,
    this.isOld = false,
    this.isInaccurate = false,
    this.locationFinished,
  });

  final double? latitude;
  final double? longitude;
  final String? longAddress;
  final String? shortAddress;
  final String? title;
  final String? subtitle;
  final Handle? handle;
  // Raw address from the server — stable even when handle is not in the local DB.
  final String? handleAddress;
  final DateTime? lastUpdated;
  final LocationStatus? status;
  final bool locatingInProgress;
  final double? horizontalAccuracy;
  final double? verticalAccuracy;
  final double? speed;
  final double? altitude;
  final bool isOld;
  final bool isInaccurate;
  final bool? locationFinished;

  bool get isLocatingInProgress => locatingInProgress;
  int? get timeStamp => lastUpdated?.millisecondsSinceEpoch;

  /// Stable identifier for matching and map marker keys.
  /// Prefers the hydrated handle key; falls back to the raw server address.
  String? get stableId => handle?.uniqueAddressAndService ?? handleAddress;

  bool isLiveFresh([DateTime? now]) {
    if (status != LocationStatus.live || isOld || lastUpdated == null) return false;
    return (now ?? DateTime.now()).difference(lastUpdated!) < const Duration(seconds: 60);
  }

  String displayFreshness([DateTime? now]) => formatFindMyFreshness(
        isLiveFresh: isLiveFresh(now),
        locatingInProgress: locatingInProgress,
        isOld: isOld,
        lastUpdated: lastUpdated,
        now: now,
      );

  String resolveDisplayName({bool hideContactInfo = false}) => resolveFriendDisplayName(
        handle: handle,
        handleAddress: handleAddress,
        title: title,
        hideContactInfo: hideContactInfo,
      );

  factory FindMyFriend.fromJson(Map<String, dynamic> json) {
    final rawTs = json["last_updated"] ?? json["timeStamp"] ?? json["timestamp"] ?? 0;
    final tsMs = rawTs is num ? rawTs.toInt() : 0;
    final rawHandle = json["handle"] is String
        ? json["handle"] as String
        : (json["handle"] is Map ? (json["handle"]["address"] as String?) : null);
    final rawAddress = rawHandle ?? (json["title"] as String?);
    return FindMyFriend(
      latitude: (json["coordinates"]?[0] as num?)?.toDouble(),
      longitude: (json["coordinates"]?[1] as num?)?.toDouble(),
      longAddress: json["long_address"],
      shortAddress: json["short_address"],
      title: json["title"],
      subtitle: json["subtitle"],
      handleAddress: rawAddress,
      handle: findHandleForAddress(rawAddress),
      lastUpdated: tsMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(tsMs),
      status: LocationStatus.values.firstWhereOrNull((e) => e.name == json["status"]),
      locatingInProgress: json["is_locating_in_progress"] ?? json["isLocatingInProgress"] ?? false,
      horizontalAccuracy: ((json["horizontalAccuracy"] ?? json["horizontal_accuracy"]) as num?)?.toDouble(),
      verticalAccuracy: ((json["verticalAccuracy"] ?? json["vertical_accuracy"]) as num?)?.toDouble(),
      speed: (json["speed"] as num?)?.toDouble(),
      altitude: (json["altitude"] as num?)?.toDouble(),
      isOld: json["isOld"] ?? json["is_old"] ?? false,
      isInaccurate: json["isInaccurate"] ?? json["is_inaccurate"] ?? false,
      locationFinished: json["locationFinished"] ?? json["location_finished"],
    );
  }

  Map<String, dynamic> toJson() => {
        "coordinates": [latitude, longitude],
        "long_address": longAddress,
        "short_address": shortAddress,
        "title": title,
        "subtitle": subtitle,
        "handle": handle?.toMap(),
        "last_updated": lastUpdated == null ? null : DateFormat("MMMM d, yyyy h:mm:ss a").format(lastUpdated!),
        "status": status?.name,
        "locating_in_progress": locatingInProgress,
        "horizontal_accuracy": horizontalAccuracy,
        "vertical_accuracy": verticalAccuracy,
        "speed": speed,
        "altitude": altitude,
        "is_old": isOld,
        "is_inaccurate": isInaccurate,
        "location_finished": locationFinished,
      };
}

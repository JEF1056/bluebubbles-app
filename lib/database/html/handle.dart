import 'package:bluebubbles/database/html/contact_v2.dart';
import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show HandleLookupKey;
import 'package:bluebubbles/services/backend/interfaces/handle_interface.dart';
import 'package:collection/collection.dart';
import 'package:dice_bear/dice_bear.dart';
import 'package:faker/faker.dart';
import 'package:flutter/widgets.dart';

class Handle {
  int? id;
  int? originalROWID;
  String uniqueAddressAndService;
  String address;
  String? formattedAddress;
  String service;
  String? country;
  String? defaultEmail;
  String? defaultPhone;
  final String fakeName = faker.person.name();

  String? color;

  final contactsV2 = ToMany<ContactV2>();

  Widget? _fakeAvatar;

  Widget get fakeAvatar {
    if (_fakeAvatar != null) return _fakeAvatar!;
    final backgroundColor = randomAvatarBackgroundColors.randomChoice();

    Avatar _avatar = DiceBearBuilder(
      seed: address,
      sprite: DiceBearStyle.miniavs,
      backgroundColor: HexColor(backgroundColor),
    ).build();
    _fakeAvatar = _avatar.toImage();
    return _fakeAvatar!;
  }

  String get displayName {
    if (address.startsWith("urn:biz")) return "Business";
    if (contactsV2.isNotEmpty) {
      final firstNativeContact = contactsV2.where((c) => c.isNative).firstOrNull;
      final nativeNickname = firstNativeContact?.nickname;
      if (!isNullOrEmpty(nativeNickname)) return nativeNickname!;

      final nativeDisplayName = firstNativeContact?.displayName;
      if (!isNullOrEmpty(nativeDisplayName)) return nativeDisplayName!;

      final computedDisplayName = contactsV2.first.computedDisplayName;
      if (!isNullOrEmpty(computedDisplayName)) return computedDisplayName;
    }
    return address.contains("@") ? address : (formattedAddress ?? formatPhoneNumber(address));
  }

  String get reactionDisplayName {
    if (address.startsWith("urn:biz")) return "Business";
    if (contactsV2.isNotEmpty) {
      final firstNativeContact = contactsV2.where((c) => c.isNative).firstOrNull;
      final nativeNickname = firstNativeContact?.nickname;
      if (!isNullOrEmpty(nativeNickname)) return nativeNickname!;

      final nativeFirstName = firstNativeContact?.firstName;
      if (!isNullOrEmpty(nativeFirstName)) return nativeFirstName!;

      final nativeComputedDisplayName = firstNativeContact?.computedDisplayName;
      if (!isNullOrEmpty(nativeComputedDisplayName)) return nativeComputedDisplayName!;

      final computedDisplayName = contactsV2.first.computedDisplayName;
      if (!isNullOrEmpty(computedDisplayName)) return computedDisplayName;
    }
    return address.contains("@") ? address : (formattedAddress ?? address);
  }

  String get shortName {
    return contactsV2.isNotEmpty ? reactionDisplayName.firstWord : reactionDisplayName;
  }

  String? get initials {
    if (address.startsWith("urn:biz")) return null;
    if (contactsV2.isNotEmpty) {
      final contactV2Initials = contactsV2.first.initials;
      if (contactV2Initials != null) return contactV2Initials;
    }
    final parts = displayName.trim().split(RegExp(r'[ \-_]'));
    if (parts.length == 1) return parts[0].firstAlpha?.toUpperCase();

    final firstPart = (parts.first.firstAlpha ?? '').toUpperCase();
    final lastPart = (parts.last.firstAlpha ?? '').toUpperCase();

    return (firstPart + lastPart).isEmpty ? null : firstPart + lastPart;
  }

  Handle({
    this.id,
    this.originalROWID,
    this.address = "",
    this.formattedAddress,
    this.service = "iMessage",
    this.uniqueAddressAndService = "",
    this.country,
    this.color,
    this.defaultEmail,
    this.defaultPhone,
  }) {
    if (service.isEmpty) {
      service = 'iMessage';
    }
    if (uniqueAddressAndService.isEmpty) {
      uniqueAddressAndService = "$address/$service";
    }
  }

  factory Handle.fromMap(Map<String, dynamic> json) => Handle(
        id: json["ROWID"] ?? json["id"],
        originalROWID: json["originalROWID"] ?? json["ROWID"],
        address: json["address"],
        formattedAddress: json["formattedAddress"],
        service: json["service"] ?? "iMessage",
        uniqueAddressAndService: json["uniqueAddrAndService"] ?? "${json["address"]}/${json["service"] ?? "iMessage"}",
        country: json["country"],
        color: json["color"],
        defaultPhone: json["defaultPhone"],
        defaultEmail: json["defaultEmail"],
      );

  Future<void> updateFormattedAddress() async {
    if (!isNullOrEmpty(formattedAddress)) return;

    if (address.contains('@') || address.startsWith('urn:biz')) {
      formattedAddress = address;
    } else {
      formattedAddress = formatPhoneNumber(address);
    }
  }

  Handle save({bool updateColor = false, matchOnOriginalROWID = false}) {
    HtmlDatabase.runInTransaction(TxMode.write, () {
      Handle? existing;
      if (matchOnOriginalROWID) {
        existing = Handle.findOne(originalROWID: originalROWID);
      } else {
        existing = Handle.findOne(addressAndService: HandleLookupKey(address, service));
      }

      if (existing != null) {
        id = existing.id;
        originalROWID ??= existing.originalROWID;
      }
      if (!updateColor) {
        color = existing?.color ?? color;
      }
      try {
        id = HtmlDatabase.handles.put(this);
      } on UniqueViolationException catch (_) {}
    });
    return this;
  }

  Future<Handle> saveAsync({bool updateColor = false, matchOnOriginalROWID = false}) async {
    final savedHandle = await HandleInterface.saveHandleAsync(
      handleData: toMap(),
      updateColor: updateColor,
      matchOnOriginalROWID: matchOnOriginalROWID,
    );

    id = savedHandle.id;
    color = savedHandle.color;
    originalROWID = savedHandle.originalROWID;
    return this;
  }

  static List<Handle> bulkSave(List<Handle> handles, {matchOnOriginalROWID = false}) {
    HtmlDatabase.runInTransaction(TxMode.write, () {
      for (Handle h in handles) {
        Handle? existing;
        if (matchOnOriginalROWID) {
          existing = Handle.findOne(originalROWID: h.originalROWID);
        } else {
          existing = Handle.findOne(addressAndService: HandleLookupKey(h.address, h.service));
        }

        if (existing != null) {
          h.id = existing.id;
          h.originalROWID ??= existing.originalROWID;
        }
      }

      final insertedIds = HtmlDatabase.handles.putMany(handles);
      for (int i = 0; i < insertedIds.length; i++) {
        handles[i].id = insertedIds[i];
      }
    });
    return handles;
  }

  static Future<List<Handle>> bulkSaveAsync(List<Handle> handles, {matchOnOriginalROWID = false}) async {
    if (handles.isEmpty) return handles;

    final savedHandles = await HandleInterface.bulkSaveHandlesAsync(
      handlesData: handles.map((e) => e.toMap()).toList(),
      matchOnOriginalROWID: matchOnOriginalROWID,
    );

    for (int i = 0; i < handles.length; i++) {
      if (i < savedHandles.length) {
        handles[i].id = savedHandles[i].id;
        handles[i].color = savedHandles[i].color;
        handles[i].originalROWID = savedHandles[i].originalROWID;
      }
    }
    return handles;
  }

  static void delete(int id) {
    HtmlDatabase.runInTransaction(TxMode.write, () {
      HtmlDatabase.handles.remove(id);
    });
  }

  Handle updateColor(String? newColor) {
    color = newColor;
    save();
    return this;
  }

  Handle updateDefaultPhone(String newPhone) {
    defaultPhone = newPhone;
    save();
    return this;
  }

  Handle updateDefaultEmail(String newEmail) {
    defaultEmail = newEmail;
    save();
    return this;
  }

  static Handle? findOne({int? id, int? originalROWID, HandleLookupKey? addressAndService}) {
    if (id == 0) return null;
    if (id != null) {
      final handle = HtmlDatabase.handles.get(id) ?? Handle.findOne(originalROWID: id);
      return handle;
    } else if (originalROWID != null) {
      final query = HtmlDatabase.handles.query(Handle_.originalROWID.equals(originalROWID)).build();
      query.limit = 1;
      final result = query.findFirst();
      query.close();
      return result;
    } else if (addressAndService != null) {
      final query = HtmlDatabase.handles
          .query(Handle_.address.equals(addressAndService.address) & Handle_.service.equals(addressAndService.service))
          .build();
      query.limit = 1;
      final result = query.findFirst();
      query.close();
      return result;
    }
    return null;
  }

  static Future<Handle?> findOneAsync({int? id, int? originalROWID, HandleLookupKey? addressAndService}) async {
    if (id == 0) return null;
    return (await HandleInterface.findOneHandleAsync(
      id: id,
      originalROWID: originalROWID,
      address: addressAndService?.address,
      service: addressAndService?.service,
    )) as dynamic;
  }

  static Handle merge(Handle handle1, Handle handle2) {
    handle1.id ??= handle2.id;
    handle1.originalROWID ??= handle2.originalROWID;
    handle1.color ??= handle2.color;
    handle1.country ??= handle2.country;
    handle1.formattedAddress ??= handle2.formattedAddress;
    if (isNullOrEmpty(handle1.defaultPhone)) {
      handle1.defaultPhone = handle2.defaultPhone;
    }
    if (isNullOrEmpty(handle1.defaultEmail)) {
      handle1.defaultEmail = handle2.defaultEmail;
    }

    return handle1;
  }

  static List<Handle> find({Condition<Handle>? cond}) {
    final query = HtmlDatabase.handles.query(cond).build();
    final result = query.find();
    query.close();
    return result;
  }

  static Future<List<Handle>> findAsync({Condition<Handle>? cond}) async {
    return (await HandleInterface.findHandlesAsync() as List).cast<Handle>();
  }

  Map<String, dynamic> toMap() {
    return {
      "ROWID": id,
      "originalROWID": originalROWID,
      "address": address,
      "formattedAddress": formattedAddress,
      "service": service,
      "uniqueAddrAndService": uniqueAddressAndService,
      "country": country,
      "color": color,
      "defaultPhone": defaultPhone,
      "defaultEmail": defaultEmail,
    };
  }
}

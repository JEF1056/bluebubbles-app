import 'dart:convert';

import 'package:bluebubbles/database/html/handle.dart';
import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:dice_bear/dice_bear.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A phone number with an associated label (e.g., "mobile", "work", "home").
class ContactPhone {
  final String number;
  final String label;

  const ContactPhone({required this.number, required this.label});

  Map<String, dynamic> toMap() => {'number': number, 'label': label};

  static ContactPhone fromMap(Map<String, dynamic> m) =>
      ContactPhone(number: m['number'] ?? '', label: m['label'] ?? '');

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ContactPhone && number == other.number && label == other.label);

  @override
  int get hashCode => Object.hash(number, label);
}

/// An email address with an associated label (e.g., "work", "home").
class ContactEmail {
  final String address;
  final String label;

  const ContactEmail({required this.address, required this.label});

  Map<String, dynamic> toMap() => {'address': address, 'label': label};

  static ContactEmail fromMap(Map<String, dynamic> m) =>
      ContactEmail(address: m['address'] ?? '', label: m['label'] ?? '');

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ContactEmail && address == other.address && label == other.label);

  @override
  int get hashCode => Object.hash(address, label);
}

class ContactV2 {
  ContactV2({
    this.id = 0,
    required this.displayName,
    required this.nativeContactId,
    this.isNative = false,
    this.avatarPath,
    this.addresses = const [],
    this.nickname,
    this.firstName,
    this.lastName,
    this.middleName,
    this.namePrefix,
    this.nameSuffix,
    this.company,
  });

  int id;
  String displayName;
  String nativeContactId;
  String? avatarPath;
  List<String> addresses;

  String? nickname;
  String? firstName;
  String? lastName;
  String? middleName;
  String? namePrefix;
  String? nameSuffix;
  String? company;
  bool isNative = false;

  List<ContactPhone> phoneNumbers = [];

  String? get dbPhoneNumbers => phoneNumbers.isEmpty ? null : jsonEncode(phoneNumbers.map((e) => e.toMap()).toList());

  set dbPhoneNumbers(String? json) {
    phoneNumbers = json == null
        ? []
        : (jsonDecode(json) as List).map((e) => ContactPhone.fromMap(e as Map<String, dynamic>)).toList();
  }

  List<ContactEmail> emailAddresses = [];

  String? get dbEmailAddresses =>
      emailAddresses.isEmpty ? null : jsonEncode(emailAddresses.map((e) => e.toMap()).toList());

  set dbEmailAddresses(String? json) {
    emailAddresses = json == null
        ? []
        : (jsonDecode(json) as List).map((e) => ContactEmail.fromMap(e as Map<String, dynamic>)).toList();
  }

  final handles = ToMany<Handle>();

  Widget? _fakeAvatar;

  Widget get fakeAvatar {
    if (_fakeAvatar != null) return _fakeAvatar!;
    Avatar _avatar = DiceBearBuilder(seed: displayName).build();
    _fakeAvatar = _avatar.toImage();
    return _fakeAvatar!;
  }

  String get computedDisplayName {
    if (nickname != null && nickname!.isNotEmpty) return nickname!;
    final first = firstName ?? '';
    final last = lastName ?? '';
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    return displayName;
  }

  String? get initials {
    final first = firstName.firstAlpha;
    final last = lastName.firstAlpha;

    if (first != null || last != null) {
      return ((first ?? '') + (last ?? '')).toUpperCase();
    }

    final parts = displayName.trim().split(' ');
    if (parts.isEmpty || displayName.isEmpty) return null;

    if (parts.length == 1) {
      return parts[0].firstAlpha?.toUpperCase();
    }

    final firstPart = parts.first.firstAlpha ?? '';
    final lastPart = parts.last.firstAlpha ?? '';

    return (firstPart + lastPart).isEmpty ? null : (firstPart + lastPart).toUpperCase();
  }

  static String normalizePhoneNumber(String phone) {
    return phone.replaceAll(RegExp(r'[^\d+]'), '');
  }

  static String normalizeEmail(String email) {
    return email.toLowerCase().trim();
  }

  static String? personUriForAddress(String? address) {
    if (address == null) return null;
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('@')) {
      return 'mailto:${normalizeEmail(trimmed)}';
    }
    final normalized = normalizePhoneNumber(trimmed);
    return normalized.isNotEmpty ? 'tel:$normalized' : null;
  }

  String? notificationPersonUri({String? fallbackAddress}) {
    if (isNative && nativeContactId.isNotEmpty) {
      return 'content://com.android.contacts/contacts/$nativeContactId';
    }
    return personUriForAddress(fallbackAddress ?? addresses.firstOrNull);
  }

  bool hasMatchingAddress(String address) {
    final normalized = address.contains('@') ? normalizeEmail(address) : normalizePhoneNumber(address);

    return addresses.any((contactAddress) {
      final contactNormalized =
          contactAddress.contains('@') ? normalizeEmail(contactAddress) : normalizePhoneNumber(contactAddress);
      return contactNormalized == normalized;
    });
  }

  Map<String, dynamic> toServerMap({required String deviceId}) {
    return {
      'externalId': '$deviceId:$nativeContactId',
      'displayName': displayName,
      'firstName': firstName,
      'lastName': lastName,
      'phoneNumbers': phoneNumbers.map((e) => e.number).toList(),
      'emails': emailAddresses.map((e) => e.address).toList(),
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'displayName': displayName,
      'nativeContactId': nativeContactId,
      'avatarPath': avatarPath,
      'addresses': addresses,
      'nickname': nickname,
      'firstName': firstName,
      'lastName': lastName,
      'middleName': middleName,
      'namePrefix': namePrefix,
      'nameSuffix': nameSuffix,
      'company': company,
      'isNative': isNative,
      'phoneNumbers': phoneNumbers.map((e) => e.toMap()).toList(),
      'emailAddresses': emailAddresses.map((e) => e.toMap()).toList(),
    };
  }

  static ContactV2 fromMap(Map<String, dynamic> map) {
    final c = ContactV2(
      id: map['id'] ?? 0,
      displayName: map['displayName'] ?? '',
      nativeContactId: map['nativeContactId'] ?? '',
      isNative: map['isNative'] ?? false,
      avatarPath: map['avatarPath'],
      addresses: List<String>.from(map['addresses'] ?? []),
      nickname: map['nickname'],
      firstName: map['firstName'],
      lastName: map['lastName'],
      middleName: map['middleName'],
      namePrefix: map['namePrefix'],
      nameSuffix: map['nameSuffix'],
      company: map['company'],
    );
    if (map['phoneNumbers'] != null) {
      c.phoneNumbers =
          (map['phoneNumbers'] as List).map((e) => ContactPhone.fromMap(e as Map<String, dynamic>)).toList();
    }
    if (map['emailAddresses'] != null) {
      c.emailAddresses =
          (map['emailAddresses'] as List).map((e) => ContactEmail.fromMap(e as Map<String, dynamic>)).toList();
    }
    return c;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ContactV2 &&
          runtimeType == other.runtimeType &&
          nativeContactId == other.nativeContactId &&
          displayName == other.displayName &&
          listEquals(addresses, other.addresses) &&
          avatarPath == other.avatarPath);

  @override
  int get hashCode => Object.hash(
        nativeContactId,
        displayName,
        Object.hashAll(addresses),
        avatarPath,
      );
}

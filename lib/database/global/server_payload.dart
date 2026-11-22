import 'dart:convert';

import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/utils/crypto_utils.dart';
import 'package:collection/collection.dart';
import 'package:get_it/get_it.dart';

enum PayloadEncoding { JSON_OBJECT, BASE64, JSON_STRING }

enum PayloadType {
  NEW_MESAGE,
  UPDATED_MESSAGE,
  MESSAGE,
  CHAT,
  ATTACHMENT,
  HANDLE,
  OTHER,
}

enum EncryptionType {
  AES_PB,
}

class ServerPayload {
  dynamic originalJson;
  dynamic data;
  final bool isLegacy;
  final PayloadType type;
  final String? subtype;
  final bool isEncrypted;
  final bool isPartial;
  PayloadEncoding encoding;
  final EncryptionType encryptionType;

  bool get isList => (isLegacy && originalJson is List) || (!isLegacy && data is List);
  bool get isString => (isLegacy && originalJson is String) || (!isLegacy && data is String);
  bool get isDict => (isLegacy && originalJson is Map) || (!isLegacy && data is Map);

  ServerPayload({
    required this.originalJson,
    this.data,
    required this.isLegacy,
    required this.type,
    this.subtype,
    required this.isEncrypted,
    required this.isPartial,
    required this.encoding,
    required this.encryptionType,
    String? passphrase,
  }) {
    if (isEncrypted && data is String) {
      if (encryptionType == EncryptionType.AES_PB) {
        final key = passphrase ??
            (GetIt.I.isRegistered<SettingsService>() ? SettingsSvc.settings.guidAuthKey.value : '');
        data = decryptAESCryptoJS(data, key);
      }
    }
    if ([PayloadEncoding.JSON_OBJECT, PayloadEncoding.JSON_STRING].contains(encoding) && data is String) {
      data = jsonDecode(data);
      encoding = PayloadEncoding.JSON_OBJECT;
    }
    if (data is Map && data is! Map<String, dynamic>) {
      data = data.cast<String, dynamic>();
    }
  }

  factory ServerPayload.fromJson(Map<String, dynamic> json, {String? passphrase}) => ServerPayload(
        originalJson: json,
        data: json["data"] ?? json,
        isLegacy: !json.containsKey("type"),
        type: PayloadType.values.firstWhereOrNull((element) => element.name == json["type"]) ?? PayloadType.OTHER,
        subtype: json["subtype"],
        isEncrypted: json["encrypted"] ?? false,
        isPartial: json["partial"] ?? false,
        encoding: PayloadEncoding.values.firstWhereOrNull((element) => element.name == json["encoding"]) ??
            PayloadEncoding.JSON_OBJECT,
        encryptionType: EncryptionType.values.firstWhereOrNull((element) => element.name == json["encryptionType"]) ??
            EncryptionType.AES_PB,
        passphrase: passphrase,
      );
}

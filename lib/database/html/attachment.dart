// ignore_for_file: return_of_invalid_type

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bluebubbles/database/html/message.dart';
import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show StickerPlacement;
import 'package:bluebubbles/services/backend/descriptors/attachment_query_descriptor.dart';
import 'package:bluebubbles/services/backend/interfaces/attachment_interface.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:mime_type/mime_type.dart';
import 'package:passkit/passkit.dart';

class Attachment {
  int? id;
  int? originalROWID;
  String? guid;
  String? uti;
  String? mimeType;
  bool? isOutgoing;
  String? transferName;
  int? totalBytes;
  int? height;
  int? width;
  Uint8List? bytes;
  String? webUrl;
  bool hasLivePhoto;
  bool isDownloaded;

  final message = ToOne<Message>();

  Map<String, dynamic>? metadata;
  Map<String, dynamic>? exif;

  String? get dbMetadata => metadata == null ? null : jsonEncode(metadata);
  set dbMetadata(String? json) => metadata = json == null ? null : jsonDecode(json) as Map<String, dynamic>;

  String? originalGuid;
  Map<String, dynamic>? stickerPlacement;

  Attachment({
    this.id,
    this.originalROWID,
    this.guid,
    this.uti,
    this.mimeType,
    this.isOutgoing,
    this.transferName,
    this.totalBytes,
    this.height,
    this.width,
    this.metadata,
    this.stickerPlacement,
    this.originalGuid,
    this.exif,
    this.bytes,
    this.webUrl,
    this.hasLivePhoto = false,
    this.isDownloaded = false,
  });

  factory Attachment.fromMap(Map<String, dynamic> json) {
    String? mimeType = json["mimeType"];
    if (json["uti"] == "com.apple.coreaudio_format" || json['transferName'].toString().endsWith(".caf")) {
      mimeType = "audio/caf";
    }

    var metadata = json["metadata"];
    if (metadata is String && metadata.isNotEmpty) {
      try {
        metadata = jsonDecode(metadata);
      } catch (_) {}
    }

    var exif = json["exif"];
    if (exif is String && exif.isNotEmpty) {
      try {
        exif = jsonDecode(exif);
      } catch (_) {}
    }

    return Attachment(
      id: json["ROWID"] ?? json["id"],
      originalROWID: json["originalROWID"],
      guid: json["guid"],
      uti: json["uti"],
      mimeType: mimeType ?? mime(json['transferName']),
      isOutgoing: json["isOutgoing"] == true,
      transferName: json['transferName'],
      totalBytes: json['totalBytes'] is int ? json['totalBytes'] : 0,
      height: json["height"] ?? 0,
      width: json["width"] ?? 0,
      metadata: metadata is String ? null : metadata,
      stickerPlacement: StickerPlacement.tryParse(json["stickerPlacement"])?.toMap(),
      originalGuid: json["originalGuid"],
      exif: exif is String ? null : exif,
      hasLivePhoto: json["hasLivePhoto"] ?? false,
      isDownloaded: json["isDownloaded"] ?? false,
    );
  }

  Future<Attachment> saveAsync(Message? message) async {
    final result = await AttachmentInterface.saveAttachmentAsync(
      attachmentData: toMap(),
      messageData: message?.toMap(),
    );
    id = result.id;
    return this;
  }

  static Future<void> bulkSaveAsync(Map<Message, List<Attachment>> map) async {
    final Map<Map<String, dynamic>, List<Map<String, dynamic>>> mapData = {};
    for (final entry in map.entries) {
      mapData[entry.key.toMap()] = entry.value.map((e) => e.toMap()).toList();
    }
    await AttachmentInterface.bulkSaveAttachmentsAsync(mapData: mapData);
  }

  static Future<Attachment> replaceAttachmentAsync(String? oldGuid, Attachment newAttachment) async {
    final existing = await Attachment.findOneAsync(oldGuid!);
    if (existing == null) {
      return Future.error("Old GUID ($oldGuid) does not exist!");
    }

    final updatedAttachment = await AttachmentInterface.replaceAttachmentAsync(
      oldGuid: oldGuid,
      newAttachmentData: newAttachment.toMap(),
    );

    newAttachment.id = updatedAttachment.id;
    newAttachment.width = updatedAttachment.width;
    newAttachment.height = updatedAttachment.height;
    newAttachment.metadata = updatedAttachment.metadata;
    newAttachment.exif = updatedAttachment.exif;
    newAttachment.stickerPlacement ??= updatedAttachment.stickerPlacement;
    newAttachment.isDownloaded = updatedAttachment.isDownloaded;
    return newAttachment;
  }

  static Future<Attachment?> findOneAsync(String guid) async {
    return (await AttachmentInterface.findOneAttachmentAsync(guid: guid)) as dynamic;
  }

  static Future<List<Attachment>> findAsync({AttachmentQueryDescriptor? queryDescriptor}) async {
    final results = await (AttachmentInterface.findAttachmentsAsync as dynamic)(queryDescriptor: queryDescriptor);
    return (results as List).cast<Attachment>();
  }

  static Future<void> deleteAsync(String guid) async {
    await AttachmentInterface.deleteAttachmentAsync(guid: guid);
  }

  String getFriendlySize({int decimals = 2}) {
    return (totalBytes ?? 0.0).toDouble().getFriendlySize(decimals: decimals);
  }

  int get orientation => (metadata?['_orientation'] as num?)?.toInt() ?? 1;

  bool get orientationSwapsDimensions => orientation == 5 || orientation == 6 || orientation == 7 || orientation == 8;

  int? get rawWidth {
    final raw = (metadata?['_raw_width'] as num?)?.toInt();
    if (raw != null && raw > 0) return raw;
    if (width != null && width! > 0) return width;
    return null;
  }

  int? get rawHeight {
    final raw = (metadata?['_raw_height'] as num?)?.toInt();
    if (raw != null && raw > 0) return raw;
    if (height != null && height! > 0) return height;
    return null;
  }

  int? get displayWidth {
    final w = rawWidth, h = rawHeight;
    if (w == null || h == null) return (metadata?['width'] as num?)?.toInt();
    return orientationSwapsDimensions ? h : w;
  }

  int? get displayHeight {
    final w = rawWidth, h = rawHeight;
    if (w == null || h == null) return (metadata?['height'] as num?)?.toInt();
    return orientationSwapsDimensions ? w : h;
  }

  bool get hasValidSize => (displayWidth ?? 0) > 0 && (displayHeight ?? 0) > 0;

  ({double width, double height}) displayBox(double maxWidth, [double maxHeight = double.infinity]) {
    final fallbackHeight = maxWidth / aspectRatio;
    double width = math.min(displayWidth?.toDouble() ?? maxWidth, maxWidth);
    double height = math.min(displayHeight?.toDouble() ?? fallbackHeight, fallbackHeight);
    if (height > maxHeight) {
      width *= maxHeight / height;
      height = maxHeight;
    }
    return (width: width, height: height);
  }

  double get aspectRatio => hasValidSize ? (displayWidth! / displayHeight!).abs() : 0.78;

  String? get mimeStart => mimeType?.split("/").first;

  static String get baseDirectory => FilesystemSvc.attachmentsPath;

  String get directory => "$baseDirectory/${FilesystemService.sanitizeGuid(guid)}";

  static String sanitizeTransferName(String? transferName) {
    final raw = "$transferName";
    final sanitized = raw.replaceAll('/', '_');
    if (sanitized == '.' || sanitized == '..') return sanitized.replaceAll('.', '_');
    return sanitized;
  }

  String get path => "$directory/${sanitizeTransferName(transferName)}";

  String get convertedExtension => (mimeType?.contains('image/hei') ?? false) && !isSeeThrough ? "jpg" : "png";

  bool get isSeeThrough {
    if (mimeType == "image/heic-sequence") return true;
    final parent = message.target;
    if (parent == null) return false;
    return parent.isSticker ||
        ReactionTypes.isStickerTapback(parent.associatedMessageType) ||
        parent.attributedBody.any((b) => b.runs.any((r) => r.isEmojiImage && r.attributes!.attachmentGuid == guid));
  }

  String get convertedPath => "$path.$convertedExtension";

  String get legacyConvertedPath => "$path.png";

  String previewPathForQuality(int quality) => "$path.preview.q$quality.jpg";

  bool get existsOnDisk => false;

  Future<bool> get existsOnDiskAsync async => false;

  bool get canCompress => mimeStart == "image" && !mimeType!.contains("gif");

  PkPass? get pkPass => null;

  bool get isPkPass => pkPass != null;

  void takeFlagsFrom(Attachment incoming) {
    hasLivePhoto = hasLivePhoto || incoming.hasLivePhoto;
    isOutgoing = isOutgoing == true || incoming.isOutgoing == true;
  }

  static Attachment merge(Attachment attachment1, Attachment attachment2) {
    attachment1.id ??= attachment2.id;
    attachment1.bytes ??= attachment2.bytes;
    attachment1.guid ??= attachment2.guid;
    attachment1.height ??= attachment2.height;
    attachment1.width ??= attachment2.width;
    attachment1.isOutgoing ??= attachment2.isOutgoing;
    attachment1.mimeType ??= attachment2.mimeType;
    attachment1.totalBytes ??= attachment2.totalBytes;
    attachment1.transferName ??= attachment2.transferName;
    attachment1.uti ??= attachment2.uti;
    attachment1.webUrl ??= attachment2.webUrl;
    attachment1.metadata = mergeTopLevelDicts(attachment1.metadata, attachment2.metadata);
    attachment1.exif = mergeTopLevelDicts(attachment1.exif, attachment2.exif);
    attachment1.stickerPlacement ??= attachment2.stickerPlacement;
    if (attachment2.hasLivePhoto) {
      attachment1.hasLivePhoto = attachment2.hasLivePhoto;
    }
    if (!attachment1.isDownloaded && attachment2.isDownloaded) {
      attachment1.isDownloaded = attachment2.isDownloaded;
    }
    if (!attachment1.message.hasValue) {
      attachment1.message.target = attachment2.message.target;
    }
    return attachment1;
  }

  Map<String, dynamic> toMap() => {
        "ROWID": id,
        "originalROWID": originalROWID,
        "guid": guid,
        "uti": uti,
        "mimeType": mimeType,
        "isOutgoing": isOutgoing!,
        "transferName": transferName,
        "totalBytes": totalBytes,
        "height": height,
        "width": width,
        "metadata": jsonEncode(metadata),
        if (stickerPlacement != null) "stickerPlacement": stickerPlacement,
        if (originalGuid != null) "originalGuid": originalGuid,
        "exif": jsonEncode(exif),
        "hasLivePhoto": hasLivePhoto,
        "isDownloaded": isDownloaded,
      };
}

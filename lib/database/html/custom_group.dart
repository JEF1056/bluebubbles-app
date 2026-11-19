import 'package:bluebubbles/database/html/chat.dart';
import 'package:bluebubbles/database/html/objectbox.dart';

class CustomGroup {
  int? id;
  String name;
  int sortOrder;
  bool showUnreadBadge;

  final chats = ToMany<Chat>();

  CustomGroup({
    this.id,
    required this.name,
    this.sortOrder = 0,
    this.showUnreadBadge = true,
  });

  factory CustomGroup.fromMap(Map<String, dynamic> map) {
    return CustomGroup(
      id: map['id'],
      name: map['name'] ?? '',
      sortOrder: map['sortOrder'] ?? 0,
      showUnreadBadge: map['showUnreadBadge'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'sortOrder': sortOrder,
      'showUnreadBadge': showUnreadBadge,
      'chatGuids': chats.map((c) => c.guid).toList(),
    };
  }
}

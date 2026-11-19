import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/actions/contact_v2_actions.dart';
import 'package:bluebubbles/services/backend/web/listeners.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Valid 2x2 RGBA PNG for exercising MemoryImage-backed adaptive theme generation.
final Uint8List _png1x1Blue = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xB6, 0x0D,
  0x24, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x90, 0x9B, 0xF0, 0xFF,
  0x3F, 0x08, 0x33, 0xC0, 0x18, 0x00, 0x5A, 0x1E, 0x0A, 0xB1, 0x0B, 0x03, 0xD8, 0x3A, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ThemesService.generateAdaptiveThemesFromImage builds and caches variants from imageBytes', () async {
    const cacheKey = 'web-bg://test-chat-guid';
    ThemesService.clearAdaptiveThemeCache(cacheKey);
    expect(ThemesService.adaptiveThemeCacheSize, 0);

    final variants = await ThemesService.generateAdaptiveThemesFromImage(
      cacheKey,
      imageBytes: _png1x1Blue,
    );

    expect(variants.keys, containsAll(MaterialYouVariant.values));
    expect(ThemesService.adaptiveThemeCacheSize, 1);

    final cached = await ThemesService.generateAdaptiveThemesFromImage(cacheKey);
    expect(identical(cached, variants), isTrue);

    ThemesService.clearAdaptiveThemeCache(cacheKey);
    expect(ThemesService.adaptiveThemeCacheSize, 0);
  });

  test('ContactV2Actions.linkHandlesToContactsInTx handles empty list safely', () {
    expect(ContactV2Actions.linkHandlesToContactsInTx(const []), isEmpty);
  });

  test('WebListeners.reset clears seen GUIDs so re-synced items emit new events', () async {
    WebListeners.reset();
    final newChats = <String>[];
    final updatedChats = <String>[];
    final newMessages = <String?>[];
    final updatedMessages = <String?>[];

    final s1 = WebListeners.newChat.listen((c) => newChats.add(c.guid));
    final s2 = WebListeners.chatUpdate.listen((c) => updatedChats.add(c.guid));
    final s3 = WebListeners.newMessage.listen((e) => newMessages.add(e.message.guid));
    final s4 = WebListeners.messageUpdate.listen((e) => updatedMessages.add(e.message.guid));

    final chat = Chat(guid: 'iMessage;-;+15551234567');
    final msg = Message(guid: 'msg-guid-1');

    WebListeners.notifyChat(chat);
    WebListeners.notifyChat(chat);
    WebListeners.notifyMessage(msg);
    WebListeners.notifyMessage(msg);
    await Future<void>.delayed(Duration.zero);

    expect(newChats, ['iMessage;-;+15551234567']);
    expect(updatedChats, ['iMessage;-;+15551234567']);
    expect(newMessages, ['msg-guid-1']);
    expect(updatedMessages, ['msg-guid-1']);

    WebListeners.reset();
    WebListeners.notifyChat(chat);
    WebListeners.notifyMessage(msg);
    await Future<void>.delayed(Duration.zero);

    expect(newChats, ['iMessage;-;+15551234567', 'iMessage;-;+15551234567']);
    expect(newMessages, ['msg-guid-1', 'msg-guid-1']);

    await s1.cancel();
    await s2.cancel();
    await s3.cancel();
    await s4.cancel();
  });
}

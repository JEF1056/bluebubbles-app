import 'package:bluebubbles/app/layouts/settings/pages/storage/storage_analyzer_controller.dart';
import 'package:bluebubbles/services/backend/filesystem/web_media_cache_quota_stub.dart'
    if (dart.library.js_interop) 'package:bluebubbles/services/backend/filesystem/web_media_cache_quota_web.dart';
import 'package:bluebubbles/services/backend/lifecycle/web_lifecycle_interop.dart';
import 'package:bluebubbles/services/backend/notifications/notifications_service.dart';
import 'package:bluebubbles/services/backend/notifications/web_notifications_interop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  tearDown(() async {
    await GetIt.I.reset();
  });

  test('web interop stubs are safe no-ops on VM', () async {
    final est = await estimateWebOriginStorage();
    expect(est.usage, isNull);
    expect(est.quota, isNull);

    updateWebTitleAndBadge(3);
    updateWebTitleAndBadge(0);
    await showWebNotificationEx(title: 'Test', body: 'Hello');

    expect(isWebNavigatorOnline, isTrue);
    final dispose = listenWebLifecycle(
      onVisibilityChange: (_) {},
      onOnlineChange: (_) {},
    );
    dispose();
  });

  test('NotificationsService.bindWebUnreadBadge safely guards missing ChatsService', () {
    final svc = NotificationsService();
    expect(() => svc.bindWebUnreadBadge(), returnsNormally);
    svc.close();
  });

  test('StorageAnalyzerController.onClose safely guards unregistered GlobalIsolate', () {
    final controller = StorageAnalyzerController();
    expect(() => controller.onClose(), returnsNormally);
  });
}

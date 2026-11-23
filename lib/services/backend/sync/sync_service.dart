import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/network/network_helpers.dart';
import 'package:bluebubbles/helpers/types/helpers/misc_helpers.dart';
import 'package:bluebubbles/helpers/ui/async_task.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/services/backend/interfaces/contact_v2_interface.dart';
import 'package:bluebubbles/services/backend/interfaces/sync_interface.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/services/isolates/incremental_sync_isolate.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
import 'package:universal_io/universal_io.dart';

export 'sync_status.dart';

// ignore: non_constant_identifier_names
SyncService get SyncSvc => GetIt.I<SyncService>();

class SyncService {
  int numberOfMessagesPerPage = 25;
  bool skipEmptyChats = true;
  bool saveToDownloads = false;
  bool syncGroupChatIcons = false;
  int? syncTimeFilter;
  final RxBool isIncrementalSyncing = false.obs;
  final Rx<SyncStatusSnapshot> status = SyncStatusSnapshot.idle.obs;

  late final SyncStatusTracker _statusTracker = SyncStatusTracker(
    onChanged: (next) => status.value = next,
  );
  Worker? _setupWorker;
  Worker? _syncingWorker;
  bool _inManagedIncrementalSync = false;

  SyncService() {
    _syncingWorker = ever<bool>(isIncrementalSyncing, (syncing) {
      if (syncing) {
        _syncSetupGate();
        _statusTracker.onSyncStarted();
      } else if (!_inManagedIncrementalSync) {
        // Clear the syncing hairline for callers that toggle isIncrementalSyncing directly (e.g. Connection Panel).
        _statusTracker.onSyncFinished(success: true);
      }
    });
  }

  void _syncSetupGate() {
    if (GetIt.I.isRegistered<SettingsService>()) {
      final finished = SettingsSvc.settings.finishedSetup;
      _statusTracker.setFinishedSetup(finished.value);
      _setupWorker ??= ever<bool>(finished, _statusTracker.setFinishedSetup);
    }
  }

  void onSocketStatusChanged({
    required SocketState state,
    required bool connectionDesired,
    required bool authFailed,
    String? errorMessage,
  }) {
    final wasConnected = _socketConnected;
    _socketConnected = state == SocketState.connected;
    _connectionDesired = connectionDesired;
    _authFailed = authFailed;
    _syncSetupGate();
    _statusTracker.setConnectionDesired(connectionDesired);
    _statusTracker.setAuthFailed(authFailed);
    _statusTracker.onSocketState(
      connected: state == SocketState.connected,
      retrying: state == SocketState.connecting || state == SocketState.reconnecting,
      failed: state == SocketState.error || (state == SocketState.disconnected && connectionDesired),
      errorMessage: errorMessage,
    );
    if (!connectionDesired || authFailed) {
      _cancelFailureRetry();
      _cancelManualRetryHttpFallback();
      _catchUpTimer?.cancel();
      _catchUpTimer = null;
      return;
    }
    if (_socketConnected) {
      _cancelManualRetryHttpFallback();
      if (_needsRecoverySync && (!wasConnected || _failureRetryTimer == null)) {
        _triggerRecoverySync();
      }
    }
  }

  void onNetworkOnlineChanged(bool online) {
    final wasOffline = !_networkOnline;
    _networkOnline = online;
    _syncSetupGate();
    _statusTracker.setNetworkOnline(online);
    if (!online) {
      _cancelFailureRetry();
      _cancelManualRetryHttpFallback();
    } else if (wasOffline && _needsRecoverySync && !_authFailed && _connectionDesired) {
      _triggerRecoverySync();
    }
  }

  void onResumeReconnectGrace() {
    _failureRetryAttempt = 0;
    _syncSetupGate();
    _statusTracker.beginReconnectGrace();
  }

  void onSetupStateChanged(bool finishedSetup) {
    _statusTracker.setFinishedSetup(finishedSetup);
  }

  void dismissIssue([String? key]) {
    _statusTracker.dismissIssue(key);
  }

  Future<void> retryNow() async {
    _syncSetupGate();
    _statusTracker.prepareManualRetry();
    _lastIncrementalSyncTimestamp = null;
    _failureRetryAttempt = 0;
    _cancelFailureRetry();
    _cancelManualRetryHttpFallback();
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    if (GetIt.I.isRegistered<SocketService>() && SocketSvc.state.value != SocketState.connected) {
      _needsRecoverySync = true;
      if (isIncrementalSyncing.value) {
        _retryImmediatelyAfterInFlight = true;
      }
      SocketSvc.restartSocket();
      if (!_socketConnected && SocketSvc.state.value != SocketState.connected) {
        _scheduleManualRetryHttpFallback();
      }
      return;
    }
    if (isIncrementalSyncing.value) {
      _retryImmediatelyAfterInFlight = true;
      return;
    }
    await startIncrementalSync(catchUp: true);
  }

  @visibleForTesting
  Future<List<Message>> Function({bool useGlobalIsolate})? incrementalSyncRunner;

  @visibleForTesting
  void disposeStatusTracker() {
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    _cancelFailureRetry();
    _cancelManualRetryHttpFallback();
    _needsRecoverySync = false;
    _retryImmediatelyAfterInFlight = false;
    _pendingUseGlobalIsolate = false;
    _failureRetryAttempt = 0;
    _setupWorker?.dispose();
    _setupWorker = null;
    _syncingWorker?.dispose();
    _syncingWorker = null;
    _statusTracker.dispose();
  }

  static const Duration _incrementalSyncCooldown = Duration(seconds: 30);
  static const Duration _manualRetryHttpFallbackDelay = Duration(seconds: 5);
  static const Duration _maxFailureRetryDelay = Duration(seconds: 60);
  static const int _maxFailureRetryAttempts = 10;
  static const List<Duration> _failureRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  static const int _dispatchChunkSize = 50;
  DateTime? _lastIncrementalSyncTimestamp;
  Timer? _failureRetryTimer;
  Timer? _manualRetryHttpFallbackTimer;
  int _failureRetryAttempt = 0;
  bool _needsRecoverySync = false;
  bool _retryImmediatelyAfterInFlight = false;
  bool _pendingUseGlobalIsolate = false;
  bool _socketConnected = false;
  bool _connectionDesired = true;
  bool _authFailed = false;
  bool _networkOnline = true;

  // Desktop pulls every server contact with avatars, so incremental syncs refresh them at most daily.
  static const Duration _serverContactSyncInterval = Duration(hours: 24);
  DateTime? _lastServerContactSync;

  /// The server that pull came from. Another server's contacts are pulled at once rather than after the day is up.
  String? _lastServerContactSyncAddress;

  FullSyncManager? _manager;
  FullSyncManager? get fullSyncManager => _manager;

  void initFullSync() {
    _manager = FullSyncManager(
        messageCount: numberOfMessagesPerPage.toInt(),
        skipEmptyChats: skipEmptyChats,
        saveLogs: saveToDownloads,
        syncGroupChatIcons: syncGroupChatIcons,
        syncTimeFilter: syncTimeFilter);
  }

  Future<void> startFullSync() async {
    if (_manager == null) {
      initFullSync();
    }

    // Set the last sync date (for incremental, even though this isn't incremental)
    // We won't try an incremental sync until the last (full) sync date is set
    SettingsSvc.settings.lastIncrementalSync.value = DateTime.now().millisecondsSinceEpoch;
    await SettingsSvc.settings.saveOneAsync('lastIncrementalSync');
    await _manager!.start();
    if (GetIt.I.isRegistered<ChatsService>() && !ChatsSvc.headless) {
      unawaited(SettingsSvc.refreshServerDetails());
      unawaited(ChatsSvc.syncPinnedChatsFromServer(forceFlagsSync: true));
    }
  }

  /// [catchUp]: a sync that must not be lost to the cooldown, because something may have been missed since the last
  /// one started (the socket just connected, or a push copy the socket never replaced). If a sync is running or ran
  /// within the cooldown, it runs once that's over instead of being skipped. Requests in the meantime share that one
  /// run, so a burst of them still costs a single sync.
  Future<void> startIncrementalSync({bool useGlobalIsolate = false, bool catchUp = false}) async {
    final now = DateTime.now();
    final sinceLast = _lastIncrementalSyncTimestamp == null ? null : now.difference(_lastIncrementalSyncTimestamp!);
    if (isIncrementalSyncing.value) {
      if (_needsRecoverySync) {
        _retryImmediatelyAfterInFlight = true;
        _pendingUseGlobalIsolate = _pendingUseGlobalIsolate || useGlobalIsolate;
      } else if (catchUp) {
        // The running sync may have queried the server before what this is catching up on got there
        _scheduleCatchUp(_incrementalSyncCooldown - (sinceLast ?? Duration.zero), useGlobalIsolate);
      }
      return;
    }
    if (sinceLast != null && sinceLast < _incrementalSyncCooldown) {
      Logger.debug(
        'Skipping incremental sync... Last ran ${sinceLast.inSeconds}s ago '
        '(cooldown: ${_incrementalSyncCooldown.inSeconds}s)${catchUp ? ', running it when the cooldown ends' : ''}',
        tag: 'Incremental Chat Sync',
      );
      if (catchUp) _scheduleCatchUp(_incrementalSyncCooldown - sinceLast, useGlobalIsolate);
      return;
    }
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    _cancelManualRetryHttpFallback();

    _lastIncrementalSyncTimestamp = now;
    _inManagedIncrementalSync = true;
    isIncrementalSyncing.value = true;
    bool chatSyncFailed = false;
    bool statusFinished = false;

    try {
      // Per-page tracking: record message IDs and chat subtitle message IDs that were
      // already applied by per-page events so the final return can skip redundant work.
      final processedMessageIds = <int>{};
      final processedSubtitleByChat = <String, int>{}; // chatGuid → message DB ID

      // This runs on the UI thread (isolate event listeners are invoked synchronously),
      // so a page of up to `batchSize` messages must never be hydrated in one block.
      Future<void> onPageComplete(dynamic data) async {
        if (data is! Map<String, dynamic>) return;
        final messageIdsByChat =
            (data['messageIdsByChat'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<int>()));
        final latestPerChat = Map<String, int>.from(data['latestMessageIdPerChat'] as Map);

        // repositionImmediate: false so a page touching many chats rebuilds the list once.
        for (final entry in latestPerChat.entries) {
          final msg = await runAsync(() => Database.messages.get(entry.value));
          if (msg == null) continue;
          // If this chat was created for the first time during this sync,
          // ChatState doesn't exist yet — register it so updateChatLatestMessage
          // isn't a silent no-op.
          if (ChatsSvc.getChatState(entry.key) == null) {
            final chat = msg.chat.target;
            if (chat != null) await ChatsSvc.addChat(chat, immediate: true);
          }
          ChatsSvc.updateChatLatestMessage(entry.key, msg, repositionImmediate: false);
          processedSubtitleByChat[entry.key] = entry.value;
        }

        // Only an open conversation view needs the individual messages — every other
        // chat is served by the subtitle update above.
        for (final entry in messageIdsByChat.entries) {
          if (maybeFindMessagesSvc(entry.key) == null) continue;
          for (int i = 0; i < entry.value.length; i += _dispatchChunkSize) {
            // Re-resolve every chunk: the user can leave this chat between chunks
            final service = maybeFindMessagesSvc(entry.key);
            if (service == null) break;
            final chunk = entry.value.sublist(i, math.min(i + _dispatchChunkSize, entry.value.length));
            final messages = await runAsync(() => Database.messages.getMany(chunk).whereType<Message>().toList());
            for (final message in messages) {
              if (message.guid == null) continue;
              if (service.struct.getMessage(message.guid!) != null) {
                service.updateMessage(message);
              } else {
                await service.addNewMessage(message);
              }
              if (message.id != null) processedMessageIds.add(message.id!);
            }
          }
        }
      }

      // Events arrive on the instance that runs the sync, so listen there.
      final GlobalIsolate? syncIsolate = incrementalSyncRunner != null
          ? null
          : (useGlobalIsolate ? GetIt.I<GlobalIsolate>() : GetIt.I<IncrementalSyncIsolate>());
      syncIsolate?.addEventListener(IsolateEvent.incrementalSyncPageComplete, onPageComplete);

      try {
        Logger.info('Starting incremental chat sync...', tag: 'Incremental Chat Sync');
        final chatStopwatch = Stopwatch()..start();
        final syncedMessages = await (incrementalSyncRunner?.call(useGlobalIsolate: useGlobalIsolate) ??
            SyncInterface.performIncrementalSync(useGlobalIsolate: useGlobalIsolate));
        if (syncedMessages.isNotEmpty) {
          // latestMessageIdPerChat is keyed by chat GUID, so syncedMessages already contains
          // at most one message per chat. Deduplicate defensively by keeping the latest
          // message per chat GUID in case the data ever changes.
          final Map<String, Message> latestPerChat = {};
          for (final message in syncedMessages) {
            final chatGuid = message.chat.target?.guid;
            if (chatGuid == null) continue;
            final existing = latestPerChat[chatGuid];
            if (existing == null ||
                (message.dateCreated != null &&
                    (existing.dateCreated == null || message.dateCreated!.isAfter(existing.dateCreated!)))) {
              latestPerChat[chatGuid] = message;
            }
          }

          // IncrementalSyncManager.complete() already called ChatsSvc.updateChat() for every
          // synced chat. Here we only need to push the subtitle update into ChatState.
          // Skip chats where the per-page event already applied the same (or newer) message.
          for (final entry in latestPerChat.entries) {
            final message = entry.value;
            if (message.id != null && processedSubtitleByChat[entry.key] == message.id) continue;
            ChatsSvc.updateChatLatestMessage(entry.key, message, repositionImmediate: false);
          }

          // Dispatch newly synced messages to any currently active chat view.
          // Skip messages already dispatched by a per-page event.
          // Existing messages need their receipt/edit state refreshed as well.
          for (final message in syncedMessages) {
            if (message.id != null && processedMessageIds.contains(message.id)) continue;
            final chatGuid = message.chat.target?.guid;
            if (chatGuid == null || message.guid == null) continue;
            if (Get.isRegistered<MessagesService>(tag: chatGuid)) {
              final service = Get.find<MessagesService>(tag: chatGuid);
              if (service.struct.getMessage(message.guid!) != null) {
                service.updateMessage(message);
              } else {
                await service.addNewMessage(message);
              }
            }
          }
        }

        chatStopwatch.stop();
        Logger.info(
            'Incremental chat sync completed! Synced ${syncedMessages.length} messages across '
            '${syncedMessages.map((m) => m.chat.target?.guid).toSet().length} chats '
            'in ${chatStopwatch.elapsedMilliseconds}ms',
            tag: 'Incremental Chat Sync');
      } catch (e, stack) {
        Logger.error('Incremental chat sync failed!', error: e, trace: stack, tag: 'Incremental Chat Sync');
        chatSyncFailed = true;
      } finally {
        syncIsolate?.removeEventListener(IsolateEvent.incrementalSyncPageComplete, onPageComplete);
      }

      // A failed chat sync must not consume the cooldown window. Otherwise a sync that
      // fails on launch (e.g. no network yet) blocks the retry triggered by the socket
      // reconnect or app resume that follows, and new messages wait out the cooldown.
      // Only the chat sync resets it: contact sync failures are usually persistent
      // (permissions, unsupported server) and shouldn't defeat the throttle.
      if (chatSyncFailed) {
        _lastIncrementalSyncTimestamp = null;
        _needsRecoverySync = true;
        _catchUpTimer?.cancel();
        _catchUpTimer = null;
      } else {
        _needsRecoverySync = false;
        _failureRetryAttempt = 0;
        _cancelFailureRetry();
        if (GetIt.I.isRegistered<ChatsService>() && !ChatsSvc.headless) {
          unawaited(SettingsSvc.refreshServerDetails());
          unawaited(ChatsSvc.syncPinnedChatsFromServer());
        }
      }

      // Stop the global syncing bar once chat/message data is fresh; background contact sync should not keep it spinning.
      _statusTracker.onSyncFinished(success: !chatSyncFailed);
      statusFinished = true;

      var contactSyncResult = true;
      var contactUploadResult = true;
      final address = SettingsSvc.settings.serverAddress.value;
      if (!kIsDesktop && !kIsWeb) {
        if (!chatSyncFailed &&
            (_lastServerContactSync == null ||
                _lastServerContactSyncAddress != address ||
                now.difference(_lastServerContactSync!) >= const Duration(hours: 6))) {
          contactSyncResult = await performContactSyncToHandles();
          contactUploadResult = await performContactSyncToServer();
          if (contactSyncResult && contactUploadResult) {
            _lastServerContactSync = now;
            _lastServerContactSyncAddress = address;
          }
        }
      } else {
        if (!chatSyncFailed &&
            (_lastServerContactSync == null ||
                _lastServerContactSyncAddress != address ||
                now.difference(_lastServerContactSync!) >= _serverContactSyncInterval)) {
          // A failed pull is swallowed in the isolate; a chat sync that reached the server stands in for its success
          contactSyncResult = await performContactSyncToHandles();
          if (contactSyncResult) {
            _lastServerContactSync = now;
            _lastServerContactSyncAddress = address;
          }
        }
        contactUploadResult = await performContactSyncToServer();
      }

      // The chat sync is the one that matters, so its failure is reported alone via SyncSvc.status
      // (no repeated flapping toast/snackbar). Contact failures get their own deduped error toast.
      if (!chatSyncFailed && Get.context != null) {
        if (!contactSyncResult) {
          await showToast(
            "Messages synced, but refreshing contacts failed. Check the logs for details.",
            isError: true,
            issueKey: 'contact_sync_refresh',
          );
        } else if (!contactUploadResult) {
          await showToast(
            "Messages synced, but uploading contacts to the server failed.",
            isError: true,
            issueKey: 'contact_sync_upload',
          );
        } else if (SettingsSvc.settings.showIncrementalSync.value) {
          await showToast('Incremental sync complete');
        }
      }

      if (!chatSyncFailed) {
        clearErrorIssue('sync_connection');
        if (contactSyncResult) clearErrorIssue('contact_sync_refresh');
        if (contactUploadResult) clearErrorIssue('contact_sync_upload');
      }
    } finally {
      if (!statusFinished) {
        _statusTracker.onSyncFinished(success: !chatSyncFailed);
      }
      isIncrementalSyncing.value = false;
      _inManagedIncrementalSync = false;
      if (_retryImmediatelyAfterInFlight) {
        final nextUseGlobalIsolate = _pendingUseGlobalIsolate || useGlobalIsolate;
        _retryImmediatelyAfterInFlight = false;
        _pendingUseGlobalIsolate = false;
        _scheduleImmediateRecovery(useGlobalIsolate: nextUseGlobalIsolate);
      } else if (chatSyncFailed) {
        _scheduleFailureRetry(useGlobalIsolate: useGlobalIsolate);
      }
    }
  }

  /// The one pending catch-up sync, if a [startIncrementalSync] `catchUp` request was held off.
  Timer? _catchUpTimer;

  void _cancelFailureRetry() {
    _failureRetryTimer?.cancel();
    _failureRetryTimer = null;
  }

  void _cancelManualRetryHttpFallback() {
    _manualRetryHttpFallbackTimer?.cancel();
    _manualRetryHttpFallbackTimer = null;
  }

  void _scheduleManualRetryHttpFallback() {
    _cancelManualRetryHttpFallback();
    _manualRetryHttpFallbackTimer = Timer(_manualRetryHttpFallbackDelay, () {
      _manualRetryHttpFallbackTimer = null;
      if (_socketConnected || !_connectionDesired || _authFailed) return;
      if (GetIt.I.isRegistered<SocketService>() && SocketSvc.state.value == SocketState.connected) return;
      _lastIncrementalSyncTimestamp = null;
      unawaited(startIncrementalSync(catchUp: true));
    });
  }

  void _triggerRecoverySync() {
    _failureRetryAttempt = 0;
    _cancelFailureRetry();
    _cancelManualRetryHttpFallback();
    if (isIncrementalSyncing.value) {
      _retryImmediatelyAfterInFlight = true;
      return;
    }
    _lastIncrementalSyncTimestamp = null;
    unawaited(startIncrementalSync(catchUp: true));
  }

  void _scheduleImmediateRecovery({bool useGlobalIsolate = false}) {
    _cancelFailureRetry();
    _lastIncrementalSyncTimestamp = null;
    _failureRetryTimer = Timer(Duration.zero, () {
      _failureRetryTimer = null;
      unawaited(startIncrementalSync(useGlobalIsolate: useGlobalIsolate, catchUp: true));
    });
  }

  void _scheduleFailureRetry({bool useGlobalIsolate = false}) {
    if (!_needsRecoverySync || !_networkOnline || !_connectionDesired || _authFailed) return;
    if (_failureRetryTimer?.isActive ?? false) return;
    if (_failureRetryAttempt >= _maxFailureRetryAttempts) return;
    final delay = _failureRetryAttempt < _failureRetryDelays.length
        ? _failureRetryDelays[_failureRetryAttempt]
        : _maxFailureRetryDelay;
    _failureRetryAttempt++;
    _failureRetryTimer = Timer(delay, () {
      _failureRetryTimer = null;
      if (!_needsRecoverySync || !_networkOnline || !_connectionDesired || _authFailed) return;
      unawaited(startIncrementalSync(useGlobalIsolate: useGlobalIsolate, catchUp: true));
    });
  }

  void _scheduleCatchUp(Duration wait, bool useGlobalIsolate) {
    if (!_connectionDesired || _authFailed) return;
    if (_catchUpTimer?.isActive ?? false) return;
    // A sync still running past the cooldown is retried shortly after
    final delay = wait > Duration.zero ? wait : const Duration(seconds: 5);
    _catchUpTimer = Timer(delay, () {
      _catchUpTimer = null;
      if (!_connectionDesired || _authFailed) return;
      unawaited(startIncrementalSync(useGlobalIsolate: useGlobalIsolate, catchUp: true));
    });
  }

  Future<bool> performContactSyncToHandles() async {
    if (!GetIt.I.isRegistered<ContactServiceV2>()) return true;
    try {
      Logger.info('Starting contact refresh', tag: 'Incremental Contact Sync');
      final contactStopwatch = Stopwatch()..start();
      final refreshedHandleIds = await ContactsSvcV2.syncContactsToHandles();
      contactStopwatch.stop();
      Logger.info(
          'Finished contact refresh, refreshed ${refreshedHandleIds.length} handles in ${contactStopwatch.elapsedMilliseconds}ms',
          tag: 'Incremental Contact Sync');

      if (refreshedHandleIds.isNotEmpty) {
        ContactsSvcV2.notifyHandlesUpdated(refreshedHandleIds);
      }

      return true;
    } catch (ex, stack) {
      Logger.error('Contacts refresh failed!', error: ex, trace: stack, tag: 'Incremental Contact Sync');
      return false;
    }
  }

  Future<bool> performContactSyncToServer() async {
    try {
      // Auto upload contacts if requested
      if (!kIsWeb && Platform.isAndroid && SettingsSvc.settings.syncContactsAutomatically.value) {
        Logger.debug("Starting contact upload to server...", tag: "Contact Upload");
        final contactUploadStopwatch = Stopwatch()..start();
        // Get all contacts from ContactServiceV2
        final contactsV2 = await ContactsSvcV2.getAllContacts();
        final deviceId = await getAndroidId();
        final _contacts = <Map<String, dynamic>>[];
        for (final c in contactsV2) {
          _contacts.add(c.toServerMap(deviceId: deviceId));
        }

        await ContactV2Interface.uploadContacts(_contacts, deviceId: deviceId);
        contactUploadStopwatch.stop();
        Logger.debug("Contact upload complete in ${contactUploadStopwatch.elapsedMilliseconds}ms",
            tag: "Contact Upload");
      }

      return true;
    } catch (e, stack) {
      Logger.error("Failed to upload contacts!", error: e, trace: stack, tag: "Contact Upload");
      return false;
    }
  }
}

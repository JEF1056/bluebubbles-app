part of 'messages_service.dart';

extension MessagesServiceFork on MessagesService {
  bool _isIndicatorVisibleMessage(Message m) {
    if (m.guid == null || m.dateDeleted != null) return false;
    if (m.isReaction || m.isGroupEvent) return false;
    final state = messageStates[m.guid!];
    if (AppSessionTypes.isGame(m) &&
        (state?.associatedMessageType.value ?? m.associatedMessageType) == AppSessionTypes.SUPERSEDED) {
      return false;
    }
    if (state != null ? state.isFullyUnsent : m.hasUnsentParts) return false;
    return true;
  }

  bool _isSentOnlyEligible(Message m) {
    if (m.isFromMe != true || !_isIndicatorVisibleMessage(m)) return false;
    final guid = m.guid!;
    if (guid.startsWith('temp') || guid.startsWith('error')) return false;
    if (m.error > 0) return false;
    if (m.dateRead != null || m.dateDelivered != null || m.isDelivered) return false;
    return true;
  }

  /// True when [candidate] is newer than [current] (using [dateCreated], with
  /// [struct.messages] newest-first ordering as tie-breaker for identical ms).
  bool _isMoreRecentMessage(Message candidate, MessageReceiptInfo? current) {
    if (current == null) return true;
    if (candidate.guid == current.guid) return false;
    final candidateDate = candidate.dateCreated;
    final currentDate = current.createdDate;
    if (candidateDate == null) return false;
    if (currentDate == null) return true;
    if (candidateDate.isAfter(currentDate)) return true;
    if (candidateDate.isBefore(currentDate)) return false;
    final list = struct.messages;
    final candIdx = list.indexWhere((m) => m.guid == candidate.guid);
    final currIdx = list.indexWhere((m) => m.guid == current.guid);
    return candIdx >= 0 && (currIdx < 0 || candIdx < currIdx);
  }

  /// True when [candidate] is strictly newer than [against] (or [against] is
  /// null). When dates are unavailable, the higher tier wins (returns false).
  bool _isReceiptNewer(MessageReceiptInfo candidate, MessageReceiptInfo? against) {
    if (against == null) return true;
    final candDate = candidate.createdDate;
    final againstDate = against.createdDate;
    if (candDate == null || againstDate == null) return false;
    if (candDate.isAfter(againstDate)) return true;
    if (candDate.isBefore(againstDate)) return false;
    final list = struct.messages;
    final candIdx = list.indexWhere((m) => m.guid == candidate.guid);
    final againstIdx = list.indexWhere((m) => m.guid == against.guid);
    return candIdx >= 0 && againstIdx >= 0 && candIdx < againstIdx;
  }

  /// Targeted rescan for the sent-only tier.
  void _recomputeSentIndicator() {
    final outgoing = struct.messages
        .where((e) => _isSentOnlyEligible(e))
        .toList()
      ..sort(Message.sort);
    final best = outgoing.firstOrNull;
    if (best?.guid != null) {
      _lastSentInfo = MessageReceiptInfo(best!.guid!, createdDate: best.dateCreated);
    }
    _normalizeSentVsReadAndDelivered();
  }

  /// Suppresses or enables the sent indicator based on whether a newer (or
  /// same-age) read or delivered message exists.
  void _normalizeSentVsReadAndDelivered() {
    if (_lastSentInfo == null) return;
    final shouldShow =
        _isReceiptNewer(_lastSentInfo!, _lastReadInfo) && _isReceiptNewer(_lastSentInfo!, _lastDeliveredInfo);
    messageStates[_lastSentInfo!.guid]?.updateShowSentIndicatorInternal(shouldShow);
  }

  void _hydrateThreadOriginators(
    Iterable<Message> messages, {
    ConversationViewController? controller,
  }) {
    final cvController = controller ??
        (Get.isRegistered<ConversationViewController>(tag: tag)
            ? Get.find<ConversationViewController>(tag: tag)
            : null);
    for (final m in messages) {
      final guid = m.threadOriginatorGuid;
      if (guid == null || guid.isEmpty) continue;
      if (struct.getThreadOriginator(guid) != null) continue;

      Message? threadOriginator;
      try {
        threadOriginator = Message.findOne(guid: guid);
      } catch (_) {}

      if (threadOriginator != null) {
        final c = getOrCreateState(threadOriginator);
        if (cvController != null) c.cvController = cvController;
        struct.addThreadOriginator(threadOriginator);
        continue;
      }

      unawaited(_fetchMissingThreadOriginator(guid, controller: cvController));
    }
  }

  Future<void> _fetchMissingThreadOriginator(
    String guid, {
    ConversationViewController? controller,
  }) async {
    if (_fetchingOriginatorGuids.contains(guid) || _missingOriginatorGuids.contains(guid)) return;
    if (!GetIt.I.isRegistered<HttpService>()) return;
    _fetchingOriginatorGuids.add(guid);
    try {
      final response = await HttpSvc.message.fetchOne(
        guid,
        withQuery: "attributedBody,messageSummaryInfo,payloadData,attachment,handle,attachment.metadata",
      );
      if (isClosed) return;
      final raw = response.data?['data'];
      if (raw is! Map) {
        _missingOriginatorGuids.add(guid);
        return;
      }
      final originator = Message.fromMap(Map<String, dynamic>.from(raw));
      final c = getOrCreateState(originator);
      final cvController = controller ??
          (Get.isRegistered<ConversationViewController>(tag: tag)
              ? Get.find<ConversationViewController>(tag: tag)
              : null);
      if (cvController != null) c.cvController = cvController;
      struct.addThreadOriginator(originator);
      for (final reply in struct.messages) {
        if (reply.threadOriginatorGuid == guid && reply.guid != null) {
          triggerMessageUpdate(reply.guid!);
        }
      }
    } catch (_) {
      // Best-effort hydration; avoid crashing on offline/transient failures.
    } finally {
      _fetchingOriginatorGuids.remove(guid);
    }
  }
}

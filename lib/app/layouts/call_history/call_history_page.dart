import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/components/facetime/facetime_link_sheet.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

enum CallLogFilter { all, missed, video }

enum CallDayBucket { today, yesterday, earlier }

class CallLogEntry {
  const CallLogEntry({
    required this.id,
    required this.date,
    required this.duration,
    required this.direction,
    required this.service,
    required this.isVideo,
    required this.address,
    this.name,
    required this.participants,
    this.read = true,
  });

  final String id;
  final DateTime date;
  final int duration;
  final String direction;
  final String service;
  final bool isVideo;
  final String address;
  final String? name;
  final List<String> participants;
  final bool read;

  bool get isMissed => direction == 'missed';
  bool get isOutgoing => direction == 'outgoing';
  bool get isPhone => service == 'phone';
  String get primaryAddress => participants.isNotEmpty ? participants.first : address;

  factory CallLogEntry.fromJson(Map<String, dynamic> json) {
    final rawDate = json['date'];
    final int epochMs = rawDate is num ? rawDate.toInt() : int.tryParse(rawDate?.toString() ?? '') ?? 0;
    final rawDuration = json['duration'];
    final int durationSecs = rawDuration is num ? rawDuration.round() : int.tryParse(rawDuration?.toString() ?? '') ?? 0;
    final address = (json['address'] ?? '').toString();
    final rawParticipants = json['participants'];
    final parsedParticipants = rawParticipants is List
        ? rawParticipants.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList(growable: false)
        : <String>[];
    final participants = parsedParticipants.isNotEmpty
        ? parsedParticipants
        : (address.trim().isNotEmpty ? <String>[address.trim()] : const <String>[]);
    final service = (json['service'] ?? 'facetime_audio').toString();
    final isVideo = json['isVideo'] == true || service == 'facetime_video';

    return CallLogEntry(
      id: (json['id'] ?? '').toString(),
      date: DateTime.fromMillisecondsSinceEpoch(epochMs),
      duration: durationSecs < 0 ? 0 : durationSecs,
      direction: (json['direction'] ?? 'incoming').toString(),
      service: service,
      isVideo: isVideo,
      address: address,
      name: json['name']?.toString(),
      participants: participants,
      read: json['read'] != false,
    );
  }
}

class CallHistoryResult {
  const CallHistoryResult({
    required this.entries,
    this.available = true,
    this.reason,
    this.hasMore,
  });

  final List<CallLogEntry> entries;
  final bool available;
  final String? reason;
  final bool? hasMore;
}

typedef CallHistoryLoader = Future<CallHistoryResult> Function({
  required int limit,
  required int offset,
  required bool missedOnly,
});

CallDayBucket bucketCallDate(DateTime date, {DateTime? now}) {
  final localDate = date.toLocal();
  final localNow = (now ?? DateTime.now()).toLocal();
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final target = DateTime(localDate.year, localDate.month, localDate.day);
  final diffDays = today.difference(target).inDays;
  if (diffDays <= 0) return CallDayBucket.today;
  if (diffDays == 1) return CallDayBucket.yesterday;
  return CallDayBucket.earlier;
}

String callDayBucketLabel(CallDayBucket bucket) {
  switch (bucket) {
    case CallDayBucket.today:
      return 'Today';
    case CallDayBucket.yesterday:
      return 'Yesterday';
    case CallDayBucket.earlier:
      return 'Earlier';
  }
}

String formatCallDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final mins = safe ~/ 60;
  final secs = safe % 60;
  return '$mins:${secs.toString().padLeft(2, '0')}';
}

String formatRelativeCallTime(DateTime date, {DateTime? now}) {
  final localDate = date.toLocal();
  final localNow = (now ?? DateTime.now()).toLocal();
  final diff = localNow.difference(localDate);
  if (diff.inMinutes < 1 && !diff.isNegative) return 'Just now';
  if (diff.inMinutes < 60 && !diff.isNegative) return '${diff.inMinutes}m ago';
  final bucket = bucketCallDate(localDate, now: localNow);
  if (bucket == CallDayBucket.today) return DateFormat.jm().format(localDate);
  if (bucket == CallDayBucket.yesterday) return 'Yesterday';
  return DateFormat.MMMd().format(localDate);
}

class CallHistoryPage extends StatefulWidget {
  const CallHistoryPage({
    super.key,
    this.loader,
    this.onCreateLink,
  });

  final CallHistoryLoader? loader;
  final VoidCallback? onCreateLink;

  @override
  State<CallHistoryPage> createState() => _CallHistoryPageState();
}

class _CallHistoryPageState extends State<CallHistoryPage> {
  static const int _pageSize = 50;
  static const double _outerRadius = FaceTimeDims.sheetTopRadius; // 28dp M3E outer corners
  static const double _innerRadius = 4.0;
  static const double _itemGap = 2.0;

  final ScrollController _scrollController = ScrollController();
  final Set<String> _expandedIds = <String>{};

  CallLogFilter _filter = CallLogFilter.all;
  List<CallLogEntry> _entries = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _available = true;
  String? _unavailableReason;
  String? _errorMessage;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loading || _loadingMore || !_hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  Future<CallHistoryResult> _fetch({
    required int limit,
    required int offset,
    required bool missedOnly,
  }) async {
    if (widget.loader != null) {
      return widget.loader!(limit: limit, offset: offset, missedOnly: missedOnly);
    }
    final response = await HttpSvc.faceTime.getCallHistory(
      limit: limit,
      offset: offset,
      missedOnly: missedOnly,
    );
    final body = response.data is Map ? response.data as Map : const {};
    final metadata = body['metadata'] is Map ? body['metadata'] as Map : const {};
    final rawList = body['data'] is List ? body['data'] as List : const [];
    final entries = rawList
        .whereType<Map>()
        .map((m) => CallLogEntry.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
    final available = metadata['available'] != false;
    final reason = metadata['reason']?.toString();
    final hasMore = entries.length >= limit;
    return CallHistoryResult(
      entries: entries,
      available: available,
      reason: reason,
      hasMore: hasMore,
    );
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
      _offset = 0;
    });
    try {
      final result = await _fetch(
        limit: _pageSize,
        offset: 0,
        missedOnly: _filter == CallLogFilter.missed,
      );
      if (!mounted) return;
      setState(() {
        _entries = result.entries;
        _available = result.available;
        _unavailableReason = result.reason;
        _hasMore = result.hasMore ?? (result.entries.length >= _pageSize);
        _offset = result.entries.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final result = await _fetch(
        limit: _pageSize,
        offset: _offset,
        missedOnly: _filter == CallLogFilter.missed,
      );
      if (!mounted) return;
      setState(() {
        _entries = [..._entries, ...result.entries];
        _hasMore = result.hasMore ?? (result.entries.length >= _pageSize);
        _offset += result.entries.length;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _selectFilter(CallLogFilter next) {
    if (_filter == next) return;
    final needsReload = _filter == CallLogFilter.missed || next == CallLogFilter.missed;
    setState(() => _filter = next);
    if (needsReload) {
      _loadInitial();
    }
  }

  List<CallLogEntry> get _visibleEntries {
    switch (_filter) {
      case CallLogFilter.all:
        return _entries;
      case CallLogFilter.missed:
        return _entries.where((e) => e.isMissed).toList(growable: false);
      case CallLogFilter.video:
        return _entries.where((e) => e.isVideo).toList(growable: false);
    }
  }

  String _resolveAddressLabel(String address, {String? fallbackName}) {
    if (GetIt.I.isRegistered<ContactServiceV2>()) {
      final contact = ContactsSvcV2.findContactForAddressSync(address);
      if (contact != null && contact.displayName.trim().isNotEmpty) {
        return contact.displayName.trim();
      }
    }
    if (fallbackName != null && fallbackName.trim().isNotEmpty) {
      return fallbackName.trim();
    }
    return address;
  }

  String _resolveEntryTitle(CallLogEntry entry) {
    final addrs = entry.participants;
    if (addrs.isEmpty) {
      return entry.name?.trim().isNotEmpty == true ? entry.name!.trim() : 'Unknown';
    }
    if (addrs.length == 1) {
      return _resolveAddressLabel(addrs.first, fallbackName: entry.name);
    }
    return addrs.map((a) => _resolveAddressLabel(a)).join(', ');
  }

  bool _canCallbackAddress(CallLogEntry entry, String address) {
    if (address.trim().isEmpty) return false;
    if (!GetIt.I.isRegistered<SettingsService>()) return true;
    if (entry.isPhone) {
      return canContinuityCall(hasPhone: true);
    }
    return canFaceTimeAddress(address);
  }

  Future<void> _placeCallback(CallLogEntry entry, String address) async {
    final label = _resolveAddressLabel(address, fallbackName: entry.participants.length == 1 ? entry.name : null);
    await startFaceTimeForAddress(
      context,
      address: address,
      callerName: label,
      video: entry.isVideo,
      isTelephony: entry.isPhone,
    );
  }

  void _openMessageForEntry(CallLogEntry entry) {
    final addrs = entry.participants;
    if (addrs.isEmpty) return;
    final selected = addrs
        .map((addr) => SelectedContact(
              displayName: _resolveAddressLabel(addr, fallbackName: addrs.length == 1 ? entry.name : null),
              address: addr,
            ))
        .toList(growable: false);
    NavigationSvc.closeSections();
    NavigationSvc.pushAndRemoveUntil(
      context,
      NewChatCreator(initialSelected: selected),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? FaceTimePalette.blueDark : FaceTimePalette.blue;
    final missedColor = isDark ? FaceTimePalette.redDarkSkin : FaceTimePalette.red;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: accent,
          onRefresh: _loadInitial,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (Navigator.of(context).canPop())
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: IconButton(
                                onPressed: () => Navigator.of(context).maybePop(),
                                icon: const Icon(Icons.arrow_back_rounded),
                                tooltip: 'Back',
                              ),
                            ),
                          Expanded(
                            child: Text(
                              'Calls',
                              style: theme.textTheme.headlineLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed: widget.onCreateLink ?? () => createAndShareFaceTimeLink(context),
                            style: FilledButton.styleFrom(
                              shape: const StadiumBorder(),
                              minimumSize: const Size(0, 40),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: const Text('Create Link'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _FilterPillRow(
                        selected: _filter,
                        accent: accent,
                        onSelected: _selectFilter,
                      ),
                    ],
                  ),
                ),
              ),
              ..._buildBodySlivers(context, theme, colorScheme, accent, missedColor),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBodySlivers(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    Color accent,
    Color missedColor,
  ) {
    if (_loading) {
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: _SkeletonGroup(
              outerRadius: _outerRadius,
              innerRadius: _innerRadius,
              gap: _itemGap,
              fillColor: colorScheme.surfaceContainer,
            ),
          ),
        ),
      ];
    }

    if (!_available) {
      return [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: _StatusCard(
              icon: Icons.lock_outline_rounded,
              title: "Mac can't read call history — grant Full Disk Access to BlueBubbles Server",
              subtitle: _unavailableReason,
              accent: accent,
              onRetry: _loadInitial,
            ),
          ),
        ),
      ];
    }

    if (_errorMessage != null) {
      return [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: _StatusCard(
              icon: Icons.cloud_off_rounded,
              title: "Couldn't load call history",
              subtitle: _errorMessage,
              accent: accent,
              onRetry: _loadInitial,
            ),
          ),
        ),
      ];
    }

    final items = _visibleEntries;
    if (items.isEmpty) {
      final emptyTitle = switch (_filter) {
        CallLogFilter.all => 'No calls yet',
        CallLogFilter.missed => 'No missed calls',
        CallLogFilter.video => 'No video calls',
      };
      return [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: _StatusCard(
              icon: Icons.call_outlined,
              title: emptyTitle,
              subtitle: _filter == CallLogFilter.all
                  ? 'Recent FaceTime and Phone calls synced from your Mac will appear here.'
                  : 'Try switching back to All calls.',
              accent: accent,
              actionLabel: _filter == CallLogFilter.all ? 'Refresh' : 'Show all calls',
              onRetry: _filter == CallLogFilter.all
                  ? _loadInitial
                  : () => _selectFilter(CallLogFilter.all),
            ),
          ),
        ),
      ];
    }

    final grouped = <CallDayBucket, List<CallLogEntry>>{};
    for (final entry in items) {
      final bucket = bucketCallDate(entry.date);
      grouped.putIfAbsent(bucket, () => <CallLogEntry>[]).add(entry);
    }

    final slivers = <Widget>[];
    for (final bucket in CallDayBucket.values) {
      final sectionEntries = grouped[bucket];
      if (sectionEntries == null || sectionEntries.isEmpty) continue;
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              callDayBucketLabel(bucket),
              style: theme.textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final entry = sectionEntries[index];
                final isFirst = index == 0;
                final isLast = index == sectionEntries.length - 1;
                final borderRadius = BorderRadius.vertical(
                  top: Radius.circular(isFirst ? _outerRadius : _innerRadius),
                  bottom: Radius.circular(isLast ? _outerRadius : _innerRadius),
                );
                return Padding(
                  padding: EdgeInsets.only(bottom: isLast ? 0 : _itemGap),
                  child: _CallLogRow(
                    entry: entry,
                    title: _resolveEntryTitle(entry),
                    expanded: _expandedIds.contains(entry.id),
                    borderRadius: borderRadius,
                    accent: accent,
                    missedColor: missedColor,
                    canCallback: _canCallbackAddress(entry, entry.primaryAddress),
                    resolveAddressLabel: (addr) => _resolveAddressLabel(addr),
                    canCallbackParticipant: (addr) => _canCallbackAddress(entry, addr),
                    onToggleExpand: () {
                      setState(() {
                        if (!_expandedIds.add(entry.id)) {
                          _expandedIds.remove(entry.id);
                        }
                      });
                    },
                    onCallback: () => _placeCallback(entry, entry.primaryAddress),
                    onCallbackParticipant: (addr) => _placeCallback(entry, addr),
                    onMessage: () => _openMessageForEntry(entry),
                  ),
                );
              },
              childCount: sectionEntries.length,
            ),
          ),
        ),
      );
    }

    if (_loadingMore) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
          ),
        ),
      );
    }

    return slivers;
  }
}

class _FilterPillRow extends StatelessWidget {
  const _FilterPillRow({
    required this.selected,
    required this.accent,
    required this.onSelected,
  });

  final CallLogFilter selected;
  final Color accent;
  final ValueChanged<CallLogFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final filter in CallLogFilter.values)
          FilterChip(
            label: Text(switch (filter) {
              CallLogFilter.all => 'All',
              CallLogFilter.missed => 'Missed',
              CallLogFilter.video => 'Video',
            }),
            selected: selected == filter,
            showCheckmark: false,
            selectedColor: accent.withValues(alpha: 0.16),
            backgroundColor: colorScheme.surfaceContainer,
            side: BorderSide(
              color: selected == filter ? accent : colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            shape: const StadiumBorder(),
            labelStyle: TextStyle(
              color: selected == filter ? accent : colorScheme.onSurfaceVariant,
              fontWeight: selected == filter ? FontWeight.w600 : FontWeight.w500,
            ),
            onSelected: (_) => onSelected(filter),
          ),
      ],
    );
  }
}

class _CallLogRow extends StatelessWidget {
  const _CallLogRow({
    required this.entry,
    required this.title,
    required this.expanded,
    required this.borderRadius,
    required this.accent,
    required this.missedColor,
    required this.canCallback,
    required this.resolveAddressLabel,
    required this.canCallbackParticipant,
    required this.onToggleExpand,
    required this.onCallback,
    required this.onCallbackParticipant,
    required this.onMessage,
  });

  final CallLogEntry entry;
  final String title;
  final bool expanded;
  final BorderRadius borderRadius;
  final Color accent;
  final Color missedColor;
  final bool canCallback;
  final String Function(String address) resolveAddressLabel;
  final bool Function(String address) canCallbackParticipant;
  final VoidCallback onToggleExpand;
  final VoidCallback onCallback;
  final ValueChanged<String> onCallbackParticipant;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final durationLabel = formatCallDuration(entry.duration);
    final relativeTime = formatRelativeCallTime(entry.date);
    final directionIcon = switch (entry.direction) {
      'outgoing' => Icons.call_made_rounded,
      'missed' => Icons.call_missed_rounded,
      _ => Icons.call_received_rounded,
    };
    final serviceIcon = entry.isVideo ? Icons.videocam_rounded : Icons.call_rounded;
    final serviceLabel = switch (entry.service) {
      'facetime_video' => 'FaceTime Video',
      'phone' => 'Phone Call',
      _ => 'FaceTime Audio',
    };

    return Material(
      color: colorScheme.surfaceContainer,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onToggleExpand,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _CallAvatar(
                    participants: entry.participants,
                    resolveLabel: resolveAddressLabel,
                    borderColor: colorScheme.surfaceContainer,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: entry.isMissed ? missedColor : colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              directionIcon,
                              size: 15,
                              color: entry.isMissed ? missedColor : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              serviceIcon,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '$durationLabel · $relativeTime',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (canCallback)
                    IconButton(
                      onPressed: onCallback,
                      tooltip: entry.isVideo ? 'FaceTime Video' : (entry.isPhone ? 'Phone Call' : 'FaceTime Audio'),
                      icon: Icon(
                        entry.isVideo ? Icons.videocam_outlined : Icons.call_outlined,
                        color: accent,
                      ),
                    ),
                ],
              ),
              AnimatedSize(
                duration: FaceTimeMotion.of(context, FaceTimeMotion.short),
                curve: FaceTimeMotion.emphasized,
                alignment: Alignment.topCenter,
                child: expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
                            const SizedBox(height: 10),
                            Text(
                              '${DateFormat.yMMMd().add_jm().format(entry.date.toLocal())} · $serviceLabel · $durationLabel',
                              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                            ),
                            if (entry.participants.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              for (final addr in entry.participants)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    children: [
                                      _CallAvatar(
                                        participants: [addr],
                                        resolveLabel: resolveAddressLabel,
                                        size: 32,
                                        borderColor: colorScheme.surfaceContainer,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              resolveAddressLabel(addr),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                            ),
                                            if (resolveAddressLabel(addr) != addr)
                                              Text(
                                                addr,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (canCallbackParticipant(addr))
                                        IconButton(
                                          onPressed: () => onCallbackParticipant(addr),
                                          icon: Icon(
                                            entry.isVideo ? Icons.videocam_outlined : Icons.call_outlined,
                                            size: 20,
                                            color: accent,
                                          ),
                                          tooltip: 'Call $addr',
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton.tonalIcon(
                                onPressed: onMessage,
                                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                                label: const Text('Message'),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallAvatar extends StatelessWidget {
  const _CallAvatar({
    required this.participants,
    required this.resolveLabel,
    required this.borderColor,
    this.size = 44,
  });

  final List<String> participants;
  final String Function(String address) resolveLabel;
  final Color borderColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasContactSvc = GetIt.I.isRegistered<ContactServiceV2>() &&
        GetIt.I.isRegistered<SettingsService>() &&
        GetIt.I.isRegistered<ThemesService>();
    if (participants.length <= 1) {
      final addr = participants.isEmpty ? '' : participants.first;
      if (hasContactSvc && addr.isNotEmpty) {
        return ContactAvatarWidget(
          handle: Handle(address: addr),
          size: size,
          editable: false,
          scaleSize: false,
        );
      }
      return FaceTimeAvatar(
        callerName: addr.isEmpty ? '?' : resolveLabel(addr),
        size: size,
      );
    }

    final shown = participants.take(2).toList(growable: false);
    final itemSize = size * 0.7;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: _CallAvatar(
              participants: [shown[0]],
              resolveLabel: resolveLabel,
              borderColor: borderColor,
              size: itemSize,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: 1.5),
              ),
              child: _CallAvatar(
                participants: [shown[1]],
                resolveLabel: resolveAddressLabelFallback(shown[1], resolveLabel),
                borderColor: borderColor,
                size: itemSize,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String Function(String) resolveAddressLabelFallback(String _, String Function(String) fn) => fn;
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.accent,
    required this.onRetry,
    this.actionLabel = 'Retry',
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color accent;
  final VoidCallback onRetry;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(FaceTimeDims.sheetTopRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: accent),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: onRetry,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _SkeletonGroup extends StatelessWidget {
  const _SkeletonGroup({
    required this.outerRadius,
    required this.innerRadius,
    required this.gap,
    required this.fillColor,
  });

  final double outerRadius;
  final double innerRadius;
  final double gap;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    final shimmerColor = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(
      children: List.generate(5, (index) {
        final isFirst = index == 0;
        final isLast = index == 4;
        return Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : gap),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(isFirst ? outerRadius : innerRadius),
                bottom: Radius.circular(isLast ? outerRadius : innerRadius),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: shimmerColor),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 140,
                        decoration: BoxDecoration(color: shimmerColor, borderRadius: BorderRadius.circular(6)),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 11,
                        width: 96,
                        decoration: BoxDecoration(color: shimmerColor, borderRadius: BorderRadius.circular(6)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

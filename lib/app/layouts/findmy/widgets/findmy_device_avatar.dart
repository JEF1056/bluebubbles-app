import 'dart:async';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

typedef FindMyDeviceIconFetcher = Future<Uint8List?> Function(String deviceId);

/// In-memory byte cache for Find My device/item product images fetched via
/// the authenticated BlueBubbles server proxy (`/api/v1/icloud/findmy/devices/icon`).
class FindMyDeviceIconCache {
  FindMyDeviceIconCache({
    this.maxEntries = 128,
    this.failureCooldown = const Duration(minutes: 2),
  });

  static final FindMyDeviceIconCache instance = FindMyDeviceIconCache();

  final int maxEntries;
  final Duration failureCooldown;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  final Map<String, DateTime> _failures = <String, DateTime>{};
  final Map<String, Future<Uint8List?>> _inflight = <String, Future<Uint8List?>>{};

  String cacheKeyFor(FindMyDevice device) =>
      '${device.id?.trim() ?? ''}|${device.iconUrl?.trim() ?? ''}';

  Uint8List? peek(FindMyDevice device) {
    if (!device.hasPreviewIcon) return null;
    final key = cacheKeyFor(device);
    final hit = _bytes.remove(key);
    if (hit != null) {
      _bytes[key] = hit;
    }
    return hit;
  }

  void seedForTest(FindMyDevice device, Uint8List bytes) {
    if (!device.hasPreviewIcon || bytes.isEmpty) return;
    _store(cacheKeyFor(device), bytes);
  }

  void clear() {
    _bytes.clear();
    _failures.clear();
    _inflight.clear();
  }

  void _store(String key, Uint8List bytes) {
    _bytes.remove(key);
    _bytes[key] = bytes;
    while (_bytes.length > maxEntries) {
      _bytes.remove(_bytes.keys.first);
    }
    _failures.remove(key);
  }

  static bool _looksLikeNonRasterPayload(Uint8List bytes) {
    if (bytes.isEmpty) return true;
    for (final b in bytes) {
      if (b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09) continue;
      return b == 0x3C || b == 0x7B;
    }
    return true;
  }

  Future<Uint8List?> getOrFetch(
    FindMyDevice device, {
    FindMyDeviceIconFetcher? fetcher,
    DateTime Function()? now,
  }) async {
    if (!device.hasPreviewIcon) return null;
    final id = device.id!.trim();
    final key = cacheKeyFor(device);
    final cached = peek(device);
    if (cached != null) return cached;

    final currentTime = (now ?? DateTime.now)();
    final failedAt = _failures[key];
    if (failedAt != null && currentTime.difference(failedAt) < failureCooldown) {
      return null;
    }

    final pending = _inflight[key];
    if (pending != null) return pending;

    final future = _fetchAndCache(
      id: id,
      key: key,
      fetcher: fetcher ?? _defaultFetch,
      now: now ?? DateTime.now,
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  Future<Uint8List?> _fetchAndCache({
    required String id,
    required String key,
    required FindMyDeviceIconFetcher fetcher,
    required DateTime Function() now,
  }) async {
    try {
      final bytes = await fetcher(id);
      if (bytes != null && !_looksLikeNonRasterPayload(bytes)) {
        _store(key, bytes);
        return bytes;
      }
    } catch (_) {
      // Fall through to cooldown cache so scroll/rebuilds do not hammer the proxy.
    }
    _failures[key] = now();
    return null;
  }

  static Future<Uint8List?> _defaultFetch(String deviceId) async {
    if (!GetIt.I.isRegistered<HttpService>()) return null;
    final response = await HttpSvc.icloud.getDeviceIcon(deviceId);
    final status = response.statusCode ?? 200;
    if (status < 200 || status >= 300) return null;
    final data = response.data;
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    return null;
  }
}

/// Standardized circular device/item medallion avatar used across map pins,
/// list tiles, detail sheets, and the nearby BLE radar sheet.
class FindMyDeviceAvatar extends StatefulWidget {
  const FindMyDeviceAvatar({
    super.key,
    required this.device,
    this.size = 42,
    this.redacted = false,
    this.showSurface = true,
    this.surfaceForImageOnly = false,
    this.showEmojiBadge = true,
    this.fallbackIcon,
    this.fallbackIconColor,
    this.cache,
    this.fetcher,
  });

  final FindMyDevice device;
  final double size;
  final bool redacted;
  final bool showSurface;
  final bool surfaceForImageOnly;
  final bool showEmojiBadge;
  final IconData? fallbackIcon;
  final Color? fallbackIconColor;
  final FindMyDeviceIconCache? cache;
  final FindMyDeviceIconFetcher? fetcher;

  /// Neutral mid-tone surface so both dark earbuds/phones and white AirTags/SmartTags
  /// read crisply in light and dark mode.
  static Color imageSurfaceColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF313742)
        : const Color(0xFFECEFF4);
  }

  @override
  State<FindMyDeviceAvatar> createState() => _FindMyDeviceAvatarState();
}

class _FindMyDeviceAvatarState extends State<FindMyDeviceAvatar> {
  Uint8List? _bytes;
  bool _decodeFailed = false;

  FindMyDeviceIconCache get _cache => widget.cache ?? FindMyDeviceIconCache.instance;

  @override
  void initState() {
    super.initState();
    _bytes = _cache.peek(widget.device);
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant FindMyDeviceAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKey = _cache.cacheKeyFor(oldWidget.device);
    final newKey = _cache.cacheKeyFor(widget.device);
    if (oldKey != newKey || oldWidget.cache != widget.cache || oldWidget.fetcher != widget.fetcher) {
      _bytes = _cache.peek(widget.device);
      _decodeFailed = false;
      _loadIfNeeded();
    }
  }

  Future<void> _loadIfNeeded() async {
    if (_bytes != null || _decodeFailed || !widget.device.hasPreviewIcon) return;
    final requestedKey = _cache.cacheKeyFor(widget.device);
    final fetched = await _cache.getOrFetch(widget.device, fetcher: widget.fetcher);
    if (!mounted || fetched == null) return;
    if (_cache.cacheKeyFor(widget.device) != requestedKey) return;
    setState(() {
      _bytes = fetched;
      _decodeFailed = false;
    });
  }

  Widget _buildFallbackContent(BuildContext context) {
    final emoji = widget.redacted ? null : widget.device.roleEmoji;
    if (emoji != null) {
      return Center(
        child: Text(
          emoji,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: widget.size * 0.46, height: 1.0),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Icon(
        widget.fallbackIcon ?? iconForFindMyDevice(widget.device),
        size: widget.size * 0.5,
        color: widget.fallbackIconColor ?? cs.onSurface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasImage = _bytes != null && !_decodeFailed;
    final emoji = widget.redacted ? null : widget.device.roleEmoji;
    final drawSurface = widget.showSurface || (hasImage && widget.surfaceForImageOnly);

    final Color? fillColor = !drawSurface
        ? null
        : (hasImage ? FindMyDeviceAvatar.imageSurfaceColor(context) : cs.surfaceContainerHighest);
    final Border? border = !widget.showSurface
        ? null
        : Border.all(
            color: hasImage && isDark
                ? Colors.white.withValues(alpha: 0.16)
                : cs.outlineVariant.withValues(alpha: 0.55),
            width: 1.0,
          );

    final Widget core = hasImage
        ? ClipOval(
            child: Padding(
              padding: EdgeInsets.all(widget.size * 0.14),
              child: Image.memory(
                _bytes!,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder: (ctx, _, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_decodeFailed) {
                      setState(() => _decodeFailed = true);
                    }
                  });
                  return _buildFallbackContent(ctx);
                },
              ),
            ),
          )
        : _buildFallbackContent(context);

    final Widget medallion = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fillColor,
        border: border,
      ),
      child: core,
    );

    if (!hasImage || !widget.showEmojiBadge || emoji == null || widget.size < 40) {
      return medallion;
    }

    final badgeSize = (widget.size * 0.38).clamp(15.0, 20.0);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          medallion,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: badgeSize,
              height: badgeSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.surface,
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.65),
                  width: 1.0,
                ),
              ),
              child: Text(
                emoji,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: badgeSize * 0.6, height: 1.0),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

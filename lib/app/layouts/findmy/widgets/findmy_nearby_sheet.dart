import 'dart:async';

import 'package:bluebubbles/app/components/blur_fade_switcher.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_avatar.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/findmy/findmy_ble_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

Future<void> showFindMyNearbySheet(
  BuildContext context,
  FindMyDevice device,
  FindMyController controller, {
  FindMyBleService? bleService,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => FindMyNearbySheet(
      device: device,
      controller: controller,
      bleService: bleService,
    ),
  );
}

class FindMyNearbySheet extends StatefulWidget {
  const FindMyNearbySheet({
    super.key,
    required this.device,
    required this.controller,
    this.bleService,
  });

  final FindMyDevice device;
  final FindMyController controller;
  final FindMyBleService? bleService;

  @override
  State<FindMyNearbySheet> createState() => _FindMyNearbySheetState();
}

class _FindMyNearbySheetState extends State<FindMyNearbySheet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final FindMyBleService _ble = widget.bleService ?? widget.controller.bleService;
  late final AnimationController _pulseController;

  StreamSubscription<FindMyBleScanEvent>? _scanSub;
  FindMyBleSpec? _spec;
  FindMyBleScanEvent? _latestEvent;
  bool _loading = true;
  bool _canLaunchUwb = false;
  bool _pausedByLifecycle = false;
  String? _errorText;
  String? _selectedComponent;
  DateTime _lastHapticAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    final components = widget.device.ringComponents;
    if (components.isNotEmpty) {
      _selectedComponent = components.first;
    }
    _startFlow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulseAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedByLifecycle = true;
      if (_scanSub != null) {
        unawaited(_scanSub!.cancel());
        _scanSub = null;
        _syncPulseAnimation();
      }
    } else if (state == AppLifecycleState.resumed) {
      final shouldResume =
          _pausedByLifecycle && _spec != null && _errorText == null && !_loading && _scanSub == null;
      _pausedByLifecycle = false;
      if (shouldResume) {
        _subscribeScan(_spec!);
      }
    }
  }

  void _syncPulseAnimation() {
    if (!mounted) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final activelyScanning = !_loading && _errorText == null && _scanSub != null;
    if (activelyScanning && !reduceMotion) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat();
      }
    } else if (_pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _scanSub = null;
    _pulseController.dispose();
    super.dispose();
  }

  void _subscribeScan(FindMyBleSpec spec) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_pausedByLifecycle ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      _pausedByLifecycle = true;
      _syncPulseAnimation();
      return;
    }
    _scanSub?.cancel();
    _scanSub = _ble.scanStream(spec).listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _latestEvent = event;
          if (event.timedOut) {
            _errorText = "Scan timed out after 2 minutes.";
          }
        });
        if (event.timedOut) {
          unawaited(_scanSub?.cancel());
          _scanSub = null;
          _syncPulseAnimation();
        }
        _triggerHapticForZone(event);
      },
      onError: (Object err) {
        if (!mounted) return;
        unawaited(_scanSub?.cancel());
        _scanSub = null;
        setState(() {
          _errorText = "BLE scan error: $err";
        });
        _syncPulseAnimation();
      },
    );
    _syncPulseAnimation();
  }

  Future<void> _startFlow() async {
    _pausedByLifecycle = false;
    if (_scanSub != null) {
      await _scanSub!.cancel();
      _scanSub = null;
    }
    if (!mounted) return;
    if (!_loading || _errorText != null || _latestEvent != null) {
      setState(() {
        _loading = true;
        _errorText = null;
        _latestEvent = null;
      });
      _syncPulseAnimation();
    }

    if (!_ble.isSupported) {
      setState(() {
        _loading = false;
        _errorText = "Nearby BLE finding is only supported on Android.";
      });
      _syncPulseAnimation();
      return;
    }

    var granted = await _ble.checkPermissions();
    if (!granted) {
      granted = await _ble.requestPermissions();
    }
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _loading = false;
        _errorText = "Bluetooth scan permission is required to find nearby trackers.";
      });
      _syncPulseAnimation();
      return;
    }

    final btEnabled = await _ble.isBluetoothEnabled();
    if (!mounted) return;
    if (!btEnabled) {
      setState(() {
        _loading = false;
        _errorText = "Turn on Bluetooth to scan for this tracker.";
      });
      _syncPulseAnimation();
      return;
    }

    final deviceId = widget.device.id;
    if (deviceId == null || deviceId.isEmpty) {
      setState(() {
        _loading = false;
        _errorText = "Missing device ID.";
      });
      _syncPulseAnimation();
      return;
    }

    FindMyBleSpec? spec;
    try {
      spec = await _ble.getBleSpec(deviceId);
    } catch (_) {}
    if (!mounted) return;
    if (spec == null) {
      setState(() {
        _loading = false;
        _errorText = "Could not fetch BLE scan spec from server.";
      });
      _syncPulseAnimation();
      return;
    }

    final uwbReady = spec.supportsUwb ? await _ble.canLaunchUwbApp(spec) : false;
    if (!mounted) return;

    setState(() {
      _spec = spec;
      _canLaunchUwb = uwbReady;
      _loading = false;
    });

    _subscribeScan(spec);
  }

  void _triggerHapticForZone(FindMyBleScanEvent event) {
    if (!event.matched || event.zone == null) return;
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastHapticAt).inMilliseconds;
    switch (event.zone) {
      case 'here':
        if (elapsedMs >= 500) {
          _lastHapticAt = now;
          HapticFeedback.heavyImpact();
        }
        break;
      case 'near':
        if (elapsedMs >= 900) {
          _lastHapticAt = now;
          HapticFeedback.mediumImpact();
        }
        break;
      case 'not_far':
        if (elapsedMs >= 1400) {
          _lastHapticAt = now;
          HapticFeedback.selectionClick();
        }
        break;
    }
  }

  Color _zoneColor(BuildContext context, String? zone) {
    final cs = context.theme.colorScheme;
    return switch (zone) {
      'here' => Colors.green,
      'near' => cs.primary,
      'not_far' => Colors.amber.shade700,
      _ => cs.outline,
    };
  }

  String _zoneLabel(String? zone) {
    return switch (zone) {
      'here' => 'Here',
      'near' => 'Near',
      'not_far' => 'Not far',
      'far' => 'Far',
      _ => 'Searching',
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final event = _latestEvent;
    final matched = event?.matched == true;
    final zoneColor = matched ? _zoneColor(context, event?.zone) : cs.outline;
    final components = widget.device.ringComponents.isNotEmpty
        ? widget.device.ringComponents
        : (_spec?.ringComponents ?? const <String>[]);
    final providerLabel = widget.device.trackerProvider == 'utag' ? 'Samsung uTag' : 'Google Find';

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + MediaQuery.viewPaddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FindMyDeviceAvatar(
                device: widget.device,
                size: 40,
                redacted: shouldRedactFindMyContactInfo(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.device.name ?? 'Find Nearby',
                      style: context.theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      providerLabel,
                      style: context.theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_errorText != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  Icon(Icons.bluetooth_disabled, size: 42, color: cs.error),
                  const SizedBox(height: 10),
                  Text(
                    _errorText!,
                    textAlign: TextAlign.center,
                    style: context.theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _startFlow,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            )
          else ...[
            Center(
              child: SizedBox(
                width: 210,
                height: 210,
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final t = reduceMotion ? 0.5 : _pulseController.value;
                    return CustomPaint(
                      painter: _RadarPainter(
                        progress: t,
                        color: zoneColor,
                        matched: matched,
                      ),
                      child: child,
                    );
                  },
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          matched && event?.meters != null
                              ? '~${event!.meters!.toStringAsFixed(1)} m'
                              : 'Searching...',
                          style: context.theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: zoneColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _TrendPill(
                          zoneLabel: _zoneLabel(event?.zone),
                          trend: event?.trend,
                          color: zoneColor,
                          matched: matched,
                        ),
                        if (matched && event?.rssi != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${event!.rssi!.round()} dBm',
                            style: context.theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_spec?.provider == 'utag' &&
                !matched &&
                (event?.nearbyBeacons.isNotEmpty ?? false)) ...[
              const SizedBox(height: 12),
              Text(
                'Nearby SmartTags — tap Lock to pair signal',
                style: context.theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              ...event!.nearbyBeacons.take(3).map((beacon) {
                final shortId = beacon.privacyIdHex.length > 8
                    ? beacon.privacyIdHex.substring(0, 8)
                    : beacon.privacyIdHex;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.sensors, color: cs.primary),
                  title: Text('SmartTag ($shortId…)'),
                  subtitle: Text('${beacon.rssi} dBm${beacon.uwbCapable ? ' • UWB' : ''}'),
                  trailing: FilledButton.tonal(
                    onPressed: () async {
                      final devId = widget.device.id;
                      if (devId != null) {
                        await _ble.lockSamsungBeacon(devId, beacon.privacyIdHex);
                      }
                    },
                    child: const Text('Lock'),
                  ),
                );
              }),
            ],
            if (components.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: components.map((comp) {
                  final selected = _selectedComponent == comp;
                  return ChoiceChip(
                    label: Text(comp.toUpperCase()),
                    selected: selected,
                    onSelected: (_) => setState(() => _selectedComponent = comp),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.device.canRing || (_spec?.ringKeyHex?.isNotEmpty ?? false))
                  Expanded(
                    child: Obx(() {
                      final isRinging = widget.controller.ringingDeviceId.value == widget.device.id;
                      final busy = widget.controller.ringBusy.value;
                      return FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () => widget.controller.toggleRingDevice(
                                  widget.device,
                                  component: _selectedComponent,
                                ),
                        icon: BlurFadeSwitcher(
                          child: busy
                              ? const SizedBox(
                                  key: ValueKey('busy'),
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  isRinging ? Icons.stop_rounded : Icons.volume_up_rounded,
                                  key: ValueKey(isRinging),
                                ),
                        ),
                        label: BlurFadeSwitcher(
                          animateSize: true,
                          child: Text(
                            isRinging ? 'Stop Sound' : 'Play Sound',
                            key: ValueKey(isRinging),
                          ),
                        ),
                      );
                    }),
                  ),
                if (_canLaunchUwb && _spec != null) ...[
                  if (widget.device.canRing || (_spec?.ringKeyHex?.isNotEmpty ?? false))
                    const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => _ble.launchUwbApp(_spec!),
                      icon: const Icon(Icons.explore_outlined),
                      label: const Text('Open UWB Arrow'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TrendPill extends StatelessWidget {
  const _TrendPill({
    required this.zoneLabel,
    required this.trend,
    required this.color,
    required this.matched,
  });

  final String zoneLabel;
  final String? trend;
  final Color color;
  final bool matched;

  @override
  Widget build(BuildContext context) {
    IconData icon = Icons.remove;
    String trendText = '';
    if (matched) {
      switch (trend) {
        case 'stronger':
          icon = Icons.arrow_upward_rounded;
          trendText = ' • Stronger';
          break;
        case 'weaker':
          icon = Icons.arrow_downward_rounded;
          trendText = ' • Weaker';
          break;
        default:
          icon = Icons.horizontal_rule_rounded;
          trendText = ' • Steady';
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (matched) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              '$zoneLabel$trendText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.progress,
    required this.color,
    required this.matched,
  });

  final double progress;
  final Color color;
  final bool matched;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1.0;
      final radius = maxR * (0.28 + 0.72 * phase);
      final alpha = (1.0 - phase) * (matched ? 0.55 : 0.25);
      ringPaint.color = color.withValues(alpha: alpha);
      canvas.drawCircle(center, radius, ringPaint);
    }

    final basePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: matched ? 0.12 : 0.06);
    canvas.drawCircle(center, maxR * 0.45, basePaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.matched != matched;
}

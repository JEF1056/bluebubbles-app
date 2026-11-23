import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:maps_launcher/maps_launcher.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

class LocationCard extends StatefulWidget {
  const LocationCard({
    super.key,
    required this.file,
    required this.attachment,
    this.messageDate,
  });

  final PlatformFile file;
  final Attachment attachment;
  final DateTime? messageDate;

  @override
  State<LocationCard> createState() => _LocationCardState();
}

class _LocationCardState extends State<LocationCard> with AutomaticKeepAliveClientMixin {
  AppleLocation? _location;
  String? _title;
  String? _mapsUrl;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _parseLocation();
  }

  Future<void> _parseLocation() async {
    String? raw;
    try {
      if (kIsWeb || widget.file.path == null) {
        if (widget.file.bytes != null) {
          raw = utf8.decode(widget.file.bytes!);
        }
      } else {
        raw = await File(widget.file.path!).readAsString();
      }
    } catch (_) {}
    if (raw == null || raw.isEmpty) return;

    final parsedUrl = AttachmentsSvc.parseAppleLocationUrl(raw)
        ?.replaceAll('\\', '')
        .replaceAll('http:', 'https:');
    String? fnTitle;
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('FN:')) {
        final val = trimmed.substring(3).trim();
        if (val.isNotEmpty && val != 'Current Location') {
          fnTitle = val;
        }
        break;
      }
    }

    AppleLocation? coords;
    if (parsedUrl != null) {
      final match = RegExp(r'(?:ll|q|sll)=(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)').firstMatch(parsedUrl);
      if (match != null) {
        final lat = double.tryParse(match.group(1)!);
        final lng = double.tryParse(match.group(2)!);
        if (lat != null && lng != null) {
          coords = AppleLocation(latitude: lat, longitude: lng);
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _mapsUrl = parsedUrl;
      _title = fnTitle;
      _location = coords;
    });
  }

  Future<void> _openInMaps() async {
    final lat = _location?.latitude;
    final lng = _location?.longitude;
    if (lat != null && lng != null) {
      if (kIsWeb) {
        final uri = Uri.parse('https://maps.google.com/?q=$lat,$lng');
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await MapsLauncher.launchCoordinates(lat, lng, _title);
      }
      return;
    }
    if (_mapsUrl != null) {
      await launchUrl(Uri.parse(_mapsUrl!), mode: LaunchMode.externalApplication);
    } else {
      showSnackbar('Error', 'Unable to open location coordinates', type: SnackbarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = context.theme.colorScheme;
    final lat = _location?.latitude;
    final lng = _location?.longitude;
    final subtitle = (lat != null && lng != null)
        ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
        : (widget.messageDate != null
            ? 'Shared ${DateFormat.yMd().format(widget.messageDate!)}'
            : 'Tap to open in Maps');

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280, minHeight: 48),
      child: Semantics(
        button: true,
        label: 'Open ${_title ?? "Location"} in Maps',
        child: Tooltip(
          message: 'Open in Maps',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _openInMaps,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.location_on_rounded,
                        color: scheme.onPrimaryContainer,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _title ?? 'Location',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 18,
                      color: scheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

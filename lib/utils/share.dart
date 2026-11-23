import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/composer_popover.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:bluebubbles/models/models.dart' show LocationAttachmentData;
import 'package:universal_io/io.dart';

class Share {
  /// Share a file with other apps.
  static void files(List<String> filepaths, {String? mimeType}) async {
    if (kIsDesktop && Platform.isLinux) {
      showSnackbar("Unsupported", "Can't share files on Linux yet!", type: SnackbarType.error);
    } else {
      // Windows' StorageFile rejects '/' separators and its share sheet requires a title, else the package is empty.
      await SharePlus.instance.share(ShareParams(
        files: filepaths
            .map((String path) => XFile(Platform.isWindows ? p.normalize(path) : path, mimeType: mimeType))
            .toList(),
        title: Platform.isWindows ? filepaths.map(p.basename).join(", ") : null,
      ));
    }
  }

  /// Share text with other apps.
  static void text(String text) async {
    await SharePlus.instance.share(ShareParams(text: text));
  }

  static Future<void> location(Chat chat) async {
    final canOpenSettings = !kIsWeb && (!kIsDesktop || !Platform.isLinux);
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      showSnackbar(
        "Location is off",
        "Location Services must be enabled to send Locations",
        type: SnackbarType.error,
        actionLabel: canOpenSettings ? "Open settings" : null,
        onAction: canOpenSettings ? () => unawaited(Geolocator.openLocationSettings()) : null,
      );
      return;
    }

    if (!kIsDesktop || !Platform.isLinux) {
      var permissionGranted = await Geolocator.checkPermission();
      if (permissionGranted == LocationPermission.denied) {
        permissionGranted = await Geolocator.requestPermission();
      }
      if (permissionGranted == LocationPermission.denied || permissionGranted == LocationPermission.deniedForever) {
        showSnackbar(
          "Location permission needed",
          "BlueBubbles needs the Location permission to send Locations",
          type: SnackbarType.error,
          actionLabel: canOpenSettings ? "Open settings" : null,
          onAction: canOpenSettings ? () => unawaited(Geolocator.openAppSettings()) : null,
        );
        return;
      }
    }

    Future<LocationAttachmentData> getLocationPreview() async {
      final locationData = await Geolocator.getCurrentPosition();
      final vcfString = AttachmentsSvc.createAppleLocation(locationData.latitude, locationData.longitude);

      // Build out the file we are going to send
      final attachmentGuid = "temp-${randomString(8)}";
      final fileName = "$attachmentGuid-CL.loc.vcf";
      final bytes = Uint8List.fromList(utf8.encode(vcfString));

      // Apple Maps does not always serve a preview image; the location is
      // still perfectly sendable without one, so this is not treated as a
      // failure the way the old force-unwrap did (which left the dialog stuck
      // on "Loading Location..." forever).
      final meta = await MetadataHelper.getLocationMetadata(locationData);

      return LocationAttachmentData(
        guid: attachmentGuid,
        fileName: fileName,
        bytes: bytes,
        mapImageUrl: meta?.imageUrl,
        title: meta?.title,
      );
    }

    final hostContext = Get.context;
    if (hostContext == null || !hostContext.mounted) return;
    final controller =
        Get.isRegistered<ConversationViewController>(tag: chat.guid) ? Get.find<ConversationViewController>(tag: chat.guid) : null;
    final isWide = MediaQuery.sizeOf(hostContext).width >= 600;

    LocationAttachmentData? confirmedPreview;
    if (!isWide) {
      confirmedPreview = await showModalBottomSheet<LocationAttachmentData>(
        context: hostContext,
        isScrollControlled: true,
        useRootNavigator: true,
        showDragHandle: true,
        backgroundColor: hostContext.theme.colorScheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (sheetCtx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: _LocationShareSheet(loadPreview: getLocationPreview),
          ),
        ),
      );
    } else if (controller != null) {
      final anchor = controller.textFieldKey.currentContext ?? hostContext;
      await showComposerPopover(
        anchor,
        controller,
        width: 360,
        height: 360,
        builder: (_) => ComposerPopoverCard(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: _LocationShareSheet(
                loadPreview: getLocationPreview,
                onResult: (preview) => confirmedPreview = preview,
              ),
            ),
          ),
        ),
      );
    } else {
      confirmedPreview = await showModalBottomSheet<LocationAttachmentData>(
        context: hostContext,
        isScrollControlled: true,
        useRootNavigator: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 420),
        backgroundColor: hostContext.theme.colorScheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (sheetCtx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: _LocationShareSheet(loadPreview: getLocationPreview),
          ),
        ),
      );
    }

    if (confirmedPreview == null) return;
    final preview = confirmedPreview!;

    final message = Message(
      guid: preview.guid,
      text: "",
      dateCreated: DateTime.now(),
      hasAttachments: true,
      isFromMe: true,
      handleId: 0,
    );

    final attachment = Attachment(
      guid: preview.guid,
      mimeType: "text/x-vlocation",
      isOutgoing: true,
      uti: "public.vlocation",
      bytes: preview.bytes,
      transferName: preview.fileName,
      totalBytes: preview.bytes.length,
    );

    OutgoingMsgHandler.queue(
      OutgoingAttachment(
        chat: chat,
        message: message,
        attachment: attachment,
      ),
    );
  }
}

class _LocationShareSheet extends StatefulWidget {
  const _LocationShareSheet({required this.loadPreview, this.onResult});

  final Future<LocationAttachmentData> Function() loadPreview;
  final ValueChanged<LocationAttachmentData?>? onResult;

  @override
  State<_LocationShareSheet> createState() => _LocationShareSheetState();
}

class _LocationShareSheetState extends State<_LocationShareSheet> {
  LocationAttachmentData? _preview;
  bool _loading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _hasError = false;
    });
    try {
      final result = await widget.loadPreview();
      if (!mounted) return;
      setState(() {
        _preview = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hasError = true;
      });
    }
  }

  void _close([LocationAttachmentData? result]) {
    if (widget.onResult != null) {
      widget.onResult!(result);
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    final textTheme = context.theme.textTheme;
    const minSize = Size(64, 48);
    const shape = StadiumBorder();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      child: _loading
          ? Column(
              key: const ValueKey('loading'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.location_on_outlined, color: scheme.primary),
                    const SizedBox(width: 10),
                    Text("Share Location", style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 14),
                Text(
                  "Finding your location…",
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _close(),
                    style: TextButton.styleFrom(minimumSize: minSize, shape: shape),
                    child: const Text("Cancel"),
                  ),
                ),
              ],
            )
          : _hasError || _preview == null
              ? Column(
                  key: const ValueKey('error'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.location_off_outlined, color: scheme.error),
                        const SizedBox(width: 10),
                        Text("Couldn't Get Location", style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Check that location permissions are granted and try again.",
                      style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => _close(),
                          style: TextButton.styleFrom(minimumSize: minSize, shape: shape),
                          child: const Text("Dismiss"),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _fetch,
                          style: FilledButton.styleFrom(minimumSize: minSize, shape: shape),
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                  ],
                )
              : Column(
                  key: const ValueKey('ready'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.location_on_outlined, color: scheme.primary),
                        const SizedBox(width: 10),
                        Text("Send Location?", style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (_preview!.mapImageUrl != null) ...[
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: AspectRatio(
                          aspectRatio: 16 / 10,
                          child: Image.network(
                            _preview!.mapImageUrl!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.map_outlined, size: 28, color: scheme.onSurfaceVariant),
                                  const SizedBox(height: 6),
                                  Text(
                                    "Map preview unavailable",
                                    style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            frameBuilder: (_, child, frame, _) {
                              if (frame == null) {
                                return Center(child: buildProgressIndicator(context));
                              }
                              return child;
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      _preview!.title ?? "Current location",
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => _close(),
                          style: TextButton.styleFrom(minimumSize: minSize, shape: shape),
                          child: const Text("Cancel"),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => _close(_preview),
                          style: FilledButton.styleFrom(minimumSize: minSize, shape: shape),
                          child: const Text("Send Location"),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }
}

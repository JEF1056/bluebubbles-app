import 'dart:convert';
import 'dart:math' as math;

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/platform/shims/native_misc.dart' show OpenFilex;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

class ContactCard extends StatefulWidget {
  const ContactCard({
    super.key,
    required this.file,
    required this.attachment,
  });

  final PlatformFile file;
  final Attachment attachment;

  @override
  State<ContactCard> createState() => _ContactCardState();
}

class _ContactCardState extends State<ContactCard> with AutomaticKeepAliveClientMixin, ThemeHelpers {
  ContactV2? contact;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    String? appleContact;
    try {
      if (kIsWeb || widget.file.path == null) {
        if (widget.file.bytes != null) {
          appleContact = utf8.decode(widget.file.bytes!);
        }
      } else {
        appleContact = await File(widget.file.path!).readAsString();
      }
    } catch (_) {}
    if (appleContact == null) return;

    final lines = appleContact.split('\n');
    final indices = <int>[];
    final avatarLines = <String>[];
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith(' ')) {
        indices.add(i);
      }
    }

    if (indices.isNotEmpty) {
      avatarLines.add(lines[indices.first - 1].trim());
    }
    for (final i in indices) {
      avatarLines.add(lines[i].trim());
    }
    if (indices.isNotEmpty) {
      lines.removeRange(indices.first - 1, indices.last + 1);
    }

    final avatarStr = avatarLines.join();

    try {
      contact = AttachmentsSvc.parseAppleContact(appleContact);
    } catch (_) {
      contact = ContactV2(displayName: 'Invalid Contact', nativeContactId: randomString(8));
    }

    if (!kIsWeb && contact != null && avatarStr.isNotEmpty) {
      try {
        final b64 = '/${avatarStr.split('/').sublist(1).join('/').trim()}';
        final bytes = base64Decode(b64);
        final tempPath = '${Directory.systemTemp.path}/contact_card_${contact!.nativeContactId}.jpg';
        await File(tempPath).writeAsBytes(bytes);
        contact!.avatarPath = tempPath;
      } catch (_) {}
    }

    if (mounted) setState(() {});
  }

  List<String> _detailLines() {
    final c = contact;
    if (c == null) return const ['Contact card'];
    final parts = <String>[];
    if (c.phoneNumbers.isNotEmpty) {
      parts.add(c.phoneNumbers.first.number);
    }
    if (c.emailAddresses.isNotEmpty) {
      parts.add(c.emailAddresses.first.address);
    }
    return parts.isEmpty ? const ['Contact card'] : parts;
  }

  Future<void> _performPrimaryAction() async {
    if (kIsWeb || widget.file.path == null) {
      final bytes = widget.file.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        downloadBytes(bytes, widget.file.name);
      } else {
        showSnackbar('Error', 'Contact card has no downloadable data', type: SnackbarType.error);
      }
      return;
    }

    final resolvedPath = p.join(
      FilesystemSvc.attachmentsPath,
      FilesystemService.sanitizeGuid(widget.attachment.guid),
      p.basename(widget.file.path!),
    );
    if (kIsDesktop) {
      await launchUrl(Uri.file(resolvedPath));
    } else {
      await OpenFilex.open(resolvedPath, type: widget.attachment.mimeType);
    }
  }

  Future<void> _openDetails(BuildContext anchorContext) async {
    final c = contact ?? ContactV2(displayName: 'Unknown', nativeContactId: 'unknown');
    final isWebOrBytesOnly = kIsWeb || widget.file.path == null;
    final usePopover = kIsWeb || MediaQuery.sizeOf(anchorContext).width >= 600;

    Widget buildBody(BuildContext ctx, {required bool showCloseButton}) {
      final maxHeight = math.min(480.0, MediaQuery.sizeOf(ctx).height * 0.72);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: _ContactDetailSheetContent(
            contact: c,
            isWebOrBytesOnly: isWebOrBytesOnly,
            showCloseButton: showCloseButton,
            onPrimaryAction: () {
              Navigator.of(ctx).pop();
              _performPrimaryAction();
            },
          ),
        ),
      );
    }

    if (!usePopover) {
      await showModalBottomSheet<void>(
        context: anchorContext,
        showDragHandle: true,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: buildBody(ctx, showCloseButton: false),
          ),
        ),
      );
      return;
    }

    final navigator = Navigator.of(anchorContext, rootNavigator: true);
    final overlayBox = navigator.overlay!.context.findRenderObject() as RenderBox;
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    final anchor = anchorBox == null || !anchorBox.attached
        ? Rect.fromLTWH(16, overlayBox.size.height / 2, 0, 0)
        : anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) & anchorBox.size;
    final themes = InheritedTheme.capture(from: anchorContext, to: navigator.context);

    await navigator.push(
      RawDialogRoute<void>(
        barrierDismissible: true,
        barrierLabel: 'Dismiss',
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (ctx, _, _) {
          const popoverWidth = 320.0;
          const margin = 12.0;
          final maxLeft = math.max(margin, overlayBox.size.width - popoverWidth - margin);
          final left = anchor.left.clamp(margin, maxLeft);
          final showBelow = anchor.bottom + 260 < overlayBox.size.height - margin;
          final top = showBelow
              ? anchor.bottom + 6
              : math.max(margin, anchor.top - 260);
          return Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: popoverWidth,
                child: themes.wrap(
                  Focus(
                    autofocus: true,
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(ctx).pop(),
                      },
                      child: Material(
                        elevation: 3,
                        color: anchorContext.theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: buildBody(ctx, showCloseButton: true),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = context.theme.colorScheme;
    final displayName = contact?.computedDisplayName ?? 'Unknown';

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 210, maxWidth: 280, minHeight: 56),
      child: Semantics(
        button: true,
        label: 'View contact $displayName',
        child: Tooltip(
          message: 'View contact',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _openDetails(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ContactAvatarWidget(
                      handle: Handle(),
                      contact: contact,
                      size: 40,
                      borderThickness: 0.5,
                      editable: false,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: context.theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          const SizedBox(height: 2),
                          for (final line in _detailLines())
                            Text(
                              line,
                              style: context.theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      iOS ? CupertinoIcons.forward : Icons.chevron_right,
                      color: scheme.outline,
                      size: 18,
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

  @override
  bool get wantKeepAlive => true;
}

class _ContactDetailSheetContent extends StatelessWidget {
  const _ContactDetailSheetContent({
    required this.contact,
    required this.isWebOrBytesOnly,
    required this.showCloseButton,
    required this.onPrimaryAction,
  });

  final ContactV2 contact;
  final bool isWebOrBytesOnly;
  final bool showCloseButton;
  final VoidCallback onPrimaryAction;

  void _copyField(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    showSnackbar('Copied', '$label copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ContactAvatarWidget(
              handle: Handle(),
              contact: contact,
              size: 48,
              borderThickness: 0.5,
              editable: false,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                contact.computedDisplayName,
                style: context.theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showCloseButton)
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
          ],
        ),
        if (contact.phoneNumbers.isNotEmpty || contact.emailAddresses.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 4),
          for (final phone in contact.phoneNumbers)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.phone_outlined, color: scheme.primary),
              title: Text(phone.number),
              subtitle: phone.label.isNotEmpty ? Text(phone.label) : null,
              onTap: () => _copyField('Phone number', phone.number),
            ),
          for (final email in contact.emailAddresses)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.email_outlined, color: scheme.primary),
              title: Text(email.address),
              subtitle: email.label.isNotEmpty ? Text(email.label) : null,
              onTap: () => _copyField('Email', email.address),
            ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onPrimaryAction,
          icon: Icon(isWebOrBytesOnly ? Icons.download_outlined : Icons.person_add_outlined),
          label: Text(isWebOrBytesOnly ? 'Download .vcf' : 'Add contact'),
        ),
      ],
    );
  }
}

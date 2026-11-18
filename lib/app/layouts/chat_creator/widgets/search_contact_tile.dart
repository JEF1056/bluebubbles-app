import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart' show SelectedContact;
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// A single contact row inside the search results list.
///
/// For each [ContactV2], this widget renders one row per unique phone number
/// and one row per unique email address (duplicates are filtered out by their
/// numeric-only representation, matching the existing [ChatListSection] logic).
class SearchContactTile extends StatelessWidget {
  const SearchContactTile({
    super.key,
    required this.contact,
    required this.controller,
  });

  final ContactV2 contact;
  final ChatCreatorController controller;

  static List<({String address, String? label})> addressesFor(
    ContactV2 contact, {
    required bool showEmails,
  }) {
    final seenNumbers = <String>{};
    final uniquePhones = contact.phoneNumbers.where((p) => seenNumbers.add(p.number.numericOnly())).toList();

    final seenAddresses = <String>{};
    final uniqueEmails = showEmails
        ? contact.emailAddresses.where((e) => seenAddresses.add(e.address.trim())).toList()
        : const <dynamic>[];

    return [
      for (final p in uniquePhones) (address: p.number, label: p.label),
      for (final e in uniqueEmails) (address: e.address as String, label: e.label as String?),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final hideInfo = SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideContactInfo.value;
      // Email addresses are only valid for iMessage
      final showEmails = controller.selectedService.value.isIMessageService;
      final entries = addressesFor(contact, showEmails: showEmails);
      if (entries.isEmpty) return const SizedBox.shrink();

      return Column(
        key: ValueKey(contact.nativeContactId),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in entries)
            ContactAddressRow(
              displayName: hideInfo ? 'Contact' : contact.computedDisplayName,
              address: hideInfo ? '' : entry.address,
              label: hideInfo ? null : entry.label,
              contact: contact,
              onTap: () {
                if (controller.selectedContacts.firstWhereOrNull((c) => c.address == entry.address) != null) {
                  return;
                }
                controller.addSelected(
                  SelectedContact(
                    displayName: contact.computedDisplayName,
                    address: entry.address,
                  ),
                );
              },
            ),
        ],
      );
    });
  }
}

class ContactAddressRow extends StatelessWidget {
  const ContactAddressRow({
    super.key,
    required this.displayName,
    required this.address,
    required this.contact,
    required this.onTap,
    this.label,
    this.shape,
    this.tileColor,
  });

  final String displayName;
  final String address;
  final String? label;
  final ContactV2 contact;
  final VoidCallback onTap;
  final ShapeBorder? shape;
  final Color? tileColor;

  @override
  Widget build(BuildContext context) {
    final subtitle = (label != null && label!.isNotEmpty) ? '$address  •  $label' : address;

    return Material(
      color: tileColor ?? Colors.transparent,
      shape: shape,
      clipBehavior: shape != null ? Clip.antiAlias : Clip.none,
      child: InkWell(
        onTap: onTap,
        child: ListTile(
          dense: SettingsSvc.settings.denseChatTiles.value,
          minVerticalPadding: 10,
          leading: ContactAvatarWidget(
            handle: null,
            contact: contact,
            size: 40,
            borderThickness: 0.1,
          ),
          title: Text(
            displayName,
            style: context.theme.textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            style: context.theme.textTheme.bodySmall?.copyWith(
              color: context.theme.colorScheme.onSurfaceVariant,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

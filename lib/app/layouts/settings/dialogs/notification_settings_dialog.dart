import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

bool _shouldMuteDateTime(String? muteArgs) {
  if (muteArgs == null) return false;
  final DateTime? time = DateTime.tryParse(muteArgs);
  if (time == null) return false;
  return DateTime.now().toLocal().difference(time).inSeconds.isNegative;
}

Future<void> showNotificationSettingsDialog(
  BuildContext context,
  Chat chat,
  VoidCallback updateParent,
) async {
  final bool iOS = SettingsSvc.settings.skin.value == Skins.iOS;
  final bool hasTempMute = chat.muteType == "temporary_mute" && _shouldMuteDateTime(chat.muteArgs);

  await showBBBottomSheet<void>(
    context: context,
    title: "Chat-Specific Settings",
    subtitle: chat.getTitle(),
    icon: iOS ? CupertinoIcons.bell : Icons.notifications_outlined,
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
    builder: (sheetCtx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ListTile(
          mouseCursor: MouseCursor.defer,
          leading: Icon(
            chat.muteType == "mute"
                ? (iOS ? CupertinoIcons.bell : Icons.volume_up_outlined)
                : (iOS ? CupertinoIcons.bell_slash : Icons.volume_off_outlined),
          ),
          title: Text(chat.muteType == "mute" ? "Unmute" : "Mute", style: sheetCtx.theme.textTheme.bodyLarge),
          subtitle: Text(
            "Completely ${chat.muteType == "mute" ? "unmute" : "mute"} this chat",
            style: sheetCtx.theme.textTheme.bodySmall!.copyWith(color: sheetCtx.theme.colorScheme.onSurfaceVariant),
          ),
          onTap: () async {
            Navigator.of(sheetCtx, rootNavigator: true).pop();
            await ChatsSvc.setChatMuted(chat, chat.muteType != "mute");
            updateParent.call();
            EventDispatcherSvc.emit("refresh", null);
          },
        ),
        if (chat.isGroup)
          ListTile(
            mouseCursor: MouseCursor.defer,
            leading: Icon(iOS ? CupertinoIcons.person_2 : Icons.group_off_outlined),
            title: Text("Mute Individuals", style: sheetCtx.theme.textTheme.bodyLarge),
            subtitle: Text(
              "Mute certain individuals in this chat",
              style: sheetCtx.theme.textTheme.bodySmall!.copyWith(color: sheetCtx.theme.colorScheme.onSurfaceVariant),
            ),
            onTap: () async {
              Navigator.of(sheetCtx, rootNavigator: true).pop();
              if (!context.mounted) return;
              await _showMuteIndividualsDialog(context, chat, updateParent);
            },
          ),
        ListTile(
          mouseCursor: MouseCursor.defer,
          leading: Icon(
            hasTempMute
                ? (iOS ? CupertinoIcons.timer : Icons.timer_off_outlined)
                : (iOS ? CupertinoIcons.clock : Icons.snooze_outlined),
          ),
          title: Text(
            hasTempMute ? "Delete Temporary Mute" : "Temporary Mute",
            style: sheetCtx.theme.textTheme.bodyLarge,
          ),
          subtitle: Text(
            hasTempMute ? "Remove scheduled mute expiration" : "Mute this chat temporarily",
            style: sheetCtx.theme.textTheme.bodySmall!.copyWith(color: sheetCtx.theme.colorScheme.onSurfaceVariant),
          ),
          onTap: () async {
            Navigator.of(sheetCtx, rootNavigator: true).pop();
            if (!context.mounted) return;
            if (_shouldMuteDateTime(chat.muteArgs)) {
              chat.muteType = null;
              chat.muteArgs = null;
              chat.saveAsync(updateMuteType: true, updateMuteArgs: true);
              updateParent.call();
              EventDispatcherSvc.emit("refresh", null);
            } else {
              final finalDate = await showBBDateTimePicker(
                context: context,
                initialDate: DateTime.now().toLocal(),
                firstDate: DateTime.now().toLocal(),
                lastDate: DateTime.now().toLocal().add(const Duration(days: 365)),
              );
              if (finalDate != null) {
                await ChatsSvc.setChatMuted(chat, false);
                chat.muteType = "temporary_mute";
                chat.muteArgs = finalDate.toIso8601String();
                chat.saveAsync(updateMuteType: true, updateMuteArgs: true);
                updateParent.call();
                EventDispatcherSvc.emit("refresh", null);
              }
            }
          },
        ),
        ListTile(
          mouseCursor: MouseCursor.defer,
          leading: Icon(iOS ? CupertinoIcons.textformat : Icons.text_fields_outlined),
          title: Text("Text Detection", style: sheetCtx.theme.textTheme.bodyLarge),
          subtitle: Text(
            "Completely mute this chat, except when a message contains certain text",
            style: sheetCtx.theme.textTheme.bodySmall!.copyWith(color: sheetCtx.theme.colorScheme.onSurfaceVariant),
          ),
          onTap: () async {
            Navigator.of(sheetCtx, rootNavigator: true).pop();
            if (!context.mounted) return;
            final result = await showTextDetectionDialog(
              context,
              initialText: chat.muteType == "text_detection" ? chat.muteArgs : null,
            );
            if (result == null) return;
            await ChatsSvc.setChatMuted(chat, false);
            chat.muteType = "text_detection";
            chat.muteArgs = result;
            chat.saveAsync(updateMuteType: true, updateMuteArgs: true);
            updateParent.call();
            EventDispatcherSvc.emit("refresh", null);
          },
        ),
        ListTile(
          mouseCursor: MouseCursor.defer,
          leading: Icon(
            iOS ? CupertinoIcons.arrow_counterclockwise : Icons.restart_alt,
            color: sheetCtx.theme.colorScheme.error,
          ),
          title: Text(
            "Reset Chat Settings",
            style: sheetCtx.theme.textTheme.bodyLarge!.copyWith(color: sheetCtx.theme.colorScheme.error),
          ),
          subtitle: Text(
            "Delete your custom settings",
            style: sheetCtx.theme.textTheme.bodySmall!.copyWith(color: sheetCtx.theme.colorScheme.onSurfaceVariant),
          ),
          onTap: () async {
            Navigator.of(sheetCtx, rootNavigator: true).pop();
            await ChatsSvc.setChatMuted(chat, false);
            chat.muteType = null;
            chat.muteArgs = null;
            chat.saveAsync(updateMuteType: true, updateMuteArgs: true);
            updateParent.call();
            EventDispatcherSvc.emit("refresh", null);
          },
        ),
      ],
    ),
  );
}

Future<void> _showMuteIndividualsDialog(
  BuildContext context,
  Chat chat,
  VoidCallback updateParent,
) async {
  final people = chat.people;
  final names = people.map((e) => e.displayName).toList();
  final List<String> existing = (chat.muteArgs?.split(",") ?? []).where((e) => e.isNotEmpty).toList();
  final iOS = SettingsSvc.settings.skin.value == Skins.iOS;

  await showBBDialog<void>(
    context: context,
    title: "Mute Individuals",
    icon: iOS ? CupertinoIcons.bell_slash : Icons.notifications_off_outlined,
    content: StatefulBuilder(builder: (ctx, setState) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              "Select the individuals you would like to mute",
              style: ctx.theme.textTheme.bodySmall?.copyWith(color: ctx.theme.colorScheme.onSurfaceVariant),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: ctx.mediaQuery.size.height * 0.4,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int index = 0; index < people.length; index++)
                    CheckboxListTile(
                      key: ValueKey(people[index].address),
                      value: existing.contains(people[index].address),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            existing.add(people[index].address);
                          } else {
                            existing.removeWhere((element) => element == people[index].address);
                          }
                        });
                      },
                      activeColor: ctx.theme.colorScheme.primary,
                      title: Text(names[index], style: ctx.theme.textTheme.bodyLarge),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }),
    actions: [
      BBDialogAction(
        text: "Cancel",
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
      BBDialogAction(
        text: "Mute Selected",
        isDefault: true,
        onPressed: () {
          if (existing.isEmpty) {
            showSnackbar("Error", "Please select at least one person!", type: SnackbarType.error);
            return;
          }
          ChatsSvc.setChatMuted(chat, false);
          chat.muteType = "mute_individuals";
          chat.muteArgs = existing.join(",");
          Navigator.of(context, rootNavigator: true).pop();
          chat.saveAsync(updateMuteType: true, updateMuteArgs: true);
          updateParent.call();
          EventDispatcherSvc.emit("refresh", null);
        },
      ),
    ],
  );
}

Future<String?> showTextDetectionDialog(BuildContext context, {String? initialText}) {
  final iOS = SettingsSvc.settings.skin.value == Skins.iOS;
  return showBBInputDialog(
    context: context,
    title: "Text Detection",
    icon: iOS ? CupertinoIcons.textformat : Icons.text_fields_outlined,
    body: "Enter any text separated by commas to whitelist notifications for. These are case insensitive.\n\nE.g. 'John,hey guys,homework'",
    initialValue: initialText,
    labelText: "Whitelisted phrases",
    hintText: "John,hey guys,homework",
    confirmText: "Save Phrases",
  );
}

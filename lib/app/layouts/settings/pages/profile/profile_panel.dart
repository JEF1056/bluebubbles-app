import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/avatar/avatar_crop.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:universal_io/io.dart';

class ProfilePanel extends StatefulWidget {
  const ProfilePanel({super.key});

  @override
  State<ProfilePanel> createState() => _ProfilePanelState();
}

class _ProfilePanelState extends State<ProfilePanel> with WidgetsBindingObserver, ThemeHelpers {
  final RxDouble opacity = 1.0.obs;
  final RxMap<String, dynamic> accountInfo = RxMap({});
  final RxMap<String, dynamic> accountContact = RxMap({});

  @override
  void initState() {
    super.initState();
    if (SettingsSvc.iCloudAccountInfo.isNotEmpty) {
      accountInfo.addAll(SettingsSvc.iCloudAccountInfo);
    }
    if (SettingsSvc.iCloudContactInfo.isNotEmpty) {
      accountContact.addAll(SettingsSvc.iCloudContactInfo);
    }
    getDetails();
  }

  void getDetails() async {
    try {
      await SettingsSvc.refreshIcloudProfile(force: true);
      if (SettingsSvc.iCloudAccountInfo.isNotEmpty) {
        accountInfo.assignAll(SettingsSvc.iCloudAccountInfo);
      }
      opacity.value = 1.0;
      if (SettingsSvc.iCloudContactInfo.isNotEmpty) {
        accountContact.assignAll(SettingsSvc.iCloudContactInfo);
      }
    } catch (e, s) {
      Logger.warn("Failed to fetch account profile info", error: e, trace: s, tag: 'ProfilePanel');
    }
    if (mounted) setState(() {});
  }

  Future<void> updateName() async {
    final name = await showBBInputDialog(
      context: context,
      title: "User Profile Name",
      icon: iOS ? CupertinoIcons.person : Icons.person_outline,
      initialValue: SettingsSvc.settings.userName.value,
      labelText: "Name",
      confirmText: "Save Name",
      textCapitalization: TextCapitalization.words,
      validator: (value) => (value == null || value.isEmpty) ? "Enter a name!" : null,
    );
    if (name == null) return;
    SettingsSvc.settings.userName.value = name;
    await SettingsSvc.settings.saveOneAsync("userName");
    if (mounted) setState(() {});
  }

  void updatePhoto() async {
    Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (context) => const AvatarCrop(),
      ),
    );
  }

  Future<void> removePhoto() async {
    final current = SettingsSvc.settings.userAvatarPath.value;
    if (current != null) {
      if (kIsWeb) {
        await FilesystemSvc.deleteWebAvatar(current);
      } else {
        final file = File(current);
        if (await file.exists()) await file.delete();
      }
    }
    SettingsSvc.settings.userAvatarPath.value = null;
    SettingsSvc.userAvatarBytes.value = null;
    await SettingsSvc.settings.saveOneAsync("userAvatarPath");
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      headerColor: headerColor,
      title: "iMessage Profile",
      tileColor: tileColor,
      initialHeader: null,
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      bodySlivers: [
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              if (iOS)
                Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: () async {
                          updatePhoto();
                        },
                        child: const ContactAvatarWidget(
                          handle: null,
                          borderThickness: 0.1,
                          editable: false,
                          fontSize: 22,
                          size: 100,
                        ),
                      ),
                      Obx(() {
                        final hasPath = !isNullOrEmpty(SettingsSvc.settings.userAvatarPath.value);
                        final hasBytes = SettingsSvc.userAvatarBytes.value != null;
                        return (hasPath || hasBytes)
                            ? Positioned(
                              right: -5,
                              top: -5,
                              child: InkWell(
                                onTap: () async {
                                  removePhoto();
                                },
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: context.theme.colorScheme.surface, width: 1),
                                    shape: BoxShape.circle,
                                    color: context.theme.colorScheme.tertiaryContainer,
                                  ),
                                  child: Icon(
                                    Icons.close,
                                    color: context.theme.colorScheme.onTertiaryContainer,
                                    size: 20,
                                  ),
                                ),
                              ),
                            )
                            : const SizedBox.shrink();
                      }),
                    ],
                  ),
                ),
              if (iOS)
                Padding(
                  padding: const EdgeInsets.only(top: 12.0),
                  child: Center(
                    child: Obx(() => RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: context.theme.textTheme.headlineMedium!.copyWith(
                              fontWeight: FontWeight.bold,
                              color: context.theme.colorScheme.onSurface,
                            ),
                            children: MessageHelper.buildEmojiText(
                              SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideContactInfo.value
                                  ? "User Name"
                                  : SettingsSvc.settings.userName.value,
                              context.theme.textTheme.headlineMedium!.copyWith(
                                fontWeight: FontWeight.bold,
                                color: context.theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        )),
                  ),
                ),
              if (iOS)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Center(
                    child: Obx(() => RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style:
                                context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.onSurfaceVariant),
                            children: MessageHelper.buildEmojiText(
                                SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideContactInfo.value
                                    ? "User iCloud"
                                    : SettingsSvc.settings.iCloudAccount.isEmpty
                                        ? "Unknown iCloud account"
                                        : SettingsSvc.settings.iCloudAccount.value,
                                context.theme.textTheme.bodyMedium!
                                    .apply(color: context.theme.colorScheme.onSurfaceVariant)),
                          ),
                        )),
                  ),
                ),
              if (iOS)
                Center(
                  child: TextButton(
                    child: Text(
                      "Change Name",
                      style: context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.primary),
                      textScaler: const TextScaler.linear(1.15),
                    ),
                    onPressed: () async {
                      updateName();
                    },
                  ),
                ),
              if (!iOS)
                Padding(
                  padding: const EdgeInsets.only(left: 15.0, bottom: 5.0),
                  child: Text("YOUR NAME AND PHOTO",
                      style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline)),
                ),
              if (!iOS)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5.0),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      mouseCursor: MouseCursor.defer,
                      leading: const ContactAvatarWidget(
                        handle: null,
                        borderThickness: 0.1,
                        editable: false,
                        fontSize: 22,
                        size: 50,
                      ),
                      onTap: () async {
                        updateName();
                      },
                      title: Obx(() => RichText(
                            text: TextSpan(
                              style: context.theme.textTheme.bodyLarge,
                              children: MessageHelper.buildEmojiText(
                                SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideContactInfo.value
                                    ? "User Name"
                                    : SettingsSvc.settings.userName.value,
                                context.theme.textTheme.bodyLarge!,
                              ),
                            ),
                          )),
                      subtitle: Obx(() => Text(
                          SettingsSvc.settings.redactedMode.value && SettingsSvc.settings.hideContactInfo.value
                              ? "User iCloud"
                              : SettingsSvc.settings.iCloudAccount.isEmpty
                                  ? "Unknown iCloud account"
                                  : SettingsSvc.settings.iCloudAccount.value,
                          style: context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.outline))),
                      trailing: Icon(Icons.edit_outlined, color: context.theme.colorScheme.onSurface),
                    ),
                  ),
                ),
              if (!iOS)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5.0),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      mouseCursor: MouseCursor.defer,
                      onTap: () async {
                        updatePhoto();
                      },
                      title: Text("Update your photo", style: context.theme.textTheme.bodyLarge!),
                      trailing: Icon(Icons.edit_outlined, color: context.theme.colorScheme.onSurface),
                    ),
                  ),
                ),
              if (!iOS)
                Obx(() {
                  final hasPath = !isNullOrEmpty(SettingsSvc.settings.userAvatarPath.value);
                  final hasBytes = SettingsSvc.userAvatarBytes.value != null;
                  return (hasPath || hasBytes)
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 5.0),
                          child: Material(
                            color: Colors.transparent,
                            child: ListTile(
                              mouseCursor: MouseCursor.defer,
                              onTap: () async {
                                removePhoto();
                              },
                              title: Text("Remove your photo",
                                  style: context.theme.textTheme.bodyLarge!
                                      .copyWith(color: context.theme.colorScheme.error)),
                              trailing: Icon(Icons.close, color: context.theme.colorScheme.error),
                            ),
                          ),
                        )
                      : const SizedBox.shrink();
                }),
              SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "iCloud Account Info"),
              Skeletonizer(
                  enabled: accountInfo.isEmpty,
                  child: SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      Obx(() {
                        bool redact = SettingsSvc.settings.redactedMode.value;
                        return SizedBox(
                          width: double.infinity,
                          child: Padding(
                          padding: const EdgeInsets.only(bottom: 8.0, left: 15, top: 8.0, right: 15),
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 300),
                            opacity: opacity.value,
                            child: SelectableText.rich(
                              TextSpan(children: [
                                TextSpan(
                                    text: redact
                                        ? "Account Name - Apple ID"
                                        : "${accountInfo['account_name']} - ${accountInfo['apple_id']}"),
                                const TextSpan(text: "\n"),
                                const TextSpan(text: "iMessage Status: ", style: TextStyle(height: 3.0)),
                                TextSpan(
                                    text: accountInfo['login_status_message']?.toUpperCase(),
                                    style: TextStyle(
                                        color: getIndicatorColor(accountInfo['login_status_message'] == "Connected"
                                            ? SocketState.connected
                                            : SocketState.disconnected))),
                                const TextSpan(text: "\n"),
                                const TextSpan(text: "SMS Forwarding Status: "),
                                TextSpan(
                                    text: accountInfo['sms_forwarding_enabled'] == true ? "ENABLED" : "DISABLED",
                                    style: TextStyle(
                                        color: getIndicatorColor(accountInfo['sms_forwarding_enabled'] == true
                                            ? SocketState.connected
                                            : SocketState.disconnected))),
                                const TextSpan(text: "  |  "),
                                TextSpan(
                                    text: accountInfo['sms_forwarding_capable'] == true ? "CAPABLE" : "INCAPABLE",
                                    style: TextStyle(
                                        color: getIndicatorColor(accountInfo['sms_forwarding_capable'] == true
                                            ? SocketState.connected
                                            : SocketState.disconnected))),
                                const TextSpan(text: "\n"),
                                const TextSpan(
                                    text: "VETTED ALIASES\n",
                                    style: TextStyle(fontWeight: FontWeight.w700, height: 3.0)),
                                ...((accountInfo['vetted_aliases'] as List<dynamic>? ?? []))
                                    .map((e) => [
                                          TextSpan(
                                              text: "⬤  ",
                                              style: TextStyle(
                                                  color: getIndicatorColor(e['Status'] == 3
                                                      ? SocketState.connected
                                                      : SocketState.disconnected))),
                                          TextSpan(text: redact ? "Alias\n" : "${e['Alias']}\n")
                                        ])
                                    .toList()
                                    .flattened,
                                const TextSpan(text: "\n"),
                                const TextSpan(
                                    text: "Tap to update values...", style: TextStyle(fontStyle: FontStyle.italic)),
                              ]),
                              onTap: () {
                                opacity.value = 0.0;
                                getDetails();
                              },
                            ),
                          ),
                          ),
                        );
                      }),
                      if (accountInfo['active_alias'] != null)
                        Container(
                          color: tileColor,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 15.0),
                            child: SettingsDivider(color: context.theme.colorScheme.outlineVariant),
                          ),
                        ),
                      if (accountInfo['active_alias'] != null)
                        SettingsOptions<String>(
                          title: "Start Chats Using",
                          initial: accountInfo['active_alias'],
                          clampWidth: false,
                          options: (accountInfo['vetted_aliases'] as List<dynamic>? ?? [])
                              .map((e) => e['Alias'].toString())
                              .toList()
                              .cast<String>(),
                          secondaryColor: headerColor,
                          useCupertino: false,
                          textProcessing: (str) => str,
                          capitalize: false,
                          onChanged: (value) async {
                            if (value == null) return;
                            accountInfo['active_alias'] = value;
                            setState(() {});
                            await HttpSvc.icloud.setAccountAlias(value);
                          },
                        ),
                    ],
                  )),
              if (!isNullOrEmpty(SettingsService.extractDisplayName(accountContact) ?? accountContact['name']))
                SettingsHeader(
                    iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "iMessage Contact Card"),
              if (!isNullOrEmpty(SettingsService.extractDisplayName(accountContact) ?? accountContact['name']))
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SettingsTile(
                          leading: () {
                            final avatarBytes = SettingsService.decodeAvatarBase64(accountContact['avatar']?.toString());
                            return avatarBytes != null
                                ? SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: ClipOval(
                                      child: Image.memory(
                                        avatarBytes,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => const CircleAvatar(),
                                      ),
                                    ),
                                  )
                                : const CircleAvatar();
                          }(),
                          title: SettingsService.extractDisplayName(accountContact) ?? accountContact['name'],
                          subtitle: "Your sharable iMessage contact card",
                        ),
                        const SettingsSubtitle(subtitle: "Visit iMessage settings on your Mac to update."),
                      ],
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.only(top: 50),
        ),
      ],
    );
  }
}

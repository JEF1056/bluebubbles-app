import 'package:bluebubbles/platform/shims/native_media.dart' as aw;
import 'package:bluebubbles/app/layouts/settings/pages/message_view/message_options_order_panel.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/database/models.dart' hide PlatformFile;
import 'package:bluebubbles/services/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Response;
import 'package:path/path.dart';
import 'package:universal_io/io.dart';

class ConversationPanel extends StatefulWidget {
  const ConversationPanel({super.key});

  @override
  State<StatefulWidget> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<ConversationPanel> with ThemeHelpers {
  final RxnBool gettingIcons = RxnBool(null);
  final RxBool playingSendSound = false.obs;
  final RxBool playingReceiveSound = false.obs;
  late final dynamic sendPlayer;
  late final dynamic receivePlayer;

  bool sendPrepared = false;
  bool receivePrepared = false;

  final RxBool _autoTranslateEnabled = false.obs;
  final RxString _targetLanguage = 'en'.obs;
  final RxBool _clearingTranslationCache = false.obs;

  static const _languageOptions = <String>[
    'en', 'es', 'fr', 'de', 'it', 'pt', 'zh-CN', 'zh-TW', 'ja', 'ko', 'ar', 'hi', 'ru', 'nl', 'pl', 'tr', 'vi', 'th', 'id',
  ];

  @override
  void initState() {
    super.initState();
    _loadTranslationConfig();

    if (kIsDesktop) {
      sendPlayer = Player();
      receivePlayer = Player();
      (sendPlayer as Player).stream.playing.listen((value) => playingSendSound.value = value);
      (receivePlayer as Player).stream.playing.listen((value) => playingReceiveSound.value = value);
    } else {
      sendPlayer = aw.PlayerController();
      receivePlayer = aw.PlayerController();
      (sendPlayer as aw.PlayerController)
          .onPlayerStateChanged
          .listen((value) => playingSendSound.value = value == aw.PlayerState.playing);
      (receivePlayer as aw.PlayerController)
          .onPlayerStateChanged
          .listen((value) => playingReceiveSound.value = value == aw.PlayerState.playing);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: "Conversations",
      initialHeader: "Customization",
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      bodySlivers: [
        SliverList(
          delegate: SliverChildListDelegate(
            <Widget>[
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          SettingsSvc.settings.showDeliveryTimestamps.value = val;
                          await SettingsSvc.settings.saveOneAsync('showDeliveryTimestamps');
                        },
                        initialVal: SettingsSvc.settings.showDeliveryTimestamps.value,
                        title: "Show Delivery Timestamps",
                        backgroundColor: tileColor,
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          SettingsSvc.settings.recipientAsPlaceholder.value = val;
                          await SettingsSvc.settings.saveOneAsync('recipientAsPlaceholder');
                        },
                        initialVal: SettingsSvc.settings.recipientAsPlaceholder.value,
                        title: "Show Chat Name as Placeholder",
                        subtitle: "Changes the default hint text in the message box to display the recipient name",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          SettingsSvc.settings.alwaysShowAvatars.value = val;
                          await SettingsSvc.settings.saveOneAsync('alwaysShowAvatars');
                        },
                        initialVal: SettingsSvc.settings.alwaysShowAvatars.value,
                        title: "Show Avatars in DM Chats",
                        subtitle: "Shows contact avatars in direct messages rather than just in group messages",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  if (!kIsWeb && !kIsDesktop) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.smartReply.value = val;
                            await SettingsSvc.settings.saveOneAsync('smartReply');
                          },
                          initialVal: SettingsSvc.settings.smartReply.value,
                          title: "Smart Suggestions",
                          subtitle:
                              "Shows smart reply suggestions above the message text field and detects various interactive content in message text",
                          backgroundColor: tileColor,
                          isThreeLine: true,
                        )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          SettingsSvc.settings.repliesToPrevious.value = val;
                          await SettingsSvc.settings.saveOneAsync('repliesToPrevious');
                        },
                        initialVal: SettingsSvc.settings.repliesToPrevious.value,
                        title: "Show Replies To Previous Message",
                        subtitle: "Shows replies to the previous message in the thread rather than the original",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  // One tile: a static title/description header, styled like
                  // `SettingsTile`, with the toggle underneath rather than beside
                  // it. `SettingsOptions` gets an empty title so it renders no
                  // label of its own on any skin — the iOS segmented control was
                  // otherwise unlabeled entirely, and Material's inline label sat
                  // beside the control rather than above it either way.
                  //
                  // Both pieces have to live inside one `Column` here, as a single
                  // entry in `SettingsSection.children` — on Material/Samsung,
                  // `M3ESection` gives every *top-level* child its own rounded
                  // corners and a gap from its neighbors, so two separate entries
                  // rendered as two visually distinct tiles despite having no
                  // divider between them. iOS didn't show the seam because its
                  // `SettingsSection` just stacks every child in one card.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16.0, 14.0, 16.0, 0.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Load Link Previews", style: context.theme.textTheme.bodyLarge),
                            const SizedBox(height: 4.0),
                            Text(
                              "Loading a preview visits the link, which can reveal your IP address and roughly "
                              "when you read the message to whoever controls it.",
                              style: context.theme.textTheme.bodySmall!.copyWith(
                                  color: context.theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75)),
                            ),
                          ],
                        ),
                      ),
                      Obx(() => SettingsOptions<LinkPreviewPolicy>(
                            initial: SettingsSvc.settings.linkPreviewPolicy.value,
                            onChanged: (val) async {
                              if (val == null) return;
                              SettingsSvc.settings.linkPreviewPolicy.value = val;
                              await SettingsSvc.settings.saveOneAsync('linkPreviewPolicy');
                            },
                            options: LinkPreviewPolicy.values,
                            textProcessing: (val) => val.label,
                            capitalize: false,
                            title: "",
                            secondaryColor: headerColor,
                            useModernMenu: true,
                            clampWidth: false
                          )),
                    ],
                  ),
                  if (!kIsWeb) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb)
                    SettingsTile(
                      title: "Message Options Order",
                      subtitle:
                          "Set the order for the options when ${SettingsSvc.settings.doubleTapForDetails.value ? "double-tapping" : "pressing and holding"} a message",
                      onTap: () {
                        NavigationSvc.pushSettings(
                          context,
                          const MessageOptionsOrderPanel(),
                        );
                      },
                      trailing: const NextButton(),
                    ),
                  if (!kIsWeb) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SettingsTile(
                          title: "Sync Group Chat Icons",
                          trailing: Obx(() => gettingIcons.value == null
                              ? const SizedBox.shrink()
                              : gettingIcons.value == true
                                  ? Container(
                                      constraints: const BoxConstraints(
                                        maxHeight: 20,
                                        maxWidth: 20,
                                      ),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                                      ))
                                  : Icon(Icons.check, color: context.theme.colorScheme.outline)),
                          onTap: () async {
                            gettingIcons.value = true;
                            for (Chat c in ChatsSvc.groupChats) {
                              await Chat.getIcon(c, force: true);
                            }
                            gettingIcons.value = false;
                          },
                          subtitle: "Get iMessage group chat icons from the server",
                        ),
                        const SettingsSubtitle(
                          subtitle: "Note: Overrides any custom avatars set for group chats.",
                        ),
                      ],
                    ),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          SettingsSvc.settings.hideNamesForReactions.value = val;
                          SettingsSvc.settings.saveOneAsync("hideNamesForReactions");
                        },
                        initialVal: SettingsSvc.settings.hideNamesForReactions.value,
                        title: "Hide Names in Reaction Details",
                        subtitle:
                            "Enable this to hide names under participant avatars when you view a message's reactions",
                        backgroundColor: tileColor,
                      )),
                ],
              ),
              if (!kIsWeb)
                SettingsHeader(
                  iosSubtitle: iosSubtitle,
                  materialSubtitle: materialSubtitle,
                  text: "Sounds",
                ),
              if (!kIsWeb)
                Obx(
                  () => SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      SettingsTile(
                        title: "${SettingsSvc.settings.sendSoundPath.value == null ? "Customize" : "Change"} Send Sound",
                        subtitle: SettingsSvc.settings.sendSoundPath.value != null
                            ? basename(SettingsSvc.settings.sendSoundPath.value!).substring("send-".length)
                            : "Default: Google Messages (tap to customize)",
                        onTap: () async {
                          PlatformFile? platformFile = await FilePicker.pickFile(type: FileType.audio);
                          if (platformFile != null) {
                            String path = join(FilesystemSvc.soundsPath, "send-${platformFile.name}");
                            await File(path).create(recursive: true);
                            await File(path).writeAsBytes(await platformFile.readAsBytes());
                            SettingsSvc.settings.sendSoundPath.value = path;
                            await SettingsSvc.settings.saveOneAsync('sendSoundPath');
                          }
                        },
                        trailing: (SettingsSvc.settings.sendSoundPath.value == null)
                            ? const SizedBox.shrink()
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                      icon: playingSendSound.value
                                          ? Icon(SettingsSvc.settings.skin.value == Skins.iOS
                                              ? CupertinoIcons.stop
                                              : Icons.stop_outlined)
                                          : Icon(SettingsSvc.settings.skin.value == Skins.iOS
                                              ? CupertinoIcons.play
                                              : Icons.play_arrow_outlined),
                                      onPressed: () async {
                                        if (sendPlayer is Player) {
                                          final Player _sendPlayer = sendPlayer as Player;
                                          if (playingSendSound.value) {
                                            await _sendPlayer.stop();
                                          } else {
                                            await _sendPlayer
                                                .setVolume(SettingsSvc.settings.soundVolume.value.toDouble());
                                            await _sendPlayer.open(Media(SettingsSvc.settings.sendSoundPath.value!));
                                          }
                                        } else if (sendPlayer is aw.PlayerController) {
                                          final aw.PlayerController _sendPlayer = sendPlayer as aw.PlayerController;
                                          if (playingSendSound.value) {
                                            await _sendPlayer.pausePlayer();
                                          } else {
                                            if (!sendPrepared) {
                                              await _sendPlayer.preparePlayer(
                                                  path: SettingsSvc.settings.sendSoundPath.value!,
                                                  volume: SettingsSvc.settings.soundVolume.value.toDouble() / 100);
                                              sendPrepared = true;
                                            }
                                            _sendPlayer.setFinishMode(finishMode: aw.FinishMode.pause);
                                            await _sendPlayer.startPlayer();
                                          }
                                        }
                                      }),
                                  IconButton(
                                    icon: Icon(SettingsSvc.settings.skin.value == Skins.iOS
                                        ? CupertinoIcons.trash
                                        : Icons.delete_outline),
                                    onPressed: () async {
                                      File file = File(SettingsSvc.settings.sendSoundPath.value!);
                                      if (await file.exists()) {
                                        await file.delete();
                                      }
                                      SettingsSvc.settings.sendSoundPath.value = null;
                                      await SettingsSvc.settings.saveOneAsync('sendSoundPath');
                                    },
                                  ),
                                ],
                              ),
                      ),
                      const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                      SettingsTile(
                        title:
                            "${SettingsSvc.settings.receiveSoundPath.value == null ? "Customize" : "Change"} Receive Sound",
                        subtitle: SettingsSvc.settings.receiveSoundPath.value != null
                            ? basename(SettingsSvc.settings.receiveSoundPath.value!).substring("receive-".length)
                            : "Default: Google Messages (tap to customize)",
                        onTap: () async {
                          PlatformFile? platformFile = await FilePicker.pickFile(type: FileType.audio);
                          if (platformFile != null) {
                            String path = join(FilesystemSvc.soundsPath, "receive-${platformFile.name}");
                            await File(path).create(recursive: true);
                            await File(path).writeAsBytes(await platformFile.readAsBytes());
                            SettingsSvc.settings.receiveSoundPath.value = path;
                            await SettingsSvc.settings.saveOneAsync('receiveSoundPath');
                          }
                        },
                        trailing: (SettingsSvc.settings.receiveSoundPath.value == null)
                            ? const SizedBox.shrink()
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                      icon: playingReceiveSound.value
                                          ? Icon(SettingsSvc.settings.skin.value == Skins.iOS
                                              ? CupertinoIcons.stop
                                              : Icons.stop_outlined)
                                          : Icon(SettingsSvc.settings.skin.value == Skins.iOS
                                              ? CupertinoIcons.play
                                              : Icons.play_arrow_outlined),
                                      onPressed: () async {
                                        if (receivePlayer is Player) {
                                          final Player _receivePlayer = receivePlayer as Player;
                                          if (playingReceiveSound.value) {
                                            await _receivePlayer.stop();
                                          } else {
                                            await _receivePlayer
                                                .setVolume(SettingsSvc.settings.soundVolume.value.toDouble());
                                            await _receivePlayer
                                                .open(Media(SettingsSvc.settings.receiveSoundPath.value!));
                                          }
                                        } else if (receivePlayer is aw.PlayerController) {
                                          final aw.PlayerController _receivePlayer =
                                              receivePlayer as aw.PlayerController;
                                          if (playingReceiveSound.value) {
                                            await _receivePlayer.pausePlayer();
                                          } else {
                                            if (!receivePrepared) {
                                              await _receivePlayer.preparePlayer(
                                                  path: SettingsSvc.settings.receiveSoundPath.value!,
                                                  volume: SettingsSvc.settings.soundVolume.value / 100);
                                              receivePrepared = true;
                                            }
                                            _receivePlayer.setFinishMode(finishMode: aw.FinishMode.pause);
                                            await _receivePlayer.startPlayer();
                                          }
                                        }
                                      }),
                                  IconButton(
                                    icon: Icon(SettingsSvc.settings.skin.value == Skins.iOS
                                        ? CupertinoIcons.trash
                                        : Icons.delete_outline),
                                    onPressed: () async {
                                      File file = File(SettingsSvc.settings.receiveSoundPath.value!);
                                      if (await file.exists()) {
                                        await file.delete();
                                      }
                                      SettingsSvc.settings.receiveSoundPath.value = null;
                                      await SettingsSvc.settings.saveOneAsync('receiveSoundPath');
                                    },
                                  ),
                                ],
                              ),
                      ),
                      const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SettingsTile(
                            title: "Send/Receive Sound Volume",
                            subtitle: "Controls the volume of the send and receive sounds",
                          ),
                          Obx(() => SettingsSlider(
                                startingVal: SettingsSvc.settings.soundVolume.value.toDouble(),
                                min: 0,
                                max: 100,
                                divisions: 100,
                                formatValue: (val) => "${val.toInt()}",
                                update: (val) => SettingsSvc.settings.soundVolume.value = val.toInt(),
                              )),
                        ],
                      ),
                    ],
                  ),
                ),
              SettingsHeader(
                iosSubtitle: iosSubtitle,
                materialSubtitle: materialSubtitle,
                text: "Gestures",
              ),
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.autoOpenKeyboard.value = val;
                            await SettingsSvc.settings.saveOneAsync('autoOpenKeyboard');
                          },
                          initialVal: SettingsSvc.settings.autoOpenKeyboard.value,
                          title: "Auto-open Keyboard",
                          subtitle: "Automatically open the keyboard when entering a chat",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.swipeToCloseKeyboard.value = val;
                            await SettingsSvc.settings.saveOneAsync('swipeToCloseKeyboard');
                          },
                          initialVal: SettingsSvc.settings.swipeToCloseKeyboard.value,
                          title: "Swipe Message Box to Close Keyboard",
                          subtitle: "Swipe down on the message box to hide the keyboard",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.swipeToOpenKeyboard.value = val;
                            await SettingsSvc.settings.saveOneAsync('swipeToOpenKeyboard');
                          },
                          initialVal: SettingsSvc.settings.swipeToOpenKeyboard.value,
                          title: "Swipe Message Box to Open Keyboard",
                          subtitle: "Swipe up on the message box to show the keyboard",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.hideKeyboardOnScroll.value = val;
                            await SettingsSvc.settings.saveOneAsync('hideKeyboardOnScroll');
                          },
                          initialVal: SettingsSvc.settings.hideKeyboardOnScroll.value,
                          title: "Hide Keyboard When Scrolling",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.openKeyboardOnSTB.value = val;
                            await SettingsSvc.settings.saveOneAsync('openKeyboardOnSTB');
                          },
                          initialVal: SettingsSvc.settings.openKeyboardOnSTB.value,
                          title: "Open Keyboard After Tapping Scroll To Bottom",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          SettingsSvc.settings.doubleTapForDetails.value = val;
                          if (val && SettingsSvc.settings.enableQuickTapback.value) {
                            SettingsSvc.settings.enableQuickTapback.value = false;
                            await SettingsSvc.settings.saveManyAsync(['doubleTapForDetails', 'enableQuickTapback']);
                          } else {
                            await SettingsSvc.settings.saveOneAsync('doubleTapForDetails');
                          }
                        },
                        initialVal: SettingsSvc.settings.doubleTapForDetails.value,
                        title: "Double-${kIsWeb || kIsDesktop ? "Click" : "Tap"} Message for Details",
                        subtitle:
                            "Opens the message details popup when double ${kIsWeb || kIsDesktop ? "click" : "tapp"}ing a message",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  if (!kIsDesktop && !kIsWeb) const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsDesktop && !kIsWeb)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            SettingsSvc.settings.sendWithReturn.value = val;
                            await SettingsSvc.settings.saveOneAsync('sendWithReturn');
                          },
                          initialVal: SettingsSvc.settings.sendWithReturn.value,
                          title: "Send Message with Enter",
                          backgroundColor: tileColor,
                        )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          SettingsSvc.settings.scrollToBottomOnSend.value = val;
                          await SettingsSvc.settings.saveOneAsync('scrollToBottomOnSend');
                        },
                        initialVal: SettingsSvc.settings.scrollToBottomOnSend.value,
                        title: "Scroll To Bottom When Sending Messages",
                        subtitle: "Scroll to the most recent messages in the chat when sending a new text",
                        backgroundColor: tileColor,
                      )),
                ],
              ),
              SettingsHeader(
                iosSubtitle: iosSubtitle,
                materialSubtitle: materialSubtitle,
                text: "Translation",
              ),
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) async {
                          final prev = _autoTranslateEnabled.value;
                          _autoTranslateEnabled.value = val;
                          try {
                            await HttpSvc.updateTranslationConfig(autoTranslateEnabled: val);
                          } catch (_) {
                            _autoTranslateEnabled.value = prev;
                            showSnackbar("Error", "Failed to update translation settings", type: SnackbarType.error);
                          }
                        },
                        initialVal: _autoTranslateEnabled.value,
                        title: "Auto-Translate Incoming Messages",
                        subtitle: "Automatically translate incoming messages on the server",
                        backgroundColor: tileColor,
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsTile(
                        title: "Preferred Language",
                        subtitle: MessageTranslation.languageName(_targetLanguage.value),
                        onTap: _pickTargetLanguage,
                        trailing: const NextButton(),
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsTile(
                        title: "Clear Translation Cache",
                        subtitle: "Remove cached translations on the server",
                        trailing: _clearingTranslationCache.value
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : null,
                        onTap: () async {
                          if (_clearingTranslationCache.value) return;
                          _clearingTranslationCache.value = true;
                          try {
                            await HttpSvc.clearTranslationCache();
                            showSnackbar("Notice", "Translation cache cleared");
                          } catch (_) {
                            showSnackbar("Error", "Failed to clear translation cache", type: SnackbarType.error);
                          } finally {
                            _clearingTranslationCache.value = false;
                          }
                        },
                      )),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _loadTranslationConfig() async {
    try {
      final resp = await HttpSvc.getTranslationConfig();
      final data = resp.data?['data'];
      if (data is Map) {
        _autoTranslateEnabled.value = data['auto_translate_enabled'] == true;
        final lang = data['translation_target_language']?.toString();
        if (lang != null && lang.isNotEmpty) _targetLanguage.value = lang;
      }
    } catch (_) {}
  }

  Future<void> _pickTargetLanguage() async {
    final chosen = await showDialog<String>(
      context: this.context,
      builder: (ctx) => SimpleDialog(
        title: const Text("Preferred Language"),
        children: [
          for (final code in _languageOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(code),
              child: Row(
                children: [
                  Expanded(child: Text(MessageTranslation.languageName(code))),
                  if (_targetLanguage.value == code) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == _targetLanguage.value) return;
    final prev = _targetLanguage.value;
    _targetLanguage.value = chosen;
    try {
      await HttpSvc.updateTranslationConfig(targetLanguage: chosen);
    } catch (_) {
      _targetLanguage.value = prev;
      showSnackbar("Error", "Failed to update preferred language", type: SnackbarType.error);
    }
  }

  @override
  void dispose() {
    if (kIsDesktop) {
      (sendPlayer as Player).dispose();
      (receivePlayer as Player).dispose();
    } else {
      (sendPlayer as aw.PlayerController).dispose();
      (receivePlayer as aw.PlayerController).dispose();
    }
    super.dispose();
  }
}

import 'dart:async';

import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/effects/send_effect_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/audio_player.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/handlers/web_input_interop.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/send_button.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:multi_value_listenable_builder/multi_value_listenable_builder.dart';
import 'package:path/path.dart';
import 'package:record/record.dart';
import 'package:universal_io/io.dart';

class TextFieldSuffix extends StatefulWidget {
  const TextFieldSuffix({
    super.key,
    required this.subjectTextController,
    required this.textController,
    required this.controller,
    required this.recorderController,
    required this.sendMessage,
    this.audioRecorder,
    this.isChatCreator = false,
    this.alwaysShowSend = false,
    this.hasInitialAttachments = false,
  });

  final TextEditingController? subjectTextController;
  final TextEditingController textController;
  final ConversationViewController? controller;
  final RecorderController? recorderController;
  final AudioRecorder? audioRecorder;
  final Future<void> Function({String? effect}) sendMessage;
  final bool isChatCreator;

  /// When true the send button is always shown, regardless of whether there
  /// is text or attachments. Used in the chat creator when an existing chat
  /// has been resolved so the user can open the conversation without typing.
  final bool alwaysShowSend;

  /// Mirrors `initialAttachments.isNotEmpty` from the parent TextFieldComponent.
  /// Used in isChatCreator mode to show the send button when attachments are
  /// pre-loaded (e.g. shared from another app) but no text has been typed yet.
  final bool hasInitialAttachments;

  @override
  State<StatefulWidget> createState() => _TextFieldSuffixState();
}

class _TextFieldSuffixState extends State<TextFieldSuffix> with ThemeHelpers {
  late final AudioRecorder audioRecorder = widget.audioRecorder ?? AudioRecorder();

  // Cache these values at init to avoid repeated platform checks
  late final bool _isWeb = kIsWeb;
  late final bool _isDesktop = kIsDesktop;

  bool get isChatCreator => widget.isChatCreator;
  bool get alwaysShowSend => widget.alwaysShowSend;

  void deleteAudioRecording(String path) {
    if (kIsWeb) {
      revokeWebObjectUrl(path);
      return;
    }
    File(path).delete();
  }

  @override
  Widget build(BuildContext context) {
    return MultiValueListenableBuilder(
      valueListenables: [widget.textController, widget.subjectTextController].nonNulls.toList(),
      builder: (context, values, _) {
        // Extract text checks outside Obx - these are already reactive via MultiValueListenableBuilder
        final hasText = widget.textController.text.isNotEmpty;
        final hasSubject = widget.subjectTextController?.text.isNotEmpty ?? false;

        // For chat creator, we don't have a controller, so skip Obx.
        // Only show the send button when there is actually content to send;
        // otherwise the button is hidden entirely to avoid a no-op tap.
        if (isChatCreator) {
          // When a controller is present (existing chat resolved), use Obx to
          // reactively watch pickedAttachments and respect alwaysShowSend.
          if (widget.controller != null) {
            return Obx(() {
              final hasAttachments = widget.controller!.pickedAttachments.isNotEmpty;
              final canSend = alwaysShowSend || hasText || hasAttachments || widget.hasInitialAttachments;
              if (!canSend) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.all(3.0),
                child: SendButton(
                  sendMessage: widget.sendMessage,
                  onLongPress: () {},
                ),
              );
            });
          }
          // No controller — check static values only.
          final canSendInCreator = hasText || widget.hasInitialAttachments;
          if (!canSendInCreator) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.all(3.0),
            child: SendButton(
              sendMessage: widget.sendMessage,
              onLongPress: () {},
            ),
          );
        }

        return Obx(() {
          // Only reactive values in Obx scope - controller is guaranteed non-null here
          final hasAttachments =
              widget.controller!.pickedAttachments.isNotEmpty || widget.controller!.pendingGame.value != null;
          final showRecording =
              widget.controller!.showRecording.value && (_isWeb || widget.recorderController != null);
          final canSend = alwaysShowSend || hasText || hasSubject || hasAttachments;

          final isMaterial = SettingsSvc.settings.skin.value == Skins.Material && !isChatCreator;

          return Padding(
            padding: EdgeInsets.all(isMaterial ? 0.0 : 3.0),
            child: AnimatedCrossFade(
              alignment: Alignment.center,
              crossFadeState: canSend && !showRecording ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 150),
              firstChild: _RecordingButton(
                isWeb: _isWeb,
                isDesktop: _isDesktop,
                isChatCreator: isChatCreator,
                alwaysShowSend: alwaysShowSend,
                showRecording: showRecording,
                controller: widget.controller,
                recorderController: widget.recorderController,
                audioRecorder: audioRecorder,
                onDeleteRecording: deleteAudioRecording,
              ),
              secondChild: SendButton(
                sendMessage: widget.sendMessage,
                onLongPress: () {
                  if (widget.controller!.scheduledDate.value != null) return;
                  sendEffectAction(
                    context,
                    widget.controller!,
                    widget.textController.text,
                    widget.subjectTextController?.text.trim() ?? "",
                    widget.controller!.replyToMessage?.message.guid,
                    widget.controller!.replyToMessage?.partIndex,
                    widget.controller!.chat.guid,
                    widget.sendMessage,
                    widget.textController is MentionTextEditingController
                        ? (widget.textController as MentionTextEditingController).sendableRuns
                        : const [],
                  );
                },
              ),
            ),
          );
        });
      },
    );
  }

  @override
  void dispose() {
    if (widget.audioRecorder == null) {
      audioRecorder.dispose();
    }

    super.dispose();
  }
}

/// Extracted recording button to reduce Obx rebuild scope and prevent
/// unnecessary rebuilds of the complex recording UI
class _RecordingButton extends StatelessWidget {
  const _RecordingButton({
    required this.isWeb,
    required this.isDesktop,
    required this.isChatCreator,
    required this.alwaysShowSend,
    required this.showRecording,
    required this.controller,
    required this.recorderController,
    required this.audioRecorder,
    required this.onDeleteRecording,
  });

  final bool isWeb;
  final bool isDesktop;
  final bool isChatCreator;
  final bool alwaysShowSend;
  final bool showRecording;
  final ConversationViewController? controller;
  final RecorderController? recorderController;
  final AudioRecorder audioRecorder;
  final Function(String) onDeleteRecording;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
      final isMaterial = SettingsSvc.settings.skin.value == Skins.Material;
      final buttonSize = isIOS ? const Size(32, 32) : const Size(48, 48);

      return TextButton(
        style: TextButton.styleFrom(
          backgroundColor: isMaterial && !isChatCreator
              ? (showRecording
                  ? context.theme.colorScheme.errorContainer
                  : context.theme.colorScheme.primaryContainer)
              : !isIOS || (isIOS && !isChatCreator && !showRecording)
                  ? null
                  : !isChatCreator && !showRecording
                      ? context.theme.colorScheme.outline
                      : context.theme.colorScheme.primary.withValues(alpha: 0.4),
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          fixedSize: buttonSize,
          maximumSize: buttonSize,
          minimumSize: buttonSize,
          tapTargetSize: isIOS ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
        ),
        child: SizedBox(
          width: buttonSize.width,
          height: buttonSize.height,
          child: Center(
            child: !isChatCreator && !showRecording
                ? Icon(
                    isIOS
                        ? CupertinoIcons.mic_fill
                        : isMaterial
                            ? Icons.graphic_eq
                            : Icons.mic_none,
                    color: isIOS
                        ? context.theme.colorScheme.outline.withValues(alpha: 0.8)
                        : isMaterial
                            ? context.theme.colorScheme.onPrimaryContainer
                            : context.theme.colorScheme.onSurfaceVariant,
                    size: isIOS ? 18 : 22,
                  )
                : Icon(
                    isIOS ? CupertinoIcons.stop_fill : Icons.stop_circle,
                    color: isIOS
                        ? context.theme.colorScheme.primary
                        : isMaterial
                            ? context.theme.colorScheme.onErrorContainer
                            : context.theme.colorScheme.onSurfaceVariant,
                    size: isIOS ? 15 : 22,
                  ),
          ),
        ),
        onPressed: () async {
          if (controller == null) return;
          controller!.onUserChatInteraction(immediate: true);
          controller!.showRecording.toggle();

          if (controller!.showRecording.value) {
            if (controller!.isDictating.value) {
              await controller!.stopDictation?.call();
            }
            // Start recording
            if (isWeb) {
              try {
                final hasPerm = await audioRecorder.hasPermission();
                if (!hasPerm) {
                  controller!.showRecording.value = false;
                  showSnackbar(
                    "Error",
                    "Microphone access was denied. Please allow microphone permissions in your browser.",
                    type: SnackbarType.error,
                  );
                  return;
                }
                final encoder = await pickWebAudioEncoder(audioRecorder);
                await audioRecorder.start(
                  RecordConfig(encoder: encoder, bitRate: 128000),
                  path: '',
                );
                if (!await audioRecorder.isRecording()) {
                  controller!.showRecording.value = false;
                  showSnackbar("Error", "Failed to start recording. Please check microphone permissions.",
                      type: SnackbarType.error);
                } else if (SettingsSvc.settings.soundVolume.value > 0) {
                  unawaited(playAppSound(
                    AppSounds.recordingStart,
                    volume: SettingsSvc.settings.soundVolume.value / 100.0,
                  ));
                }
              } catch (e, stack) {
                controller!.showRecording.value = false;
                showSnackbar("Error", "Failed to start recording. Please check microphone permissions.",
                    type: SnackbarType.error);
                Logger.error("Error starting web recording", error: e, trace: stack);
              }
              return;
            }
            if (isDesktop) {
              try {
                File temp = File(join(
                  FilesystemSvc.appDocDir.path,
                  "temp",
                  "recorder",
                  "${controller!.chat.guid.characters.where((c) => c.isAlphabetOnly || c.isNumericOnly).join()}.m4a",
                ));
                temp.createSync(recursive: true);
                // Windows Media Foundation AAC encoder strictly supports up to 192 kbps (192000 bps).
                // Requesting an unsupported bitrate causes MF_E_INVALIDMEDIATYPE (0xC00D36B4).
                await audioRecorder.start(const RecordConfig(bitRate: 192000), path: temp.path);
                if (SettingsSvc.settings.soundVolume.value > 0) {
                  unawaited(playAppSound(
                    AppSounds.recordingStart,
                    volume: SettingsSvc.settings.soundVolume.value / 100.0,
                  ));
                }
              } catch (e, stack) {
                controller!.showRecording.value = false;
                showSnackbar("Error", "Failed to start recording. Please check microphone permissions.",
                    type: SnackbarType.error);
                Logger.error("Error starting desktop recording", error: e, trace: stack);
              }
              return;
            }
            try {
              await recorderController!.record(
                recorderSettings: const RecorderSettings(
                  sampleRate: 44100,
                  bitRate: 320000,
                ),
              );
              // If the recorder still isn't in a recording state after the call,
              // treat it as a failure and reset the UI.
              if (!recorderController!.isRecording) {
                controller!.showRecording.value = false;
                showSnackbar("Error", "Failed to start recording. Please check microphone permissions.",
                    type: SnackbarType.error);
              } else if (SettingsSvc.settings.soundVolume.value > 0) {
                unawaited(playAppSound(
                  AppSounds.recordingStart,
                  volume: SettingsSvc.settings.soundVolume.value / 100.0,
                ));
              }
            } catch (e, stack) {
              controller!.showRecording.value = false;
              showSnackbar("Error", "Failed to start recording. Please check microphone permissions.",
                  type: SnackbarType.error);
              Logger.error("Error starting recording", error: e, trace: stack);
            }
          } else {
            // Stop recording and show dialog
            final String? stoppedPath;
            late final PlatformFile file;

            if (isWeb) {
              try {
                stoppedPath = await audioRecorder.stop();
              } catch (e, stack) {
                showSnackbar("Error", "Failed to save voice memo. Please try again.", type: SnackbarType.error);
                Logger.error("Error stopping web recording", error: e, trace: stack);
                return;
              }
              if (stoppedPath == null) {
                showSnackbar("Error", "Failed to save voice memo. Please try again.", type: SnackbarType.error);
                return;
              }
              ({Uint8List bytes, String mimeType})? blobData;
              try {
                blobData = await readWebBlobUrlBytes(stoppedPath);
              } catch (e, stack) {
                Logger.error("Error reading web recording blob", error: e, trace: stack);
              } finally {
                revokeWebObjectUrl(stoppedPath);
              }
              if (blobData == null || blobData.bytes.isEmpty) {
                showSnackbar("Error", "Failed to save voice memo. Please try again.", type: SnackbarType.error);
                return;
              }
              final ext = audioExtensionForMime(blobData.mimeType);
              file = PlatformFile(
                name: "voice_memo_${DateTime.now().millisecondsSinceEpoch}.$ext",
                bytes: blobData.bytes,
                size: blobData.bytes.length,
              );
            } else if (isDesktop) {
              stoppedPath = await audioRecorder.stop();
              if (stoppedPath == null) {
                showSnackbar("Error", "Failed to save voice memo. Please try again.", type: SnackbarType.error);
                return;
              }
              final _file = File(stoppedPath);
              file = PlatformFile(
                name: basename(_file.path),
                path: _file.path,
                bytes: await _file.readAsBytes(),
                size: await _file.length(),
              );
            } else {
              stoppedPath = await recorderController!.stop();
              if (stoppedPath == null) {
                showSnackbar("Error", "Failed to save voice memo. Please try again.", type: SnackbarType.error);
                return;
              }
              final _file = File(stoppedPath);
              file = PlatformFile(
                name: basename(_file.path),
                path: _file.path,
                bytes: await _file.readAsBytes(),
                size: await _file.length(),
              );
            }
            if (SettingsSvc.settings.soundVolume.value > 0) {
              unawaited(playAppSound(
                AppSounds.recordingStop,
                volume: SettingsSvc.settings.soundVolume.value / 100.0,
              ));
            }

            final String path = stoppedPath;
            if (!context.mounted) return;

            await showBBDialog(
              context: context,
              barrierDismissible: false,
              title: "Send it?",
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Review your audio snippet before sending it",
                    style: context.theme.textTheme.bodyLarge,
                  ),
                  Container(height: 10.0),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: context.width * 0.6),
                    child: AudioPlayer(
                      key: Key("AudioMessage-$path"),
                      file: file,
                      attachment: null,
                    ),
                  )
                ],
              ),
              actions: <BBDialogAction>[
                BBDialogAction(
                  text: "Discard",
                  isDestructive: true,
                  onPressed: () {
                    onDeleteRecording(path);
                    Navigator.of(context, rootNavigator: true).pop();
                  },
                ),
                BBDialogAction(
                  text: "Send",
                  isDefault: true,
                  onPressed: () async {
                    controller!.onUserChatInteraction(immediate: true);
                    await controller!.send(SendData(
                      attachments: [file],
                      text: "",
                      subject: "",
                      isAudioMessage: true,
                    ));
                    onDeleteRecording(path);
                    Navigator.of(context, rootNavigator: true).pop();
                  },
                ),
              ],
            );
          }
        },
      );
    });
  }
}

@visibleForTesting
Future<AudioEncoder> pickWebAudioEncoder(AudioRecorder recorder) async {
  if (await recorder.isEncoderSupported(AudioEncoder.aacLc)) {
    return AudioEncoder.aacLc;
  }
  if (await recorder.isEncoderSupported(AudioEncoder.opus)) {
    return AudioEncoder.opus;
  }
  return AudioEncoder.wav;
}

@visibleForTesting
String audioExtensionForMime(String mimeType) {
  final clean = mimeType.split(';').first.trim().toLowerCase();
  if (clean.contains('mp4') || clean.contains('aac')) return 'm4a';
  if (clean.contains('webm')) return 'webm';
  if (clean.contains('ogg')) return 'ogg';
  if (clean.contains('wav')) return 'wav';
  return 'm4a';
}

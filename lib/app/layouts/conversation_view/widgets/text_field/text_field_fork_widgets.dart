import 'dart:async';

import 'package:bluebubbles/helpers/web/web_speech_stub.dart'
    if (dart.library.js_interop) 'package:bluebubbles/helpers/web/web_speech_web.dart' as web_speech;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';

String hintTextForService({
  required bool material,
  required bool isRCS,
  required bool isIMessage,
}) {
  if (material) {
    if (isRCS) return "RCS message";
    return isIMessage ? "iMessage" : "Text message";
  }
  if (isRCS) return "Text Message • RCS";
  return isIMessage ? "iMessage" : "Text Forwarding";
}

class DictationMicButton extends StatelessWidget {
  const DictationMicButton({
    super.key,
    required this.dictation,
    required this.iOS,
    this.compact = false,
    this.onBeforeToggle,
  });

  final NativeSpeechDictation dictation;
  final bool iOS;
  final bool compact;
  final VoidCallback? onBeforeToggle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: dictation.isListening,
      builder: (context, listening, _) {
        final colors = context.theme.colorScheme;
        final size = compact ? 32.0 : 38.0;
        return IconButton(
          key: const Key('native-stt-mic-button'),
          tooltip: listening ? 'Stop voice typing' : 'Voice typing',
          constraints: BoxConstraints(minWidth: size, minHeight: compact ? 32.0 : 40.0),
          padding: EdgeInsets.zero,
          style: listening
              ? IconButton.styleFrom(
                  backgroundColor: colors.errorContainer,
                  shape: const CircleBorder(),
                )
              : null,
          icon: Icon(
            listening ? Icons.mic_rounded : Icons.keyboard_voice_outlined,
            color: listening
                ? colors.onErrorContainer
                : (iOS ? colors.outline.withValues(alpha: 0.8) : colors.onSurfaceVariant),
            size: compact ? 18 : 22,
          ),
          onPressed: () async {
            onBeforeToggle?.call();
            await dictation.toggle();
          },
        );
      },
    );
  }
}

/// Streams native speech-to-text (Android SpeechRecognizer / Web Speech API) into a [TextEditingController].
class NativeSpeechDictation {
  NativeSpeechDictation({
    required this.getTextController,
    this.onInteraction,
    this.onListeningChanged,
    this.onError,
    bool? isWeb,
    bool? isAndroid,
    this.commandChannel = const MethodChannel('com.bluebubbles.messaging'),
    this.eventChannel = const MethodChannel('com.bluebubbles.messaging/speech'),
    this.requestMicPermission,
    this.isWebSupported,
    this.startWeb,
    this.stopWeb,
    this.cancelWeb,
  })  : isWeb = isWeb ?? kIsWeb,
        isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  final TextEditingController Function() getTextController;
  final void Function()? onInteraction;
  final void Function(bool listening)? onListeningChanged;
  final void Function(String message)? onError;
  final bool isWeb;
  final bool isAndroid;
  final MethodChannel commandChannel;
  final MethodChannel eventChannel;
  final Future<bool> Function()? requestMicPermission;
  final bool Function()? isWebSupported;
  final bool Function({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
    required void Function() onEnd,
    String? lang,
  })? startWeb;
  final void Function()? stopWeb;
  final void Function()? cancelWeb;

  final ValueNotifier<bool> isListening = ValueNotifier<bool>(false);
  String _prefix = '';
  String _suffix = '';
  bool _disposed = false;

  Future<bool> checkAvailability() async {
    if (isWeb) {
      return (isWebSupported ?? () => web_speech.isWebSpeechSupported)();
    }
    if (isAndroid) {
      try {
        return await commandChannel.invokeMethod<bool>('speech-recognition', {'action': 'isAvailable'}) ?? false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<bool> toggle() async {
    if (isListening.value) {
      await stop();
      return false;
    }
    return start();
  }

  Future<bool> start() async {
    if (_disposed) return false;
    final val = getTextController().value;
    final text = val.text;
    final sel = val.selection;
    final startOffset = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final endOffset = sel.isValid ? sel.end.clamp(startOffset, text.length) : text.length;
    _prefix = text.substring(0, startOffset);
    _suffix = text.substring(endOffset);

    if (isWeb) {
      final started = (startWeb ?? web_speech.startWebSpeech)(
        onResult: (transcript, isFinal) => applyTranscript(transcript, isFinal: isFinal),
        onError: _handleWebError,
        onEnd: _finish,
      );
      if (started) _setListening(true);
      return started;
    }

    if (isAndroid) {
      final granted = await (requestMicPermission ?? _defaultAndroidMicPermission)();
      if (!granted) {
        onError?.call('Microphone access was denied. Please allow microphone permissions.');
        return false;
      }
      eventChannel.setMethodCallHandler(_handleAndroidEvent);
      try {
        final started = await commandChannel.invokeMethod<bool>('speech-recognition', {'action': 'start'}) ?? false;
        if (!started) {
          eventChannel.setMethodCallHandler(null);
          onError?.call('Speech recognition is not available on this device.');
          return false;
        }
        _setListening(true);
        return true;
      } catch (_) {
        eventChannel.setMethodCallHandler(null);
        onError?.call('Failed to start speech recognition.');
        return false;
      }
    }

    return false;
  }

  void applyTranscript(String spoken, {bool isFinal = false}) {
    if (_disposed || !isListening.value) return;
    final trimmed = spoken.trim();
    if (trimmed.isEmpty) return;
    final leadSpace = _prefix.isNotEmpty && !RegExp(r'\s$').hasMatch(_prefix) ? ' ' : '';
    final trailSpace = _suffix.isNotEmpty && !RegExp(r'^\s').hasMatch(_suffix) ? ' ' : '';
    final nextText = '$_prefix$leadSpace$trimmed$trailSpace$_suffix';
    final cursor = _prefix.length + leadSpace.length + trimmed.length;
    getTextController().value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    onInteraction?.call();
  }

  Future<void> stop({bool cancel = false}) async {
    if (!isListening.value) return;
    _setListening(false);
    if (isWeb) {
      (cancel ? (cancelWeb ?? web_speech.cancelWebSpeech) : (stopWeb ?? web_speech.stopWebSpeech))();
    } else if (isAndroid) {
      eventChannel.setMethodCallHandler(null);
      try {
        await commandChannel.invokeMethod('speech-recognition', {'action': cancel ? 'cancel' : 'stop'});
      } catch (_) {}
    }
  }

  void dispose() {
    _disposed = true;
    if (isListening.value) {
      unawaited(stop(cancel: true));
    } else if (isAndroid) {
      eventChannel.setMethodCallHandler(null);
    }
    isListening.dispose();
  }

  Future<bool> _defaultAndroidMicPermission() async {
    try {
      return (await Permission.microphone.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleAndroidEvent(MethodCall call) async {
    if (call.method != 'onSpeechEvent' || _disposed) return;
    final args = (call.arguments as Map?)?.cast<String, dynamic>();
    if (args == null) return;
    final type = args['type'] as String? ?? '';
    final text = args['text'] as String? ?? '';
    switch (type) {
      case 'partial':
        applyTranscript(text, isFinal: false);
        break;
      case 'final':
        applyTranscript(text, isFinal: true);
        break;
      case 'done':
        _finish();
        break;
      case 'error':
        // Android SpeechRecognizer codes 6 (SPEECH_TIMEOUT) and 7 (NO_MATCH) are normal quiet stops.
        if (text == '9') {
          onError?.call('Microphone access was denied. Please allow microphone permissions.');
        } else if (text != '6' && text != '7') {
          onError?.call('Voice typing error (code $text).');
        }
        _finish();
        break;
    }
  }

  void _handleWebError(String code) {
    if (code == 'not-allowed' || code == 'service-not-allowed') {
      onError?.call('Microphone access was denied. Please allow microphone permissions in your browser.');
    } else if (code != 'no-speech' && code != 'aborted') {
      onError?.call('Voice typing error: $code');
    }
    _finish();
  }

  void _finish() {
    if (_disposed) return;
    if (isAndroid) {
      eventChannel.setMethodCallHandler(null);
    }
    _setListening(false);
  }

  void _setListening(bool value) {
    if (_disposed || isListening.value == value) return;
    isListening.value = value;
    onListeningChanged?.call(value);
  }
}

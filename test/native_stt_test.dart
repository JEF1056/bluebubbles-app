import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_component.dart';
import 'package:bluebubbles/helpers/web/web_speech_stub.dart' as web_speech;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const commandChannel = MethodChannel('com.bluebubbles.messaging');
  const eventChannel = MethodChannel('com.bluebubbles.messaging/speech');

  Future<void> dispatchAndroidEvent(String type, [String text = '']) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onSpeechEvent', {'type': type, 'text': text}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      eventChannel.name,
      data,
      (_) {},
    );
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(commandChannel, null);
    eventChannel.setMethodCallHandler(null);
  });

  group('Web speech stub', () {
    test('reports unsupported on non-web targets', () {
      expect(web_speech.isWebSpeechSupported, isFalse);
      expect(
        web_speech.startWebSpeech(onResult: (_, _) {}, onError: (_) {}, onEnd: () {}),
        isFalse,
      );
      web_speech.stopWebSpeech();
      web_speech.cancelWebSpeech();
    });
  });

  group('NativeSpeechDictation (Android)', () {
    test('checks availability, requests mic permission, streams partial+final text, and stops cleanly', () async {
      final actions = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        commandChannel,
        (call) async {
          if (call.method == 'speech-recognition') {
            final action = (call.arguments as Map)['action'] as String;
            actions.add(action);
            if (action == 'isAvailable') return true;
            if (action == 'start') return true;
          }
          return null;
        },
      );

      final textController = TextEditingController(text: 'Hey');
      textController.selection = const TextSelection.collapsed(offset: 3);
      var interactionCalls = 0;
      final listeningStates = <bool>[];

      final dictation = NativeSpeechDictation(
        getTextController: () => textController,
        onInteraction: () => interactionCalls++,
        onListeningChanged: listeningStates.add,
        isWeb: false,
        isAndroid: true,
        requestMicPermission: () async => true,
      );

      expect(await dictation.checkAvailability(), isTrue);
      expect(await dictation.toggle(), isTrue);
      expect(dictation.isListening.value, isTrue);

      await dispatchAndroidEvent('partial', 'there');
      expect(textController.text, 'Hey there');
      expect(textController.selection.baseOffset, 'Hey there'.length);

      await dispatchAndroidEvent('partial', 'there friend');
      expect(textController.text, 'Hey there friend');

      await dispatchAndroidEvent('final', 'there friend!');
      expect(textController.text, 'Hey there friend!');
      expect(interactionCalls, 3);

      await dispatchAndroidEvent('done');
      expect(dictation.isListening.value, isFalse);
      expect(listeningStates, [true, false]);
      expect(actions, ['isAvailable', 'start']);

      dictation.dispose();
      textController.dispose();
    });

    test('denies start when microphone permission is refused', () async {
      final errors = <String>[];
      final textController = TextEditingController();
      final dictation = NativeSpeechDictation(
        getTextController: () => textController,
        onError: errors.add,
        isWeb: false,
        isAndroid: true,
        requestMicPermission: () async => false,
      );

      expect(await dictation.start(), isFalse);
      expect(dictation.isListening.value, isFalse);
      expect(errors, isNotEmpty);

      dictation.dispose();
      textController.dispose();
    });

    test('auto-stops on toggle and cancel on dispose without mutating cleared field', () async {
      final actions = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        commandChannel,
        (call) async {
          if (call.method == 'speech-recognition') {
            final action = (call.arguments as Map)['action'] as String;
            actions.add(action);
            if (action == 'start') return true;
          }
          return null;
        },
      );

      final textController = TextEditingController();
      final dictation = NativeSpeechDictation(
        getTextController: () => textController,
        isWeb: false,
        isAndroid: true,
        requestMicPermission: () async => true,
      );

      expect(await dictation.start(), isTrue);
      await dispatchAndroidEvent('partial', 'hello');
      expect(textController.text, 'hello');

      // Second tap toggles off via stop
      expect(await dictation.toggle(), isFalse);
      expect(dictation.isListening.value, isFalse);
      expect(actions, ['start', 'stop']);

      // Simulate send clearing textController; late speech event must be ignored
      textController.clear();
      await dispatchAndroidEvent('final', 'stale late text');
      expect(textController.text, isEmpty);

      // Start again and dispose -> sends cancel
      expect(await dictation.start(), isTrue);
      dictation.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(actions, ['start', 'stop', 'start', 'cancel']);
      textController.dispose();
    });
  });

  group('NativeSpeechDictation (Web)', () {
    test('streams partial+final transcripts, splices at mid-string cursor, and handles permission error', () async {
      void Function(String text, bool isFinal)? capturedResult;
      void Function(String error)? capturedError;
      void Function()? capturedEnd;
      var stopped = false;

      final textController = TextEditingController(text: 'Hello world');
      textController.selection = const TextSelection.collapsed(offset: 5);
      final errors = <String>[];
      var interactions = 0;

      final sut = NativeSpeechDictation(
        getTextController: () => textController,
        onInteraction: () => interactions++,
        onError: errors.add,
        isWeb: true,
        isAndroid: false,
        isWebSupported: () => true,
        startWeb: ({required onResult, required onError, required onEnd, String? lang}) {
          capturedResult = onResult;
          capturedError = onError;
          capturedEnd = onEnd;
          return true;
        },
        stopWeb: () => stopped = true,
      );

      expect(await sut.checkAvailability(), isTrue);
      expect(await sut.start(), isTrue);
      capturedResult?.call('beautiful', false);
      expect(textController.text, 'Hello beautiful world');
      expect(interactions, 1);

      capturedResult?.call('amazing', true);
      expect(textController.text, 'Hello amazing world');
      expect(interactions, 2);

      await sut.stop();
      expect(stopped, isTrue);
      expect(sut.isListening.value, isFalse);

      // Permission denied error on web
      expect(await sut.start(), isTrue);
      capturedError?.call('not-allowed');
      expect(sut.isListening.value, isFalse);
      expect(errors.single, contains('Microphone access was denied'));

      capturedEnd?.call();
      sut.dispose();
      textController.dispose();
    });
  });
}

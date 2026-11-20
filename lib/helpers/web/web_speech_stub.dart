bool get isWebSpeechSupported => false;

bool startWebSpeech({
  required void Function(String text, bool isFinal) onResult,
  required void Function(String error) onError,
  required void Function() onEnd,
  String? lang,
}) =>
    false;

void stopWebSpeech() {}

void cancelWebSpeech() {}

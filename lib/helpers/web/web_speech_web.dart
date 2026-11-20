import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSObject? _activeRecognition;

JSFunction? _speechCtor() {
  try {
    if (globalContext.has('SpeechRecognition')) {
      return globalContext['SpeechRecognition'] as JSFunction?;
    }
    if (globalContext.has('webkitSpeechRecognition')) {
      return globalContext['webkitSpeechRecognition'] as JSFunction?;
    }
  } catch (_) {}
  return null;
}

bool get isWebSpeechSupported => _speechCtor() != null;

bool startWebSpeech({
  required void Function(String text, bool isFinal) onResult,
  required void Function(String error) onError,
  required void Function() onEnd,
  String? lang,
}) {
  final ctor = _speechCtor();
  if (ctor == null) return false;
  cancelWebSpeech();

  try {
    final rec = ctor.callAsConstructor<JSObject>();
    rec['continuous'] = true.toJS;
    rec['interimResults'] = true.toJS;
    if (lang != null && lang.isNotEmpty) {
      rec['lang'] = lang.toJS;
    }

    rec['onresult'] = ((JSObject event) {
      final results = event['results'] as JSObject?;
      if (results == null) return;
      final len = (results['length'] as JSNumber?)?.toDartInt ?? 0;
      final buf = StringBuffer();
      var allFinal = len > 0;
      for (var i = 0; i < len; i++) {
        final item = results.getProperty<JSObject?>(i.toJS);
        if (item == null) continue;
        final isFinal = (item['isFinal'] as JSBoolean?)?.toDart ?? false;
        if (!isFinal) allFinal = false;
        final alt = item.getProperty<JSObject?>(0.toJS);
        final transcript = (alt?['transcript'] as JSString?)?.toDart ?? '';
        if (transcript.isNotEmpty) {
          if (buf.isNotEmpty && !buf.toString().endsWith(' ') && !transcript.startsWith(' ')) {
            buf.write(' ');
          }
          buf.write(transcript);
        }
      }
      final combined = buf.toString().trim();
      if (combined.isNotEmpty) {
        onResult(combined, allFinal);
      }
    }).toJS;

    rec['onerror'] = ((JSObject event) {
      final err = (event['error'] as JSString?)?.toDart ?? 'unknown';
      onError(err);
    }).toJS;

    rec['onend'] = ((JSAny? _) {
      if (identical(_activeRecognition, rec)) {
        _activeRecognition = null;
      }
      onEnd();
    }).toJS;

    _activeRecognition = rec;
    rec.callMethod('start'.toJS);
    return true;
  } catch (e) {
    _activeRecognition = null;
    onError(e.toString());
    return false;
  }
}

void stopWebSpeech() {
  try {
    _activeRecognition?.callMethod('stop'.toJS);
  } catch (_) {}
}

void cancelWebSpeech() {
  final rec = _activeRecognition;
  _activeRecognition = null;
  if (rec == null) return;
  try {
    rec.callMethod('abort'.toJS);
  } catch (_) {}
}

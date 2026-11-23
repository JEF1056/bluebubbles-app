import 'dart:math' as math;
import 'dart:typed_data';

const int _wavSampleRate = 22050;

ByteData _allocPcmWav(int numSamples) {
  final int dataSize = numSamples * 2;
  final buffer = ByteData(44 + dataSize);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      buffer.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little); // PCM subchunk size
  buffer.setUint16(20, 1, Endian.little); // PCM format
  buffer.setUint16(22, 1, Endian.little); // mono
  buffer.setUint32(24, _wavSampleRate, Endian.little);
  buffer.setUint32(28, _wavSampleRate * 2, Endian.little); // byte rate
  buffer.setUint16(32, 2, Endian.little); // block align
  buffer.setUint16(34, 16, Endian.little); // bits per sample
  writeAscii(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);
  return buffer;
}

/// Synthesizes a 2.8-second 16-bit mono PCM WAV ringtone (two harmonic chimes + trailing silence)
/// so native `loop = true` playback produces a natural call cadence even in throttled background tabs.
Uint8List buildIncomingRingtoneWavBytes() {
  const double totalSeconds = 2.8;
  final int numSamples = (_wavSampleRate * totalSeconds).round();
  final buffer = _allocPcmWav(numSamples);

  double chimeSample(double t, double start, double end, double f1, double f2) {
    if (t < start || t >= end) return 0.0;
    final local = t - start;
    final duration = end - start;
    const attack = 0.015;
    final envAttack = local < attack ? (local / attack) : 1.0;
    final envDecay = math.exp(-4.2 * (local / duration));
    final envTail = (end - t) < 0.03 ? ((end - t) / 0.03) : 1.0;
    final env = envAttack * envDecay * envTail;
    final wave = 0.55 * math.sin(2 * math.pi * f1 * local) +
        0.35 * math.sin(2 * math.pi * f2 * local) +
        0.10 * math.sin(2 * math.pi * (f1 * 2.0) * local);
    return wave * env;
  }

  for (var i = 0; i < numSamples; i++) {
    final t = i / _wavSampleRate;
    final sample = chimeSample(t, 0.0, 0.34, 659.25, 987.77) + // E5 + B5
        chimeSample(t, 0.42, 0.90, 783.99, 1174.66); // G5 + D6
    final clamped = (sample * 0.45).clamp(-1.0, 1.0);
    buffer.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
  }

  return buffer.buffer.asUint8List();
}

/// Synthesizes a 6.0-second 16-bit mono PCM WAV outgoing ringback loop:
/// 250ms lead-in silence + 2.0s 440Hz+480Hz dual sine with 15ms raised-cosine fade + 3.75s silence.
Uint8List buildOutgoingRingbackWavBytes() {
  const double totalSeconds = 6.0;
  const double leadIn = 0.25;
  const double toneDuration = 2.0;
  const double fadeDuration = 0.015;
  final int numSamples = (_wavSampleRate * totalSeconds).round();
  final buffer = _allocPcmWav(numSamples);

  for (var i = 0; i < numSamples; i++) {
    final t = i / _wavSampleRate;
    double sample = 0.0;
    if (t >= leadIn && t < leadIn + toneDuration) {
      final local = t - leadIn;
      double env = 1.0;
      if (local < fadeDuration) {
        env = 0.5 * (1.0 - math.cos(math.pi * local / fadeDuration));
      } else if (toneDuration - local < fadeDuration) {
        env = 0.5 * (1.0 - math.cos(math.pi * (toneDuration - local) / fadeDuration));
      }
      final wave = 0.5 * (math.sin(2 * math.pi * 440.0 * local) + math.sin(2 * math.pi * 480.0 * local));
      sample = wave * env * 0.28;
    }
    final clamped = sample.clamp(-1.0, 1.0);
    buffer.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
  }

  return buffer.buffer.asUint8List();
}

/// Synthesizes a subtle 310ms 16-bit mono PCM WAV call-ended one-shot tone:
/// 480Hz (130ms) -> 360Hz (180ms) with gentle exponential decay.
Uint8List buildCallEndedToneWavBytes() {
  const double firstDuration = 0.13;
  const double secondDuration = 0.18;
  const double totalSeconds = firstDuration + secondDuration;
  final int numSamples = (_wavSampleRate * totalSeconds).round();
  final buffer = _allocPcmWav(numSamples);

  double toneSample(double local, double duration, double freq, double decayRate) {
    const attack = 0.008;
    const tail = 0.020;
    final envAttack = local < attack ? (local / attack) : 1.0;
    final remaining = duration - local;
    final envTail = remaining < tail ? (remaining / tail) : 1.0;
    final envDecay = math.exp(-decayRate * (local / duration));
    return math.sin(2 * math.pi * freq * local) * envAttack * envDecay * envTail;
  }

  for (var i = 0; i < numSamples; i++) {
    final t = i / _wavSampleRate;
    final double sample;
    if (t < firstDuration) {
      sample = toneSample(t, firstDuration, 480.0, 2.5);
    } else {
      sample = toneSample(t - firstDuration, secondDuration, 360.0, 3.5);
    }
    final clamped = (sample * 0.25).clamp(-1.0, 1.0);
    buffer.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
  }

  return buffer.buffer.asUint8List();
}

import 'dart:math' as math;
import 'dart:typed_data';

/// Synthesizes a 2.8-second 16-bit mono PCM WAV ringtone (two harmonic chimes + trailing silence)
/// so native `loop = true` playback produces a natural call cadence even in throttled background tabs.
Uint8List buildIncomingRingtoneWavBytes() {
  const int sampleRate = 22050;
  const double totalSeconds = 2.8;
  final int numSamples = (sampleRate * totalSeconds).round();
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
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  buffer.setUint16(32, 2, Endian.little); // block align
  buffer.setUint16(34, 16, Endian.little); // bits per sample
  writeAscii(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);

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
    final t = i / sampleRate;
    final sample = chimeSample(t, 0.0, 0.34, 659.25, 987.77) + // E5 + B5
        chimeSample(t, 0.42, 0.90, 783.99, 1174.66); // G5 + D6
    final clamped = (sample * 0.45).clamp(-1.0, 1.0);
    buffer.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
  }

  return buffer.buffer.asUint8List();
}

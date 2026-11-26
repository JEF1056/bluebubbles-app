// BlueBubbles Web FaceTime Voice Isolation AudioWorkletProcessor.
// Runs 48kHz RNNoise WASM (/facetime/rnnoise.wasm) on 480-sample (10ms) frames
// with zero-dropout bypass toggling, sample-rate-aware linear resampling,
// VAD-driven soft noise gate with comfort floor, and safe passthrough fallback.

const RNNOISE_FRAME_SIZE = 480;
const PCM_SCALE = 32768.0;
const MIN_GATE_FLOOR = 0.05; // -26dB comfort floor to prevent unnatural dead silence

class BbVoiceIsolationProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const opts = (options && options.processorOptions) || {};
    this._enabled = opts.enabled !== false;
    this._ready = false;
    this._failed = false;

    // Detect sample rate (global in AudioWorkletGlobalScope or from processorOptions)
    this._sampleRate = (opts && typeof opts.sampleRate === 'number' && opts.sampleRate > 0)
      ? opts.sampleRate
      : (typeof sampleRate === 'number' && sampleRate > 0 ? sampleRate : 48000);

    this._exports = null;
    this._memory = null;
    this._state = 0;
    this._framePtr = 0;

    // Resampler state
    this._inStep = this._sampleRate / 48000;
    this._outStep = 48000 / this._sampleRate;
    this._resampleInPos = 0;
    this._resampleOutPos = 0;
    this._lastInSample = 0;
    this._lastOutSample = 0;

    // VAD soft-gate state: smooth envelope to prevent word-tail clipping
    this._vadGain = 1.0;

    // Headroom for 48kHz and resampled 16k-96k streams
    this._inQueue = new Float32Array(RNNOISE_FRAME_SIZE * 8);
    this._inCount = 0;
    this._outQueue = new Float32Array(RNNOISE_FRAME_SIZE * 8);
    this._outCount = 0;

    this.port.onmessage = (event) => {
      const msg = event && event.data;
      if (!msg || typeof msg !== 'object') return;
      if (msg.type === 'dispose' || msg.dispose) {
        this._dispose();
        return;
      }
      if (typeof msg.enabled === 'boolean') {
        if (this._enabled !== msg.enabled) {
          this._enabled = msg.enabled;
          this._inCount = 0;
          this._outCount = 0;
          this._resampleInPos = 0;
          this._resampleOutPos = 0;
          this._lastInSample = 0;
          this._lastOutSample = 0;
          this._vadGain = 1.0;
        }
      }
      if (msg.wasmBinary && !this._ready && !this._failed) {
        this._initWasm(msg.wasmBinary);
      }
    };

    if (opts.wasmBinary) {
      this._initWasm(opts.wasmBinary);
    }
  }

  _dispose() {
    if (this._exports) {
      if (this._state && typeof this._exports.h === 'function') {
        try {
          this._exports.h(this._state);
        } catch (_) {}
      }
      if (this._framePtr && typeof this._exports.i === 'function') {
        try {
          this._exports.i(this._framePtr);
        } catch (_) {}
      }
    }
    this._state = 0;
    this._framePtr = 0;
    this._exports = null;
    this._memory = null;
    this._ready = false;
    this._inCount = 0;
    this._outCount = 0;
    this._resampleInPos = 0;
    this._resampleOutPos = 0;
    this._lastInSample = 0;
    this._lastOutSample = 0;
    this._vadGain = 1.0;
  }

  async _initWasm(wasmBinary) {
    try {
      let memory = null;
      const imports = {
        a: {
          a: (requestedSize) => {
            try {
              if (!memory) return 0;
              const cur = memory.buffer.byteLength;
              if (requestedSize <= cur) return 1;
              const pages = Math.ceil((requestedSize - cur) / 65536);
              memory.grow(pages);
              return 1;
            } catch (_) {
              return 0;
            }
          },
          b: (dest, src, num) => {
            if (!memory) return;
            new Uint8Array(memory.buffer).copyWithin(dest, src, src + num);
          },
        },
      };
      const result = await WebAssembly.instantiate(wasmBinary, imports);
      const instance = result.instance || result;
      const exports = instance.exports;
      memory = exports.c;
      if (typeof exports.d === 'function') {
        exports.d();
      }
      const state = exports.f(0);
      const framePtr = exports.g(RNNOISE_FRAME_SIZE * 4);
      if (!state || !framePtr) {
        throw new Error('Failed to allocate RNNoise WASM state');
      }
      this._exports = exports;
      this._memory = memory;
      this._state = state;
      this._framePtr = framePtr;
      this._ready = true;
      this.port.postMessage({ type: 'ready', rnnoise: true });
    } catch (err) {
      this._failed = true;
      this.port.postMessage({
        type: 'fallback',
        reason: err ? String(err) : 'rnnoise-init-failed',
      });
    }
  }

  _processRnnoiseFrame(offset) {
    const f32 = new Float32Array(this._memory.buffer, this._framePtr, RNNOISE_FRAME_SIZE);
    for (let i = 0; i < RNNOISE_FRAME_SIZE; i++) {
      f32[i] = this._inQueue[offset + i] * PCM_SCALE;
    }

    // RNNoise returns VAD speech probability in [0.0, 1.0]
    const vadProb = this._exports.j(this._state, this._framePtr, this._framePtr);

    // VAD soft-gate with comfort noise floor:
    // Scale speech probability with a 0.05 (-26dB) floor to avoid harsh dead silence.
    // Speech range [0.1, 0.5] provides smooth hangover, preserving word endings and breathing.
    const vadTarget = (typeof vadProb === 'number' && !isNaN(vadProb))
      ? MIN_GATE_FLOOR + (1.0 - MIN_GATE_FLOOR) * Math.min(1.0, Math.max(0.0, (vadProb - 0.1) / 0.4))
      : 1.0;

    // Fast attack (0.35) for instant speech onset, gentle release (0.08) to preserve word tails
    const prevGain = this._vadGain;
    if (vadTarget > this._vadGain) {
      this._vadGain += (vadTarget - this._vadGain) * 0.35;
    } else {
      this._vadGain += (vadTarget - this._vadGain) * 0.08;
    }

    const gainStep = (this._vadGain - prevGain) / RNNOISE_FRAME_SIZE;
    let currentGain = prevGain;

    const outView = new Float32Array(this._memory.buffer, this._framePtr, RNNOISE_FRAME_SIZE);
    for (let i = 0; i < RNNOISE_FRAME_SIZE; i++) {
      currentGain += gainStep;
      this._outQueue[this._outCount + i] = (outView[i] / PCM_SCALE) * currentGain;
    }
    this._outCount += RNNOISE_FRAME_SIZE;
  }

  process(inputs, outputs) {
    const input = inputs[0] && inputs[0][0];
    const output = outputs[0] && outputs[0][0];
    if (!output) return true;
    if (!input || input.length === 0) {
      output.fill(0);
      return true;
    }

    if (!this._enabled || !this._ready) {
      output.set(input);
      return true;
    }

    const n = input.length;

    if (this._sampleRate === 48000) {
      // Direct 48kHz fast path (0 resampler overhead)
      if (this._inCount + n > this._inQueue.length) {
        this._inCount = 0;
      }
      this._inQueue.set(input, this._inCount);
      this._inCount += n;

      let readOffset = 0;
      while (this._inCount - readOffset >= RNNOISE_FRAME_SIZE) {
        if (this._outCount + RNNOISE_FRAME_SIZE <= this._outQueue.length) {
          this._processRnnoiseFrame(readOffset);
        }
        readOffset += RNNOISE_FRAME_SIZE;
      }
      if (readOffset > 0) {
        const remaining = this._inCount - readOffset;
        if (remaining > 0) {
          this._inQueue.copyWithin(0, readOffset, this._inCount);
        }
        this._inCount = remaining;
      }

      if (this._outCount >= n) {
        output.set(this._outQueue.subarray(0, n));
        const rem = this._outCount - n;
        if (rem > 0) {
          this._outQueue.copyWithin(0, n, this._outCount);
        }
        this._outCount = rem;
      } else {
        // Initial 10ms frame accumulation: pass through cleanly without silence gap.
        output.set(input);
      }
    } else {
      // Resample input from this._sampleRate to 48kHz
      if (this._inCount + RNNOISE_FRAME_SIZE * 2 > this._inQueue.length) {
        this._inCount = 0;
      }
      while (this._resampleInPos + this._inStep <= n) {
        this._resampleInPos += this._inStep;
        const i0 = Math.floor(this._resampleInPos);
        const frac = this._resampleInPos - i0;
        const s0 = i0 === 0 ? this._lastInSample : input[i0 - 1];
        const s1 = i0 < n ? input[i0] : input[n - 1];
        const s = s0 + (s1 - s0) * frac;
        if (this._inCount < this._inQueue.length) {
          this._inQueue[this._inCount++] = s;
        }
      }
      this._resampleInPos -= n;
      this._lastInSample = input[n - 1];

      // Process 480-sample 48kHz RNNoise frames
      let readOffset = 0;
      while (this._inCount - readOffset >= RNNOISE_FRAME_SIZE) {
        if (this._outCount + RNNOISE_FRAME_SIZE <= this._outQueue.length) {
          this._processRnnoiseFrame(readOffset);
        }
        readOffset += RNNOISE_FRAME_SIZE;
      }
      if (readOffset > 0) {
        const remaining = this._inCount - readOffset;
        if (remaining > 0) {
          this._inQueue.copyWithin(0, readOffset, this._inCount);
        }
        this._inCount = remaining;
      }

      // Resample output from 48kHz to this._sampleRate
      const neededOut48 = Math.ceil(this._resampleOutPos + n * this._outStep) + 2;
      if (this._outCount >= neededOut48) {
        let produced = 0;
        while (produced < n && this._resampleOutPos + this._outStep <= this._outCount) {
          this._resampleOutPos += this._outStep;
          const i0 = Math.floor(this._resampleOutPos);
          const frac = this._resampleOutPos - i0;
          const s0 = i0 === 0 ? this._lastOutSample : this._outQueue[i0 - 1];
          const s1 = i0 < this._outCount ? this._outQueue[i0] : this._outQueue[this._outCount - 1];
          output[produced++] = s0 + (s1 - s0) * frac;
        }
        const consumed = Math.floor(this._resampleOutPos);
        if (consumed > 0) {
          this._lastOutSample = this._outQueue[consumed - 1];
          const rem = this._outCount - consumed;
          if (rem > 0) {
            this._outQueue.copyWithin(0, consumed, this._outCount);
          }
          this._outCount = rem;
          this._resampleOutPos -= consumed;
        }
        while (produced < n) {
          output[produced] = output[produced - 1] || 0;
          produced++;
        }
      } else {
        // Initial accumulation: pass through cleanly without silence gap
        output.set(input);
      }
    }

    return true;
  }
}

registerProcessor('bb-voice-isolation', BbVoiceIsolationProcessor);

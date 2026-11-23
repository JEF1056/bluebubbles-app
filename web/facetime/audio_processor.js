// BlueBubbles Web FaceTime Voice Isolation AudioWorkletProcessor.
// Runs 48kHz RNNoise WASM (/facetime/rnnoise.wasm) on 480-sample (10ms) frames
// with zero-dropout bypass toggling and safe passthrough fallback before init.

const RNNOISE_FRAME_SIZE = 480;
const PCM_SCALE = 32768.0;

class BbVoiceIsolationProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const opts = (options && options.processorOptions) || {};
    this._enabled = opts.enabled !== false;
    this._ready = false;
    this._failed = false;

    this._exports = null;
    this._memory = null;
    this._state = 0;
    this._framePtr = 0;

    this._inQueue = new Float32Array(RNNOISE_FRAME_SIZE * 3);
    this._inCount = 0;
    this._outQueue = new Float32Array(RNNOISE_FRAME_SIZE * 3);
    this._outCount = 0;

    this.port.onmessage = (event) => {
      const msg = event && event.data;
      if (!msg || typeof msg !== 'object') return;
      if (typeof msg.enabled === 'boolean') {
        if (this._enabled !== msg.enabled) {
          this._enabled = msg.enabled;
          this._inCount = 0;
          this._outCount = 0;
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
    this._exports.j(this._state, this._framePtr, this._framePtr);
    const outView = new Float32Array(this._memory.buffer, this._framePtr, RNNOISE_FRAME_SIZE);
    for (let i = 0; i < RNNOISE_FRAME_SIZE; i++) {
      this._outQueue[this._outCount + i] = outView[i] / PCM_SCALE;
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

    return true;
  }
}

registerProcessor('bb-voice-isolation', BbVoiceIsolationProcessor);

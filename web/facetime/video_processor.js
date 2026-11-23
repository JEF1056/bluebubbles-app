// BlueBubbles Web FaceTime Video Processor
// Self-hosted MediaPipe Vision bundle + WASM + TFLite model under web/facetime/
// with graceful fallback to CDN.
// WebGL2 pipeline:
// - Temporal denoise (motion-adaptive history blend)
// - Spatial denoise (3x3 bilateral filter)
// - Background-only Kawase blur (halo-free background extraction)
// - Joint bilateral mask edge refinement
// - Driven via requestVideoFrameCallback where supported.

(function () {
  if (window.bbFaceTimeVideoProcessor) return;

  const LOCAL_BUNDLE = 'facetime/vision_bundle.mjs';
  const LOCAL_WASM_ROOT = 'facetime/wasm';
  const LOCAL_MODEL_URL = 'facetime/selfie_segmenter_landscape.tflite';

  const CDN_BUNDLE =
    'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.18/vision_bundle.mjs';
  const CDN_WASM_ROOT =
    'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.18/wasm';
  const CDN_MODEL_URL =
    'https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter_landscape/float16/latest/selfie_segmenter_landscape.tflite';

  let segmenterPromise = null;

  async function createSegmenterInstance() {
    let vision = null;
    let fileset = null;
    let modelPath = LOCAL_MODEL_URL;

    // Try local self-hosted MediaPipe assets first
    try {
      vision = await import(/* webpackIgnore: true */ LOCAL_BUNDLE);
      fileset = await vision.FilesetResolver.forVisionTasks(LOCAL_WASM_ROOT);
      const probe = await fetch(LOCAL_MODEL_URL, { method: 'HEAD' });
      if (!probe.ok) modelPath = CDN_MODEL_URL;
    } catch (localErr) {
      console.warn('Local MediaPipe assets failed, falling back to CDN', localErr);
      try {
        vision = await import(/* webpackIgnore: true */ CDN_BUNDLE);
        fileset = await vision.FilesetResolver.forVisionTasks(CDN_WASM_ROOT);
        modelPath = CDN_MODEL_URL;
      } catch (cdnErr) {
        throw new Error(`Failed to load MediaPipe from local or CDN: ${cdnErr}`);
      }
    }

    try {
      return await vision.ImageSegmenter.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: modelPath, delegate: 'GPU' },
        runningMode: 'VIDEO',
        outputCategoryMask: false,
        outputConfidenceMasks: true,
      });
    } catch (_) {
      return await vision.ImageSegmenter.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: modelPath, delegate: 'CPU' },
        runningMode: 'VIDEO',
        outputCategoryMask: false,
        outputConfidenceMasks: true,
      });
    }
  }

  async function getSegmenter() {
    if (!segmenterPromise) {
      segmenterPromise = createSegmenterInstance().catch((err) => {
        segmenterPromise = null;
        throw err;
      });
    }
    return segmenterPromise;
  }

  function presetPalette(id) {
    switch (id) {
      case 'studio_warm':
        return ['#2b211b', '#523828', '#1b1715'];
      case 'gradient_dusk':
        return ['#1a2538', '#334d72', '#171923'];
      case 'slate_minimal':
        return ['#20242a', '#2f3640', '#14171c'];
      case 'ocean_calm':
        return ['#122b36', '#1e4e5f', '#0d1d24'];
      default:
        return ['#1b2330', '#2b394e', '#13161b'];
    }
  }

  function renderPresetCanvas(presetId, width, height) {
    const c = document.createElement('canvas');
    c.width = Math.max(2, width);
    c.height = Math.max(2, height);
    const ctx = c.getContext('2d');
    if (ctx) {
      const [c0, c1, c2] = presetPalette(presetId);
      const grad = ctx.createLinearGradient(0, 0, c.width, c.height);
      grad.addColorStop(0, c0);
      grad.addColorStop(0.55, c1);
      grad.addColorStop(1, c2);
      ctx.fillStyle = grad;
      ctx.fillRect(0, 0, c.width, c.height);
    }
    return c;
  }

  function createWebGL2Renderer(canvas) {
    const gl = canvas.getContext('webgl2', {
      alpha: false,
      antialias: false,
      depth: false,
      stencil: false,
      desynchronized: true,
      powerPreference: 'high-performance',
    });
    if (!gl) return null;

    const VS = `#version 300 es
      in vec2 aPos;
      out vec2 vUv;
      void main() {
        vUv = aPos * 0.5 + 0.5;
        gl_Position = vec4(aPos, 0.0, 1.0);
      }`;

    // Pass 1: Temporal Denoise (motion-adaptive history blend)
    const FS_TEMPORAL = `#version 300 es
      precision mediump float;
      uniform sampler2D uTexCurrent;
      uniform sampler2D uTexHistory;
      uniform float uHasHistory;
      uniform float uDenoise;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
        vec3 cur = texture(uTexCurrent, uv).rgb;
        if (uDenoise < 0.5 || uHasHistory < 0.5) {
          outColor = vec4(cur, 1.0);
          return;
        }
        vec3 prev = texture(uTexHistory, vUv).rgb;
        float diff = length(cur - prev);
        // Motion-adaptive blend: static areas get up to 0.70 history weight,
        // while rapid motion reduces history weight towards 0 to avoid ghosting.
        float alpha = clamp(0.70 - diff * 4.0, 0.0, 0.70);
        outColor = vec4(mix(cur, prev, alpha), 1.0);
      }`;

    // Pass 2: Spatial Denoise (3x3 bilateral edge-preserving filter)
    const FS_SPATIAL_DENOISE = `#version 300 es
      precision mediump float;
      uniform sampler2D uTex;
      uniform vec2 uTexel;
      uniform float uDenoise;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec3 center = texture(uTex, vUv).rgb;
        if (uDenoise < 0.5) {
          outColor = vec4(center, 1.0);
          return;
        }
        vec3 sum = center;
        float wSum = 1.0;
        for (int dx = -1; dx <= 1; dx++) {
          for (int dy = -1; dy <= 1; dy++) {
            if (dx == 0 && dy == 0) continue;
            vec3 s = texture(uTex, vUv + vec2(float(dx), float(dy)) * uTexel).rgb;
            vec3 d = s - center;
            float w = exp(-dot(d, d) * 36.0) * 0.65;
            sum += s * w;
            wSum += w;
          }
        }
        outColor = vec4(sum / wSum, 1.0);
      }`;

    // Pass 3a: Background extraction for blur (prevents foreground color bleed / halos)
    const FS_BG_EXTRACT = `#version 300 es
      precision mediump float;
      uniform sampler2D uFg;
      uniform sampler2D uMask;
      uniform vec2 uTexel;
      uniform float uHasMask;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec4 fg = texture(uFg, vUv);
        if (uHasMask < 0.5) {
          outColor = fg;
          return;
        }
        vec2 maskUv = vec2(vUv.x, 1.0 - vUv.y);
        float m = texture(uMask, maskUv).r;
        if (m < 0.35) {
          outColor = fg;
          return;
        }
        // Sample outward away from the person to find actual background color
        vec2 bestUv = vUv;
        float minM = m;
        for (float r = 1.0; r <= 3.0; r += 1.0) {
          vec2 o = uTexel * (r * 6.0);
          vec2 offsets[8] = vec2[](
            vec2( o.x,  0.0), vec2(-o.x,  0.0),
            vec2( 0.0,  o.y), vec2( 0.0, -o.y),
            vec2( o.x,  o.y), vec2(-o.x,  o.y),
            vec2( o.x, -o.y), vec2(-o.x, -o.y)
          );
          for (int i = 0; i < 8; i++) {
            vec2 candUv = clamp(vUv + offsets[i], 0.0, 1.0);
            float cm = texture(uMask, vec2(candUv.x, 1.0 - candUv.y)).r;
            if (cm < minM) {
              minM = cm;
              bestUv = candUv;
              if (minM < 0.2) break;
            }
          }
          if (minM < 0.2) break;
        }
        outColor = texture(uFg, bestUv);
      }`;

    // Pass 3b: Kawase blur
    const FS_KAWASE = `#version 300 es
      precision mediump float;
      uniform sampler2D uTex;
      uniform vec2 uOffset;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec4 c = texture(uTex, vUv + vec2(-uOffset.x, -uOffset.y))
               + texture(uTex, vUv + vec2( uOffset.x, -uOffset.y))
               + texture(uTex, vUv + vec2(-uOffset.x,  uOffset.y))
               + texture(uTex, vUv + vec2( uOffset.x,  uOffset.y));
        outColor = c * 0.25;
      }`;

    // Pass 4: Final composite with Joint Bilateral Mask Edge Refinement
    const FS_COMPOSITE = `#version 300 es
      precision mediump float;
      uniform sampler2D uFg;
      uniform sampler2D uBg;
      uniform sampler2D uMask;
      uniform int uMode; // 0=none, 1=blur, 2=virtualBg
      uniform float uHasMask;
      uniform vec2 uTexel;
      uniform vec2 uMaskTexel;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec4 fg = texture(uFg, vUv);
        if (uMode == 0) {
          outColor = fg;
          return;
        }
        vec4 bg = texture(uBg, vUv);
        if (uHasMask < 0.5) {
          outColor = (uMode == 1) ? mix(fg, bg, 0.4) : fg;
          return;
        }
        vec2 maskUv = vec2(vUv.x, 1.0 - vUv.y);
        float mCenter = texture(uMask, maskUv).r;

        float alpha;
        if (mCenter < 0.08) {
          alpha = 0.0;
        } else if (mCenter > 0.92) {
          alpha = 1.0;
        } else {
          // Joint bilateral mask refinement using high-resolution color guide
          vec3 guideColor = fg.rgb;
          float wSum = 1.0;
          float mSum = mCenter;
          for (int dx = -1; dx <= 1; dx++) {
            for (int dy = -1; dy <= 1; dy++) {
              if (dx == 0 && dy == 0) continue;
              vec2 offsetUv = clamp(vUv + vec2(float(dx), float(-dy)) * uTexel * 2.0, 0.0, 1.0);
              vec2 offsetMaskUv = clamp(maskUv + vec2(float(dx), float(dy)) * uMaskTexel, 0.0, 1.0);
              vec3 sColor = texture(uFg, offsetUv).rgb;
              float sMask = texture(uMask, offsetMaskUv).r;
              float colorDist = distance(guideColor, sColor);
              float w = exp(-colorDist * 16.0);
              mSum += sMask * w;
              wSum += w;
            }
          }
          float refinedM = mSum / wSum;
          alpha = smoothstep(0.28, 0.72, refinedM);
        }

        outColor = vec4(mix(bg.rgb, fg.rgb, alpha), 1.0);
      }`;

    function compile(type, src) {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        throw new Error(gl.getShaderInfoLog(s) || 'Shader compile error');
      }
      return s;
    }

    function link(fsSrc) {
      const p = gl.createProgram();
      const vs = compile(gl.VERTEX_SHADER, VS);
      const fs = compile(gl.FRAGMENT_SHADER, fsSrc);
      gl.attachShader(p, vs);
      gl.attachShader(p, fs);
      gl.linkProgram(p);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
        throw new Error(gl.getProgramInfoLog(p) || 'Program link error');
      }
      return p;
    }

    const progTemporal = link(FS_TEMPORAL);
    const progSpatial = link(FS_SPATIAL_DENOISE);
    const progBgExtract = link(FS_BG_EXTRACT);
    const progKawase = link(FS_KAWASE);
    const progComposite = link(FS_COMPOSITE);

    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

    function bindQuad(prog) {
      const loc = gl.getAttribLocation(prog, 'aPos');
      gl.bindBuffer(gl.ARRAY_BUFFER, quad);
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    }

    function makeTex(filter = gl.LINEAR) {
      const t = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
      return t;
    }

    const texVideo = makeTex();
    const texTemporal = makeTex();
    const texFg = makeTex();
    const texHistory = makeTex();
    const texBlurA = makeTex();
    const texBlurB = makeTex();
    const texVirtualBg = makeTex();
    const texMask = makeTex();

    const fboTemporal = gl.createFramebuffer();
    const fboFg = gl.createFramebuffer();
    const fboBlurA = gl.createFramebuffer();
    const fboBlurB = gl.createFramebuffer();

    let allocW = 0;
    let allocH = 0;
    let maskW = 0;
    let maskH = 0;
    let hasHistory = false;

    function ensureTargets(w, h) {
      if (allocW === w && allocH === h) return;
      allocW = w;
      allocH = h;
      hasHistory = false;
      const bw = Math.max(64, Math.floor(w / 4));
      const bh = Math.max(64, Math.floor(h / 4));

      // Temporal FBO
      gl.bindTexture(gl.TEXTURE_2D, texTemporal);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboTemporal);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texTemporal, 0);

      // Foreground FBO
      gl.bindTexture(gl.TEXTURE_2D, texFg);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboFg);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texFg, 0);

      // History texture
      gl.bindTexture(gl.TEXTURE_2D, texHistory);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);

      // Blur FBOs
      for (const [t, f] of [
        [texBlurA, fboBlurA],
        [texBlurB, fboBlurB],
      ]) {
        gl.bindTexture(gl.TEXTURE_2D, t);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, bw, bh, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.bindFramebuffer(gl.FRAMEBUFFER, f);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }

    function uploadMask(maskBytes, w, h) {
      gl.bindTexture(gl.TEXTURE_2D, texMask);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      if (maskW !== w || maskH !== h) {
        maskW = w;
        maskH = h;
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, w, h, 0, gl.RED, gl.UNSIGNED_BYTE, maskBytes);
      } else {
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RED, gl.UNSIGNED_BYTE, maskBytes);
      }
    }

    function uploadBgSource(sourceCanvasOrImg) {
      gl.bindTexture(gl.TEXTURE_2D, texVirtualBg);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, sourceCanvasOrImg);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    }

    function render(video, w, h, opts, hasMask) {
      ensureTargets(w, h);

      gl.bindTexture(gl.TEXTURE_2D, texVideo);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);

      // Pass 1: Temporal Denoise -> fboTemporal
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboTemporal);
      gl.viewport(0, 0, w, h);
      gl.useProgram(progTemporal);
      bindQuad(progTemporal);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texVideo);
      gl.uniform1i(gl.getUniformLocation(progTemporal, 'uTexCurrent'), 0);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, texHistory);
      gl.uniform1i(gl.getUniformLocation(progTemporal, 'uTexHistory'), 1);
      gl.uniform1f(gl.getUniformLocation(progTemporal, 'uHasHistory'), hasHistory ? 1.0 : 0.0);
      gl.uniform1f(gl.getUniformLocation(progTemporal, 'uDenoise'), opts.denoise ? 1.0 : 0.0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

      // Pass 2: Spatial Denoise -> fboFg
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboFg);
      gl.viewport(0, 0, w, h);
      gl.useProgram(progSpatial);
      bindQuad(progSpatial);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texTemporal);
      gl.uniform1i(gl.getUniformLocation(progSpatial, 'uTex'), 0);
      gl.uniform2f(gl.getUniformLocation(progSpatial, 'uTexel'), 1.0 / w, 1.0 / h);
      gl.uniform1f(gl.getUniformLocation(progSpatial, 'uDenoise'), opts.denoise ? 1.0 : 0.0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

      // Update history texture from denoised foreground
      gl.bindTexture(gl.TEXTURE_2D, texHistory);
      gl.copyTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 0, 0, w, h);
      hasHistory = !!opts.denoise;

      const isBlur = opts.effect === 'blurLight' || opts.effect === 'blurStrong';
      const isVirtualBg = opts.effect === 'virtualBackground';

      if (isBlur) {
        const bw = Math.max(64, Math.floor(w / 4));
        const bh = Math.max(64, Math.floor(h / 4));
        const baseRadius = opts.effect === 'blurStrong' ? 4.0 : 2.0;

        // Background extraction pass: extract halo-free background into fboBlurA
        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurA);
        gl.viewport(0, 0, bw, bh);
        gl.useProgram(progBgExtract);
        bindQuad(progBgExtract);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texFg);
        gl.uniform1i(gl.getUniformLocation(progBgExtract, 'uFg'), 0);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, texMask);
        gl.uniform1i(gl.getUniformLocation(progBgExtract, 'uMask'), 1);
        gl.uniform2f(gl.getUniformLocation(progBgExtract, 'uTexel'), 1.0 / w, 1.0 / h);
        gl.uniform1f(gl.getUniformLocation(progBgExtract, 'uHasMask'), hasMask ? 1.0 : 0.0);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        // 3-pass Kawase blur
        gl.useProgram(progKawase);
        bindQuad(progKawase);

        // Level 1: fboBlurA -> fboBlurB
        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurB);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texBlurA);
        gl.uniform1i(gl.getUniformLocation(progKawase, 'uTex'), 0);
        gl.uniform2f(gl.getUniformLocation(progKawase, 'uOffset'), baseRadius / bw, baseRadius / bh);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        // Level 2: fboBlurB -> fboBlurA
        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurA);
        gl.bindTexture(gl.TEXTURE_2D, texBlurB);
        gl.uniform2f(gl.getUniformLocation(progKawase, 'uOffset'), (baseRadius * 1.8) / bw, (baseRadius * 1.8) / bh);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        // Level 3: fboBlurA -> fboBlurB
        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurB);
        gl.bindTexture(gl.TEXTURE_2D, texBlurA);
        gl.uniform2f(gl.getUniformLocation(progKawase, 'uOffset'), (baseRadius * 2.8) / bw, (baseRadius * 2.8) / bh);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      }

      // Final composite with joint bilateral mask edge refinement -> canvas
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, w, h);
      gl.useProgram(progComposite);
      bindQuad(progComposite);

      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texFg);
      gl.uniform1i(gl.getUniformLocation(progComposite, 'uFg'), 0);

      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, isVirtualBg ? texVirtualBg : texBlurB);
      gl.uniform1i(gl.getUniformLocation(progComposite, 'uBg'), 1);

      gl.activeTexture(gl.TEXTURE2);
      gl.bindTexture(gl.TEXTURE_2D, texMask);
      gl.uniform1i(gl.getUniformLocation(progComposite, 'uMask'), 2);

      gl.uniform1i(gl.getUniformLocation(progComposite, 'uMode'), isBlur ? 1 : isVirtualBg ? 2 : 0);
      gl.uniform1f(gl.getUniformLocation(progComposite, 'uHasMask'), hasMask ? 1.0 : 0.0);
      gl.uniform2f(gl.getUniformLocation(progComposite, 'uTexel'), 1.0 / w, 1.0 / h);
      gl.uniform2f(gl.getUniformLocation(progComposite, 'uMaskTexel'), 1.0 / (maskW || 256), 1.0 / (maskH || 144));
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    function dispose() {
      [texVideo, texTemporal, texFg, texHistory, texBlurA, texBlurB, texVirtualBg, texMask].forEach((t) =>
        gl.deleteTexture(t)
      );
      [fboTemporal, fboFg, fboBlurA, fboBlurB].forEach((f) => gl.deleteFramebuffer(f));
      [progTemporal, progSpatial, progBgExtract, progKawase, progComposite].forEach((p) => gl.deleteProgram(p));
      gl.deleteBuffer(quad);
    }

    return { render, uploadMask, uploadBgSource, dispose };
  }

  function createSession(rawTrack, initialOptions) {
    const opts = Object.assign(
      {
        effect: 'none',
        denoise: false,
        backgroundId: null,
        backgroundPath: null,
        targetFps: 30,
      },
      initialOptions || {}
    );

    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.autoplay = true;
    video.srcObject = new MediaStream([rawTrack]);

    const canvas = document.createElement('canvas');
    const settings = (rawTrack.getSettings && rawTrack.getSettings()) || {};
    canvas.width = settings.width || 1280;
    canvas.height = settings.height || 720;

    const webgl = createWebGL2Renderer(canvas);
    const ctx2d = webgl ? null : canvas.getContext('2d');

    let disposed = false;
    let segmenter = null;
    let loadingSegmenter = false;
    let maskBytes = null;
    let maskW = 0;
    let maskH = 0;
    let hasMask = false;
    let bgSignature = '';
    let bgCanvas = null;
    let frameCallbackId = null;
    let fallbackTimerId = null;
    let lastSegmentAt = 0;
    let lastFrameTime = performance.now();

    function refreshBackground() {
      if (opts.effect !== 'virtualBackground') return;
      const sig = `${opts.backgroundId || ''}|${opts.backgroundPath || ''}|${canvas.width}x${canvas.height}`;
      if (sig === bgSignature) return;
      bgSignature = sig;

      if (opts.backgroundPath) {
        const img = new Image();
        img.crossOrigin = 'anonymous';
        img.onload = () => {
          if (disposed) return;
          const off = document.createElement('canvas');
          off.width = canvas.width;
          off.height = canvas.height;
          const c = off.getContext('2d');
          if (c) {
            const scale = Math.max(off.width / img.width, off.height / img.height);
            const dw = img.width * scale;
            const dh = img.height * scale;
            c.drawImage(img, (off.width - dw) / 2, (off.height - dh) / 2, dw, dh);
          }
          bgCanvas = off;
          if (webgl) webgl.uploadBgSource(off);
        };
        img.onerror = () => {
          if (disposed) return;
          bgCanvas = renderPresetCanvas(opts.backgroundId, canvas.width, canvas.height);
          if (webgl) webgl.uploadBgSource(bgCanvas);
        };
        img.src = opts.backgroundPath;
      } else {
        bgCanvas = renderPresetCanvas(opts.backgroundId, canvas.width, canvas.height);
        if (webgl) webgl.uploadBgSource(bgCanvas);
      }
    }

    function ensureSegmenter() {
      if (opts.effect === 'none' || segmenter || loadingSegmenter || disposed) return;
      loadingSegmenter = true;
      getSegmenter()
        .then((seg) => {
          if (!disposed) segmenter = seg;
        })
        .catch(() => {})
        .finally(() => {
          loadingSegmenter = false;
        });
    }

    function processFrame(nowMs) {
      if (disposed || video.readyState < 2 || video.videoWidth <= 0 || video.videoHeight <= 0) return;
      lastFrameTime = nowMs;

      if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        bgSignature = '';
      }

      refreshBackground();
      if (opts.effect !== 'none') {
        ensureSegmenter();
      }

      if (opts.effect !== 'none' && segmenter && nowMs - lastSegmentAt >= 33) {
        lastSegmentAt = nowMs;
        try {
          const res = segmenter.segmentForVideo(video, nowMs);
          const conf = res && res.confidenceMasks && res.confidenceMasks[0];
          if (conf) {
            const floatMask = conf.getAsFloat32Array();
            const mw = conf.width;
            const mh = conf.height;
            if (!maskBytes || maskBytes.length !== mw * mh) {
              maskBytes = new Uint8Array(mw * mh);
            }
            // EMA temporal smoothing prevents mask flicker on hair/edges
            for (let i = 0; i < floatMask.length; i++) {
              const target = Math.max(0, Math.min(255, Math.round(floatMask[i] * 255)));
              maskBytes[i] = hasMask ? Math.round(maskBytes[i] * 0.30 + target * 0.70) : target;
            }
            maskW = mw;
            maskH = mh;
            hasMask = true;
            if (webgl) webgl.uploadMask(maskBytes, maskW, maskH);
            conf.close();
          }
          if (res && typeof res.close === 'function') res.close();
        } catch (_) {}
      }

      if (webgl) {
        webgl.render(video, canvas.width, canvas.height, opts, hasMask);
      } else if (ctx2d) {
        ctx2d.save();
        if (opts.effect === 'blurLight' || opts.effect === 'blurStrong') {
          ctx2d.filter = opts.effect === 'blurStrong' ? 'blur(12px)' : 'blur(5px)';
        } else {
          ctx2d.filter = 'none';
        }
        ctx2d.drawImage(video, 0, 0, canvas.width, canvas.height);
        ctx2d.restore();
      }
    }

    function scheduleNext() {
      if (disposed) return;
      if (typeof video.requestVideoFrameCallback === 'function') {
        frameCallbackId = video.requestVideoFrameCallback((now) => {
          processFrame(now);
          scheduleNext();
        });
      }
    }

    const fps = Math.max(15, Math.min(30, opts.targetFps || 30));
    const outputStream = canvas.captureStream(fps);
    const outputTrack = outputStream.getVideoTracks()[0];

    video.play().catch(() => {});
    refreshBackground();
    if (opts.effect !== 'none') ensureSegmenter();

    const hasRvfc = typeof video.requestVideoFrameCallback === 'function';
    if (hasRvfc) {
      scheduleNext();
    }
    fallbackTimerId = setInterval(() => {
      const now = performance.now();
      if (!hasRvfc || document.hidden || now - lastFrameTime > 200) {
        processFrame(now);
      }
    }, Math.round(1000 / fps));

    return {
      track: outputTrack,
      updateOptions(next) {
        if (disposed || !next) return;
        Object.assign(opts, next);
        if (opts.effect === 'none') {
          hasMask = false;
        } else {
          ensureSegmenter();
          refreshBackground();
        }
      },
      dispose() {
        if (disposed) return;
        disposed = true;
        if (frameCallbackId !== null && typeof video.cancelVideoFrameCallback === 'function') {
          try {
            video.cancelVideoFrameCallback(frameCallbackId);
          } catch (_) {}
          frameCallbackId = null;
        }
        if (fallbackTimerId !== null) {
          clearInterval(fallbackTimerId);
          fallbackTimerId = null;
        }
        video.srcObject = null;
        if (outputTrack) {
          try {
            outputTrack.stop();
          } catch (_) {}
        }
        if (webgl) webgl.dispose();
      },
    };
  }

  window.bbFaceTimeVideoProcessor = { createSession };
})();

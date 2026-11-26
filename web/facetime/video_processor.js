// BlueBubbles Web FaceTime Video Processor
// Self-hosted MediaPipe Vision bundle + WASM + TFLite model under web/facetime/
// with graceful fallback to CDN.
// WebGL2 pipeline:
// - Temporal denoise (motion-adaptive history blend)
// - Spatial denoise (3x3 bilateral edge-preserving filter)
// - Background-only Dual-Kawase pyramid blur (halo-free background extraction)
// - Joint bilateral mask edge refinement + Auto-Exposure/Shadow-Lift + AMD FidelityFX CAS
// - Driven via WebCodecs MediaStreamTrackProcessor/Generator with rVFC fallback + thermal governor.

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

    // Pass 3b: Dual-Kawase Downsample (5-tap center + 4 half-pixel diagonal corners)
    const FS_KAWASE_DOWN = `#version 300 es
      precision mediump float;
      uniform sampler2D uTex;
      uniform vec2 uHalfPixel;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec4 sum = texture(uTex, vUv) * 4.0;
        sum += texture(uTex, vUv - uHalfPixel);
        sum += texture(uTex, vUv + uHalfPixel);
        sum += texture(uTex, vUv + vec2(uHalfPixel.x, -uHalfPixel.y));
        sum += texture(uTex, vUv - vec2(uHalfPixel.x, -uHalfPixel.y));
        outColor = sum * 0.125;
      }`;

    // Pass 3c: Dual-Kawase Upsample (8-tap tent filter)
    const FS_KAWASE_UP = `#version 300 es
      precision mediump float;
      uniform sampler2D uTex;
      uniform vec2 uHalfPixel;
      in vec2 vUv;
      out vec4 outColor;
      void main() {
        vec4 sum = texture(uTex, vUv + vec2(-uHalfPixel.x * 2.0, 0.0));
        sum += texture(uTex, vUv + vec2(-uHalfPixel.x, uHalfPixel.y)) * 2.0;
        sum += texture(uTex, vUv + vec2(0.0, uHalfPixel.y * 2.0));
        sum += texture(uTex, vUv + vec2(uHalfPixel.x, uHalfPixel.y)) * 2.0;
        sum += texture(uTex, vUv + vec2(uHalfPixel.x * 2.0, 0.0));
        sum += texture(uTex, vUv + vec2(uHalfPixel.x, -uHalfPixel.y)) * 2.0;
        sum += texture(uTex, vUv + vec2(0.0, -uHalfPixel.y * 2.0));
        sum += texture(uTex, vUv + vec2(-uHalfPixel.x, -uHalfPixel.y)) * 2.0;
        outColor = sum / 12.0;
      }`;

    // Pass 4: Final composite with AMD FidelityFX CAS + Auto-Exposure/Shadow-Lift + Joint Bilateral Mask Edge Refinement
    const FS_COMPOSITE = `#version 300 es
      precision mediump float;
      uniform sampler2D uFg;
      uniform sampler2D uBg;
      uniform sampler2D uMask;
      uniform int uMode; // 0=none, 1=blur, 2=virtualBg
      uniform float uHasMask;
      uniform vec2 uTexel;
      uniform vec2 uMaskTexel;
      uniform float uEnhance;
      uniform float uSharpness;
      uniform float uExposureGain;
      uniform float uShadowLift;
      in vec2 vUv;
      out vec4 outColor;

      vec3 applyCas(vec3 c) {
        vec3 a = texture(uFg, vUv + vec2(0.0, -uTexel.y)).rgb;
        vec3 b = texture(uFg, vUv + vec2(-uTexel.x, 0.0)).rgb;
        vec3 d = texture(uFg, vUv + vec2(uTexel.x, 0.0)).rgb;
        vec3 e = texture(uFg, vUv + vec2(0.0, uTexel.y)).rgb;
        vec3 mnRGB = min(min(a, b), min(d, e));
        mnRGB = min(mnRGB, c);
        vec3 mxRGB = max(max(a, b), max(d, e));
        mxRGB = max(mxRGB, c);
        vec3 rcpMRGB = 1.0 / max(mxRGB, vec3(1e-4));
        vec3 ampRGB = clamp(min(mnRGB, 1.0 - mxRGB) * rcpMRGB, 0.0, 1.0);
        ampRGB = sqrt(ampRGB);
        float peak = -1.0 / mix(8.0, 5.0, uSharpness);
        vec3 wRGB = ampRGB * peak;
        return clamp((c + (a + b + d + e) * wRGB) / (1.0 + 4.0 * wRGB), 0.0, 1.0);
      }

      vec3 applyExposureAndShadowLift(vec3 rgb) {
        vec3 lifted = rgb * uExposureGain;
        // Soft highlight shoulder above 0.78 prevents clipping bright skin/windows
        lifted = mix(lifted, 1.0 - exp(-lifted * 1.45), step(0.75, lifted) * 0.35);
        float luma = dot(lifted, vec3(0.2126, 0.7152, 0.0722));
        float shadowMask = (1.0 - smoothstep(0.0, 0.48, luma)) * uShadowLift;
        return clamp(lifted + lifted * shadowMask * 0.85 + vec3(shadowMask * 0.03), 0.0, 1.0);
      }

      void main() {
        vec4 fg = texture(uFg, vUv);
        if (uEnhance > 0.5) {
          if (uSharpness > 0.01) {
            fg.rgb = applyCas(fg.rgb);
          }
          fg.rgb = applyExposureAndShadowLift(fg.rgb);
        }
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

    // Cache attribute & uniform locations once at link time to eliminate per-frame lookups
    function link(fsSrc, uniformNames) {
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
      const uniforms = {};
      for (const name of uniformNames) {
        uniforms[name] = gl.getUniformLocation(p, name);
      }
      return {
        prog: p,
        aPos: gl.getAttribLocation(p, 'aPos'),
        u: uniforms,
      };
    }

    const pTemporal = link(FS_TEMPORAL, ['uTexCurrent', 'uTexHistory', 'uHasHistory', 'uDenoise']);
    const pSpatial = link(FS_SPATIAL_DENOISE, ['uTex', 'uTexel', 'uDenoise']);
    const pBgExtract = link(FS_BG_EXTRACT, ['uFg', 'uMask', 'uTexel', 'uHasMask']);
    const pKawaseDown = link(FS_KAWASE_DOWN, ['uTex', 'uHalfPixel']);
    const pKawaseUp = link(FS_KAWASE_UP, ['uTex', 'uHalfPixel']);
    const pComposite = link(FS_COMPOSITE, [
      'uFg',
      'uBg',
      'uMask',
      'uMode',
      'uHasMask',
      'uTexel',
      'uMaskTexel',
      'uEnhance',
      'uSharpness',
      'uExposureGain',
      'uShadowLift',
    ]);

    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

    function bindQuad(shader) {
      gl.bindBuffer(gl.ARRAY_BUFFER, quad);
      gl.enableVertexAttribArray(shader.aPos);
      gl.vertexAttribPointer(shader.aPos, 2, gl.FLOAT, false, 0, 0);
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
    const texBlurC = makeTex();
    const texVirtualBg = makeTex();
    const texMask = makeTex();

    const fboTemporal = gl.createFramebuffer();
    const fboFg = gl.createFramebuffer();
    const fboBlurA = gl.createFramebuffer();
    const fboBlurB = gl.createFramebuffer();
    const fboBlurC = gl.createFramebuffer();

    let allocW = 0;
    let allocH = 0;
    let maskW = 0;
    let maskH = 0;
    let hasHistory = false;

    function allocColorTarget(tex, fbo, w, h) {
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    }

    function ensureTargets(w, h) {
      if (allocW === w && allocH === h) return;
      allocW = w;
      allocH = h;
      hasHistory = false;

      const aw = Math.max(64, Math.floor(w / 4));
      const ah = Math.max(64, Math.floor(h / 4));
      const bw = Math.max(32, Math.floor(aw / 2));
      const bh = Math.max(32, Math.floor(ah / 2));
      const cw = Math.max(16, Math.floor(bw / 2));
      const ch = Math.max(16, Math.floor(bh / 2));

      allocColorTarget(texTemporal, fboTemporal, w, h);
      allocColorTarget(texFg, fboFg, w, h);

      gl.bindTexture(gl.TEXTURE_2D, texHistory);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);

      allocColorTarget(texBlurA, fboBlurA, aw, ah);
      allocColorTarget(texBlurB, fboBlurB, bw, bh);
      allocColorTarget(texBlurC, fboBlurC, cw, ch);

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

    function render(source, w, h, opts, hasMask, enhanceState) {
      ensureTargets(w, h);

      gl.bindTexture(gl.TEXTURE_2D, texVideo);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);

      const useTemporal = !!opts.denoise;
      const useSpatial = !!opts.denoise && enhanceState.spatialDenoise;

      // Pass 1: Temporal Denoise -> fboTemporal
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboTemporal);
      gl.viewport(0, 0, w, h);
      gl.useProgram(pTemporal.prog);
      bindQuad(pTemporal);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texVideo);
      gl.uniform1i(pTemporal.u.uTexCurrent, 0);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, texHistory);
      gl.uniform1i(pTemporal.u.uTexHistory, 1);
      gl.uniform1f(pTemporal.u.uHasHistory, hasHistory ? 1.0 : 0.0);
      gl.uniform1f(pTemporal.u.uDenoise, useTemporal ? 1.0 : 0.0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

      // Pass 2: Spatial Denoise -> fboFg
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboFg);
      gl.viewport(0, 0, w, h);
      gl.useProgram(pSpatial.prog);
      bindQuad(pSpatial);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texTemporal);
      gl.uniform1i(pSpatial.u.uTex, 0);
      gl.uniform2f(pSpatial.u.uTexel, 1.0 / w, 1.0 / h);
      gl.uniform1f(pSpatial.u.uDenoise, useSpatial ? 1.0 : 0.0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

      // Update history texture from denoised foreground (kept in native exposure space)
      gl.bindTexture(gl.TEXTURE_2D, texHistory);
      gl.copyTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 0, 0, w, h);
      hasHistory = useTemporal;

      const isBlur = opts.effect === 'blurLight' || opts.effect === 'blurStrong';
      const isVirtualBg = opts.effect === 'virtualBackground';

      if (isBlur) {
        const aw = Math.max(64, Math.floor(w / 4));
        const ah = Math.max(64, Math.floor(h / 4));
        const bw = Math.max(32, Math.floor(aw / 2));
        const bh = Math.max(32, Math.floor(ah / 2));
        const cw = Math.max(16, Math.floor(bw / 2));
        const ch = Math.max(16, Math.floor(bh / 2));
        const strong = opts.effect === 'blurStrong';
        const offsetScale = strong ? 1.6 : 1.0;

        // Background extraction pass -> fboBlurA
        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurA);
        gl.viewport(0, 0, aw, ah);
        gl.useProgram(pBgExtract.prog);
        bindQuad(pBgExtract);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texFg);
        gl.uniform1i(pBgExtract.u.uFg, 0);
        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, texMask);
        gl.uniform1i(pBgExtract.u.uMask, 1);
        gl.uniform2f(pBgExtract.u.uTexel, 1.0 / w, 1.0 / h);
        gl.uniform1f(pBgExtract.u.uHasMask, hasMask ? 1.0 : 0.0);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        // Dual-Kawase pyramid downsample: A -> B (-> C for blurStrong)
        gl.useProgram(pKawaseDown.prog);
        bindQuad(pKawaseDown);

        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurB);
        gl.viewport(0, 0, bw, bh);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texBlurA);
        gl.uniform1i(pKawaseDown.u.uTex, 0);
        gl.uniform2f(pKawaseDown.u.uHalfPixel, offsetScale / aw, offsetScale / ah);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        if (strong) {
          gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurC);
          gl.viewport(0, 0, cw, ch);
          gl.bindTexture(gl.TEXTURE_2D, texBlurB);
          gl.uniform2f(pKawaseDown.u.uHalfPixel, offsetScale / bw, offsetScale / bh);
          gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        }

        // Dual-Kawase pyramid upsample: (C -> B ->) A
        gl.useProgram(pKawaseUp.prog);
        bindQuad(pKawaseUp);
        gl.uniform1i(pKawaseUp.u.uTex, 0);

        if (strong) {
          gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurB);
          gl.viewport(0, 0, bw, bh);
          gl.bindTexture(gl.TEXTURE_2D, texBlurC);
          gl.uniform2f(pKawaseUp.u.uHalfPixel, offsetScale / cw, offsetScale / ch);
          gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        }

        gl.bindFramebuffer(gl.FRAMEBUFFER, fboBlurA);
        gl.viewport(0, 0, aw, ah);
        gl.bindTexture(gl.TEXTURE_2D, texBlurB);
        gl.uniform2f(pKawaseUp.u.uHalfPixel, offsetScale / bw, offsetScale / bh);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      }

      // Final composite with CAS + Auto-Exposure/Shadow-Lift + joint bilateral edge refinement
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, w, h);
      gl.useProgram(pComposite.prog);
      bindQuad(pComposite);

      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texFg);
      gl.uniform1i(pComposite.u.uFg, 0);

      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, isVirtualBg ? texVirtualBg : texBlurA);
      gl.uniform1i(pComposite.u.uBg, 1);

      gl.activeTexture(gl.TEXTURE2);
      gl.bindTexture(gl.TEXTURE_2D, texMask);
      gl.uniform1i(pComposite.u.uMask, 2);

      gl.uniform1i(pComposite.u.uMode, isBlur ? 1 : isVirtualBg ? 2 : 0);
      gl.uniform1f(pComposite.u.uHasMask, hasMask ? 1.0 : 0.0);
      gl.uniform2f(pComposite.u.uTexel, 1.0 / w, 1.0 / h);
      gl.uniform2f(pComposite.u.uMaskTexel, 1.0 / (maskW || 256), 1.0 / (maskH || 144));
      gl.uniform1f(pComposite.u.uEnhance, opts.denoise ? 1.0 : 0.0);
      gl.uniform1f(pComposite.u.uSharpness, enhanceState.sharpness);
      gl.uniform1f(pComposite.u.uExposureGain, enhanceState.exposureGain);
      gl.uniform1f(pComposite.u.uShadowLift, enhanceState.shadowLift);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    function dispose() {
      [
        texVideo,
        texTemporal,
        texFg,
        texHistory,
        texBlurA,
        texBlurB,
        texBlurC,
        texVirtualBg,
        texMask,
      ].forEach((t) => gl.deleteTexture(t));
      [fboTemporal, fboFg, fboBlurA, fboBlurB, fboBlurC].forEach((f) => gl.deleteFramebuffer(f));
      [pTemporal, pSpatial, pBgExtract, pKawaseDown, pKawaseUp, pComposite].forEach((s) =>
        gl.deleteProgram(s.prog)
      );
      gl.deleteBuffer(quad);
      gl.getExtension('WEBGL_lose_context')?.loseContext();
      canvas.width = canvas.height = 0;
    }

    return { render, uploadMask, uploadBgSource, dispose };
  }

  function createSession(rawTrack, initialOptions) {
    const opts = Object.assign(
      {
        effect: 'none',
        denoise: true,
        backgroundId: null,
        backgroundPath: null,
        targetFps: 30,
      },
      initialOptions || {}
    );

    const canvas = document.createElement('canvas');
    const settings = (rawTrack.getSettings && rawTrack.getSettings()) || {};
    canvas.width = settings.width || 1280;
    canvas.height = settings.height || 720;

    const webgl = createWebGL2Renderer(canvas);
    const ctx2d = webgl ? null : canvas.getContext('2d');

    // Tiny 16x16 probe avoids gl.readPixels GPU-CPU stall while feeding Auto-Exposure
    const lumaCanvas = document.createElement('canvas');
    lumaCanvas.width = 16;
    lumaCanvas.height = 16;
    const lumaCtx = lumaCanvas.getContext('2d', { willReadFrequently: true });

    const enhanceState = {
      exposureGain: 1.0,
      shadowLift: 0.15,
      sharpness: 0.45,
      spatialDenoise: true,
    };

    let disposed = false;
    let segmenter = null;
    let loadingSegmenter = false;
    let maskBytes = null;
    let maskW = 0;
    let maskH = 0;
    let hasMask = false;
    let bgSignature = '';
    let bgCanvas = null;
    let lastSegmentAt = 0;
    let lastLumaAt = 0;
    let smoothedLuma = 0.45;
    let lastProcessedAt = 0;

    // Adaptive thermal governor state
    let avgProcessMs = 8;
    let highLoadStreak = 0;
    let lowLoadStreak = 0;
    let governorTier = 0; // 0: full, 1: 24fps + 66ms seg, 2: 18fps + 100ms seg + no spatial

    function updateExposureFromSource(source, nowMs) {
      if (!opts.denoise || !lumaCtx || nowMs - lastLumaAt < 250) return;
      lastLumaAt = nowMs;
      try {
        lumaCtx.drawImage(source, 0, 0, 16, 16);
        const data = lumaCtx.getImageData(0, 0, 16, 16).data;
        let sum = 0;
        for (let i = 0; i < data.length; i += 4) {
          sum += 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
        }
        const meanLuma = sum / (256 * 255);
        smoothedLuma = smoothedLuma * 0.8 + meanLuma * 0.2;
        // Target ~0.46 mid-tone luma; clamp gain to [0.92, 1.55] to avoid blowing highlights
        const targetGain = Math.max(0.92, Math.min(1.55, 0.46 / Math.max(0.14, smoothedLuma)));
        enhanceState.exposureGain = enhanceState.exposureGain * 0.8 + targetGain * 0.2;
        const darkFactor = Math.max(0.0, Math.min(1.0, (0.42 - smoothedLuma) / 0.28));
        enhanceState.shadowLift = 0.12 + darkFactor * 0.42;
      } catch (_) {}
    }

    function updateGovernor(processMs) {
      avgProcessMs = avgProcessMs * 0.85 + processMs * 0.15;
      const baseFps = Math.max(15, Math.min(30, opts.targetFps || 30));
      const budgetMs = 1000 / baseFps;

      if (avgProcessMs > budgetMs * 0.72) {
        highLoadStreak++;
        lowLoadStreak = 0;
        if (highLoadStreak >= 15 && governorTier < 2) {
          governorTier++;
          highLoadStreak = 0;
        }
      } else if (avgProcessMs < budgetMs * 0.4) {
        lowLoadStreak++;
        highLoadStreak = 0;
        if (lowLoadStreak >= 45 && governorTier > 0) {
          governorTier--;
          lowLoadStreak = 0;
        }
      } else {
        highLoadStreak = 0;
        lowLoadStreak = 0;
      }

      enhanceState.spatialDenoise = governorTier < 2;
      enhanceState.sharpness = governorTier >= 2 ? 0.25 : 0.45;
    }

    function effectiveFps() {
      const baseFps = Math.max(15, Math.min(30, opts.targetFps || 30));
      if (governorTier >= 2) return Math.min(baseFps, 18);
      if (governorTier === 1) return Math.min(baseFps, 24);
      return baseFps;
    }

    function segIntervalMs() {
      if (governorTier >= 2) return 100;
      if (governorTier === 1) return 66;
      return 33;
    }

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

    function renderFrame(source, srcW, srcH, nowMs) {
      if (disposed || srcW <= 0 || srcH <= 0) return false;
      const minFrameDelta = 1000 / effectiveFps();
      if (lastProcessedAt > 0 && nowMs - lastProcessedAt < minFrameDelta * 0.85) {
        return false;
      }
      lastProcessedAt = nowMs;

      const t0 = performance.now();
      if (canvas.width !== srcW || canvas.height !== srcH) {
        canvas.width = srcW;
        canvas.height = srcH;
        bgSignature = '';
      }

      refreshBackground();
      if (opts.effect !== 'none') {
        ensureSegmenter();
      }

      updateExposureFromSource(source, nowMs);

      if (opts.effect !== 'none' && segmenter && nowMs - lastSegmentAt >= segIntervalMs()) {
        lastSegmentAt = nowMs;
        try {
          const res = segmenter.segmentForVideo(source, nowMs);
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
              maskBytes[i] = hasMask ? Math.round(maskBytes[i] * 0.3 + target * 0.7) : target;
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
        webgl.render(source, canvas.width, canvas.height, opts, hasMask, enhanceState);
      } else if (ctx2d) {
        ctx2d.save();
        if (opts.effect === 'blurLight' || opts.effect === 'blurStrong') {
          ctx2d.filter = opts.effect === 'blurStrong' ? 'blur(12px)' : 'blur(5px)';
        } else {
          ctx2d.filter = 'none';
        }
        ctx2d.drawImage(source, 0, 0, canvas.width, canvas.height);
        ctx2d.restore();
      }

      updateGovernor(performance.now() - t0);
      return true;
    }

    refreshBackground();
    if (opts.effect !== 'none') ensureSegmenter();

    const hasWebCodecs =
      typeof MediaStreamTrackProcessor === 'function' &&
      typeof MediaStreamTrackGenerator === 'function' &&
      typeof VideoFrame === 'function';

    let outputTrack = null;
    let video = null;
    let frameCallbackId = null;
    let fallbackTimerId = null;
    let wcReader = null;
    let wcWriter = null;

    function startRvfcFallback() {
      video = document.createElement('video');
      video.muted = true;
      video.playsInline = true;
      video.autoplay = true;
      video.srcObject = new MediaStream([rawTrack]);
      video.play().catch(() => {});

      let lastRvfcAt = performance.now();
      function processVideo(nowMs) {
        if (disposed || video.readyState < 2) return;
        lastRvfcAt = nowMs;
        renderFrame(video, video.videoWidth, video.videoHeight, nowMs);
      }

      function scheduleNext() {
        if (disposed) return;
        if (typeof video.requestVideoFrameCallback === 'function') {
          frameCallbackId = video.requestVideoFrameCallback((now) => {
            processVideo(now);
            scheduleNext();
          });
        }
      }

      const fps = Math.max(15, Math.min(30, opts.targetFps || 30));
      const outputStream = canvas.captureStream(fps);
      outputTrack = outputStream.getVideoTracks()[0];

      const hasRvfc = typeof video.requestVideoFrameCallback === 'function';
      if (hasRvfc) scheduleNext();
      fallbackTimerId = setInterval(() => {
        const now = performance.now();
        if (!hasRvfc || document.hidden || now - lastRvfcAt > 200) {
          processVideo(now);
        }
      }, Math.round(1000 / fps));
    }

    if (hasWebCodecs) {
      try {
        const processor = new MediaStreamTrackProcessor({ track: rawTrack });
        const generator = new MediaStreamTrackGenerator({ kind: 'video' });
        outputTrack = generator;
        wcReader = processor.readable.getReader();
        wcWriter = generator.writable.getWriter();

        (async () => {
          try {
            while (!disposed) {
              const { value: frame, done } = await wcReader.read();
              if (done || !frame) break;
              try {
                if (!disposed) {
                  const w = frame.displayWidth || frame.codedWidth;
                  const h = frame.displayHeight || frame.codedHeight;
                  const rendered = renderFrame(frame, w, h, performance.now());
                  if (rendered) {
                    const outFrame = new VideoFrame(canvas, {
                      timestamp: frame.timestamp,
                      duration: frame.duration,
                    });
                    try {
                      await wcWriter.write(outFrame);
                    } finally {
                      outFrame.close();
                    }
                  }
                }
              } finally {
                frame.close();
              }
            }
          } catch (_) {
            // Stream ended or track stopped during teardown
          }
        })();
      } catch (_) {
        startRvfcFallback();
      }
    } else {
      startRvfcFallback();
    }

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
        if (wcReader) {
          wcReader.cancel().catch(() => {});
          wcReader = null;
        }
        if (wcWriter) {
          wcWriter.close().catch(() => {});
          wcWriter = null;
        }
        if (frameCallbackId !== null && video && typeof video.cancelVideoFrameCallback === 'function') {
          try {
            video.cancelVideoFrameCallback(frameCallbackId);
          } catch (_) {}
          frameCallbackId = null;
        }
        if (fallbackTimerId !== null) {
          clearInterval(fallbackTimerId);
          fallbackTimerId = null;
        }
        if (video) {
          video.srcObject = null;
          video = null;
        }
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

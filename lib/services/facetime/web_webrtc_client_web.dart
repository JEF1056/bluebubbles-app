import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:web/web.dart' as web;

class _WebBrowserRtcPeerAdapter implements WebRtcMediaPeerAdapter {
  static int _viewCounter = 0;

  web.RTCPeerConnection? _pc;
  web.MediaStream? _localStream;
  web.MediaStream? _remoteStream;
  web.MediaStreamTrack? _rawAudioTrack;
  web.MediaStreamTrack? _processedAudioTrack;
  web.MediaStreamTrack? _rawVideoTrack;
  web.MediaStreamTrack? _processedVideoTrack;
  web.RTCRtpSender? _audioSender;
  web.RTCRtpSender? _videoSender;

  web.AudioContext? _audioContext;
  web.MediaStreamAudioSourceNode? _audioSourceNode;
  web.BiquadFilterNode? _highPassNode;
  web.AudioWorkletNode? _workletNode;
  web.MediaStreamAudioDestinationNode? _audioDestNode;
  bool _rnnoiseActive = false;

  JSObject? _videoProcessorSession;
  Future<void>? _videoProcessorScriptFuture;
  FaceTimeVideoEffectType _videoEffect = FaceTimeVideoEffectType.none;
  bool _videoDenoise = false;
  String? _backgroundId;
  String? _backgroundPath;

  web.HTMLAudioElement? _remoteAudioEl;
  web.HTMLVideoElement? _remoteVideoEl;
  web.HTMLVideoElement? _localVideoEl;
  String? _remoteViewType;
  String? _localViewType;

  String? _selectedOutputId;
  String? _selectedInputId;
  bool _voiceIsolationEnabled = true;

  bool _hasLocalVideo = false;
  bool _canFlipCamera = false;
  bool _isFrontCamera = true;
  bool _cameraEnabled = false;
  bool _closed = false;

  Timer? _statsTimer;
  final AdaptiveQualityLadder _ladder = AdaptiveQualityLadder();
  int _prevBytesSent = 0;
  int _prevBytesRecv = 0;
  int _prevAudioBytesSent = 0;
  int _prevAudioBytesRecv = 0;
  DateTime? _prevStatsAt;
  DateTime? _lastAudioLogAt;
  JSFunction? _autoplayResumeListener;

  void Function(WebRtcIceCandidate candidate)? _onIceCandidate;
  void Function(Widget? widget)? _onRemoteVideoWidget;
  void Function(Widget? widget)? _onLocalVideoWidget;
  void Function(String state)? _onConnectionStateChanged;
  void Function(
    List<FaceTimeAudioDevice> outputs,
    List<FaceTimeAudioDevice> inputs,
    String? activeOutputId,
    String? activeInputId,
  )? _onAudioDevicesChanged;
  void Function(FaceTimeCallQualityStats stats)? _onQualityStats;
  void Function(String state)? _onIceStateChanged;

  JSFunction? _deviceChangeListener;

  @override
  bool get isSupported {
    try {
      return web.window.has('RTCPeerConnection') &&
          web.window.navigator.has('mediaDevices');
    } catch (_) {
      return false;
    }
  }

  @override
  bool get hasLocalVideo => _hasLocalVideo;

  @override
  bool get canFlipCamera => _canFlipCamera;

  @override
  bool get isFrontCamera => _isFrontCamera;

  @override
  bool get canSelectAudioOutput {
    try {
      final probe = _remoteAudioEl ?? (web.document.createElement('audio') as web.HTMLAudioElement);
      return probe.has('setSinkId');
    } catch (_) {
      return false;
    }
  }

  void _ensureVideoElements() {
    if (_remoteVideoEl == null) {
      final el = web.document.createElement('video') as web.HTMLVideoElement;
      el.autoplay = true;
      el.playsInline = true;
      el.muted = true; // Audio is played exclusively via _remoteAudioEl in document.body.
      el.style.width = '100%';
      el.style.height = '100%';
      el.style.objectFit = 'contain';
      el.style.pointerEvents = 'none';
      _remoteVideoEl = el;
      final viewType = 'bb-ft-remote-video-${++_viewCounter}';
      _remoteViewType = viewType;
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => el);
    }

    if (_localVideoEl == null) {
      final el = web.document.createElement('video') as web.HTMLVideoElement;
      el.autoplay = true;
      el.playsInline = true;
      el.muted = true;
      el.setAttribute('playsinline', 'true');
      el.setAttribute('muted', 'true');
      el.style.width = '100%';
      el.style.height = '100%';
      el.style.objectFit = 'contain';
      el.style.pointerEvents = 'none';
      el.style.transform = _isFrontCamera ? 'scaleX(-1)' : 'none';
      _localVideoEl = el;
      final viewType = 'bb-ft-local-video-${++_viewCounter}';
      _localViewType = viewType;
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => el);
    }
  }

  void _attachRemoteAudio(web.MediaStream stream) {
    _detachAutoplayListeners();
    _remoteAudioEl?.srcObject = null;
    _remoteAudioEl?.remove();
    final audio = web.HTMLAudioElement()
      ..autoplay = true
      ..muted = false
      ..volume = 1.0
      ..setAttribute('playsinline', 'true')
      ..style.display = 'none'
      ..srcObject = stream;
    _remoteAudioEl = audio;
    web.document.body?.append(audio);

    // Unmute all remote audio tracks explicitly.
    final tracks = stream.getAudioTracks().toDart;
    for (final track in tracks) {
      track.enabled = true;
    }

    if (_selectedOutputId != null && _selectedOutputId!.isNotEmpty && canSelectAudioOutput) {
      unawaited(selectAudioOutput(_selectedOutputId!));
    }
    _playRemoteAudioWithAutoplayFallback(audio);
  }

  void _playRemoteAudioWithAutoplayFallback(web.HTMLAudioElement audio) {
    audio.play().toDart.then((_) {
      _detachAutoplayListeners();
    }).catchError((dynamic _) {
      if (_autoplayResumeListener != null || _closed) return null;
      final listener = ((web.Event _) {
        if (_closed || _remoteAudioEl != audio) {
          _detachAutoplayListeners();
          return;
        }
        audio.play().toDart.then((_) {
          _detachAutoplayListeners();
        }).catchError((_) => null);
        if (_audioContext != null && _audioContext!.state == 'suspended') {
          unawaited(_audioContext!.resume().toDart.catchError((_) => null));
        }
      }).toJS;
      _autoplayResumeListener = listener;
      web.document.addEventListener('click', listener);
      web.document.addEventListener('pointerdown', listener);
      web.document.addEventListener('keydown', listener);
      return null;
    });
  }

  void _detachAutoplayListeners() {
    final listener = _autoplayResumeListener;
    if (listener != null) {
      try {
        web.document.removeEventListener('click', listener);
        web.document.removeEventListener('pointerdown', listener);
        web.document.removeEventListener('keydown', listener);
      } catch (_) {}
      _autoplayResumeListener = null;
    }
  }

  @override
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo}) async {
    _closed = false;
    _hasLocalVideo = false;
    _canFlipCamera = false;
    _isFrontCamera = true;
    _cameraEnabled = false;
    _ensureVideoElements();

    final jsIceServers = iceServers
        .map((server) => <String, dynamic>{
              'urls': server.urls.length == 1 ? server.urls.first : server.urls,
              if (server.username != null && server.username!.isNotEmpty) 'username': server.username,
              if (server.credential != null && server.credential!.isNotEmpty) 'credential': server.credential,
            })
        .toList();

    final config = <String, dynamic>{
      'iceServers': jsIceServers,
    }.jsify() as web.RTCConfiguration;

    final pc = web.RTCPeerConnection(config);
    _pc = pc;

    pc.onicecandidate = ((web.RTCPeerConnectionIceEvent event) {
      final cand = event.candidate;
      if (cand == null || cand.candidate.isEmpty) return;
      _onIceCandidate?.call(WebRtcIceCandidate(
        candidate: cand.candidate,
        sdpMid: cand.sdpMid,
        sdpMLineIndex: cand.sdpMLineIndex,
      ));
    }).toJS;

    pc.onconnectionstatechange = ((web.Event _) {
      _onConnectionStateChanged?.call(pc.connectionState);
    }).toJS;

    pc.oniceconnectionstatechange = ((web.Event _) {
      _onIceStateChanged?.call(pc.iceConnectionState);
    }).toJS;

    pc.ontrack = ((web.RTCTrackEvent event) {
      final track = event.track;
      final streams = event.streams.toDart;
      final stream = streams.isNotEmpty ? streams.first : _streamWithTrack(track);
      _remoteStream = stream;

      if (track.kind == 'audio') {
        _attachRemoteAudio(stream);
      } else if (track.kind == 'video' && _remoteVideoEl != null && _remoteViewType != null) {
        _remoteVideoEl!.srcObject = stream;
        _remoteVideoEl!.style.pointerEvents = 'none';
        unawaited(_remoteVideoEl!.play().toDart.catchError((_) => null));
        _onRemoteVideoWidget?.call(HtmlElementView(viewType: _remoteViewType!));
      }
    }).toJS;

    final audioConstraints = _buildAudioConstraints(deviceId: _selectedInputId);
    final videoConstraints = wantVideo ? _buildVideoConstraints(front: _isFrontCamera) : false.toJS;

    web.MediaStream localStream;
    try {
      localStream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: audioConstraints, video: videoConstraints))
          .toDart;
    } catch (e) {
      if (!wantVideo || !identical(_pc, pc)) rethrow;
      // Retry audio-only if camera acquisition failed or was denied.
      localStream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: audioConstraints, video: false.toJS))
          .toDart;
    }

    if (_closed || !identical(_pc, pc)) {
      _stopStream(localStream);
      return;
    }

    _localStream = localStream;
    final audioTracks = localStream.getAudioTracks().toDart;
    if (audioTracks.isNotEmpty) {
      _rawAudioTrack = audioTracks.first;
      final sendAudioTrack = await _setupAudioPipeline(audioTracks.first);
      if (_closed || !identical(_pc, pc)) {
        await _disposeAudioPipeline(_audioContext);
        _stopStream(localStream);
        return;
      }
      _audioSender = pc.addTrack(sendAudioTrack, localStream);
      if (_processedAudioTrack != null && identical(sendAudioTrack, _processedAudioTrack)) {
        Logger.info('RNNoise AudioWorklet output verified as published track', tag: 'WebRtc');
      }
    }

    final videoTracks = localStream.getVideoTracks().toDart;
    if (wantVideo && videoTracks.isNotEmpty) {
      final rawVideo = videoTracks.first;
      _hasLocalVideo = true;
      _cameraEnabled = true;
      _rawVideoTrack = rawVideo;
      final transceiver = pc.addTransceiver(
        rawVideo,
        web.RTCRtpTransceiverInit(
          direction: 'sendrecv',
          streams: <web.MediaStream>[localStream].toJS,
        ),
      );
      _videoSender = transceiver.sender;
      _preferH264Codec(transceiver, isSendRecv: true);
      await _applyVideoSenderParams(
        maxBitrateBps: _ladder.currentRung.maxBitrateKbps * 1000,
        maxFramerate: _ladder.currentRung.maxFramerate,
        scaleResolutionDownBy: _ladder.currentRung.scaleResolutionDownBy,
      );
      _updateLocalPreviewTrack(rawVideo);
    } else if (wantVideo) {
      final transceiver = pc.addTransceiver(
        'video'.toJS,
        web.RTCRtpTransceiverInit(direction: 'recvonly'),
      );
      _preferH264Codec(transceiver, isSendRecv: false);
    }

    await _refreshCanFlipCamera();
    if (_closed || !identical(_pc, pc)) return;
    _attachDeviceChangeListener();
    _startStatsLoop();
  }

  void _preferH264Codec(web.RTCRtpTransceiver transceiver, {required bool isSendRecv}) {
    try {
      final caps = isSendRecv
          ? web.RTCRtpSender.getCapabilities('video')
          : web.RTCRtpReceiver.getCapabilities('video');
      if (caps == null) return;
      final codecs = caps.codecs.toDart;
      if (codecs.isEmpty) return;
      final h264 = <web.RTCRtpCodec>[];
      final rest = <web.RTCRtpCodec>[];
      for (final codec in codecs) {
        if (codec.mimeType.toLowerCase() == 'video/h264') {
          h264.add(codec);
        } else {
          rest.add(codec);
        }
      }
      if (h264.isEmpty) return;
      transceiver.setCodecPreferences(<web.RTCRtpCodec>[...h264, ...rest].toJS);
    } catch (_) {}
  }

  web.MediaStream _streamWithTrack(web.MediaStreamTrack track) {
    final stream = web.MediaStream();
    stream.addTrack(track);
    return stream;
  }

  JSAny _buildAudioConstraints({String? deviceId}) {
    final map = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': <String, dynamic>{'exact': deviceId},
    };
    return map.jsify()!;
  }

  JSAny _buildVideoConstraints({required bool front, String? deviceId}) {
    final map = <String, dynamic>{
      if (deviceId != null && deviceId.isNotEmpty)
        'deviceId': <String, dynamic>{'exact': deviceId}
      else
        'facingMode': front ? 'user' : 'environment',
      'width': <String, dynamic>{'ideal': 1920, 'min': 640},
      'height': <String, dynamic>{'ideal': 1080, 'min': 360},
      'frameRate': <String, dynamic>{'ideal': 30, 'min': 15},
    };
    return map.jsify()!;
  }

  void _updateLocalPreviewTrack(web.MediaStreamTrack? track) {
    if (_localVideoEl == null || _localViewType == null) return;
    if (track == null) {
      _localVideoEl!.srcObject = null;
      _onLocalVideoWidget?.call(null);
      return;
    }
    _localVideoEl!.srcObject = _streamWithTrack(track);
    _localVideoEl!.style.pointerEvents = 'none';
    _localVideoEl!.style.transform = _isFrontCamera ? 'scaleX(-1)' : 'none';
    unawaited(_localVideoEl!.play().toDart.catchError((_) => null));
    _onLocalVideoWidget?.call(HtmlElementView(viewType: _localViewType!));
  }

  void _rewireAudioGraph() {
    final source = _audioSourceNode;
    final worklet = _workletNode;
    final hpf = _highPassNode;
    if (source == null || worklet == null) return;
    try {
      source.disconnect();
      hpf?.disconnect();
      if (_voiceIsolationEnabled && _rnnoiseActive && hpf != null) {
        source.connect(hpf);
        hpf.connect(worklet);
      } else {
        source.connect(worklet);
      }
    } catch (_) {}
  }

  Future<void> _disposeAudioPipeline(web.AudioContext? ctx) async {
    try {
      _audioSourceNode?.disconnect();
    } catch (_) {}
    try {
      _highPassNode?.disconnect();
    } catch (_) {}
    try {
      _workletNode?.disconnect();
    } catch (_) {}
    try {
      _audioDestNode?.disconnect();
    } catch (_) {}
    try {
      _processedAudioTrack?.stop();
    } catch (_) {}
    _audioSourceNode = null;
    _highPassNode = null;
    _workletNode = null;
    _audioDestNode = null;
    _processedAudioTrack = null;
    if (identical(_audioContext, ctx)) {
      _audioContext = null;
    }
    if (ctx != null) {
      try {
        await ctx.close().toDart;
      } catch (_) {}
    }
  }

  Future<web.MediaStreamTrack> _setupAudioPipeline(web.MediaStreamTrack rawTrack) async {
    web.AudioContext? ctx;
    try {
      if (!web.window.has('AudioContext')) {
        return rawTrack;
      }
      ctx = web.AudioContext(web.AudioContextOptions(sampleRate: 48000));
      _audioContext = ctx;
      if (ctx.sampleRate != 48000) {
        Logger.warn('Web AudioContext sampleRate (${ctx.sampleRate}) does not match 48000 Hz', tag: 'WebRtc');
      }
      if (ctx.state == 'suspended') {
        await ctx.resume().toDart;
        if (_closed) {
          await _disposeAudioPipeline(ctx);
          return rawTrack;
        }
      }

      final resp = await web.window.fetch('facetime/rnnoise.wasm'.toJS).toDart;
      if (_closed || !resp.ok) {
        await _disposeAudioPipeline(ctx);
        return rawTrack;
      }
      final wasmBuffer = await resp.arrayBuffer().toDart;
      if (_closed) {
        await _disposeAudioPipeline(ctx);
        return rawTrack;
      }
      await ctx.audioWorklet.addModule('facetime/audio_processor.js').toDart;
      if (_closed) {
        await _disposeAudioPipeline(ctx);
        return rawTrack;
      }

      final source = ctx.createMediaStreamSource(_streamWithTrack(rawTrack));
      _audioSourceNode = source;

      final hpf = ctx.createBiquadFilter();
      hpf.type = 'highpass';
      hpf.frequency.value = 85;
      _highPassNode = hpf;

      final workletOptions = <String, dynamic>{
        'numberOfInputs': 1,
        'numberOfOutputs': 1,
        'outputChannelCount': <int>[1],
        'processorOptions': <String, dynamic>{
          'enabled': _voiceIsolationEnabled,
        },
      }.jsify() as web.AudioWorkletNodeOptions;

      final worklet = web.AudioWorkletNode(ctx, 'bb-voice-isolation', workletOptions);
      _workletNode = worklet;
      _rnnoiseActive = true;

      worklet.port.onmessage = ((web.MessageEvent event) {
        final data = event.data;
        if (data == null || !data.isA<JSObject>()) return;
        final obj = data as JSObject;
        final type = (obj['type'] as JSString?)?.toDart;
        if (type == 'fallback') {
          _rnnoiseActive = false;
          _rewireAudioGraph();
          if (_rawAudioTrack != null) {
            unawaited(
              _rawAudioTrack!
                  .applyConstraints(web.MediaTrackConstraints(
                    echoCancellation: true.toJS,
                    autoGainControl: true.toJS,
                    noiseSuppression: _voiceIsolationEnabled.toJS,
                  ))
                  .toDart
                  .catchError((_) => null),
            );
          }
        } else if (type == 'ready') {
          _rnnoiseActive = true;
          _rewireAudioGraph();
          if (_rawAudioTrack != null) {
            unawaited(
              _rawAudioTrack!
                  .applyConstraints(web.MediaTrackConstraints(
                    echoCancellation: true.toJS,
                    autoGainControl: true.toJS,
                    noiseSuppression: false.toJS,
                  ))
                  .toDart
                  .catchError((_) => null),
            );
          }
        }
      }).toJS;

      worklet.port.postMessage(
        <String, dynamic>{'wasmBinary': wasmBuffer, 'enabled': _voiceIsolationEnabled}.jsify(),
      );

      final dest = ctx.createMediaStreamDestination();
      _audioDestNode = dest;

      _rewireAudioGraph();
      worklet.connect(dest);

      final outTracks = dest.stream.getAudioTracks().toDart;
      if (outTracks.isEmpty) {
        await _disposeAudioPipeline(ctx);
        return rawTrack;
      }

      outTracks.first.enabled = rawTrack.enabled;
      _processedAudioTrack = outTracks.first;
      // Avoid double noise suppression when RNNoise is active; keep autoGainControl and
      // echoCancellation decoupled and consistently enabled.
      try {
        await rawTrack.applyConstraints(web.MediaTrackConstraints(
          echoCancellation: true.toJS,
          autoGainControl: true.toJS,
          noiseSuppression: false.toJS,
        )).toDart;
      } catch (_) {}
      if (_closed) {
        await _disposeAudioPipeline(ctx);
        return rawTrack;
      }
      return outTracks.first;
    } catch (_) {
      _rnnoiseActive = false;
      await _disposeAudioPipeline(ctx);
      return rawTrack;
    }
  }

  @override
  Future<void> setVoiceIsolation(bool enabled) async {
    _voiceIsolationEnabled = enabled;
    if (_workletNode != null && _rnnoiseActive) {
      _workletNode!.port.postMessage(<String, dynamic>{'enabled': enabled}.jsify());
      _rewireAudioGraph();
      if (_rawAudioTrack != null) {
        try {
          await _rawAudioTrack!.applyConstraints(web.MediaTrackConstraints(
            echoCancellation: true.toJS,
            autoGainControl: true.toJS,
            noiseSuppression: false.toJS,
          )).toDart;
        } catch (_) {}
      }
    } else if (_rawAudioTrack != null) {
      try {
        await _rawAudioTrack!.applyConstraints(web.MediaTrackConstraints(
          echoCancellation: true.toJS,
          autoGainControl: true.toJS,
          noiseSuppression: enabled.toJS,
        )).toDart;
      } catch (_) {}
    }
  }

  Future<void> _ensureVideoProcessorScript() {
    if (web.window.has('bbFaceTimeVideoProcessor')) return Future.value();
    final existing = _videoProcessorScriptFuture;
    if (existing != null) return existing;

    final completer = Completer<void>();
    final script = web.document.createElement('script') as web.HTMLScriptElement;
    script.src = 'facetime/video_processor.js';
    script.async = true;
    script.onload = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    script.onerror = ((web.Event _) {
      _videoProcessorScriptFuture = null;
      if (!completer.isCompleted) completer.completeError(StateError('Failed to load facetime/video_processor.js'));
    }).toJS;
    (web.document.head ?? web.document.body)?.appendChild(script);
    return _videoProcessorScriptFuture = completer.future;
  }

  @override
  Future<void> setVideoProcessing({
    required FaceTimeVideoEffectType effect,
    required bool denoise,
    String? backgroundId,
    String? backgroundPath,
  }) async {
    _videoEffect = effect;
    _videoDenoise = denoise;
    _backgroundId = backgroundId;
    _backgroundPath = backgroundPath;

    final rawVideo = _rawVideoTrack;
    final sender = _videoSender;
    if (rawVideo == null || sender == null) return;

    final wantsProcessing = effect != FaceTimeVideoEffectType.none || denoise;
    if (!wantsProcessing) {
      final session = _videoProcessorSession;
      if (session != null) {
        _videoProcessorSession = null;
        _processedVideoTrack = null;
        try {
          await sender.replaceTrack(rawVideo).toDart;
          if (!_closed) {
            _updateLocalPreviewTrack(rawVideo);
          }
        } finally {
          try {
            session.callMethod<JSAny?>('dispose'.toJS);
          } catch (_) {}
        }
      }
      return;
    }

    final opts = <String, dynamic>{
      'effect': effect.name,
      'denoise': denoise,
      'backgroundId': backgroundId,
      'backgroundPath': backgroundPath,
      'targetFps': _ladder.currentRung.maxFramerate,
    }.jsify()!;

    if (_videoProcessorSession != null) {
      _videoProcessorSession!.callMethod<JSAny?>('updateOptions'.toJS, opts);
      return;
    }

    try {
      await _ensureVideoProcessorScript();
      if (_closed || !identical(_rawVideoTrack, rawVideo)) return;
      if (_videoEffect == FaceTimeVideoEffectType.none && !_videoDenoise) return;
      final latestOpts = <String, dynamic>{
        'effect': _videoEffect.name,
        'denoise': _videoDenoise,
        'backgroundId': _backgroundId,
        'backgroundPath': _backgroundPath,
        'targetFps': _ladder.currentRung.maxFramerate,
      }.jsify()!;
      if (_videoProcessorSession != null) {
        _videoProcessorSession!.callMethod<JSAny?>('updateOptions'.toJS, latestOpts);
        return;
      }
      final api = web.window['bbFaceTimeVideoProcessor'] as JSObject?;
      if (api == null) return;
      final session = api.callMethod<JSObject?>('createSession'.toJS, rawVideo, latestOpts);
      if (session == null) return;
      final outTrack = session['track'] as web.MediaStreamTrack?;
      if (outTrack == null) {
        session.callMethod<JSAny?>('dispose'.toJS);
        return;
      }
      outTrack.enabled = rawVideo.enabled;
      _videoProcessorSession = session;
      _processedVideoTrack = outTrack;
      try {
        await sender.replaceTrack(outTrack).toDart;
      } catch (_) {
        try {
          session.callMethod<JSAny?>('dispose'.toJS);
        } catch (_) {}
        try {
          outTrack.stop();
        } catch (_) {}
        if (identical(_videoProcessorSession, session)) {
          _videoProcessorSession = null;
          _processedVideoTrack = null;
        }
        rethrow;
      }
      if (_closed || !identical(_rawVideoTrack, rawVideo)) {
        try {
          session.callMethod<JSAny?>('dispose'.toJS);
        } catch (_) {}
        try {
          outTrack.stop();
        } catch (_) {}
        if (identical(_videoProcessorSession, session)) {
          _videoProcessorSession = null;
          _processedVideoTrack = null;
        }
        return;
      }
      _updateLocalPreviewTrack(outTrack);
    } catch (_) {
      // Keep raw camera track active if processor load/init fails.
    }
  }

  String? _trackDeviceId(web.MediaStreamTrack? track) {
    if (track == null) return null;
    try {
      final id = track.getSettings().deviceId;
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findAlternateVideoDeviceId(String? currentDeviceId) async {
    try {
      final devices = (await web.window.navigator.mediaDevices.enumerateDevices().toDart).toDart;
      final ids = <String>[
        for (final d in devices)
          if (d.kind == 'videoinput' && d.deviceId.isNotEmpty) d.deviceId,
      ];
      if (ids.length < 2) return null;
      if (currentDeviceId == null) return ids[1];
      final idx = ids.indexOf(currentDeviceId);
      if (idx == -1) return ids.first;
      return ids[(idx + 1) % ids.length];
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshCanFlipCamera() async {
    if (!_hasLocalVideo) {
      _canFlipCamera = false;
      return;
    }
    try {
      final devices = (await web.window.navigator.mediaDevices.enumerateDevices().toDart).toDart;
      final videoInputs = devices.where((d) => d.kind == 'videoinput').length;
      _canFlipCamera = videoInputs > 1;
    } catch (_) {
      _canFlipCamera = false;
    }
  }

  FaceTimeAudioDeviceKind _inferDeviceKind(String label, {required bool isInput}) {
    final lower = label.toLowerCase();
    if (lower.contains('bluetooth') || lower.contains('airpods') || lower.contains('buds') || lower.contains('wireless')) {
      return FaceTimeAudioDeviceKind.bluetooth;
    }
    if (lower.contains('usb')) {
      return FaceTimeAudioDeviceKind.usb;
    }
    if (lower.contains('headphone') || lower.contains('headset') || lower.contains('wired') || lower.contains('jack')) {
      return FaceTimeAudioDeviceKind.wired;
    }
    if (lower.contains('speaker')) {
      return FaceTimeAudioDeviceKind.speaker;
    }
    return isInput ? FaceTimeAudioDeviceKind.builtinMic : FaceTimeAudioDeviceKind.unknown;
  }

  @override
  Future<
      ({
        List<FaceTimeAudioDevice> outputs,
        List<FaceTimeAudioDevice> inputs,
        String? activeOutputId,
        String? activeInputId,
      })> enumerateAudioDevices() async {
    try {
      final rawDevices = (await web.window.navigator.mediaDevices.enumerateDevices().toDart).toDart;
      final activeOut = _selectedOutputId ?? 'default';
      final activeIn = _selectedInputId ?? _trackDeviceId(_rawAudioTrack);

      final outputs = <FaceTimeAudioDevice>[];
      final inputs = <FaceTimeAudioDevice>[];

      for (final d in rawDevices) {
        if (d.kind == 'audiooutput') {
          final id = d.deviceId;
          final label = d.label.trim().isNotEmpty ? d.label.trim() : (id == 'default' ? 'System Default' : 'Speaker');
          outputs.add(FaceTimeAudioDevice(
            id: id,
            label: label,
            kind: _inferDeviceKind(label, isInput: false),
            isInput: false,
            isActive: id == activeOut,
          ));
        } else if (d.kind == 'audioinput') {
          final id = d.deviceId;
          final label = d.label.trim().isNotEmpty ? d.label.trim() : (id == 'default' ? 'Default Microphone' : 'Microphone');
          inputs.add(FaceTimeAudioDevice(
            id: id,
            label: label,
            kind: _inferDeviceKind(label, isInput: true),
            isInput: true,
            isActive: (activeIn != null && activeIn.isNotEmpty) ? id == activeIn : id == 'default',
          ));
        }
      }

      return (
        outputs: outputs,
        inputs: inputs,
        activeOutputId: outputs.isEmpty ? null : (outputs.any((d) => d.isActive) ? activeOut : outputs.first.id),
        activeInputId: inputs.isEmpty ? null : (inputs.any((d) => d.isActive) ? activeIn : inputs.first.id),
      );
    } catch (_) {
      return (
        outputs: const <FaceTimeAudioDevice>[],
        inputs: const <FaceTimeAudioDevice>[],
        activeOutputId: null,
        activeInputId: null,
      );
    }
  }

  @override
  Future<bool> selectAudioOutput(String deviceId) async {
    if (!canSelectAudioOutput || _remoteAudioEl == null) return false;
    try {
      await _remoteAudioEl!.setSinkId(deviceId).toDart;
      _selectedOutputId = deviceId;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> selectAudioInput(String deviceId) async {
    final pc = _pc;
    if (pc == null) return false;
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(
            audio: _buildAudioConstraints(deviceId: deviceId),
            video: false.toJS,
          ))
          .toDart;
      if (!identical(_pc, pc)) {
        _stopStream(stream);
        return false;
      }
      final newTracks = stream.getAudioTracks().toDart;
      if (newTracks.isEmpty) {
        _stopStream(stream);
        return false;
      }
      final newRaw = newTracks.first;
      newRaw.enabled = _rawAudioTrack?.enabled ?? true;
      _selectedInputId = deviceId;

      final oldRaw = _rawAudioTrack;
      _rawAudioTrack = newRaw;

      if (_audioContext != null && _workletNode != null && _rnnoiseActive) {
        try {
          _audioSourceNode?.disconnect();
          _audioSourceNode = _audioContext!.createMediaStreamSource(_streamWithTrack(newRaw));
          _rewireAudioGraph();
          await newRaw.applyConstraints(web.MediaTrackConstraints(
            echoCancellation: true.toJS,
            autoGainControl: true.toJS,
            noiseSuppression: false.toJS,
          )).toDart;
          if (_audioSender != null && _processedAudioTrack != null && _audioSender!.track != _processedAudioTrack) {
            await _audioSender!.replaceTrack(_processedAudioTrack).toDart;
          }
        } catch (_) {
          if (_audioSender != null) {
            await _audioSender!.replaceTrack(newRaw).toDart;
          }
        }
      } else if (_audioSender != null) {
        await _audioSender!.replaceTrack(newRaw).toDart;
        try {
          await newRaw.applyConstraints(web.MediaTrackConstraints(
            echoCancellation: true.toJS,
            autoGainControl: true.toJS,
            noiseSuppression: _voiceIsolationEnabled.toJS,
          )).toDart;
        } catch (_) {}
      }

      if (oldRaw != null) {
        try {
          oldRaw.stop();
        } catch (_) {}
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _attachDeviceChangeListener() {
    if (_deviceChangeListener != null) return;
    _deviceChangeListener = ((web.Event _) {
      if (_closed) return;
      unawaited(enumerateAudioDevices().then((res) {
        if (!_closed) {
          _onAudioDevicesChanged?.call(res.outputs, res.inputs, res.activeOutputId, res.activeInputId);
        }
      }));
    }).toJS;
    web.window.navigator.mediaDevices.addEventListener('devicechange', _deviceChangeListener);
  }

  void _detachDeviceChangeListener() {
    if (_deviceChangeListener != null) {
      try {
        web.window.navigator.mediaDevices.removeEventListener('devicechange', _deviceChangeListener);
      } catch (_) {}
      _deviceChangeListener = null;
    }
  }

  Future<void> _applyVideoSenderParams({
    required int maxBitrateBps,
    required int maxFramerate,
    required double scaleResolutionDownBy,
  }) async {
    final sender = _videoSender;
    if (sender == null) return;
    try {
      final params = sender.getParameters();
      final encodings = params.encodings.toDart;
      if (encodings.isNotEmpty) {
        encodings.first.maxBitrate = maxBitrateBps;
        encodings.first.maxFramerate = maxFramerate;
        encodings.first.scaleResolutionDownBy = scaleResolutionDownBy;
        await sender.setParameters(params).toDart;
      }
    } catch (_) {}
  }

  void _startStatsLoop() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollStats());
    });
  }

  Future<void> _pollStats() async {
    final pc = _pc;
    if (_closed || pc == null) return;
    try {
      final report = await pc.getStats().toDart;
      final now = DateTime.now();

      int bytesSent = 0;
      int sendW = 0;
      int sendH = 0;
      int sendFps = 0;
      bool qualityLimited = false;

      int bytesRecv = 0;
      int recvW = 0;
      int recvH = 0;
      int recvFps = 0;
      int packetsLost = 0;
      int packetsRecv = 0;
      double availableOutKbps = 0;
      int rttMs = 0;

      int audioBytesSent = 0;
      int audioPacketsSent = 0;
      int audioBytesRecv = 0;
      int audioPacketsRecv = 0;
      int audioPacketsLost = 0;
      double audioInLevel = 0.0;
      double audioOutLevel = 0.0;

      report.callMethod<JSAny?>(
        'forEach'.toJS,
        ((JSObject stat, JSAny? _) {
          final type = (stat['type'] as JSString?)?.toDart;
          final kind = (stat['kind'] as JSString?)?.toDart ?? (stat['mediaType'] as JSString?)?.toDart;
          if (type == 'outbound-rtp') {
            if (kind == 'video') {
              bytesSent += ((stat['bytesSent'] as JSNumber?)?.toDartDouble ?? 0).round();
              sendW = ((stat['frameWidth'] as JSNumber?)?.toDartDouble ?? sendW).round();
              sendH = ((stat['frameHeight'] as JSNumber?)?.toDartDouble ?? sendH).round();
              sendFps = ((stat['framesPerSecond'] as JSNumber?)?.toDartDouble ?? sendFps).round();
              final qlr = (stat['qualityLimitationReason'] as JSString?)?.toDart;
              if (qlr == 'bandwidth' || qlr == 'cpu') {
                qualityLimited = true;
              }
            } else if (kind == 'audio') {
              audioBytesSent += ((stat['bytesSent'] as JSNumber?)?.toDartDouble ?? 0).round();
              audioPacketsSent += ((stat['packetsSent'] as JSNumber?)?.toDartDouble ?? 0).round();
            }
          } else if (type == 'inbound-rtp') {
            if (kind == 'video') {
              bytesRecv += ((stat['bytesReceived'] as JSNumber?)?.toDartDouble ?? 0).round();
              recvW = ((stat['frameWidth'] as JSNumber?)?.toDartDouble ?? recvW).round();
              recvH = ((stat['frameHeight'] as JSNumber?)?.toDartDouble ?? recvH).round();
              recvFps = ((stat['framesPerSecond'] as JSNumber?)?.toDartDouble ?? recvFps).round();
              packetsLost += ((stat['packetsLost'] as JSNumber?)?.toDartDouble ?? 0).round();
              packetsRecv += ((stat['packetsReceived'] as JSNumber?)?.toDartDouble ?? 0).round();
            } else if (kind == 'audio') {
              audioBytesRecv += ((stat['bytesReceived'] as JSNumber?)?.toDartDouble ?? 0).round();
              audioPacketsRecv += ((stat['packetsReceived'] as JSNumber?)?.toDartDouble ?? 0).round();
              audioPacketsLost += ((stat['packetsLost'] as JSNumber?)?.toDartDouble ?? 0).round();
              final lvl = (stat['audioLevel'] as JSNumber?)?.toDartDouble;
              if (lvl != null && lvl > 0) audioInLevel = lvl;
            }
          } else if (type == 'media-source' && kind == 'audio') {
            final lvl = (stat['audioLevel'] as JSNumber?)?.toDartDouble;
            if (lvl != null && lvl > 0) audioOutLevel = lvl;
          } else if (type == 'remote-inbound-rtp') {
            final rttSec = (stat['roundTripTime'] as JSNumber?)?.toDartDouble;
            if (rttSec != null && rttSec > 0) {
              rttMs = (rttSec * 1000).round();
            }
          } else if (type == 'candidate-pair' && (stat['nominated'] as JSBoolean?)?.toDart == true) {
            final rttSec = (stat['currentRoundTripTime'] as JSNumber?)?.toDartDouble;
            if (rttSec != null && rttSec > 0) {
              rttMs = (rttSec * 1000).round();
            }
            final bweBps = (stat['availableOutgoingBitrate'] as JSNumber?)?.toDartDouble;
            if (bweBps != null && bweBps > 0) {
              availableOutKbps = bweBps / 1000.0;
            }
          }
        }).toJS,
      );

      int sendBitrateKbps = 0;
      int recvBitrateKbps = 0;
      int audioSendBitrateKbps = 0;
      int audioRecvBitrateKbps = 0;
      if (_prevStatsAt != null) {
        final elapsedMs = now.difference(_prevStatsAt!).inMilliseconds;
        if (elapsedMs > 0) {
          if (bytesSent >= _prevBytesSent) {
            sendBitrateKbps = (((bytesSent - _prevBytesSent) * 8) / elapsedMs).round();
          }
          if (bytesRecv >= _prevBytesRecv) {
            recvBitrateKbps = (((bytesRecv - _prevBytesRecv) * 8) / elapsedMs).round();
          }
          if (audioBytesSent >= _prevAudioBytesSent) {
            audioSendBitrateKbps = (((audioBytesSent - _prevAudioBytesSent) * 8) / elapsedMs).round();
          }
          if (audioBytesRecv >= _prevAudioBytesRecv) {
            audioRecvBitrateKbps = (((audioBytesRecv - _prevAudioBytesRecv) * 8) / elapsedMs).round();
          }
        }
      }
      _prevBytesSent = bytesSent;
      _prevBytesRecv = bytesRecv;
      _prevAudioBytesSent = audioBytesSent;
      _prevAudioBytesRecv = audioBytesRecv;
      _prevStatsAt = now;

      if (_lastAudioLogAt == null || now.difference(_lastAudioLogAt!).inSeconds >= 6) {
        _lastAudioLogAt = now;
        if (GetIt.I.isRegistered<BaseLogger>()) {
          Logger.debug(
            'WebRTC audio stats: inBitrate=${audioRecvBitrateKbps}kbps inPkts=$audioPacketsRecv inLost=$audioPacketsLost inLevel=${audioInLevel.toStringAsFixed(3)} outBitrate=${audioSendBitrateKbps}kbps outPkts=$audioPacketsSent outLevel=${audioOutLevel.toStringAsFixed(3)}',
            tag: 'WebWebRtc',
          );
        }
      }

      final totalPackets = packetsLost + packetsRecv;
      final packetLossPct = totalPackets > 0 ? (packetsLost / totalPackets) * 100.0 : 0.0;

      if (_hasLocalVideo && _videoSender != null && _rawVideoTrack?.enabled == true) {
        final decision = _ladder.evaluate(
          availableBitrateKbps: availableOutKbps,
          packetLossPct: packetLossPct,
          rttMs: rttMs,
          qualityLimited: qualityLimited,
          timestamp: now,
        );
        if (decision.changed) {
          await _applyVideoSenderParams(
            maxBitrateBps: decision.maxBitrateBps,
            maxFramerate: decision.maxFramerate,
            scaleResolutionDownBy: decision.scaleResolutionDownBy,
          );
        }
      }

      _onQualityStats?.call(FaceTimeCallQualityStats(
        sendWidth: sendW,
        sendHeight: sendH,
        sendFps: sendFps,
        sendBitrateKbps: sendBitrateKbps,
        recvWidth: recvW,
        recvHeight: recvH,
        recvFps: recvFps,
        recvBitrateKbps: recvBitrateKbps,
        packetLossPct: double.parse(packetLossPct.toStringAsFixed(2)),
        rttMs: rttMs,
        audioSendBitrateKbps: audioSendBitrateKbps,
        audioRecvBitrateKbps: audioRecvBitrateKbps,
        audioPacketsLost: audioPacketsLost,
        audioInLevel: audioInLevel,
        audioOutLevel: audioOutLevel,
      ));
    } catch (_) {}
  }

  @override
  Future<WebRtcSessionDescription> createAndSetOffer() async {
    final pc = _pc;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }
    final offer = await pc.createOffer().toDart;
    if (offer == null || offer.sdp.isEmpty) {
      throw StateError('Failed to create WebRTC SDP offer');
    }
    await pc.setLocalDescription(web.RTCLocalSessionDescriptionInit(type: offer.type, sdp: offer.sdp)).toDart;
    return WebRtcSessionDescription(type: offer.type, sdp: offer.sdp);
  }

  @override
  Future<void> setRemoteAnswer(String sdp, String type) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(web.RTCSessionDescriptionInit(type: type, sdp: sdp)).toDart;
  }

  @override
  Future<void> addIceCandidate(WebRtcIceCandidate candidate) async {
    final pc = _pc;
    if (pc == null) return;
    await pc
        .addIceCandidate(web.RTCIceCandidateInit(
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ))
        .toDart;
  }

  @override
  void setMicMuted(bool muted) {
    if (_rawAudioTrack != null) {
      _rawAudioTrack!.enabled = !muted;
    }
    if (_processedAudioTrack != null) {
      _processedAudioTrack!.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _cameraEnabled = enabled;
    if (_rawVideoTrack != null) {
      _rawVideoTrack!.enabled = enabled;
    }
    if (_processedVideoTrack != null) {
      _processedVideoTrack!.enabled = enabled;
    }
  }

  @override
  Future<void> flipCamera() async {
    final pc = _pc;
    final sender = _videoSender;
    final stream = _localStream;
    if (!_hasLocalVideo || pc == null || sender == null || stream == null) return;

    final oldTrack = _rawVideoTrack;
    final oldDeviceId = _trackDeviceId(oldTrack);
    final nextFront = !_isFrontCamera;

    web.MediaStream? newStream;
    try {
      newStream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(
            audio: false.toJS,
            video: _buildVideoConstraints(front: nextFront),
          ))
          .toDart;
    } catch (_) {
      newStream = null;
    }
    if (!identical(_pc, pc)) {
      _stopStream(newStream);
      return;
    }

    var newTracks = newStream?.getVideoTracks().toDart ?? <web.MediaStreamTrack>[];
    final sameDevice = oldDeviceId != null && newTracks.isNotEmpty && _trackDeviceId(newTracks.first) == oldDeviceId;
    if (newTracks.isEmpty || sameDevice) {
      final altDeviceId = await _findAlternateVideoDeviceId(oldDeviceId);
      if (!identical(_pc, pc)) {
        _stopStream(newStream);
        return;
      }
      if (altDeviceId != null) {
        _stopStream(newStream);
        newStream = null;
        try {
          newStream = await web.window.navigator.mediaDevices
              .getUserMedia(web.MediaStreamConstraints(
                audio: false.toJS,
                video: _buildVideoConstraints(front: nextFront, deviceId: altDeviceId),
              ))
              .toDart;
          if (!identical(_pc, pc)) {
            _stopStream(newStream);
            return;
          }
          newTracks = newStream.getVideoTracks().toDart;
        } catch (_) {
          _stopStream(newStream);
          newStream = null;
          newTracks = <web.MediaStreamTrack>[];
        }
      } else if (sameDevice) {
        _stopStream(newStream);
        return;
      }
    }

    if (newTracks.isEmpty) {
      _stopStream(newStream);
      return;
    }

    final newRaw = newTracks.first;
    newRaw.enabled = _cameraEnabled;
    for (var i = 1; i < newTracks.length; i++) {
      newTracks[i].stop();
    }

    if (_videoProcessorSession != null) {
      try {
        _videoProcessorSession!.callMethod<JSAny?>('dispose'.toJS);
      } catch (_) {}
      _videoProcessorSession = null;
      _processedVideoTrack = null;
    }
    try {
      await sender.replaceTrack(newRaw).toDart;
    } catch (_) {
      _stopStream(newStream);
      rethrow;
    }
    if (_closed || !identical(_pc, pc)) {
      _stopStream(newStream);
      return;
    }
    _updateLocalPreviewTrack(newRaw);

    if (oldTrack != null) {
      stream.removeTrack(oldTrack);
      try {
        oldTrack.stop();
      } catch (_) {}
    }
    stream.addTrack(newRaw);
    _rawVideoTrack = newRaw;
    _isFrontCamera = nextFront;

    if (_videoEffect != FaceTimeVideoEffectType.none || _videoDenoise) {
      await setVideoProcessing(
        effect: _videoEffect,
        denoise: _videoDenoise,
        backgroundId: _backgroundId,
        backgroundPath: _backgroundPath,
      );
    } else {
      _updateLocalPreviewTrack(newRaw);
    }
  }

  @override
  void setOnIceCandidate(void Function(WebRtcIceCandidate candidate)? callback) {
    _onIceCandidate = callback;
  }

  @override
  void setOnRemoteVideoWidget(void Function(Widget? widget)? callback) {
    _onRemoteVideoWidget = callback;
  }

  @override
  void setOnLocalVideoWidget(void Function(Widget? widget)? callback) {
    _onLocalVideoWidget = callback;
  }

  @override
  void setOnConnectionStateChanged(void Function(String state)? callback) {
    _onConnectionStateChanged = callback;
  }

  @override
  void setOnAudioDevicesChanged(
    void Function(
      List<FaceTimeAudioDevice> outputs,
      List<FaceTimeAudioDevice> inputs,
      String? activeOutputId,
      String? activeInputId,
    )? callback,
  ) {
    _onAudioDevicesChanged = callback;
  }

  @override
  void setOnQualityStats(void Function(FaceTimeCallQualityStats stats)? callback) {
    _onQualityStats = callback;
  }

  @override
  void setOnIceStateChanged(void Function(String state)? callback) {
    _onIceStateChanged = callback;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    _detachDeviceChangeListener();

    _onRemoteVideoWidget?.call(null);
    _onLocalVideoWidget?.call(null);
    _onIceCandidate = null;
    _onRemoteVideoWidget = null;
    _onLocalVideoWidget = null;
    _onConnectionStateChanged = null;
    _onAudioDevicesChanged = null;
    _onQualityStats = null;
    _onIceStateChanged = null;

    if (_videoProcessorSession != null) {
      try {
        _videoProcessorSession!.callMethod<JSAny?>('dispose'.toJS);
      } catch (_) {}
      _videoProcessorSession = null;
    }

    _stopStream(_localStream);
    _stopStream(_remoteStream);
    _localStream = null;
    _remoteStream = null;

    try {
      _rawAudioTrack?.stop();
    } catch (_) {}
    try {
      _processedAudioTrack?.stop();
    } catch (_) {}
    try {
      _rawVideoTrack?.stop();
    } catch (_) {}
    try {
      _processedVideoTrack?.stop();
    } catch (_) {}
    _rawAudioTrack = null;
    _processedAudioTrack = null;
    _rawVideoTrack = null;
    _processedVideoTrack = null;
    _audioSender = null;
    _videoSender = null;

    if (_audioContext != null) {
      try {
        _audioSourceNode?.disconnect();
        _highPassNode?.disconnect();
        _workletNode?.disconnect();
        _audioDestNode?.disconnect();
        await _audioContext!.close().toDart;
      } catch (_) {}
      _audioContext = null;
      _audioSourceNode = null;
      _highPassNode = null;
      _workletNode = null;
      _audioDestNode = null;
    }

    _detachAutoplayListeners();
    _remoteAudioEl?.srcObject = null;
    _remoteAudioEl?.remove();
    _remoteAudioEl = null;

    _remoteVideoEl?.srcObject = null;
    _remoteVideoEl?.remove();
    _remoteVideoEl = null;

    _localVideoEl?.srcObject = null;
    _localVideoEl?.remove();
    _localVideoEl = null;

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        pc.onicecandidate = null;
        pc.ontrack = null;
        pc.onconnectionstatechange = null;
        pc.oniceconnectionstatechange = null;
        pc.close();
      } catch (_) {}
    }

    _hasLocalVideo = false;
    _canFlipCamera = false;
    _cameraEnabled = false;
    _isFrontCamera = true;
    _rnnoiseActive = false;
  }

  void _stopStream(web.MediaStream? stream) {
    if (stream == null) return;
    try {
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
    } catch (_) {}
  }
}

WebRtcPeerAdapter createPlatformWebRtcPeerAdapter() => _WebBrowserRtcPeerAdapter();

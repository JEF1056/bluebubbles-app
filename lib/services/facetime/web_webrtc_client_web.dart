import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

int _nextVideoViewId = 0;

class _BrowserWebRtcPeerAdapter implements WebRtcPeerAdapter {
  web.RTCPeerConnection? _pc;
  web.MediaStream? _localStream;
  web.HTMLAudioElement? _audioElement;
  web.HTMLVideoElement? _videoElement;
  web.HTMLVideoElement? _localVideoElement;
  web.RTCRtpSender? _videoSender;

  bool _hasLocalVideo = false;
  bool _canFlipCamera = false;
  bool _isFrontCamera = true;
  bool _cameraEnabled = false;

  void Function(WebRtcIceCandidate candidate)? _onIceCandidate;
  void Function(Widget? widget)? _onRemoteVideoWidget;
  void Function(Widget? widget)? _onLocalVideoWidget;
  void Function(String state)? _onConnectionStateChanged;

  @override
  bool get isSupported => true;

  @override
  bool get hasLocalVideo => _hasLocalVideo;

  @override
  bool get canFlipCamera => _canFlipCamera;

  @override
  bool get isFrontCamera => _isFrontCamera;

  web.MediaTrackConstraints _videoConstraints({required bool front, String? deviceId}) {
    if (deviceId != null && deviceId.isNotEmpty) {
      return web.MediaTrackConstraints(
        deviceId: web.ConstrainDOMStringParameters(exact: deviceId.toJS),
        width: web.ConstrainULongRange(ideal: 1280),
        height: web.ConstrainULongRange(ideal: 720),
        frameRate: web.ConstrainDoubleRange(ideal: 30),
      );
    }
    return web.MediaTrackConstraints(
      facingMode: (front ? 'user' : 'environment').toJS,
      width: web.ConstrainULongRange(ideal: 1280),
      height: web.ConstrainULongRange(ideal: 720),
      frameRate: web.ConstrainDoubleRange(ideal: 30),
    );
  }

  @override
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo}) async {
    final jsServers = <web.RTCIceServer>[
      for (final server in iceServers)
        () {
          final entry = web.RTCIceServer(
            urls: server.urls.length == 1
                ? server.urls.first.toJS
                : <JSString>[for (final u in server.urls) u.toJS].toJS,
          );
          if (server.username != null && server.username!.isNotEmpty) {
            entry.username = server.username!;
          }
          if (server.credential != null && server.credential!.isNotEmpty) {
            entry.credential = server.credential!;
          }
          return entry;
        }(),
    ].toJS;

    final pc = web.RTCPeerConnection(web.RTCConfiguration(iceServers: jsServers));
    _pc = pc;
    _hasLocalVideo = false;
    _canFlipCamera = false;
    _isFrontCamera = true;
    _cameraEnabled = false;
    _videoSender = null;

    pc.onicecandidate = ((web.RTCPeerConnectionIceEvent event) {
      final candidate = event.candidate;
      if (candidate == null || candidate.candidate.isEmpty) return;
      _onIceCandidate?.call(WebRtcIceCandidate(
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ));
    }).toJS;

    pc.onconnectionstatechange = ((web.Event _) {
      _onConnectionStateChanged?.call(pc.connectionState);
    }).toJS;

    pc.ontrack = ((web.RTCTrackEvent event) {
      final track = event.track;
      final streams = event.streams.toDart;
      final stream = streams.isNotEmpty ? streams.first : _streamWithTrack(track);

      if (track.kind == 'audio') {
        _attachRemoteAudio(stream);
      } else if (track.kind == 'video') {
        _attachRemoteVideo(stream);
      }
    }).toJS;

    late web.MediaStream stream;
    if (wantVideo) {
      try {
        stream = await web.window.navigator.mediaDevices
            .getUserMedia(web.MediaStreamConstraints(
              audio: true.toJS,
              video: _videoConstraints(front: _isFrontCamera),
            ))
            .toDart;
      } catch (_) {
        if (!identical(_pc, pc)) return;
        // Retry audio-only if camera permission/device acquisition fails
        stream = await web.window.navigator.mediaDevices
            .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
            .toDart;
      }
    } else {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
          .toDart;
    }
    if (!identical(_pc, pc)) {
      _stopStreamTracks(stream);
      return;
    }
    _localStream = stream;

    for (final track in stream.getAudioTracks().toDart) {
      pc.addTrack(track, stream);
    }

    final videoTracks = stream.getVideoTracks().toDart;
    if (wantVideo && videoTracks.isNotEmpty) {
      final videoTrack = videoTracks.first;
      _hasLocalVideo = true;
      _cameraEnabled = true;
      final transceiver = pc.addTransceiver(
        videoTrack,
        web.RTCRtpTransceiverInit(
          direction: 'sendrecv',
          streams: <web.MediaStream>[stream].toJS,
        ),
      );
      _videoSender = transceiver.sender;
      _preferH264Codec(transceiver, isSendRecv: true);
      final multiCam = await _hasMultipleVideoInputs();
      if (!identical(_pc, pc)) return;
      _canFlipCamera = multiCam;
      _attachLocalVideo(videoTrack);
    } else if (wantVideo) {
      final transceiver = pc.addTransceiver(
        'video'.toJS,
        web.RTCRtpTransceiverInit(direction: 'recvonly'),
      );
      _preferH264Codec(transceiver, isSendRecv: false);
    }
  }

  void _stopStreamTracks(web.MediaStream? stream) {
    if (stream == null) return;
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
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

  Future<bool> _hasMultipleVideoInputs() async {
    try {
      final devices = (await web.window.navigator.mediaDevices.enumerateDevices().toDart).toDart;
      var count = 0;
      for (final device in devices) {
        if (device.kind == 'videoinput') {
          count++;
          if (count >= 2) return true;
        }
      }
    } catch (_) {}
    return false;
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

  web.MediaStream _streamWithTrack(web.MediaStreamTrack track) {
    final stream = web.MediaStream();
    stream.addTrack(track);
    return stream;
  }

  void _attachRemoteAudio(web.MediaStream stream) {
    _audioElement?.remove();
    final audio = web.HTMLAudioElement()
      ..autoplay = true
      ..setAttribute('playsinline', 'true')
      ..style.display = 'none'
      ..srcObject = stream;
    _audioElement = audio;
    web.document.body?.append(audio);
    unawaited(audio.play().toDart.catchError((_) => null));
  }

  void _attachRemoteVideo(web.MediaStream stream) {
    _videoElement?.remove();
    final video = web.HTMLVideoElement()
      ..autoplay = true
      ..playsInline = true
      ..muted = true
      ..srcObject = stream;
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'cover';
    _videoElement = video;

    final viewType = 'bb-ft-remote-video-${_nextVideoViewId++}';
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => video);
    unawaited(video.play().toDart.catchError((_) => null));
    _onRemoteVideoWidget?.call(HtmlElementView(viewType: viewType));
  }

  void _attachLocalVideo(web.MediaStreamTrack videoTrack) {
    _localVideoElement?.remove();
    final video = web.HTMLVideoElement()
      ..autoplay = true
      ..playsInline = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('muted', 'true')
      ..srcObject = _streamWithTrack(videoTrack);
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'cover'
      ..transform = _isFrontCamera ? 'scaleX(-1)' : 'none';
    _localVideoElement = video;

    final viewType = 'bb-ft-local-video-${_nextVideoViewId++}';
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => video);
    unawaited(video.play().toDart.catchError((_) => null));
    _onLocalVideoWidget?.call(HtmlElementView(viewType: viewType));
  }

  @override
  Future<WebRtcSessionDescription> createAndSetOffer() async {
    final pc = _pc;
    if (pc == null) {
      throw StateError('RTCPeerConnection is not initialized');
    }
    final offer = await pc.createOffer().toDart;
    final type = offer?.type ?? 'offer';
    final sdp = offer?.sdp ?? '';
    if (sdp.isEmpty) {
      throw StateError('Failed to create WebRTC SDP offer');
    }
    await pc.setLocalDescription(web.RTCLocalSessionDescriptionInit(type: type, sdp: sdp)).toDart;
    return WebRtcSessionDescription(type: type, sdp: sdp);
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
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getAudioTracks().toDart) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    if (!_hasLocalVideo) return;
    _cameraEnabled = enabled;
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getVideoTracks().toDart) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> flipCamera() async {
    final pc = _pc;
    final sender = _videoSender;
    final stream = _localStream;
    if (!_hasLocalVideo || pc == null || sender == null || stream == null) return;

    final oldTracks = stream.getVideoTracks().toDart;
    final oldTrack = oldTracks.isNotEmpty ? oldTracks.first : null;
    final oldDeviceId = _trackDeviceId(oldTrack);
    final nextFront = !_isFrontCamera;

    web.MediaStream? newStream;
    try {
      newStream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(
            video: _videoConstraints(front: nextFront),
          ))
          .toDart;
    } catch (_) {
      newStream = null;
    }
    if (!identical(_pc, pc)) {
      _stopStreamTracks(newStream);
      return;
    }

    var newTracks = newStream?.getVideoTracks().toDart ?? <web.MediaStreamTrack>[];
    final sameDevice = oldDeviceId != null && newTracks.isNotEmpty && _trackDeviceId(newTracks.first) == oldDeviceId;
    if (newTracks.isEmpty || sameDevice) {
      final altDeviceId = await _findAlternateVideoDeviceId(oldDeviceId);
      if (!identical(_pc, pc)) {
        _stopStreamTracks(newStream);
        return;
      }
      if (altDeviceId != null) {
        _stopStreamTracks(newStream);
        newStream = null;
        try {
          newStream = await web.window.navigator.mediaDevices
              .getUserMedia(web.MediaStreamConstraints(
                video: _videoConstraints(front: nextFront, deviceId: altDeviceId),
              ))
              .toDart;
          if (!identical(_pc, pc)) {
            _stopStreamTracks(newStream);
            return;
          }
          newTracks = newStream.getVideoTracks().toDart;
        } catch (_) {
          _stopStreamTracks(newStream);
          newStream = null;
          newTracks = <web.MediaStreamTrack>[];
        }
      } else if (sameDevice) {
        _stopStreamTracks(newStream);
        return;
      }
    }

    if (newTracks.isEmpty) {
      _stopStreamTracks(newStream);
      return;
    }

    final newTrack = newTracks.first;
    newTrack.enabled = _cameraEnabled;
    try {
      await sender.replaceTrack(newTrack).toDart;
    } catch (_) {
      _stopStreamTracks(newStream);
      rethrow;
    }
    if (!identical(_pc, pc)) {
      _stopStreamTracks(newStream);
      return;
    }

    for (final t in oldTracks) {
      stream.removeTrack(t);
      t.stop();
    }
    for (var i = 1; i < newTracks.length; i++) {
      newTracks[i].stop();
    }
    stream.addTrack(newTrack);

    _isFrontCamera = nextFront;
    final localVideoEl = _localVideoElement;
    if (localVideoEl != null) {
      localVideoEl.srcObject = _streamWithTrack(newTrack);
      localVideoEl.style.transform = _isFrontCamera ? 'scaleX(-1)' : 'none';
      unawaited(localVideoEl.play().toDart.catchError((_) => null));
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
  Future<void> close() async {
    _onRemoteVideoWidget?.call(null);
    _onLocalVideoWidget?.call(null);
    _onIceCandidate = null;
    _onRemoteVideoWidget = null;
    _onLocalVideoWidget = null;
    _onConnectionStateChanged = null;

    _videoSender = null;
    _hasLocalVideo = false;
    _canFlipCamera = false;
    _cameraEnabled = false;
    _isFrontCamera = true;

    final stream = _localStream;
    _localStream = null;
    _stopStreamTracks(stream);

    _audioElement?.srcObject = null;
    _audioElement?.remove();
    _audioElement = null;

    _videoElement?.srcObject = null;
    _videoElement?.remove();
    _videoElement = null;

    _localVideoElement?.srcObject = null;
    _localVideoElement?.remove();
    _localVideoElement = null;

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      pc.onicecandidate = null;
      pc.ontrack = null;
      pc.onconnectionstatechange = null;
      pc.close();
    }
  }
}

WebRtcPeerAdapter createPlatformWebRtcPeerAdapter() => _BrowserWebRtcPeerAdapter();

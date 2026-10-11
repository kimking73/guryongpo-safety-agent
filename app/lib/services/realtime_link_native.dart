import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'realtime_link_base.dart';

export 'realtime_link_base.dart';

/// Android·iOS만. 그 밖(데스크톱·flutter test)은 null → 녹음 올리기 방식
RealtimeLink? createRealtimeLink() => (Platform.isAndroid || Platform.isIOS) ? _NativeWebRtcLink() : null;

/// 휴대폰 WebRTC (flutter_webrtc, 2026-10-12): realtime_link_web.dart와 같은 흐름 — 마이크 트랙을 올리고,
/// 받은 모델 소리 트랙은 플러그인이 바로 튼다 (스피커로), 이벤트는 데이터 채널 `oai-events`.
/// 에코 제거·잡음 억제는 기기 WebRTC 오디오 처리가 한다.
class _NativeWebRtcLink implements RealtimeLink {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _mic;
  final _pending = <String>[]; // 데이터 채널이 열리기 전에 보낸 것
  bool _closed = false;

  @override
  Future<void> connect({
    required String callsUrl,
    required String clientSecret,
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function() onClosed,
    bool microphone = true,
  }) async {
    final mic = _mic = microphone
        ? await navigator.mediaDevices.getUserMedia({
            'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
            'video': false,
          })
        : null;
    if (_closed) return _stopMic();
    final pc = _pc = await createPeerConnection({});
    if (mic != null) {
      for (final track in mic.getAudioTracks()) {
        await pc.addTrack(track, mic);
      }
    } else {
      await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly)); // 듣기만
    }
    final dc = _dc = await pc.createDataChannel('oai-events', RTCDataChannelInit());
    dc.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        for (final m in _pending) {
          dc.send(RTCDataChannelMessage(m));
        }
        _pending.clear();
      } else if (s == RTCDataChannelState.RTCDataChannelClosed && !_closed) {
        close();
        onClosed();
      }
    };
    dc.onMessage = (m) {
      if (m.isBinary) return;
      try {
        onEvent(Map<String, dynamic>.from(jsonDecode(m.text) as Map));
      } catch (_) {}
    };
    pc.onConnectionState = (s) {
      if (_closed) return;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        close();
        onClosed();
      }
    };

    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    final answer = await Dio().post<String>(callsUrl,
        data: offer.sdp,
        options: Options(
            contentType: 'application/sdp',
            responseType: ResponseType.plain,
            headers: {'Authorization': 'Bearer $clientSecret'},
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10)));
    if (_closed) return;
    await pc.setRemoteDescription(RTCSessionDescription(answer.data!, 'answer'));
    // 화면을 보지 않고 듣는 사용자 — 귀에 대지 않아도 들리게 스피커로 (블루투스 이어폰이 있으면 그쪽)
    try {
      await Helper.setSpeakerphoneOnButPreferBluetooth();
    } catch (_) {}
  }

  @override
  void send(Map<String, dynamic> event) {
    if (_closed) return;
    final text = jsonEncode(event);
    final dc = _dc;
    if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      dc.send(RTCDataChannelMessage(text));
    } else {
      _pending.add(text);
    }
  }

  void _stopMic() {
    final mic = _mic;
    if (mic != null) {
      for (final t in mic.getTracks()) {
        t.stop();
      }
      mic.dispose();
    }
    _mic = null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopMic();
    try {
      await _dc?.close();
      await _pc?.close();
    } catch (_) {}
    _pending.clear();
  }
}

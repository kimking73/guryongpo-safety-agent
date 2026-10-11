import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;

import 'realtime_link_base.dart';

export 'realtime_link_base.dart';

RealtimeLink? createRealtimeLink() => _WebRtcLink();

/// 브라우저 WebRTC: 마이크 트랙을 올리고, 받은 소리 트랙은 <audio>로 틀고, 이벤트는 데이터 채널 `oai-events`.
/// 에코 제거·잡음 억제는 브라우저가 한다 (스피커로 나온 모델 목소리를 다시 듣지 않게).
class _WebRtcLink implements RealtimeLink {
  web.RTCPeerConnection? _pc;
  web.RTCDataChannel? _dc;
  web.MediaStream? _mic;
  web.HTMLAudioElement? _audio;
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
        ? await web.window.navigator.mediaDevices
            .getUserMedia(web.MediaStreamConstraints(
                audio: {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true}.jsify()!))
            .toDart
        : null;
    if (_closed) return _stopMic();
    final pc = _pc = web.RTCPeerConnection();
    final audio = _audio = web.HTMLAudioElement()..autoplay = true;
    pc.ontrack = ((web.RTCTrackEvent e) {
      final streams = e.streams.toDart;
      if (streams.isNotEmpty) audio.srcObject = streams.first;
    }).toJS;
    if (mic != null) {
      for (final track in mic.getAudioTracks().toDart) {
        pc.addTrack(track, mic);
      }
    } else {
      pc.addTransceiver('audio'.toJS, web.RTCRtpTransceiverInit(direction: 'recvonly')); // 듣기만
    }
    final dc = _dc = pc.createDataChannel('oai-events');
    dc.onopen = ((web.Event _) {
      for (final m in _pending) {
        dc.send(m.toJS);
      }
      _pending.clear();
    }).toJS;
    dc.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSString>()) {
        try {
          onEvent(Map<String, dynamic>.from(jsonDecode((data as JSString).toDart) as Map));
        } catch (_) {}
      }
    }).toJS;
    void lost(web.Event _) {
      if (_closed) return;
      final s = pc.connectionState;
      if (s == 'failed' || s == 'closed' || s == 'disconnected') {
        close();
        onClosed();
      }
    }

    pc.onconnectionstatechange = lost.toJS;
    dc.onclose = lost.toJS;

    await pc.setLocalDescription().toDart; // 인자 없이 = 지금 상태에 맞는 제안(offer)을 만들어 넣는다
    final answer = await Dio().post<String>(callsUrl,
        data: pc.localDescription!.sdp,
        options: Options(
            contentType: 'application/sdp',
            responseType: ResponseType.plain,
            headers: {'Authorization': 'Bearer $clientSecret'},
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10)));
    if (_closed) return;
    await pc.setRemoteDescription(web.RTCSessionDescriptionInit(type: 'answer', sdp: answer.data!)).toDart;
  }

  @override
  void send(Map<String, dynamic> event) {
    if (_closed) return;
    final text = jsonEncode(event);
    final dc = _dc;
    if (dc != null && dc.readyState == 'open') {
      dc.send(text.toJS);
    } else {
      _pending.add(text);
    }
  }

  void _stopMic() {
    final mic = _mic;
    if (mic != null) {
      for (final t in mic.getTracks().toDart) {
        t.stop();
      }
    }
    _mic = null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopMic();
    try {
      _dc?.close();
      _pc?.close();
    } catch (_) {}
    _audio?.pause();
    _audio?.srcObject = null;
    _pending.clear();
  }
}

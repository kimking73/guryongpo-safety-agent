// 실시간 음성 대화의 연결부 (OpenAI Realtime, WebRTC). 웹은 브라우저 WebRTC, Android·iOS는 flutter_webrtc (2026-10-12).
// 그 밖(데스크톱 테스트 등)은 createRealtimeLink()가 null이라 녹음 올리기 방식(VoiceConversation)으로 넘어간다.
export 'realtime_link_stub.dart'
    if (dart.library.js_interop) 'realtime_link_web.dart'
    if (dart.library.io) 'realtime_link_native.dart';

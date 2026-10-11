// 실시간 음성 대화의 연결부 (OpenAI Realtime, WebRTC). 웹에서만 된다 — 그 밖의 기기는 createRealtimeLink()가 null이라
// 녹음 올리기 방식(VoiceConversation)으로 넘어간다.
export 'realtime_link_stub.dart' if (dart.library.js_interop) 'realtime_link_web.dart';

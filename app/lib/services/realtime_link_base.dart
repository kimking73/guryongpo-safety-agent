/// OpenAI Realtime과의 연결 하나: 마이크 소리를 보내고, 모델 소리를 틀고, 이벤트(JSON)를 주고받는다.
abstract class RealtimeLink {
  /// 마이크 권한을 받고 연결한다. 권한이 없거나 연결하지 못하면 예외.
  /// [onEvent]는 서버 이벤트, [onClosed]는 연결이 끊겼을 때 (스스로 [close]한 경우는 부르지 않는다).
  Future<void> connect({
    required String callsUrl,
    required String clientSecret,
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function() onClosed,
  });

  /// 클라이언트 이벤트를 보낸다 (연결 전·끊긴 뒤에는 버린다)
  void send(Map<String, dynamic> event);

  /// 마이크와 연결을 닫는다
  Future<void> close();
}

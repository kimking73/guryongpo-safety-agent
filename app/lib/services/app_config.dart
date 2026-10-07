enum AppMode { mock, remote }

class AppConfig {
  static const _mode = String.fromEnvironment('APP_MODE', defaultValue: 'mock');
  // 서버 주소. 로컬은 서비스별 포트, 배포는 Caddy가 한 도메인에서 경로(/api/v1·/api/chat·/api/route)로 나눈다.
  // Android 에뮬레이터에서는 localhost 대신 10.0.2.2
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8000');
  static const aiBaseUrl = String.fromEnvironment('AI_BASE_URL', defaultValue: 'http://localhost:8001');
  static const routeBaseUrl = String.fromEnvironment('ROUTE_BASE_URL', defaultValue: 'http://localhost:8002');
  /// 로컬 개발 전용: 값을 주면 Firebase 토큰 대신 'Bearer dev:<값>'으로 서버를 부른다 (서버 API_AUTH_MODE=dev 일 때만 통함).
  /// 로컬에 firebase-admin 키가 없어 로그인 화면을 못 볼 때 쓴다. 배포 빌드(deploy/push_web.sh)에는 넣지 않는다.
  /// 예: --dart-define=DEV_UID=responder-demo (uid가 responder로 시작하면 서버가 방재단 역할로 본다)
  static const devUid = String.fromEnvironment('DEV_UID');

  /// 배포 빌드 표시 (deploy/push_web.sh: 커밋·빌드 시각). 브라우저가 예전 앱을 쓰는지 화면에서 바로 확인하려고 (2026-10-08)
  static const build = String.fromEnvironment('APP_BUILD', defaultValue: '개발 빌드');
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static AppMode get mode => _mode == 'remote' ? AppMode.remote : AppMode.mock;
  static bool get isRemote => mode == AppMode.remote;
  /// 화면에 붙이는 데이터 출처 표기
  static String get dataLabel => isRemote ? '실시간 데이터' : '예시 데이터';
  static bool get hasFirebaseConfig => firebaseApiKey.isNotEmpty && firebaseAppId.isNotEmpty && firebaseProjectId.isNotEmpty && firebaseSenderId.isNotEmpty;
}

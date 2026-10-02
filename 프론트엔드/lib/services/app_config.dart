enum AppMode { mock, remote }

class AppConfig {
  static const _mode = String.fromEnvironment('APP_MODE', defaultValue: 'mock');
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static AppMode get mode => _mode == 'remote' ? AppMode.remote : AppMode.mock;
  static bool get hasFirebaseConfig => firebaseApiKey.isNotEmpty && firebaseAppId.isNotEmpty && firebaseProjectId.isNotEmpty && firebaseSenderId.isNotEmpty;
}

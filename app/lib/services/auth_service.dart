import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'app_config.dart';

class AuthStateInfo {
  const AuthStateInfo({required this.isMock, this.userId, this.token});
  final bool isMock;
  final String? userId, token;
}

class AuthService {
  Future<AuthStateInfo> initialize() async {
    if (!AppConfig.hasFirebaseConfig) return const AuthStateInfo(isMock: true, userId: 'mock-guryongpo-user');
    await Firebase.initializeApp(options: FirebaseOptions(apiKey: AppConfig.firebaseApiKey, appId: AppConfig.firebaseAppId, messagingSenderId: AppConfig.firebaseSenderId, projectId: AppConfig.firebaseProjectId));
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user;
    return AuthStateInfo(isMock: false, userId: user?.uid, token: await user?.getIdToken());
  }
  Future<String?> token() async => Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser?.getIdToken();
}

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import '../firebase_options.dart';
import 'account_sync.dart';
import 'app_config.dart';

class AuthStateInfo {
  const AuthStateInfo({required this.isMock, this.userId, this.token});
  final bool isMock;
  final String? userId, token;
}

/// 지금 로그인한 계정 (화면 표시용)
class AccountInfo {
  const AccountInfo({required this.uid, required this.isAnonymous, this.email, this.provider});
  final String uid;
  final bool isAnonymous;
  final String? email;
  /// 'google.com' · 'password' · null(익명)
  final String? provider;
  String get providerLabel => switch (provider) { 'google.com' => 'Google', 'password' => '이메일', _ => '로그인 안 함' };
}

/// 로그인 실패를 화면에 보여 줄 한국어 문구로
class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Firebase 오류 코드 → 사용자 문구
String authErrorMessage(String code) => switch (code) {
      'invalid-email' => '이메일 형식이 올바르지 않습니다.',
      'weak-password' => '비밀번호는 6자 이상으로 정해 주세요.',
      'email-already-in-use' || 'credential-already-in-use' => '이미 가입된 이메일입니다. 로그인해 주세요.',
      'user-not-found' || 'wrong-password' || 'invalid-credential' || 'INVALID_LOGIN_CREDENTIALS' =>
        '이메일 또는 비밀번호가 맞지 않습니다.',
      'too-many-requests' => '시도가 너무 많습니다. 잠시 뒤 다시 해 주세요.',
      'popup-closed-by-user' || 'cancelled-popup-request' || 'web-context-canceled' || 'canceled' =>
        '로그인을 취소했습니다.',
      'popup-blocked' => '브라우저가 로그인 창을 막았습니다. 팝업을 허용해 주세요.',
      'network-request-failed' => '인터넷 연결을 확인해 주세요.',
      'operation-not-allowed' => '이 로그인 방식이 아직 켜져 있지 않습니다. 관리자에게 알려 주세요.',
      'requires-recent-login' => '보안을 위해 다시 로그인해 주세요.',
      _ => '로그인하지 못했습니다. 다시 시도해 주세요. ($code)',
    };

/// Firebase 로그인 (Google·이메일). **로그인해야 앱을 쓴다** — 로그인 안 하면 로그인 화면만 (main.dart 라우터, 사용자 결정 2026-10-08).
/// 익명 계정은 만들지 않고, 예전에 만들어진 익명 세션은 시작할 때 로그아웃한다. 목업 모드(Firebase 없음)는 로그인 없이.
class AuthService {
  /// Firebase 설정: --dart-define 값이 있으면 그것(예전 방식), 없으면 firebase_options.dart
  static FirebaseOptions? get firebaseOptions => AppConfig.hasFirebaseConfig
      ? FirebaseOptions(apiKey: AppConfig.firebaseApiKey, appId: AppConfig.firebaseAppId,
          messagingSenderId: AppConfig.firebaseSenderId, projectId: AppConfig.firebaseProjectId,
          authDomain: DefaultFirebaseOptions.web.authDomain)
      : DefaultFirebaseOptions.currentPlatform;

  /// 목업 모드(APP_MODE=mock)이거나 이 플랫폼 설정이 없으면 Firebase를 쓰지 않는다
  static bool get enabled => AppConfig.isRemote && firebaseOptions != null;
  static bool get ready => Firebase.apps.isNotEmpty;

  /// 로그인·로그아웃 때마다 오른다 — 라우터(refreshListenable)가 듣고 로그인 화면으로 보내거나 돌려보낸다
  static final changes = ValueNotifier<int>(0);
  static bool _listening = false;

  /// Google·이메일로 로그인했는지 (익명 제외). 정보 저장 기능을 여는 기준. 로컬 개발 dev uid 도 로그인으로 본다
  static bool get signedIn {
    if (AppConfig.devUid.isNotEmpty) return true;
    final u = ready ? FirebaseAuth.instance.currentUser : null;
    return u != null && !u.isAnonymous;
  }

  Future<AuthStateInfo> initialize() async {
    if (!enabled) return const AuthStateInfo(isMock: true, userId: 'mock-guryongpo-user');
    try {
      if (!ready) await Firebase.initializeApp(options: firebaseOptions);
      final auth = FirebaseAuth.instance;
      if (!_listening) {
        _listening = true;
        auth.userChanges().listen((_) => changes.value++);
      }
      // 웹은 저장된 로그인을 되살리는 데 잠깐 걸린다 — currentUser 가 비어 있다고 바로 익명 로그인하면
      // 새로고침할 때마다 새 익명 계정이 생기고 Google·이메일 로그인이 풀린다 (2026-10-05 수정)
      final restored = auth.currentUser ??
          await auth.authStateChanges().first.timeout(const Duration(seconds: 5), onTimeout: () => null);
      // 익명 계정을 만들지 않는다. 예전에 자동으로 만든 익명 세션이 남아 있으면 로그아웃 (서버 기록은 그대로)
      if (restored != null && restored.isAnonymous) await auth.signOut();
      if (!signedIn) return const AuthStateInfo(isMock: false);
      final user = auth.currentUser;
      await syncServerUser();
      await AccountSync.instance.pullOrPush(); // 계정에 저장된 앱 정보 내려받기 (없으면 기기 값 올리기)
      return AuthStateInfo(isMock: false, userId: user?.uid, token: await user?.getIdToken());
    } catch (_) {
      // 오프라인 등으로 로그인 실패 — 재난 정보는 토큰 없이도 보이게 계속 진행
      return const AuthStateInfo(isMock: false);
    }
  }

  Future<String?> token() async {
    if (AppConfig.devUid.isNotEmpty) return 'dev:${AppConfig.devUid}'; // 로컬 개발 전용 (AppConfig.devUid)
    return signedIn ? FirebaseAuth.instance.currentUser?.getIdToken() : null;
  }

  /// 로그인한 Firebase uid (없으면 null — 목업·초기화 전)
  String? get uid => signedIn ? FirebaseAuth.instance.currentUser?.uid : null;

  /// 로그인 상태가 바뀔 때마다 (연결·로그인·로그아웃 포함)
  Stream<AccountInfo?> accountChanges() =>
      ready ? FirebaseAuth.instance.userChanges().map(_info) : Stream.value(null);

  AccountInfo? get account => ready ? _info(FirebaseAuth.instance.currentUser) : null;

  static AccountInfo? _info(User? u) {
    if (u == null) return null;
    final p = u.providerData.map((d) => d.providerId).where((id) => id != 'firebase').toList();
    return AccountInfo(uid: u.uid, isAnonymous: u.isAnonymous, email: u.email,
        provider: p.contains('google.com') ? 'google.com' : (p.isNotEmpty ? p.first : null));
  }

  /// Google 로그인. 익명이면 지금 계정에 연결, 이미 다른 계정에 묶인 Google이면 그 계정으로 로그인
  Future<void> signInWithGoogle() => _run(() async {
        final auth = FirebaseAuth.instance;
        final provider = GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'});
        final user = auth.currentUser;
        if (user != null && user.isAnonymous) {
          try {
            kIsWeb ? await user.linkWithPopup(provider) : await user.linkWithProvider(provider);
            return;
          } on FirebaseAuthException catch (e) {
            if (e.code != 'credential-already-in-use') rethrow;
            // 이미 가입된 Google 계정 → 그 계정으로 로그인 (지금 익명 기록은 이 기기에만 남는다)
            if (e.credential != null) {
              await auth.signInWithCredential(e.credential!);
              return;
            }
          }
        }
        kIsWeb ? await auth.signInWithPopup(provider) : await auth.signInWithProvider(provider);
      });

  /// 이메일 가입: 익명 계정에 이메일·비밀번호를 연결
  Future<void> signUpWithEmail(String email, String password) => _run(() async {
        final auth = FirebaseAuth.instance;
        final cred = EmailAuthProvider.credential(email: email.trim(), password: password);
        final user = auth.currentUser;
        if (user != null && user.isAnonymous) {
          await user.linkWithCredential(cred);
        } else {
          await auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
        }
      });

  Future<void> signInWithEmail(String email, String password) =>
      _run(() => FirebaseAuth.instance.signInWithEmailAndPassword(email: email.trim(), password: password));

  Future<void> sendPasswordReset(String email) =>
      _run(() => FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim()), sync: false);

  /// 로그아웃 → 계정 없이 계속 쓴다 (재난 정보·길찾기는 로그인 없이도. 익명 계정은 만들지 않는다)
  Future<void> signOut() => _run(() async {
        await AccountSync.instance.push(); // 못 올린 변경을 계정에 남기고
        await AccountSync.instance.clearLocal(); // 이 기기에서는 지운다
        await FirebaseAuth.instance.signOut();
      });

  /// Firebase 작업 실행 → 오류는 AuthFailure(한국어), 성공하면 서버 사용자 등록
  Future<void> _run(Future<void> Function() action, {bool sync = true}) async {
    if (!ready) throw const AuthFailure('로그인 기능을 쓸 수 없는 상태입니다 (Firebase 미설정).');
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(authErrorMessage(e.code));
    }
    if (sync) {
      await syncServerUser();
      await AccountSync.instance.pullOrPush();
    }
  }

  /// 서버에 사용자 등록 (POST /api/v1/user, uid 기준 멱등). 실패해도 로그인은 그대로 둔다
  Future<void> syncServerUser() async {
    final t = await token();
    if (t == null) return;
    try {
      await Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl, connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10)))
          .post<Object?>('/api/v1/user', options: Options(headers: {'Authorization': 'Bearer $t'}));
    } catch (_) {}
  }
}

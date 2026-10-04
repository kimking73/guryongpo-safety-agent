// Firebase 클라이언트 설정 (웹·안드로이드·iOS). flutterfire configure 결과와 같은 형식.
// 비밀 값이 아니다 — 앱에 그대로 들어가 배포되는 공개 식별자이고, 승인된 도메인·앱 ID(패키지·번들)로 보호된다.
// 다시 만들 때: Firebase 콘솔 → 프로젝트 설정 → 내 앱에서 값 확인, 또는 `flutterfire configure`.
// 프로젝트 guryong-guardian-0924, 앱 ID kr.guryong.guardian
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  /// 지원하지 않는 플랫폼(데스크톱)이면 null → 앱은 Firebase 없이(목업 로그인) 동작
  static FirebaseOptions? get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        return null;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
        apiKey: 'AIzaSyD8uEJlUvVnckMpEKl0ZAwmWaadH5QeQko',
        appId: '1:959823576613:web:639f5e1d38b255d031c9cc',
        messagingSenderId: '959823576613',
        projectId: 'guryong-guardian-0924',
        authDomain: 'guryong-guardian-0924.firebaseapp.com',
        storageBucket: 'guryong-guardian-0924.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
        apiKey: 'AIzaSyBBE6zaTgBfkB1KFHOcBzY5AFgonIq92f0',
        appId: '1:959823576613:android:4f943ec13b89e13b31c9cc',
        messagingSenderId: '959823576613',
        projectId: 'guryong-guardian-0924',
        storageBucket: 'guryong-guardian-0924.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
        apiKey: 'AIzaSyDANvwpzkK65U0NSsJMNl9O4s0Lmu9qGJo',
        appId: '1:959823576613:ios:000ea056e57a3a3731c9cc',
        messagingSenderId: '959823576613',
        projectId: 'guryong-guardian-0924',
        storageBucket: 'guryong-guardian-0924.firebasestorage.app',
        iosClientId: '959823576613-ib7ddu7h17g71k3m487jr3liugpulfmk.apps.googleusercontent.com',
        iosBundleId: 'kr.guryong.guardian',
  );
}

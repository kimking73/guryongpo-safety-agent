import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/auth_service.dart';

void main() {
  test('Firebase 오류 코드 → 한국어 문구', () {
    expect(authErrorMessage('invalid-email'), contains('이메일 형식'));
    expect(authErrorMessage('weak-password'), contains('6자'));
    expect(authErrorMessage('email-already-in-use'), contains('이미 가입'));
    expect(authErrorMessage('credential-already-in-use'), contains('이미 가입'));
    expect(authErrorMessage('invalid-credential'), contains('맞지 않습니다'));
    expect(authErrorMessage('popup-closed-by-user'), contains('취소'));
    expect(authErrorMessage('operation-not-allowed'), contains('켜져 있지 않습니다'));
    expect(authErrorMessage('something-new'), contains('something-new'));
  });

  test('계정 제공자 표시', () {
    expect(const AccountInfo(uid: 'a', isAnonymous: true).providerLabel, '익명');
    expect(const AccountInfo(uid: 'a', isAnonymous: false, provider: 'google.com').providerLabel, 'Google');
    expect(const AccountInfo(uid: 'a', isAnonymous: false, provider: 'password').providerLabel, '이메일');
  });

  test('예시 데이터 모드(APP_MODE 없음)에서는 Firebase를 쓰지 않는다', () async {
    expect(AuthService.enabled, isFalse);
    final s = await AuthService().initialize();
    expect(s.isMock, isTrue);
    expect(AuthService().uid, isNull);
  });
}

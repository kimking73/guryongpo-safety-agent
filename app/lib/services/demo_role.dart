import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'demo_mode.dart';
import 'demo_role_store.dart';

/// 시연 역할 (2026-10-12 사용자 요청): 분할 화면 시연에서 한쪽 창은 사용자(주민), 다른 쪽 창은 방재단원.
/// 창마다 따로 저장한다(웹 sessionStorage) — 기기 기록(localStorage)은 두 창이 같이 쓰므로 거기 두면 두 창이 같은 역할이 된다
enum DemoRole { user, responder }

extension DemoRoleLabel on DemoRole {
  String get label => this == DemoRole.user ? '사용자 모드' : '방재단원 모드';
}

class DemoRoleNotifier extends StateNotifier<DemoRole> {
  /// [initial] = 테스트용 시작 역할 (창 저장소를 건드리지 않는다)
  DemoRoleNotifier([DemoRole? initial])
      : super(initial ?? (readWindowValue(_key) == 'responder' ? DemoRole.responder : DemoRole.user));
  static const _key = 'demo_role_v1';

  void set(DemoRole r) {
    state = r;
    writeWindowValue(_key, r.name);
  }
}

final demoRoleProvider = StateNotifierProvider<DemoRoleNotifier, DemoRole>((_) => DemoRoleNotifier());

/// 이 창이 시연 방재단원 화면인지 (시연 모드 + 방재단원 모드)
final demoResponderViewProvider =
    Provider<bool>((ref) => ref.watch(showDemoProvider) && ref.watch(demoRoleProvider) == DemoRole.responder);

/// 이 창이 시연 사용자(주민) 화면인지 (시연 모드 + 사용자 모드)
final demoUserViewProvider =
    Provider<bool>((ref) => ref.watch(showDemoProvider) && ref.watch(demoRoleProvider) == DemoRole.user);

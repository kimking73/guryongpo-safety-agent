import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../live_screens.dart' show meProvider;
import '../patrol_screens.dart' show isPatrolRole;
import 'app_config.dart';
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

/// 방재단원 모드를 쓸 수 있는 계정인지 (2026-10-12 사용자 요청: 방재단 화면은 전용 코드를 받은 사람만, 시연 모드도).
/// 서버 연결이면 서버 계정 역할이 방재단·관리자여야 한다 = '방재단 로그인'에서 전용 코드(초대 코드)를 넣은 계정.
/// 서버 없이 실행(APP_MODE=mock, 개발용)은 확인할 곳이 없어 그대로 연다
final responderUnlockedProvider = Provider<bool>(
    (ref) => !AppConfig.isRemote || isPatrolRole('${ref.watch(meProvider).valueOrNull?['role'] ?? ''}'));

/// 이 창이 시연 방재단원 화면인지 (시연 모드 + 방재단원 모드 + 코드로 로그인한 계정)
final demoResponderViewProvider = Provider<bool>((ref) =>
    ref.watch(showDemoProvider) && ref.watch(demoRoleProvider) == DemoRole.responder && ref.watch(responderUnlockedProvider));

/// 이 창이 시연 사용자(주민) 화면인지 (시연 모드 + 방재단원 화면이 아님 — 방재단원 모드를 골랐어도 코드 로그인 전이면 사용자)
final demoUserViewProvider =
    Provider<bool>((ref) => ref.watch(showDemoProvider) && !ref.watch(demoResponderViewProvider));

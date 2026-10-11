import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/demo_relay.dart';
import 'package:guryongpo_safety/services/demo_role.dart';
import 'package:guryongpo_safety/services/prototype_safety_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI 서버 시연 방(ai/guardian_ai/demo_room.py)과 같은 규칙의 가짜: 보낸 칸만 바꾸고 바뀔 때마다 version + 1
class _FakeRoom {
  final room = <String, dynamic>{'alert_active': false, 'response': null, 'needs': <String>[], 'dispatch': null, 'version': 0};

  Dio dio() => Dio(BaseOptions(baseUrl: 'http://fake'))
    ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      if (o.method == 'PUT') {
        (o.data as Map).forEach((k, v) => room[k as String] = v);
        room['version'] = (room['version'] as int) + 1;
      }
      h.resolve(Response(requestOptions: o, statusCode: 200, data: Map<String, dynamic>.from(room)));
    }));
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // 2026-10-12 사용자 요청: 각기 다른 계정으로 로그인해도 사용자 모드 ↔ 방재단원 모드 알림이 오가게
  test('사용자 모드는 응답을 보내고 출동 기록을 받는다 · 방재단원 모드는 응답을 받는다', () async {
    SharedPreferences.setMockInitialValues({'optional_profile': '{"지체 지원":"지원 필요"}'});
    final server = _FakeRoom();
    final user = PrototypeSafetyController();
    await user.load();
    final userRelay = DemoRelay(code: 'K7Q2', role: DemoRole.user, store: user, status: (_) {}, dio: server.dio())..start();
    await user.startDemoAlert(PrototypeSafetyController.prototypeAlertKey);
    await user.respond(PrototypeSafetyController.prototypeAlertKey, EvacuationResponseStatus.needHelp);
    await _settle();
    expect(server.room['alert_active'], true);
    expect(server.room['response'], 'need_help');
    expect(server.room['needs'], ['mobility_limited']);   // '내 정보' 장애 유형만 (이름·주소는 보내지 않음)

    // 다른 계정의 방재단원 창: 방에서 주민 응답·장애 유형을 받는다
    final crew = PrototypeSafetyController();
    final crewRelay = DemoRelay(code: 'K7Q2', role: DemoRole.responder, store: crew, status: (_) {}, dio: server.dio())..start();
    await _settle();
    expect(crew.demoAlertActive, isTrue);
    expect(crew.responseFor(PrototypeSafetyController.prototypeAlertKey), EvacuationResponseStatus.needHelp);
    expect(crew.residentNeeds, ['mobility_limited']);

    // 방재단원이 [실제 출발] → 방에 출동 기록 → 사용자 창이 받는다 (여기선 방에 직접 써서 다른 기기처럼)
    server.room['dispatch'] = {
      'departed_at': '2026-10-12T10:00:00.000',
      'eta': '2026-10-12T10:06:00.000',
      'responder': '시연 방재단원',
      'stage': 'en_route'
    };
    server.room['version'] = (server.room['version'] as int) + 1;
    await userRelay.poll();
    expect(user.demoDispatch?.eta, DateTime.parse('2026-10-12T10:06:00.000'));

    // 사용자가 새 시연 경보를 시작하면 방의 지난 출동 기록도 지운다
    await user.startDemoAlert(PrototypeSafetyController.prototypeAlertKey);
    await _settle();
    expect(server.room['dispatch'], isNull);
    expect(server.room['response'], isNull);
    userRelay.stop();
    crewRelay.stop();
  });
}

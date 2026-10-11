// 디자인 (2026-10-08 개편, 2026-10-11 웹·휴대폰 한 벌): 날씨 6칸 값 뽑기, 휴대폰 폭 하단 탭, 첫 화면 순서
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/onboarding.dart' show Onboarding;
import 'package:guryongpo_safety/services/demo_role.dart';
import 'package:guryongpo_safety/services/prototype_safety_store.dart';
import 'package:guryongpo_safety/prototype_safety_screens.dart' show prototypeEvacuationAlertId;
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/ui/gk_widgets.dart' show GkSideNav, GkEmergencyCall;
import 'package:guryongpo_safety/weather_section.dart';

void main() {
  test('서버 단계 → 디자인 단계', () {
    expect(levelLabel('normal'), '좋음');
    expect(levelLabel('watch'), '관심');
    expect(levelLabel('advisory'), '주의');
    expect(levelLabel('warning'), '경보');
    expect(levelLabel('critical'), '경보');
    expect(levelLabel(null), '');
  });

  test('날씨 6칸: 시연은 예시 값, 실측은 서버 위젯 값 · 없으면 자료 없음', () {
    expect(weatherItems(null, demo: true).map((w) => w.key),
        ['wind', 'rain', 'wave', 'river', 'dust', 'uv']);

    final live = weatherItems({
      'widgets': [
        {
          'type': 'wind',
          'data': {
            'value': 21.3, 'wind_gust': 30, 'wind_dir': 45, 'level': 'warning', 'station_name': '구룡포', 'observed_at': null,
            'series': [
              {'t': '2026-10-11T10:10:00+09:00', 'v': 12.0},
              {'t': '2026-10-11T10:50:00+09:00', 'v': 9.5},
              {'t': '2026-10-11T11:20:00+09:00', 'v': 21.3},
            ]
          }
        },
        {
          'type': 'water_level',
          'data': {
            'stations': [
              {'station_name': 'A', 'value': 80, 'unit': 'cm', 'level': 'normal'},
              {'station_name': 'B', 'value': 140, 'unit': 'cm', 'level': 'advisory'},
            ]
          }
        },
        {
          'type': 'life_safety',
          'data': {
            'items': [
              {'hazard': 'fine_dust', 'value': 18, 'level': 'normal'},
              {'hazard': 'ultrafine_dust', 'value': 9, 'level': 'watch'},
              {'hazard': 'uv', 'value': 1, 'level': 'normal', 'label': '자외선'},
            ]
          }
        },
        {'type': 'rain', 'data': {'available': false, 'reason': '관측소 점검 중'}},
      ]
    }, demo: false);
    final byKey = {for (final w in live) w.key: w};
    expect(byKey['wind']!.value, '21.3');
    expect(byKey['wind']!.level, '경보');
    expect(byKey['wind']!.note, contains('북동풍'));
    // 눌렀을 때 표: 시각별 최대, 최근 것부터 (값만 본다 — 시각 글자는 기기 시간대에 따라 다르다)
    expect(byKey['wind']!.table.map((r) => r.$2), ['21.3', '12']);
    expect(byKey['river']!.table.first, ('B', '140cm · 주의'));
    expect(byKey['dust']!.table, isEmpty);
    // 칸에 바로 보이는 권고 문구
    expect(byKey['wind']!.description, contains('외출을 삼가세요'));
    expect(byKey['river']!.value, '140'); // 가장 높은 단계 지점
    expect(byKey['river']!.level, '주의');
    expect(byKey['dust']!.value, '18 / 9');
    expect(byKey['dust']!.level, '관심'); // 둘 중 나쁜 쪽
    expect(byKey['uv']!.level, '좋음');
    expect(byKey['rain']!.value, '-');
    expect(byKey['rain']!.levelText, '자료 없음');
    expect(byKey['rain']!.note, '관측소 점검 중');
    expect(byKey['wave']!.levelText, '자료 없음');
  });

  testWidgets('휴대폰 폭: 웹 화면 그대로 + 하단 탭(시연 방재단원 모드면 방재단 현황까지 4개) · 머리줄 119', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({});
    Onboarding.reset();
    Onboarding.setConsented();
    Onboarding.setDone();
    appBooted = false;
    appRouter.go('/');
    await t.pumpWidget(ProviderScope(
        overrides: [demoRoleProvider.overrideWith((_) => DemoRoleNotifier(DemoRole.responder))], child: const GuryongpoApp()));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.state.matchedLocation, '/');
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(GkSideNav), findsNothing);
    final bar = find.byType(NavigationBar);
    for (final label in ['대시보드', 'AI 대화창', '방재단 현황', '사용자 정보']) {
      expect(find.descendant(of: bar, matching: find.text(label)), findsOneWidget);
    }
    expect(find.byType(GkEmergencyCall), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  // 2026-10-12 사용자 요청: 시연 모드를 사용자 모드·방재단원 모드로 (분할 화면 시연)
  Future<PrototypeSafetyController> pumpShell(WidgetTester t, DemoRole role) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({});
    final store = PrototypeSafetyController();
    await store.load();
    Onboarding.reset();
    Onboarding.setConsented();
    Onboarding.setDone();
    appBooted = false;
    appRouter.go('/');
    await t.pumpWidget(ProviderScope(overrides: [
      demoRoleProvider.overrideWith((_) => DemoRoleNotifier(role)),
      prototypeSafetyProvider.overrideWith((_) => store),
    ], child: const GuryongpoApp()));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    return store;
  }

  testWidgets('시연 사용자 모드: 방재단 현황 메뉴가 없고, 주민 응답 알림도 띄우지 않는다', (t) async {
    final store = await pumpShell(t, DemoRole.user);
    final bar = find.byType(NavigationBar);
    expect(find.descendant(of: bar, matching: find.text('방재단 현황')), findsNothing);
    expect(find.descendant(of: bar, matching: find.text('사용자 정보')), findsOneWidget);
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('주민 응답이 왔어요'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('시연 방재단원 모드: 다른 창의 주민이 응답하면 "주민 응답이 왔어요" 알림', (t) async {
    final store = await pumpShell(t, DemoRole.responder);
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.textContaining('주민 응답이 왔어요 · 앱 사용자 (시연 주민) · 도움 필요'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('처음 들어온 기기: 동의 화면부터 → 두 동의 후 다음 → 내 정보(2/2)', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    // 전에 이 기기에서 동의·내 정보를 끝냈어도(옛 저장값) 앱을 새로 열면 처음 화면부터 (2026-10-10 사용자 결정)
    SharedPreferences.setMockInitialValues({'onboarding_consent_v1': true, 'onboarding_done_v1': true});
    Onboarding.reset();
    appBooted = false;
    appRouter.go('/');
    await t.pumpWidget(const ProviderScope(child: GuryongpoApp()));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('구룡포 안전 비서'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(appRouter.state.matchedLocation, '/login');
    // 동의 없이 다음 → 그대로
    await t.tap(find.text('다음'));
    await t.pump(const Duration(milliseconds: 300));
    expect(appRouter.state.matchedLocation, '/login');
    await t.tap(find.text('위치 정보 수집 동의', findRichText: true));
    await t.tap(find.text('장애 정보(시각·청각·지체) 민감정보 수집 동의', findRichText: true));
    await t.pump();
    await t.ensureVisible(find.text('다음'));
    await t.tap(find.text('다음'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.state.matchedLocation, '/setup');
    expect(find.text('2 / 2'), findsOneWidget);
    expect(Onboarding.consented, isTrue);
    // 내 정보(2/2)를 끝내야 대시보드
    // (화면 맨 아래에 걸려 탭이 빗나가므로 버튼 동작을 직접 부른다 — 확인할 것은 화면 순서)
    t.widget<TextButton>(find.widgetWithText(TextButton, '나중에 입력할게요')).onPressed!();
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.state.matchedLocation, '/');
    // 앱을 다시 열면(새로고침) 다시 동의 화면부터
    Onboarding.reset();
    appBooted = false;
    appRouter.go('/');
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.state.matchedLocation, '/login');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('동의만 하고 내 정보를 끝내지 않았으면 대시보드 대신 내 정보(2/2)부터', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({});
    Onboarding.reset();
    Onboarding.setConsented();
    appBooted = false;
    appRouter.go('/');
    await t.pumpWidget(const ProviderScope(child: GuryongpoApp()));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.state.matchedLocation, '/setup');
    await t.ensureVisible(find.text('나중에 입력할게요'));
    await t.pump();
    await t.tap(find.text('나중에 입력할게요'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.state.matchedLocation, '/');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}

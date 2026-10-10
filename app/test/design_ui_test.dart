// 디자인 개편 (2026-10-08): 날씨 6칸 값 뽑기, 탭바 3/4개, AI 추천 질문 → 덧붙일 카드
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/mobile/onboarding.dart' show Onboarding;
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/mobile/ai_chat.dart';
import 'package:guryongpo_safety/mobile/app_shell.dart';
import 'package:guryongpo_safety/mobile/dashboard_cards.dart';

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
          'data': {'value': 21.3, 'wind_gust': 30, 'wind_dir': 45, 'level': 'warning', 'station_name': '구룡포', 'observed_at': null}
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

  test('추천 질문 → 덧붙일 카드 (태풍·지원 탭을 AI 대화창으로 옮김)', () {
    expect(cardFor('태풍 대비 체크리스트 알려줘'), 'checklist');
    expect(cardFor('지금 태풍 정보 알려줘'), 'typhoon');
    expect(cardFor('재난 후 내가 받을 수 있는 보험이 있는지 알려줘'), 'support');
    expect(cardFor('가까운 대피소는 어디야?'), isNull);
  });

  testWidgets('하단 탭: 기본 3개, 방재단이면 방재단 현황까지 4개', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(bottomNavigationBar: DsTabBar(current: '/', responder: false))));
    expect(find.text('대시보드'), findsOneWidget);
    expect(find.text('AI 대화창'), findsOneWidget);
    expect(find.text('사용자'), findsOneWidget);
    expect(find.text('방재단 현황'), findsNothing);

    await t.pumpWidget(const MaterialApp(home: Scaffold(bottomNavigationBar: DsTabBar(current: '/team', responder: true))));
    expect(find.text('방재단 현황'), findsOneWidget);
  });

  test('대피 현황 칩 색·글자', () {
    expect(evacStyle(null).label, '응답 전');
    expect(evacStyle('evacuating').label, '대피 중');
    expect(evacStyle('evacuated').label, '대피 완료');
    expect(evacStyle('need_help').label, '도움 필요');
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

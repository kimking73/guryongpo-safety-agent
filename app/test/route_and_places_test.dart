// AI 답의 경로 → 지도, 등록 장소 저장 → AI 요청 profile, 보행 불편 → 노약자 경로
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/disaster_center.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/mobile/onboarding.dart' show Onboarding;
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/origin_picker.dart' show originLabelProvider;
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/services/account_service.dart';
import 'package:guryongpo_safety/ui/map_menu.dart';

const _chat = {
  'conversation_id': 'c1',
  'answer': '구룡포항까지 성인 경로로 902m, 도보 12분입니다.',
  'route': {
    'destination': {
      'name': '구룡포항',
      'lat': 35.9905,
      'lon': 129.556,
      'kind': 'place'
    },
    'profile': 'adult',
    'distance_m': 902,
    'duration_s': 700,
    'avoided': ['flood-67'],
    'still_inside': [],
    'hazards_ok': true,
    'geometry': '_p~iF~ps|U_ulLnnqC',
  },
};

/// 목업 저장소 + AI 답에 경로가 오는 가짜
class RouteAnsweringRepo extends MockSafetyRepository {
  @override
  Future<ChatAnswer> ask(
      String question, UserMode userMode, LatLng origin) async {
    final answer = chatAnswerFromJson(_chat);
    final route = answer.route!;
    return ChatAnswer(
      answer.text,
      route: SafetyRoute(
        shelterId: route.shelterId,
        routeType: RouteType.nearest,
        polylinePoints: route.polylinePoints,
        distanceMeters: route.distanceMeters,
        estimatedMinutes: route.estimatedMinutes,
        riskAvoidanceSummary: route.riskAvoidanceSummary,
        avoided: route.avoided,
        stillInside: route.stillInside,
      ),
      destinationName: answer.destinationName,
      destinationKind: answer.destinationKind,
      destinationPos: answer.destinationPos,
    );
  }
}

void main() {
  // 이 파일은 웹 화면(web-prototype 디자인)의 대시보드를 본다 — 테스트(VM)는 kIsWeb=false 라 기본이 휴대폰 화면
  setUp(() => useMobileUi = false);
  tearDown(() => useMobileUi = !kIsWeb);
  test('채팅 응답의 경로 → 지도용 경로·목적지', () {
    final a = chatAnswerFromJson(_chat, names: {'flood-67': '침수 경보'});
    expect(a.text, contains('902m'));
    expect(a.route!.polylinePoints, hasLength(2));
    expect(a.route!.riskAvoidanceSummary, contains('침수 경보'));
    expect((a.destinationName, a.destinationKind), ('구룡포항', 'place'));
    expect(a.destinationPos, const LatLng(35.9905, 129.556));
    expect(chatAnswerFromJson({'answer': '안녕하세요'}).route, isNull);
    expect(a.route!.seaPoints, isEmpty);
  });

  test('바다 위에서 받은 AI 경로: 바닷길 점선 + 항구부터 도보 경로', () {
    final route = Map<String, dynamic>.from(_chat['route'] as Map);
    final sea = {
      'port_name': '구룡포항', 'berth': {'lat': 35.99, 'lon': 129.558}, 'land_point': {'lat': 35.99, 'lon': 129.557},
      'distance_m': 1830, 'straight_m': 1620, 'bearing_deg': 250.0, 'bearing_label': '서남서쪽',
      'path': '_p~iF~ps|U_ulLnnqC', 'path_found': true,
    };
    final a = chatAnswerFromJson({..._chat, 'route': {...route, 'sea': sea}});
    expect(a.route!.seaPoints, hasLength(2));
    expect(a.route!.riskAvoidanceSummary, contains('서남서쪽의 구룡포항까지 바닷길 1830m'));
    final lost = chatAnswerFromJson({..._chat, 'route': {...route, 'sea': {...sea, 'path_found': false}}});
    expect(lost.route!.seaPoints, isEmpty);
    expect(lost.route!.riskAvoidanceSummary, contains('직선 1620m'));
  });

  test('등록 장소 저장·삭제와 AI 요청 profile', () async {
    SharedPreferences.setMockInitialValues({});
    final acc = AccountService();
    await acc.addPlace(const SavedPlace(
        id: '1', name: '우리집', type: '집', position: LatLng(35.99, 129.55)));
    await acc.addPlace(const SavedPlace(
        id: '2', name: '수산 작업장', type: '직장', position: LatLng(35.98, 129.56)));
    await acc.addPlace(const SavedPlace(
        id: '3',
        name: '교회',
        type: '기타',
        position: LatLng(35.97, 129.54),
        alert: false));
    final places = await acc.places();
    expect(places.map((p) => p.name), ['우리집', '수산 작업장', '교회']);
    expect(placesForProfile(places), {
      'home': {'lat': 35.99, 'lon': 129.55, 'label': '집'},
      'frequent_places': [
        {'lat': 35.98, 'lon': 129.56, 'label': '직장'},
        {'lat': 35.97, 'lon': 129.54, 'label': '교회'},
      ],
    });
    await acc.removePlace('2');
    expect((await acc.places()).map((p) => p.id), ['1', '3']);
    expect(placesForProfile(const []), isEmpty);
  });

  test('노약자 경로 = 65세 이상 또는 휠체어 (보행 능력은 더 묻지 않음, 2026-10-09)', () {
    expect(routeProfileFor(70, '도보'), 'elderly');
    expect(routeProfileFor(40, '휠체어'), 'elderly');
    expect(routeProfileFor(40, '도보'), 'adult');
  });

  test('목업 AI가 대피소·의료시설 경로와 가까운/안전 전략을 연결한다', () async {
    final repo = MockSafetyRepository();
    final shelter =
        await repo.ask('가까운 대피소까지 경로', UserMode.user, originFor(UserMode.user));
    expect(shelter.destinationKind, 'shelter');
    expect(shelter.route?.routeType, RouteType.nearest);
    final medical =
        await repo.ask('의료시설까지 안전 경로', UserMode.user, originFor(UserMode.user));
    expect(medical.destinationKind, 'medical');
    expect(medical.destinationName, contains('의료지원소'));
    expect(medical.route?.routeType, RouteType.safest);
  });

  testWidgets('AI 답의 "지도에서 경로 보기" → 대시보드 지도가 그 경로를 그린다', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // 테스트에서는 지도 타일 다운로드가 막혀 이미지 오류가 난다 — 그것만 무시하고 나머지 오류는 그대로 실패로 본다
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues(
        {'profile_setup_complete': true});
    Onboarding.setConsented();
    Onboarding.setDone();
    appRouter.go('/');
    final container = ProviderContainer(
        overrides: [repo.overrideWithValue(RouteAnsweringRepo())]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
        container: container, child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.widgetWithText(MapMenuButton, '경로 안내'), findsOneWidget);
    expect(find.text('AI 대화창'), findsWidgets);
    await t.tap(find.text('AI 대화창').first);
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final chip = find.text('지금 침수 위험이 있어?');
    await t.ensureVisible(chip.first);
    await t.tap(chip.first);
    expect(
        container
            .read(chatMessages)
            .any((m) => m.mine && m.text == '지금 침수 위험이 있어?'),
        isTrue);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    final button = find.byType(RouteButton);
    expect(button, findsOneWidget);
    await t.ensureVisible(button);
    await t.tap(find.text('지도에서 경로 보기'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(DisasterDashboard), findsOneWidget);
    expect(find.byType(RouteMap), findsNothing);
    expect(container.read(routeFacilityId), aiRouteId);
    await t.scrollUntilVisible(
      find.byTooltip('경로 안내 종료'),
      400,
      scrollable: find.descendant(
        of: find.byType(DisasterDashboard),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byTooltip('경로 안내 종료'), findsOneWidget);
    // 경로 방식은 경로 안내 한 덩어리(RouteSummaryRows) 안에서 고른다 (2026-10-10)
    expect(find.text('최단 거리'), findsOneWidget);
    await t.ensureVisible(find.byTooltip('경로 안내 종료'));
    await t.pump();
    await t.tap(find.byTooltip('경로 안내 종료'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DisasterDashboard), findsOneWidget);
    expect(find.text('경로 보기'), findsOneWidget);
    expect(
        container
            .read(chatMessages)
            .any((m) => m.mine && m.text == '지금 침수 위험이 있어?'),
        isTrue);
    appRouter.go('/ai');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('긴급 화면에서 대피소·의료시설 목록과 양쪽 경로 선택을 연다', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues(
        {'profile_setup_complete': true});
    Onboarding.setConsented();
    Onboarding.setDone();
    appRouter.go('/');
    await t.pumpWidget(ProviderScope(
        overrides: [repo.overrideWithValue(MockSafetyRepository())],
        child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    await t.tap(find.widgetWithText(MapMenuButton, '경로 안내'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    // 실내체육관은 목록과 경로 안내 줄(가까운 대피소) 두 곳에 나온다
    expect(find.text('구룡포 실내체육관 (예시)'), findsWidgets);
    expect(find.text('구룡포 의료지원소 (예시)'), findsOneWidget);
    // 경로 방식은 경로 안내 한 덩어리 안에서 하나만 고른다 (2026-10-10)
    expect(find.text('최단 거리'), findsOneWidget);
    expect(find.text('안전한 경로'), findsOneWidget);
    expect(find.text('오르막 회피'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('큰 창에서 "경로 안내"를 눌러도 지도가 멈추지 않는다 (2026-10-02 웹 오류 회귀)', (t) async {
    t.view.physicalSize = const Size(2400, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    final errors = <String>[];
    FlutterError.onError = (d) {
      if (d.library != 'image resource service')
        errors.add(d.exceptionAsString());
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues(
        {'profile_setup_complete': true});
    Onboarding.setConsented();
    Onboarding.setDone();
    appRouter.go('/');
    await t.pumpWidget(ProviderScope(
        overrides: [repo.overrideWithValue(MockSafetyRepository())],
        child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    await t.tap(find.widgetWithText(MapMenuButton, '경로 안내'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await t.tap(find.text('구룡포 실내체육관 (예시)').last);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await t.ensureVisible(find.text('안전한 경로'));
    await t.pump();
    await t.tap(find.text('안전한 경로'));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(errors.where((e) => e.contains('cameraConstraint')), isEmpty);
    expect(find.byType(DisasterDashboard), findsOneWidget);
    expect(find.byType(RouteMap), findsNothing);
    // 예전 '대피소 경로 · 이름' 머리줄은 경로 안내 한 덩어리로 합쳤다 (2026-10-10) — 경로가 열려 있으면 종료 버튼이 보인다
    expect(find.byTooltip('경로 안내 종료'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  test('경로 방식 켜고 끄기 (2026-10-11): 안전한 경로·오르막 회피는 함께 고를 수 있고, 둘 다 끄면 최단 거리', () {
    expect(routeTypeOf(safe: false, uphill: false), RouteType.nearest);
    expect(routeTypeOf(safe: true, uphill: false), RouteType.safest);
    expect(routeTypeOf(safe: true, uphill: true), RouteType.flat);
    expect(routeTypeOf(safe: false, uphill: true), RouteType.uphill);
    expect(RouteType.uphill.strategy, 'uphill'); // 경로 서버 strategy (route/guardian_route/service.py NO_AVOID)
    for (final t in RouteType.values) {
      expect(routeTypeOf(safe: t.avoidsHazards, uphill: t.avoidsUphill), t, reason: '$t');
    }
    // 목업도 오르막만 회피 경로를 준다 (가까운 경로 예시를 바탕으로)
    final r = MockSafetyRepository().exampleRoute('gym', UserMode.user, RouteType.uphill);
    expect(r.routeType, RouteType.uphill);
  });

  testWidgets('출발 5가지 (2026-10-11): 현위치·집·내 장소·GPS 선택·직접 입력, GPS 선택 → 지도를 누른 곳이 현재 위치', (t) async {
    t.view.physicalSize = const Size(1280, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({'profile_setup_complete': true});
    Onboarding.setConsented();
    Onboarding.setDone();
    appRouter.go('/');
    final container = ProviderContainer(overrides: [repo.overrideWithValue(MockSafetyRepository())]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    await t.tap(find.widgetWithText(MapMenuButton, '경로 안내'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    // 경로 안내를 열면 대피소 고르기 창이 먼저 뜬다 (기존 동작) — 닫고 시작
    Navigator.of(t.element(find.byType(BottomSheet))).pop();
    await t.pump(const Duration(milliseconds: 500));
    await t.ensureVisible(find.text('출발:'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('출발:'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    for (final l in ['현위치', '집', '내 장소', 'GPS 선택', '직접 입력']) {
      expect(find.textContaining(l), findsWidgets, reason: l);
    }
    await t.tap(find.text('GPS 선택'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    expect(container.read(mapPickMode), isTrue);
    expect(find.textContaining('지도에서 출발할 곳을 눌러 주세요'), findsWidgets);
    // 지도를 누른 것처럼
    const p = LatLng(35.9930, 129.5520);
    t.widget<DisasterDashboard>(find.byType(DisasterDashboard)).onMapPick!(p);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    expect(container.read(mapPickMode), isFalse);
    final here = container.read(userLocation);
    expect(here.position, p);
    expect(here.manual, isTrue);
    expect(container.read(originLabelProvider), 'GPS 선택 위치'); // 출발 버튼 글자
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}

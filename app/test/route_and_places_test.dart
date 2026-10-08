// AI 답의 경로 → 지도, 등록 장소 저장 → AI 요청 profile, 보행 불편 → 노약자 경로
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/disaster_center.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/services/account_service.dart';

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

  test("선택 정보 '보행 능력'을 적으면 노약자 경로", () async {
    SharedPreferences.setMockInitialValues({});
    final acc = AccountService();
    expect(await acc.walkingImpaired(), isFalse);
    await acc.saveOptionalProfile({'보행 능력': '무릎이 불편함'});
    expect(await acc.walkingImpaired(), isTrue);
    expect(routeProfileFor(40, '도보', walkingImpaired: true), 'elderly');
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

  testWidgets('AI 답의 "경로 안내 화면 보기" → 대시보드 지도 전체화면이 그 경로를 그린다', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // 테스트에서는 지도 타일 다운로드가 막혀 이미지 오류가 난다 — 그것만 무시하고 나머지 오류는 그대로 실패로 본다
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({'profile_setup_complete': true});
    appRouter.go('/');
    final container = ProviderContainer(
        overrides: [repo.overrideWithValue(RouteAnsweringRepo())]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
        container: container, child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    // 하단 탭 (디자인 개편): 대시보드 · AI 대화창 · 사용자
    expect(find.text('대시보드'), findsWidgets);
    expect(find.text('AI 대화창'), findsOneWidget);
    await t.tap(find.text('AI 대화창'));
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
    final button = find.text('경로 안내 화면 보기');
    expect(button, findsOneWidget);
    await t.ensureVisible(button);
    await t.tap(button);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(DisasterDashboard), findsOneWidget);
    expect(find.byType(RouteMap), findsNothing);
    expect(container.read(routeFacilityId), aiRouteId);
    expect(container.read(dashMapFull), isTrue);
    expect(find.byTooltip('경로 안내 종료'), findsOneWidget);
    expect(find.text('가까운 경로'), findsWidgets);
    await t.tap(find.byTooltip('경로 안내 종료'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DisasterDashboard), findsOneWidget);
    expect(find.text('대피·의료시설'), findsOneWidget);
    // 전체화면 닫기 → 카드 보기로
    await t.tap(find.byTooltip('전체화면 닫기'));
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(dashMapFull), isFalse);
    expect(find.text('최근 재난문자'), findsOneWidget);
    appRouter.go('/ai');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  Future<void> openFacilities(WidgetTester t) async {
    await t.tap(find.text('전체화면'));
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    await t.tap(find.text('대피소·의료시설 경로'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
  }

  testWidgets('지도 전체화면에서 대피소·의료시설 목록과 양쪽 경로 선택을 연다', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.library != 'image resource service') onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({'profile_setup_complete': true});
    appRouter.go('/');
    await t.pumpWidget(ProviderScope(
        overrides: [repo.overrideWithValue(MockSafetyRepository())],
        child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    await openFacilities(t);
    expect(find.text('구룡포 실내체육관 (예시)'), findsOneWidget);
    expect(find.text('구룡포 의료지원소 (예시)'), findsOneWidget);
    // 시설마다 지금 고른 경로 종류(기본 안전 경로)를 함께 보여 준다
    expect(find.textContaining('안전 경로'), findsWidgets);
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
    SharedPreferences.setMockInitialValues({'profile_setup_complete': true});
    appRouter.go('/');
    await t.pumpWidget(ProviderScope(
        overrides: [repo.overrideWithValue(MockSafetyRepository())],
        child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    await openFacilities(t);
    await t.tap(find.text('구룡포 실내체육관 (예시)'));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(errors.where((e) => e.contains('cameraConstraint')), isEmpty);
    expect(find.byType(DisasterDashboard), findsOneWidget);
    expect(find.byType(RouteMap), findsNothing);
    expect(find.textContaining('경로 · 구룡포'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}

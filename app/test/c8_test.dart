import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guryongpo_safety/live_screens.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/services/prototype_safety_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/patrol_screens.dart';
import 'package:guryongpo_safety/ui/map_menu.dart';
import 'package:guryongpo_safety/ui/widgets.dart' show PillButton;
import 'package:guryongpo_safety/prototype_safety_screens.dart'
    show prototypeEvacuationAlertId, evacuationFlashTransitionInterval;
import 'package:guryongpo_safety/services/live_api.dart';
import 'package:guryongpo_safety/services/demo_live_api.dart';
import 'package:latlong2/latlong.dart';

/// 서버 대신 경로별 응답을 돌려주고, 받은 요청을 기록하는 Dio
class FakeServer {
  FakeServer(this.routes);
  final Map<String, Object? Function(RequestOptions)> routes; // 'GET /api/v1/user' → 응답 본문
  final seen = <RequestOptions>[];

  Dio dio() => Dio(BaseOptions(baseUrl: 'http://fake'))
    ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      seen.add(o);
      final f = routes['${o.method} ${o.path}'];
      if (f == null) {
        h.reject(DioException(requestOptions: o, response: Response(requestOptions: o, statusCode: 404, data: {'message': '없음'})));
        return;
      }
      h.resolve(Response(requestOptions: o, statusCode: 200, data: f(o)));
    }));

  LiveApi api() {
    final d = dio();
    return LiveApi(api: d, route: d);
  }
}

/// 긴 목록 화면(ListView는 보이는 만큼만 만든다)을 한 번에 보도록 화면을 길게.
/// 테스트에서는 지도 타일을 인터넷에서 못 받는다(HTTP 400) — 그 이미지 오류만 무시한다
void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(900, 3200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.library == 'image resource service' && '${d.exception}'.contains('tile.openstreetmap.org')) return;
    original?.call(d);
  };
  addTearDown(() => FlutterError.onError = original);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Widget _app(Widget child, List<Override> overrides) =>
    ProviderScope(overrides: overrides, child: MaterialApp(home: Scaffold(body: child)));

const _incident = {
  'id': 'inc-1', 'hazard': 'flood', 'level': 'warning', 'title': '구룡포 침수 경보', 'started_at': '2026-10-05T10:00:00+09:00',
  'closed_at': null,
  'summary': {'total': 2, 'need_help': 1, 'no_response': 1, 'evacuating': 0, 'evacuated': 0, 'visited': 0},
};

Map<String, dynamic> _detail() => {
      ..._incident,
      'next_poll_sec': 10,
      'area': {
        'type': 'MultiPolygon',
        'coordinates': [
          [
            [[129.55, 35.98], [129.56, 35.98], [129.56, 35.99], [129.55, 35.98]]
          ]
        ]
      },
      'targets': [
        {'id': 't-2', 'kind': 'household', 'label': '[시연] 박○○ 댁', 'location': {'lat': 35.985, 'lng': 129.555},
         'needs': ['elderly'], 'status': 'no_response', 'priority_rank': 2, 'priority_reasons': [], 'last_visit': null},
        {'id': 't-1', 'kind': 'household', 'label': '[시연] 김○○ 댁', 'location': {'lat': 35.986, 'lng': 129.556},
         'needs': ['living_alone', 'mobility_limited'], 'status': 'need_help', 'priority_rank': 1,
         'priority_reasons': [{'factor': 'need_help', 'points': 50, 'label': '도움 요청'}], 'phone': '010-0000-0000',
         'last_visit': null},
      ],
    };

const _households = [
  {'id': 'h-1', 'label': '[시연] 김○○ 댁', 'location': {'lat': 35.986, 'lng': 129.556}, 'needs': ['living_alone', 'mobility_limited']},
  {'id': 'h-2', 'label': '[시연] 호미로 독거 어르신 댁', 'location': {'lat': 35.9896, 'lng': 129.5541}, 'needs': ['elderly', 'living_alone']},
  {'id': 'h-3', 'label': '[시연] 시장 옆 청각장애 주민 댁', 'location': {'lat': 35.9882, 'lng': 129.5525}, 'needs': ['hearing']},
  {'id': 'h-4', 'label': '[시연] 영유아 가구', 'location': {'lat': 35.9850, 'lng': 129.5500}, 'needs': ['infant']},
];

void main() {
  test('취약 가구 분류: 시각·청각·지체 (기타 취약 없음 — 2026-10-11, 휠체어·와상 = 지체)', () {
    expect(vulnerableKind(['hearing']), VulnerableKind.hearing);
    expect(vulnerableKind(['elderly', 'living_alone']), isNull);
    expect(vulnerableKind(['elderly', 'living_alone', 'wheelchair']), VulnerableKind.mobility);
    expect(vulnerableKind(['infant']), isNull);
    expect(vulnerableKinds(['vision', 'mobility_limited']), [VulnerableKind.vision, VulnerableKind.mobility]);
    expect(HouseholdFilter.values, [HouseholdFilter.all, HouseholdFilter.vision, HouseholdFilter.hearing, HouseholdFilter.mobility]);
    expect(matchesFilter(HouseholdFilter.all, ['elderly', 'living_alone']), isFalse);
    expect(matchesFilter(HouseholdFilter.mobility, ['bedridden']), isTrue);
    expect(registeredSupport({'kind': 'household', 'needs': ['hearing', 'wheelchair']}), ['청각장애', '지체장애']);
  });

  testWidgets('대피 상황이 없어도 장애 가구가 지도에 나오고 시각·청각·지체 필터로 고른다 (기타 취약 가구 없음)', (t) async {
    _tall(t);
    final s = FakeServer({
      'GET /api/v1/admin/incidents': (_) => <Object>[],
      'GET /api/v1/admin/households': (_) => _households,
    });
    await t.pumpWidget(_app(const LiveResponderScreen(), [
      liveApiProvider.overrideWithValue(s.api()),
      meProvider.overrideWith((_) async => {'role': 'responder'}),
    ]));
    await _settle(t);
    expect(find.text('진행 중인 대피 경보가 없습니다'), findsOneWidget);
    expect(find.text('도움 필요'), findsNothing); // 경보가 없으면 0 집계 대신 '경보 없음'
    expect(find.text('등록 장애 가구 전체 2'), findsOneWidget);   // 거동 불편 김○○ + 청각장애
    expect(find.text('지체장애 1'), findsOneWidget);
    expect(find.text('청각장애 1'), findsOneWidget);
    expect(find.text('시각장애 0'), findsOneWidget);
    expect(find.textContaining('기타 취약'), findsNothing);
    expect(find.textContaining('독거노인'), findsNothing);
    expect(find.text('장애인 가구'), findsNothing);
    expect(find.text('지체장애 가구'), findsOneWidget);   // 범례는 '우선 확인 가구 지도' 메뉴 안 (방문 경로 안내는 '경로 안내' 메뉴, 2026-10-11)
    // 등록 가구 목록 카드는 뺐다 (2026-10-10) — 지도 표식(툴팁)으로 확인. 세 유형이 없는 가구는 지도에 없다
    Finder marker(String label) => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith(label));
    expect(marker('[시연] 김○○ 댁 · 지체장애'), findsOneWidget);
    expect(marker('[시연] 호미로 독거 어르신 댁'), findsNothing);
    await t.tap(find.text('청각장애 1'));
    await _settle(t);
    expect(marker('[시연] 시장 옆 청각장애 주민 댁 · 청각장애'), findsOneWidget);
    expect(marker('[시연] 김○○ 댁'), findsNothing);
    expect(marker('[시연] 영유아 가구'), findsNothing);
  });

  test('역할: 방재단·관리자만 (돌봄 담당·주민 제외)', () {
    expect(isPatrolRole('responder'), isTrue);
    expect(isPatrolRole('admin'), isTrue);
    expect(isPatrolRole('caregiver'), isFalse);
    expect(isPatrolRole('resident'), isFalse);
    expect(isPatrolRole(null), isFalse);
  });

  test('LiveApi: 방문 기록·담당·대리 등록·해상 경로 요청 형식', () async {
    final s = FakeServer({
      'GET /api/v1/admin/incidents/inc-1': (_) => _detail(),
      'POST /api/v1/admin/incidents/inc-1/targets/t-1/visits': (o) => {'id': 1, 'result': (o.data as Map)['result']},
      'PATCH /api/v1/admin/incidents/inc-1/targets/t-1': (o) => {'id': 't-1'},
      'POST /api/v1/admin/households': (o) => {'id': 'h-1', 'label': (o.data as Map)['label']},
      'POST /api/route/sea': (o) => {'at_sea': true},
    });
    final api = s.api();
    expect((await api.incident('inc-1'))['targets'], hasLength(2));
    await api.recordVisit('inc-1', 't-1', {'result': 'not_home', 'note': '문 잠김'});
    expect(s.seen.last.data, {'result': 'not_home', 'note': '문 잠김'});
    await api.patchTarget('inc-1', 't-1', {'assigned_to': 'me'});
    expect(s.seen.last.method, 'PATCH');
    expect((await api.createHousehold({'label': '이○○ 댁', 'consent_method': 'verbal', 'consent_by': '본인'}))['label'], '이○○ 댁');
    await api.seaRoute(35.99, 129.58, profile: 'elderly');
    expect(s.seen.last.data, {'origin': {'lat': 35.99, 'lon': 129.58}, 'profile': 'elderly'});
  });

  test('route 서버 오류 문장(detail)도 한국어 한 줄로', () {
    final o = RequestOptions(path: '/api/route/sea');
    final e = DioException(requestOptions: o, response: Response(requestOptions: o, statusCode: 422, data: {'detail': '구룡포 일대 밖입니다'}));
    expect(liveError(e), '구룡포 일대 밖입니다');
  });

  test('해상 경로 응답 → 해상 구간(출발→접안점)·육상 구간(접안점→도로→경로)', () {
    final plan = SeaRoutePlan({
      'at_sea': true,
      'port': {'id': 'guryongpo', 'name': '구룡포항', 'kind': 'national_fishing',
               'berth': {'lat': 35.98896, 'lon': 129.55547}, 'land_point': {'lat': 35.98931, 'lon': 129.55575}},
      'sea_leg': {'distance_m': 1324, 'straight_m': 1324, 'bearing_deg': 279.0, 'bearing_label': '서쪽', 'direct': true,
                  'path': '', 'path_found': true, 'alternatives': []},
      'destination': {'name': '여의주타워', 'lat': 35.99038, 'lon': 129.55503, 'note': null},
      'land_route': {'distance_m': 131, 'duration_s': 94, 'geometry': '_p~iF~ps|U_ulLnnqC'},
      'land_route_error': null,
    }, const LatLng(35.9871, 129.57));
    expect(plan.seaPoints, [const LatLng(35.9871, 129.57), const LatLng(35.98896, 129.55547)]);
    expect(plan.landPoints.first, const LatLng(35.98896, 129.55547));
    expect(plan.landPoints[1], const LatLng(35.98931, 129.55575));
    expect(plan.landPoints, hasLength(4)); // 접안점 + 도로 시작점 + 경로 2점
    expect(latLng(plan.destination), const LatLng(35.99038, 129.55503));

    final onLand = SeaRoutePlan({'at_sea': false, 'port': null, 'sea_leg': null, 'land_route': {'geometry': '_p~iF~ps|U_ulLnnqC'}},
        const LatLng(35.98, 129.54));
    expect(onLand.seaPoints, isEmpty);
    expect(onLand.landPoints, hasLength(2));
  });

  test('해상 구간: 서버 바닷길(방파제를 돌아가는 꺾은선)이 있으면 그대로 그린다', () {
    final plan = SeaRoutePlan({
      'at_sea': true,
      'port': {'berth': {'lat': 43.252, 'lon': -126.453}, 'land_point': {'lat': 43.252, 'lon': -126.453}},
      'sea_leg': {'path': '_p~iF~ps|U_ulLnnqC_mqNvxq`@', 'direct': false},
    }, const LatLng(38.5, -120.2));
    expect(plan.seaPoints, hasLength(3)); // 출발 → 꺾는 점 → 접안점
    expect(plan.seaPoints[1], const LatLng(40.7, -120.95));
    // 바닷길을 못 찾으면 직선(육지를 뚫을 수 있음)을 그리지 않는다
    final none = SeaRoutePlan({...plan.raw, 'sea_leg': {'path': '_p~iF~ps|U', 'path_found': false}}, const LatLng(38.5, -120.2));
    expect(none.seaPoints, isEmpty);
  });

  test('점선은 짧은 선분 여러 개', () {
    final dashes = dashedLine(const [LatLng(35.0, 129.0), LatLng(35.1, 129.1)], Colors.blue, dashes: 10);
    expect(dashes, hasLength(5));
  });

  test('우선순위 근거: 서버 근거(B13)를 잇고, 없으면(예전 서버) 상태만', () {
    expect(priorityReason(_detail()['targets'][1] as Map<String, dynamic>), '도움 요청');
    expect(priorityReason(_detail()['targets'][0] as Map<String, dynamic>), '응답 없음');
  });

  for (final role in ['resident', 'caregiver']) {
    testWidgets('방재단 대시보드: $role 이면 잠금 + 초대 코드', (t) async {
      final s = FakeServer({});
      await t.pumpWidget(_app(const LiveResponderScreen(), [
        liveApiProvider.overrideWithValue(s.api()),
        meProvider.overrideWith((_) async => {'role': role}),
      ]));
      await t.pumpAndSettle();
      expect(find.text('방재단·관리자만 볼 수 있는 화면입니다'), findsOneWidget);
      expect(find.text('역할 받기'), findsOneWidget);
      expect(s.seen.where((o) => o.path.startsWith('/api/v1/admin')), isEmpty);
    });
  }

  testWidgets('방재단 대시보드: 우선순위 명단 → 방문 결과 입력 → 다시 불러오기', (t) async {
    var visited = false;
    final s = FakeServer({
      'GET /api/v1/admin/households': (_) => _households,
      'GET /api/v1/admin/incidents': (_) => [_incident],
      'GET /api/v1/admin/incidents/inc-1': (_) {
        final d = _detail();
        if (!visited) return d;
        final ts = [for (final x in d['targets'] as List) Map<String, dynamic>.from(x as Map)];
        ts[1]['status'] = 'evacuated';
        ts[1]['last_visit'] = {'visited_at': '2026-10-05T10:20:00+09:00', 'result': 'evacuated_with_help',
          'responder': {'nickname': '방재단1'}};
        return {...d, 'targets': ts};
      },
      'POST /api/v1/admin/incidents/inc-1/targets/t-1/visits': (_) {
        visited = true;
        return {'id': 1};
      },
    });
    _tall(t);
    await t.pumpWidget(_app(const LiveResponderScreen(), [
      liveApiProvider.overrideWithValue(s.api()),
      meProvider.overrideWith((_) async => {'role': 'responder'}),
    ]));
    await _settle(t);

    expect(find.text('구룡포 침수 경보'), findsOneWidget);
    expect(find.text('주민 대피 현황'), findsOneWidget);
    // 머리 줄은 가구 대리 등록만 (2026-10-10): 온라인·계정·실시간/시연 칩 없음
    expect(find.text('가구 대리 등록'), findsOneWidget);
    for (final s in ['온라인', '실시간', '시연 · 예시 데이터']) {
      expect(find.text(s), findsNothing, reason: s);
    }
    expect(find.text('예시 위치 · 실제 지도 연결 전'), findsNothing);
    // 우선 확인 가구: 도움 필요 김○○(1번)가 응답 없음 박○○(2번)보다 위
    final first = t.getTopLeft(find.text('[시연] 김○○ 댁').first).dy;
    final second = t.getTopLeft(find.text('[시연] 박○○ 댁').first).dy;
    expect(first, lessThan(second));
    expect(find.textContaining(RegExp('^도움 필요 · 지체장애'), findRichText: true), findsOneWidget);   // 등록된 needs(보행 불편)만 장애로, 유형까지
    // 실제 서버에는 업무 단계 칸이 없다 — 단계 바꾸기 없이 배정만
    expect(find.text('배정 0가구 · 미배정 2가구'), findsOneWidget);
    expect(find.text('업무 단계 바꾸기'), findsNothing);

    // 목록을 누르면 지도 아래에 그 가구 정보 (방문 결과·경로에 추가 버튼은 목록 줄의 아이콘으로 옮겼다 — 2026-10-10)
    await t.ensureVisible(find.text('[시연] 김○○ 댁').first);
    await t.tap(find.text('[시연] 김○○ 댁').first);
    await _settle(t);
    expect(find.text('1번 · [시연] 김○○ 댁'), findsOneWidget);
    expect(find.text('방문 결과'), findsNothing);
    expect(find.text('경로에 추가'), findsNothing);
    // 우선 확인 줄 오른쪽 '방문 결과' 아이콘 (1번 김○○ 줄이 맨 위)
    await t.ensureVisible(find.byTooltip('방문 결과').first);
    await t.tap(find.byTooltip('방문 결과').first);
    await t.pumpAndSettle();
    // 방문 결과는 4가지 (2026-10-11 사용자 요청)
    for (final r in ['대피 완료', '대피 거부', '부재·확인 불가', '기타']) {
      expect(find.widgetWithText(ListTile, r), findsOneWidget, reason: r);
    }
    expect(find.text('함께 대피함'), findsNothing);
    await t.tap(find.widgetWithText(ListTile, '대피 완료'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, '휠체어로 이동');
    await t.tap(find.text('기록'));
    await _settle(t);

    final post = s.seen.firstWhere((o) => o.method == 'POST');
    expect(post.path, '/api/v1/admin/incidents/inc-1/targets/t-1/visits');
    expect(post.data, {'result': 'evacuated_with_help', 'note': '휠체어로 이동'});
    expect(find.textContaining('마지막 방문'), findsOneWidget);
    expect(find.text('대피 완료'), findsWidgets);
    // 김○○는 대피 완료가 되어 우선 확인 목록에서 빠지고, 박○○가 1번
    expect(find.textContaining(RegExp('^도움 필요 · 지체장애'), findRichText: true), findsNothing);
    // 대피 완료는 우선 확인 가구·배정 현황 모두 '대피 완료 1곳 보기'로 접힌다 (2026-10-11 사용자 요청)
    expect(find.text('대피 완료 1곳 보기'), findsNWidgets(2));
    expect(find.textContaining('방문: 대피 완료'), findsNothing);
    await t.ensureVisible(find.text('대피 완료 1곳 보기').first);
    await t.tap(find.text('대피 완료 1곳 보기').first);
    await _settle(t);
    // 펼치면 방문 결과가 그 가구 줄 이름 옆에 보인다
    expect(find.textContaining('방문: 대피 완료'), findsOneWidget);
    expect(find.text('대피 완료 1곳 접기'), findsOneWidget);
    // 담당 지정은 그대로 (배정 칸 숫자는 담당 기준)
    expect(find.text('배정 0가구 · 미배정 2가구'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink()); // 10초 갱신 타이머 정리
  });

  testWidgets('대피 경보 팝업 시연: 실제와 같은 팝업, 응답은 기기 시연 기록에만 (서버 호출 없음)', (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = PrototypeSafetyController();
    await store.load();
    final s = FakeServer({});
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store), liveApiProvider.overrideWithValue(s.api())],
        child: MaterialApp(
            home: Scaffold(
                body: Consumer(
                    builder: (c, ref, _) =>
                        TextButton(onPressed: () => showEvacuationAlertDemo(c, ref), child: const Text('시연')))))));
    await t.tap(find.text('시연'));
    await t.pumpAndSettle();
    expect(find.text('지금 당장 대피해야 합니다'), findsOneWidget);
    expect(find.textContaining('실제 경보가 아닙니다'), findsOneWidget);
    await t.tap(find.text('대피 완료'));
    await t.pumpAndSettle();
    expect(find.text('지금 당장 대피해야 합니다'), findsNothing);
    expect(store.responseFor(prototypeEvacuationAlertId), EvacuationResponseStatus.evacuated);
    expect(s.seen, isEmpty);
  });

  // 2026-10-11 사용자 요청: 대피 현황 칩을 누르면 대피 중·대피 완료·도움 필요 팝업, 알림 방식은 사용자 화면 스위치대로
  Future<PrototypeSafetyController> pumpChip(WidgetTester t, AccessibilitySettings a) async {
    SharedPreferences.setMockInitialValues({});
    final store = PrototypeSafetyController();
    await store.load();
    await store.updateAccessibility(a);
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store), liveApiProvider.overrideWithValue(FakeServer({}).api())],
        child: const MaterialApp(home: Scaffold(body: Center(child: EvacStatusChip())))));
    await t.tap(find.byType(EvacStatusChip));
    await t.pump();
    await t.pump();
    return store;
  }

  double flashOpacity(WidgetTester t) =>
      t.widget<AnimatedOpacity>(find.byKey(const ValueKey('evacuation-flash'))).opacity;

  testWidgets('대피 현황 칩: 진행 중인 경보가 없어도 시연 모드면 3버튼 팝업, 진동·화면 점멸 켜짐이면 깜빡인다', (t) async {
    final store = await pumpChip(t, const AccessibilitySettings(strongVibration: true, screenFlash: true));
    expect(find.text('지금 당장 대피해야 합니다'), findsOneWidget);
    for (final s in ['대피 완료', '대피 중', '도움 필요']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('진동·화면 점멸 켜짐 · 사용자 화면에서 바꿀 수 있어요'), findsOneWidget);
    await t.pump(evacuationFlashTransitionInterval);
    expect(flashOpacity(t), greaterThan(0));
    await t.tap(find.text('대피 완료'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100)); // 깜빡임 타이머가 돌아 pumpAndSettle은 쓰지 않는다
    }
    expect(find.text('지금 당장 대피해야 합니다'), findsNothing);
    expect(store.responseFor(prototypeEvacuationAlertId), EvacuationResponseStatus.evacuated);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('대피 현황 칩: 진동·화면 점멸을 끄면 팝업만 뜨고 깜빡이지 않는다', (t) async {
    await pumpChip(t, const AccessibilitySettings(strongVibration: false, screenFlash: false));
    expect(find.text('지금 당장 대피해야 합니다'), findsOneWidget);
    expect(find.text('음성·진동·화면 점멸 알림 꺼짐 · 사용자 화면에서 켤 수 있어요'), findsOneWidget);
    await t.pump(evacuationFlashTransitionInterval * 3);
    expect(flashOpacity(t), 0);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('민감정보 동의: 두 항목 모두 체크해야 등록 버튼이 켜진다', (t) async {
    bool? result;
    _tall(t);
    await t.pumpWidget(MaterialApp(
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () async => result = await Navigator.of(c).push<bool>(
                    MaterialPageRoute(builder: (_) => const SensitiveConsentScreen(needs: ['wheelchair']))),
                child: const Text('열기')))));
    await t.tap(find.text('열기'));
    await t.pumpAndSettle();
    expect(find.textContaining('건강·장애 관련 정보: 휠체어'), findsOneWidget);
    expect(find.textContaining('동의서 버전 v1'), findsOneWidget);
    FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, '동의하고 등록'));
    expect(button().onPressed, isNull);
    await t.tap(find.text('(필수) 위 민감정보를 수집·이용하는 데 동의합니다'));
    await t.pump();
    expect(button().onPressed, isNull);
    await t.tap(find.text('(필수) 대피 상황 때 방재단에게 제공하는 데 동의합니다'));
    await t.pump();
    expect(button().onPressed, isNotNull);
    await t.tap(find.text('동의하고 등록'));
    await t.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets("방재단 경로 안내: 창에서 '경로 추가'한 곳만 자동으로 최단·우선순위 최단 두 경로를 받는다 (2026-10-11)", (t) async {
    final d = _detail();
    final ts = [for (final x in d['targets'] as List) Map<String, dynamic>.from(x as Map)];
    d['targets'] = [
      {...ts[0], 'priority_tier': 4},
      {...ts[1], 'priority_tier': 2},
      {...ts[0], 'id': 't-3', 'label': '[시연] 안 넣은 댁', 'priority_rank': 3, 'priority_tier': 4},
    ];
    final sent = <Map>[];
    Map<String, dynamic> plan(List<String> ids) => {
          'order': [for (var i = 0; i < ids.length; i++) {'id': ids[i], 'seq': i + 1, 'tier': 4, 'leg_distance_m': 300, 'leg_duration_s': 240, 'geometry': '_p~iF~ps|U_ulLnnqC'}],
          'distance_m': 1200, 'duration_s': 900, 'geometry': '_p~iF~ps|U_ulLnnqC', 'still_inside': <String>[],
        };
    final s = FakeServer({
      'GET /api/v1/admin/incidents': (_) => [_incident],
      'GET /api/v1/admin/households': (_) => <Object>[],
      'GET /api/v1/admin/incidents/inc-1': (_) => d,
      'POST /api/route/visits': (o) {
        sent.add(o.data as Map);
        final ids = [for (final x in (o.data as Map)['stops'] as List) '${x['id']}'];
        return {'mode': 'walk', 'shortest': plan(ids.reversed.toList()), 'priority': plan(ids), 'blocked_zones': <String>[], 'hazards_ok': true};
      },
    });
    _tall(t);
    await t.pumpWidget(_app(const LiveResponderScreen(), [
      liveApiProvider.overrideWithValue(s.api()),
      meProvider.overrideWith((_) async => {'role': 'responder'}),
    ]));
    await _settle(t);

    // 우선 확인 가구 줄에는 경로 추가 아이콘이 없다 — 지도 카드 '경로 안내'로만
    expect(find.byTooltip('경로에 추가'), findsNothing);
    expect(find.text('내 방문 경로'), findsNothing);
    // 지도 카드 상위 메뉴 두 개 = 대시보드와 같은 모양 (2026-10-11)
    expect(find.widgetWithText(MapMenuButton, '우선 확인 가구 지도'), findsOneWidget);
    await t.ensureVisible(find.widgetWithText(MapMenuButton, '경로 안내'));
    await t.tap(find.widgetWithText(MapMenuButton, '경로 안내'));
    await _settle(t);
    expect(find.text('방문 경로 안내'), findsWidgets);   // 창 제목 + 지도 아래 칸 제목
    expect(find.text('대피소·의료시설 선택'), findsNothing);
    // 박○○(2번)·김○○(1번)를 넣고 t-3은 안 넣음. 목록 순서 = 우선 확인 순서 (김○○ 먼저)
    await t.tap(find.widgetWithText(PillButton, '경로 추가').at(1));
    await _settle(t);
    await t.tap(find.widgetWithText(PillButton, '경로 추가').first);
    await _settle(t);
    expect(find.widgetWithText(PillButton, '추가됨'), findsNWidgets(2));
    await t.tap(find.widgetWithText(PillButton, '2곳 경로 계산'));
    await _settle(t);
    // 창을 닫으면 바로 계산 (계산 버튼 없음)
    expect(sent, hasLength(1));
    expect([for (final x in sent.last['stops'] as List) (x['id'], x['tier'])], [('t-1', 2), ('t-2', 4)]);   // 명단(순위) 순서로 보냄
    expect(sent.last['mode'], 'walk');
    expect(find.text('방문 경로 안내'), findsOneWidget);   // 지도 범례 자리의 칸 (2026-10-11)
    expect(find.text('경로에 넣은 곳 2/10'), findsOneWidget);
    expect(find.byTooltip('경로에서 빼기'), findsNWidgets(2));
    expect(find.text('출발:'), findsOneWidget);                 // 대시보드 경로 안내와 같은 출발 칸

    expect(find.text('도보 · 총 1.2km · 약 15분'), findsOneWidget);
    double y(String label) => t.getTopLeft(find.descendant(of: find.byType(ListTile), matching: find.text(label)).first).dy;
    expect(y('[시연] 박○○ 댁'), lessThan(y('[시연] 김○○ 댁')));   // 최단: t-2 → t-1
    await t.ensureVisible(find.text('우선순위 경로'));
    await t.tap(find.text('우선순위 경로'));
    await _settle(t);
    expect(y('[시연] 김○○ 댁'), lessThan(y('[시연] 박○○ 댁')));   // 우선순위: t-1 → t-2

    // 한 구간씩 보기 (2026-10-12): 처음엔 전체 보기, ▶ 로 구간을 넘기고 '전체 보기'로 돌아온다
    expect(find.textContaining('전체 보기 · 구간 2개'), findsOneWidget);
    expect(find.byTooltip('앞 구간'), findsOneWidget);
    await t.ensureVisible(find.byTooltip('다음 구간'));
    await t.tap(find.byTooltip('다음 구간'));
    await _settle(t);
    expect(find.text('1 / 2 구간 · 300m · 4분'), findsOneWidget);
    expect(find.textContaining('출발(내 위치) → [시연] 김○○ 댁'), findsOneWidget);   // 우선순위 경로의 첫 구간
    await t.tap(find.byTooltip('다음 구간'));
    await _settle(t);
    expect(find.text('2 / 2 구간 · 300m · 4분'), findsOneWidget);
    expect(find.textContaining('[시연] 김○○ 댁 → [시연] 박○○ 댁'), findsOneWidget);
    // 목록 줄을 눌러도 그 구간으로 (첫 줄 = 1구간)
    await t.tap(find.descendant(of: find.byType(ListTile), matching: find.text('[시연] 김○○ 댁')).first);
    await _settle(t);
    expect(find.text('1 / 2 구간 · 300m · 4분'), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, '전체 보기'));
    await _settle(t);
    expect(find.textContaining('전체 보기 · 구간 2개'), findsOneWidget);
    // 다른 경로(최단)를 보면 전체 보기부터
    await t.tap(find.byTooltip('다음 구간'));
    await _settle(t);
    await t.ensureVisible(find.text('최단 경로'));
    await t.tap(find.text('최단 경로'));
    await _settle(t);
    expect(find.textContaining('전체 보기 · 구간 2개'), findsOneWidget);

    // 하나를 빼면 1곳으로 자동 재계산
    final remove = find.byTooltip('경로에서 빼기').at(1);
    await t.ensureVisible(remove);
    await t.tap(remove);
    await _settle(t);
    expect(sent, hasLength(2));
    expect([for (final x in sent.last['stops'] as List) x['id']], ['t-1']);
    expect(find.text('경로에 넣은 곳 1/10'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  test('우선 확인 순서: 위험지역 안 도움 필요 → 응답 없음, 등록된 장애 정보만 먼저 (앱 사용자 화면 설정은 장애로 보지 않음)', () {
    final ts = <Map<String, dynamic>>[
      {'id': 'a', 'kind': 'household', 'status': 'no_response', 'needs': ['elderly'], 'priority_rank': 1},
      {'id': 'b', 'kind': 'household', 'status': 'need_help', 'needs': <String>[], 'priority_rank': 2},
      {'id': 'c', 'kind': 'household', 'status': 'no_response', 'needs': ['hearing'], 'priority_rank': 3},
      {'id': 'd', 'kind': 'app_user', 'status': 'need_help', 'needs': <String>[], 'disabilities': ['시각장애'], 'priority_rank': 4},
      {'id': 'e', 'kind': 'household', 'status': 'need_help', 'needs': ['wheelchair'], 'priority_rank': 5},
      {'id': 'f', 'kind': 'household', 'status': 'need_help', 'needs': <String>[], 'in_area': false, 'priority_rank': 0},
      {'id': 'g', 'kind': 'household', 'status': 'evacuating', 'needs': <String>[], 'priority_rank': 0},
    ];
    expect([for (final t in priorityTargets(ts)) t['id']], ['e', 'b', 'd', 'c', 'a']);
    expect(registeredSupport(ts[3]), isEmpty);
  });

  test('업무 상태: 배정 없으면 미배정, 서버에 단계가 없으면 배정됨, 방문 결과 대피 완료면 완료', () {
    expect(workStatusOf({'status': 'evacuated', 'assigned_to': null}), WorkStatus.unassigned);
    expect(workStatusOf({'status': 'evacuated', 'assigned_to': {'is_me': true}}), WorkStatus.assigned);
    // 2026-10-11: 방문 결과 '대피 완료' → 배정 여부와 상관없이 완료 (예전 기록 '이송'도)
    expect(workStatusOf({'status': 'evacuated', 'assigned_to': null, 'last_visit': {'result': 'evacuated_with_help'}}), WorkStatus.done);
    expect(workStatusOf({'assigned_to': {'is_me': true}, 'last_visit': {'result': 'transported'}}), WorkStatus.done);
    expect(workStatusOf({'assigned_to': {'is_me': true}, 'last_visit': {'result': 'not_home'}}), WorkStatus.assigned);
    expect(workStatusOf({'assigned_to': {'is_me': false}, 'work_status': 'escorting'}), WorkStatus.escorting);
    expect(workStep(WorkStatus.visiting), 1);
    expect(workStep(WorkStatus.assigned), -1);
  });

  testWidgets('넓은 화면: 우선 확인 가구(왼쪽)·방재단 배정 현황(오른쪽) 나란히 (2026-10-10)', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(1600, 4000);
    SharedPreferences.setMockInitialValues({});
    DemoLiveApi.resetDemoIncident();
    final store = PrototypeSafetyController();
    await store.load();
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: const MaterialApp(home: Scaffold(body: DemoPatrolScope(child: LiveResponderScreen())))));
    await _settle(t);
    final left = t.getTopLeft(find.text('우선 확인 가구')), right = t.getTopLeft(find.text('방재단 배정 현황'));
    expect(left.dy, right.dy);
    expect(left.dx, lessThan(right.dx));
    expect(find.byTooltip('방문 결과'), findsWidgets);
    expect(find.byTooltip('경로에 추가'), findsNothing);   // 경로 추가는 지도 '경로 안내' 창으로 (2026-10-11)
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(minutes: 1));   // 남은 타이머 정리
  });

  testWidgets('시연 대시보드: 팝업 응답이 집계·목록에 반영되고, 배정·업무 단계 변경이 집계와 맞는다', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(900, 9000);
    SharedPreferences.setMockInitialValues({});
    DemoLiveApi.resetDemoIncident();
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: const MaterialApp(home: Scaffold(body: DemoPatrolScope(child: LiveResponderScreen())))));
    await _settle(t);
    expect(find.text('시연 방재단원'), findsNothing);
    expect(find.text('시연 · 예시 데이터'), findsNothing);
    expect(find.text('예시 위치 · 실제 지도 연결 전'), findsOneWidget);
    expect(find.text('앱 사용자 (시연 주민)'), findsWidgets);   // 응답 전 = 응답 없음으로 우선 확인 (+ 배정 현황)
    // 시연 가구는 6곳, 이름에 '[시연]' 머리 없음 (2026-10-10)
    expect(find.textContaining('[시연]'), findsNothing);
    expect(find.text('등록 장애 가구 전체 6'), findsOneWidget);   // 시각 2 · 청각 2 · 지체 2
    for (final k in ['시각장애 2', '청각장애 2', '지체장애 2']) {
      expect(find.text(k), findsOneWidget, reason: k);
    }
    int count(String status) =>
        int.parse(t.widget<Text>(find.byKey(ValueKey('evac-count-$status'))).textSpan!.toPlainText().split(' ').first);
    final noResp = count('no_response'), help = count('need_help');

    // 대피 경보 팝업에서 '도움 필요'로 응답 → 집계·목록이 바로 바뀐다
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    await _settle(t);
    expect(count('no_response'), noResp - 1);
    expect(count('need_help'), help + 1);

    // 배정 카드를 고르면 '업무 단계 바꾸기'만 나온다 ('내가 맡기'는 뺐다 — 2026-10-10). 가는 중 → 방문 중
    Finder chip(String label) => find.textContaining(RegExp('^$label [0-9]+\$'));
    Finder step(String label) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '진행 단계: $label');
    const label = '구룡포리 지체장애 어르신 댁';   // 시연 순서표 첫째: 도움 필요 · 방재단원 A · 가는 중
    await t.ensureVisible(find.text(label).last);
    await t.tap(find.text(label).last);
    await _settle(t);
    expect(find.text('내가 맡기'), findsNothing);
    expect(find.text('맡기 취소'), findsNothing);
    final card = find.byKey(const ValueKey('assign-demo-target-demo-household-01'));   // 주민 응답은 모든 카드에 보여 key 로 고른다
    expect(find.descendant(of: card, matching: find.text('방재단원 A (예시)')), findsOneWidget);
    expect(find.descendant(of: card, matching: step('출발 (1/4)')), findsOneWidget);
    await t.tap(find.descendant(of: card, matching: find.text('업무 단계 바꾸기')));
    await t.pumpAndSettle();
    await t.tap(find.text('방문 중').last);
    await _settle(t);
    final card2 = find.byKey(const ValueKey('assign-demo-target-demo-household-01'));
    expect(find.descendant(of: card2, matching: step('방문 (2/4)')), findsOneWidget);
    // 상태 칩으로 거르면 그 상태만
    await t.tap(chip('방문 중'));
    await _settle(t);
    expect(find.text('방재단원 A (예시)'), findsWidgets);
    expect(step('출발 (1/4)'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  // 2026-10-11 사용자 요청: 장애인 주민이 대피 현황에서 보낸 응답이 방재단 화면(같은 브라우저 다른 창)에 바로 —
  // 우선 확인 가구·배정 현황 모두에 응답 + '내 정보'의 장애 유형이 보인다
  testWidgets('시연 주민 응답: 프로필 장애 유형과 함께 우선 확인 가구·배정 현황에 응답 4가지가 보인다', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(900, 9000);
    SharedPreferences.setMockInitialValues({'optional_profile': '{"지체 지원":"지원 필요"}'});
    DemoLiveApi.resetDemoIncident();
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: const MaterialApp(home: Scaffold(body: DemoPatrolScope(child: LiveResponderScreen())))));
    await _settle(t);
    final me = find.byKey(const ValueKey('assign-${DemoLiveApi.meTargetId}'));
    final priorityRows = find.byKey(const ValueKey('priority-${DemoLiveApi.meTargetId}'));   // 앱 사용자 줄만
    Finder inPriority(String s) => find.descendant(of: priorityRows, matching: find.textContaining(s));

    // 응답 전 = 응답 없음
    expect(find.text('앱 사용자 (시연 주민)'), findsWidgets);
    expect(inPriority('응답 없음 · 지체'), findsOneWidget);
    expect(find.descendant(of: me, matching: find.textContaining('주민 응답 응답 없음 · 지체')), findsOneWidget);

    // 도움 필요
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    await _settle(t);
    expect(inPriority('도움 필요 · 지체장애 · 미배정'), findsOneWidget);
    expect(find.descendant(of: me, matching: find.textContaining('주민 응답 도움 필요 · 지체')), findsOneWidget);

    // 대피 중: 우선 확인 순번에서는 빠져도 번호 없이 목록에 남는다
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.evacuating);
    await _settle(t);
    expect(inPriority('대피 중 · 지체'), findsOneWidget);
    expect(find.descendant(of: me, matching: find.textContaining('주민 응답 대피 중 · 지체')), findsOneWidget);

    // 대피 완료: '대피 완료 N곳 보기' 접힘 안
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.evacuated);
    await _settle(t);
    expect(inPriority('대피 완료 · 지체'), findsNothing);
    final fold = find.textContaining(RegExp(r'^대피 완료 \d+곳 보기$')).first;
    await t.ensureVisible(fold);
    await t.tap(fold);
    await _settle(t);
    expect(inPriority('대피 완료 · 지체'), findsOneWidget);
    expect(find.descendant(of: me, matching: find.textContaining('주민 응답 대피 완료 · 지체')), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('다른 창이 바꾼 시연 응답을 syncFromStorage 로 읽는다 (같은 브라우저 창 두 개)', (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = PrototypeSafetyController();
    await store.load();
    expect(store.demoAlertActive, isFalse);
    // 다른 창이 쓴 것처럼 저장소만 바꾼다
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('prototype_demo_alert_active_v1', true);
    await prefs.setString('prototype_evacuation_responses_v1', '{"$prototypeEvacuationAlertId":"need_help"}');
    var notified = 0;
    store.addListener(() => notified++);
    await store.syncFromStorage();
    expect(store.demoAlertActive, isTrue);
    expect(store.responseFor(prototypeEvacuationAlertId), EvacuationResponseStatus.needHelp);
    expect(notified, 1);
  });

  // 2026-10-12 사용자 요청: 다른 계정(다른 브라우저·기기)끼리 사용자 모드 ↔ 방재단원 모드 연동 — 시연 응답을 서버에 저장
  test('시연 응답·시연 경보 시작을 서버에도 저장한다 (장애 유형 포함), 실패해도 기기 기록은 남는다', () async {
    SharedPreferences.setMockInitialValues({'optional_profile': '{"청각 지원":"지원 필요"}'});
    final fake = FakeServer({
      'POST /api/v1/demo/evacuation/start': (_) => {'id': 'demo-user-a'},
      'POST /api/v1/demo/evacuation/response': (_) => {'id': 'demo-user-a'},
    });
    final api = fake.api();
    final original = PrototypeSafetyController.server;
    addTearDown(() => PrototypeSafetyController.server = original);
    PrototypeSafetyController.server = () => api;
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp, via: 'alarm');
    expect([for (final o in fake.seen) '${o.method} ${o.path}'],
        ['POST /api/v1/demo/evacuation/start', 'POST /api/v1/demo/evacuation/response']);
    expect(fake.seen.first.data, {'needs': ['hearing']});
    expect(fake.seen.last.data, {'status': 'need_help', 'needs': ['hearing'], 'via': 'alarm'});
    expect(store.lastServerSaved, isTrue);
    expect(demoSavedNote(store), '서버에 저장 · 방재단 화면에 전달');

    // 서버가 안 받으면: 기기 기록은 남고 '서버 저장 실패'
    PrototypeSafetyController.server = () => FakeServer({}).api();
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.evacuated);
    expect(store.responseFor(prototypeEvacuationAlertId), EvacuationResponseStatus.evacuated);
    expect(store.lastServerSaved, isFalse);
    // 서버 연결이 아니면(목업·시연 끔) 보내지 않는다
    PrototypeSafetyController.server = () => null;
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.evacuating);
    expect(store.lastServerSaved, isNull);
    store.dispose();
  });

  // 2026-10-12 사용자 요청: 방재단 현황에 주민의 실제 위치
  test('시연 응답에 현재 위치를 싣고, 20m 넘게 움직이면 위치만 다시 보낸다', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeServer({
      'POST /api/v1/demo/evacuation/start': (_) => {'id': 'demo-user-a'},
      'POST /api/v1/demo/evacuation/response': (_) => {'id': 'demo-user-a'},
      'GET /api/v1/demo/evacuation/me': (_) => {'id': 'demo-user-a', 'status': 'need_help', 'dispatch': null},
      'POST /api/v1/demo/evacuation/location': (_) => null,
    });
    final api = fake.api();
    final server = PrototypeSafetyController.server, loc = PrototypeSafetyController.currentLocation;
    addTearDown(() {
      PrototypeSafetyController.server = server;
      PrototypeSafetyController.currentLocation = loc;
    });
    (double, double)? here = (35.9871, 129.5522);
    PrototypeSafetyController.server = () => api;
    PrototypeSafetyController.currentLocation = () => here;
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    expect((fake.seen.last.data as Map)['location'], {'lat': 35.9871, 'lng': 129.5522});
    fake.seen.clear();
    await store.pullFromServer();                      // 그대로면 위치를 보내지 않는다
    expect([for (final o in fake.seen) o.path], ['/api/v1/demo/evacuation/me']);
    here = (35.9881, 129.5522);                        // 약 110m 이동
    fake.seen.clear();
    await store.pullFromServer();
    expect(fake.seen.last.path, '/api/v1/demo/evacuation/location');
    expect(fake.seen.last.data, {'location': {'lat': 35.9881, 'lng': 129.5522}});
    here = null;                                       // 위치를 모르면(GPS 꺼짐·구룡포 밖) 위치 없이
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.evacuating);
    expect((fake.seen.last.data as Map).containsKey('location'), isFalse);
    store.dispose();
  });

  test('주민 앱이 서버에서 다른 계정 방재단원의 출동 기록(도착 예정)을 받는다', () async {
    SharedPreferences.setMockInitialValues({});
    Map<String, dynamic>? dispatch = {
      'departed_at': '2026-10-12T12:00:00+09:00',
      'eta': '2026-10-12T12:07:00+09:00',
      'responder': '시연 방재단원',
      'stage': 'en_route',
    };
    final fake = FakeServer({
      'POST /api/v1/demo/evacuation/start': (_) => {'id': 'demo-user-a'},
      'GET /api/v1/demo/evacuation/me': (_) => {'id': 'demo-user-a', 'status': 'need_help', 'dispatch': dispatch},
    });
    final api = fake.api();
    final original = PrototypeSafetyController.server;
    addTearDown(() => PrototypeSafetyController.server = original);
    PrototypeSafetyController.server = () => api;
    final store = PrototypeSafetyController();
    await store.load();
    await store.pullFromServer();
    expect(store.demoDispatch, isNull);           // 시연 경보 전이면 묻지 않는다
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.pullFromServer();
    expect(store.demoDispatch?.stage, 'en_route');
    expect(store.demoDispatch?.eta, DateTime.parse('2026-10-12T12:07:00+09:00'));
    dispatch = null;                              // 방재단원이 배정을 풀면 지워진다
    await store.pullFromServer();
    expect(store.demoDispatch, isNull);
    store.dispose();
  });

  testWidgets('다른 계정의 시연 응답(서버)이 방재단 화면에 응답·장애 유형으로 보이고, 출발·해제를 서버로 보낸다', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(900, 9000);
    SharedPreferences.setMockInitialValues({});
    DemoLiveApi.resetDemoIncident();
    final read = DemoLiveApi.readServerResponses, write = DemoLiveApi.writeServerDispatch;
    addTearDown(() {
      DemoLiveApi.readServerResponses = read;
      DemoLiveApi.writeServerDispatch = write;
      DemoLiveApi.resetDemoIncident();
    });
    const other = 'demo-user-7b1d2c3e-4f50-4a6b-8c7d-9e0f1a2b3c4d';
    final rows = [
      {
        'id': other, 'label': '하린', 'status': 'need_help', 'needs': ['hearing'], 'minutes_since_alert': 2,
        'started_at': '2026-10-12T12:00:00+09:00', 'is_me': false, 'location': {'lat': 35.9887, 'lng': 129.5549},
        'dispatch': null, 'dispatch_by_me': false,
      },
    ];
    final sent = <(String, Map<String, dynamic>?)>[];
    DemoLiveApi.readServerResponses = (_) async => rows;
    DemoLiveApi.writeServerDispatch = (_, id, d) async => sent.add((id, d));
    final store = PrototypeSafetyController();
    await store.load();
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: const MaterialApp(home: Scaffold(body: DemoPatrolScope(child: LiveResponderScreen())))));
    await _settle(t);
    final card = find.byKey(const ValueKey('assign-$other'));
    expect(find.descendant(of: card, matching: find.text('하린')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('주민 응답 도움 필요 · 청각')), findsOneWidget);
    expect(find.textContaining('앱 사용자 (시연 주민)'), findsNothing);     // 이 기기에는 시연 경보가 없다

    final api = DemoLiveApi();
    final eta = DateTime(2026, 10, 12, 12, 7);
    await api.dispatch(DemoLiveApi.incidentId, [(other, eta)]);
    expect(sent.single.$1, other);
    expect(sent.single.$2?['stage'], 'en_route');
    expect(DateTime.parse('${sent.single.$2?['eta']}').isAtSameMomentAs(eta), isTrue);   // UTC 로 보내도 같은 시각
    await api.patchTarget(DemoLiveApi.incidentId, other, {'work_status': 'visiting'});
    expect(sent.last.$2?['stage'], 'visiting');
    await api.patchTarget(DemoLiveApi.incidentId, other, {'assigned_to': null});
    expect(sent.last.$2, isNull);
    await _settle(t);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('서버에 내 시연 응답이 있으면 이 기기 줄(앱 사용자)을 겹쳐 넣지 않고 (나)로 보인다', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(900, 9000);
    SharedPreferences.setMockInitialValues({});
    DemoLiveApi.resetDemoIncident();
    final read = DemoLiveApi.readServerResponses;
    addTearDown(() {
      DemoLiveApi.readServerResponses = read;
      DemoLiveApi.resetDemoIncident();
    });
    DemoLiveApi.readServerResponses = (_) async => [
          {
            'id': 'demo-user-me', 'label': '시연 주민 caa7', 'status': 'evacuating', 'needs': <String>[],
            'minutes_since_alert': 1, 'started_at': '2026-10-12T12:00:00+09:00', 'is_me': true,
            'location': {'lat': 35.9893, 'lng': 129.5541}, 'dispatch': null, 'dispatch_by_me': false,
          },
        ];
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: const MaterialApp(home: Scaffold(body: DemoPatrolScope(child: LiveResponderScreen())))));
    await _settle(t);
    expect(find.text('시연 주민 caa7 (나)'), findsWidgets);
    expect(find.text('앱 사용자 (시연 주민)'), findsNothing);
    await _settle(t);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('가구 대리 등록 (2026-10-11): 이름·주소(필수)·연락처·장애 유형만, 지체·시각 → 보행 불편·시각', (t) async {
    final api = _CaptureDemoApi();
    _tall(t);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const Text('home')),
      GoRoute(path: '/d', builder: (_, __) => const Scaffold(body: LiveDelegatedHouseholdScreen())),
    ]);
    await t.pumpWidget(ProviderScope(overrides: [
      liveApiProvider.overrideWithValue(api),
      meProvider.overrideWith((_) async => {'role': 'responder'}),
    ], child: MaterialApp.router(routerConfig: router)));
    router.push('/d');
    await _settle(t);
    // 사진 속 칸은 모두 없다
    for (final gone in ['함께 사는 사람 수', '방재단이 알아야 할 점 (선택)', '민감정보 동의 (별도)', '동의한 사람 (예: 본인, 딸 김○○)', '집 위치를 정해 주세요', '고령', '반려동물']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text('주소 (필수)'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, '이름 또는 호칭 (필수)'), '박○○ 댁');
    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, '등록'));
    await _settle(t);
    expect(find.text('이름과 주소를 모두 넣어 주세요.'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, '주소 (필수)'), '구룡포읍 호미로 152');
    // 장애 유형은 선택 (2026-10-11 사용자 결정 — 고르지 않아도 등록 가능)
    await t.tap(find.widgetWithText(FilterChip, '지체'));
    await t.tap(find.widgetWithText(FilterChip, '시각'));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, '등록'));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final body = api.bodies.single;
    expect(body['label'], '박○○ 댁');
    expect(body['address'], '구룡포읍 호미로 152');
    expect(body['needs'], ['mobility_limited', 'vision']);
    expect(body['location'], isA<Map>());
    expect(body['consent_method'], 'verbal');   // 동의는 확인 체크 하나 → 구두·본인 또는 보호자 (2026-10-11)
    expect(body['consent_by'], '본인 또는 보호자');
    expect(body.containsKey('note'), isFalse);
    await t.pumpWidget(const SizedBox.shrink());
  });

  // 2026-10-12 사용자 요청 (쌍방향 소통): 방재단이 '내 방문 경로'에서 [출발] → 집마다 도착 예정 → 시민 화면 대피 현황 옆에
  testWidgets('방재단 [출발]: 경로 이동 시간 누적으로 도착 예정, 시연 주민에게 출발·도착 예정을 보낸다', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(900, 9000);
    SharedPreferences.setMockInitialValues({});
    DemoLiveApi.resetDemoIncident();
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    final api = _RouteDemoApi();
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: MaterialApp(
            home: Scaffold(
                body: DemoPatrolScope(
                    child: ProviderScope(overrides: [liveApiProvider.overrideWithValue(api)], child: const LiveResponderScreen()))))));
    await _settle(t);
    await t.ensureVisible(find.widgetWithText(MapMenuButton, '경로 안내'));
    await t.tap(find.widgetWithText(MapMenuButton, '경로 안내'));
    await _settle(t);
    final row = find.ancestor(
        of: find.descendant(of: find.byType(Dialog), matching: find.text('앱 사용자 (시연 주민)')), matching: find.byType(Row)).first;
    await t.tap(find.descendant(of: row, matching: find.widgetWithText(PillButton, '경로 추가')));
    await _settle(t);
    await t.tap(find.widgetWithText(PillButton, '1곳 경로 계산'));
    await _settle(t);
    expect(find.textContaining('출발하면 약 6분 뒤'), findsOneWidget);   // 출발 전: 누적 이동 시간
    // 계산만으로는 출발이 아니다: [경로 계산] 옆 [실제 출발] (2026-10-12 사용자 요청)
    expect(find.widgetWithText(PillButton, '경로 계산'), findsOneWidget);
    expect(store.demoDispatch, isNull);

    final before = DateTime.now();
    final go = find.widgetWithText(PillButton, '실제 출발');
    await t.ensureVisible(go);
    await t.tap(go);
    await _settle(t);
    expect(find.textContaining('출발함 · '), findsOneWidget);
    // 시민에게 보낸 출동 기록: 가는 중 · 도착 예정 = 출발 + 6분
    final d = store.demoDispatch!;
    expect(d.stage, 'en_route');
    expect(d.eta.difference(before).inSeconds, inInclusiveRange(359, 362));
    final eta = clockHm(d.eta);
    // 방재단 화면: 내가 맡음 · 가는 중 · 도착 예정
    final card = find.byKey(const ValueKey('assign-${DemoLiveApi.meTargetId}'));
    expect(find.descendant(of: card, matching: find.text('도착 예정 $eta')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('나')), findsOneWidget);
    expect(find.textContaining('도착 예정 $eta'), findsWidgets);   // 경로 목록 줄에도

    // 배정 현황에서 '방문 중'으로 바꾸면 시민 쪽은 '도착'
    await t.ensureVisible(card);
    await t.tap(find.descendant(of: card, matching: find.text('앱 사용자 (시연 주민)')));
    await _settle(t);
    await t.tap(find.descendant(of: card, matching: find.text('업무 단계 바꾸기')));
    await t.pumpAndSettle();
    await t.tap(find.text('방문 중').last);
    await _settle(t);
    expect(store.demoDispatch!.stage, 'visiting');
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(minutes: 1));   // 남은 타이머(안내 메시지) 정리
  });

  // 2026-10-12 사용자 요청: 업무 단계 메뉴가 미배정 카드에서 안 보였다 · 대피 중으로 응답한 앱 사용자는 경로에 넣을 수 없었다
  testWidgets('미배정 카드도 업무 단계 바꾸기 → 내가 맡고 그 단계, 대피 중 앱 사용자도 경로 안내 창에 나온다', (t) async {
    _tall(t);
    t.view.physicalSize = const Size(900, 9000);
    SharedPreferences.setMockInitialValues({});
    DemoLiveApi.resetDemoIncident();
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.evacuating);
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: const MaterialApp(home: Scaffold(body: DemoPatrolScope(child: LiveResponderScreen())))));
    await _settle(t);
    // 미배정 앱 사용자 카드: 고르지 않아도 '업무 단계 바꾸기' → '방문 중' = 내가 맡고 방문 중
    final card = find.byKey(const ValueKey('assign-${DemoLiveApi.meTargetId}'));
    await t.ensureVisible(card);
    expect(find.descendant(of: card, matching: find.text('미배정')), findsOneWidget);
    await t.tap(find.descendant(of: card, matching: find.text('업무 단계 바꾸기')));
    await t.pumpAndSettle();
    await t.tap(find.text('방문 중').last);
    await _settle(t);
    expect(find.descendant(of: card, matching: find.text('나')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('방문 중')), findsOneWidget);
    expect(store.demoDispatch?.stage, 'visiting');   // 사용자 쪽은 '방재단 도착'

    // 경로 안내 창: 대피 중인 앱 사용자도 번호 없이 목록에 → 경로 추가
    await t.ensureVisible(find.widgetWithText(MapMenuButton, '경로 안내'));
    await t.tap(find.widgetWithText(MapMenuButton, '경로 안내'));
    await _settle(t);
    final row = find.ancestor(
        of: find.descendant(of: find.byType(Dialog), matching: find.text('앱 사용자 (시연 주민)')), matching: find.byType(Row)).first;
    expect(find.descendant(of: row, matching: find.widgetWithText(PillButton, '경로 추가')), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(minutes: 1));
  });

  testWidgets('시민 화면: 대피 현황 칩 옆에 방재단 출발·도착 예정, 다른 창이 보낸 것도 받는다', (t) async {
    SharedPreferences.setMockInitialValues({});
    final store = PrototypeSafetyController();
    await store.load();
    await store.startDemoAlert(prototypeEvacuationAlertId);
    await t.pumpWidget(ProviderScope(
        overrides: [prototypeSafetyProvider.overrideWith((_) => store)],
        child: MaterialApp(
            scaffoldMessengerKey: rootMessengerKey,
            home: const Scaffold(body: Row(children: [EvacStatusChip(), DispatchEtaPill()])))));
    await t.pump();
    expect(find.textContaining('방재단'), findsNothing);   // 출발 전엔 없음

    // 다른 창(방재단)이 저장소에 쓴 것처럼
    final eta = DateTime.now().add(const Duration(minutes: 6));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('prototype_demo_dispatch_v1',
        '{"departed_at":"${DateTime.now().toIso8601String()}","eta":"${eta.toIso8601String()}","responder":"시연 방재단원","stage":"en_route"}');
    await store.syncFromStorage();
    await t.pump();
    await t.pump();
    expect(find.text('방재단 출발 · ${clockHm(eta)} 도착 예정 (약 6분)'), findsOneWidget);
    expect(find.textContaining('방재단이 출발했어요'), findsOneWidget);   // 한 번 안내

    await PrototypeSafetyController.saveDemoDispatch(
        DemoDispatch(departedAt: DateTime.now(), eta: eta, responder: '시연 방재단원', stage: 'visiting'));
    await t.pump();
    expect(find.text('방재단 도착'), findsOneWidget);
    await PrototypeSafetyController.saveDemoDispatch(null);
    await t.pump();
    expect(find.text('방재단 도착'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 6));
  });

  test('visitCumulative: 앞 구간 이동 시간을 더한다', () {
    final r = visitCumulative({
      'order': [
        {'id': 'a', 'seq': 1, 'leg_duration_s': 120},
        {'id': 'b', 'seq': 2, 'leg_duration_s': 300},
      ]
    });
    expect([for (final (o, d) in r) (o['id'], d.inSeconds)], [('a', 120), ('b', 420)]);
  });
  test('방문 경로를 구간별로 그리기 (2026-10-12): 전체 보기는 구간마다 색이 다른 가는 선, 구간 보기는 고른 구간만 진하게', () {
    const g = '_p~iF~ps|U_ulLnnqC';   // 두 점짜리 선
    Map<String, dynamic> plan(int n, {bool legs = true}) => {
          'geometry': g,
          'order': [for (var i = 0; i < n; i++) {'id': 'h$i', 'seq': i + 1, if (legs) 'geometry': g}],
        };
    // 전체 보기: 흰 테두리 3 + 구간 3, 구간 색이 서로 다르고 모두 같은 가는 굵기
    final all = visitLegLines(plan(3));
    expect(all, hasLength(6));
    final colored = all.sublist(3);
    expect({for (final l in colored) l.color}, hasLength(3));
    expect([for (final l in colored) l.strokeWidth], [4.0, 4.0, 4.0]);
    expect(colored.first.color, visitLegColor(1));
    // 같은 길을 같은 방향으로 지나는 세 구간 → 겹치지 않게 서로 다른 줄(옆으로 나란히)
    expect({for (final l in colored) '${l.points.first.latitude.toStringAsFixed(6)},${l.points.first.longitude.toStringAsFixed(6)}'}, hasLength(3));
    // 구간 보기: 고른 구간만 남색 굵게(맨 위), 나머지는 옅은 회색
    final focus = visitLegLines(plan(3), focus: 1);
    expect([for (final l in focus) l.color], [visitLegDim, visitLegDim, Colors.white, visitLegColor(1)]);
    expect(focus.last.strokeWidth, greaterThan(focus.first.strokeWidth));
    // 구간 선이 없는 예전 서버: 전체 선 하나 (흰 테두리 + 남색)
    expect(visitLegPoints(plan(3, legs: false)), isEmpty);
    expect(visitLegLines(plan(3, legs: false)), hasLength(2));
    // 구간 색은 5색을 돌려 쓴다
    expect(visitLegColor(6), visitLegColor(1));
  });

  test('겹치는 구간을 나란히 (2026-10-12): 반대 방향은 길 양쪽으로, 같은 방향은 줄 번호를 달리해 옆으로', () {
    const a = LatLng(35.9900, 129.5500), b = LatLng(35.9945, 129.5500);   // 정북으로 약 500m
    final mid = LatLng((a.latitude + b.latitude) / 2, a.longitude);
    // 오른쪽으로 10m: 북쪽으로 가는 선은 동쪽(경도 +)으로, 남쪽으로 가는 선은 서쪽으로 밀린다
    final up = offsetLine(const [a, b], 10), down = offsetLine(const [b, a], 10);
    expect(up.first.longitude, greaterThan(a.longitude));
    expect(down.first.longitude, lessThan(a.longitude));
    expect(const Distance().as(LengthUnit.Meter, a, up.first), closeTo(10, 1));
    expect(up.first.latitude, closeTo(a.latitude, 1e-6));   // 옆으로만 민다
    expect(offsetLine(const [a, b], 0), const [a, b]);

    // 줄 번호: 같은 방향으로 겹치면 1, 2, 3 … / 반대 방향이나 떨어진 길은 모두 1번 줄
    expect(visitLegLanes([[a, mid, b], [a, mid, b], [a, mid, b]]), [1, 2, 3]);
    expect(visitLegLanes([[a, mid, b], [b, mid, a]]), [1, 1]);
    expect(visitLegLanes([[a, mid, b], const [LatLng(35.9900, 129.5600), LatLng(35.9920, 129.5600), LatLng(35.9945, 129.5600)]]), [1, 1]);

    // 화면에서 줄 간격 6px: 확대할수록(zoom ↑) 실제 거리는 줄어든다, 반대 방향 두 구간은 서로 다른 쪽에 놓인다
    final far = visitLegLanePoints([[a, mid, b], [b, mid, a]], 13), near = visitLegLanePoints([[a, mid, b], [b, mid, a]], 17);
    double gap(List<List<LatLng>> l) => const Distance().as(LengthUnit.Meter, l[0].first, l[1].last);
    expect(far[0].first.longitude, greaterThan(a.longitude));
    expect(far[1].last.longitude, lessThan(a.longitude));
    expect(gap(far), greaterThan(gap(near) * 8));
  });

  test('방문 경로 방향 화살표 (2026-10-12): 짧은 구간에도 1개, 방향은 진행 방향', () {
    // 정북으로 60m
    final north = visitLegArrowSpots(const [LatLng(35.9900, 129.5500), LatLng(35.99054, 129.5500)]);
    expect(north, hasLength(1));
    expect(north.single.$2, closeTo(0, 1));
    expect(north.single.$1.latitude, closeTo(35.99027, 1e-4));   // 구간 가운데
    // 정동으로 약 450m → 150m마다 3개, 방향 90°
    final east = visitLegArrowSpots(const [LatLng(35.9900, 129.5500), LatLng(35.9900, 129.5550)]);
    expect(east, hasLength(3));
    expect([for (final e in east) e.$2], everyElement(closeTo(90, 1)));
    // 꺾이는 길: 북 → 서, 화살표가 각 구간 방향을 따른다
    final turn = visitLegArrowSpots(const [LatLng(35.9900, 129.5500), LatLng(35.9927, 129.5500), LatLng(35.9927, 129.5467)]);
    expect(turn.first.$2, closeTo(0, 1));
    expect(turn.last.$2, closeTo(270, 1));
    expect(visitLegArrowSpots(const [LatLng(35.99, 129.55)]), isEmpty);
    expect(visitLegArrows(const [LatLng(35.9900, 129.5500), LatLng(35.9900, 129.5550)], visitLegColor(2)), hasLength(3));
  });

  test('시연 가구 배치 (2026-10-11): 최단 방문 순서와 우선순위 방문 순서가 달라지게 — 먼 집이 도움 요청, 가까운 집은 응답 없음', () async {
    DemoLiveApi.resetDemoIncident();
    DemoLiveApi.myAlertActive = false;
    final targets = (await DemoLiveApi().incident(DemoLiveApi.incidentId))['targets'] as List;
    Map<String, dynamic> h(int n) =>
        Map<String, dynamic>.from(targets.firstWhere((t) => t['household_id'] == 'demo-household-0$n') as Map);
    double lat(int n) => ((h(n)['location'] as Map)['lat'] as num).toDouble();
    // 도움 요청 = 1번·2번, 응답 없음 = 3번·4번 — 모두 대피 경보 지역 안
    expect([for (final n in [1, 2, 3, 4]) h(n)['status']], ['need_help', 'need_help', 'no_response', 'no_response']);
    expect([for (final n in [1, 2, 3, 4]) h(n)['in_area']], everyElement(isTrue));
    expect([for (final n in [1, 2, 3, 4]) h(n)['priority_tier']], [1, 1, 3, 3]);
    // 한 줄로 늘어서지 않게 동(3번)·남(1번)·서(2번)·북서(4번)로 벌려 놓았다 — 한 줄이면 두 경로가 같은 길로 그려진다
    double lng(int n) => ((h(n)['location'] as Map)['lng'] as num).toDouble();
    expect(lng(3) > lng(1) && lng(1) > lng(2) && lng(2) > lng(4), isTrue);
    expect(lat(1) < lat(3) && lat(3) < lat(2) && lat(2) < lat(4), isTrue);
    // 우선 확인 번호: 도움 요청 두 곳이 1·2번
    expect([for (final t in priorityTargets(targets.cast<Map<String, dynamic>>()).take(2)) t['status']], ['need_help', 'need_help']);
  });
}

/// 시연 API + 방문 경로 (경로 서버 대신 집마다 6분)
class _RouteDemoApi extends DemoLiveApi {
  @override
  Future<Map<String, dynamic>> visitRoute(double lat, double lon, List<Map<String, dynamic>> stops, {String mode = 'walk'}) async {
    Map<String, dynamic> plan() => {
          'order': [
            for (var i = 0; i < stops.length; i++)
              {'id': stops[i]['id'], 'seq': i + 1, 'tier': 1, 'leg_distance_m': 400, 'leg_duration_s': 360}
          ],
          'distance_m': 400 * stops.length,
          'duration_s': 360 * stops.length,
          'geometry': '_p~iF~ps|U_ulLnnqC',
          'still_inside': <String>[],
        };
    return {'mode': mode, 'shortest': plan(), 'priority': plan(), 'blocked_zones': <String>[], 'hazards_ok': true};
  }
}

/// 시연 API + 대리 등록 요청 본문 기록 (주소 → 좌표는 테스트에서 서버가 없어 시연 규칙대로 지금 위치로)
class _CaptureDemoApi extends DemoLiveApi {
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> createHousehold(Map<String, dynamic> body) {
    bodies.add(body);
    return super.createHousehold(body);
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/live_screens.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/services/prototype_safety_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/patrol_screens.dart';
import 'package:guryongpo_safety/prototype_safety_screens.dart' show prototypeEvacuationAlertId;
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
  test('취약 가구 분류: 장애인·독거노인·기타 (둘 다면 아이콘은 장애인, 필터는 둘 다)', () {
    expect(vulnerableKind(['hearing']), VulnerableKind.disabled);
    expect(vulnerableKind(['elderly', 'living_alone']), VulnerableKind.elderlyAlone);
    expect(vulnerableKind(['elderly', 'living_alone', 'wheelchair']), VulnerableKind.disabled);
    expect(vulnerableKind(['infant']), VulnerableKind.other);
    expect(vulnerableKind(['living_alone']), VulnerableKind.other); // 고령 아닌 독거는 독거노인 아님
    final both = ['elderly', 'living_alone', 'wheelchair'];
    expect(matchesFilter(HouseholdFilter.disabled, both) && matchesFilter(HouseholdFilter.elderlyAlone, both), isTrue);
    expect(matchesFilter(HouseholdFilter.elderlyAlone, ['hearing']), isFalse);
  });

  testWidgets('대피 상황이 없어도 장애인·독거노인 가구가 지도·목록에 나오고 필터로 고른다', (t) async {
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
    expect(find.text('장애인 2'), findsOneWidget);       // 거동 불편 김○○ + 청각장애
    expect(find.text('독거노인 1'), findsOneWidget);
    // 지도 마커: 장애인 아이콘 2 + 독거노인 1 + 기타 1 (목록 아이콘과 범례도 같은 아이콘을 쓴다)
    expect(find.byIcon(Icons.accessible), findsWidgets);
    expect(find.text('[시연] 영유아 가구'), findsOneWidget);
    await t.tap(find.text('독거노인 1'));
    await _settle(t);
    expect(find.text('[시연] 호미로 독거 어르신 댁'), findsOneWidget);
    expect(find.text('[시연] 시장 옆 청각장애 주민 댁'), findsNothing);
    expect(find.text('[시연] 영유아 가구'), findsNothing);
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
    expect(find.text('실시간'), findsOneWidget);          // 서버 갱신 중 (시연 아님)
    expect(find.text('시연 · 예시 데이터'), findsNothing);
    expect(find.text('예시 위치 · 실제 지도 연결 전'), findsNothing);
    // 우선 확인 가구: 도움 필요 김○○(1번)가 응답 없음 박○○(2번)보다 위
    final first = t.getTopLeft(find.text('[시연] 김○○ 댁')).dy;
    final second = t.getTopLeft(find.text('[시연] 박○○ 댁')).dy;
    expect(first, lessThan(second));
    expect(find.text('도움 필요 · 장애'), findsOneWidget);   // 등록된 needs(보행 불편)만 장애로
    // 실제 서버에는 업무 단계 칸이 없다 — 단계 바꾸기 없이 배정만
    expect(find.text('배정 0곳 · 미배정 2곳'), findsOneWidget);
    expect(find.text('업무 단계 바꾸기'), findsNothing);

    // 목록을 누르면 그 가구 정보와 할 일
    await t.ensureVisible(find.text('[시연] 김○○ 댁'));
    await t.tap(find.text('[시연] 김○○ 댁'));
    await _settle(t);
    expect(find.text('1번 · [시연] 김○○ 댁'), findsOneWidget);
    await t.ensureVisible(find.text('방문 결과').first);
    await t.tap(find.text('방문 결과').first);
    await t.pumpAndSettle();
    await t.tap(find.text('함께 대피함'));
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
    expect(find.text('도움 필요 · 장애'), findsNothing);
    // 주민 대피 완료 ≠ 방재단 업무 완료: 배정 현황은 그대로 미배정
    expect(find.text('배정 0곳 · 미배정 2곳'), findsOneWidget);
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

  testWidgets("내 방문 경로: '경로에 추가'한 곳만 최단·우선순위 최단 두 경로로 받는다 (2026-10-09)", (t) async {
    final d = _detail();
    final ts = [for (final x in d['targets'] as List) Map<String, dynamic>.from(x as Map)];
    d['targets'] = [
      {...ts[0], 'priority_tier': 4},
      {...ts[1], 'priority_tier': 2},
      {...ts[0], 'id': 't-3', 'label': '[시연] 안 넣은 댁', 'priority_rank': 3, 'priority_tier': 4},
    ];
    Object? sent;
    Map<String, dynamic> plan(List<String> ids) => {
          'order': [for (var i = 0; i < ids.length; i++) {'id': ids[i], 'seq': i + 1, 'tier': 4, 'leg_distance_m': 300, 'leg_duration_s': 240}],
          'distance_m': 1200, 'duration_s': 900, 'geometry': '_p~iF~ps|U_ulLnnqC', 'still_inside': <String>[],
        };
    final s = FakeServer({
      'GET /api/v1/admin/incidents': (_) => [_incident],
      'GET /api/v1/admin/households': (_) => <Object>[],
      'GET /api/v1/admin/incidents/inc-1': (_) => d,
      'POST /api/route/visits': (o) {
        sent = o.data;
        return {'mode': 'walk', 'shortest': plan(['t-2', 't-1']), 'priority': plan(['t-1', 't-2']), 'blocked_zones': <String>[], 'hazards_ok': true};
      },
    });
    _tall(t);
    await t.pumpWidget(_app(const LiveResponderScreen(), [
      liveApiProvider.overrideWithValue(s.api()),
      meProvider.overrideWith((_) async => {'role': 'responder'}),
    ]));
    await _settle(t);

    expect(find.text('내 방문 경로'), findsOneWidget);
    expect(find.text('경로에 추가한 곳이 없습니다'), findsOneWidget);
    // 우선 확인 목록에서 박○○·김○○ 순서로 골라 넣는다 — t-3은 안 넣음
    Future<void> add(String label) async {
      await t.ensureVisible(find.text(label));
      await t.tap(find.text(label));
      await _settle(t);
      await t.ensureVisible(find.text('경로에 추가'));
      await t.tap(find.text('경로에 추가'));
      await _settle(t);
    }

    await add('[시연] 박○○ 댁');
    await add('[시연] 김○○ 댁');
    expect(find.text('경로에서 빼기'), findsOneWidget);   // 고른 가구(김○○) 정보 칸
    expect(find.byTooltip('경로에서 빼기'), findsNWidgets(2));
    expect(find.text('2곳 경로 계산'), findsOneWidget);
    await t.ensureVisible(find.text('2곳 경로 계산'));
    await t.tap(find.text('2곳 경로 계산'));
    await _settle(t);
    final body = sent! as Map;
    expect([for (final x in body['stops'] as List) (x['id'], x['tier'])], [('t-1', 2), ('t-2', 4)]);   // 명단(순위) 순서로 보냄
    expect(body['mode'], 'walk');

    expect(find.text('도보 · 총 1.2km · 약 15분'), findsOneWidget);
    double y(String label) => t.getTopLeft(find.descendant(of: find.byType(ListTile), matching: find.text(label)).first).dy;
    expect(y('[시연] 박○○ 댁'), lessThan(y('[시연] 김○○ 댁')));   // 최단: t-2 → t-1
    await t.ensureVisible(find.text('우선순위 최단 경로'));
    await t.tap(find.text('우선순위 최단 경로'));
    await _settle(t);
    expect(y('[시연] 김○○ 댁'), lessThan(y('[시연] 박○○ 댁')));   // 우선순위: t-1 → t-2

    // 하나를 빼면 결과가 지워지고 1곳으로 다시 계산
    final remove = find.descendant(of: find.widgetWithText(ListTile, '2번 · [시연] 박○○ 댁'), matching: find.byTooltip('경로에서 빼기'));
    await t.ensureVisible(remove);
    await t.tap(remove);
    await _settle(t);
    expect(find.text('1곳 경로 계산'), findsOneWidget);
    expect(find.text('우선순위 최단 경로'), findsNothing);
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

  test('업무 상태는 주민 응답과 따로: 배정 없으면 미배정, 서버에 단계가 없으면 배정됨', () {
    expect(workStatusOf({'status': 'evacuated', 'assigned_to': null}), WorkStatus.unassigned);
    expect(workStatusOf({'status': 'evacuated', 'assigned_to': {'is_me': true}}), WorkStatus.assigned);
    expect(workStatusOf({'assigned_to': {'is_me': false}, 'work_status': 'escorting'}), WorkStatus.escorting);
    expect(workStep(WorkStatus.visiting), 1);
    expect(workStep(WorkStatus.assigned), -1);
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
    expect(find.text('시연 · 예시 데이터'), findsOneWidget);
    expect(find.text('실시간'), findsNothing);
    expect(find.text('예시 위치 · 실제 지도 연결 전'), findsOneWidget);
    expect(find.text('앱 사용자 (나 · 시연)'), findsOneWidget);   // 응답 전 = 응답 없음으로 우선 확인
    int count(String status) =>
        int.parse(t.widget<Text>(find.byKey(ValueKey('evac-count-$status'))).textSpan!.toPlainText().split(' ').first);
    final noResp = count('no_response'), help = count('need_help');

    // 대피 경보 팝업에서 '도움 필요'로 응답 → 집계·목록이 바로 바뀐다
    await store.respond(prototypeEvacuationAlertId, EvacuationResponseStatus.needHelp);
    await _settle(t);
    expect(count('no_response'), noResp - 1);
    expect(count('need_help'), help + 1);

    // 배정: 내가 맡기 → 배정 수 +1, 업무 = 가는 중. 업무 단계 바꾸기 → 방문 중
    int assigned() => int.parse(RegExp(r'배정 ([0-9]+)곳').firstMatch(t.widget<Text>(find.textContaining('곳 · 미배정')).data!)!.group(1)!);
    Finder chip(String label) => find.ancestor(of: find.textContaining(RegExp('^$label [0-9]+\$')), matching: find.byType(ChoiceChip));
    final before = assigned();
    final unassignedChip = int.parse(RegExp(r'([0-9]+)$').firstMatch(t.widget<Text>(find.textContaining(RegExp(r'^미배정 [0-9]+$'))).data!)!.group(1)!);
    await t.tap(find.text('내가 맡기').first);
    await _settle(t);
    expect(assigned(), before + 1);
    expect(find.textContaining(RegExp('^미배정 ${unassignedChip - 1}\$')), findsOneWidget);
    final mine = find.ancestor(of: find.textContaining('내가 담당 · 주민 응답'), matching: find.byType(Material)).first;
    expect(find.descendant(of: mine, matching: find.text('가는 중')), findsOneWidget);
    expect(find.descendant(of: mine, matching: find.text('출발(지금)')), findsOneWidget);
    await t.tap(find.descendant(of: mine, matching: find.text('업무 단계 바꾸기')));
    await t.pumpAndSettle();
    await t.tap(find.text('방문 중').last);
    await _settle(t);
    final mine2 = find.ancestor(of: find.textContaining('내가 담당 · 주민 응답'), matching: find.byType(Material)).first;
    expect(find.descendant(of: mine2, matching: find.text('방문(지금)')), findsOneWidget);
    // 상태 칩으로 거르면 그 상태만
    await t.tap(chip('방문 중'));
    await _settle(t);
    expect(find.textContaining('내가 담당'), findsWidgets);
    expect(find.text('출발(지금)'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
}

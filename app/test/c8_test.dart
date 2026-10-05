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
    expect(find.text('진행 중인 대피 상황이 없습니다'), findsOneWidget);
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

  test('우선순위 근거: 서버 근거가 없으면 지금 순서 규칙을 밝힌다', () {
    expect(priorityReason(_detail()['targets'][1] as Map<String, dynamic>), '도움 요청');
    expect(priorityReason(_detail()['targets'][0] as Map<String, dynamic>), '미응답 우선 · 도움 필요한 점 1개');
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
    // 서버 순위대로: 1순위 김○○(도움 필요)가 2순위 박○○보다 위
    final first = t.getTopLeft(find.text('[시연] 김○○ 댁')).dy;
    final second = t.getTopLeft(find.text('[시연] 박○○ 댁')).dy;
    expect(first, lessThan(second));
    expect(find.text('순위 근거: 도움 요청'), findsOneWidget);

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
}

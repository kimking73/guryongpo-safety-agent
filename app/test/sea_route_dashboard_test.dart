// 대시보드 '경로 안내' — 지금 위치가 바다 위면 따로 화면을 열지 않고 그 위치에서 바로 해상 경로를 받아 그린다 (2026-10-10 사용자 요청)
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:guryongpo_safety/disaster_center.dart';
import 'package:guryongpo_safety/live_screens.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/patrol_screens.dart';
import 'package:guryongpo_safety/route_planner.dart';
import 'package:guryongpo_safety/services/live_api.dart';

const _ship = LatLng(35.975, 129.575);

/// route 서버 /api/route/sea 실제 응답 모양 (로컬 route 서버에서 받은 값 그대로, 육상 구간 포함)
final _seaJson = <String, dynamic>{
  'at_sea': true,
  'port': {
    'id': 'byeongpo',
    'name': '병포리 포구',
    'berth': {'lat': 35.980093, 'lon': 129.554197},
    'land_point': {'lat': 35.979964, 'lon': 129.554335},
  },
  'sea_leg': {
    'distance_m': 2005,
    'straight_m': 1956,
    'bearing_deg': 286.8,
    'bearing_label': '서북서쪽',
    'direct': false,
    'path': 'wjqzEwrzuWe[b{Bk@?m@??v@?t@k@v@PT',
    'path_found': true,
  },
  'destination': {'name': '구룡포 실내체육관', 'lat': 35.9890, 'lon': 129.5530},
  'land_route': {'distance_m': 1200, 'duration_s': 900, 'geometry': ''},
};

class _SeaApi extends LiveApi {
  _SeaApi() : super(api: Dio(), route: Dio());
  final calls = <LatLng>[];
  final dests = <LatLng?>[];
  @override
  Future<Map<String, dynamic>> seaRoute(double lat, double lon,
      {String profile = 'adult', double? toLat, double? toLon}) async {
    calls.add(LatLng(lat, lon));
    dests.add(toLat == null || toLon == null ? null : LatLng(toLat, toLon));
    return _seaJson;
  }
}

ProviderContainer _container(_SeaApi api, WhereNow where) => ProviderContainer(overrides: [
      liveApiProvider.overrideWithValue(api),
      whereNowProvider.overrideWith((_) async => where),
      userLocation.overrideWithValue(const UserLocation(_ship, fromGps: true, manual: true)),
    ]);

void main() {
  test('바다 위면 지금 위치에서 해상 경로를 받고, 지도에 바닷길·항구·대피소를 그린다', () async {
    final api = _SeaApi();
    final c = _container(api, const WhereNow(WhereKind.sea));
    addTearDown(c.dispose);
    final plan = await c.read(seaRoutePlanProvider.future);
    expect(api.calls, [_ship]);
    expect(plan, isNotNull);
    expect(plan!.seaPoints.length, greaterThanOrEqualTo(2));
    expect(seaRoutePolylines(plan), isNotEmpty);
    // 배 위치 · 항구 접안점 · 대피소
    expect(seaRouteMarkers(plan), hasLength(3));
  });

  test('육지면 해상 경로를 부르지 않는다', () async {
    final api = _SeaApi();
    final c = _container(api, const WhereNow(WhereKind.land));
    addTearDown(c.dispose);
    expect(await c.read(seaRoutePlanProvider.future), isNull);
    expect(api.calls, isEmpty);
  });

  test('도착을 고르면 그곳까지, X로 끝내면 해상 경로를 그리지 않는다 (2026-10-11)', () async {
    final api = _SeaApi();
    final c = _container(api, const WhereNow(WhereKind.sea));
    addTearDown(c.dispose);
    c.listen(seaRoutePlanProvider, (_, __) {});
    await c.read(seaRoutePlanProvider.future);
    expect(api.dests, [null]); // 처음엔 경로 서버가 가까운 대피소를 고른다
    const home = LatLng(35.985, 129.555);
    c.read(seaDestPoint.notifier).state = const RoutePoint('집', home);
    expect(await c.read(seaRoutePlanProvider.future), isNotNull);
    expect(api.dests.last, home);
    c.read(seaRouteOff.notifier).state = true;
    expect(await c.read(seaRoutePlanProvider.future), isNull);
    expect(api.calls, hasLength(2));
  });

  testWidgets('경로 안내 줄: 바다 위에서도 출발·도착·종료(X)가 남는다 (2026-10-11)', (t) async {
    final api = _SeaApi();
    final c = _container(api, const WhereNow(WhereKind.sea));
    addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
        container: c, child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RoutePlanner())))));
    await t.pump();
    await t.pump();
    expect(find.text('출발:'), findsOneWidget);
    expect(find.text('도착:'), findsOneWidget);
    expect(find.text('구룡포 실내체육관'), findsOneWidget); // 경로 서버가 고른 대피소
    await t.tap(find.byTooltip('경로 안내 종료'));
    await t.pump();
    await t.pump();
    expect(c.read(seaRouteOff), isTrue);
    expect(find.text('출발:'), findsOneWidget); // 끝내도 출발·도착은 남아 다시 고를 수 있다
    await t.tap(find.text('경로 보기'));
    await t.pump();
    expect(c.read(seaRouteOff), isFalse);
  });

  testWidgets('경로 안내 칸: 바다 위면 버튼 대신 항구까지 바닷길·대피소까지 길을 바로 보여 준다', (t) async {
    final api = _SeaApi();
    final c = _container(api, const WhereNow(WhereKind.sea));
    addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
        container: c, child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SeaRoutePanel())))));
    await t.pump();
    await t.pump();
    expect(find.textContaining('서북서쪽 병포리 포구까지 바닷길 2.0km'), findsOneWidget);
    expect(find.textContaining('항구에서 구룡포 실내체육관까지'), findsOneWidget);
  });
}

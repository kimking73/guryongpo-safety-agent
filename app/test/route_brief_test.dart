// AI 경로 설명 (2026-10-11): 경로 서버의 계단·급경사 길이 매핑, 설명 응답 매핑, 지도 위 칸 표시·접기
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/route_brief_card.dart';

const _route = {
  'profile': 'adult', 'distance_m': 1001, 'duration_s': 721, 'ascend_m': 40, 'max_slope_pct': 31, 'max_uphill_pct': 31,
  'steps_m': 24, 'steep_up_m': 136, 'very_steep_up_m': 85, 'avoided': [], 'still_inside': ['z2'],
  'geometry': 'oktzEe|vuWl@p@BCpAhB', 'hazards_ok': true,
};

void main() {
  test('경로 응답의 오르막·계단 길이 → 경로 모델, 없으면 0', () {
    final r = routeFromJson(_route, 's1', RouteType.safest, names: const {'z2': '침수 경보'});
    expect([r.ascendMeters, r.stepsMeters, r.steepUpMeters, r.verySteepUpMeters], [40, 24, 136, 85]);
    final old = routeFromJson({..._route}..removeWhere((k, _) => k.endsWith('_m') && k != 'distance_m'), 's1', RouteType.safest);
    expect([old.ascendMeters, old.stepsMeters, old.steepUpMeters], [0, 0, 0]);
  });

  test('설명 응답 매핑 · 서버 없이 만든 설명은 경로 값만 쓴다', () {
    final b = RouteBrief.fromJson({
      'summary': '구룡포 실내체육관까지 1001m, 걸어서 약 13분입니다.',
      'hazards': ['다른 길이 없어 침수 경보 구역을 지납니다.'],
      'cautions': ['급한 오르막이 136m 있습니다.'],
      'note': '경사·계단 길이는 실제와 다를 수 있습니다.',
    });
    expect(b.fromAi, isTrue);
    expect(b.hazards.single, contains('침수 경보'));

    final r = routeFromJson(_route, 's1', RouteType.safest, names: const {'z2': '침수 경보'});
    final local = RouteBrief.local(r, '구룡포 실내체육관');
    expect(local.fromAi, isFalse);
    expect(local.summary, '구룡포 실내체육관까지 1001m, 걸어서 약 13분입니다.');
    expect(local.hazards.single, contains('침수 경보'));
    expect(local.cautions, ['급한 오르막이 136m 있습니다 (가장 급한 곳 31%).', '계단이 24m 있습니다.']);
  });

  testWidgets('지도 위 칸: 요약·위험·주의를 보이고 접으면 제목과 위험 개수만', (t) async {
    const brief = RouteBrief(
        summary: '구룡포 실내체육관까지 1001m, 걸어서 약 13분입니다.',
        hazards: ['다른 길이 없어 침수 경보 구역을 지납니다.'],
        cautions: ['급한 오르막이 136m 있습니다.'],
        note: '경사·계단 길이는 실제와 다를 수 있습니다.');
    await t.pumpWidget(ProviderScope(
      overrides: [
        routeFacilityId.overrideWith((_) => 's1'),
        routeBriefProvider('s1').overrideWith((_) async => brief),
      ],
      child: const MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topRight, child: RouteBriefCard(maxWidth: 320)))),
    ));
    await t.pumpAndSettle();
    expect(find.text('AI 경로 설명'), findsOneWidget);
    expect(find.text(brief.summary), findsOneWidget);
    expect(find.text('위험한 요소'), findsOneWidget);
    expect(find.text('주의할 점'), findsOneWidget);
    expect(find.text('급한 오르막이 136m 있습니다.'), findsOneWidget);

    await t.tap(find.text('AI 경로 설명'));
    await t.pumpAndSettle();
    expect(find.text(brief.summary), findsNothing);
    expect(find.text('위험 1'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('경로가 없으면 칸을 그리지 않는다', (t) async {
    await t.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: RouteBriefCard(maxWidth: 320)))));
    await t.pump();
    expect(find.text('AI 경로 설명'), findsNothing);
  });

  test('해상 경로 → 설명 요청: 바닷길 + 항구에서 대피소까지, 육지 위치면 육상 구간만', () {
    final raw = {
      'at_sea': true,
      'port': {'name': '구룡포항', 'berth': {'lat': 35.99, 'lon': 129.56}},
      'sea_leg': {'distance_m': 820.4, 'bearing_label': '북서쪽', 'direct': false, 'path_found': true},
      'destination': {'name': '구룡포초등학교', 'lat': 35.991, 'lon': 129.555},
      'land_route': {..._route, 'still_inside': ['flood--8']},
    };
    final b = seaBriefBody(raw, 35.98, 129.57)!;
    expect(b['sea'], {'port_name': '구룡포항', 'distance_m': 820, 'bearing_label': '북서쪽', 'direct': false, 'path_found': true});
    expect((b['route'] as Map)['steps_m'], 24);
    expect((b['destination'] as Map)['name'], '구룡포초등학교');
    expect((b['origin'] as Map)['name'], '배 위치');
    final local = localBriefOfBody(b);
    expect(local.summary, '북서쪽 구룡포항까지 바닷길 820m입니다. 항구에서 구룡포초등학교까지 1001m, 걸어서 약 13분입니다.');
    expect(local.hazards.single, contains('1곳'));
    expect(local.cautions.single, contains('방파제'));

    final land = seaBriefBody({...raw, 'at_sea': false, 'sea_leg': null, 'port': null}, 35.98, 129.57)!;
    expect(land.containsKey('sea'), isFalse);
    expect(seaBriefBody({'at_sea': false}, 35.98, 129.57), isNull);
  });

  test('방재단 방문 경로 → 설명 요청: 고른 순서의 거리·집 수, 풀어 준 구역', () {
    final result = {
      'mode': 'walk',
      'hazards_ok': true,
      'blocked_zones': ['flood--3'],
      'shortest': {'order': [{'id': 'a', 'seq': 1}, {'id': 'b', 'seq': 2}], 'distance_m': 900, 'duration_s': 660, 'geometry': 'abc', 'still_inside': []},
      'priority': {'order': [{'id': 'b', 'seq': 1}, {'id': 'a', 'seq': 2}], 'distance_m': 1200, 'duration_s': 870, 'geometry': 'abd', 'still_inside': ['flood--3']},
    };
    final b = visitBriefBody(result, 'priority', 35.99, 129.55, '내 위치')!;
    expect(b['visits'], {'stops': 2, 'by_priority': true, 'blocked_zones': ['flood--3']});
    expect((b['route'] as Map)['distance_m'], 1200);
    expect(localBriefOfBody(b).summary, '2곳을 모두 도는 길은 1200m, 걸어서 약 15분입니다.');
    expect(visitBriefBody({'shortest': {'order': []}}, 'shortest', 35.99, 129.55, '내 위치'), isNull);
  });

  testWidgets('요청 값으로 그리는 칸 (해상·방문 경로): 서버 없이도 경로 값으로 만든 설명을 보인다', (t) async {
    final body = visitBriefBody({
      'mode': 'walk',
      'shortest': {'order': [{'id': 'a', 'seq': 1}], 'distance_m': 300, 'duration_s': 240, 'geometry': 'abc', 'still_inside': []},
    }, 'shortest', 35.99, 129.55, '내 위치');
    await t.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topRight, child: RouteBriefCard(maxWidth: 320, body: body))))));
    await t.pumpAndSettle();
    expect(find.text('AI 경로 설명'), findsOneWidget);
    expect(find.text('1곳을 모두 도는 길은 300m, 걸어서 약 4분입니다.'), findsOneWidget);
  });
}

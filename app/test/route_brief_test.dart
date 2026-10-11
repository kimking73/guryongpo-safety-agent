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
}

import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/demo_live_api.dart';

void main() {
  test('시연 방재단 데이터: 가구 6곳, 이름에 [시연] 없음·가상 동의, 앱 안 예시 대피 상황 하나 (2026-10-10)', () async {
    final api = DemoLiveApi();
    final hh = await api.adminHouseholds();
    expect(hh, hasLength(DemoLiveApi.maxDemoHouseholds));
    // 장애 유형은 시각·청각·지체(보행 불편)만, 모든 가구가 하나 이상 (2026-10-11)
    const dis = {'vision', 'hearing', 'mobility_limited'};
    for (final h in hh) {
      final needs = {for (final n in h['needs'] as List) '$n'};
      expect(needs.difference({...dis, 'elderly'}), isEmpty, reason: '${h['label']}');
      expect(needs.intersection(dis), isNotEmpty, reason: '${h['label']}');
    }
    expect(hh.any((h) => '${h['label']}'.contains('[시연]')), isFalse);
    expect(hh.every((h) => (h['consent'] as Map)['by'] == '시연용 가상 데이터'), isTrue);
    expect(DemoLiveApi.stripDemoPrefix('[시연] 하정리 댁'), '하정리 댁');
    final incidents = await api.adminIncidents();
    expect(incidents, hasLength(1));
    expect('${incidents.first['title']}', isNot(contains('[시연]')));
    final d = await api.incident(DemoLiveApi.incidentId);
    expect(d['targets'] as List, hasLength(hh.length + (DemoLiveApi.myAlertActive ? 1 : 0)));
    expect(api.supportsWorkStatus, isTrue);
    expect((await api.me())['role'], 'responder');
    final ov = await api.adminOverview();
    expect(ov['households_total'], hh.length);
    expect((ov['needs_counts'] as Map)['elderly'], greaterThan(2));
  });

  test('시연 대리 등록은 목록에 바로 추가', () async {
    final api = DemoLiveApi();
    final before = (await api.adminHouseholds()).length;
    await api.createHousehold({'label': '새 가구', 'location': {'lat': 35.99, 'lng': 129.55}, 'needs': ['elderly'], 'members': 1});
    final after = await api.adminHouseholds();
    expect(after.length, before + 1);
    expect(after.last['label'], '새 가구');
  });
}

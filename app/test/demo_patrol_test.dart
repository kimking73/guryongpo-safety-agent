import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/demo_live_api.dart';

void main() {
  test('시연 방재단 데이터: 가구 12곳, 모두 [시연] 표시·가상 동의, 앱 안 예시 대피 상황 하나', () async {
    final api = DemoLiveApi();
    final hh = await api.adminHouseholds();
    expect(hh, hasLength(greaterThanOrEqualTo(12)));
    expect(hh.every((h) => '${h['label']}'.startsWith('[시연]')), isTrue);
    expect(hh.every((h) => (h['consent'] as Map)['by'] == '시연용 가상 데이터'), isTrue);
    final incidents = await api.adminIncidents();
    expect(incidents, hasLength(1));
    expect('${incidents.first['title']}', startsWith('[시연]'));
    final d = await api.incident(DemoLiveApi.incidentId);
    expect(d['targets'] as List, hasLength(hh.length + (DemoLiveApi.myAlertActive ? 1 : 0)));
    expect(api.supportsWorkStatus, isTrue);
    expect((await api.me())['role'], 'responder');
    final ov = await api.adminOverview();
    expect(ov['households_total'], hh.length);
    expect((ov['needs_counts'] as Map)['elderly'], greaterThan(5));
  });

  test('시연 대리 등록은 목록에 바로 추가', () async {
    final api = DemoLiveApi();
    final before = (await api.adminHouseholds()).length;
    await api.createHousehold({'label': '새 가구', 'location': {'lat': 35.99, 'lng': 129.55}, 'needs': ['elderly'], 'members': 1});
    final after = await api.adminHouseholds();
    expect(after.length, before + 1);
    expect(after.last['label'], '[시연] 새 가구');
  });
}

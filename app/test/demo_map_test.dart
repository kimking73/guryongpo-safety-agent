import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/services/demo_mode.dart';

/// 시연 모드 지도: 읍 전체 호우·강풍 특보 영역은 칠하지 않는다 (2026-10-07). 실측 화면은 그대로.
void main() {
  const areas = [
    RiskArea(level: '경계', label: '침수 경보', polygons: [], hazard: 'flood'),
    RiskArea(level: '경계', label: '산사태 경고', polygons: [], hazard: 'landslide'),
    RiskArea(level: '경계', label: '호우경보', polygons: [], hazard: 'heavy_rain'),
    RiskArea(level: '주의', label: '강풍주의보', polygons: [], hazard: 'strong_wind'),
  ];
  tearDown(() => DemoData.on = false);

  test('시연 모드면 호우·강풍 영역을 지도에서 뺀다', () {
    DemoData.on = true;
    expect(DemoData.mapAreas(areas).map((a) => a.hazard), ['flood', 'landslide']);
  });

  test('실측 화면은 모든 영역을 그대로 그린다', () {
    DemoData.on = false;
    expect(DemoData.mapAreas(areas), hasLength(4));
  });
}

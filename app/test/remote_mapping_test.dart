// 서버 실제 응답 모양(2026-10-02 로컬 서버에서 받은 값) → 화면 모델 변환
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/services/polyline.dart';

const _warningRisk = {
  'location': {'lat': 35.9903, 'lng': 129.5558},
  'max_level': 'warning',
  'max_level_num': 3,
  'items': [
    {'hazard': 'flood', 'level': 'warning', 'level_num': 3, 'label': '침수 경보',
     'reason': '구룡포환승센터 지표면 수위계 침수심 230mm (기준 150mm)', 'area_id': 1022,
     'observed_at': '2026-10-05T14:27:00+09:00'},
    {'hazard': 'uv', 'level': 'watch', 'level_num': 1, 'label': '자외선 보통', 'reason': null, 'area_id': null},
  ],
  'computed_at': '2026-10-05T14:30:00+09:00',
  'data_stale': false,
};

void main() {
  test('Google polyline 디코딩 (경로 서버 geometry 형식)', () {
    // 구글 문서 예시: (38.5,-120.2) (40.7,-120.95) (43.252,-126.453)
    final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(pts.length, 3);
    expect(pts[0].latitude, closeTo(38.5, 1e-9));
    expect(pts[2].longitude, closeTo(-126.453, 1e-9));
  });

  test('polyline: 좌표가 줄어드는(음수 변화량) 경로도 웹에서 맞게 — flutter test --platform chrome 로도 돌린다', () {
    final pts = decodePolyline('istzEmzuuWh@y@XgAl@Uc@qCGaA?_@');   // 실제 경로 서버 응답 (남동쪽으로 감)
    expect(pts.first.latitude, closeTo(35.99173, 1e-9));
    expect(pts.every((p) => p.latitude > 35.9 && p.latitude < 36.1 && p.longitude > 129.5 && p.longitude < 129.6), isTrue);
  });

  test('위험도: 판정 단계를 한국어로, 근거를 항목별로', () {
    final r = riskFromJson(_warningRisk);
    expect(r.level, '경계');
    expect(r.title, '침수 경보 · 자외선 보통');
    expect(r.summary, contains('침수심 230mm'));
    expect(r.updatedAt, '14:30');
    expect(r.details, hasLength(2));
    expect(r.details[1], '자외선 보통');
  });

  test('위험도: 항목이 없으면 정상, 판정 지연이면 지연 안내', () {
    final ok = riskFromJson({'max_level': 'normal', 'items': [], 'computed_at': '2026-10-02T13:32:00+09:00', 'data_stale': false});
    expect(ok.level, '정상');
    expect(ok.title, '현재 위험 없음');
    final stale = riskFromJson({'max_level': 'normal', 'items': [], 'computed_at': null, 'data_stale': true});
    expect(stale.stale, isTrue);
    expect(stale.summary, contains('지연'));
  });

  test('알림: 위험 판정 항목마다 하나', () {
    final a = alertsFromRiskJson(_warningRisk);
    expect(a.map((x) => x.id), ['flood-1022', 'uv-1']);
    expect(a.first.level, '경계');
    expect(a.first.time, '14:27');
    expect(a.last.time, '14:30');
  });

  test('대피소 GeoJSON → 시설 (거리·도보시간 추정)', () {
    final fc = {'type': 'FeatureCollection', 'features': [
      {'type': 'Feature', 'id': 8, 'geometry': {'type': 'Point', 'coordinates': [129.5526, 35.9912]},
       'properties': {'id': 8, 'name': '구룡포 초등학교 앞', 'shelter_types': ['tsunami'], 'address': '경북 포항시 남구 구룡포읍',
         'capacity': null, 'phone': null, 'is_indoor': false, 'is_accessible': null, 'in_risk_area': false}},
    ]};
    final f = facilitiesFromGeoJson(fc, FacilityType.shelter, originFor(UserMode.visitor)).single;
    expect(f.id, 'shelter-8');
    expect(f.description, '지진해일 대피장소 · 실외');
    expect(f.distanceKm, 0.1);
    expect(f.walkMinutes, greaterThan(0));
    expect(f.accessible, isFalse);
  });

  test('위험 영역 MultiPolygon → 폴리곤 고리', () {
    final areas = riskAreasFromGeoJson({'type': 'FeatureCollection', 'features': [
      {'type': 'Feature', 'id': 1, 'geometry': {'type': 'MultiPolygon', 'coordinates': [
        [[[129.55, 35.99], [129.56, 35.99], [129.56, 36.0], [129.55, 35.99]]]]},
       'properties': {'level': 'critical', 'label': '침수 심각'}},
    ]});
    expect(areas.single.level, '심각');
    expect(areas.single.hazard, '');
    expect(areas.single.contains(const LatLng(35.991, 129.555)), isTrue);
    expect(areas.single.polygons.single.first.latitude, 35.99);
  });

  test('경로 응답 → 지도 경로', () {
    final r = routeFromJson({'profile': 'elderly', 'distance_m': 274, 'duration_s': 263, 'max_slope_pct': 17,
      'avoided': ['flood-001'], 'still_inside': [], 'geometry': 'gmtzEsgvuWZQAo@A_A?M@O?SEW?OBMDIVYUa@dByBDMAOAEUa@'},
      'shelter-19', RouteType.safest, names: {'flood-001': '임시 침수 구역 1 (항구 뒷길)'});
    expect(r.polylinePoints.first.latitude, closeTo(35.9908, 1e-4));
    expect(r.estimatedMinutes, 5);
    expect(r.riskAvoidanceSummary, contains('1곳을 피했습니다: 임시 침수 구역 1 (항구 뒷길)'));
    expect(r.riskAvoidanceSummary, contains('노약자'));
  });

  test('경로 프로필: 65세 이상이나 휠체어면 노약자', () {
    expect(routeProfileFor(70, '도보'), 'elderly');
    expect(routeProfileFor(30, '휠체어'), 'elderly');
    expect(routeProfileFor(30, '도보'), 'adult');
    expect(routeProfileFor(null, null), 'adult');
  });

  test('대피소 제외 규칙: 침수·산사태 영역 안, 침수 중 지하 (AI와 같은 규칙)', () {
    Facility f(String name, double lat, double lng) => Facility(id: name, name: name, type: FacilityType.shelter,
        position: LatLng(lat, lng), address: '', description: '', distanceKm: 0, walkMinutes: 0, accessible: false);
    final square = [const LatLng(35.99, 129.55), const LatLng(35.99, 129.56), const LatLng(36.0, 129.56), const LatLng(36.0, 129.55)];
    final flood = RiskArea(level: '경계', label: '침수 경보', hazard: 'flood', polygons: [square]);
    final rain = RiskArea(level: '경계', label: '강우 경보', hazard: 'heavy_rain', polygons: [square]);
    final watch = RiskArea(level: '관심', label: '침수 보통', hazard: 'flood', polygons: [square]);
    expect(shelterExclusion(f('초등학교 앞', 35.995, 129.555), [flood]), '위험 영역 안(침수 경보)');
    expect(shelterExclusion(f('초등학교 앞', 35.995, 129.555), [rain]), isNull);        // 호우 영역은 읍 전체라 안 씀
    expect(shelterExclusion(f('초등학교 앞', 35.995, 129.555), [watch]), isNull);       // 관심 단계는 안 뺌
    expect(shelterExclusion(f('여의주타워 지하주차장', 35.98, 129.54), [flood]), '침수 중 지하 시설');
    expect(shelterExclusion(f('여의주타워 지하주차장', 35.98, 129.54), [rain]), isNull);
  });

  test('경로 응답: 위험 정보를 못 읽었으면 알림', () {
    final r = routeFromJson({'profile': 'adult', 'distance_m': 100, 'duration_s': 60, 'avoided': [], 'still_inside': [],
      'hazards_ok': false, 'geometry': '_p~iF~ps|U'}, 'x', RouteType.nearest);
    expect(r.riskAvoidanceSummary, contains('위험 정보를 확인하지 못해'));
  });
}

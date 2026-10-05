import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';

void main() {
  test('침수 격자: 서버가 영역 모양대로 자른 칸(Polygon·MultiPolygon)을 그 모양 그대로', () {
    final grids = floodGridFromGeoJson({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'id': '129555_35990',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [[129.555, 35.990], [129.556, 35.990], [129.5555, 35.9908], [129.555, 35.990]]
            ]
          },
          'properties': {'level': 'warning', 'area_id': 7, 'source': '구룡포환승센터 지표면 수위계'}
        },
        {
          'type': 'Feature',
          'id': '129556_35990',
          'geometry': {
            'type': 'MultiPolygon',
            'coordinates': [
              [[[129.556, 35.990], [129.5565, 35.990], [129.556, 35.9905], [129.556, 35.990]]],
              [[[129.5568, 35.9905], [129.557, 35.9905], [129.557, 35.991], [129.5568, 35.9905]]]
            ]
          },
          'properties': {'level': 'critical'}
        },
      ]
    });
    expect(grids, hasLength(2));
    expect(grids[0].level, '경계');
    expect(grids[0].shapes, hasLength(1));
    expect(grids[0].shapes.first, hasLength(4)); // 네모가 아니라 잘린 삼각형(닫힌 고리)
    expect(grids[0].shapes.first[2].latitude, closeTo(35.9908, 1e-9));
    expect(grids[1].level, '심각');
    expect(grids[1].shapes, hasLength(2));
    expect(grids[1].east, closeTo(129.557, 1e-9));
  });
}

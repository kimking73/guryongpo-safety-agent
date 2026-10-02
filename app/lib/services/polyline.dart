import 'package:latlong2/latlong.dart';

/// Google 인코딩 polyline (정밀도 1e5, lat·lon 순) → 좌표 목록. 경로 서버 응답의 geometry 형식.
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0, lat = 0, lng = 0;
  int next() {
    var result = 0, shift = 0, b = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    // ~(result >> 1) 대신 산술식: 웹(JS)에서는 ~가 부호 없는 32비트 값을 돌려줘 음수 변화량이 4294967295 근처의 큰 수가 된다
    // (2026-10-02 크롬에서 위도 42985 같은 좌표가 나와 지도가 멈춤)
    return (result & 1) != 0 ? -(result >> 1) - 1 : result >> 1;
  }

  while (index < encoded.length) {
    lat += next();
    lng += next();
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

/// 경로 서버 도로망 범위 (graphhopper/fetch_osm.sh BBOX = AI tools.ROUTE_BOUNDS). 이 밖의 GPS는 쓰지 않는다
const serviceSouth = 35.92, serviceWest = 129.48, serviceNorth = 36.04, serviceEast = 129.60;
/// 대시보드 지도가 보여 주는 범위 = 경로 안내 범위 (구룡포 일대). 이보다 멀리 축소·이동하지 못하게 한다 (태풍 지도는 제외)
final guryongpoBounds = LatLngBounds(const LatLng(serviceSouth, serviceWest), const LatLng(serviceNorth, serviceEast));
const guryongpoMinZoom = 12.0;

bool inServiceArea(LatLng p) =>
    p.latitude >= serviceSouth && p.latitude <= serviceNorth && p.longitude >= serviceWest && p.longitude <= serviceEast;

/// 이만큼(m) 넘게 움직였을 때만 위치를 바꾼다 — 위험도·시설·경로를 다시 불러오는 횟수를 줄인다
const moveThresholdM = 30.0;

/// 위치를 읽지 못한 이유 (화면 안내용)
class LocationUnavailable implements Exception {
  const LocationUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// GPS 읽기. 테스트는 이 클래스를 가짜로 바꾼다 (main.dart locationService provider).
class LocationService {
  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw const LocationUnavailable('기기의 위치 서비스가 꺼져 있습니다.');
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw const LocationUnavailable('위치 권한이 없어 예시 위치를 씁니다.');
    }
  }

  /// 지금 위치 한 번 (GPS 버튼)
  Future<LatLng> current() async {
    await _ensurePermission();
    final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(timeLimit: Duration(seconds: 15)));
    return LatLng(p.latitude, p.longitude);
  }

  /// 움직일 때마다 (앱이 켜져 있는 동안 계속)
  Stream<LatLng> watch() async* {
    await _ensurePermission();
    yield* Geolocator.getPositionStream(locationSettings: const LocationSettings(distanceFilter: 10))
        .map((p) => LatLng(p.latitude, p.longitude));
  }
}

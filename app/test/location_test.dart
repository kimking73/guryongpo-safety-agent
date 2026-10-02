// GPS 위치: 구룡포 안이면 위험도·시설·경로·AI가 그 위치 기준, 밖이거나 권한이 없으면 예시 위치
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:guryongpo_safety/services/location_service.dart';

class FakeGps extends LocationService {
  FakeGps(this.points, {this.fail});
  final List<LatLng> points;
  final LocationUnavailable? fail;
  @override
  Future<LatLng> current() async => fail != null ? throw fail! : points.last;
  @override
  Stream<LatLng> watch() => fail != null ? Stream.error(fail!) : Stream.fromIterable(points);
}

/// 목업 저장소가 받은 출발점을 기록
class OriginSpy extends MockSafetyRepository {
  final origins = <LatLng>[];
  @override
  Future<RiskStatus> risk(LatLng origin) { origins.add(origin); return super.risk(origin); }
}

Future<OriginSpy> boot(WidgetTester t, LocationService gps) async {
  t.view.physicalSize = const Size(1280, 900); t.view.devicePixelRatio = 1; addTearDown(t.view.reset);
  final onError = FlutterError.onError;
  FlutterError.onError = (d) { if (d.library != 'image resource service') onError?.call(d); };
  addTearDown(() => FlutterError.onError = onError);
  SharedPreferences.setMockInitialValues({'profile_setup_complete': true, 'user_mode': 'resident'});
  final spy = OriginSpy();
  await t.pumpWidget(ProviderScope(overrides: [repo.overrideWithValue(spy), locationService.overrideWithValue(gps)], child: const GuryongpoApp()));
  for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 300)); }
  return spy;
}

Future<void> done(WidgetTester t) async { await t.pumpWidget(const SizedBox()); await t.pump(const Duration(seconds: 1)); }

void main() {
  test('구룡포 범위 판단', () {
    expect(inServiceArea(const LatLng(35.9907, 129.5526)), isTrue);
    expect(inServiceArea(const LatLng(36.019, 129.343)), isFalse);   // 포항 시내
  });

  testWidgets('구룡포 안 GPS → 위험도를 그 위치로 요청, 상태 줄 "GPS 위치 기준"', (t) async {
    const here = LatLng(35.9930, 129.5560);
    final spy = await boot(t, FakeGps([here]));
    expect(spy.origins.last, here);
    expect(find.textContaining('GPS 위치 기준'), findsOneWidget);
    await done(t);
  });

  testWidgets('30m 안쪽 움직임은 다시 불러오지 않는다', (t) async {
    final spy = await boot(t, FakeGps(const [LatLng(35.9930, 129.5560), LatLng(35.99305, 129.55605)]));
    expect(spy.origins.where((o) => o == const LatLng(35.99305, 129.55605)), isEmpty);
    await done(t);
  });

  testWidgets('구룡포 밖 GPS → 예시 위치, 이유 표시', (t) async {
    final spy = await boot(t, FakeGps(const [LatLng(36.019, 129.343)]));
    expect(spy.origins.last, originFor(UserMode.resident));
    expect(find.textContaining('구룡포 밖이라 예시 위치'), findsOneWidget);
    await done(t);
  });

  testWidgets('권한 거부 → 예시 위치, 이유 표시', (t) async {
    final spy = await boot(t, FakeGps(const [], fail: const LocationUnavailable('위치 권한이 없어 예시 위치를 씁니다.')));
    expect(spy.origins.last, originFor(UserMode.resident));
    expect(find.textContaining('위치 권한이 없어'), findsOneWidget);
    await done(t);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/origin_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _chip(UserLocation here, {String? label}) => ProviderScope(overrides: [
      userLocation.overrideWithValue(here),
      originLabelProvider.overrideWith((_) => label),
    ], child: const MaterialApp(home: Scaffold(body: OriginChip())));

void main() {
  const p = LatLng(35.985, 129.552);
  testWidgets('출발 칩: 직접 지정한 위치 이름', (t) async {
    await t.pumpWidget(_chip(const UserLocation(p, fromGps: true, manual: true), label: '우리집'));
    expect(find.text('출발: 우리집'), findsOneWidget);
  });
  testWidgets('출발 칩: GPS', (t) async {
    await t.pumpWidget(_chip(const UserLocation(p, fromGps: true)));
    expect(find.text('출발: 현재 위치 (GPS)'), findsOneWidget);
  });
  testWidgets('출발 칩: GPS 없음 → 구룡포 기본 위치', (t) async {
    await t.pumpWidget(_chip(const UserLocation(p, fromGps: false)));
    expect(find.text('출발: 구룡포 기본 위치'), findsOneWidget);
  });
  testWidgets('칩을 누르면 고르는 방법 목록', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(_chip(const UserLocation(p, fromGps: true)));
    await t.tap(find.byType(ActionChip));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    expect(find.text('현재 위치 (GPS)'), findsOneWidget);
    expect(find.text('지도에서 고르기'), findsOneWidget);
    expect(find.text('주소로 찾기'), findsOneWidget);
  });
}

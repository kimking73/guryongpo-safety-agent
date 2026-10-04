import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/custom_route.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('길찾기: 출발·목적지 입력과 경로 비교 버튼, 목적지 없으면 안내', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: CustomRouteScreen()))));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(find.text('출발지'), findsOneWidget);
    expect(find.text('목적지'), findsOneWidget);
    await t.tap(find.text('경로 비교'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(find.textContaining('목적지 주소를 입력'), findsOneWidget);
  });

  testWidgets('길찾기: 저장한 집이 바로가기 칩으로', (t) async {
    SharedPreferences.setMockInitialValues({
      'optional_profile': '{"homeName":"우리집","homeAddress":"구룡포읍 호미로 152","homeLat":"35.98","homeLon":"129.55"}',
    });
    await t.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: CustomRouteScreen()))));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(find.widgetWithText(ActionChip, '우리집'), findsNWidgets(2)); // 출발·목적지 둘 다
  });
}

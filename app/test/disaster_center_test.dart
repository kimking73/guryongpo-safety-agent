import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/disaster_center.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('flood grid covers Guryongpo and leaves zero/unknown cells unfilled',
      () {
    final grids = demoFloodGrid(0);
    expect(grids, hasLength(32 * 32));
    expect(grids.map((g) => g.west).reduce((a, b) => a < b ? a : b),
        closeTo(129.5, 1e-8));
    expect(grids.map((g) => g.south).reduce((a, b) => a < b ? a : b),
        closeTo(35.93, 1e-8));
    expect(grids.any((g) => g.depthCm == 0 && !g.hasRisk), isTrue);
    expect(
        grids.where((g) => !g.hasRisk).every((g) => g.level == '미확인'), isTrue);
    final allPolygons = floodGridPolygons(grids);
    final severePolygons = floodGridPolygons(grids, severeOnly: true);
    expect(allPolygons.where((p) => p.color == Colors.transparent),
        hasLength(grids.where((g) => !g.hasRisk).length));
    expect(
        severePolygons, hasLength(grids.where((g) => g.level == '심각').length));
  });

  testWidgets('map options remain stable while hazard layers toggle and reset',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final errors = <String>[];
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.library != 'image resource service') {
        errors.add(details.exceptionAsString());
      }
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DisasterDashboard()),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    final floodChip = find.widgetWithText(FilterChip, '침수 격자');
    final windChip = find.widgetWithText(FilterChip, '강풍 화살표·풍속');
    final slideChip = find.widgetWithText(FilterChip, '산사태 위험 안내');
    final overallChip = find.widgetWithText(FilterChip, '전체 재난 표시');
    expect(tester.widget<FilterChip>(overallChip).selected, isTrue);
    expect(tester.widget<FilterChip>(floodChip).selected, isFalse);
    expect(tester.widget<FilterChip>(windChip).selected, isFalse);
    expect(tester.widget<FilterChip>(slideChip).selected, isFalse);
    expect(find.byIcon(Icons.water_drop),
        findsNothing); // Grid cells are filled by server risk stage, not depth icons.
    expect(find.textContaining('주의보: 평균 14m/s'),
        findsNothing); // Composite legend is minimal.
    expect(find.text('침수는 심각 단계만 표시'), findsOneWidget);

    await tester.tap(floodChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilterChip>(overallChip).selected, isFalse);
    expect(tester.widget<FilterChip>(floodChip).selected, isTrue);
    expect(tester.widget<FilterChip>(windChip).selected, isFalse);
    expect(tester.widget<FilterChip>(slideChip).selected, isFalse);

    await tester.tap(windChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilterChip>(floodChip).selected, isTrue);
    expect(tester.widget<FilterChip>(windChip).selected, isTrue);
    expect(tester.widget<FilterChip>(slideChip).selected, isFalse);
    expect(find.text('침수 위험 단계'), findsOneWidget);
    expect(find.text('강풍 기준'), findsOneWidget);
    expect(find.textContaining('주의보: 평균 14m/s'), findsOneWidget);

    await tester.tap(floodChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilterChip>(floodChip).selected, isFalse);
    expect(tester.widget<FilterChip>(windChip).selected, isTrue);
    expect(find.text('격자색은 서버 위험 단계'), findsNothing);
    await tester.tap(windChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilterChip>(windChip).selected, isFalse);
    await tester.tap(overallChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilterChip>(overallChip).selected, isTrue);
    expect(tester.widget<FilterChip>(floodChip).selected, isFalse);
    expect(tester.widget<FilterChip>(windChip).selected, isFalse);
    expect(tester.widget<FilterChip>(slideChip).selected, isFalse);

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  testWidgets(
      'legacy flood map keeps camera valid when overlays rebuild at wide size',
      (tester) async {
    tester.view.physicalSize = const Size(2400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(ProviderScope(
      overrides: [repo.overrideWithValue(MockSafetyRepository())],
      child: const MaterialApp(home: Scaffold(body: MapCard(height: 520))),
    ));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('침수 위험도 확인'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets(
      'dashboard map can be replaced and restored without inherited-element errors',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final errors = <Object?>[];
    final flutterErrors = <String>[];
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError =
        (details) => flutterErrors.add(details.exceptionAsString());

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DisasterDashboard()),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    errors.add(tester.takeException());
    final initialDashboard =
        find.byType(DisasterDashboard).evaluate().isNotEmpty;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TyphoonScreen(initialLocal: true)),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    errors.add(tester.takeException());
    final openedTyphoon = find.byType(TyphoonScreen).evaluate().isNotEmpty;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DisasterDashboard()),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    errors.add(tester.takeException());
    final returnedDashboard =
        find.byType(DisasterDashboard).evaluate().isNotEmpty;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    errors.add(tester.takeException());
    FlutterError.onError = previousErrorHandler;
    expect(initialDashboard, isTrue);
    expect(openedTyphoon, isTrue);
    expect(returnedDashboard, isTrue);
    expect(errors.whereType<Object>(), isEmpty, reason: errors.join('\n'));
    expect(flutterErrors, isEmpty, reason: flutterErrors.join('\n'));
  });
}

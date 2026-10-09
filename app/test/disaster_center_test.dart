import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/disaster_center.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:guryongpo_safety/ui/map_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _has(String s) => find.textContaining(s, findRichText: true);

Future<void> _openLegend(WidgetTester t, {bool routeMode = false, bool hasRoute = false}) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (c) => Stack(children: [
                    mapLegendButton(c,
                        routeMode: routeMode,
                        visible: const {HazardKind.flood, HazardKind.slide},
                        hasRoute: hasRoute,
                        hasDestination: hasRoute,
                        hasSea: false),
                  ])))));
  await t.tap(find.text('범례'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('지도 범례 (2026-10-09): 기본은 핵심만, 기술 설명은 접힌 범례 자세히 안 · 경로 전에는 목적지·경로 없음', (t) async {
    await _openLegend(t);
    for (final s in ['노랑 · 주의', '주황 · 경계', '빨강 · 심각', '파란 테두리 · 침수', '갈색 테두리 · 산사태', '현위치', '범례 자세히']) {
      expect(_has(s), findsWidgets, reason: s);
    }
    expect(_has('목적지'), findsNothing);
    expect(_has('파란 선'), findsNothing);
    expect(_has('물방울'), findsNothing);       // 접혀 있음
    expect(_has('칸 가운데 점'), findsNothing);
    await t.tap(find.text('범례 자세히'));
    await t.pumpAndSettle();
    expect(_has('물방울'), findsWidgets);
    expect(_has('칸 가운데 점'), findsWidgets);
    expect(_has('채움색 = 위험 단계'), findsWidgets);
  });

  testWidgets('지도 범례: 경로 안내 중이면 대피소·의료시설·목적지·파란 선·주황 경고', (t) async {
    await _openLegend(t, routeMode: true, hasRoute: true);
    for (final s in ['대피소', '의료시설', '목적지', '파란 선', '주황 경고 표시']) {
      expect(_has(s), findsWidgets, reason: s);
    }
    expect(_has('숫자 원'), findsNothing);       // 묶음 표시는 자세히 안
  });

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

    MapMenuButton btn(String label) => tester.widget<MapMenuButton>(find.widgetWithText(MapMenuButton, label));
    Future<void> tap(String label) async {
      await tester.tap(find.widgetWithText(MapMenuButton, label));
      await tester.pump(const Duration(milliseconds: 100));
    }

    const all = ['전체 재난 표시', '태풍', '침수 격자', '강풍', '산사태 위험 지역'];
    // 처음: 재난 지도 메뉴가 펼쳐져 있고 재난은 모두 켜짐 (종합 보기)
    expect(btn('재난 지도').expanded, isTrue);
    expect(btn('경로 안내').expanded, isFalse);
    for (final l in all) {
      expect(btn(l).selected, isTrue, reason: l);
    }
    expect(find.byIcon(Icons.water_drop),
        findsNothing); // Grid cells are filled by server risk stage, not depth icons.
    expect(find.textContaining('주의보: 평균 14m/s'),
        findsNothing); // Composite legend is minimal.
    expect(find.text('침수는 심각 단계만 표시'), findsOneWidget);

    // 모두 켜진 상태에서 '전체 재난 표시' → 모두 끔
    await tap('전체 재난 표시');
    for (final l in all) {
      expect(btn(l).selected, isFalse, reason: l);
    }

    // 여러 개 동시 선택
    await tap('침수 격자');
    await tap('강풍');
    expect(btn('침수 격자').selected, isTrue);
    expect(btn('강풍').selected, isTrue);
    expect(btn('산사태 위험 지역').selected, isFalse);
    expect(btn('전체 재난 표시').selected, isFalse);
    expect(find.text('침수 위험 단계'), findsOneWidget);
    expect(find.text('강풍 기준'), findsOneWidget);
    expect(find.textContaining('주의보: 평균 14m/s'), findsOneWidget);

    await tap('침수 격자');
    expect(btn('침수 격자').selected, isFalse);
    expect(btn('강풍').selected, isTrue);
    expect(find.text('격자색은 서버 위험 단계'), findsNothing);

    // 하나씩 다 켜면 '전체' 표시도 켜진다
    await tap('침수 격자');
    await tap('산사태 위험 지역');
    expect(btn('전체 재난 표시').selected, isFalse);
    await tap('태풍');
    expect(btn('전체 재난 표시').selected, isTrue);
    expect(find.textContaining('태풍 경로는 구룡포 밖까지'), findsOneWidget);
    // 일부만 켜져 있을 때 '전체' → 모두 켬
    await tap('강풍');
    expect(btn('전체 재난 표시').selected, isFalse);
    await tap('전체 재난 표시');
    for (final l in all) {
      expect(btn(l).selected, isTrue, reason: l);
    }

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

  group('지도 메뉴 (2026-10-09)', () {
    Future<void> pumpDash(WidgetTester tester,
        {WhereNow where = const WhereNow(WhereKind.land), Size size = const Size(1280, 2400)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
          overrides: [repo.overrideWithValue(MockSafetyRepository())],
          child: MaterialApp(home: Scaffold(body: _RouteTypeHost(where: where)))));
      await tester.pump(const Duration(milliseconds: 100));
    }

    MapMenuButton btn(WidgetTester t, String label) =>
        t.widget<MapMenuButton>(find.widgetWithText(MapMenuButton, label));
    Future<void> tap(WidgetTester t, String label) async {
      // 좁은 화면에서는 지도 카드가 아래에 있어 아직 만들어지지 않았을 수 있다 — 보일 때까지 내린다
      await t.scrollUntilVisible(find.widgetWithText(MapMenuButton, label), 300,
          scrollable: find.descendant(of: find.byType(DisasterDashboard), matching: find.byType(Scrollable)).first);
      await t.pump();
      await t.tap(find.widgetWithText(MapMenuButton, label));
      await t.pump(const Duration(milliseconds: 100));
    }

    // 지도 타일 다운로드 오류(테스트 환경)만 무시하고, 나머지 오류(넘침 등)는 그대로 실패로 본다
    void ignoreTileErrors() {
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.library != 'image resource service') onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
    }

    testWidgets('상위 메뉴는 하나만 펼치고, 경로 방식은 하나만 고른다', (t) async {
      ignoreTileErrors();
      await pumpDash(t);
      expect(find.text('대피소·의료시설 경로'), findsNothing);
      expect(find.text('주소로 길찾기'), findsNothing);
      expect(find.textContaining('출발:'), findsNothing);
      expect(find.widgetWithText(MapMenuButton, '현위치'), findsOneWidget);
      expect(find.widgetWithText(MapMenuButton, '최단 거리'), findsNothing);

      await tap(t, '경로 안내');
      expect(btn(t, '경로 안내').expanded, isTrue);
      expect(btn(t, '재난 지도').expanded, isFalse);
      expect(find.widgetWithText(MapMenuButton, '전체 재난 표시'), findsNothing); // 재난 지도 하위 항목은 접힘
      expect(btn(t, '안전한 경로').selected, isTrue);
      expect(btn(t, '최단 거리').selected, isFalse);
      expect(find.widgetWithText(MapMenuButton, '해상 경로 안내'), findsNothing);

      await tap(t, '최단 거리');
      expect(btn(t, '최단 거리').selected, isTrue);
      expect(btn(t, '안전한 경로').selected, isFalse);
      expect(btn(t, '오르막 회피').selected, isFalse);
      await tap(t, '오르막 회피');
      expect(btn(t, '오르막 회피').selected, isTrue);
      expect(btn(t, '최단 거리').selected, isFalse);

      // 보고 있는 메뉴를 다시 누르면 접힌다
      await tap(t, '경로 안내');
      expect(btn(t, '경로 안내').expanded, isFalse);
      expect(find.widgetWithText(MapMenuButton, '최단 거리'), findsNothing);

      await tap(t, '재난 지도');
      expect(btn(t, '재난 지도').expanded, isTrue);
      expect(btn(t, '경로 안내').expanded, isFalse);
      expect(find.widgetWithText(MapMenuButton, '전체 재난 표시'), findsOneWidget);
    });

    testWidgets('바다면 육상 경로 대신 해상 경로 안내만', (t) async {
      ignoreTileErrors();
      await pumpDash(t, where: const WhereNow(WhereKind.sea));
      await tap(t, '경로 안내');
      expect(find.widgetWithText(MapMenuButton, '해상 경로 안내'), findsOneWidget);
      for (final l in ['최단 거리', '안전한 경로', '오르막 회피']) {
        expect(find.widgetWithText(MapMenuButton, l), findsNothing, reason: l);
      }
      expect(find.widgetWithText(MapMenuButton, '경로 안내'), findsOneWidget); // 상위 메뉴 이름은 그대로
    });

    testWidgets('판별 못 하면 육지·바다를 정하지 않고 위치 확인 안내', (t) async {
      ignoreTileErrors();
      await pumpDash(t, where: const WhereNow(WhereKind.unknown, reason: '판별 데이터 없음.'));
      await tap(t, '경로 안내');
      expect(find.text('위치 확인이 필요해요'), findsOneWidget);
      for (final l in ['최단 거리', '안전한 경로', '오르막 회피', '해상 경로 안내']) {
        expect(find.widgetWithText(MapMenuButton, l), findsNothing, reason: l);
      }
      expect(find.widgetWithText(MapMenuButton, '현위치 확인'), findsOneWidget);
    });

    testWidgets('GPS 가 없으면 위치 확인 안내 + 기본 위치(육지) 기준 경로 방식', (t) async {
      ignoreTileErrors();
      await pumpDash(t, where: const WhereNow(WhereKind.unknown, noGps: true, reason: '위치 권한이 없습니다.'));
      await tap(t, '경로 안내');
      expect(find.text('위치 확인이 필요해요'), findsOneWidget);
      expect(find.textContaining('구룡포 기본 위치에서 출발'), findsOneWidget);
      expect(find.widgetWithText(MapMenuButton, '안전한 경로'), findsOneWidget);
    });

    testWidgets('휴대폰 폭(375px)에서도 넘침 없이 줄바꿈되고 버튼은 44×44 이상', (t) async {
      ignoreTileErrors();
      await pumpDash(t, size: const Size(375, 812));
      void checkSizes() {
        for (final e in find.byType(MapMenuButton).evaluate()) {
          final size = (e.renderObject! as RenderBox).size;
          expect(size.height >= 44 && size.width >= 44, isTrue, reason: '$size');
          expect(size.width <= 375, isTrue, reason: '$size');
        }
      }

      await tap(t, '경로 안내');
      checkSizes();
      await tap(t, '재난 지도'); // 다른 메뉴 → 재난 지도 하위 항목 5개가 펼쳐진다
      expect(find.widgetWithText(MapMenuButton, '산사태 위험 지역'), findsOneWidget);
      checkSizes();
    });
  });
}

/// 경로 방식 선택을 실제로 바꿔 보는 테스트용 껍데기 (main.dart Dashboard 가 하는 일)
class _RouteTypeHost extends StatefulWidget {
  const _RouteTypeHost({required this.where});
  final WhereNow where;
  @override
  State<_RouteTypeHost> createState() => _RouteTypeHostState();
}

class _RouteTypeHostState extends State<_RouteTypeHost> {
  RouteType type = RouteType.safest;
  @override
  Widget build(BuildContext context) => DisasterDashboard(
        where: widget.where,
        routeType: type,
        onRouteTypeChanged: (t) => setState(() => type = t),
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/live_screens.dart';
import 'package:guryongpo_safety/services/demo_mode.dart';

Widget _app(Widget child, List<Override> overrides) =>
    ProviderScope(overrides: overrides, child: MaterialApp(home: Scaffold(body: child)));

void main() {
  test('표시 도우미: 시각·풍향·단계', () {
    expect(windFrom(45), '북동풍');
    expect(windFrom(314.6), '북서풍');
    expect(windFrom(null), '');
    expect(hhmm(null), '-');
    expect(levelKo['advisory'], '주의');
    expect(hazardKo['heavy_rain'], '호우');
  });

  testWidgets('시연 모드 스위치: 끄면 실측, 켜면 가상 화면', (t) async {
    const sw = DemoSwitch(demo: Text('가상'), live: Text('실측'));
    await t.pumpWidget(_app(sw, [showDemoProvider.overrideWithValue(false)]));
    expect(find.text('실측'), findsOneWidget);
    await t.pumpWidget(_app(sw, [showDemoProvider.overrideWithValue(true)]));
    await t.pump();
    expect(find.text('가상'), findsOneWidget);
  });

  testWidgets('태풍이 없으면 지어내지 않고 "자료 없음 · 사유"', (t) async {
    await t.pumpWidget(_app(const LiveTyphoonScreen(), [
      liveDashboardProvider.overrideWith((_) async => {
            'widgets': [
              {'type': 'typhoon', 'emphasized': false, 'data': {'available': false, 'reason': '현재 진행 중인 태풍이 없습니다'}},
            ],
          }),
    ]));
    await t.pumpAndSettle();
    expect(find.textContaining('자료 없음 · 현재 진행 중인 태풍이 없습니다'), findsOneWidget);
    expect(find.textContaining('가상'), findsNothing);
  });

  testWidgets('시연 모드에서만 보는 화면은 실측 모드에서 안내만', (t) async {
    await t.pumpWidget(_app(const DemoOnlyNotice(title: '해상 경로 데모', demo: Text('가상 해상 경로')),
        [showDemoProvider.overrideWithValue(false)]));
    expect(find.text('가상 해상 경로'), findsNothing);
    expect(find.textContaining('시연 모드에서만'), findsOneWidget);
  });
}

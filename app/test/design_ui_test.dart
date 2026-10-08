// 디자인 개편 (2026-10-08): 날씨 6칸 값 뽑기, 탭바 3/4개, AI 추천 질문 → 덧붙일 카드
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/ai_chat.dart';
import 'package:guryongpo_safety/app_shell.dart';
import 'package:guryongpo_safety/dashboard_cards.dart';

void main() {
  test('서버 단계 → 디자인 단계', () {
    expect(levelLabel('normal'), '좋음');
    expect(levelLabel('watch'), '관심');
    expect(levelLabel('advisory'), '주의');
    expect(levelLabel('warning'), '경보');
    expect(levelLabel('critical'), '경보');
    expect(levelLabel(null), '');
  });

  test('날씨 6칸: 시연은 예시 값, 실측은 서버 위젯 값 · 없으면 자료 없음', () {
    expect(weatherItems(null, demo: true).map((w) => w.key),
        ['wind', 'rain', 'wave', 'river', 'dust', 'uv']);

    final live = weatherItems({
      'widgets': [
        {
          'type': 'wind',
          'data': {'value': 21.3, 'wind_gust': 30, 'wind_dir': 45, 'level': 'warning', 'station_name': '구룡포', 'observed_at': null}
        },
        {
          'type': 'water_level',
          'data': {
            'stations': [
              {'station_name': 'A', 'value': 80, 'unit': 'cm', 'level': 'normal'},
              {'station_name': 'B', 'value': 140, 'unit': 'cm', 'level': 'advisory'},
            ]
          }
        },
        {
          'type': 'life_safety',
          'data': {
            'items': [
              {'hazard': 'fine_dust', 'value': 18, 'level': 'normal'},
              {'hazard': 'ultrafine_dust', 'value': 9, 'level': 'watch'},
              {'hazard': 'uv', 'value': 1, 'level': 'normal', 'label': '자외선'},
            ]
          }
        },
        {'type': 'rain', 'data': {'available': false, 'reason': '관측소 점검 중'}},
      ]
    }, demo: false);
    final byKey = {for (final w in live) w.key: w};
    expect(byKey['wind']!.value, '21.3');
    expect(byKey['wind']!.level, '경보');
    expect(byKey['wind']!.note, contains('북동풍'));
    expect(byKey['river']!.value, '140'); // 가장 높은 단계 지점
    expect(byKey['river']!.level, '주의');
    expect(byKey['dust']!.value, '18 / 9');
    expect(byKey['dust']!.level, '관심'); // 둘 중 나쁜 쪽
    expect(byKey['uv']!.level, '좋음');
    expect(byKey['rain']!.value, '-');
    expect(byKey['rain']!.levelText, '자료 없음');
    expect(byKey['rain']!.note, '관측소 점검 중');
    expect(byKey['wave']!.levelText, '자료 없음');
  });

  test('추천 질문 → 덧붙일 카드 (태풍·지원 탭을 AI 대화창으로 옮김)', () {
    expect(cardFor('태풍 대비 체크리스트 알려줘'), 'checklist');
    expect(cardFor('지금 태풍 정보 알려줘'), 'typhoon');
    expect(cardFor('재난 후 내가 받을 수 있는 보험이 있는지 알려줘'), 'support');
    expect(cardFor('가까운 대피소는 어디야?'), isNull);
  });

  testWidgets('하단 탭: 기본 3개, 방재단이면 방재단 현황까지 4개', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(bottomNavigationBar: DsTabBar(current: '/', responder: false))));
    expect(find.text('대시보드'), findsOneWidget);
    expect(find.text('AI 대화창'), findsOneWidget);
    expect(find.text('사용자'), findsOneWidget);
    expect(find.text('방재단 현황'), findsNothing);

    await t.pumpWidget(const MaterialApp(home: Scaffold(bottomNavigationBar: DsTabBar(current: '/team', responder: true))));
    expect(find.text('방재단 현황'), findsOneWidget);
  });

  test('대피 현황 칩 색·글자', () {
    expect(evacStyle(null).label, '응답 전');
    expect(evacStyle('evacuating').label, '대피 중');
    expect(evacStyle('evacuated').label, '대피 완료');
    expect(evacStyle('need_help').label, '도움 필요');
  });
}

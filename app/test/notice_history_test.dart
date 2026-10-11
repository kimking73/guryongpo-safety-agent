import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/notice_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 2026-10-12 사용자 요청: 알림은 짧게 3초, 새 알림이 이전 것을 바로 대신하고, 지난 알림은 종(알림 화면)에서
void main() {
  testWidgets('알림은 3초 뒤 사라지고, 버튼이 있어도 3초, 지난 알림 기록에 남는다', (t) async {
    SharedPreferences.setMockInitialValues({});
    NoticeHistory.clear();
    final key = GlobalKey<ScaffoldMessengerState>();
    await t.pumpWidget(MaterialApp(
        home: NoticeMessenger(key: key, child: const Scaffold(body: SizedBox.expand()))));
    key.currentState!.showSnackBar(const SnackBar(content: Text('첫 알림'), duration: Duration(seconds: 10)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('첫 알림'), findsOneWidget);
    // 새 알림은 줄 서지 않고 바로
    key.currentState!.showSnackBar(SnackBar(
        content: const Text('주민 응답이 왔어요'), action: SnackBarAction(label: '보기', onPressed: () {})));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('첫 알림'), findsNothing);
    expect(find.text('주민 응답이 왔어요'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('주민 응답이 왔어요'), findsNothing);
    expect([for (final e in NoticeHistory.entries.value) e.text], ['주민 응답이 왔어요', '첫 알림']);
  });

  testWidgets('알림 화면의 지난 알림 카드', (t) async {
    SharedPreferences.setMockInitialValues({});
    NoticeHistory.clear();
    NoticeHistory.add('시연 응답: 대피 중', at: DateTime(2026, 10, 12, 3, 5));
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: NoticeHistoryCard())));
    expect(find.text('지난 알림 1개'), findsOneWidget);
    await t.tap(find.text('지난 알림 1개'));
    await t.pumpAndSettle();
    expect(find.text('10/12 03:05'), findsOneWidget);
    await t.tap(find.text('기록 지우기'));
    await t.pumpAndSettle();
    expect(find.text('지난 알림 0개'), findsOneWidget);
  });
}

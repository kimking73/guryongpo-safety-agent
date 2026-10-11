import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/evac_alarm_layer.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/services/evac_alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 재난문자처럼 뜨는 대피 경보 (2026-10-11): 경보 화면은 첫 화면(동의·내 정보) 위에 뜨고, 닫으면 아래 화면 그대로
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    evacAlarmCurrent.value = null;
    evacAlarmShownIds.clear();
  });

  testWidgets('경보 화면은 첫 화면 위에 뜨고, 응답하면 닫혀서 첫 화면이 그대로 보인다', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        builder: (_, child) => EvacAlarmLayer(child: child!),
        home: const Scaffold(body: Text('필수 동의')),
      ),
    ));
    expect(find.text('지금 당장 대피해야 합니다'), findsNothing);

    evacAlarmCurrent.value = demoEvacuationAlert;
    await tester.pumpAndSettle();
    expect(find.text('지금 당장 대피해야 합니다'), findsOneWidget);
    expect(find.text('필수 동의', skipOffstage: false), findsOneWidget);   // 아래 첫 화면은 그대로 남아 있다

    await tester.tap(find.text('대피 완료'));
    await tester.pumpAndSettle();
    expect(evacAlarmCurrent.value, isNull);
    expect(evacAlarmShownIds, contains(demoEvacuationAlert.id));
    expect(find.text('지금 당장 대피해야 합니다'), findsNothing);
    expect(find.text('필수 동의'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));   // 응답 안내 등 남은 타이머
  });

  test('사이렌으로 울릴 푸시 = 대피 경보 + 응답 없는 사람 재알림 (서버 alerts/fcm.py is_alarm 과 같은 기준)', () {
    final a = EvacAlarm.fromPush({'kind': 'evacuation', 'alert_id': 'a1', 'title': '[대피] 호우', 'body': '대피하세요'});
    expect(a?.id, 'a1');
    expect(a?.title, '[대피] 호우');
    expect(a?.summary, '대피하세요');
    expect(a?.responseRequired, isTrue);
    expect(EvacAlarm.fromPush({'kind': 'reminder', 'alert_id': 'a1', 'status': 'no_response'}), isNotNull);
    expect(EvacAlarm.fromPush({'kind': 'reminder', 'alert_id': 'a1', 'status': 'evacuating'}), isNull);
    expect(EvacAlarm.fromPush({'kind': 'alert', 'alert_id': 'a1'}), isNull);
    expect(EvacAlarm.fromPush({'kind': 'evacuation'}), isNull);   // 경보 id 없음
  });
}

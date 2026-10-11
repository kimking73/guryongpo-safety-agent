import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/services/alert_notifications.dart';

/// 주의보·경보 등 일반 재난 알림을 잠금 화면에 (2026-10-11): 누르면 그 경고 화면, 대피 경보 알림과 섞이지 않는다
void main() {
  const alert = AlertItem(
      id: 'a1', title: '[호우 경보] 구룡포읍', level: '경보', time: '', summary: '실내에 머무르세요', guide: '');

  NotificationResponse tap(String? payload) => NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotification, payload: payload);

  tearDown(() {
    AlertNotifications.onOpen = null;
    AlertNotifications.onShow = null;
  });

  test('재난 알림을 누르면 그 경고 id 로 연다', () {
    String? opened;
    AlertNotifications.onOpen = (id, preview) => opened = '$id|${preview.title}';
    expect(AlertNotifications.handleResponse(tap(AlertNotifications.payloadOf(alert))), isTrue);
    expect(opened, 'a1|[호우 경보] 구룡포읍');
  });

  test('경고 화면이 없는 알림(대피 종료·시연)은 경고 화면 대신 앱 안에 내용만 보여 준다', () {
    var opened = false;
    String? shown;
    AlertNotifications.onOpen = (_, __) => opened = true;
    AlertNotifications.onShow = (a) => shown = a.summary;
    expect(AlertNotifications.handleResponse(tap(AlertNotifications.payloadOf(alert, openable: false))), isTrue);
    expect(opened, isFalse);
    expect(shown, '실내에 머무르세요');
  });

  test('대피 경보·시연 알림 payload 는 건드리지 않는다', () {
    expect(AlertNotifications.handleResponse(tap('{"kind":"evac_alarm","alertId":"a1"}')), isFalse);
    expect(AlertNotifications.handleResponse(tap('{"alertId":"a1"}')), isFalse);
    expect(AlertNotifications.handleResponse(tap(null)), isFalse);
  });

  test('같은 경고는 같은 알림 자리, 대피 경보(7310)·시연(7306) 자리와 겹치지 않는다', () {
    final id = AlertNotifications.notificationId('a1');
    expect(AlertNotifications.notificationId('a1'), id);
    expect(id, inInclusiveRange(100000, 999999));
  });
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/domain_models.dart';

// 주의보·경보·대피 종료 등 일반 재난 알림도 잠금 화면에 (2026-10-11 사용자 요청, Android 먼저)
//
// - 서버(server/alerts/fcm.py)는 일반 알림을 Android 채널 'alerts' 로 보낸다 — 앱이 이 채널을 만들어 두어야
//   소리·진동·화면 위 팝업이 나온다 (없으면 '기타' 채널로 떨어져 조용히 들어간다)
// - 앱을 보고 있을 때 온 푸시는 Android 가 띄우지 않으므로 여기서 같은 채널로 직접 띄운다 → 알림 센터·잠금 화면에 남는다
// - 대피 경보(사이렌·전체 화면)는 services/evac_alarm.dart 가 따로 맡는다
// - 아이폰·웹은 아무것도 하지 않는다 (아이폰은 Apple 개발자 계정·APNs 키가 생기면)

class AlertNotifications {
  AlertNotifications._();

  // 서버 fcm.py 의 channel_id 와 같은 이름. 채널 설정(중요도·소리·진동)은 처음 만들 때 고정된다 — 바꾸려면 id 를 새로
  static const channelId = 'alerts';
  static const _kind = 'alert_notice';

  /// 잠금 화면 알림을 쓸 수 있는 기기 (지금은 Android 앱만)
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 알림을 눌렀을 때 — 경고 id 로 경고 화면을 연다 (FcmNotificationService 가 정해 둔다)
  static void Function(String alertId, AlertItem preview)? onOpen;

  /// 열 경고 화면이 없는 알림으로 앱이 열렸을 때 — 앱 안에 내용을 보여 준다 (main.dart 가 정해 둔다)
  static void Function(AlertItem preview)? onShow;

  static const _channel = AndroidNotificationChannel(
    channelId,
    '재난 알림',
    description: '주의보·경보·대피 종료 등 재난 알림',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  );

  /// 'alerts' 채널을 만든다. 백그라운드 푸시가 오기 전에 있어야 하므로 앱 시작·푸시 켜기 때 부른다 (여러 번 불러도 됨)
  static Future<void> ensureChannel() async {
    if (!supported) return;
    try {
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
    } catch (_) {}
  }

  /// 같은 경고는 같은 자리(id)에 — 다시 와도 알림이 두 번 쌓이지 않게. 대피 경보 자리(7310)·시연 자리(7306)와 겹치지 않는 범위
  static int notificationId(String alertId) => 100000 + (alertId.hashCode & 0x3fffffff) % 900000;

  /// [openable] = 눌렀을 때 열 경고 화면이 있는지 (대피 종료처럼 경고 id 가 없는 알림은 앱만 연다)
  static String payloadOf(AlertItem alert, {bool openable = true}) => jsonEncode({
        'kind': _kind,
        'alertId': openable ? alert.id : '',
        'title': alert.title,
        'summary': alert.summary,
      });

  /// 일반 재난 알림을 시스템 알림으로 띄운다 — 소리·진동·화면 위 팝업, 잠금 화면에 내용 전체.
  /// 화면이 꺼져 있으면 켠다: 전체 화면 알림으로 앱을 잠깐 열어 화면을 켠 뒤 바로 잠금 화면으로 돌려
  /// 잠금 화면에 이 알림이 보이게 한다 (MainActivity.kt wakeForNotice, 2026-10-11 — 소리만 나고 화면이 안 켜졌음).
  /// 휴대폰을 쓰는 중이면 Android 가 전체 화면 대신 위쪽 팝업으로만 보여 준다
  static Future<void> show(AlertItem alert, {bool openable = true}) async {
    if (!supported) return;
    await ensureChannel();
    try {
      await FlutterLocalNotificationsPlugin().show(
        notificationId(alert.id),
        alert.title,
        alert.summary,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
            visibility: NotificationVisibility.public,
            playSound: true,
            enableVibration: true,
            ticker: alert.title,
            fullScreenIntent: true,
            styleInformation: BigTextStyleInformation(alert.summary),
          ),
        ),
        payload: payloadOf(alert, openable: openable),
      );
    } catch (_) {}
  }

  /// DemoNotifications 가 받은 알림 응답 중 우리 것이면 처리하고 true
  static bool handleResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.contains('"$_kind"')) return false;
    try {
      final d = jsonDecode(payload) as Map<String, dynamic>;
      final id = '${d['alertId'] ?? ''}';
      final preview = AlertItem(
        id: id,
        title: '${d['title'] ?? '재난 알림'}',
        level: '경보',
        time: '',
        summary: '${d['summary'] ?? ''}',
        guide: '${d['summary'] ?? ''}',
      );
      // 열 경고 화면이 없으면(대피 종료·시연) 앱 안에 내용만 보여 준다 — 화면이 켜지며 앱이 열렸을 때도 알림 내용이 보이게
      id.isEmpty ? onShow?.call(preview) : onOpen?.call(id, preview);
    } on FormatException {
      return true;
    } on TypeError {
      return true;
    }
    return true;
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/domain_models.dart';

// 대피 경보를 재난안전문자처럼 (2026-10-11 사용자 요청, Android 먼저)
//
// - 화면이 꺼져 있고 무음 모드여도 울린다: 알림 소리를 '알람' 용도로 내서 벨소리·무음 설정과 상관없이 알람 음량으로 나온다
// - 응답할 때까지 사이렌 반복(insistent) · 긴 진동 · 화면을 켜서 잠금 화면 위에 전체 화면 경보(fullScreenIntent)
// - 경보 화면(mobile/evac_alarm_layer.dart)이 화면 점멸·손전등 깜빡임·음성 안내·3버튼 응답을 맡는다
// - 서버는 대피 경보를 data 전용 FCM 으로 보내고(server/alerts/fcm.py), 앱이 꺼져 있어도 백그라운드 처리기가 이 알림을 띄운다
// - 아이폰·웹은 지금처럼 일반 알림 + 앱 안 팝업 (아이폰 무음 통과는 Apple 'Critical Alerts' 승인 뒤)

/// 지금 띄울 경보 화면 (null = 없음). 첫 화면(동의·내 정보)보다 위에 뜬다 — 닫으면 아래 화면 흐름 그대로.
/// 앱 틀(MaterialApp builder)이 보므로 Riverpod 가 아닌 ValueNotifier
final evacAlarmCurrent = ValueNotifier<AlertItem?>(null);

/// 경보 화면으로 이미 보여 준 경보 — 셸의 대피 확인 팝업이 같은 경보를 한 번 더 띄우지 않게
final evacAlarmShownIds = <String>{};

class EvacAlarm {
  EvacAlarm._();

  static const notificationId = 7310;
  static const _channel = MethodChannel('guardian/alarm');
  static const _kind = 'evac_alarm';

  /// 진동 패턴: 0.8초 울림 · 0.4초 쉼 반복 (재난문자처럼 길게)
  static final _vibration = Int64List.fromList([0, 800, 400, 800, 400, 800, 400, 800]);

  /// 사이렌 + 전체 화면 경보를 쓸 수 있는 기기 (지금은 Android 만)
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// iPhone (2026-10-12): 꺼진 화면을 켜거나 앱을 스스로 깨울 수 없어서, 잠금 화면 알림을 띄우고
  /// 알림을 누르면 경보 화면이 열리며 바로 음성 안내가 시작된다 (EvacuationAlertDialog)
  static bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// '잠금 화면 경보 시연' 버튼을 보일 기기 — Android(사이렌·전체 화면) + iPhone(잠금 화면 알림)
  static bool get demoSupported => supported || _ios;

  /// iPhone 시연: [delay] 뒤 잠금 화면 대피 경보 알림을 OS 에 예약한다 (화면이 꺼져 앱이 멈춰도 울린다)
  static Future<void> scheduleIos(AlertItem alert, Duration delay) async {
    if (!_ios) return;
    await FlutterLocalNotificationsPlugin().zonedSchedule(
      notificationId,
      alert.title,
      alert.summary,
      tz.TZDateTime.now(tz.UTC).add(delay),
      const NotificationDetails(
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.active,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: _payload(alert),
    );
  }

  static String _payload(AlertItem alert) => jsonEncode({
        'kind': _kind,
        'alertId': alert.id,
        'title': alert.title,
        'summary': alert.summary,
        'guide': alert.guide,
      });

  /// 3버튼 (DemoNotifications 와 같은 id — 서버 응답값)
  static const actions = <(String, String)>[
    ('evacuated', '대피 완료'),
    ('evacuating', '대피 중'),
    ('need_help', '도움 필요'),
  ];

  /// 알림을 눌렀거나 전체 화면으로 열렸을 때 (bootstrap 이 정해 둔다)
  static void Function(AlertItem alert)? onOpen;

  /// 알림의 3버튼 중 하나를 눌렀을 때
  static Future<void> Function(AlertItem alert, String status)? onAction;

  // ---- 방재단 배정 안내 (2026-10-12, B12): 서버 FCM responder_assigned → 시각장애인은 화면을 켜고 음성으로 읽는다
  static const etaNotificationId = 7311;
  static const _etaKind = 'responder_eta';

  /// 배정 안내 알림으로 앱이 열렸을 때 읽을 문장 (bootstrap 이 정해 둔다). 정해지기 전에 열리면 [pendingEta]에 둔다
  static void Function(String text, String? incidentId)? onResponderEta;
  static (String, String?)? pendingEta;

  /// FCM data(kind=responder_assigned) → 읽을 문장. 다른 푸시면 null
  static String? etaTextFromPush(Map<String, dynamic> data) {
    if (data['kind'] != 'responder_assigned') return null;
    final text = '${data['tts_text'] ?? ''}'.trim();
    if (text.isNotEmpty) return text;
    final min = int.tryParse('${data['eta_min'] ?? ''}');
    return min == null ? '방재단원이 배정되었습니다. 곧 찾아갑니다.' : '방재단원이 배정되었습니다. 약 $min분 후 도착합니다.';
  }

  /// 화면이 꺼져 있어도 켜서 앱을 여는 배정 안내 알림 (사이렌 없음, 한 번 울림). Android 만
  static Future<void> showResponderEta(String text, {String? incidentId, bool initialize = false}) async {
    if (!supported) return;
    final plugin = FlutterLocalNotificationsPlugin();
    if (initialize) {
      await plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    }
    await plugin.show(
      etaNotificationId,
      '방재단원이 오고 있습니다',
      text,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'responder_eta_v1',
          '방재단 도착 안내',
          channelDescription: '방재단원이 배정되면 도착 예상 시간을 음성으로 알려 줍니다',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          fullScreenIntent: true,
          autoCancel: true,
          styleInformation: BigTextStyleInformation(text),
        ),
      ),
      payload: jsonEncode({'kind': _etaKind, 'text': text, 'incidentId': incidentId}),
    );
  }

  /// 배정 안내를 읽고 난 뒤: 알림을 치우고, 대피 경보 화면이 없으면 잠금 화면 위 표시를 푼다
  static Future<void> doneResponderEta() async {
    if (!supported) return;
    try {
      await FlutterLocalNotificationsPlugin().cancel(etaNotificationId);
    } catch (_) {}
    if (evacAlarmCurrent.value == null) await _invoke('lockScreen', false);
  }

  /// 사이렌 알림을 띄운다. FCM 백그라운드 처리기(다른 isolate)에서도 부르므로 그때는 플러그인을 여기서 초기화한다
  static Future<void> show(AlertItem alert, {bool initialize = false}) async {
    if (!supported) return;
    final plugin = FlutterLocalNotificationsPlugin();
    if (initialize) {
      await plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    }
    await plugin.show(
      notificationId,
      alert.title,
      alert.summary,
      NotificationDetails(
        android: AndroidNotificationDetails(
          // 채널 설정(소리·진동)은 처음 만들 때 고정된다 — 바꾸려면 채널 id 를 새로 (v1 → v2)
          'evacuation_alarm_v1',
          '대피 경보',
          channelDescription: '대피가 필요할 때 무음 모드에서도 울리는 경보',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          sound: const RawResourceAndroidNotificationSound('evac_siren'),
          audioAttributesUsage: AudioAttributesUsage.alarm,
          playSound: true,
          enableVibration: true,
          vibrationPattern: _vibration,
          // 4 = FLAG_INSISTENT: 응답하거나 화면을 만질 때까지 사이렌 반복
          additionalFlags: Int32List.fromList([4]),
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          ticker: '대피 경보',
          styleInformation: BigTextStyleInformation(alert.summary),
          actions: [
            for (final (id, label) in actions)
              AndroidNotificationAction(id, label, showsUserInterface: true, cancelNotification: true),
          ],
        ),
      ),
      payload: _payload(alert),
    );
  }

  /// FCM data(서버 FcmPayload: kind·alert_id·title·body) → 경보. 사이렌으로 울릴 푸시가 아니면 null
  /// (서버 alerts/fcm.py is_alarm 과 같은 기준: 대피 경보 + 응답 없는 사람 재알림, '대피 중' 재확인은 제외)
  static AlertItem? fromPush(Map<String, dynamic> data, {String? title, String? body}) {
    final kind = data['kind'];
    final alarm = kind == 'evacuation' || (kind == 'reminder' && data['status'] == 'no_response');
    if (!alarm) return null;
    final id = '${data['alert_id'] ?? ''}';
    if (id.isEmpty) return null;
    final text = body ?? '${data['body'] ?? data['tts_text'] ?? '지금 계신 곳이 위험합니다. 대피소로 이동하세요.'}';
    return AlertItem(
      id: id,
      title: title ?? '${data['title'] ?? '대피 경보'}',
      level: '경보',
      time: '',
      summary: text,
      guide: '${data['guide'] ?? ''}',
      responseRequired: true,
    );
  }

  /// DemoNotifications 가 받은 알림 응답 중 우리 것이면 처리하고 true
  static Future<bool> handleResponse(NotificationResponse response) async {
    final payload = response.payload;
    if (payload != null && payload.contains('"$_etaKind"')) {
      try {
        final d = jsonDecode(payload) as Map;
        final text = '${d['text'] ?? ''}', incident = d['incidentId'] as String?;
        final open = onResponderEta;
        if (open != null) {
          open(text, incident);
        } else {
          pendingEta = (text, incident);
        }
      } catch (_) {}
      return true;
    }
    if (payload == null || !payload.contains('"$_kind"')) return false;
    final Map<String, dynamic> d;
    try {
      d = jsonDecode(payload) as Map<String, dynamic>;
    } on FormatException {
      return true;
    }
    final alert = AlertItem(
      id: '${d['alertId']}',
      title: '${d['title'] ?? '대피 경보'}',
      level: '경보',
      time: '',
      summary: '${d['summary'] ?? ''}',
      guide: '${d['guide'] ?? ''}',
      responseRequired: true,
    );
    final action = response.actionId;
    if (action != null && action.isNotEmpty) {
      await stop();
      await onAction?.call(alert, action);
    } else {
      onOpen?.call(alert);
    }
    return true;
  }

  /// 사이렌만 멈춘다 (경보 화면을 처음 만졌을 때). 점멸·진동은 응답할 때까지
  static Future<void> silence() async {
    if (!supported && !_ios) return;
    try {
      await FlutterLocalNotificationsPlugin().cancel(notificationId);
    } catch (_) {}
  }

  /// 경보 끝: 사이렌·손전등 끄고 잠금 화면 위 표시를 푼다
  static Future<void> stop() async {
    await silence();
    await torch(false);
    await _invoke('lockScreen', false);
  }

  /// 손전등 켜기/끄기 — 플래시가 없거나 실패하면 조용히 넘어간다
  static Future<void> torch(bool on) => _invoke('torch', on);

  /// 알림 권한 + Android 14부터 사용자가 켜야 하는 '전체 화면 알림' 권한을 묻는다
  static Future<void> requestPermissions() async {
    if (_ios) {
      try {
        await FlutterLocalNotificationsPlugin()
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, sound: true);
      } catch (_) {}
      return;
    }
    if (!supported) return;
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      await android?.requestNotificationsPermission();
      await android?.requestFullScreenIntentPermission();
    } catch (_) {}
  }

  static Future<void> _invoke(String method, Object? arg) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<Object?>(method, arg);
    } catch (_) {}
  }
}

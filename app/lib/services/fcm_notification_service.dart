import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/domain_models.dart';
import '../repositories/mock_repository.dart';
import 'alert_notifications.dart';
import 'app_config.dart';
import 'auth_service.dart';
import 'evac_alarm.dart';
import 'evac_voice_check.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 앱이 꺼진 상태에서 받은 푸시 — 로그인과 같은 Firebase 설정(firebase_options.dart 또는 --dart-define)으로 초기화
  final options = AuthService.firebaseOptions;
  if (Firebase.apps.isEmpty && options != null) {
    await Firebase.initializeApp(options: options);
  }
  // 대피 경보는 서버가 data 전용으로 보낸다 → 여기서 사이렌 + 전체 화면 경보를 직접 띄운다 (2026-10-11)
  final alert = EvacAlarm.fromPush(message.data);
  if (alert != null) await EvacAlarm.show(alert, initialize: true);
  // 방재단 배정 안내: 시각장애인이면 화면을 켜고 앱을 열어 도착 예상 시간을 음성으로 읽는다 (2026-10-12)
  final eta = EvacAlarm.etaTextFromPush(message.data);
  if (eta != null && await EvacVoiceCheck.visionSupportSaved()) {
    await EvacAlarm.showResponderEta(eta, incidentId: message.data['incident_id'] as String?, initialize: true);
  }
}

class FcmNotificationService {
  FcmNotificationService._();

  static final instance = FcmNotificationService._();
  static const _enabledKey = 'c5_fcm_enabled';
  static const _tokenKey = 'c5_fcm_token';
  static const _deviceIdKey = 'c5_fcm_device_id';

  SafetyRepository? _repository;
  Future<void> Function(AlertItem)? _onForeground;
  Future<void> Function(String alertId, AlertItem preview)? _onOpen;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<String>? _tokenSubscription;
  bool _initialized = false;

  Future<bool> get isEnabled async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  Future<String?> get deviceId async =>
      (await SharedPreferences.getInstance()).getString(_deviceIdKey);

  Future<void> initialize({
    required SafetyRepository repository,
    required Future<void> Function(AlertItem) onForeground,
    required Future<void> Function(String, AlertItem) onOpen,
  }) async {
    _repository = repository;
    _onForeground = onForeground;
    _onOpen = onOpen;
    if (_initialized ||
        kIsWeb ||
        !AppConfig.isRemote ||
        Firebase.apps.isEmpty) {
      return;
    }
    // 주의보·경보 등 일반 알림 채널 — 앱이 꺼져 있을 때 Android 가 이 채널로 띄운다 (잠금 화면·소리·진동)
    await AlertNotifications.ensureChannel();
    AlertNotifications.onOpen = (id, preview) => unawaited(_onOpen?.call(id, preview));
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
      // 앱을 보고 있을 때 온 대피 경보: 사이렌을 울리고 경보 화면을 바로 띄운다
      final evac = EvacAlarm.fromPush(message.data,
          title: message.notification?.title, body: message.notification?.body);
      final eta = EvacAlarm.etaTextFromPush(message.data);
      if (evac != null) {
        unawaited(EvacAlarm.show(evac));
        EvacAlarm.onOpen?.call(evac);
      } else if (eta != null) {
        // 방재단 배정 안내: 앱을 보고 있으면 바로 (시각장애인이면 음성으로 — onResponderEta 가 판단)
        // 시각장애인이면 onResponderEta 의 gpt-realtime 이 읽으므로 알림은 읽지 않는다 (두 목소리 겹침 방지)
        unawaited(EvacVoiceCheck.visionSupportSaved().then((vision) =>
            AlertNotifications.show(_preview(message), openable: false, speak: !vision)));
        EvacAlarm.onResponderEta?.call(eta, message.data['incident_id'] as String?);
      } else {
        // 앱을 보고 있어도 알림 센터·잠금 화면에 남게 시스템 알림으로도 띄운다
        final id = message.data['alert_id'] as String?;
        unawaited(AlertNotifications.show(_preview(message),
            openable: id != null && id.isNotEmpty));
      }
      unawaited(_onForeground?.call(_preview(message)));
    });
    _openedSubscription =
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final id = message.data['alert_id'] as String?;
      if (id != null && id.isNotEmpty) {
        unawaited(_onOpen?.call(id, _preview(message)));
      }
    });
    _tokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) => unawaited(_registerToken(token)),
    );
    _initialized = true;

    if (await isEnabled) {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _registerToken(token);
    }
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    final id = initial?.data['alert_id'] as String?;
    if (initial != null && id != null && id.isNotEmpty) {
      await _onOpen?.call(id, _preview(initial));
    }
  }

  Future<AuthorizationStatus> enablePush() async {
    if (kIsWeb || !AppConfig.isRemote || Firebase.apps.isEmpty) {
      return AuthorizationStatus.notDetermined;
    }
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      // 대피 경보가 잠금 화면 위에 뜨려면 '전체 화면 알림' 권한도 (Android 14부터 사용자가 켬)
      await EvacAlarm.requestPermissions();
      await AlertNotifications.ensureChannel();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, true);
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _registerToken(token);
    }
    return settings.authorizationStatus;
  }

  Future<void> disablePush() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    if (token != null) await _repository?.unregisterDeviceToken(token);
    await prefs.remove(_tokenKey);
    await prefs.remove(_deviceIdKey);
    await prefs.setBool(_enabledKey, false);
  }

  Future<void> _registerToken(String token) async {
    if (!await isEnabled || _repository == null) return;
    if (!AuthService.signedIn) return;   // 푸시 등록(기기 토큰 저장)은 로그인한 사람만 (2026-10-08)
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      _ => 'android',
    };
    final deviceId = await _repository!.registerDeviceToken(token, platform);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    if (deviceId != null) await prefs.setString(_deviceIdKey, deviceId);
  }

  AlertItem _preview(RemoteMessage message) {
    final id = message.data['alert_id'] as String? ??
        message.messageId ??
        'push-${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';
    final title = message.notification?.title ??
        message.data['title'] as String? ??
        '재난 알림';
    final body = message.notification?.body ??
        message.data['body'] as String? ??
        message.data['tts_text'] as String? ??
        '새 재난 알림이 도착했습니다.';
    return AlertItem(
      id: id,
      title: title,
      level: '경보',
      time: _formatTime(message.sentTime ?? DateTime.now()),
      summary: body,
      guide: body,
    );
  }

  String _formatTime(DateTime time) =>
      '${time.toLocal().hour.toString().padLeft(2, '0')}:'
      '${time.toLocal().minute.toString().padLeft(2, '0')}';

  Future<void> dispose() async {
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _tokenSubscription?.cancel();
    _initialized = false;
  }
}

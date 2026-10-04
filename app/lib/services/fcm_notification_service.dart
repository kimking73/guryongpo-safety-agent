import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/domain_models.dart';
import '../repositories/mock_repository.dart';
import 'app_config.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty && AppConfig.hasFirebaseConfig) {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: AppConfig.firebaseApiKey,
        appId: AppConfig.firebaseAppId,
        messagingSenderId: AppConfig.firebaseSenderId,
        projectId: AppConfig.firebaseProjectId,
      ),
    );
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
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
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

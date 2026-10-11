import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alert_notifications.dart';
import 'evac_alarm.dart';
import 'prototype_safety_store.dart';

class DemoNotifications {
  DemoNotifications._();

  static final DemoNotifications instance = DemoNotifications._();
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Future<void> Function(String, EvacuationResponseStatus)? _onResponse;
  bool _initialized = false;

  static const _categoryId = 'EVACUATION_DEMO';
  static const _actions = <(String, String, EvacuationResponseStatus)>[
    ('evacuated', '대피 완료', EvacuationResponseStatus.evacuated),
    ('evacuating', '대피 중', EvacuationResponseStatus.evacuating),
    ('need_help', '도움 필요', EvacuationResponseStatus.needHelp),
  ];

  Future<void> initialize(
    Future<void> Function(String, EvacuationResponseStatus) onResponse,
  ) async {
    if (_initialized) return;
    _onResponse = onResponse;
    if (kIsWeb) {
      _initialized = true;
      return;
    }
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        notificationCategories: [
          DarwinNotificationCategory(
            _categoryId,
            actions: [
              for (final (id, label, _) in _actions)
                DarwinNotificationAction.plain(
                  id,
                  label,
                  options: {DarwinNotificationActionOption.foreground},
                ),
            ],
            options: {DarwinNotificationCategoryOption.customDismissAction},
          ),
        ],
      ),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleResponse,
    );
    _initialized = true;
    // 주의보·경보 채널은 앱을 열 때마다 만든다 — 푸시 설정이 늦거나 실패해도 FCM 이 이 채널로 띄우게
    await AlertNotifications.ensureChannel();
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && response != null) {
      await _handleResponse(response);
    }
  }

  Future<void> _handleResponse(NotificationResponse response) async {
    // 대피 경보 사이렌 알림(services/evac_alarm.dart)은 같은 플러그인을 쓰므로 여기서 넘겨준다
    if (await EvacAlarm.handleResponse(response)) return;
    // 주의보·경보 등 일반 재난 알림(services/alert_notifications.dart)도 같은 플러그인
    if (AlertNotifications.handleResponse(response)) return;
    final status = EvacuationResponseStatusLabel.fromWireValue(
      response.actionId,
    );
    final payload = response.payload;
    if (status == null || payload == null || _onResponse == null) return;
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      final alertId = decoded['alertId'] as String?;
      if (alertId != null) await _onResponse!(alertId, status);
    } on FormatException {
      return;
    } on TypeError {
      return;
    }
  }

  Future<void> showDemoEvacuationAlert({required String alertId}) async {
    if (kIsWeb) {
      throw UnsupportedError('웹은 앱 안의 알림 시뮬레이터를 사용합니다.');
    }
    if (!_initialized) throw StateError('알림 서비스가 초기화되지 않았습니다.');
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      await ios?.requestPermissions(alert: true, badge: false, sound: true);
    }

    final androidActions = [
      for (final (id, label, _) in _actions)
        AndroidNotificationAction(
          id,
          label,
          showsUserInterface: true,
          cancelNotification: true,
        ),
    ];
    await _plugin.show(
      7306,
      '구룡포 안전 · 대피 확인',
      '안전 상태를 선택해 방재단에 알려 주세요.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'evacuation_demo',
          '대피 확인 시연',
          channelDescription: '대피 확인 3버튼 시연 알림',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.alarm,
          actions: androidActions,
          styleInformation: const BigTextStyleInformation(
            '대피 완료, 대피 중, 도움 필요 중 현재 상태를 선택해 주세요.',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          categoryIdentifier: _categoryId,
          presentAlert: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode({'alertId': alertId}),
    );
  }
}

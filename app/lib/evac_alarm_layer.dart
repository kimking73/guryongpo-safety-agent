import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'main.dart';
import 'models/domain_models.dart';
import 'prototype_safety_screens.dart';
import 'services/alert_notifications.dart';
import 'services/evac_alarm.dart';
import 'services/prototype_safety_store.dart';

/// 재난문자처럼 뜨는 대피 경보 화면 (2026-10-11 사용자 요청). 앱 전체(라우터) 위에 깔려서
/// 잠금 화면에서 열려도 첫 화면(동의·내 정보)보다 먼저 보인다 — 닫으면 아래의 첫 화면 흐름이 그대로 이어진다.
/// 화면 점멸·손전등·음성은 사용자 화면 '알림' 스위치대로 (EvacuationAlertDialog), 사이렌은 처음 만질 때 멈춘다.
class EvacAlarmLayer extends StatelessWidget {
  const EvacAlarmLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AlertItem?>(
        valueListenable: evacAlarmCurrent,
        child: child,
        builder: (_, alert, child) => Stack(children: [
          child!,
          if (alert != null)
            Positioned.fill(
              // 앱의 Navigator 와 HeroController 를 나눠 쓰면 안 된다
              child: HeroControllerScope.none(
              child: Navigator(
                // 팝업 안의 안내창·말풍선이 쓸 자리 (라우터 바깥이라 따로)
                key: ValueKey('evac-alarm-${alert.id}'),
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, __, ___) => Consumer(
                    builder: (_, ref, __) => ColoredBox(
                      color: const Color(0xF0101828),
                      child: EvacuationAlertDialog(
                        alert: alert,
                        alarm: true,
                        onClose: () => _close(alert),
                        onRespond: alert.id == prototypeEvacuationAlertId ? (s) => _demoRespond(ref, s) : null,
                      ),
                    ),
                  ),
                ),
              ),
              ),
            ),
        ]),
      );

  static void _close(AlertItem alert) {
    evacAlarmShownIds.add(alert.id);
    if (evacAlarmCurrent.value?.id == alert.id) evacAlarmCurrent.value = null;
    unawaited(EvacAlarm.stop());
  }

  /// 시연 경보('10초 뒤 경보 시연'): 서버 연결 + 시연 모드면 서버 시연 응답으로 (다른 계정의 방재단원 화면에), 아니면 기기에만
  static Future<void> _demoRespond(WidgetRef ref, String status) async {
    final s = EvacuationResponseStatusLabel.fromWireValue(status);
    if (s == null) return;
    await recordPrototypeEvacuationResponse(ref, s, via: 'alarm');
    showResponseMessage('시연 응답: ${s.label} (${demoSavedNote(ref.read(prototypeSafetyProvider))})');
  }
}

/// 시연: [delay] 뒤에 실제와 같은 사이렌 + 전체 화면 경보. 그 사이 화면을 끄고 무음으로 바꿔 확인한다 (기기에만 기록)
Future<void> scheduleEvacAlarmDemo(WidgetRef ref, {Duration delay = const Duration(seconds: 10)}) async {
  await EvacAlarm.requestPermissions();
  await ref.read(prototypeSafetyProvider).startDemoAlert(prototypeEvacuationAlertId);
  evacAlarmShownIds.remove(prototypeEvacuationAlertId);
  // iPhone: 앱이 멈춰도 울리게 OS 에 예약 (Dart 타이머는 화면이 꺼지면 멈춘다)
  await EvacAlarm.scheduleIos(demoEvacuationAlert, delay);
  Timer(delay, () {
    unawaited(EvacAlarm.show(demoEvacuationAlert));
    // 앱을 보고 있으면 전체 화면 알림 대신 위쪽 알림만 나오므로 경보 화면을 바로 띄운다
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      EvacAlarm.onOpen?.call(demoEvacuationAlert);
    }
  });
}

/// 시연: [delay] 뒤에 주의보·경보 같은 일반 재난 알림 — 화면을 끄고 기다리면 잠금 화면에 뜬다 (서버로 보내지 않음)
Future<void> scheduleAlertNoticeDemo({Duration delay = const Duration(seconds: 10)}) async {
  await EvacAlarm.requestPermissions();
  await AlertNotifications.ensureChannel();
  Timer(delay, () {
    unawaited(AlertNotifications.show(
      const AlertItem(
        id: 'demo-alert-notice',
        title: '[호우 경보] 구룡포읍 · 현재 위치 (시연)',
        level: '경보',
        time: '',
        summary: '구룡포읍에 호우 경보가 발효 중입니다. 하천·해안가·비탈면 가까이 가지 말고 안전한 실내에 머무르세요.',
        guide: '',
      ),
      openable: false,   // 시연 알림은 서버에 없는 경고 — 누르면 앱만 연다
    ));
  });
}

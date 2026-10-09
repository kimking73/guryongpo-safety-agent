import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';

import '../dashboard_parts.dart';
import '../live_screens.dart';
import '../main.dart';
import '../models/domain_models.dart';
import '../origin_picker.dart';
import '../prototype_safety_screens.dart';
import '../services/app_config.dart';
import '../services/demo_mode.dart';
import '../services/demo_speech.dart';
import '../services/prototype_safety_store.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'dashboard_cards.dart';
import 'm_disaster_center.dart';

/// 휴대폰 앱 화면(구룡포 안전 비서 모바일 디자인)의 대시보드 연결·대피 확인 창.
/// 웹(브라우저)은 main.dart 의 화면(web-prototype 디자인)을 쓴다 — 고르는 곳은 main.dart [useMobileUi]

/// 대시보드 지도 전체화면 (대피 중 응답·AI 경로 카드가 켠다)
final dashMapFull = StateProvider<bool>((_) => false);

/// 대피 확인 모달을 띄운다 — 전체 화면 덮개(남색 반투명) + 가운데 카드, 접근성 설정이면 화면 점멸·진동
Future<void> showEvacuationAlert(BuildContext context, AlertItem alert,
        {Future<void> Function(String status)? onRespond}) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '대피 상태 확인',
      barrierColor: const Color(0x9914225B),
      pageBuilder: (_, __, ___) =>
          MEvacuationAlertDialog(alert: alert, onRespond: onRespond),
    );

/// 위쪽 '대피 현황' 칩: 응답할 경보가 있으면 그 경보, 시연이면 시연 경보, 아니면 안내
Future<void> openEvacuationCheck(BuildContext context, WidgetRef ref) async {
  final alerts = ref.read(alertCenterProvider);
  final alert = alerts.reversed.where((a) => a.responseRequired).firstOrNull;
  if (alert != null) return showEvacuationAlert(context, alert);
  if (ref.read(showDemoProvider)) return showMEvacuationAlertDemo(context, ref);
  showDsToast(context, '지금 응답할 대피 경보가 없어요');
}

/// 응답이 없을 때 방재단에 알리기까지 기다리는 시간 (디자인 10분)
const evacuationResponseTimeout = Duration(minutes: 10);

class MEvacuationAlertDialog extends ConsumerStatefulWidget {
  const MEvacuationAlertDialog({super.key, required this.alert, this.onRespond});
  final AlertItem alert;

  /// 시연용: 주면 서버로 보내지 않고 이 함수로 응답을 처리한다 (showMEvacuationAlertDemo)
  final Future<void> Function(String status)? onRespond;

  @override
  ConsumerState<MEvacuationAlertDialog> createState() =>
      _MEvacuationAlertDialogState();
}

class _MEvacuationAlertDialogState extends ConsumerState<MEvacuationAlertDialog> {
  bool _busy = false;
  late int _left = evacuationResponseTimeout.inSeconds;
  Timer? _countdown, _flash, _vibrate;
  bool _flashOn = false;
  int _flashTicks = 0;

  @override
  void initState() {
    super.initState();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _busy) return;
      if (_left <= 1) {
        _countdown?.cancel();
        _respond('need_help'); // 응답이 없으면 도움 필요로 방재단에 알린다 (디자인)
      } else {
        setState(() => _left--);
      }
    });
    final a = ref.read(prototypeSafetyProvider).accessibility;
    if (a.screenFlash) {
      _flash = Timer.periodic(evacuationFlashTransitionInterval, (t) {
        if (!mounted || _flashTicks >= 60) {
          t.cancel();
          if (mounted) setState(() => _flashOn = false);
          return;
        }
        setState(() => _flashOn = ++_flashTicks % 2 == 1);
      });
    }
    if (a.strongVibration) {
      var pulses = 0;
      _vibrate = Timer.periodic(const Duration(milliseconds: 450), (t) {
        if (++pulses >= evacuationHapticPulseLimit) t.cancel();
        HapticFeedback.vibrate().catchError((Object _) {});
      });
    }
    // 음성: 사용자 탭 '음성 안내 자동 재생'을 켰거나 시각 지원을 고른 사람만 (시연 화면과 같은 기준)
    if (ref.read(autoVoiceAlerts) || (a.visionSupport && a.voicePrompts)) {
      unawaited(DemoSpeech.instance.speak(
          '대피 확인 경보입니다. 지금 계신 곳은 위험해요. 대피 완료, 대피 중, 도움 필요 중에서 골라 주세요.'));
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _flash?.cancel();
    _vibrate?.cancel();
    super.dispose();
  }

  Future<void> _respond(String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    final demo = widget.onRespond;
    if (demo != null) {
      Navigator.of(context).pop();
      await demo(status);
      return;
    }
    final result = await submitEvacuationResponse(ref, widget.alert, status);
    if (!mounted) return;
    if (result == ResponseSubmitResult.sent ||
        result == ResponseSubmitResult.queued) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = false);
  }

  Widget _choice(String status, String title, String sub, Color circle,
      Widget icon, {bool red = false}) {
    final fg = red ? Colors.white : Ds.ink;
    return Material(
      color: red ? Ds.danger : Ds.bg,
      borderRadius: BorderRadius.circular(38),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : () => _respond(status),
        child: SizedBox(
          height: 76,
          child: Row(children: [
            const SizedBox(width: 10),
            Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: circle, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: dsText(20, weight: FontWeight.w800, color: fg)),
                    Text(sub,
                        style: dsText(15, color: red ? Colors.white : Ds.sub)),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shelters = [
      ...?ref.watch(facilitiesProvider).valueOrNull
    ].where((f) => f.type == FacilityType.shelter);
    final nearestId = shelters.isEmpty ? null : nearestShelterId(ref);
    final nearest = shelters.where((f) => f.id == nearestId).firstOrNull;
    final mm = _left ~/ 60, ss = '${_left % 60}'.padLeft(2, '0');
    final card = Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(30)),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const IconCircle(FontAwesomeIcons.personRunning,
              size: 68, iconSize: 30, bg: Ds.danger, fg: Colors.white),
          const SizedBox(height: 14),
          Text(widget.alert.title,
              textAlign: TextAlign.center,
              style: dsText(14, weight: FontWeight.w800, color: Ds.danger)),
          const SizedBox(height: 6),
          Text('지금 당장 대피해야 합니다',
              textAlign: TextAlign.center,
              style: dsText(25, weight: FontWeight.w800, height: 1.3, spacing: -.5)),
          const SizedBox(height: 4),
          Text('지금 계신 곳은 위험해요. 대피소로 이동하세요.',
              textAlign: TextAlign.center,
              style: dsText(16, weight: FontWeight.w700, color: Ds.sub)),
          if (nearest != null) ...[
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const FaIcon(FontAwesomeIcons.houseFlag, size: 15, color: Ds.navy),
              const SizedBox(width: 6),
              Flexible(
                  child: Text(
                      '${nearest.name} · ${nearest.distanceKm.toStringAsFixed(1)}km',
                      style: dsText(16, weight: FontWeight.w600, color: Ds.sub))),
            ]),
          ],
          if (widget.alert.summary.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(widget.alert.summary,
                textAlign: TextAlign.center,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: dsText(14, color: Ds.muted, height: 1.45)),
          ],
          if (widget.alert.guide.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(widget.alert.guide,
                textAlign: TextAlign.center,
                style: dsText(14, weight: FontWeight.w700, color: Ds.sub, height: 1.45)),
          ],
          const SizedBox(height: 14),
          Text('지금 상태를 알려주세요', style: dsText(18, weight: FontWeight.w800)),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const FaIcon(FontAwesomeIcons.stopwatch, size: 13, color: Ds.danger),
            const SizedBox(width: 6),
            Flexible(
                child: Text('응답이 없으면 $mm분 $ss초 뒤 방재단에 연락해요',
                    style: dsText(14, color: Ds.sub))),
          ]),
          const SizedBox(height: 14),
          _choice('evacuated', '대피 완료', '대피소에 도착했어요', Ds.good,
              const FaIcon(FontAwesomeIcons.check, size: 22, color: Colors.white)),
          const SizedBox(height: 8),
          _choice('evacuating', '대피 중', '지금 대피소로 가고 있어요', Ds.warn,
              const FaIcon(FontAwesomeIcons.personWalking, size: 22, color: Colors.white)),
          const SizedBox(height: 8),
          _choice('need_help', '도움 필요', '혼자 이동하기 어려워요', Colors.white,
              Text('SOS', style: dsText(17, weight: FontWeight.w900, color: Ds.danger)),
              red: true),
          if (_busy)
            const Padding(
                padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
        ]),
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: Stack(children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              key: const ValueKey('evacuation-flash'),
              duration: const Duration(milliseconds: 120),
              opacity: _flashOn ? .55 : 0,
              child: Container(
                  decoration: BoxDecoration(
                      color: Ds.danger,
                      border: Border.all(color: Colors.white, width: 10))),
            ),
          ),
        ),
        SafeArea(child: Center(child: card)),
      ]),
    );
  }
}

/// 시연: 실제 대피 확인 경보와 같은 팝업을 띄운다 (2026-10-05 사용자 요청). 응답은 서버로 보내지 않고 기기의
/// 시연 기록(prototypeSafetyProvider)에만 남는다 — '대피 중'이면 실제처럼 가까운 대피소 경로 안내를 시작한다
const _demoEvacuationAlert = AlertItem(
  id: prototypeEvacuationAlertId,
  title: '대피 필요 · 호우 경보 · 현재 위치 (시연)',
  level: 'warning',
  time: '',
  summary: '구룡포읍행정복지센터 강우량계 시간당 38.5mm · 포항 DT 4단계(경보) (시연 — 실제 경보가 아닙니다). '
      '하천·해안가·비탈면 가까이 가지 마세요.',
  guide: '물이 고인 도로·해안가·맨홀 주변에 접근하지 마세요.',
  responseRequired: true,
);

Future<void> showMEvacuationAlertDemo(BuildContext context, WidgetRef ref) =>
    showEvacuationAlert(
      context,
      _demoEvacuationAlert,
      onRespond: (status) async {
        final s = EvacuationResponseStatusLabel.fromWireValue(status);
        if (s == null) return;
        await recordPrototypeEvacuationResponse(ref, s);
        if (s == EvacuationResponseStatus.evacuated) {
          showResponseMessage('대피 완료를 기록했어요 (시연 — 기기에만 기록, 서버로 보내지 않음)');
        }
      },
    );

class MDashboard extends ConsumerWidget {
  const MDashboard({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final route = ref.watch(routeFacilityId);
    // 화면은 김다인 대시보드 UI 하나. 시연 모드면 가상 시나리오, 아니면 서버 실측 데이터로 채운다 (2026-10-05)
    // 앱 안 가상 화면은 서버 없이 실행(APP_MODE=mock)할 때만. 서버 연결이면 시연 모드도 실측 화면 + 서버 시연 데이터
    final demo = !AppConfig.isRemote;
    final serverDemo = ref.watch(serverDemoProvider);
    final routeAsync = route == null ? null : ref.watch(routeProvider(route));
    final routeType = ref.watch(routeKind);
    final facilities =
        ref.watch(facilitiesProvider).valueOrNull ?? const <Facility>[];
    final destination = route == null ? null : routeDestination(ref, route);
    final live = demo ? null : ref.watch(liveDashboardProvider).valueOrNull;
    return MDisasterDashboard(
      demo: demo,
      floodGrids: demo ? null : ref.watch(floodGridProvider).valueOrNull,
      riskItems: liveRiskItems(live),
      windPoints: demo
          ? const []
          : [
              for (final w in ref.watch(windPointsProvider).valueOrNull ?? const <WindPoint>[])
                (w.position, w.speed, w.dirDeg, w.name, w.observedAt)
            ],
      simulated: serverDemo,
      liveTop: demo ? null : const LiveDashboardTop(),
      liveBottom: demo ? null : const LiveRealtimeSection(),
      routeExtras: Wrap(spacing: 8, runSpacing: 4, children: [
        if (route != customRouteId) const OriginChip(),
        ActionChip(
            avatar: const Icon(Icons.alt_route, size: 18),
            label: Text(route == customRouteId ? '길찾기 다시' : '길찾기 (주소로)'),
            onPressed: () => c.push('/route-search')),
        if (route != null && !demo)
          ActionChip(
              avatar: const Icon(Icons.navigation_outlined, size: 18),
              label: const Text('이동 중 안내'),
              onPressed: () => c.push('/route-follow')),
      ]),
      routeActive: route != null,
      fullScreen: ref.watch(dashMapFull),
      onFullScreenChanged: (v) => ref.read(dashMapFull.notifier).state = v,
      routeSummary: const RouteSummaryRows(),
      facilities: facilities,
      riskAreas: ref.watch(riskAreasProvider).valueOrNull ?? const <RiskArea>[],
      // 길찾기 경로는 사용자가 정한 출발지에서 그린다
      currentLocation: route == customRouteId
          ? (ref.watch(routeStartOrigin) ?? ref.watch(userLocation).position)
          : ref.watch(userLocation).position,
      selectedDestination: destination,
      safetyRoute: routeAsync?.valueOrNull,
      routeLoading: routeAsync?.isLoading ?? false,
      routeError: routeAsync?.hasError == true ? '${routeAsync?.error}' : null,
      routeType: routeType,
      onChooseFacility: () => showModalBottomSheet<void>(
        context: c,
        showDragHandle: true,
        builder: (_) => const ShelterPickerSheet(),
      ),
      travelMode: ref.watch(travelMode),
      onTravelModeChanged: (m) => ref.read(travelMode.notifier).state = m,
      onRouteTypeChanged: (type) {
        if (destination != null) {
          ref.read(routeKind.notifier).state = type;
          ref.invalidate(routeProvider(destination.id));
        }
      },
      onEndRoute: () => ref.read(routeFacilityId.notifier).state = null,
      onRetryRoute:
          route == null ? null : () => ref.invalidate(routeProvider(route)),
    );
  }
}

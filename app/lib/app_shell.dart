import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';

import 'live_screens.dart';
import 'main.dart';
import 'models/domain_models.dart';
import 'patrol_screens.dart';
import 'prototype_safety_screens.dart' show prototypeEvacuationAlertId;
import 'services/app_config.dart';
import 'services/demo_mode.dart';
import 'services/prototype_safety_store.dart';
import 'ui/tokens.dart';
import 'ui/widgets.dart';

/// 하단 탭 (디자인: 대시보드 · AI 대화창 · [방재단 현황] · 사용자)
const tabPaths = ['/', '/ai', '/team', '/profile'];

/// 방재단 탭을 보일지 — 시연이면 기기 시연 역할, 실측이면 서버 역할(responder·admin)
final isResponderProvider = Provider<bool>((ref) {
  if (ref.watch(showDemoProvider)) {
    return ref.watch(prototypeSafetyProvider).hasResponderAccess;
  }
  if (!AppConfig.isRemote) return false;
  final me = ref.watch(meProvider).valueOrNull;
  return isPatrolRole('${me?['role']}');
});

/// 알림 화면을 마지막으로 연 뒤 들어온 경보 수 (종 배지)
final seenAlertCount = StateProvider<int>((_) => 0);

int alertCount(WidgetRef ref) {
  final center = ref.watch(alertCenterProvider).length;
  if (center > 0 || AppConfig.isRemote) return center;
  return ref.watch(alertsProvider).valueOrNull?.length ?? 0;
}

/// 내 대피 응답 (시연 기록 → 서버 경보 응답 → 서버 대피 상태 순). 없으면 null
String? myEvacStatus(WidgetRef ref) {
  final prototype = ref
      .watch(prototypeSafetyProvider)
      .responseFor(prototypeEvacuationAlertId)
      ?.wireValue;
  final fromAlerts = ref
      .watch(alertCenterProvider)
      .reversed
      .map((a) => a.myStatus)
      .where((s) => s == 'evacuating' || s == 'evacuated' || s == 'need_help')
      .firstOrNull;
  return prototype ??
      fromAlerts ??
      (ref.watch(alertEvacuationProvider)?['status'] as String?);
}

/// 대피 상태별 칩 색·글자·아이콘
({String label, Color bg, Color fg, Color iconBg, Color iconFg, FaIconData icon})
    evacStyle(String? status) => switch (status) {
          'evacuated' => (
              label: '대피 완료',
              bg: Ds.goodDeep,
              fg: Colors.white,
              iconBg: Colors.white,
              iconFg: Ds.goodDeep,
              icon: FontAwesomeIcons.check
            ),
          'evacuating' => (
              label: '대피 중',
              bg: Ds.warnDeep,
              fg: Colors.white,
              iconBg: Colors.white,
              iconFg: Ds.warnDeep,
              icon: FontAwesomeIcons.personWalking
            ),
          'need_help' => (
              label: '도움 필요',
              bg: Ds.danger,
              fg: Colors.white,
              iconBg: Colors.white,
              iconFg: Ds.danger,
              icon: FontAwesomeIcons.lifeRing
            ),
          _ => (
              label: '응답 전',
              bg: Colors.white,
              fg: Ds.navy,
              iconBg: Ds.soft,
              iconFg: Ds.navy,
              icon: FontAwesomeIcons.personRunning
            ),
        };

/// 탭 밖 화면 제목
const _pageTitles = {
  '/typhoon': '태풍 정보',
  '/support': '지원 및 복구',
  '/alerts-hub': '알림',
  '/alerts': '경고·대피 확인',
  '/map': '대피소·의료시설',
  '/route-search': '길찾기',
  '/route-follow': '이동 중 안내',
  '/evacuation': '대피 확인 시연',
  '/evacuation-voice': '음성 대피 확인 시연',
  '/accessibility': '접근성 설정',
  '/household': '내 가구 등록',
  '/household/delegate': '가구 대리 등록',
  '/responder': '방재단 현황',
  '/sea-route': '바다 위 대피 경로',
  '/profile/edit': '내 정보 수정',
};

/// 앱 틀: 위쪽 칩 줄 · 화면 · 남색 하단 탭바. 탭 밖 화면은 뒤로 버튼 + 제목만
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  final Set<String> _shownAlertIds = {};
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _presentNextAlert());
  }

  void _schedule() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _presentNextAlert());

  /// 응답이 필요한 경보가 오면 대피 확인 모달을 띄운다
  Future<void> _presentNextAlert() async {
    if (!mounted || _showing) return;
    final pending = ref.read(pendingResponseIdsProvider);
    final alert = ref
        .read(alertCenterProvider)
        .where((a) =>
            a.responseRequired &&
            a.myStatus == null &&
            !pending.contains(a.id) &&
            !_shownAlertIds.contains(a.id))
        .firstOrNull;
    if (alert == null) return;
    _showing = true;
    _shownAlertIds.add(alert.id);
    try {
      await showEvacuationAlert(context, alert);
    } finally {
      _showing = false;
      _schedule();
    }
  }

  @override
  Widget build(BuildContext c) {
    ref.listen<List<AlertItem>>(alertCenterProvider, (_, __) => _schedule());
    ref.listen<Set<String>>(pendingResponseIdsProvider, (previous, next) {
      for (final id in previous ?? const <String>{}) {
        if (!next.contains(id) &&
            ref.read(alertCenterProvider).any(
                (a) => a.id == id && a.responseRequired && a.myStatus == null)) {
          _shownAlertIds.remove(id);
        }
      }
      _schedule();
    });
    ref.watch(gpsTracker);
    final here = GoRouterState.of(c).uri.path;
    final responder = ref.watch(isResponderProvider);
    final isTab = tabPaths.contains(here) && (here != '/team' || responder);
    // 대시보드 지도 전체화면: 위 칩 줄·탭바 없이 지도만
    if (here == '/' && ref.watch(dashMapFull)) {
      return Scaffold(
          backgroundColor: Ds.bg, body: SafeArea(child: widget.child));
    }
    if (!isTab) {
      return Scaffold(
        backgroundColor: Ds.bg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            PageHeader(_pageTitles[here] ?? '구룡포 안전',
                onBack: () => c.canPop() ? c.pop() : c.go('/')),
            Expanded(child: widget.child),
          ]),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Ds.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          TopChipBar(team: here == '/team'),
          Expanded(child: widget.child),
        ]),
      ),
      bottomNavigationBar: DsTabBar(current: here, responder: responder),
    );
  }
}

/// 위쪽 칩 줄: 온라인/오프라인 · 대피 현황 · 알림 종 (방재단 탭이면 방재단원(나) · 실시간)
class TopChipBar extends ConsumerWidget {
  const TopChipBar({super.key, this.team = false});
  final bool team;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(offline);
    final net = Tooltip(
      message: isOffline ? '눌러서 다시 연결' : '눌러서 오프라인 화면 보기',
      child: GestureDetector(
        onTap: () => ref.read(offline.notifier).state = !isOffline,
        child: isOffline
            ? Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                    color: Ds.warnDeep,
                    borderRadius: BorderRadius.circular(Ds.pill),
                    boxShadow: const [
                      BoxShadow(color: Ds.offlineRing, spreadRadius: 3)
                    ]),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const FaIcon(FontAwesomeIcons.plugCircleXmark,
                      size: 15, color: Colors.white),
                  const SizedBox(width: 6),
                  Text('오프라인',
                      semanticsLabel: '오프라인',
                      style: dsText(15,
                          weight: FontWeight.w800, color: Colors.white)),
                ]),
              )
            : const PillChip('온라인',
                icon: FontAwesomeIcons.cloud, fontSize: 15, fg: Ds.navy),
      ),
    );
    final children = <Widget>[net, const SizedBox(width: 8)];
    if (team) {
      children.addAll([
        const Flexible(
            child: PillChip('방재단원(나)', icon: FontAwesomeIcons.idBadge)),
        const Spacer(),
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
              color: Ds.danger, borderRadius: BorderRadius.circular(Ds.pill)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text('실시간',
                style:
                    dsText(14, weight: FontWeight.w800, color: Colors.white)),
          ]),
        ),
      ]);
    } else {
      final st = evacStyle(myEvacStatus(ref));
      final unread = (alertCount(ref) - ref.watch(seenAlertCount)).clamp(0, 99);
      children.addAll([
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
            label: '대피 현황 ${st.label}',
            button: true,
            child: Material(
              color: st.bg,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => openEvacuationCheck(context, ref),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.only(left: 4, right: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconCircle(st.icon,
                        size: 32, iconSize: 13, bg: st.iconBg, fg: st.iconFg),
                    const SizedBox(width: 6),
                    Text('대피 현황 ',
                        style: dsText(13,
                            weight: FontWeight.w600,
                            color: st.fg.withValues(alpha: .9))),
                    Flexible(
                        child: Text(st.label,
                            overflow: TextOverflow.ellipsis,
                            style: dsText(15,
                                weight: FontWeight.w800, color: st.fg))),
                  ]),
                ),
              ),
            ),
          ),
        ),
        ),
        const SizedBox(width: 8),
        Stack(clipBehavior: Clip.none, children: [
          CircleButton(FontAwesomeIcons.solidBell,
              size: 44,
              iconSize: 18,
              tooltip: '알림',
              onPressed: () {
                ref.read(seenAlertCount.notifier).state = alertCount(ref);
                context.push('/alerts-hub');
              }),
          if (unread > 0)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 20),
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                    color: Ds.navy,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Ds.bg, width: 2)),
                alignment: Alignment.center,
                child: Text('$unread',
                    style: dsText(11,
                        weight: FontWeight.w800, color: Colors.white)),
              ),
            ),
        ]),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Row(children: children),
    );
  }
}

/// 남색 하단 탭바
class DsTabBar extends StatelessWidget {
  const DsTabBar({super.key, required this.current, required this.responder});
  final String current;
  final bool responder;

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, String, FaIconData?)>[
      ('/', '대시보드', null),
      ('/ai', 'AI 대화창', FontAwesomeIcons.solidMessage),
      if (responder) ('/team', '방재단 현황', FontAwesomeIcons.userShield),
      ('/profile', '사용자', FontAwesomeIcons.solidUser),
    ];
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      color: Ds.navy,
      padding: EdgeInsets.fromLTRB(10, 8, 10, bottom > 0 ? bottom : 14),
      child: Row(children: [
        for (final (i, t) in tabs.indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _TabButton(tab: t, selected: t.$1 == current)),
        ]
      ]),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.tab, required this.selected});
  final (String, String, FaIconData?) tab;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Ds.navy : Colors.white;
    return Semantics(
      selected: selected,
      button: true,
      label: tab.$2,
      excludeSemantics: true,
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go(tab.$1),
          child: SizedBox(
            height: 62,
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                      width: 24,
                      height: 24,
                      child: Center(
                          child: tab.$3 == null
                              ? _GridIcon(color: fg)
                              : FaIcon(tab.$3, size: 20, color: fg))),
                  const SizedBox(height: 5),
                  Text(tab.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: dsText(14, weight: FontWeight.w800, color: fg)),
                ]),
          ),
        ),
      ),
    );
  }
}

/// 대시보드 탭 아이콘 (네모 4칸)
class _GridIcon extends StatelessWidget {
  const _GridIcon({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    Widget cell() => Container(
        width: 8.5,
        height: 8.5,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(3)));
    return SizedBox(
      width: 20,
      height: 20,
      child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [cell(), cell()]),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [cell(), cell()]),
      ]),
    );
  }
}

/// 넓은 화면(웹·태블릿)에서는 가운데 휴대폰 폭으로 보여 준다
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});
  final Widget? child;
  static const maxWidth = 480.0;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w <= maxWidth + 40) return child ?? const SizedBox();
    return ColoredBox(
      color: const Color(0xFFDDE1EC),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(size: Size(maxWidth, MediaQuery.sizeOf(context).height)),
            child: ClipRect(child: child ?? const SizedBox()),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'models/domain_models.dart';
import 'repositories/mock_repository.dart';
import 'repositories/remote_repository.dart';
import 'services/app_config.dart';
import 'services/auth_service.dart';
import 'services/account_service.dart';
import 'dashboard_parts.dart';

/// APP_MODE=remote면 실제 서버, 아니면 예시 데이터
final repo = Provider<SafetyRepository>(
    (_) => AppConfig.isRemote ? RemoteSafetyRepository() : MockSafetyRepository());
/// The prototype opens as the fishing-resident scenario. Visitors can switch
/// modes in the profile, where the same flood layer is centred on their origin.
final mode = StateProvider<UserMode>((_) => UserMode.resident);
final offline = StateProvider<bool>((_) => false);
final routeFacilityId = StateProvider<String?>((_) => null);

/// `safe` avoids the illustrated hazard; `near` illustrates the shorter route.
final routeKind = StateProvider<RouteType>((_) => RouteType.safest);
final chatMessages = StateProvider<List<ChatMessage>>((_) => []);
final residentOccupation = StateProvider<String>((_) => '어업·수산업');
final autoVoiceAlerts = StateProvider<bool>((_) => false);
final voiceLanguage = StateProvider<String>((_) => '한국어');
final floodLayer = StateProvider<bool>((_) => false);
final floodTime = StateProvider<int>((_) => 0);

// 서버 데이터. 사용자 유형(출발 위치)이 바뀌면 다시 불러온다. 새로고침은 ref.invalidate.
final riskProvider = FutureProvider<RiskStatus>((ref) => ref.watch(repo).risk(ref.watch(mode)));
final riskAreasProvider = FutureProvider<List<RiskArea>>((ref) => ref.watch(repo).riskAreas());
final facilitiesProvider = FutureProvider<List<Facility>>((ref) => ref.watch(repo).getFacilities(ref.watch(mode)));
final alertsProvider = FutureProvider<List<AlertItem>>((ref) => ref.watch(repo).alerts(ref.watch(mode)));
/// AI 답의 "지도에서 경로 보기"로 고른 경로 (routeFacilityId == aiRouteId일 때 지도에 그린다)
const aiRouteId = 'ai';
final aiRoute = StateProvider<ChatAnswer?>((_) => null);
final placesProvider = FutureProvider<List<SavedPlace>>((_) => AccountService().places());
final routeProvider = FutureProvider.family<SafetyRoute, String>((ref, facilityId) async {
  if (facilityId == aiRouteId) {
    final route = ref.watch(aiRoute)?.route;
    if (route == null) throw StateError('AI 경로가 없습니다.');
    return route;
  }
  final facility = (await ref.watch(facilitiesProvider.future)).firstWhere((f) => f.id == facilityId);
  return ref.watch(repo).routeFor(facility, ref.watch(mode), ref.watch(routeKind));
});

/// AI가 안내한 경로를 대시보드 지도에 띄운다 (서버를 다시 부르지 않고 AI가 계산한 경로 그대로)
void showAiRoute(WidgetRef ref, ChatAnswer answer) {
  ref.read(aiRoute.notifier).state = answer;
  ref.invalidate(routeProvider(aiRouteId));
  startRouteToShelter(ref, aiRouteId);
}

/// 지금 지도에 그리는 목적지 (대피소·의료시설 목록 또는 AI 경로의 목적지)
Facility? routeDestination(WidgetRef ref, String id) {
  if (id == aiRouteId) {
    final a = ref.watch(aiRoute);
    if (a == null || a.destinationPos == null) return null;
    final kind = a.destinationKind;
    return Facility(id: aiRouteId, name: a.destinationName ?? '목적지', type: kind == 'shelter' ? FacilityType.shelter : kind == 'medical' ? FacilityType.medical : FacilityType.place,
        position: a.destinationPos!, address: '', description: 'AI 안내 목적지', distanceKm: 0, walkMinutes: 0, accessible: false);
  }
  return ref.watch(facilitiesProvider).valueOrNull?.where((f) => f.id == id).firstOrNull;
}

/// 가장 가까운 '갈 만한' 대피소 (shelterExclusion 규칙). 모두 위험하면 가장 가까운 곳, 못 불러왔으면 예시 대피소
String nearestShelterId(WidgetRef ref) {
  final areas = ref.read(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
  final shelters = [...?ref.read(facilitiesProvider).valueOrNull]
      .where((f) => f.type == FacilityType.shelter)
      .toList()
    ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  if (shelters.isEmpty) return 'gym';
  return (shelters.where((f) => shelterExclusion(f, areas) == null).firstOrNull ?? shelters.first).id;
}

/// The only state transition that starts a route. Every shelter picker uses
/// this so a selected destination always opens the dashboard map route mode.
void startRouteToShelter(WidgetRef ref, String shelterId,
    {RouteType routeType = RouteType.safest}) {
  ref.read(routeKind.notifier).state = routeType;
  ref.read(routeFacilityId.notifier).state = shelterId;
}

void main() => runApp(const ProviderScope(child: GuryongpoApp()));

class GuryongpoApp extends StatelessWidget {
  const GuryongpoApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp.router(
        title: '구룡포 안전',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true,
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xff006b73))),
        routerConfig: appRouter,
      );
}

final appRouter = GoRouter(initialLocation: '/boot', routes: [
  GoRoute(path: '/boot', builder: (_, __) => const BootScreen()),
  GoRoute(path: '/location', builder: (_, __) => const InitialSetupScreen()),
  ShellRoute(builder: (_, __, child) => Shell(child: child), routes: [
    GoRoute(path: '/', builder: (_, __) => const Dashboard()),
    GoRoute(path: '/map', builder: (_, __) => const FacilitiesScreen()),
    GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
    GoRoute(path: '/ai', builder: (_, __) => const AiScreen()),
    GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
  ]),
  GoRoute(
      path: '/facility/:id',
      builder: (_, s) => FacilityScreen(id: s.pathParameters['id']!)),
  GoRoute(
      path: '/alert/:id',
      builder: (_, s) => AlertScreen(id: s.pathParameters['id']!)),
]);

class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key});
  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen> {
  String text = '인증 상태를 확인하는 중…';
  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    final a = await AuthService().initialize();
    final saved = await AccountService().savedMode();
    final complete = await AccountService().hasCompletedSetup();
    if (saved == UserMode.resident.name)
      ref.read(mode.notifier).state = UserMode.resident;
    if (!mounted) return;
    setState(
        () => text = a.isMock ? 'Firebase 미설정: 목업 모드로 시작합니다.' : '익명 로그인 완료');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) context.go(complete ? '/' : '/location');
  }

  @override
  Widget build(BuildContext c) => Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.health_and_safety_outlined, size: 72),
        const SizedBox(height: 16),
        const Text('구룡포 안전',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(text),
        const SizedBox(height: 20),
        const CircularProgressIndicator()
      ])));
}

class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('초기 위치 설정')),
      body: Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.location_on_outlined, size: 62),
                    const SizedBox(height: 16),
                    const Text('현재 위치를 설정하세요',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('목업에서는 구룡포 예시 좌표를 사용합니다.',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                        onPressed: () => c.go('/'),
                        icon: const Icon(Icons.my_location),
                        label: const Text('위치 권한 허용 (예시)')),
                    OutlinedButton.icon(
                        onPressed: () => c.go('/'),
                        icon: const Icon(Icons.map),
                        label: const Text('지도에서 직접 선택 (예시)'))
                  ]))));
}

class Shell extends ConsumerWidget {
  const Shell({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    const nav = [
      ('대시보드', Icons.dashboard_outlined, '/'),
      ('알림', Icons.notifications_outlined, '/alerts'),
      ('프로필', Icons.person_outline, '/profile')
    ];
    final wide = MediaQuery.sizeOf(c).width >= 840;
    final here = GoRouterState.of(c).uri.path;
    final selected = nav.indexWhere((x) => x.$3 == here).clamp(0, 2) as int;
    final body = Column(children: [const StatusLine(), Expanded(child: child)]);
    return Scaffold(
        appBar: wide ? null : AppBar(title: const Text('구룡포 안전')),
        body: wide
            ? Row(children: [
                NavigationRail(
                    selectedIndex: selected,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (i) => c.go(nav[i].$3),
                    destinations: nav
                        .map((x) => NavigationRailDestination(
                            icon: Icon(x.$2), label: Text(x.$1)))
                        .toList()),
                const VerticalDivider(width: 1),
                Expanded(child: body)
              ])
            : body,
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: selected,
                onDestinationSelected: (i) => c.go(nav[i].$3),
                destinations: nav
                    .map((x) =>
                        NavigationDestination(icon: Icon(x.$2), label: x.$1))
                    .toList()));
  }
}

class StatusLine extends ConsumerWidget {
  const StatusLine({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final isOffline = ref.watch(offline);
    return Material(
        color: isOffline ? Colors.amber.shade100 : Colors.teal.shade50,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(isOffline ? Icons.cloud_off : Icons.cloud_done, size: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(isOffline
                      ? '오프라인 · 저장된 예시 정보 · 10:42'
                      : '온라인 · ${AppConfig.dataLabel}${AppConfig.isRemote ? '' : ' · 10:42'}')),
              TextButton(
                  onPressed: () =>
                      ref.read(offline.notifier).state = !isOffline,
                  child: Text(isOffline ? '다시 연결' : '오프라인 보기'))
            ])));
  }
}

class Dashboard extends ConsumerWidget {
  const Dashboard({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => ref.watch(riskProvider).when(
      loading: () => const DashboardLoading(),
      error: (e, _) => LoadError(message: '$e', onRetry: () => ref.invalidate(riskProvider)),
      data: (risk) {
        final resident = ref.watch(mode) == UserMode.resident;
        final route = ref.watch(routeFacilityId);
        final selectedRouteType = ref.watch(routeKind);
        final main = route == null
            ? const ServiceMap()
            : RouteMap(
                key: ValueKey(
                    'route-$route-${selectedRouteType.name}-${ref.watch(mode).name}'),
                facilityId: route);
        final side = AiPanel(risk: risk, resident: resident);
        return LayoutBuilder(
            builder: (_, b) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      b.maxWidth > 900
                          ? Row(children: [
                              const Icon(Icons.notifications_outlined),
                              const SizedBox(width: 6),
                              Text(
                                  '알림 | ${resident ? '주민' : '관광객'} 맞춤 안내'),
                              const Spacer(),
                              FilledButton.icon(
                                  onPressed: () {
                                    startRouteToShelter(ref,
                                        ref.read(routeFacilityId) ?? nearestShelterId(ref));
                                  },
                                  icon: const Icon(Icons.directions_walk),
                                  label: const Text('경로 안내')),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                  onPressed: () => call119(c),
                                  icon: const Icon(Icons.phone_in_talk),
                                  label: const Text('119 연결 및 위치 전송'))
                            ])
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(children: [
                                  const Icon(Icons.notifications_outlined),
                                  const SizedBox(width: 6),
                                  Expanded(
                                      child: Text(
                                          '알림 | ${resident ? '주민' : '관광객'} 맞춤 안내',
                                          overflow: TextOverflow.ellipsis))
                                ]),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                    onPressed: () {
                                      startRouteToShelter(ref,
                                          ref.read(routeFacilityId) ?? nearestShelterId(ref));
                                    },
                                    icon: const Icon(Icons.directions_walk),
                                    label: const Text('경로 안내')),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                    onPressed: () => call119(c),
                                    icon: const Icon(Icons.phone_in_talk),
                                    label: const Text('119 연결 및 위치 전송'))
                              ],
                            ),
                      const SizedBox(height: 10),
                      FloodWarningBanner(risk: risk, resident: resident),
                      const SizedBox(height: 12),
                      RainWaterInfographic(risk: risk),
                      const SizedBox(height: 12),
                      b.maxWidth > 900
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                  Expanded(flex: 3, child: main),
                                  const SizedBox(width: 12),
                                  SizedBox(width: 360, child: side)
                                ])
                          : Column(children: [
                              main,
                              const SizedBox(height: 12),
                              side
                            ]),
                      const SizedBox(height: 12),
                      ModeCards(resident: resident, risk: risk)
                    ])));
      });
}

class RiskCard extends StatelessWidget {
  const RiskCard({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext c) => Card(
      color: risk.color,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 34),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('${risk.level} · ${risk.title}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  Text(risk.summary,
                      style: const TextStyle(color: Colors.white))
                ])),
            TextButton(
                onPressed: () => c.go('/map'),
                child:
                    const Text('대피소 보기', style: TextStyle(color: Colors.white)))
          ])));
}

class FloodWarningBanner extends StatelessWidget {
  const FloodWarningBanner({super.key, required this.risk, required this.resident});
  final RiskStatus risk;
  final bool resident;
  @override
  Widget build(BuildContext context) => AppConfig.isRemote ? _live() : Card(
      color: risk.color,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('${risk.level} · 호우·침수 위험 · 예시 데이터',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
              VoiceButton(text: resident
                  ? '선제 경고. 등록된 직장에 침수될 가능성이 높습니다. 해당 지역 방문을 피하세요.'
                  : '현재 위치 주변 저지대에 침수 가능성이 있습니다. 해안가와 물이 고인 도로를 피하세요.')
            ]),
            const SizedBox(height: 8),
            Text(resident
                ? '선제 경고: 등록된 직장에 침수될 가능성이 높습니다. 해당 지역 방문을 피하세요.'
                : '현재 위치 주변 저지대에 침수 가능성이 있습니다. 안전한 장소를 확인하세요.',
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('예시 데이터 기준, 저지대·침수 구간·맨홀 주변 접근을 피하고 안전한 장소를 확인하세요.',
                style: TextStyle(color: Colors.white)),
          ])));

  /// 실제 위험도 판정 (/api/v1/risk)
  Widget _live() => Card(
      color: risk.color,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(risk.level == '정상' || risk.level == '관심' ? Icons.verified_user_outlined : Icons.warning_amber_rounded, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('${risk.level} · ${risk.title} · ${risk.updatedAt} 판정',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
              VoiceButton(text: '${risk.title}. ${risk.summary}. ${risk.guide}')
            ]),
            const SizedBox(height: 8),
            Text(risk.summary, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(risk.guide, style: const TextStyle(color: Colors.white)),
          ])));
}

/// 서버에서 못 불러왔을 때 (연결 실패 등)
class LoadError extends StatelessWidget {
  const LoadError({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, size: 48), const SizedBox(height: 12),
        Text(message, textAlign: TextAlign.center), const SizedBox(height: 12),
        FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('다시 시도'))])));
}

class RainWaterInfographic extends StatelessWidget {
  const RainWaterInfographic({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context) => AppConfig.isRemote ? _live() : Card(
      child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [const Icon(Icons.water_drop, color: Colors.blue), const SizedBox(width: 6),
            const Text('침수 현황 인포그래픽', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(), Text('마지막 갱신 ${risk.updatedAt} · 예시 데이터', style: const TextStyle(fontSize: 12))]),
          const SizedBox(height: 12),
          Row(children: const [
            Expanded(child: _Metric(label: '현재 강수량', value: '18 mm/h', color: Colors.blue, icon: Icons.umbrella)),
            SizedBox(width: 8), Expanded(child: _Metric(label: '최근 누적', value: '86 mm', color: Colors.indigo, icon: Icons.bar_chart)),
            SizedBox(width: 8), Expanded(child: _Metric(label: '현재 수위', value: '2.8 m', color: Colors.deepOrange, icon: Icons.waves)),
          ]),
          const SizedBox(height: 10),
          Row(children: [const Text('현재 위험 단계  '), Chip(label: Text('${risk.level} · 예시 데이터')), const SizedBox(width: 8), const Expanded(child: Text('현재 수위 위험도'))]),
          Row(children: [const SizedBox(width: 96), Expanded(child: LinearProgressIndicator(value: .82, minHeight: 12, color: Colors.red, backgroundColor: Colors.blue.shade100)), const SizedBox(width: 8), const Text('경계')]),
        ],
      )));

  /// 판정 근거 목록 (관측값·기준). 수치는 서버 판정 문구 그대로
  Widget _live() => Card(
      child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [const Icon(Icons.water_drop, color: Colors.blue), const SizedBox(width: 6),
            const Text('현재 위험 판정 근거', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(), Text('${risk.updatedAt} 판정${risk.stale ? ' · 갱신 지연' : ''}', style: const TextStyle(fontSize: 12))]),
          const SizedBox(height: 10),
          if (risk.details.isEmpty) const Text('발효 중인 호우·침수 등 위험 판정이 없습니다.'),
          ...risk.details.map((d) => Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.circle, size: 8, color: risk.color), const SizedBox(width: 8), Expanded(child: Text(d))]))),
          const SizedBox(height: 8),
          Row(children: [const Text('현재 위험 단계  '), Chip(label: Text(risk.level)), const SizedBox(width: 8),
            Expanded(child: LinearProgressIndicator(value: const {'정상': .05, '관심': .25, '주의': .5, '경계': .75, '심각': 1.0}[risk.level] ?? .05, minHeight: 12, color: risk.color, backgroundColor: Colors.blue.shade100))]),
        ],
      )));
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.color, required this.icon});
  final String label, value; final Color color; final IconData icon;
  @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: color.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: color), Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), Text(label, style: const TextStyle(fontSize: 12))]));
}

class DashboardLoading extends StatelessWidget {
  const DashboardLoading({super.key});
  @override Widget build(BuildContext context) => const Padding(padding: EdgeInsets.all(16), child: Column(children: [LinearProgressIndicator(), SizedBox(height: 16), _LoadingCard(height: 110), SizedBox(height: 12), _LoadingCard(height: 300)]));
}
class _LoadingCard extends StatelessWidget { const _LoadingCard({required this.height}); final double height; @override Widget build(BuildContext context) => Card(child: SizedBox(height: height, child: Center(child: Text('${AppConfig.dataLabel} 준비 중…')))); }

class DashboardInfo extends ConsumerWidget {
  const DashboardInfo({super.key, required this.risk, required this.userMode});
  final RiskStatus risk;
  final UserMode userMode;
  @override
  Widget build(BuildContext c, WidgetRef ref) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          userMode == UserMode.visitor
                              ? '관광객 맞춤 안내'
                              : '주민 맞춤 안내',
                          style: Theme.of(c).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(userMode == UserMode.visitor
                          ? '현재 위치와 가장 안전한 대피소를 우선 안내합니다.'
                          : '등록 장소와 복구 지원 정보를 확인하세요.'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed: () {
                            startRouteToShelter(ref, nearestShelterId(ref));
                            c.go('/');
                          },
                          icon: const Icon(Icons.directions_walk),
                          label: const Text('가장 안전한 경로 안내'))
                    ]))),
        const SizedBox(height: 10),
        Card(
            child: ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('즉시 행동 요령'),
                subtitle: Text(risk.guide),
                trailing: IconButton(
                    icon: const Icon(Icons.auto_awesome),
                    onPressed: () => c.go('/ai')))),
        Card(
            child: ListTile(
                leading: const Icon(Icons.home_work_outlined),
                title: const Text('가까운 예시 대피소'),
                subtitle: const Text('구룡포 실내체육관 · 0.8km · 12분'),
                onTap: () => c.go('/facility/gym'))),
        OutlinedButton.icon(
            onPressed: () => call119(c),
            icon: const Icon(Icons.phone_in_talk),
            label: const Text('119 연결 (예시 위치 표시)'))
      ]);
}

class MapCard extends ConsumerStatefulWidget {
  const MapCard({super.key, required this.height}); final double height;
  @override ConsumerState<MapCard> createState() => _MapCardState();
}
class _MapCardState extends ConsumerState<MapCard> {
  LatLng current = const LatLng(35.9907, 129.5526); String? locationNote; FloodGrid? selected;
  Future<void> locate() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        setState(() => locationNote = 'GPS 권한이 없어 지도에서 위치를 선택할 수 있습니다.'); return;
      }
      final p = await Geolocator.getCurrentPosition();
      if (mounted) setState(() { current = LatLng(p.latitude, p.longitude); locationNote = 'GPS 현재 위치를 반영했습니다.'; });
    } catch (_) { if (mounted) setState(() => locationNote = '위치를 읽지 못했습니다. 지도를 눌러 현재 위치를 선택하세요.'); }
  }
  FloodGrid? gridAt(LatLng p) { for (final g in floodGridsFor(ref.read(floodTime))) { if (p.latitude >= g.south && p.latitude <= g.north && p.longitude >= g.west && p.longitude <= g.east) return g; } return null; }
  @override Widget build(BuildContext c) {
    final active = ref.watch(floodLayer), time = ref.watch(floodTime);
    return Card(clipBehavior: Clip.antiAlias, child: SizedBox(height: widget.height, child: Stack(children: [
      FlutterMap(options: MapOptions(initialCenter: const LatLng(35.9922, 129.5531), initialZoom: 14.5,
        // 구룡포읍 전체 (대피소가 읍 남북으로 흩어져 있다)
        cameraConstraint: CameraConstraint.contain(bounds: LatLngBounds(const LatLng(35.940,129.525), const LatLng(36.035,129.585))),
        onTap: (_, point) { if (locationNote != null) setState(() { current = point; locationNote = '지도에서 선택한 현재 위치입니다.'; }); if (active) setState(() => selected = gridAt(point)); }), children: [
        TileLayer(urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', subdomains: const ['a','b','c'], userAgentPackageName: 'com.example.guryongpo_safety'),
        if (active) PolygonLayer(polygons: floodGridPolygons(time)),
        if (AppConfig.isRemote) PolygonLayer(polygons: riskAreaPolygons(ref.watch(riskAreasProvider).valueOrNull ?? const [])),
        MarkerLayer(markers: [
          Marker(point: current, width: 46, height: 46, child: const Icon(Icons.my_location, color: Colors.blue, size: 34)),
          // 등록 장소 (없고 목업 모드면 예시 집·직장)
          ...[for (final p in ref.watch(placesProvider).valueOrNull ?? const <SavedPlace>[]) (p.position, p.type)]
              .followedBy((ref.watch(placesProvider).valueOrNull?.isEmpty ?? true) && !AppConfig.isRemote
                  ? const [(LatLng(35.9935, 129.5498), '집'), (LatLng(35.9879, 129.5548), '직장')] : const <(LatLng, String)>[])
              .map((p) => Marker(point: p.$1, width: 46, height: 46, child: Icon(p.$2 == '집' ? Icons.home : p.$2 == '직장' ? Icons.business : Icons.place,
                  color: p.$2 == '집' ? Colors.indigo : const Color(0xffe56717), size: 32))),
          ...?ref.watch(facilitiesProvider).valueOrNull?.map((f) => Marker(point: f.position, width: 55, height: 45, child: Icon(f.type == FacilityType.shelter ? Icons.home_work_outlined : Icons.local_hospital, color: f.type == FacilityType.shelter ? Colors.teal : Colors.red)))
        ])
      ]),
      // 예시 침수 그리드는 목업 전용 (실제 모드는 서버 위험 영역을 항상 표시)
      if (!AppConfig.isRemote) Positioned(left: 10, top: 10, child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: active ? const Color(0xff16803c) : Colors.white, foregroundColor: active ? Colors.white : Colors.black87), onPressed: () => ref.read(floodLayer.notifier).state = !active, icon: const Icon(Icons.grid_on), label: const Text('침수 위험도 확인'))),
      Positioned(left: 12, top: 58, child: IconButton.filledTonal(tooltip: 'GPS 현재 위치 확인', onPressed: locate, icon: const Icon(Icons.gps_fixed))),
      if (active) const FloodGridLegend(),
      if (active) Positioned(left: 10, right: 10, bottom: 8, child: Material(color: Colors.white.withValues(alpha: .94), borderRadius: BorderRadius.circular(12), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), child: Row(children: [
        IconButton(tooltip: '시간 흐름 재생', onPressed: () => ref.read(floodTime.notifier).state = (time + 1) % 5, icon: const Icon(Icons.play_circle_outline)),
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: ['현재','1시간 후','3시간 후','6시간 후','오늘 밤'].asMap().entries.map((e) => Padding(padding: const EdgeInsets.only(right: 4), child: ChoiceChip(label: Text(e.value), selected: time == e.key, onSelected: (_) => ref.read(floodTime.notifier).state = e.key))).toList())))
      ])))),
      if (selected != null && active) Positioned(left: 12, bottom: 55, child: Material(elevation: 5, borderRadius: BorderRadius.circular(10), child: Container(width: 210, padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(selected!.name, style: const TextStyle(fontWeight: FontWeight.bold)), Text('${selected!.level} · 예상 ${selected!.depth}', style: TextStyle(color: selected!.color, fontWeight: FontWeight.bold)), Text('업데이트 10:42 · ${selected!.guide}', style: const TextStyle(fontSize: 11))])))),
      if (locationNote != null) Positioned(left: 12, right: 12, top: 105, child: Material(color: Colors.white.withValues(alpha:.93), borderRadius: BorderRadius.circular(8), child: Padding(padding: const EdgeInsets.all(8), child: Text(locationNote!, style: const TextStyle(fontSize: 12)))))
    ])));
  }
}

void showPlaceInfo(BuildContext context, WidgetRef ref, String type, String name, String detail) =>
    showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8), Text('유형: $type · $detail'), const SizedBox(height: 4), Text(AppConfig.isRemote ? '거리는 직선거리 기준 대략값입니다.' : '모든 시설·거리·운영 상태는 예시 데이터입니다.'),
        if (type == '대피소') ...[const SizedBox(height: 12), FilledButton.icon(onPressed: () { Navigator.pop(context); final f = ref.read(facilitiesProvider).requireValue.firstWhere((f) => f.name == name); startRouteToShelter(ref, f.id); context.go('/'); }, icon: const Icon(Icons.directions_walk), label: const Text('경로 안내'))]
      ])));
class FacilitiesScreen extends StatelessWidget {
  const FacilitiesScreen({super.key});
  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (_, b) {
        final list = const FacilityList();
        return b.maxWidth > 850
            ? Row(children: [
                const Expanded(
                    flex: 3,
                    child: Padding(
                        padding: EdgeInsets.all(16),
                        child: MapCard(height: 480))),
                SizedBox(width: 360, child: list)
              ])
            : Column(children: [
                const Padding(
                    padding: EdgeInsets.all(12), child: MapCard(height: 300)),
                Expanded(child: list)
              ]);
      });
}

class FacilityList extends ConsumerStatefulWidget {
  const FacilityList({super.key});
  @override
  ConsumerState<FacilityList> createState() => _FacilityListState();
}

class _FacilityListState extends ConsumerState<FacilityList> {
  bool nearest = false;
  @override
  Widget build(BuildContext c) {
    final areas = ref.watch(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
    int unsafe(Facility f) => shelterExclusion(f, areas) == null ? 0 : 1;
    // 안전 추천: 갈 만한 곳 먼저, 그다음 도보 시간 순 / 가까운 순: 거리만
    final fs = [...?ref.watch(facilitiesProvider).valueOrNull]..sort((a, b) => nearest
        ? a.distanceKm.compareTo(b.distanceKm)
        : unsafe(a) != unsafe(b) ? unsafe(a) - unsafe(b) : a.walkMinutes.compareTo(b.walkMinutes));
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: Text(AppConfig.isRemote ? '주변 대피·의료 시설' : '예시 시설', style: Theme.of(c).textTheme.titleLarge)),
            FilterChip(
                label: Text(nearest ? '가까운 순' : '안전 추천'),
                selected: true,
                onSelected: (_) => setState(() => nearest = !nearest))
          ])),
      if (ref.watch(facilitiesProvider).hasError)
        Padding(padding: const EdgeInsets.all(12), child: Text('${ref.watch(facilitiesProvider).error}')),
      if (ref.watch(facilitiesProvider).isLoading) const LinearProgressIndicator(),
      Expanded(
          child: ListView(
              children: fs
                  .map((f) { final warn = shelterExclusion(f, areas); return Card(
                      child: ListTile(
                          leading: Icon(warn != null ? Icons.warning_amber_rounded : f.type == FacilityType.shelter
                              ? Icons.home_work_outlined
                              : Icons.local_hospital, color: warn != null ? Colors.orange.shade800 : null),
                          title: Text(f.name),
                          subtitle: Text(
                              '${AppConfig.isRemote ? '약 ' : ''}${f.distanceKm}km · 도보 ${f.walkMinutes}분 · ${warn ?? f.description}'),
                          onTap: () {
                            startRouteToShelter(ref, f.id);
                            c.go('/');
                          })); })
                  .toList()))
    ]);
  }
}

class FacilityScreen extends ConsumerWidget {
  const FacilityScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final fs = ref.watch(facilitiesProvider).valueOrNull;
    final f = fs?.where((x) => x.id == id).firstOrNull;
    if (f == null) {
      return Scaffold(appBar: AppBar(title: const Text('시설 상세')),
          body: fs == null ? const Center(child: CircularProgressIndicator()) : const Center(child: Text('시설 정보를 찾지 못했습니다.')));
    }
    final label = AppConfig.isRemote ? '' : '예시 ';
    return Scaffold(
        appBar: AppBar(title: const Text('시설 상세')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(f.name, style: Theme.of(c).textTheme.headlineSmall),
          Chip(
              label:
                  Text(f.type == FacilityType.shelter ? '$label대피소' : f.type == FacilityType.medical ? '$label의료시설' : '목적지')),
          const MapCard(height: 240),
          Card(
              child: Column(children: [
            ListTile(title: const Text('주소'), subtitle: Text(f.address)),
            ListTile(title: const Text('구분'), subtitle: Text(f.description)),
            ListTile(
                title: const Text('거리 및 도보 시간'),
                subtitle: Text('${f.distanceKm}km · ${f.walkMinutes}분')),
            ListTile(
                title: const Text('접근성'),
                subtitle: Text(AppConfig.isRemote
                    ? (f.accessible ? '휠체어 접근 가능' : '확인 필요')
                    : (f.accessible ? '휠체어 접근 가능 (예시)' : '확인 필요 (예시)'))),
            ListTile(
                title: const Text('연락처'), subtitle: Text(f.phone ?? (AppConfig.isRemote ? '정보 없음' : '054-000-0000 (예시)')))
          ])),
          FilledButton.icon(
              onPressed: () {
                startRouteToShelter(ref, f.id);
                c.go('/');
              },
              icon: const Icon(Icons.directions_walk),
              label: const Text('안전 경로 안내'))
        ]));
  }
}

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final s = ref.watch(alertsProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
            Text('알림', style: Theme.of(c).textTheme.headlineSmall),
            Text(AppConfig.isRemote
                ? '현재 위치 주변의 실시간 위험 판정입니다. 공식 재난 문자를 함께 확인하세요.'
                : '모든 항목은 예시 알림이며 실제 재난 경보가 아닙니다.'),
            const SizedBox(height: 10),
            if (s.isLoading) const LinearProgressIndicator(),
            if (s.hasError) LoadError(message: '${s.error}', onRetry: () => ref.invalidate(alertsProvider)),
            if (s.valueOrNull?.isEmpty ?? false) const Card(child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('현재 알림이 없습니다'))),
            ...?(s.valueOrNull?.where((a) => a.id != 'work-flood' || ref.watch(mode) == UserMode.resident).map((a) => Card(
                child: ListTile(
                    leading: Icon(a.read
                        ? Icons.notifications_none
                        : Icons.notifications_active_outlined),
                    title: Text('${a.level} · ${a.title}'),
                    subtitle: Text('${a.summary}\n${a.time}'),
                    isThreeLine: true,
                    onTap: () => c.go('/alert/${a.id}')))))
          ]);
  }
}

class AlertScreen extends ConsumerWidget {
  const AlertScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
        final s = ref.watch(alertsProvider);
        final a = s.valueOrNull?.where((x) => x.id == id).firstOrNull;
        if (a == null)
          return Scaffold(appBar: AppBar(title: const Text('알림 상세')),
              body: Center(child: s.isLoading ? const CircularProgressIndicator() : const Text('이미 해제된 알림입니다.')));
        return Scaffold(
            appBar: AppBar(title: const Text('알림 상세')),
            body: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Chip(label: Text('${a.level} · ${AppConfig.isRemote ? a.time : '예시 알림'}')),
                      Text(a.title, style: Theme.of(c).textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      Text(a.summary),
                      const SizedBox(height: 20),
                      const Text('행동 요령',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(a.guide),
                      VoiceButton(text: '${a.title}. ${a.summary}. ${a.guide}'),
                      if (id == 'work-flood') SupportCard(fishing: ref.watch(residentOccupation) == '어업·수산업'),
                      const Spacer(),
                      FilledButton(
                          onPressed: () { startRouteToShelter(ref, nearestShelterId(ref)); c.go('/'); },
                          child: const Text('침수 위험 그리드·안전 경로 보기')),
                      OutlinedButton(
                          onPressed: () => c.go('/ai'),
                          child: const Text('AI에게 묻기'))
                    ])));
  }
}

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});
  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final input = TextEditingController();
  final messages = <ChatMessage>[
    ChatMessage(AppConfig.isRemote ? '구룡가디언 AI입니다. 현재 위험과 대피소, 가고 싶은 곳까지의 길을 물어보세요.' : '예시 AI 안내입니다. 현재 위험과 대피소에 대해 물어보세요.', false)
  ];
  Future<void> send([String? q]) async {
    final question = q ?? input.text;
    if (question.trim().isEmpty) return;
    setState(() {
      messages.add(ChatMessage(question, true));
      input.clear();
    });
    final answer = await ref.read(repo).ask(question, ref.read(mode));
    if (mounted) setState(() => messages.add(ChatMessage(answer.text, false, answer: answer)));
  }

  @override
  Widget build(BuildContext c) => Column(children: [
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text(AppConfig.isRemote ? '실시간 데이터 기반 AI 답변 · 공식 재난 안내를 함께 확인하세요.' : '목업 데이터 기반 답변 · 실제 재난 지시가 아닙니다.')),
        Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(
              spacing: 8,
              children: ['가까운 대피소는 어디야?', '지금 침수 위험이 있어?', '도보로 안전하게 갈 수 있어?']
                  .map((q) =>
                      ActionChip(label: Text(q), onPressed: () => send(q)))
                  .toList()),
          const SizedBox(height: 14),
          ...messages.map((m) => Align(
              alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m.text),
                        if (m.answer?.route != null) RouteButton(onPressed: () { showAiRoute(ref, m.answer!); context.go('/'); }),
                      ])))))
        ])),
        Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: input,
                      onSubmitted: (_) => send(),
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(), hintText: '메시지 입력…'))),
              IconButton(onPressed: send, icon: const Icon(Icons.send))
            ]))
      ]);
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final current = ref.watch(mode);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('사용자 정보', style: Theme.of(c).textTheme.headlineSmall),
      const SizedBox(height: 12),
      SegmentedButton<UserMode>(
          segments: const [
            ButtonSegment(value: UserMode.visitor, label: Text('관광객')),
            ButtonSegment(value: UserMode.resident, label: Text('주민'))
          ],
          selected: {
            current
          },
          onSelectionChanged: (v) {
            ref.read(mode.notifier).state = v.first;
            AccountService().saveMode(v.first.name);
          }),
      Card(
          child: Column(children: const [
        ListTile(title: Text('익명 사용자'), subtitle: Text('mock-guryongpo-user')),
        ListTile(title: Text('이동수단'), subtitle: Text('도보')),
        ListTile(title: Text('접근성'), subtitle: Text('휠체어 접근 우선 (예시)'))
      ])),
      Card(
          child: Column(children: [
        const ListTile(
            title: Text('계정 연결'), subtitle: Text('설정값이 없으면 목업 로그인으로 동작합니다.')),
        ListTile(
            leading: const Icon(Icons.g_mobiledata),
            title: const Text('Google 로그인'),
            onTap: () => AccountService().signInMock(SignInMethod.google)),
        ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Naver 이메일 로그인'),
            onTap: () => AccountService().signInMock(SignInMethod.naver))
      ])),
      Card(child: Column(children: [
        ListTile(title: const Text('음성 안내 설정'), subtitle: Text('언어: ${ref.watch(voiceLanguage)} · 접근성 기능')),
        SwitchListTile(value: ref.watch(autoVoiceAlerts), title: const Text('재난 경고 자동 음성 재생'), subtitle: const Text('기본값: 꺼짐 · 사용자가 설정한 경우에만 자동 재생'), onChanged: (v) => ref.read(autoVoiceAlerts.notifier).state = v),
        SegmentedButton<String>(segments: const [ButtonSegment(value: '한국어', label: Text('한국어')), ButtonSegment(value: 'English', label: Text('English'))], selected: {ref.watch(voiceLanguage)}, onSelectionChanged: (v) => ref.read(voiceLanguage.notifier).state = v.first),
        const SizedBox(height: 10),
      ])),
      Card(child: Column(children: [
          const ListTile(title: Text('등록 장소'), subtitle: Text('지도에 표시하고, AI에게 "집까지", "직장까지"처럼 물을 수 있어요. 이 기기에만 저장됩니다.')),
          for (final p in ref.watch(placesProvider).valueOrNull ?? const <SavedPlace>[])
            ListTile(leading: Icon(p.type == '집' ? Icons.home : p.type == '직장' ? Icons.business : Icons.place),
                title: Text(p.type == '기타' ? p.name : '${p.type} · ${p.name}'),
                subtitle: Text('${p.position.latitude.toStringAsFixed(5)}, ${p.position.longitude.toStringAsFixed(5)} · 알림 ${p.alert ? '켜짐' : '꺼짐'}'),
                trailing: IconButton(tooltip: '삭제', icon: const Icon(Icons.delete_outline), onPressed: () async {
                  await AccountService().removePlace(p.id);
                  ref.invalidate(placesProvider);
                })),
          ListTile(leading: const Icon(Icons.add_location_alt_outlined), title: const Text('장소 등록'), subtitle: const Text('장소명 · 유형 · 지도에서 위치 선택 · 알림 설정'), onTap: () => showModalBottomSheet<void>(context: c, showDragHandle: true, isScrollControlled: true, builder: (_) => const _PlaceForm())),
      ])),
      if (current == UserMode.resident)
        Card(child: Column(children: [
          ListTile(title: const Text('직업'), subtitle: Text(ref.watch(residentOccupation)), trailing: DropdownButton<String>(value: ref.watch(residentOccupation), items: const [DropdownMenuItem(value: '어업·수산업', child: Text('어업·수산업')), DropdownMenuItem(value: '기타 직업', child: Text('기타 직업'))], onChanged: (v) => ref.read(residentOccupation.notifier).state = v!)),
        ])),
      const OptionalDetailsCard()
    ]);
  }
}

/// 장소 등록: 이름·유형을 적고 작은 지도에서 눌러 위치를 고른다 (주소 검색은 앱에 지도 API 키를 두지 않으려고 쓰지 않는다)
class _PlaceForm extends ConsumerStatefulWidget { const _PlaceForm(); @override ConsumerState<_PlaceForm> createState() => _PlaceFormState(); }
class _PlaceFormState extends ConsumerState<_PlaceForm> {
  String type = '집';
  bool alert = true;
  LatLng? point;
  final name = TextEditingController();
  @override
  void dispose() { name.dispose(); super.dispose(); }
  Future<void> save() async {
    final label = name.text.trim().isEmpty ? type : name.text.trim();
    await AccountService().addPlace(SavedPlace(id: DateTime.now().microsecondsSinceEpoch.toString(), name: label, type: type, position: point!, alert: alert));
    ref.invalidate(placesProvider);
    if (mounted) Navigator.pop(context);
  }
  @override
  Widget build(BuildContext c) => SafeArea(child: Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(c).bottom),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('장소 등록', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: const InputDecoration(labelText: '장소명 (비우면 유형 이름)', border: OutlineInputBorder())),
        const SizedBox(height: 9),
        DropdownButtonFormField<String>(initialValue: type, decoration: const InputDecoration(labelText: '유형', border: OutlineInputBorder()),
            items: const [DropdownMenuItem(value: '집', child: Text('집')), DropdownMenuItem(value: '직장', child: Text('직장')), DropdownMenuItem(value: '기타', child: Text('기타'))],
            onChanged: (v) => setState(() => type = v!)),
        const SizedBox(height: 9),
        Text(point == null ? '아래 지도에서 위치를 눌러 고르세요' : '선택한 위치: ${point!.latitude.toStringAsFixed(5)}, ${point!.longitude.toStringAsFixed(5)}', style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        SizedBox(height: 220, child: ClipRRect(borderRadius: BorderRadius.circular(10), child: FlutterMap(
            options: MapOptions(initialCenter: const LatLng(35.9910, 129.5530), initialZoom: 15,
                cameraConstraint: CameraConstraint.contain(bounds: LatLngBounds(const LatLng(35.940, 129.525), const LatLng(36.035, 129.585))),
                onTap: (_, p) => setState(() => point = p)),
            children: [
              TileLayer(urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', subdomains: const ['a', 'b', 'c'], userAgentPackageName: 'com.example.guryongpo_safety'),
              if (point != null) MarkerLayer(markers: [Marker(point: point!, width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.red, size: 36))]),
            ]))),
        TextButton.icon(onPressed: () => setState(() => point = originFor(ref.read(mode))), icon: const Icon(Icons.my_location), label: const Text('지금 출발 위치로')),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: alert, title: const Text('알림 수신'), onChanged: (v) => setState(() => alert = v)),
        FilledButton(onPressed: point == null ? null : save, child: const Text('등록하기')),
      ]))));
}

class OptionalDetailsCard extends StatefulWidget {
  const OptionalDetailsCard({super.key});
  @override
  State<OptionalDetailsCard> createState() => _OptionalDetailsCardState();
}

class _OptionalDetailsCardState extends State<OptionalDetailsCard> {
  final values = <String, String>{};
  final controller = TextEditingController();
  String field = '자주 가는 장소';
  final fields = [
    '자주 가는 장소',
    '보호 동반자',
    '보행 능력',
    '시각 지원',
    '청각 지원',
    '혈액형',
    '직업',
    '비상 연락처'
  ];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final v = await AccountService().optionalProfile();
    if (mounted) setState(() => values.addAll(v));
  }

  Future<void> save() async => AccountService().saveOptionalProfile(values);
  @override
  Widget build(BuildContext c) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('선택 정보', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('개인정보는 선택 입력이며 기기에 저장됩니다.'),
            DropdownButton<String>(
                value: field,
                isExpanded: true,
                items: fields
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (x) => setState(() => field = x!)),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: controller,
                      decoration: const InputDecoration(labelText: '값 입력'))),
              IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    if (controller.text.isNotEmpty) {
                      setState(() => values[field] = controller.text);
                      save();
                      controller.clear();
                    }
                  })
            ]),
            ...values.entries.map((e) => ListTile(
                title: Text(e.key),
                subtitle: Text(e.value),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () {
                        setState(() {
                          field = e.key;
                          controller.text = e.value;
                        });
                      }),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        setState(() => values.remove(e.key));
                        save();
                      })
                ])))
          ])));
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

Future<void> call119(BuildContext c) async {
  ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
      content: Text('예시 현재 위치: 35.9907, 129.5526 · 실제 위치 전송은 구현하지 않았습니다.')));
  await launchUrl(Uri.parse('tel:119'));
}

class InitialSetupScreen extends ConsumerStatefulWidget {
  const InitialSetupScreen({super.key});
  @override
  ConsumerState<InitialSetupScreen> createState() => _InitialSetupScreenState();
}

class _InitialSetupScreenState extends ConsumerState<InitialSetupScreen> {
  UserMode selected = UserMode.visitor;
  final age = TextEditingController();
  String transport = '도보';
  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('필수 정보 입력')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(padding: const EdgeInsets.all(24), children: [
                const Text('예시 데이터 · 구룡포 서비스 지역',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                SegmentedButton<UserMode>(
                    segments: const [
                      ButtonSegment(
                          value: UserMode.resident, label: Text('주민')),
                      ButtonSegment(value: UserMode.visitor, label: Text('관광객'))
                    ],
                    selected: {
                      selected
                    },
                    onSelectionChanged: (v) =>
                        setState(() => selected = v.first)),
                const SizedBox(height: 16),
                const ListTile(
                    leading: Icon(Icons.location_on),
                    title: Text('주거·출발 위치'),
                    subtitle: Text('구룡포 예시 위치 35.9907, 129.5526')),
                CheckboxListTile(
                    value: true,
                    onChanged: (_) {},
                    title: const Text('현재 위치를 주거 위치로 저장 (예시)')),
                TextField(
                    controller: age,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: '연령 (필수)', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                DropdownButtonFormField(
                    value: transport,
                    items: const [
                      DropdownMenuItem(value: '도보', child: Text('도보')),
                      DropdownMenuItem(value: '휠체어', child: Text('휠체어'))
                    ],
                    onChanged: (v) => setState(() => transport = v!),
                    decoration: const InputDecoration(
                        labelText: '이동수단', border: OutlineInputBorder())),
                const SizedBox(height: 20),
                FilledButton(
                    onPressed: age.text.isEmpty ? null : () => complete(),
                    child: const Text('저장 후 대시보드 보기'))
              ]))));
  Future<void> complete() async {
    ref.read(mode.notifier).state = selected;
    await AccountService().saveMode(selected.name);
    await AccountService()
        .saveRequiredSetup(age: age.text, transport: transport);
    if (mounted) context.go('/');
  }

  @override
  void dispose() {
    age.dispose();
    super.dispose();
  }
}

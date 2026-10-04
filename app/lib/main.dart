import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'models/domain_models.dart';
import 'repositories/mock_repository.dart';
import 'repositories/remote_repository.dart';
import 'services/app_config.dart';
import 'services/auth_service.dart';
import 'services/account_service.dart';
import 'services/location_service.dart';
import 'services/geocoding_service.dart';
import 'dashboard_parts.dart';
import 'disaster_center.dart';
import 'login_screen.dart';

/// APP_MODE=remote면 실제 서버, 아니면 예시 데이터
final repo = Provider<SafetyRepository>((_) =>
    AppConfig.isRemote ? RemoteSafetyRepository() : MockSafetyRepository());
final offline = StateProvider<bool>((_) => false);
final routeFacilityId = StateProvider<String?>((_) => null);

/// `safe` avoids the illustrated hazard; `near` illustrates the shorter route.
final routeKind = StateProvider<RouteType>((_) => RouteType.safest);
final chatMessages = StateProvider<List<ChatMessage>>((_) => []);
final userOccupation = StateProvider<String>((_) => '');
final autoVoiceAlerts = StateProvider<bool>((_) => false);
final voiceLanguage = StateProvider<String>((_) => '한국어');
final floodLayer = StateProvider<bool>((_) => false);
final floodTime = StateProvider<int>((_) => 0);

// --- 사용자 위치 ---------------------------------------------------------------
/// 사용자가 있는 곳. fromGps=false면 사용자 유형별 예시 좌표 (GPS가 없거나, 권한이 없거나, 구룡포 밖)
class UserLocation {
  const UserLocation(this.position,
      {required this.fromGps, this.manual = false});
  final LatLng position;
  final bool fromGps, manual;
}

final locationService = Provider<LocationService>((_) => LocationService());

/// 마지막으로 받은 위치 (GPS 또는 지도에서 직접 고른 곳). 구룡포 밖이어도 그대로 둔다 — 쓸지는 userLocation이 정한다
final gpsPosition =
    StateProvider<(LatLng, bool)?>((_) => null); // (위치, 지도에서 직접 고름)
final gpsNote = StateProvider<String?>((_) => null);
final userLocation = Provider<UserLocation>((ref) {
  final g = ref.watch(gpsPosition);
  if (g != null && inServiceArea(g.$1))
    return UserLocation(g.$1, fromGps: true, manual: g.$2);
  return UserLocation(originFor(UserMode.user), fromGps: false);
});

/// 30m 넘게 움직였을 때만 위치를 바꾼다 (첫 위치·지도 선택은 바로)
void setPosition(WidgetRef ref, LatLng p, {bool manual = false}) {
  final prev = ref.read(gpsPosition);
  if (manual ||
      prev == null ||
      prev.$2 ||
      const Distance().as(LengthUnit.Meter, prev.$1, p) > moveThresholdM) {
    ref.read(gpsPosition.notifier).state = (p, manual);
  }
}

/// 앱이 켜져 있는 동안 GPS를 따라간다 (Shell이 watch). 권한 거부·실패면 예시 위치 그대로
final gpsTracker = Provider<void>((ref) {
  StreamSubscription<LatLng>? sub;
  try {
    sub = ref.watch(locationService).watch().listen((p) {
      final prev = ref.read(gpsPosition);
      if (prev != null && prev.$2) return; // 지도에서 직접 고른 위치가 우선
      if (prev == null ||
          const Distance().as(LengthUnit.Meter, prev.$1, p) > moveThresholdM) {
        ref.read(gpsPosition.notifier).state = (p, false);
      }
      ref.read(gpsNote.notifier).state =
          inServiceArea(p) ? null : '현재 위치가 구룡포 밖이라 예시 위치를 씁니다.';
    },
        onError: (Object e) => ref.read(gpsNote.notifier).state =
            e is LocationUnavailable ? e.message : '위치를 읽지 못해 예시 위치를 씁니다.');
  } catch (_) {}
  ref.onDispose(() => sub?.cancel());
});

// 서버 데이터. 사용자 위치가 바뀌면(30m 넘게) 다시 불러온다. 새로고침은 ref.invalidate.
final riskProvider = FutureProvider<RiskStatus>(
    (ref) => ref.watch(repo).risk(ref.watch(userLocation).position));
final riskAreasProvider =
    FutureProvider<List<RiskArea>>((ref) => ref.watch(repo).riskAreas());
final floodGridProvider = FutureProvider<List<FloodGrid>>(
    (ref) => ref.watch(repo).floodGrid(timeIndex: ref.watch(floodTime)));
final facilitiesProvider = FutureProvider<List<Facility>>(
    (ref) => ref.watch(repo).getFacilities(ref.watch(userLocation).position));
final alertsProvider = FutureProvider<List<AlertItem>>(
    (ref) => ref.watch(repo).alerts(ref.watch(userLocation).position));

/// AI 답의 "지도에서 경로 보기"로 고른 경로 (routeFacilityId == aiRouteId일 때 지도에 그린다)
const aiRouteId = 'ai';
final aiRoute = StateProvider<ChatAnswer?>((_) => null);
final placesProvider =
    FutureProvider<List<SavedPlace>>((_) => AccountService().places());
final routeProvider =
    FutureProvider.family<SafetyRoute, String>((ref, facilityId) async {
  if (facilityId == aiRouteId) {
    final route = ref.watch(aiRoute)?.route;
    if (route == null) throw StateError('AI 경로가 없습니다.');
    return route;
  }
  final facility = (await ref.watch(facilitiesProvider.future))
      .firstWhere((f) => f.id == facilityId);
  return ref.watch(repo).routeFor(facility, UserMode.user, ref.watch(routeKind),
      ref.watch(userLocation).position);
});

/// AI가 안내한 경로를 대시보드 지도에 띄운다 (서버를 다시 부르지 않고 AI가 계산한 경로 그대로)
void showAiRoute(WidgetRef ref, ChatAnswer answer) {
  ref.read(aiRoute.notifier).state = answer;
  ref.invalidate(routeProvider(aiRouteId));
  startRouteToShelter(
    ref,
    aiRouteId,
    routeType: answer.route?.routeType ?? RouteType.safest,
  );
}

/// 지금 지도에 그리는 목적지 (대피소·의료시설 목록 또는 AI 경로의 목적지)
Facility? routeDestination(WidgetRef ref, String id) {
  if (id == aiRouteId) {
    final a = ref.watch(aiRoute);
    if (a == null || a.destinationPos == null) return null;
    final kind = a.destinationKind;
    return Facility(
        id: aiRouteId,
        name: a.destinationName ?? '목적지',
        type: kind == 'shelter'
            ? FacilityType.shelter
            : kind == 'medical'
                ? FacilityType.medical
                : FacilityType.place,
        position: a.destinationPos!,
        address: '',
        description: 'AI 안내 목적지',
        distanceKm: 0,
        walkMinutes: 0,
        accessible: false);
  }
  return ref
      .watch(facilitiesProvider)
      .valueOrNull
      ?.where((f) => f.id == id)
      .firstOrNull;
}

/// 가장 가까운 '갈 만한' 대피소 (shelterExclusion 규칙). 모두 위험하면 가장 가까운 곳, 못 불러왔으면 예시 대피소
String nearestShelterId(WidgetRef ref) {
  final areas = ref.read(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
  final shelters = [...?ref.read(facilitiesProvider).valueOrNull]
      .where((f) => f.type == FacilityType.shelter)
      .toList()
    ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  if (shelters.isEmpty) return 'gym';
  return (shelters
              .where((f) => shelterExclusion(f, areas) == null)
              .firstOrNull ??
          shelters.first)
      .id;
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
  GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
  GoRoute(path: '/location', builder: (_, __) => const InitialSetupScreen()),
  ShellRoute(builder: (_, __, child) => Shell(child: child), routes: [
    GoRoute(path: '/', builder: (_, __) => const Dashboard()),
    GoRoute(path: '/map', builder: (_, __) => const FacilitiesScreen()),
    GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
    GoRoute(path: '/ai', builder: (_, __) => const AiScreen()),
    GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
    GoRoute(
        path: '/typhoon',
        builder: (_, s) => TyphoonScreen(initialLocal: s.extra == 'local')),
    GoRoute(path: '/support', builder: (_, __) => const RecoveryScreen()),
    GoRoute(path: '/alerts-hub', builder: (_, __) => const AlertHubScreen()),
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
    await AccountService().clearLegacyMode();
    if (!mounted) return;
    setState(
        () => text = a.isMock ? 'Firebase 미설정: 목업 모드로 시작합니다.' : '로그인 확인 완료');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // Show live emergency information before asking the user to complete profile setup.
    if (mounted) context.go('/');
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
      ('태풍 정보', Icons.cyclone, '/typhoon'),
      ('선제 경고·알림', Icons.notifications_active_outlined, '/alerts-hub'),
      ('지원 및 복구', Icons.health_and_safety_outlined, '/support'),
      ('프로필', Icons.person_outline, '/profile')
    ];
    final wide = MediaQuery.sizeOf(c).width >= 840;
    final destinations =
        wide ? [...nav, ('AI 채팅', Icons.chat_bubble_outline, '/ai')] : nav;
    final here = GoRouterState.of(c).uri.path;
    final selected = destinations
        .indexWhere((x) => x.$3 == here)
        .clamp(0, destinations.length - 1) as int;
    ref.watch(gpsTracker);
    final body = Column(children: [const StatusLine(), Expanded(child: child)]);
    return Scaffold(
        appBar: wide
            ? null
            : AppBar(
                title: const Text('구룡포 안전'),
                actions: [
                  IconButton(
                      tooltip: 'AI 채팅',
                      onPressed: () => c.go('/ai'),
                      icon: const Icon(Icons.chat_bubble_outline))
                ],
              ),
        body: wide
            ? Row(children: [
                NavigationRail(
                    selectedIndex: selected,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (i) => c.go(destinations[i].$3),
                    destinations: destinations
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
    final here = ref.watch(userLocation);
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
                      : '온라인 · ${AppConfig.dataLabel}${AppConfig.isRemote ? '' : ' · 10:42'} · ${here.fromGps ? (here.manual ? '지도에서 고른 위치' : 'GPS 위치') : '예시 위치'} 기준${!here.fromGps && ref.watch(gpsNote) != null ? ' (${ref.watch(gpsNote)})' : ''}')),
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
  Widget build(BuildContext c, WidgetRef ref) {
    final route = ref.watch(routeFacilityId);
    if (route == null) return const DisasterDashboard();
    final routeType = ref.watch(routeKind);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
            child: Text(routeType == RouteType.nearest ? '가까운 경로' : '안전 경로',
                style: Theme.of(c).textTheme.headlineSmall)),
        TextButton.icon(
            onPressed: () => ref.read(routeFacilityId.notifier).state = null,
            icon: const Icon(Icons.dashboard_outlined),
            label: const Text('재난 종합')),
      ]),
      RouteMap(
          key: ValueKey('route-$route-${routeType.name}'), facilityId: route),
    ]);
  }
  /*Widget build(BuildContext c, WidgetRef ref) => ref.watch(riskProvider).when(
      loading: () => const DashboardLoading(),
      error: (e, _) => LoadError(message: '$e', onRetry: () => ref.invalidate(riskProvider)),
      data: (risk) {
        final route = ref.watch(routeFacilityId);
        final selectedRouteType = ref.watch(routeKind);
        final main = route == null
            ? const ServiceMap()
            : RouteMap(
                key: ValueKey(
                    'route-$route-${selectedRouteType.name}-${ref.watch(mode).name}'),
                facilityId: route);
        final side = AiPanel(risk: risk);
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
                                  '알림 | 사용자 맞춤 안내'),
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
                                          '알림 | 사용자 맞춤 안내',
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
                      FloodWarningBanner(risk: risk),
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
                      ModeCards(risk: risk)
                    ])));
      });*/
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
  const FloodWarningBanner({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context) => AppConfig.isRemote
      ? _live()
      : Card(
          color: risk.color,
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text('${risk.level} · 호우·침수 위험 · 예시 데이터',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold))),
                      VoiceButton(
                          text: '현재 위치와 등록 장소 주변의 침수 가능성을 확인하고 안전한 실내로 이동하세요.')
                    ]),
                    const SizedBox(height: 8),
                    const Text('선제 경고: 현재 위치와 등록 장소 주변의 저지대 침수 가능성을 확인하세요.',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text(
                        '예시 데이터 기준, 저지대·침수 구간·맨홀 주변 접근을 피하고 안전한 장소를 확인하세요.',
                        style: TextStyle(color: Colors.white)),
                  ])));

  /// 실제 위험도 판정 (/api/v1/risk)
  Widget _live() => Card(
      color: risk.color,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  risk.level == '정상' || risk.level == '관심'
                      ? Icons.verified_user_outlined
                      : Icons.warning_amber_rounded,
                  color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      '${risk.level} · ${risk.title} · ${risk.updatedAt} 판정',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              VoiceButton(text: '${risk.title}. ${risk.summary}. ${risk.guide}')
            ]),
            const SizedBox(height: 8),
            Text(risk.summary,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
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
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'))
          ])));
}

class RainWaterInfographic extends StatelessWidget {
  const RainWaterInfographic({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context) => AppConfig.isRemote
      ? _live()
      : Card(
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.water_drop, color: Colors.blue),
                    const SizedBox(width: 6),
                    const Text('침수 현황 인포그래픽',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('마지막 갱신 ${risk.updatedAt} · 예시 데이터',
                        style: const TextStyle(fontSize: 12))
                  ]),
                  const SizedBox(height: 12),
                  Row(children: const [
                    Expanded(
                        child: _Metric(
                            label: '현재 강수량',
                            value: '18 mm/h',
                            color: Colors.blue,
                            icon: Icons.umbrella)),
                    SizedBox(width: 8),
                    Expanded(
                        child: _Metric(
                            label: '최근 누적',
                            value: '86 mm',
                            color: Colors.indigo,
                            icon: Icons.bar_chart)),
                    SizedBox(width: 8),
                    Expanded(
                        child: _Metric(
                            label: '현재 수위',
                            value: '2.8 m',
                            color: Colors.deepOrange,
                            icon: Icons.waves)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    const Text('현재 위험 단계  '),
                    Chip(label: Text('${risk.level} · 예시 데이터')),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('현재 수위 위험도'))
                  ]),
                  Row(children: [
                    const SizedBox(width: 96),
                    Expanded(
                        child: LinearProgressIndicator(
                            value: .82,
                            minHeight: 12,
                            color: Colors.red,
                            backgroundColor: Colors.blue.shade100)),
                    const SizedBox(width: 8),
                    const Text('경계')
                  ]),
                ],
              )));

  /// 판정 근거 목록 (관측값·기준). 수치는 서버 판정 문구 그대로
  Widget _live() => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.water_drop, color: Colors.blue),
                const SizedBox(width: 6),
                const Text('현재 위험 판정 근거',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${risk.updatedAt} 판정${risk.stale ? ' · 갱신 지연' : ''}',
                    style: const TextStyle(fontSize: 12))
              ]),
              const SizedBox(height: 10),
              if (risk.details.isEmpty)
                const Text('발효 중인 호우·침수 등 위험 판정이 없습니다.'),
              ...risk.details.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.circle, size: 8, color: risk.color),
                        const SizedBox(width: 8),
                        Expanded(child: Text(d))
                      ]))),
              const SizedBox(height: 8),
              Row(children: [
                const Text('현재 위험 단계  '),
                Chip(label: Text(risk.level)),
                const SizedBox(width: 8),
                Expanded(
                    child: LinearProgressIndicator(
                        value: const {
                              '정상': .05,
                              '관심': .25,
                              '주의': .5,
                              '경계': .75,
                              '심각': 1.0
                            }[risk.level] ??
                            .05,
                        minHeight: 12,
                        color: risk.color,
                        backgroundColor: Colors.blue.shade100))
              ]),
            ],
          )));
}

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.label,
      required this.value,
      required this.color,
      required this.icon});
  final String label, value;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color),
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12))
      ]));
}

class DashboardLoading extends StatelessWidget {
  const DashboardLoading({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(children: [
        LinearProgressIndicator(),
        SizedBox(height: 16),
        _LoadingCard(height: 110),
        SizedBox(height: 12),
        _LoadingCard(height: 300)
      ]));
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.height});
  final double height;
  @override
  Widget build(BuildContext context) => Card(
      child: SizedBox(
          height: height,
          child: Center(child: Text('${AppConfig.dataLabel} 준비 중…'))));
}

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
                      Text('사용자 맞춤 안내',
                          style: Theme.of(c).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      const Text('현재 위치와 등록 장소를 바탕으로 안전 정보와 대피소를 안내합니다.'),
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
  const MapCard({super.key, required this.height});
  final double height;
  @override
  ConsumerState<MapCard> createState() => _MapCardState();
}

class _MapCardState extends ConsumerState<MapCard> {
  String? locationNote;
  FloodGrid? selected;
  final mapController = MapController();
  late final MapOptions mapOptions;
  @override
  void initState() {
    super.initState();
    // Keep options stable while overlays and provider state rebuild. flutter_map
    // revalidates the active camera whenever MapOptions is replaced; doing that
    // on every parent rebuild can trip its cameraConstraint assertion.
    mapOptions = MapOptions(
      initialCenter: const LatLng(35.9922, 129.5531),
      initialZoom: 14.5,
      minZoom: 10,
      cameraConstraint: CameraConstraint.containCenter(
        bounds: LatLngBounds(
          const LatLng(35.925, 129.495),
          const LatLng(36.055, 129.605),
        ),
      ),
      onTap: (_, point) {
        if (locationNote != null) {
          setPosition(ref, point, manual: true);
          setState(() => locationNote = '지도에서 선택한 현재 위치입니다.');
        }
        if (ref.read(floodLayer)) setState(() => selected = gridAt(point));
      },
    );
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }

  /// GPS 버튼: 지금 위치를 한 번 읽어 앱 전체 위치(userLocation)에 반영. 못 읽으면 지도를 눌러 고를 수 있게 한다
  Future<void> locate() async {
    try {
      final p = await ref.read(locationService).current();
      if (!mounted) return;
      if (inServiceArea(p)) {
        ref.read(gpsPosition.notifier).state = (p, false);
        setState(() => locationNote = 'GPS 현재 위치를 반영했습니다.');
      } else {
        setState(() =>
            locationNote = '현재 위치가 구룡포 밖이라 예시 위치를 씁니다. 지도를 눌러 위치를 고를 수 있습니다.');
      }
    } on LocationUnavailable catch (e) {
      if (mounted)
        setState(() => locationNote = '${e.message} 지도를 눌러 현재 위치를 고를 수 있습니다.');
    } catch (_) {
      if (mounted)
        setState(() => locationNote = '위치를 읽지 못했습니다. 지도를 눌러 현재 위치를 고르세요.');
    }
  }

  FloodGrid? gridAt(LatLng p) {
    for (final g in ref.read(floodGridProvider).valueOrNull ??
        demoFloodGrid(ref.read(floodTime))) {
      if (p.latitude >= g.south &&
          p.latitude <= g.north &&
          p.longitude >= g.west &&
          p.longitude <= g.east) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext c) {
    final active = ref.watch(floodLayer), time = ref.watch(floodTime);
    final gridAsync = ref.watch(floodGridProvider);
    final grids = gridAsync.valueOrNull ??
        (AppConfig.isRemote ? const <FloodGrid>[] : demoFloodGrid(time));
    return Card(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
            height: widget.height,
            child: Stack(children: [
              FlutterMap(
                  mapController: mapController,
                  options: mapOptions,
                  children: [
                    TileLayer(
                        urlTemplate:
                            'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        subdomains: const ['a', 'b', 'c'],
                        userAgentPackageName: 'com.example.guryongpo_safety'),
                    if (active && grids.isNotEmpty)
                      PolygonLayer(polygons: floodGridPolygons(grids)),
                    if (AppConfig.isRemote)
                      PolygonLayer(
                          polygons: riskAreaPolygons(
                              ref.watch(riskAreasProvider).valueOrNull ??
                                  const [])),
                    MarkerLayer(markers: [
                      Marker(
                          point: ref.watch(userLocation).position,
                          width: 46,
                          height: 46,
                          child: const Icon(Icons.my_location,
                              color: Colors.blue, size: 34)),
                      // 등록 장소 (없고 목업 모드면 예시 집·직장)
                      ...[
                        for (final p in ref.watch(placesProvider).valueOrNull ??
                            const <SavedPlace>[])
                          (p.position, p.type)
                      ]
                          .followedBy(
                              (ref.watch(placesProvider).valueOrNull?.isEmpty ??
                                          true) &&
                                      !AppConfig.isRemote
                                  ? const [
                                      (LatLng(35.9935, 129.5498), '집'),
                                      (LatLng(35.9879, 129.5548), '직장')
                                    ]
                                  : const <(LatLng, String)>[])
                          .map((p) => Marker(
                              point: p.$1,
                              width: 46,
                              height: 46,
                              child: Icon(
                                  p.$2 == '집'
                                      ? Icons.home
                                      : p.$2 == '직장'
                                          ? Icons.business
                                          : Icons.place,
                                  color: p.$2 == '집'
                                      ? Colors.indigo
                                      : const Color(0xffe56717),
                                  size: 32))),
                      ...?ref.watch(facilitiesProvider).valueOrNull?.map((f) =>
                          Marker(
                              point: f.position,
                              width: 55,
                              height: 45,
                              child: Icon(
                                  f.type == FacilityType.shelter
                                      ? Icons.home_work_outlined
                                      : Icons.local_hospital,
                                  color: f.type == FacilityType.shelter
                                      ? Colors.teal
                                      : Colors.red))),
                      if (active)
                        for (final g in grids.where((g) => g.hasRisk))
                          Marker(
                              point: g.center,
                              width: 18,
                              height: 18,
                              child: GestureDetector(
                                  onTap: () => setState(() => selected = g),
                                  child: DecoratedBox(
                                      decoration: BoxDecoration(
                                          color: riskColor(g.level),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white,
                                              width: 1))))),
                    ])
                  ]),
              Positioned(
                  left: 10,
                  top: 10,
                  child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor:
                              active ? const Color(0xff16803c) : Colors.white,
                          foregroundColor:
                              active ? Colors.white : Colors.black87),
                      onPressed: () {
                        final next = !active;
                        ref.read(floodLayer.notifier).state = next;
                        mapController.move(
                            const LatLng(35.99, 129.55), next ? 11.5 : 14.5);
                      },
                      icon: const Icon(Icons.grid_on),
                      label: const Text('침수 위험도 확인'))),
              Positioned(
                  left: 12,
                  top: 58,
                  child: IconButton.filledTonal(
                      tooltip: 'GPS 현재 위치 확인',
                      onPressed: locate,
                      icon: const Icon(Icons.gps_fixed))),
              if (active) const FloodGridLegend(),
              if (active)
                Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Material(
                        color: Colors.white.withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 5),
                            child: Row(children: [
                              IconButton(
                                  tooltip: '시간 흐름 재생',
                                  onPressed: () => ref
                                      .read(floodTime.notifier)
                                      .state = (time + 1) % 5,
                                  icon: const Icon(Icons.play_circle_outline)),
                              Expanded(
                                  child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                          children: [
                                        '현재',
                                        '1시간 후',
                                        '3시간 후',
                                        '6시간 후',
                                        '오늘 밤'
                                      ]
                                              .asMap()
                                              .entries
                                              .map((e) => Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          right: 4),
                                                  child: ChoiceChip(
                                                      label: Text(e.value),
                                                      selected: time == e.key,
                                                      onSelected: (_) => ref
                                                          .read(floodTime
                                                              .notifier)
                                                          .state = e.key)))
                                              .toList())))
                            ])))),
              if (selected != null && active)
                Positioned(
                  left: 12,
                  bottom: 55,
                  child: Material(
                    elevation: 5,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 230,
                      padding: const EdgeInsets.all(10),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(selected!.id,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold))),
                              IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      setState(() => selected = null),
                                  icon: const Icon(Icons.close, size: 18)),
                            ]),
                            Text(
                                selected!.hasRisk
                                    ? '침수 위험 · ${selected!.level}'
                                    : '확인된 침수 위험 없음 · 침수 자료 미확인',
                                style: TextStyle(
                                    color: selected!.hasRisk
                                        ? riskColor(selected!.level)
                                        : Colors.blueGrey,
                                    fontWeight: FontWeight.bold)),
                            if (selected!.depthCm != null)
                              Text(
                                  '${selected!.isExample ? '예시 ' : ''}수심 ${selected!.depthCm!.toStringAsFixed(0)}cm'),
                            Text(
                                '시각: ${selected!.observedAt ?? '확인 불가'} · 출처: ${selected!.source.isEmpty ? '자료 없음' : selected!.source}',
                                style: const TextStyle(fontSize: 11)),
                            if (selected!.isExample)
                              const Text('예시 데이터 · 실제 침수 관측이 아닙니다.',
                                  style: TextStyle(fontSize: 10)),
                            if (selected!.hasRisk)
                              const Text(
                                  '권고: 저지대·침수 구간에 진입하지 말고 안전한 경로를 이용하세요.',
                                  style: TextStyle(fontSize: 11)),
                          ]),
                    ),
                  ),
                ),
              if (locationNote != null)
                Positioned(
                    left: 12,
                    right: 12,
                    top: 105,
                    child: Material(
                        color: Colors.white.withValues(alpha: .93),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(locationNote!,
                                style: const TextStyle(fontSize: 12)))))
            ])));
  }
}

void showPlaceInfo(BuildContext context, WidgetRef ref, String type,
        String name, String detail) =>
    showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text('유형: $type · $detail'),
                  const SizedBox(height: 4),
                  Text(AppConfig.isRemote
                      ? '거리는 직선거리 기준 대략값입니다.'
                      : '모든 시설·거리·운영 상태는 예시 데이터입니다.'),
                  if (type == '대피소') ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          final f = ref
                              .read(facilitiesProvider)
                              .requireValue
                              .firstWhere((f) => f.name == name);
                          startRouteToShelter(ref, f.id);
                          context.go('/');
                        },
                        icon: const Icon(Icons.directions_walk),
                        label: const Text('경로 안내'))
                  ]
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
    final areas =
        ref.watch(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
    int unsafe(Facility f) => shelterExclusion(f, areas) == null ? 0 : 1;
    // 안전 추천: 갈 만한 곳 먼저, 그다음 도보 시간 순 / 가까운 순: 거리만
    final fs = [...?ref.watch(facilitiesProvider).valueOrNull]
      ..sort((a, b) => nearest
          ? a.distanceKm.compareTo(b.distanceKm)
          : unsafe(a) != unsafe(b)
              ? unsafe(a) - unsafe(b)
              : a.walkMinutes.compareTo(b.walkMinutes));
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: Text(AppConfig.isRemote ? '주변 대피·의료 시설' : '예시 시설',
                    style: Theme.of(c).textTheme.titleLarge)),
            FilterChip(
                label: Text(nearest ? '가까운 순' : '안전 추천'),
                selected: true,
                onSelected: (_) => setState(() => nearest = !nearest))
          ])),
      if (ref.watch(facilitiesProvider).hasError)
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text('${ref.watch(facilitiesProvider).error}')),
      if (ref.watch(facilitiesProvider).isLoading)
        const LinearProgressIndicator(),
      Expanded(
          child: ListView(
              children: fs.map((f) {
        final warn = shelterExclusion(f, areas);
        return Card(
            child: Column(children: [
          ListTile(
              leading: Icon(
                  warn != null
                      ? Icons.warning_amber_rounded
                      : f.type == FacilityType.shelter
                          ? Icons.home_work_outlined
                          : Icons.local_hospital,
                  color: warn != null ? Colors.orange.shade800 : null),
              title: Text(f.name),
              subtitle: Text(
                  '${AppConfig.isRemote ? '약 ' : ''}${f.distanceKm}km · 도보 ${f.walkMinutes}분 · ${warn ?? f.description}'),
              onTap: () {
                startRouteToShelter(ref, f.id);
                c.go('/');
              }),
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(children: [
                Expanded(
                    child: OutlinedButton.icon(
                  onPressed: () {
                    startRouteToShelter(ref, f.id,
                        routeType: RouteType.nearest);
                    c.go('/');
                  },
                  icon: const Icon(Icons.bolt),
                  label: const Text('가까운 경로'),
                )),
                const SizedBox(width: 8),
                Expanded(
                    child: FilledButton.tonalIcon(
                  onPressed: () {
                    startRouteToShelter(ref, f.id, routeType: RouteType.safest);
                    c.go('/');
                  },
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('안전 경로'),
                )),
              ])),
        ]));
      }).toList()))
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
      return Scaffold(
          appBar: AppBar(title: const Text('시설 상세')),
          body: fs == null
              ? const Center(child: CircularProgressIndicator())
              : const Center(child: Text('시설 정보를 찾지 못했습니다.')));
    }
    final label = AppConfig.isRemote ? '' : '예시 ';
    return Scaffold(
        appBar: AppBar(title: const Text('시설 상세')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(f.name, style: Theme.of(c).textTheme.headlineSmall),
          Chip(
              label: Text(f.type == FacilityType.shelter
                  ? '$label대피소'
                  : f.type == FacilityType.medical
                      ? '$label의료시설'
                      : '목적지')),
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
                title: const Text('연락처'),
                subtitle: Text(f.phone ??
                    (AppConfig.isRemote ? '정보 없음' : '054-000-0000 (예시)')))
          ])),
          Row(children: [
            Expanded(
                child: OutlinedButton.icon(
              onPressed: () {
                startRouteToShelter(ref, f.id, routeType: RouteType.nearest);
                c.go('/');
              },
              icon: const Icon(Icons.bolt),
              label: const Text('가까운 경로'),
            )),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton.icon(
              onPressed: () {
                startRouteToShelter(ref, f.id, routeType: RouteType.safest);
                c.go('/');
              },
              icon: const Icon(Icons.shield_outlined),
              label: const Text('안전 경로'),
            )),
          ])
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
      if (s.hasError)
        LoadError(
            message: '${s.error}',
            onRetry: () => ref.invalidate(alertsProvider)),
      if (s.valueOrNull?.isEmpty ?? false)
        const Card(
            child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('현재 알림이 없습니다'))),
      ...?(s.valueOrNull?.map((a) => Card(
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
      return Scaffold(
          appBar: AppBar(title: const Text('알림 상세')),
          body: Center(
              child: s.isLoading
                  ? const CircularProgressIndicator()
                  : const Text('이미 해제된 알림입니다.')));
    return Scaffold(
        appBar: AppBar(title: const Text('알림 상세')),
        body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Chip(
                      label: Text(
                          '${a.level} · ${AppConfig.isRemote ? a.time : '예시 알림'}')),
                  Text(a.title, style: Theme.of(c).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(a.summary),
                  const SizedBox(height: 20),
                  const Text('행동 요령',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(a.guide),
                  VoiceButton(text: '${a.title}. ${a.summary}. ${a.guide}'),
                  if (id == 'work-flood') const SupportCard(),
                  const Spacer(),
                  FilledButton(
                      onPressed: () {
                        startRouteToShelter(ref, nearestShelterId(ref));
                        c.go('/');
                      },
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
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(chatMessages).isNotEmpty) return;
      ref.read(chatMessages.notifier).state = [
        ChatMessage(
          AppConfig.isRemote
              ? '구룡가디언 AI입니다. 현재 위험과 대피소, 가고 싶은 곳까지의 길을 물어보세요.'
              : '예시 AI 안내입니다. 현재 위험과 대피소에 대해 물어보세요.',
          false,
        )
      ];
    });
  }

  Future<void> send([String? q]) async {
    final question = q ?? input.text;
    if (question.trim().isEmpty || loading) return;
    ref.read(chatMessages.notifier).state = [
      ...ref.read(chatMessages),
      ChatMessage(question, true),
    ];
    setState(() {
      loading = true;
      input.clear();
    });
    try {
      final answer = await ref
          .read(repo)
          .ask(question, UserMode.user, ref.read(userLocation).position);
      if (mounted) {
        ref.read(chatMessages.notifier).state = [
          ...ref.read(chatMessages),
          ChatMessage(answer.text, false, answer: answer),
        ];
      }
    } catch (_) {
      if (mounted) {
        const answer = ChatAnswer(
          'AI 서비스에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.',
          isError: true,
        );
        ref.read(chatMessages.notifier).state = [
          ...ref.read(chatMessages),
          ChatMessage(answer.text, false, answer: answer),
        ];
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final messages = ref.watch(chatMessages);
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Text(AppConfig.isRemote
              ? '실시간 데이터 기반 AI 답변 · 공식 재난 안내를 함께 확인하세요.'
              : '목업 데이터 기반 답변 · 실제 재난 지시가 아닙니다.')),
      Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(
            spacing: 8,
            children: ['가까운 대피소는 어디야?', '지금 침수 위험이 있어?', '도보로 안전하게 갈 수 있어?']
                .map(
                    (q) => ActionChip(label: Text(q), onPressed: () => send(q)))
                .toList()),
        const SizedBox(height: 14),
        ...List.generate(messages.length, (index) {
          final m = messages[index];
          String? retryQuestion;
          if (m.answer?.isError == true) {
            for (var i = index - 1; i >= 0; i--) {
              if (messages[i].mine) {
                retryQuestion = messages[i].text;
                break;
              }
            }
          }
          return Align(
            alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Card(
                child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.text),
                    if (retryQuestion != null)
                      TextButton.icon(
                          onPressed: loading ? null : () => send(retryQuestion),
                          icon: const Icon(Icons.refresh),
                          label: const Text('다시 시도')),
                    if (m.answer?.route != null)
                      RouteButton(onPressed: () {
                        showAiRoute(ref, m.answer!);
                        context.go('/');
                      }),
                  ]),
            )),
          );
        }),
        if (loading)
          const Padding(
              padding: EdgeInsets.all(12),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('구룡포 정보를 확인하고 있습니다…')
              ])),
      ])),
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: input,
                    onSubmitted: send,
                    decoration: const InputDecoration(
                        border: OutlineInputBorder(), hintText: '메시지 입력…'))),
            IconButton(
                onPressed: loading ? null : send,
                icon: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send))
          ]))
    ]);
  }

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
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('사용자 정보', style: Theme.of(c).textTheme.headlineSmall),
      const ProfileDetailsCard(),
      const SizedBox(height: 12),
      const AccountCard(),
      Card(
          child: Column(children: const [
        ListTile(title: Text('이동수단'), subtitle: Text('도보')),
        ListTile(title: Text('접근성'), subtitle: Text('휠체어 접근 우선 (예시)'))
      ])),
      Card(
          child: Column(children: [
        ListTile(
            title: const Text('음성 안내 설정'),
            subtitle: Text('언어: ${ref.watch(voiceLanguage)} · 접근성 기능')),
        SwitchListTile(
            value: ref.watch(autoVoiceAlerts),
            title: const Text('재난 경고 자동 음성 재생'),
            subtitle: const Text('기본값: 꺼짐 · 사용자가 설정한 경우에만 자동 재생'),
            onChanged: (v) => ref.read(autoVoiceAlerts.notifier).state = v),
        SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '한국어', label: Text('한국어')),
              ButtonSegment(value: 'English', label: Text('English'))
            ],
            selected: {
              ref.watch(voiceLanguage)
            },
            onSelectionChanged: (v) =>
                ref.read(voiceLanguage.notifier).state = v.first),
        const SizedBox(height: 10),
      ])),
      Card(
          child: Column(children: [
        const ListTile(
            title: Text('등록 장소'),
            subtitle:
                Text('지도에 표시하고, AI에게 "집까지", "직장까지"처럼 물을 수 있어요. 이 기기에만 저장됩니다.')),
        for (final p
            in ref.watch(placesProvider).valueOrNull ?? const <SavedPlace>[])
          ListTile(
              leading: Icon(p.type == '집'
                  ? Icons.home
                  : p.type == '직장'
                      ? Icons.business
                      : Icons.place),
              title: Text(p.type == '기타' ? p.name : '${p.type} · ${p.name}'),
              subtitle: Text(
                  '${p.address.isEmpty ? '주소 없음' : p.address} · 알림 ${p.alert ? '켜짐' : '꺼짐'}'),
              trailing: IconButton(
                  tooltip: '삭제',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await AccountService().removePlace(p.id);
                    ref.invalidate(placesProvider);
                  })),
        ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: const Text('장소 등록'),
            subtitle: const Text('장소명 · 유형 · 도로명 주소 · 알림 설정'),
            onTap: () => showModalBottomSheet<void>(
                context: c,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => const _PlaceForm())),
      ])),
      const OptionalDetailsCard()
    ]);
  }
}

/// 주소는 앱에서 좌표화하지 않는다. 카카오 키를 보관한 서버가 좌표를 반환한다.
class _PlaceForm extends ConsumerStatefulWidget {
  const _PlaceForm();
  @override
  ConsumerState<_PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends ConsumerState<_PlaceForm> {
  String type = '집';
  bool alert = true;
  bool resolving = false;
  final name = TextEditingController();
  final address = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (resolving || address.text.trim().isEmpty) return;
    setState(() => resolving = true);
    try {
      final resolved = await GeocodingService().resolve(address.text);
      final label = name.text.trim().isEmpty ? type : name.text.trim();
      await AccountService().addPlace(SavedPlace(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: label,
        type: type,
        address: resolved.address,
        position: resolved.position,
        alert: alert,
      ));
      ref.invalidate(placesProvider);
      if (mounted) Navigator.pop(context);
    } on GeocodingException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext c) => SafeArea(
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, 24 + MediaQuery.viewInsetsOf(c).bottom),
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                const Text('장소 등록',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
                const SizedBox(height: 12),
                TextField(
                    controller: name,
                    decoration: const InputDecoration(
                        labelText: '장소명 (비우면 유형 이름)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 9),
                DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(
                        labelText: '유형', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: '집', child: Text('집')),
                      DropdownMenuItem(value: '직장', child: Text('직장')),
                      DropdownMenuItem(value: '기타', child: Text('기타'))
                    ],
                    onChanged: (v) => setState(() => type = v!)),
                const SizedBox(height: 9),
                TextField(
                    controller: address,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: '도로명 주소',
                        hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152',
                        border: OutlineInputBorder())),
                const SizedBox(height: 6),
                const Text('주소를 저장하면 서버가 카카오 주소 검색으로 좌표를 확인합니다.',
                    style: TextStyle(fontSize: 12)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: alert,
                    title: const Text('알림 수신'),
                    onChanged: (v) => setState(() => alert = v)),
                FilledButton.icon(
                    onPressed:
                        resolving || address.text.trim().isEmpty ? null : save,
                    icon: resolving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add_location_alt_outlined),
                    label: Text(resolving ? '주소 확인 중…' : '주소 확인 후 등록')),
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
  final age = TextEditingController();
  final address = TextEditingController();
  String transport = '도보';
  bool resolving = false;
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
                TextField(
                    controller: address,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: '주거·출발 도로명 주소',
                        hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152',
                        border: OutlineInputBorder())),
                const SizedBox(height: 6),
                const Text('주소를 서버에서 좌표로 변환해 저장합니다.',
                    style: TextStyle(fontSize: 12)),
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
                    onPressed: age.text.isEmpty ||
                            address.text.trim().isEmpty ||
                            resolving
                        ? null
                        : () => complete(),
                    child: Text(resolving ? '주소 확인 중…' : '저장 후 대시보드 보기'))
              ]))));
  Future<void> complete() async {
    setState(() => resolving = true);
    try {
      final resolved = await GeocodingService().resolve(address.text);
      final account = AccountService();
      await account.saveRequiredSetup(age: age.text, transport: transport);
      final optional = await account.optionalProfile();
      optional.addAll({
        'homeName': '집',
        'homeAddress': resolved.address,
        'homeLat': '${resolved.position.latitude}',
        'homeLon': '${resolved.position.longitude}',
        'transport': transport,
      });
      await account.saveOptionalProfile(optional);
      if (mounted) context.go('/');
    } on GeocodingException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  void dispose() {
    age.dispose();
    address.dispose();
    super.dispose();
  }
}

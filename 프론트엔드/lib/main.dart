import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'models/domain_models.dart';
import 'repositories/mock_repository.dart';
import 'services/auth_service.dart';
import 'services/account_service.dart';
import 'dashboard_parts.dart';

final repo = Provider<SafetyRepository>((_) => MockSafetyRepository());
/// The prototype opens as the fishing-resident scenario. Visitors can switch
/// modes in the profile, where the same flood layer is centred on their origin.
final mode = StateProvider<UserMode>((_) => UserMode.resident);
final offline = StateProvider<bool>((_) => false);
final routeFacilityId = StateProvider<String?>((_) => null);

/// `safe` avoids the illustrated hazard; `near` illustrates the shorter route.
final routeKind = StateProvider<RouteType>((_) => RouteType.safest);
final chatMessages = StateProvider<List<(String, bool)>>((_) => []);
final residentOccupation = StateProvider<String>((_) => '어업·수산업');
final autoVoiceAlerts = StateProvider<bool>((_) => false);
final voiceLanguage = StateProvider<String>((_) => '한국어');
final floodLayer = StateProvider<bool>((_) => false);
final floodTime = StateProvider<int>((_) => 0);

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
                      : '온라인 · 예시 데이터 · 10:42')),
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
  Widget build(BuildContext c, WidgetRef ref) => FutureBuilder<RiskStatus>(
      future: ref.read(repo).risk(),
      builder: (_, s) {
        final risk = s.data;
        if (risk == null) return const DashboardLoading();
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
                                        ref.read(routeFacilityId) ?? 'gym');
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
                                          ref.read(routeFacilityId) ?? 'gym');
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
  Widget build(BuildContext context) => Card(
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
}

class RainWaterInfographic extends StatelessWidget {
  const RainWaterInfographic({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context) => Card(
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
class _LoadingCard extends StatelessWidget { const _LoadingCard({required this.height}); final double height; @override Widget build(BuildContext context) => Card(child: SizedBox(height: height, child: Center(child: Text('예시 데이터 준비 중…')))); }

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
                            startRouteToShelter(ref, 'gym');
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
        cameraConstraint: CameraConstraint.contain(bounds: LatLngBounds(const LatLng(35.984,129.543), const LatLng(36.001,129.562))),
        onTap: (_, point) { if (locationNote != null) setState(() { current = point; locationNote = '지도에서 선택한 현재 위치입니다.'; }); if (active) setState(() => selected = gridAt(point)); }), children: [
        TileLayer(urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', subdomains: const ['a','b','c'], userAgentPackageName: 'com.example.guryongpo_safety'),
        if (active) PolygonLayer(polygons: floodGridPolygons(time)),
        MarkerLayer(markers: [
          Marker(point: current, width: 46, height: 46, child: const Icon(Icons.my_location, color: Colors.blue, size: 34)),
          Marker(point: const LatLng(35.9935,129.5498), width: 46, height: 46, child: const Icon(Icons.home, color: Colors.indigo, size: 32)),
          Marker(point: const LatLng(35.9879,129.5548), width: 46, height: 46, child: const Icon(Icons.business, color: Color(0xffe56717), size: 32)),
          ...MockSafetyRepository.facilities.map((f) => Marker(point: f.position, width: 55, height: 45, child: Icon(f.type == FacilityType.shelter ? Icons.home_work_outlined : Icons.local_hospital, color: f.type == FacilityType.shelter ? Colors.teal : Colors.red)))
        ])
      ]),
      Positioned(left: 10, top: 10, child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: active ? const Color(0xff16803c) : Colors.white, foregroundColor: active ? Colors.white : Colors.black87), onPressed: () => ref.read(floodLayer.notifier).state = !active, icon: const Icon(Icons.grid_on), label: const Text('침수 위험도 확인'))),
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
        const SizedBox(height: 8), Text('유형: $type · $detail'), const SizedBox(height: 4), const Text('모든 시설·거리·운영 상태는 예시 데이터입니다.'),
        if (type == '대피소') ...[const SizedBox(height: 12), FilledButton.icon(onPressed: () { Navigator.pop(context); final f = MockSafetyRepository.facilities.firstWhere((f) => f.name == name); startRouteToShelter(ref, f.id); context.go('/'); }, icon: const Icon(Icons.directions_walk), label: const Text('경로 안내'))]
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
    final fs = [...MockSafetyRepository.facilities]..sort((a, b) => nearest
        ? a.distanceKm.compareTo(b.distanceKm)
        : a.walkMinutes.compareTo(b.walkMinutes));
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: Text('예시 시설', style: Theme.of(c).textTheme.titleLarge)),
            FilterChip(
                label: Text(nearest ? '가까운 순' : '안전 추천'),
                selected: true,
                onSelected: (_) => setState(() => nearest = !nearest))
          ])),
      Expanded(
          child: ListView(
              children: fs
                  .map((f) => Card(
                      child: ListTile(
                          leading: Icon(f.type == FacilityType.shelter
                              ? Icons.home_work_outlined
                              : Icons.local_hospital),
                          title: Text(f.name),
                          subtitle: Text(
                              '${f.distanceKm}km · 도보 ${f.walkMinutes}분 · 가장 안전한 경로'),
                          onTap: () {
                            startRouteToShelter(ref, f.id);
                            c.go('/');
                          })))
                  .toList()))
    ]);
  }
}

class FacilityScreen extends ConsumerWidget {
  const FacilityScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final f = MockSafetyRepository.facilities.firstWhere((x) => x.id == id);
    return Scaffold(
        appBar: AppBar(title: const Text('시설 상세')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(f.name, style: Theme.of(c).textTheme.headlineSmall),
          Chip(
              label:
                  Text(f.type == FacilityType.shelter ? '예시 대피소' : '예시 의료시설')),
          const MapCard(height: 240),
          Card(
              child: Column(children: [
            ListTile(title: const Text('주소'), subtitle: Text(f.address)),
            ListTile(
                title: const Text('거리 및 도보 시간'),
                subtitle: Text('${f.distanceKm}km · ${f.walkMinutes}분')),
            ListTile(
                title: const Text('접근성'),
                subtitle: Text(f.accessible ? '휠체어 접근 가능 (예시)' : '확인 필요 (예시)')),
            const ListTile(
                title: Text('연락처'), subtitle: Text('054-000-0000 (예시)'))
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
  Widget build(BuildContext c, WidgetRef ref) => FutureBuilder<List<AlertItem>>(
      future: ref.read(repo).alerts(),
      builder: (_, s) => ListView(padding: const EdgeInsets.all(16), children: [
            Text('알림', style: Theme.of(c).textTheme.headlineSmall),
            const Text('모든 항목은 예시 알림이며 실제 재난 경보가 아닙니다.'),
            const SizedBox(height: 10),
            ...?(s.data?.where((a) => a.id != 'work-flood' || ref.watch(mode) == UserMode.resident).map((a) => Card(
                child: ListTile(
                    leading: Icon(a.read
                        ? Icons.notifications_none
                        : Icons.notifications_active_outlined),
                    title: Text('${a.level} · ${a.title}'),
                    subtitle: Text('${a.summary}\n${a.time}'),
                    isThreeLine: true,
                    onTap: () => c.go('/alert/${a.id}')))))
          ]));
}

class AlertScreen extends ConsumerWidget {
  const AlertScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext c, WidgetRef ref) => FutureBuilder<List<AlertItem>>(
      future: MockSafetyRepository().alerts(),
      builder: (_, s) {
        final a = s.data?.firstWhere((x) => x.id == id);
        if (a == null)
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        return Scaffold(
            appBar: AppBar(title: const Text('알림 상세')),
            body: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Chip(label: Text('${a.level} · 예시 알림')),
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
                          onPressed: () { startRouteToShelter(ref, 'gym'); c.go('/'); },
                          child: const Text('침수 위험 그리드·안전 경로 보기')),
                      OutlinedButton(
                          onPressed: () => c.go('/ai'),
                          child: const Text('AI에게 묻기'))
                    ])));
      });
}

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});
  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final input = TextEditingController();
  final messages = <(String, bool)>[
    ('예시 AI 안내입니다. 현재 위험과 대피소에 대해 물어보세요.', false)
  ];
  Future<void> send([String? q]) async {
    final question = q ?? input.text;
    if (question.trim().isEmpty) return;
    setState(() {
      messages.add((question, true));
      input.clear();
    });
    final answer = await ref.read(repo).ask(question);
    if (mounted) setState(() => messages.add((answer, false)));
  }

  @override
  Widget build(BuildContext c) => Column(children: [
        const Padding(
            padding: EdgeInsets.all(12),
            child: Text('목업 데이터 기반 답변 · 실제 재난 지시가 아닙니다.')),
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
              alignment: m.$2 ? Alignment.centerRight : Alignment.centerLeft,
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12), child: Text(m.$1)))))
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
      if (current == UserMode.resident)
        Card(child: Column(children: [
          const ListTile(title: Text('등록 장소'), subtitle: Text('집 · 직장 · 자주 가는 장소의 위험도를 지도에 표시합니다.')),
          const ListTile(leading: Icon(Icons.home), title: Text('집'), subtitle: Text('구룡포로 18 · 알림 수신 켜짐'), trailing: Icon(Icons.edit_outlined)),
          const ListTile(leading: Icon(Icons.business), title: Text('직장'), subtitle: Text('구룡포 수산 작업장 · 알림 수신 켜짐'), trailing: Icon(Icons.edit_outlined)),
          ListTile(leading: const Icon(Icons.add_location_alt_outlined), title: const Text('장소 등록'), subtitle: const Text('장소명 · 주소 또는 좌표 · 유형 · 알림 설정'), onTap: () => showModalBottomSheet<void>(context: c, showDragHandle: true, builder: (_) => const _PlaceForm())),
          ListTile(title: const Text('직업'), subtitle: Text(ref.watch(residentOccupation)), trailing: DropdownButton<String>(value: ref.watch(residentOccupation), items: const [DropdownMenuItem(value: '어업·수산업', child: Text('어업·수산업')), DropdownMenuItem(value: '기타 직업', child: Text('기타 직업'))], onChanged: (v) => ref.read(residentOccupation.notifier).state = v!)),
        ])),
      const OptionalDetailsCard()
    ]);
  }
}

class _PlaceForm extends StatefulWidget { const _PlaceForm(); @override State<_PlaceForm> createState()=>_PlaceFormState(); }
class _PlaceFormState extends State<_PlaceForm> { String type='기타'; bool alert=true; @override Widget build(BuildContext c)=>SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(20,0,20,24),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[const Text('장소 등록',style:TextStyle(fontWeight:FontWeight.bold,fontSize:19)),const SizedBox(height:12),const TextField(decoration:InputDecoration(labelText:'장소명',border:OutlineInputBorder())),const SizedBox(height:9),const TextField(decoration:InputDecoration(labelText:'주소 또는 지도 좌표',border:OutlineInputBorder())),const SizedBox(height:9),DropdownButtonFormField<String>(value:type,decoration:const InputDecoration(labelText:'유형',border:OutlineInputBorder()),items:const [DropdownMenuItem(value:'집',child:Text('집')),DropdownMenuItem(value:'직장',child:Text('직장')),DropdownMenuItem(value:'기타',child:Text('기타'))],onChanged:(v)=>setState(()=>type=v!)),SwitchListTile(contentPadding:EdgeInsets.zero,value:alert,title:const Text('알림 수신'),onChanged:(v)=>setState(()=>alert=v)),FilledButton(onPressed:()=>Navigator.pop(c),child:const Text('등록하기'))]))); }

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

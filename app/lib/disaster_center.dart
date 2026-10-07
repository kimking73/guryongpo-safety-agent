import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';

import 'services/account_service.dart';
import 'services/location_service.dart';
import 'services/app_config.dart';
import 'services/demo_mode.dart';
import 'services/geocoding_service.dart';
import 'models/domain_models.dart';
import 'prototype_safety_screens.dart';

const demoTime = '시연 기준 시각 · 가상 시나리오 당일 14:00';
const guryongpo = LatLng(35.9910, 129.5530);

enum HazardKind { flood, wind, slide, overlap, storm }

class DemoHazard {
  const DemoHazard(
    this.id,
    this.name,
    this.kind,
    this.point,
    this.summary,
    this.guide,
    this.time, {
    this.depth = 0,
    this.fromDirection = '',
  });
  final String id, name, summary, guide, time, fromDirection;
  final HazardKind kind;
  final LatLng point;
  final double depth;
}

const demoHazards = <DemoHazard>[
  DemoHazard(
    'W-01',
    '구룡포 해안 시연구역 A',
    HazardKind.wind,
    LatLng(35.9892, 129.5620),
    '평균 21m/s · 순간최대 30m/s · 북동풍',
    '해안·방파제 접근을 자제하세요.',
    '14:00',
    fromDirection: '북동풍',
  ),
  DemoHazard(
    'L-01',
    '구룡포 산지 시연구역 B',
    HazardKind.slide,
    LatLng(36.0055, 129.5420),
    '13:20 산사태 위험도 안내 목업 · 실제 발생 정보 아님',
    '위험 안내 목업입니다. 실제 통제 정보는 공식 안내를 확인하세요.',
    '13:20',
  ),
  DemoHazard(
    'F-01',
    '구룡포 저지대 시연구역 C',
    HazardKind.flood,
    LatLng(35.9820, 129.5520),
    '13:40 침수 확인 · 깊이 0.2~0.6m',
    '침수 도로와 지하공간에 진입하지 마세요.',
    '13:40',
    depth: .4,
  ),
  DemoHazard(
    'M-01',
    '구룡포 해안 저지대 시연구역 D',
    HazardKind.overlap,
    LatLng(35.9805, 129.5620),
    '침수와 강풍 동시 관측',
    '해안과 침수 구간에 접근하지 마세요.',
    '14:00',
  ),
];

Color _floodColor(String level) => switch (level) {
      '주의' => const Color(0xffe7ac16),
      '경계' => const Color(0xffe56717),
      '심각' => const Color(0xffd93232),
      _ => Colors.transparent,
    };

List<Polygon> _disasterFloodPolygons(List<FloodGrid> grids,
        {required bool severeOnly}) =>
    [
      for (final g in grids)
        if (g.hasRisk && (!severeOnly || g.level == '심각') || !severeOnly)
          for (final ring in g.shapes)
          Polygon(
            points: ring,
            color: g.hasRisk && (!severeOnly || g.level == '심각')
                ? _floodColor(g.level).withValues(alpha: .24)
                : Colors.transparent,
            borderColor: Colors.blueGrey.withValues(alpha: .24),
            borderStrokeWidth: .35,
          ),
    ];

List<Marker> _clusteredFacilities(List<Facility> facilities, double zoom,
    {String? selectedId,
    required List<RiskArea> riskAreas,
    required ValueChanged<Facility> onFacilityTap,
    required ValueChanged<LatLng> onClusterTap}) {
  final cell = zoom >= 14
      ? .0018
      : zoom >= 12
          ? .009
          : .035;
  final buckets = <(int, int), List<Facility>>{};
  for (final f in facilities.where((f) =>
      f.type == FacilityType.shelter || f.type == FacilityType.medical)) {
    if (f.id == selectedId) continue;
    final key = (
      (f.position.latitude / cell).floor(),
      (f.position.longitude / cell).floor()
    );
    buckets.putIfAbsent(key, () => []).add(f);
  }
  return [
    for (final bucket in buckets.values)
      if (bucket.length == 1)
        _facilityMarker(bucket.single,
            warning: shelterExclusion(bucket.single, riskAreas) != null,
            onTap: () => onFacilityTap(bucket.single))
      else
        Marker(
          point: LatLng(
            bucket.map((f) => f.position.latitude).reduce((a, b) => a + b) /
                bucket.length,
            bucket.map((f) => f.position.longitude).reduce((a, b) => a + b) /
                bucket.length,
          ),
          width: 48,
          height: 48,
          child: Semantics(
            button: true,
            label:
                '대피소 ${bucket.where((f) => f.type == FacilityType.shelter).length}곳, 의료시설 ${bucket.where((f) => f.type == FacilityType.medical).length}곳 묶음${bucket.any((f) => shelterExclusion(f, riskAreas) != null) ? ', 위험 구역 시설 포함' : ''}. 눌러 확대',
            child: GestureDetector(
              onTap: () => onClusterTap(LatLng(
                bucket.map((f) => f.position.latitude).reduce((a, b) => a + b) /
                    bucket.length,
                bucket
                        .map((f) => f.position.longitude)
                        .reduce((a, b) => a + b) /
                    bucket.length,
              )),
              child: CircleAvatar(
                backgroundColor: Colors.teal.shade800,
                child: Text('${bucket.length}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ),
  ];
}

Marker _facilityMarker(Facility facility,
        {bool warning = false, required VoidCallback onTap}) =>
    Marker(
      point: facility.position,
      width: 46,
      height: 50,
      child: Tooltip(
        message:
            '${facility.type == FacilityType.shelter ? '대피소' : '의료시설'} · ${facility.name}${warning ? ' · 위험 구역 주의' : ''}',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Stack(children: [
              Align(
                alignment: Alignment.topCenter,
                child: Icon(
                  facility.type == FacilityType.shelter
                      ? Icons.health_and_safety
                      : Icons.local_hospital,
                  color: facility.type == FacilityType.shelter
                      ? Colors.teal.shade800
                      : Colors.red.shade700,
                  size: 30,
                ),
              ),
              if (warning)
                const Positioned(
                  right: 1,
                  top: 0,
                  child: Icon(Icons.warning_amber_rounded,
                      color: Colors.deepOrange, size: 18),
                ),
            ]),
          ),
        ),
      ),
    );

Color _hazardColor(HazardKind k) => switch (k) {
      HazardKind.flood => Colors.blue.shade800,
      HazardKind.wind => Colors.deepOrange.shade700,
      HazardKind.slide => Colors.brown.shade700,
      HazardKind.overlap => Colors.purple.shade800,
      HazardKind.storm => Colors.indigo.shade800,
    };
Color _windColor(double averageSpeed, double gustSpeed) {
  if (averageSpeed >= 21 || gustSpeed >= 26) return Colors.red.shade800;
  if (averageSpeed >= 14 || gustSpeed >= 20) return Colors.deepOrange;
  return Colors.blueGrey.shade700;
}

enum _DashboardMode { emergency, facilities }

IconData _hazardIcon(HazardKind k) => switch (k) {
      HazardKind.flood => Icons.flood,
      HazardKind.wind => Icons.navigation,
      HazardKind.slide => Icons.terrain,
      HazardKind.overlap => Icons.warning_amber_rounded,
      HazardKind.storm => Icons.cyclone,
    };

class DisasterDashboard extends StatefulWidget {
  const DisasterDashboard({
    super.key,
    this.routeActive = false,
    this.facilities = const [],
    this.riskAreas = const [],
    this.currentLocation = guryongpo,
    this.selectedDestination,
    this.safetyRoute,
    this.routeLoading = false,
    this.routeError,
    this.routeType = RouteType.safest,
    this.onChooseFacility,
    this.onRouteTypeChanged,
    this.onEndRoute,
    this.onRetryRoute,
    this.demo = true,
    this.simulated = false,
    this.floodGrids,
    this.riskItems = const [],
    this.windPoints = const [],
    this.liveTop,
    this.liveBottom,
    this.routeExtras,
  });

  final bool routeActive;
  final List<Facility> facilities;
  final List<RiskArea> riskAreas;
  final LatLng currentLocation;
  final Facility? selectedDestination;
  final SafetyRoute? safetyRoute;
  final bool routeLoading;
  final String? routeError;
  final RouteType routeType;
  final VoidCallback? onChooseFacility;
  final ValueChanged<RouteType>? onRouteTypeChanged;
  final VoidCallback? onEndRoute;
  final VoidCallback? onRetryRoute;

  /// 시연 모드(가상 시나리오). false = 실측: 아래 값으로 위험 카드·침수 격자·바람·장소 위험·실시간 정보를 채운다 (2026-10-05)
  final bool demo;
  /// 서버 시연 데이터 (실제 센서 위치 + 시연 측정값) — 범례 문구만 다르다
  final bool simulated;
  final List<FloodGrid>? floodGrids;
  /// 서버 위험 판정 항목 (/dashboard point_risk.items)
  final List<Map<String, dynamic>> riskItems;
  /// 실측 바람 (위치, 평균풍속 m/s, 풍향(불어오는 방향 °), 지점 이름, 관측 시각)
  final List<(LatLng, double, double, String, String?)> windPoints;
  /// 실측 모드 위쪽(판정 시각·출발 위치·바로가기·머리 배너)과 아래쪽(실시간 관측 카드·가까운 대피소)
  final Widget? liveTop, liveBottom;
  /// 경로 패널에 붙일 것 (출발 위치·길찾기·이동 중 안내)
  final Widget? routeExtras;

  @override
  State<DisasterDashboard> createState() => _DisasterDashboardState();
}

class _DisasterDashboardState extends State<DisasterDashboard> {
  _DashboardMode dashboardMode = _DashboardMode.emergency;
  bool compositeView = true;
  final activeLayers = <HazardKind>{};
  DemoHazard? selected;
  LatLng focus = guryongpo;
  double mapZoom = 13;
  bool zoomUpdateScheduled = false;
  final MapController mapController = MapController();
  Map<String, String> savedProfile = {};
  List<SavedPlace> savedPlaces = [];
  String? fittedRouteKey;
  /// 시연 = 가상 격자, 실측 = 서버 침수 격자
  List<FloodGrid> get _grids => widget.demo ? demoFloodGrid(0) : (widget.floodGrids ?? const <FloodGrid>[]);
  /// 지점의 위험 단계 (주의·경계·심각 / 미확인 또는 정상)
  String _levelAt(LatLng p) {
    if (widget.demo) return _riskForPosition(p, _grids);
    const order = ['주의', '경계', '심각'];
    var best = _riskForPosition(p, _grids);
    for (final a in widget.riskAreas) {
      if (a.contains(p) && order.indexOf(a.level) > order.indexOf(best)) best = a.level;
    }
    return order.contains(best) ? best : '정상';
  }
  late final MapOptions mapOptions = MapOptions(
    initialCenter: guryongpo,
    // 구룡포 일대로 한정 (2026-10-05): 화면 전체가 범위 안에 있어야 하고(밖은 보이지 않음), 처음엔 범위를 꽉 채운다
    initialCameraFit: CameraFit.insideBounds(bounds: guryongpoBounds),
    cameraConstraint: CameraConstraint.contain(bounds: guryongpoBounds),
    onPositionChanged: (camera, _) {
      if ((camera.zoom - mapZoom).abs() > .2 &&
          mounted &&
          !zoomUpdateScheduled) {
        zoomUpdateScheduled = true;
        final zoom = camera.zoom;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          zoomUpdateScheduled = false;
          if (mounted && (zoom - mapZoom).abs() > .2) {
            setState(() => mapZoom = zoom);
          }
        });
      }
    },
    onTap: (_, point) {
      if (!compositeView && !activeLayers.contains(HazardKind.flood)) return;
      final grids = _grids;
      final cell = grids
          .where((g) =>
              point.latitude >= g.south &&
              point.latitude <= g.north &&
              point.longitude >= g.west &&
              point.longitude <= g.east)
          .firstOrNull;
      if (cell != null &&
          cell.hasRisk &&
          (!compositeView || cell.level == '심각')) _showGrid(context, cell);
    },
  );

  @override
  void initState() {
    super.initState();
    dashboardMode = widget.routeActive
        ? _DashboardMode.facilities
        : _DashboardMode.emergency;
    _loadRegisteredPlaces();
  }

  Future<void> _loadRegisteredPlaces() async {
    final profile = await AccountService().optionalProfile();
    final places = await AccountService().places();
    if (mounted)
      setState(() {
        savedProfile = profile;
        savedPlaces = places;
      });
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }

  void choose(String value) {
    if (value == '태풍') {
      context.push('/typhoon', extra: 'local');
      return;
    }
    setState(() {
      selected = null;
      compositeView = true;
      activeLayers.clear();
      focus = guryongpo;
    });
    mapController.fitCamera(CameraFit.insideBounds(bounds: guryongpoBounds));
  }

  void toggleLayer(HazardKind layer, bool on) => setState(() {
        if (compositeView) {
          compositeView = false;
          activeLayers.clear();
        }
        if (on) {
          activeLayers.add(layer);
        } else {
          activeLayers.remove(layer);
        }
      });

  void setCompositeView(bool on) => setState(() {
        compositeView = on;
        activeLayers.clear();
      });

  void setDashboardMode(_DashboardMode mode) {
    final shouldChooseFacility =
        mode == _DashboardMode.facilities && widget.selectedDestination == null;
    setState(() => dashboardMode = mode);
    if (shouldChooseFacility) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && dashboardMode == _DashboardMode.facilities) {
          widget.onChooseFacility?.call();
        }
      });
    }
  }

  Widget _emergencyLayerControls(Set<HazardKind> visible) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilterChip(
            avatar: const Icon(Icons.dashboard_outlined, size: 18),
            label: const Text('전체 재난 표시'),
            selected: compositeView,
            onSelected: setCompositeView,
          ),
          ActionChip(
            avatar: const Icon(Icons.cyclone, size: 18),
            label: const Text('태풍'),
            onPressed: () => choose('태풍'),
          ),
          FilterChip(
            label: const Text('침수 격자'),
            selected: !compositeView && visible.contains(HazardKind.flood),
            onSelected: (on) => toggleLayer(HazardKind.flood, on),
          ),
          FilterChip(
            label: const Text('강풍 화살표·풍속'),
            selected: !compositeView && visible.contains(HazardKind.wind),
            onSelected: (on) => toggleLayer(HazardKind.wind, on),
          ),
          FilterChip(
            label: const Text('산사태 위험 지역'),
            selected: !compositeView && visible.contains(HazardKind.slide),
            onSelected: (on) => toggleLayer(HazardKind.slide, on),
          ),
        ],
      );

  void focusOn(LatLng point) {
    setState(() => focus = point);
    mapController.move(point, 15);
  }

  Widget _personalizedMockAlerts(BuildContext context) {
    if (AppConfig.isRemote || !widget.demo) return const SizedBox.shrink();
    final grids = _grids;
    final alerts = <(String, String, LatLng, String)>[];
    for (final key in ['home', 'work']) {
      final position = _position(savedProfile, key);
      if (position == null) continue;
      final level = _riskForPosition(position, grids);
      if (level == '미확인') continue;
      final isHome = key == 'home';
      final name = (savedProfile['${key}Name'] ?? '').trim().isEmpty
          ? (isHome ? '집' : '직장')
          : savedProfile['${key}Name']!;
      final address = savedProfile['${key}Address'] ?? '주소 미등록';
      alerts.add((
        '$name 주변 침수 위험 · $level',
        '$address 주변의 침수 위험을 가정한 사용자 맞춤 목업 경고입니다.',
        position,
        level,
      ));
    }
    if (alerts.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('사용자 맞춤형 선제 경고 · 예시',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final alert in alerts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.notifications_active_outlined,
                    color: _riskColor(alert.$4)),
                title: Text(alert.$1,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(alert.$2),
                onTap: () => focusOn(alert.$3),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => context.go('/alerts-hub'),
                icon: const Icon(Icons.open_in_new),
                label: const Text('선제 경고 전체 보기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant DisasterDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.routeActive && widget.routeActive) {
      dashboardMode = _DashboardMode.facilities;
    }
    final route = widget.safetyRoute;
    final destination = widget.selectedDestination;
    if (route == null || destination == null) {
      fittedRouteKey = null;
      return;
    }
    final bounds = LatLngBounds.fromPoints([
      widget.currentLocation,
      ...route.seaPoints,
      ...route.polylinePoints,
      destination.position
    ]);
    final key = '${bounds.northWest}:${bounds.southEast}';
    if (key == fittedRouteKey) return;
    fittedRouteKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        mapController.fitCamera(CameraFit.bounds(
            bounds: bounds, padding: const EdgeInsets.all(60)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final routeMode = dashboardMode == _DashboardMode.facilities;
    final visible = routeMode
        ? <HazardKind>{}
        : compositeView
            ? <HazardKind>{
                HazardKind.flood,
                HazardKind.wind,
                HazardKind.slide,
                HazardKind.overlap,
              }
            : activeLayers;
    final floodGrids = _grids;
    final destination = routeMode ? widget.selectedDestination : null;
    final route = routeMode ? widget.safetyRoute : null;
    final facilityMarkers = _clusteredFacilities(widget.facilities, mapZoom,
        selectedId: destination?.id,
        riskAreas: widget.riskAreas,
        onFacilityTap: (facility) => _showFacility(context, facility),
        onClusterTap: (point) => focusOn(point));
    final registered = <(LatLng, String)>[
      if (_position(savedProfile, 'home') case final p?)
        (
          p,
          savedProfile['homeName']?.isNotEmpty == true
              ? savedProfile['homeName']!
              : '집'
        ),
      if (_position(savedProfile, 'work') case final p?)
        (
          p,
          savedProfile['workName']?.isNotEmpty == true
              ? savedProfile['workName']!
              : '직장'
        ),
      for (final p in savedPlaces) (p.position, p.name),
    ];
    final legendParts = [
      if (visible.contains(HazardKind.flood)) '침수',
      if (visible.contains(HazardKind.wind)) '강풍',
      if (visible.contains(HazardKind.slide)) '산사태',
    ];
    final legendTitle = compositeView || legendParts.isEmpty
        ? '지도 범례'
        : '${legendParts.join('·')} 범례';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '대시보드',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: '프로필 설정',
              onPressed: () => context.push('/profile'),
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        SegmentedButton<_DashboardMode>(
          segments: const [
            ButtonSegment(
              value: _DashboardMode.emergency,
              icon: Icon(Icons.dashboard_outlined),
              label: Text('긴급 재난 종합'),
            ),
            ButtonSegment(
              value: _DashboardMode.facilities,
              icon: Icon(Icons.directions_walk),
              label: Text('대피소·의료시설 경로'),
            ),
          ],
          selected: {dashboardMode},
          onSelectionChanged: (selection) => setDashboardMode(selection.first),
        ),
        const SizedBox(height: 12),
        if (!routeMode) ...[
          if (widget.demo) ...[
            const _DemoBanner(),
            const SizedBox(height: 10),
            const PrototypeFeatureLinks(),
          ] else if (widget.liveTop != null)
            widget.liveTop!,
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: widget.demo
                ? [
                    _riskCard(context, demoHazards[0]),
                    _riskCard(context, demoHazards[1]),
                    _riskCard(context, demoHazards[2]),
                    _riskCard(context, demoHazards[3]),
                  ]
                : widget.riskItems.isEmpty
                    ? [_liveRiskCard(context, null)]
                    : [for (final i in widget.riskItems) _liveRiskCard(context, i)],
          ),
          const SizedBox(height: 12),
          _emergencyLayerControls(visible),
          const SizedBox(height: 8),
        ] else ...[
          _integratedRoutePanel(context),
          const SizedBox(height: 8),
        ],
        SizedBox(
          height: 390,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: FlutterMap(
              mapController: mapController,
              options: mapOptions,
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'guryongpo.safety.demo',
                ),
                if (visible.contains(HazardKind.flood))
                  PolygonLayer(
                      polygons: _disasterFloodPolygons(floodGrids,
                          severeOnly: compositeView)),
                if (!routeMode && widget.riskAreas.isNotEmpty)
                  PolygonLayer(
                    polygons: [
                      for (final area in DemoData.mapAreas(widget.riskAreas))
                        for (final ring in area.polygons)
                          if (ring.length >= 3)
                            Polygon(
                              points: ring,
                              color: _floodColor(area.level)
                                  .withValues(alpha: .22),
                              borderColor:
                                  _hazardColor(area.hazard == 'landslide'
                                      ? HazardKind.slide
                                      : area.hazard == 'wind'
                                          ? HazardKind.wind
                                          : HazardKind.flood),
                              borderStrokeWidth: 2,
                            ),
                    ],
                  ),
                if (route != null && route.polylinePoints.length > 1)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: route.polylinePoints,
                      color: Colors.white,
                      strokeWidth: 11,
                    ),
                    Polyline(
                      points: route.polylinePoints,
                      color: Colors.blue.shade800,
                      strokeWidth: 7,
                    ),
                    if (route.seaPoints.length > 1)
                      Polyline(
                          points: route.seaPoints,
                          color: Colors.teal.shade700,
                          strokeWidth: 5,
                          pattern: const StrokePattern.dotted()),
                  ]),
                MarkerLayer(
                  markers: [
                    if (visible.contains(HazardKind.flood))
                      for (final g in floodGrids.where((g) =>
                          g.hasRisk && (!compositeView || g.level == '심각')))
                        Marker(
                          point: g.center,
                          width: 22,
                          height: 22,
                          child: GestureDetector(
                            onTap: () => _showGrid(context, g),
                            child: DecoratedBox(
                                decoration: BoxDecoration(
                                    color: _floodColor(g.level),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2))),
                          ),
                        ),
                    // 수위계 위치 (2026-10-07): 침수 영역 원의 중심 = 판정 원인 센서의 실제 좌표 (포항 DT 수위계·맨홀)
                    if (!routeMode && visible.contains(HazardKind.flood))
                      for (final a in _floodSensors(DemoData.mapAreas(widget.riskAreas)))
                        Marker(
                          point: a.sensor!,
                          width: 30,
                          height: 30,
                          child: Tooltip(
                            message: a.reason ?? a.label,
                            child: GestureDetector(
                              onTap: () => _showSensor(context, a),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: _hazardColor(HazardKind.flood), width: 2),
                                    boxShadow: const [
                                      BoxShadow(color: Colors.black26, blurRadius: 3)
                                    ]),
                                child: Icon(Icons.water_drop,
                                    size: 18,
                                    color: a.level == '정상' || a.level == '관심'
                                        ? _hazardColor(HazardKind.flood)
                                        : _floodColor(a.level)),
                              ),
                            ),
                          ),
                        ),
                    if (visible.contains(HazardKind.wind) && !widget.demo)
                      for (final w in widget.windPoints)
                        Marker(
                          point: w.$1,
                          width: 76,
                          height: 64,
                          child: GestureDetector(
                            onTap: () => _showLiveWind(context, w),
                            child: Column(children: [
                              // 화살표는 불어가는 방향 = 풍향(불어오는 방향) + 180°
                              Transform.rotate(
                                angle: (w.$3 + 180) * math.pi / 180,
                                child: Icon(Icons.navigation,
                                    color: _windColor(w.$2, w.$2), size: 18 + math.min(w.$2, 24)),
                              ),
                              Text('${w.$2.toStringAsFixed(1)}m/s',
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ]),
                          ),
                        ),
                    if (visible.contains(HazardKind.wind) && widget.demo)
                      for (final w in const [
                        (LatLng(35.9892, 129.5620), 21.0, '북동풍'),
                        (LatLng(35.9902, 129.5550), 17.0, '북동풍'),
                        (LatLng(35.9855, 129.5530), 10.0, '동풍'),
                        (LatLng(35.9955, 129.5480), 7.0, '동풍'),
                      ])
                        Marker(
                          point: w.$1,
                          width: 76,
                          height: 64,
                          child: GestureDetector(
                            onTap: () => _showWind(context, w.$1, w.$2, w.$3),
                            child: Column(
                              children: [
                                Transform.rotate(
                                  angle: (w.$3 == '북동풍' ? 225 : 270) *
                                      math.pi /
                                      180,
                                  child: Icon(
                                    Icons.navigation,
                                    color: _windColor(w.$2, w.$2 + 9),
                                    size: 18 + w.$2,
                                  ),
                                ),
                                Text(
                                  '${w.$2.toInt()}m/s',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    if (widget.demo && visible.contains(HazardKind.slide))
                      Marker(
                        point: demoHazards[1].point,
                        width: 54,
                        height: 54,
                        child: GestureDetector(
                          onTap: () => _showHazard(context, demoHazards[1]),
                          child: const Icon(
                            Icons.terrain,
                            color: Colors.brown,
                            size: 38,
                          ),
                        ),
                      ),
                    if (widget.demo && visible.contains(HazardKind.overlap))
                      Marker(
                        point: demoHazards[3].point,
                        width: 56,
                        height: 56,
                        child: GestureDetector(
                          onTap: () => _showHazard(context, demoHazards[3]),
                          child: const Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.purple,
                            size: 40,
                          ),
                        ),
                      ),
                    ...demoHazards
                        .where(
                          (h) =>
                              widget.demo &&
                              h.kind != HazardKind.overlap &&
                              h.kind != HazardKind.flood &&
                              visible.contains(h.kind),
                        )
                        .map(
                          (h) => Marker(
                            point: h.point,
                            width: 42,
                            height: 42,
                            child: GestureDetector(
                              onTap: () => _showHazard(context, h),
                              child: Icon(
                                _hazardIcon(h.kind),
                                color: _hazardColor(h.kind),
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                    if (!routeMode)
                      for (final place in registered)
                        Marker(
                          point: place.$1,
                          width: 78,
                          height: 54,
                          child: Column(children: [
                            Icon(
                                place.$2.contains('집')
                                    ? Icons.home
                                    : Icons.business,
                                color: _riskColor(_levelAt(place.$1)),
                                size: 28),
                            Container(
                                color: Colors.white.withValues(alpha: .92),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                child: Text(
                                    '${place.$2} · ${_levelAt(place.$1)}',
                                    style: const TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold))),
                          ]),
                        ),
                    if (routeMode) ...facilityMarkers,
                    if (destination != null)
                      Marker(
                        point: destination.position,
                        width: 150,
                        height: 58,
                        child: Stack(children: [
                          Column(children: [
                            Icon(
                              destination.type == FacilityType.medical
                                  ? Icons.local_hospital
                                  : Icons.location_on,
                              color: Colors.blue.shade800,
                              size: 38,
                            ),
                            Container(
                              color: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(destination.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ]),
                          if (shelterExclusion(destination, widget.riskAreas) !=
                              null)
                            const Positioned(
                              right: 28,
                              top: 0,
                              child: Icon(Icons.warning_amber_rounded,
                                  color: Colors.deepOrange, size: 18),
                            ),
                        ]),
                      ),
                    Marker(
                      point: widget.currentLocation,
                      width: 92,
                      height: 54,
                      child: Column(children: [
                        Icon(Icons.my_location,
                            color: _riskColor(_levelAt(widget.currentLocation)),
                            size: 30),
                        Container(
                          color: Colors.white.withValues(alpha: .94),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                              '현위치 · ${_levelAt(widget.currentLocation)}',
                              style: const TextStyle(
                                  fontSize: 9, fontWeight: FontWeight.bold)),
                        ),
                      ]),
                    ),
                  ],
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: Colors.white.withValues(alpha: .94)),
                    onPressed: () => _showMapLegend(context,
                        routeMode: routeMode,
                        visible: visible,
                        hasRoute: route != null,
                        hasSea: (route?.seaPoints.length ?? 0) > 1,
                        hidesTownWide: DemoData.on),
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: const Text('범례'),
                  ),
                ),
                if (!routeMode)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(legendTitle,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            if (compositeView) ...const [
                              Text('재난 표식은 영향 위치',
                                  style: TextStyle(fontSize: 11)),
                              Text('바람 화살표는 방향·세기',
                                  style: TextStyle(fontSize: 11)),
                              Text('침수는 심각 단계만 표시',
                                  style: TextStyle(fontSize: 11)),
                            ],
                            if (!compositeView &&
                                visible.contains(HazardKind.flood)) ...const [
                              Text('격자색은 서버 위험 단계',
                                  style: TextStyle(fontSize: 11)),
                              Text('실측 수심 구간 기준이 아님',
                                  style: TextStyle(fontSize: 10)),
                            ],
                            if (!compositeView &&
                                visible.contains(HazardKind.flood) &&
                                widget.demo)
                              const Text('목업 격자는 예시 데이터',
                                  style: TextStyle(fontSize: 10)),
                            if (!compositeView &&
                                visible.contains(HazardKind.slide))
                              Text(widget.demo ? '산사태 표식은 목업 알림 위치입니다.' : '산사태는 판정된 위험 영역으로 표시',
                                  style: const TextStyle(fontSize: 11)),
                            Text(widget.demo ? '가상 시연 데이터' : widget.simulated ? '시연 측정값 · 실측과 같은 판정 규칙' : '실측 · 서버 위험 판정',
                                style: const TextStyle(fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (!routeMode &&
                    !compositeView &&
                    (visible.contains(HazardKind.flood) ||
                        visible.contains(HazardKind.wind)))
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Card(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 230),
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (visible.contains(HazardKind.flood)) ...[
                                const Text('침수 위험 단계',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold)),
                                for (final item in const [
                                  ('주의', '주의'),
                                  ('경계', '경계'),
                                  ('심각', '심각')
                                ])
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 12,
                                        height: 12,
                                        color: _floodColor(item.$1)
                                            .withValues(alpha: .7),
                                      ),
                                      const SizedBox(width: 5),
                                      Text(item.$2,
                                          style: const TextStyle(fontSize: 10)),
                                    ],
                                  ),
                              ],
                              if (visible.contains(HazardKind.flood) &&
                                  visible.contains(HazardKind.wind))
                                const Divider(height: 12),
                              if (visible.contains(HazardKind.wind)) ...[
                                const Text('강풍 기준',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold)),
                                const Text('화살표: 불어가는 방향 · 크기·색: 풍속',
                                    style: TextStyle(fontSize: 10)),
                                const Text('주의보: 평균 14m/s 또는 순간 20m/s',
                                    style: TextStyle(fontSize: 10)),
                                const Text('경보: 평균 21m/s 또는 순간 26m/s',
                                    style: TextStyle(fontSize: 10)),
                                TextButton(
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => launchUrl(Uri.parse(
                                    'https://www.weather.go.kr/w/forecast/guide/standard.do',
                                  )),
                                  child: const Text('기상청 공식 기준 보기',
                                      style: TextStyle(fontSize: 10)),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (!routeMode) ...[
          if (visible.contains(HazardKind.slide))
            Card(
              child: ListTile(
                leading: const Icon(Icons.terrain, color: Colors.brown),
                title: const Text('산림청 산사태 위험지도(2025)'),
                subtitle: const Text(
                    '공식 산사태 위험지도 열기 · 위험등급 1~5(1등급이 가장 높음). 앱 지도에는 판정된 산사태 위험 영역만 표시합니다.'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => launchUrl(Uri.parse(
                  'https://sansatai.forest.go.kr/mhms_pub/mhms/lndsInfo/lndsMapViewPage.do',
                )),
              ),
            ),
          const SizedBox(height: 14),
          const Text(
            '등록 장소 위험 요약',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          _SavedPlaceSummary(
            currentLocation: widget.currentLocation,
            onFocus: (p) => focusOn(p),
            levelAt: widget.demo ? null : _levelAt,
          ),
          _personalizedMockAlerts(context),
          const SizedBox(height: 8),
          Text(
            widget.demo
                ? '실시간 정보 · 각 지점은 서로 다른 측정 위치의 가상 자료'
                : '실시간 관측·예보 · 기상청·포항 디지털 트윈',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (widget.demo) const _RealtimeCards() else if (widget.liveBottom != null) widget.liveBottom!,
          const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _riskCard(BuildContext context, DemoHazard h) => SizedBox(
        width: MediaQuery.sizeOf(context).width > 850 ? 300 : null,
        child: Card(
          color: _hazardColor(h.kind).withValues(alpha: .06),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() {
                selected = h;
                focus = h.point;
                compositeView = false;
                activeLayers.add(h.kind);
              });
              mapController.move(h.point, 15);
              _showHazard(context, h);
            },
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_hazardIcon(h.kind), color: _hazardColor(h.kind)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${h.id} · ${h.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${h.summary}\n기준 ${h.time} · ${h.guide}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// 실측 위험 카드: 서버 판정 항목 1개 (null = 위험 없음)
  Widget _liveRiskCard(BuildContext context, Map<String, dynamic>? i) {
    final kind = switch (i?['hazard']) {
      'landslide' => HazardKind.slide,
      'strong_wind' || 'high_seas' => HazardKind.wind,
      'typhoon' => HazardKind.storm,
      null => HazardKind.flood,
      _ => HazardKind.flood,
    };
    final loc = i?['location'] as Map?;
    final point = loc == null ? null : LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble());
    final level = _levelKoFromServer('${i?['level'] ?? 'normal'}');
    return SizedBox(
      width: MediaQuery.sizeOf(context).width > 850 ? 300 : null,
      child: Card(
        color: (i == null ? Colors.green : _hazardColor(kind)).withValues(alpha: .06),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: point == null
              ? null
              : () {
                  setState(() {
                    compositeView = false;
                    activeLayers.add(kind);
                  });
                  mapController.move(point, 15);
                },
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(i == null ? Icons.verified_outlined : _hazardIcon(kind),
                  color: i == null ? Colors.green.shade700 : _hazardColor(kind)),
              const SizedBox(width: 9),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i == null ? '현재 위치 주변 위험 없음 · 정상' : '${i['label']} · $level',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    i == null
                        ? '침수·호우·강풍·산사태·태풍·풍랑·생활안전 판정 결과 주의 이상 위험이 없습니다.'
                        : [
                            if (i['reason'] != null) '${i['reason']}',
                            if (i['observed_at'] != null) '기준 ${_hhmm('${i['observed_at']}')}',
                            if (i['simulated'] == true) '시연용 모의값',
                          ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _integratedRoutePanel(BuildContext context) {
    final destination = widget.selectedDestination;
    final route = widget.safetyRoute;
    final warning = destination == null
        ? null
        : shelterExclusion(destination, widget.riskAreas);
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.route_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                destination == null
                    ? '대피·의료시설'
                    : '${switch (destination.type) { FacilityType.shelter => '대피소', FacilityType.medical => '의료시설', _ => '목적지' }} 경로 · ${destination.name}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: widget.onChooseFacility,
              icon: const Icon(Icons.place_outlined),
              label: Text(destination == null ? '목적지 선택' : '변경'),
            ),
            if (destination != null)
              IconButton(
                tooltip: '경로 안내 종료',
                onPressed: widget.onEndRoute,
                icon: const Icon(Icons.close),
              ),
          ]),
          if (widget.routeLoading) ...const [
            LinearProgressIndicator(),
            SizedBox(height: 8),
            Text('위험 구역을 확인해 경로를 준비하고 있습니다.'),
          ],
          if (warning != null)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.warning_amber_rounded,
                  color: Colors.deepOrange),
              title: Text(warning),
              subtitle: Text(destination?.type == FacilityType.medical
                  ? '의료시설은 선택할 수 있지만, 위험 구역 경고를 확인하세요.'
                  : '위험 구역 내 대피소입니다. 안전한 대체 시설을 우선 확인하세요.'),
            ),
          if (widget.routeError != null)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.route_outlined),
              title: const Text('경로를 불러오지 못했습니다. 지도와 시설 표시는 유지됩니다.'),
              subtitle: Text(widget.routeError!),
              trailing: widget.onRetryRoute == null
                  ? null
                  : IconButton(
                      tooltip: '경로 다시 찾기',
                      onPressed: widget.onRetryRoute,
                      icon: const Icon(Icons.refresh),
                    ),
            ),
          if (route != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${route.distanceMeters >= 1000 ? '${(route.distanceMeters / 1000).toStringAsFixed(1)}km' : '${route.distanceMeters}m'} · 도보 ${route.estimatedMinutes}분 · ${route.routeType == RouteType.nearest ? '가까운 경로' : '안전 경로'}${route.hazardsOk ? '' : ' · 위험 정보 확인 불가'}\n${route.riskAvoidanceSummary}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (destination != null)
            Wrap(spacing: 6, children: [
              ChoiceChip(
                label: const Text('가까운 경로'),
                selected: widget.routeType == RouteType.nearest,
                onSelected: (_) =>
                    widget.onRouteTypeChanged?.call(RouteType.nearest),
              ),
              ChoiceChip(
                label: const Text('안전 경로'),
                selected: widget.routeType == RouteType.safest,
                onSelected: (_) =>
                    widget.onRouteTypeChanged?.call(RouteType.safest),
              ),
            ]),
          if (destination == null)
            const Text('확대하면 시설이 개별 표시됩니다. 묶음 표식을 누르면 해당 구역으로 확대합니다.',
                style: TextStyle(fontSize: 12)),
          if (widget.routeExtras != null) ...[
            const SizedBox(height: 6),
            widget.routeExtras!,
          ],
        ]),
      ),
    );
  }

  void _showFacility(BuildContext context, Facility facility) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: [
            Text(facility.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(facility.type == FacilityType.shelter ? '대피소' : '의료시설'),
            if (facility.address.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.location_on_outlined),
                title: const Text('주소'),
                subtitle: Text(facility.address),
              ),
            if (facility.description.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline),
                title: const Text('시설 정보'),
                subtitle: Text(facility.description),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.directions_walk),
              title: const Text('거리 및 도보 시간'),
              subtitle: Text(
                  '${facility.distanceKm.toStringAsFixed(1)}km · ${facility.walkMinutes}분'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.accessible_forward),
              title: const Text('접근성'),
              subtitle: Text(facility.accessible ? '휠체어 접근 가능' : '확인 필요'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text('운영 상태'),
              subtitle: Text(facility.open ? '운영 중' : '운영하지 않음'),
            ),
            if (facility.phone?.isNotEmpty == true)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_outlined),
                title: const Text('연락처'),
                subtitle: Text(facility.phone!),
              ),
          ],
        ),
      ),
    );
  }
}

void _showHazard(BuildContext c, DemoHazard h) => showModalBottomSheet<void>(
      context: c,
      showDragHandle: true,
      builder: (_) => _detailSheet(
          c, h.name, h.summary, h.time, h.guide, '위험 안내 목업 데이터 · 실제 발생 정보 아님'),
    );
/// 센서마다 하나 (같은 수위계가 규칙 두 개로 영역 두 개를 내면 높은 단계만)
List<RiskArea> _floodSensors(List<RiskArea> areas) {
  const order = ['정상', '관심', '주의', '경계', '심각'];
  final best = <String, RiskArea>{};
  for (final a in areas) {
    final p = a.sensor;
    if (a.hazard != 'flood' || p == null) continue;
    final key = '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';
    final cur = best[key];
    if (cur == null || order.indexOf(a.level) > order.indexOf(cur.level)) best[key] = a;
  }
  return best.values.toList();
}

void _showSensor(BuildContext c, RiskArea a) => showModalBottomSheet<void>(
      context: c,
      showDragHandle: true,
      builder: (context) => _detailSheet(
        context,
        '수위계 · ${a.label}',
        a.reason ?? a.label,
        _hhmm(a.observedAt),
        '이 센서를 중심으로 한 원이 침수 ${a.level} 영역입니다. 주의 이상이면 경로가 이 원을 피합니다.',
        DemoData.on ? '포항 디지털 트윈 센서 실제 위치 · 측정값은 시연값' : '포항 디지털 트윈 센서 실측',
      ),
    );

void _showGrid(BuildContext c, FloodGrid g) => showModalBottomSheet<void>(
      context: c,
      showDragHandle: true,
      builder: (context) => _detailSheet(
        context,
        '침수 격자 ${g.id}',
        '침수 위험 · ${g.level}${g.depthCm == null ? '\n수심 미확인' : '\n예시 수심 ${g.depthCm!.toStringAsFixed(0)}cm'}',
        g.observedAt ?? '확인 시각 없음',
        '위험 단계 셀에는 진입하지 말고 안전한 경로를 이용하세요.',
        '${g.source.isEmpty ? '자료 미확인' : g.source}${g.isExample ? ' · 예시 데이터, 실제 관측이 아닙니다' : ''}',
      ),
    );
void _showWind(
  BuildContext c,
  LatLng p,
  double speed,
  String from,
) =>
    showModalBottomSheet<void>(
      context: c,
      showDragHandle: true,
      builder: (context) => _detailSheet(
        context,
        '구룡포 강풍 관측 시연지점',
        '평균풍속 ${speed.toInt()}m/s · 순간최대풍속 ${speed.toInt() + 9}m/s · 풍향 $from(불어오는 방향)\n지도 화살표는 불어가는 방향',
        demoTime,
        '해안가·옥외 시설물 주변을 피하세요. 태풍 DEMO 영향(가상 시나리오).',
        '관측(가상 시연 자료)',
      ),
    );
void _showLiveWind(BuildContext c, (LatLng, double, double, String, String?) w) =>
    showModalBottomSheet<void>(
      context: c,
      showDragHandle: true,
      builder: (context) => _detailSheet(
        context,
        w.$4,
        '평균풍속 ${w.$2.toStringAsFixed(1)}m/s · 풍향 ${w.$3.round()}°(불어오는 방향)\n지도 화살표는 불어가는 방향',
        _hhmm(w.$5),
        w.$2 >= 14 ? '해안가·옥외 시설물 주변을 피하세요.' : '강풍 주의보 기준(평균 14m/s) 아래입니다.',
        '실측 (기상청 AWS·포항 디지털 트윈 대기 센서)',
      ),
    );

String _levelKoFromServer(String level) =>
    const {'watch': '관심', 'advisory': '주의', 'warning': '경보', 'critical': '위험'}[level] ?? '정상';

String _hhmm(String? iso) {
  final t = DateTime.tryParse(iso ?? '')?.toLocal();
  return t == null ? '-' : '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

Widget _detailSheet(
  BuildContext context,
  String title,
  String summary,
  String time,
  String guide,
  String source,
) =>
    SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(summary),
            Text('기준 시각: $time'),
            Text('자료 구분: $source'),
            const SizedBox(height: 8),
            Text('행동 안내: $guide'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('닫기'),
              ),
            ),
          ],
        ),
      ),
    );

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();
  @override
  Widget build(BuildContext c) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.amber.shade100,
          borderRadius: BorderRadius.circular(9),
        ),
        child: const Text(
          '모든 위험·좌표·측정값·시설 정보는 실제 발생 정보가 아닌 시연용 가상 데이터입니다. 기상청 실시간 자료 미연동.',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        ),
      );
}

class _SavedPlaceSummary extends StatefulWidget {
  const _SavedPlaceSummary({
    required this.currentLocation,
    required this.onFocus,
    this.levelAt,
  });
  final LatLng currentLocation;
  final ValueChanged<LatLng> onFocus;
  /// 실측: 위험 영역·침수 격자로 판정한 단계. null = 시연(가상 격자)
  final String Function(LatLng)? levelAt;
  @override
  State<_SavedPlaceSummary> createState() => _SavedPlaceSummaryState();
}

class _SavedPlaceSummaryState extends State<_SavedPlaceSummary> {
  Map<String, String> profile = {};
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await AccountService().optionalProfile();
    if (mounted) setState(() => profile = p);
  }

  @override
  Widget build(BuildContext c) {
    final home = _position(profile, 'home');
    final work = _position(profile, 'work');
    final grids = demoFloodGrid(0);
    return FutureBuilder<List<SavedPlace>>(
      future: AccountService().places(),
      builder: (c, s) {
        final places = s.data ?? const <SavedPlace>[];
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _placeTile(
              c,
              '현위치',
              widget.currentLocation,
              widget.levelAt == null ? '현재 위치 기준 · 예시 판정' : '현재 위치 기준 · 서버 위험 판정',
              grids,
              Icons.my_location,
            ),
            if (home != null)
              _placeTile(
                c,
                profile['homeName'] ?? '집',
                home,
                profile['homeAddress'] ?? '주소 미등록',
                grids,
                Icons.home,
              ),
            if (work != null)
              _placeTile(
                c,
                profile['workName'] ?? '직장',
                work,
                profile['workAddress'] ?? '주소 미등록',
                grids,
                Icons.business,
              ),
            ...places.map(
              (p) => _placeTile(
                c,
                p.name,
                p.position,
                p.address.isEmpty ? '주소 미등록' : p.address,
                grids,
                Icons.place,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _placeTile(
    BuildContext c,
    String title,
    LatLng p,
    String address,
    List<FloodGrid> grids,
    IconData icon,
  ) {
    final cell = _gridForPosition(p, grids);
    final live = widget.levelAt != null;
    final level = live ? widget.levelAt!(p) : (cell?.hasRisk == true ? cell!.level : '미확인');
    final color = _riskColor(level);
    final progress = switch (level) {
      '심각' => 1.0,
      '경계' => .72,
      '주의' => .42,
      _ => .08,
    };
    final guidance = switch (level) {
      '심각' => '위험 구간 접근을 피하고 고지대로 이동하세요.',
      '경계' => '저지대·지하 공간 접근을 피하세요.',
      '주의' => '배수 상태와 주변 상황을 확인하세요.',
      '정상' => '현재 주의 이상 위험 구역 밖입니다.',
      _ => '위험 정보 미확인 · 공식 안내를 확인하세요.',
    };
    final depth = cell?.hasRisk == true ? cell!.depthCm : null;
    final summary = live
        ? (level == '정상' ? '위험 구역 밖' : depth == null ? '위험 구역 안' : '침수 깊이 ${depth.round()}cm (센서)')
        : depth == null
            ? '예상 침수 깊이 미확인'
            : '예시 침수 깊이 ${depth.round()}cm';
    return SizedBox(
      width: 245,
      child: Card(
        color: color.withValues(alpha: .06),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            widget.onFocus(p);
            _placeDetail(c, title, address, '$level 위험 · $summary', demo: !live);
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(icon, color: color),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(level,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12)),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(summary,
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 9,
                    color: color,
                    backgroundColor: color.withValues(alpha: .16),
                  ),
                ),
                const SizedBox(height: 7),
                Text(guidance, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                Text(address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.black54)),
                const SizedBox(height: 3),
                const Text('눌러 지도 이동·상세 보기',
                    style: TextStyle(fontSize: 10, color: Colors.black54)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

LatLng? _position(Map<String, String> p, String key) {
  final a = double.tryParse(p['${key}Lat'] ?? '');
  final b = double.tryParse(p['${key}Lon'] ?? '');
  return a == null || b == null ? null : LatLng(a, b);
}

FloodGrid? _gridForPosition(LatLng p, [List<FloodGrid>? grids]) =>
    (grids ?? demoFloodGrid(0))
        .where((g) =>
            p.latitude >= g.south &&
            p.latitude <= g.north &&
            p.longitude >= g.west &&
            p.longitude <= g.east)
        .firstOrNull;

String _riskForPosition(LatLng p, [List<FloodGrid>? grids]) {
  final cell = _gridForPosition(p, grids);
  return cell?.hasRisk == true ? cell!.level : '미확인';
}

Color _riskColor(String level) => switch (level) {
      '정상' => const Color(0xff2e7d32),
      '주의' => const Color(0xffe7ac16),
      '경계' => const Color(0xffe56717),
      '심각' => const Color(0xffd93232),
      _ => const Color(0xff718096),
    };

void _placeDetail(
  BuildContext c,
  String name,
  String address,
  String risk, {
  bool demo = true,
}) =>
    showDialog<void>(
      context: c,
      builder: (ctx) => AlertDialog(
        title: Text(name),
        content: Text(
          '도로명 주소: $address\n위험 요약: $risk${demo ? '\n특이사항: 가상 시연 정보' : ''}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );

class _RealtimeCards extends StatelessWidget {
  const _RealtimeCards();
  @override
  Widget build(BuildContext c) => Column(
        children: [
          _rainfallMetric(),
          _metric(Icons.navigation, '바람', '평균 21 · 순간 30m/s',
              '북동풍 · 화살표는 바람이 불어가는 방향', '해안 시연지점 · 14:00', Colors.deepOrange,
              rotation: math.pi * 1.25),
          _metric(Icons.waves, '파고', '유의 3.2m', '최대파고 4.8m · 높은 파도 예시',
              '해상 시연지점 · 14:00', Colors.blue),
          _metric(Icons.height, '수위', '현재 2.4m', '최근 1시간 +0.3m · 침수 깊이와 별도 지표',
              '수위 시연지점 · 14:00', Colors.teal),
        ],
      );
}

Widget _rainfallMetric() {
  const hourlyRain = <(String, int)>[
    ('09시', 8),
    ('10시', 12),
    ('11시', 17),
    ('12시', 24),
    ('13시', 25),
    ('14시', 32),
  ];
  const color = Colors.indigo;
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.water_drop_outlined, color: color),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('강수',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            _exampleBadge(),
          ]),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              RichText(
                text: const TextSpan(
                  style: TextStyle(color: Colors.black87),
                  children: [
                    TextSpan(
                        text: '32',
                        style: TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w800)),
                    TextSpan(
                        text: ' mm/h',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('강한 비',
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
              const Text('누적 118 mm',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          const Text('최근 6시간 시간당 강수량',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Semantics(
            container: true,
            label:
                '최근 6시간 시간당 강수량 예시. ${hourlyRain.map((e) => '${e.$1} ${e.$2}밀리미터').join(', ')}. 누적 118밀리미터.',
            child: SizedBox(
              height: 78,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < hourlyRain.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('${hourlyRain[i].$2}',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: i == hourlyRain.length - 1
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: i == hourlyRain.length - 1
                                        ? color
                                        : Colors.black54)),
                            const SizedBox(height: 3),
                            Container(
                              height: 38 * hourlyRain[i].$2 / 32,
                              decoration: BoxDecoration(
                                color: color.withValues(
                                    alpha: i == hourlyRain.length - 1
                                        ? .92
                                        : .30 + .08 * i),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(5)),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(hourlyRain[i].$1,
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.black54)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 18),
          const Text('구룡포 강수 시연지점 · 14:00 · 목업 자료',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
    ),
  );
}

Widget _exampleBadge() => _badge('예시');

/// 자료 구분 배지: 예시(가상) · 실측 · 예보 · 자료 없음
Widget _badge(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: (text == '실측' ? Colors.teal : text == '예보' ? Colors.indigo : Colors.black).withValues(alpha: .08),
          borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.black54)),
    );

/// 실측 '실시간 정보' (2026-10-05): 김다인 디자인(_rainfallMetric·_metric) 그대로, 값은 서버 /dashboard 위젯
class LiveRealtimeCards extends StatelessWidget {
  const LiveRealtimeCards({super.key, required this.widgets, this.simulated = false});
  final List<Map<String, dynamic>> widgets;
  /// 서버 시연 데이터면 배지 '실측' → '시연'
  final bool simulated;
  String get _obs => simulated ? '시연' : '실측';

  Map<String, dynamic> _w(String type) => Map<String, dynamic>.from(
      widgets.where((w) => w['type'] == type).firstOrNull?['data'] as Map? ?? const {'available': false, 'reason': '서버 자료 없음'});

  static bool _ok(Map<String, dynamic> d) => d['available'] != false;
  static String _n(Object? v, [int f = 1]) => v is num ? v.toStringAsFixed(f) : '-';

  @override
  Widget build(BuildContext c) {
    final rain = _w('rain'), wind = _w('wind'), wave = _w('wave'), water = _w('water_level');
    final life = _w('life_safety'), fc = _w('forecast');
    return Column(children: [
      _ok(rain)
          ? _liveRainfall(rain, simulated: simulated)
          : _metric(Icons.water_drop_outlined, '강수', '자료 없음', '${rain['reason']}', '구룡포 AWS', Colors.indigo,
              badge: '자료 없음', suffix: ''),
      _ok(wind)
          ? _metric(Icons.navigation, '바람', '평균 ${_n(wind['value'])} · 순간 ${_n(wind['wind_gust'])}m/s',
              '${_windFromKo(wind['wind_dir'])} · 화살표는 바람이 불어가는 방향', '${wind['station_name']} · ${_hhmm('${wind['observed_at']}')}',
              Colors.deepOrange,
              rotation: wind['wind_dir'] is num ? ((wind['wind_dir'] as num) + 180) * math.pi / 180 : 0, badge: _obs, suffix: simulated ? ' · 시연값' : ' · 기상청 관측')
          : _metric(Icons.navigation, '바람', '자료 없음', '${wind['reason']}', '구룡포 AWS', Colors.deepOrange, badge: '자료 없음', suffix: ''),
      _ok(wave)
          ? _metric(
              Icons.waves,
              '파고',
              '예보 ${_n(wave['value'])}m',
              '앞으로 24시간 최대 ${_n([for (final p in wave['series'] as List? ?? const []) ((p as Map)['v'] as num?)?.toDouble() ?? 0].fold<double>(0, math.max))}m · 실측 파고는 수집하지 않음',
              '구룡포항 앞바다 · ${_hhmm('${wave['observed_at']}')}부터',
              Colors.blue,
              badge: '예보',
              suffix: simulated ? ' · 시연 예보' : ' · 기상청 단기예보')
          : _metric(Icons.waves, '파고', '자료 없음', '${wave['reason']}', '구룡포항 앞바다', Colors.blue, badge: '자료 없음', suffix: ''),
      _liveWater(water),
      if (_ok(fc)) _liveForecast(fc),
      if (_ok(life))
        for (final i in life['items'] as List? ?? const [])
          _metric(
              Icons.wb_sunny_outlined,
              '${(i as Map)['label']}',
              '${_n(i['value'], 0)}${i['unit'] ?? ''}',
              '판정 ${const {'watch': '관심', 'advisory': '주의', 'warning': '경보', 'critical': '위험'}[i['level']] ?? '정상'}',
              '${i['station_name']} · ${_hhmm('${i['observed_at']}')}',
              Colors.amber.shade800,
              badge: _obs,
              suffix: ''),
    ]);
  }

  Widget _liveWater(Map<String, dynamic> d) {
    if (!_ok(d)) {
      return _metric(Icons.height, '수위', '자료 없음', '${d['reason']}', '포항 디지털 트윈', Colors.teal, badge: '자료 없음', suffix: '');
    }
    final st = [for (final s in d['stations'] as List? ?? const []) Map<String, dynamic>.from(s as Map)];
    final river = st.where((s) => s['kind'] == 'river_level').firstOrNull;
    final warn = st.where((s) => const {'advisory', 'warning', 'critical'}.contains(s['level'])).toList();
    final flood = st.where((s) => s['kind'] == 'road_flood' && s['value'] is num).toList();
    final maxFlood = flood.isEmpty ? null : flood.map((s) => (s['value'] as num).toDouble()).reduce(math.max);
    return _metric(
      Icons.height,
      '수위',
      river?['value'] is num ? '하천 ${((river!['value'] as num) / 1000).toStringAsFixed(2)}m' : '센서 ${st.length}곳',
      '${warn.isEmpty ? '센서 ${st.length}곳 모두 정상' : '주의 이상 ${warn.length}곳: ${warn.map((s) => s['station_name']).join(', ')}'}'
          '${maxFlood == null ? '' : ' · 지표면 침수심 최고 ${maxFlood.toStringAsFixed(0)}mm'}',
      '포항 디지털 트윈 · ${_hhmm('${d['observed_at']}')} 수집',
      Colors.teal,
      badge: _obs,
      suffix: '',
    );
  }

  Widget _liveForecast(Map<String, dynamic> d) {
    final slots = [for (final s in d['slots'] as List? ?? const []) Map<String, dynamic>.from(s as Map)];
    if (slots.isEmpty) return const SizedBox.shrink();
    double mx(String k) => slots.map((s) => (s[k] as num?)?.toDouble() ?? 0).reduce(math.max);
    final rainSum = slots.map((s) => (s['pcp_mm'] as num?)?.toDouble() ?? 0).fold<double>(0, (a, b) => a + b);
    final temps = slots.map((s) => (s['tmp'] as num?)?.toDouble()).whereType<double>().toList();
    return _metric(
      Icons.wb_cloudy_outlined,
      '예보 (12시간)',
      '강수확률 최고 ${mx('pop').round()}%',
      '예상 강수 ${rainSum.toStringAsFixed(1)}mm · 최고 풍속 ${mx('wsd').toStringAsFixed(1)}m/s'
          '${temps.isEmpty ? '' : ' · ${temps.reduce(math.min).round()}~${temps.reduce(math.max).round()}℃'}',
      '구룡포읍 · ${_hhmm('${slots.first['t']}')}부터',
      Colors.blueGrey,
      badge: '예보',
      suffix: simulated ? ' · 시연 예보' : ' · 기상청 단기예보',
    );
  }
}

/// 김다인 _rainfallMetric 디자인 + 실측: 1시간 강수·오늘 누적·최근 6시간 시간별 막대
Widget _liveRainfall(Map<String, dynamic> d, {bool simulated = false}) {
  const color = Colors.indigo;
  final now = (d['value'] as num?)?.toDouble() ?? 0;
  // 10분 간격 '1시간 강수' 값에서 시각별 마지막 값 → 최근 6시간 막대
  final byHour = <int, (String, double)>{};
  for (final p in d['series'] as List? ?? const []) {
    final t = DateTime.tryParse('${(p as Map)['t']}')?.toLocal();
    if (t == null) continue;
    byHour[t.year * 1000000 + t.month * 10000 + t.day * 100 + t.hour] = ('${t.hour}시', (p['v'] as num?)?.toDouble() ?? 0);
  }
  final hourly = (byHour.keys.toList()..sort()).map((k) => byHour[k]!).toList();
  final bars = hourly.length > 6 ? hourly.sublist(hourly.length - 6) : hourly;
  final top = bars.isEmpty ? 0.0 : bars.map((e) => e.$2).reduce(math.max);
  final label = now <= 0 ? '비 없음' : now < 3 ? '약한 비' : now < 15 ? '보통 비' : now < 30 ? '강한 비' : '매우 강한 비';
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.water_drop_outlined, color: color),
          const SizedBox(width: 8),
          const Expanded(child: Text('강수', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          _badge(simulated ? '시연' : '실측'),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          RichText(
            text: TextSpan(style: const TextStyle(color: Colors.black87), children: [
              TextSpan(text: now.toStringAsFixed(1), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              const TextSpan(text: ' mm/h', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(20)),
            child: Text(label, style: const TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          Text('오늘 누적 ${((d['rain_day'] as num?) ?? 0).toStringAsFixed(1)} mm',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 12),
        const Text('최근 6시간 시간당 강수량', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SizedBox(
          height: 78,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < bars.length; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text(bars[i].$2.toStringAsFixed(bars[i].$2 < 10 ? 1 : 0),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: i == bars.length - 1 ? FontWeight.bold : FontWeight.normal,
                            color: i == bars.length - 1 ? color : Colors.black54)),
                    const SizedBox(height: 3),
                    Container(
                      height: top <= 0 ? 2 : math.max(2, 38 * bars[i].$2 / top),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: i == bars.length - 1 ? .92 : .30 + .08 * i),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(bars[i].$1, style: const TextStyle(fontSize: 10, color: Colors.black54)),
                  ]),
                ),
              ),
          ]),
        ),
        const Divider(height: 18),
        Text('${d['station_name']} · ${_hhmm('${d['observed_at']}')} · ${simulated ? '시연값' : '기상청 관측'}',
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ]),
    ),
  );
}

String _windFromKo(Object? deg) {
  const dirs = ['북', '북북동', '북동', '동북동', '동', '동남동', '남동', '남남동', '남', '남남서', '남서', '서남서', '서', '서북서', '북서', '북북서'];
  return deg is num ? '${dirs[((deg % 360) / 22.5).round() % 16]}풍' : '풍향 미확인';
}


Widget _metric(
  IconData icon,
  String title,
  String value,
  String description,
  String locationTime,
  Color color, {
  double rotation = 0,
  String badge = '예시',
  String suffix = ' · 가상 시연 자료',
}) =>
    Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(15)),
              child: Center(
                  child: Transform.rotate(
                      angle: rotation,
                      child: Icon(icon, color: color, size: 31)))),
          const SizedBox(width: 13),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const Spacer(),
                  _badge(badge),
                ]),
                Text(value,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                Text(description, style: const TextStyle(fontSize: 13)),
                Text('$locationTime$suffix',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.black54)),
              ])),
        ]),
      ),
    );

class TyphoonScreen extends StatefulWidget {
  const TyphoonScreen({super.key, this.initialLocal = false, this.demo = true, this.live});
  final bool initialLocal;
  /// false = 실측: [live] (서버 /dashboard typhoon 위젯 data)로 그린다. 진행 중인 태풍이 없으면 available=false (2026-10-05)
  final bool demo;
  final Map<String, dynamic>? live;
  @override
  State<TyphoonScreen> createState() => _TyphoonScreenState();
}

class _TyphoonScreenState extends State<TyphoonScreen> {
  static const localMapCenter = LatLng(35.62, 129.68);
  late bool local;
  final MapController mapController = MapController();
  late final MapOptions mapOptions;
  @override
  void initState() {
    super.initState();
    local = widget.initialLocal;
    mapOptions = MapOptions(
      initialCenter: widget.demo
          ? (local ? localMapCenter : const LatLng(35.0, 130.0))
          : (local ? _localCenter : _overallCenter),
      initialZoom: local ? 7.2 : (widget.demo ? 5.1 : 4.6),
    );
  }

  // ---- 실측 태풍 (live) ----
  bool get _hasLive => !widget.demo && widget.live != null && widget.live!['available'] != false;
  List<Map<String, dynamic>> get _liveTrack =>
      [for (final p in widget.live?['track'] as List? ?? const []) Map<String, dynamic>.from(p as Map)];
  Map<String, dynamic> get _cur => Map<String, dynamic>.from(widget.live?['current'] as Map? ?? const {});
  LatLng _ll(Map p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble());
  List<LatLng> get _past => [for (final p in _liveTrack.where((p) => p['is_forecast'] != true)) _ll(p)];
  List<LatLng> get _future => [for (final p in _liveTrack.where((p) => p['is_forecast'] == true)) _ll(p)];
  LatLng get _livePos => _cur['lat'] is num ? _ll(_cur) : (_past.isNotEmpty ? _past.last : const LatLng(35.0, 130.0));
  LatLng get _overallCenter {
    final pts = [..._past, ..._future, guryongpo];
    if (pts.length < 2) return const LatLng(35.0, 130.0);
    final b = LatLngBounds.fromPoints(pts);
    return b.center;
  }
  LatLng get _localCenter => _hasLive
      ? LatLng((guryongpo.latitude * 2 + _livePos.latitude) / 3, (guryongpo.longitude * 2 + _livePos.longitude) / 3)
      : localMapCenter;
  static const _dirKo = {
    'N': '북', 'NNE': '북북동', 'NE': '북동', 'ENE': '동북동', 'E': '동', 'ESE': '동남동', 'SE': '남동', 'SSE': '남남동',
    'S': '남', 'SSW': '남남서', 'SW': '남서', 'WSW': '서남서', 'W': '서', 'WNW': '서북서', 'NW': '북서', 'NNW': '북북서',
  };
  static String _t(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    return t == null ? '-' : '${t.month}/${t.day} ${t.hour}시';
  }

  static const track = <LatLng>[
    LatLng(32.9, 130.4),
    LatLng(33.8, 130.1),
    LatLng(34.7, 129.9),
    LatLng(35.25, 129.8),
    LatLng(35.65, 129.72),
    LatLng(36.1, 129.65),
    LatLng(36.55, 129.58),
    LatLng(36.95, 129.5),
  ];
  static const times = <String>[
    '10:00',
    '11:00',
    '12:00',
    '14:00 현재',
    '16:00 예측',
    '18:00 예측',
    '20:00 예측',
    '22:00 예측',
  ];
  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '태풍 정보',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        if (widget.demo) const _DemoBanner(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.cyclone, color: Colors.deepOrange, size: 26),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      local
                          ? '구룡포 태풍 영향 요약'
                          : widget.demo
                              ? '태풍 시연 현황'
                              : _hasLive
                                  ? '태풍 ${widget.live!['name_ko'] ?? widget.live!['code']} 현황'
                                  : '태풍 현황',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.deepOrange.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(widget.demo ? '가상 시나리오' : '기상청 실측',
                        style: const TextStyle(
                            color: Colors.deepOrange,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                ]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.demo
                      ? [
                          _typhoonStat(
                              Icons.air, '최대 풍속', '35 m/s', Colors.deepOrange),
                          _typhoonStat(
                              Icons.speed, '이동 속도', '25 km/h', Colors.indigo),
                          _typhoonStat(Icons.radar, '영향 반경', '150 km', Colors.orange),
                        ]
                      : _hasLive
                          ? [
                              _typhoonStat(Icons.air, '최대 풍속',
                                  _cur['max_wind_ms'] is num ? '${(_cur['max_wind_ms'] as num).round()} m/s' : '-', Colors.deepOrange),
                              _typhoonStat(Icons.speed, '이동 속도',
                                  _cur['speed_kmh'] is num ? '${(_cur['speed_kmh'] as num).round()} km/h${_cur['direction'] != null ? ' ${_dirKo['${_cur['direction']}'] ?? _cur['direction']}' : ''}' : '-',
                                  Colors.indigo),
                              _typhoonStat(Icons.radar, '강풍 반경',
                                  _cur['radius_15ms_km'] is num ? '${(_cur['radius_15ms_km'] as num).round()} km' : '-', Colors.orange),
                              _typhoonStat(Icons.social_distance, '구룡포까지', '${widget.live!['distance_km']} km', Colors.teal),
                            ]
                          : [],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: .09),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.deepOrange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        !widget.demo
                            ? (!_hasLive
                                ? '${widget.live?['reason'] ?? '현재 진행 중인 태풍이 없습니다'} · 기상청 태풍 정보 기준'
                                : (_cur['radius_15ms_km'] is num && (widget.live!['distance_km'] as num) <= (_cur['radius_15ms_km'] as num))
                                    ? '구룡포가 강풍 반경 안에 있습니다 · ${_t(_cur['t'])} 분석'
                                    : '구룡포에서 ${widget.live!['distance_km']}km · 예상 최근접 ${widget.live!['closest_km']}km (${_t(widget.live!['eta_closest'])}) · ${_t(_cur['t'])} 분석')
                            : local
                                ? '구룡포가 가상 강풍 영향 반경 안에 있습니다 · 기준 시각 14:00'
                                : '구룡포 예상 영향과 태풍 경로를 지도에서 확인하세요 · 기준 시각 14:00',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('태풍 전체')),
            ButtonSegment(value: true, label: Text('구룡포 영향 보기')),
          ],
          selected: {local},
          onSelectionChanged: (v) {
            final next = v.first;
            setState(() => local = next);
            mapController.move(
              widget.demo
                  ? (next ? localMapCenter : const LatLng(35.0, 130.0))
                  : (next ? _localCenter : _overallCenter),
              next ? 7.2 : (widget.demo ? 5.1 : 4.6),
            );
          },
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 460,
          child: FlutterMap(
            mapController: mapController,
            options: mapOptions,
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'guryongpo.safety.demo',
              ),
              if (!widget.demo) ...[
                if (_hasLive && _cur['radius_15ms_km'] is num)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: _livePos,
                      radius: (_cur['radius_15ms_km'] as num).toDouble() * 1000,
                      useRadiusInMeter: true,
                      color: Colors.orange.withValues(alpha: .15),
                      borderColor: Colors.deepOrange,
                      borderStrokeWidth: 2,
                    ),
                  ]),
                if (_hasLive)
                  PolylineLayer(polylines: [
                    if (_past.length > 1) Polyline(points: _past, color: Colors.indigo, strokeWidth: 4),
                    if (_future.isNotEmpty) ..._dashed([if (_past.isNotEmpty) _past.last, ..._future]),
                  ]),
                MarkerLayer(markers: [
                  for (final p in _liveTrack)
                    Marker(
                      point: _ll(p),
                      width: 70,
                      height: 50,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                          p['is_forecast'] == true
                              ? Icons.trip_origin
                              : (_ll(p) == _livePos ? Icons.cyclone : Icons.place),
                          color: _ll(p) == _livePos ? Colors.red : Colors.indigo,
                          size: 22,
                        ),
                        Text('${_t(p['t'])}${p['is_forecast'] == true ? ' 예측' : _ll(p) == _livePos ? ' 현재' : ''}',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  Marker(
                    point: guryongpo,
                    width: 60,
                    height: 48,
                    child: const Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.home, color: Colors.teal),
                      Text('구룡포', style: TextStyle(fontSize: 9)),
                    ]),
                  ),
                ]),
              ] else ...[
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: track[3],
                    radius: 150000,
                    useRadiusInMeter: true,
                    color: Colors.orange.withValues(alpha: .15),
                    borderColor: Colors.deepOrange,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: track.take(4).toList(),
                    color: Colors.indigo,
                    strokeWidth: 4,
                  ),
                  ..._dashed(track.skip(3).toList()),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (var i = 0; i < track.length; i++)
                    Marker(
                      point: track[i],
                      width: 65,
                      height: 50,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            i < 3
                                ? Icons.place
                                : i == 3
                                    ? Icons.cyclone
                                    : Icons.trip_origin,
                            color: i == 3 ? Colors.red : Colors.indigo,
                            size: 22,
                          ),
                          Text(times[i],
                              style: const TextStyle(
                                  fontSize: 10, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  Marker(
                    point: guryongpo,
                    width: 60,
                    height: 48,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.home, color: Colors.teal),
                        Text('구룡포', style: TextStyle(fontSize: 9)),
                      ],
                    ),
                  ),
                ],
              ),
              ],
            ],
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('경로와 지도 읽기',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                  '${local ? '구룡포와 현재 태풍 위치의 관계를 확대해 표시합니다.' : '태풍의 전체 이동 흐름을 표시합니다.'}\n실선은 지나온 경로, 점선은 예측 경로, 주황색 원은 강풍 영향 반경입니다.',
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.demo
                      ? '태풍 이름·경로·풍속·반경·시각은 모두 시연용 가상값이며 기상청 발표 정보가 아닙니다.'
                      : '출처: ${widget.live?['source'] ?? '기상청 태풍 정보'}. 주황색 원은 초속 15m 이상 강풍 반경입니다.',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                if (!widget.demo)
                  TextButton.icon(
                    onPressed: () => launchUrl(Uri.parse('https://www.weather.go.kr/w/typhoon/report.do')),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('기상청 태풍 정보 열기'),
                  ),
              ],
            ),
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: () => c.go('/'),
          icon: const Icon(Icons.map),
          label: const Text('대시보드 강풍·종합 보기로 이동'),
        ),
      ],
    );
  }
}

Widget _typhoonStat(IconData icon, String label, String value, Color color) =>
    Container(
      constraints: const BoxConstraints(minWidth: 112),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .22)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 7),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          Text(value,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ]),
      ]),
    );

List<Polyline> _dashed(List<LatLng> pts) {
  final out = <Polyline>[];
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    for (var j = 0; j < 8; j++) {
      if (j.isOdd) continue;
      LatLng at(double t) => LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          );
      out.add(
        Polyline(
          points: [at(j / 8), at((j + 1) / 8)],
          color: Colors.indigo,
          strokeWidth: 4,
        ),
      );
    }
  }
  return out;
}

class _WeatherBulletins extends StatelessWidget {
  const _WeatherBulletins({this.warnings, this.forecast});
  /// 실측: 서버 warnings·forecast 위젯 data. 둘 다 null = 시연(가상 특보·예보)
  final Map<String, dynamic>? warnings, forecast;

  Widget _live(BuildContext context) {
    final items = [for (final w in warnings?['items'] as List? ?? const []) Map<String, dynamic>.from(w as Map)];
    final slots = [for (final x in forecast?['slots'] as List? ?? const []) Map<String, dynamic>.from(x as Map)];
    double mx(String k) => slots.isEmpty ? 0 : slots.map((x) => (x[k] as num?)?.toDouble() ?? 0).reduce(math.max);
    final rain = slots.fold<double>(0, (a, x) => a + ((x['pcp_mm'] as num?)?.toDouble() ?? 0));
    final types = {for (final x in slots) if (x['pty'] != null && x['pty'] != '없음') '${x['pty']}'};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 10),
      const Text('기상 특보', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      if (warnings?['available'] == false)
        Card(child: ListTile(leading: const Icon(Icons.info_outline), title: Text('자료 없음 · ${warnings?['reason']}')))
      else if (items.isEmpty)
        const Card(
            child: ListTile(
                leading: Icon(Icons.verified_outlined, color: Colors.green),
                title: Text('발효 중인 기상특보가 없습니다'),
                subtitle: Text('대상: 포항시·경북남부앞바다 · 기상청 특보 기준')))
      else
        for (final w in items)
          Card(
            child: ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: Colors.deepOrange),
              title: Text('${w['label']}'),
              subtitle: Text('대상: ${w['region_name']}\n발표: ${_hhmm('${w['issued_at']}')} · 기상청'),
              isThreeLine: true,
            ),
          ),
      const Text('기상 예보', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      Card(
        child: ListTile(
          leading: const Icon(Icons.cloudy_snowing, color: Colors.indigo),
          title: Text(slots.isEmpty
              ? '자료 없음 · ${forecast?['reason'] ?? '기상청 단기예보 자료가 없습니다'}'
              : types.isEmpty
                  ? '앞으로 12시간 비 소식 없음'
                  : '앞으로 12시간 ${types.join('·')} 예보'),
          subtitle: slots.isEmpty
              ? null
              : Text('대상: 포항시 남구 구룡포읍\n${_hhmm('${slots.first['t']}')}부터 12시간 · 강수확률 최고 ${mx('pop').round()}% · 예상 강수 ${rain.toStringAsFixed(1)}mm · 최고 풍속 ${mx('wsd').toStringAsFixed(1)}m/s'),
          isThreeLine: slots.isNotEmpty,
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(left: 8, bottom: 8),
        child: Text('출처: 기상청 특보·단기예보 (실측)', style: TextStyle(fontSize: 11)),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => warnings != null || forecast != null ? _live(context) : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          const Text('기상 특보',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          Card(
            child: ListTile(
              leading: const Icon(Icons.warning_amber_rounded,
                  color: Colors.deepOrange),
              title: const Text('호우주의보 · 예시 데이터'),
              subtitle: const Text(
                '대상: 포항시 남구 구룡포읍\n발표: 오늘 13:00 (가상) · 유효: 오늘 18:00까지 (가상)\n기준 안내: 3시간 60mm 또는 12시간 110mm 이상 예상',
              ),
              isThreeLine: true,
            ),
          ),
          const Text('기상 예보',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloudy_snowing, color: Colors.indigo),
              title: const Text('강한 비 가능성 · 예시 데이터'),
              subtitle: const Text(
                '대상: 포항시 남구 구룡포읍\n예보 작성: 오늘 12:00 (가상) · 유효: 오늘 14:00~18:00 (가상)\n예보 내용: 시간당 20~30mm 비가 내리는 상황을 가정',
              ),
              isThreeLine: true,
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 8, bottom: 8),
            child: Text('출처: 기상청 기준을 참고한 화면 검토용 목업. 실제 발표 정보가 아닙니다.',
                style: TextStyle(fontSize: 11)),
          ),
        ],
      );
}

class AlertHubScreen extends StatefulWidget {
  const AlertHubScreen({
    super.key,
    this.demo = true,
    this.dashboard,
    this.alerts = const [],
    this.areas = const [],
  });
  /// false = 실측: 서버 대시보드(특보·예보·재난문자·장소 위험), 내 경고(A5), 현재 위험 영역으로 채운다 (2026-10-05)
  final bool demo;
  final Map<String, dynamic>? dashboard;
  final List<AlertItem> alerts;
  final List<RiskArea> areas;
  @override
  State<AlertHubScreen> createState() => _AlertHubScreenState();
}

class _AlertHubScreenState extends State<AlertHubScreen> {
  Map<String, String> profile = {};
  @override
  void initState() {
    super.initState();
    AccountService().optionalProfile().then((v) {
      if (mounted) setState(() => profile = v);
    });
  }

  Map<String, dynamic>? _widget(String type) {
    final w = (widget.dashboard?['widgets'] as List? ?? const [])
        .cast<Map>()
        .where((w) => w['type'] == type)
        .firstOrNull;
    return w == null ? null : Map<String, dynamic>.from(w['data'] as Map);
  }

  Widget _liveBuild(BuildContext c) {
    final places = [
      for (final p in widget.dashboard?['places'] as List? ?? const [])
        if (((p as Map)['max_level_num'] as num? ?? 0) >= 2) Map<String, dynamic>.from(p)
    ];
    final msgs = _widget('disaster_messages');
    const lv = {'watch': '관심', 'advisory': '주의', 'warning': '경보', 'critical': '위험'};
    const hz = {'flood': '침수', 'landslide': '산사태', 'heavy_rain': '호우', 'strong_wind': '강풍', 'typhoon': '태풍', 'high_seas': '풍랑'};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('선제 경고·알림', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('사용자 맞춤형 선제 경고', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        _WeatherBulletins(warnings: _widget('warnings') ?? const {}, forecast: _widget('forecast') ?? const {}),
        if (widget.alerts.isEmpty && places.isEmpty)
          const Card(
            child: ListTile(
                leading: Icon(Icons.verified_outlined, color: Colors.green),
                title: Text('지금 받은 맞춤 경고가 없습니다'),
                subtitle: Text('현재 위치·등록한 집·직장 주변에 위험이 생기면 여기와 알림으로 알려 드립니다.')),
          ),
        ...widget.alerts.map((a) => Card(
              child: ExpansionTile(
                leading: const Icon(Icons.personal_injury, color: Colors.deepOrange),
                title: Text(a.title),
                subtitle: Text('${a.level} · ${a.time}${a.read ? '' : ' · 새 경고'} · 눌러 상세 정보 보기'),
                children: [
                  ListTile(title: const Text('경고 이유'), subtitle: Text(a.summary)),
                  ListTile(title: const Text('권고 행동'), subtitle: Text(a.guide)),
                  if (a.responseRequired)
                    ListTile(title: const Text('대피 확인'), subtitle: Text(a.myStatus == null ? '아직 응답하지 않았습니다' : '응답: ${a.myStatus}')),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => c.go('/alert/${Uri.encodeComponent(a.id)}'),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(a.responseRequired ? '상세·대피 확인' : '상세 보기'),
                    ),
                  ),
                ],
              ),
            )),
        ...places.map((p) => Card(
              child: ExpansionTile(
                leading: const Icon(Icons.home_work_outlined, color: Colors.deepOrange),
                title: Text('${p['label']} 주변 위험 · ${lv[p['max_level']] ?? p['max_level']}'),
                subtitle: const Text('등록 장소 · 서버 위험 판정'),
                children: [
                  const ListTile(title: Text('권고 행동'), subtitle: Text('지도에서 위험 구역을 확인하고 그 장소로 이동하지 마세요.')),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                        onPressed: () => c.go('/'), icon: const Icon(Icons.map_outlined), label: const Text('종합 지도 열기')),
                  ),
                ],
              ),
            )),
        const SizedBox(height: 10),
        const Text('일반 알림 · 재난문자', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        if (msgs == null || msgs['available'] == false)
          Card(child: ListTile(leading: const Icon(Icons.sms_outlined), title: Text('자료 없음 · ${msgs?['reason'] ?? '재난문자 자료가 없습니다'}')))
        else if ((msgs['items'] as List? ?? const []).isEmpty)
          const Card(child: ListTile(leading: Icon(Icons.sms_outlined), title: Text('최근 24시간 재난문자가 없습니다')))
        else
          for (final m in msgs['items'] as List)
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.sms),
                title: Text('${(m as Map)['sender'] ?? '재난문자'} · ${m['alert_class'] ?? ''}'),
                subtitle: Text('발송 ${_hhmm('${m['sent_at']}')}'),
                children: [Padding(padding: const EdgeInsets.all(14), child: Text('${m['message']}'))],
              ),
            ),
        const SizedBox(height: 8),
        const Text('위험 지역 경고', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        if (widget.areas.isEmpty)
          const Card(
              child: ListTile(
                  leading: Icon(Icons.verified_outlined, color: Colors.green),
                  title: Text('현재 구룡포에 주의 이상 위험 지역이 없습니다'),
                  subtitle: Text('침수·산사태 판정 결과 · 10분마다 갱신'))),
        for (final a in widget.areas)
          Card(
            child: ExpansionTile(
              leading: Icon(Icons.warning, color: _riskColor(a.level)),
              title: Text(a.label.isEmpty ? '${hz[a.hazard] ?? a.hazard} 위험 지역' : a.label),
              subtitle: Text('${hz[a.hazard] ?? a.hazard} · ${a.level} · 서버 위험 판정'),
              children: [
                ListTile(
                  title: const Text('위험 원인·행동 안내'),
                  subtitle: const Text('이 구역에 들어가지 말고, 안에 있다면 가까운 안전한 대피소로 이동하세요.'),
                  trailing: IconButton(icon: const Icon(Icons.map), onPressed: () => c.go('/')),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext c) {
    if (!widget.demo) return _liveBuild(c);
    final jobs =
        (profile['jobs'] ?? '').split('|').where((e) => e.isNotEmpty).toList();
    final homeName =
        (profile['homeName'] ?? '').trim().isEmpty ? '집' : profile['homeName']!;
    final workName = (profile['workName'] ?? '').trim().isEmpty
        ? '직장'
        : profile['workName']!;
    final personal = <(String, String, String, String, String)>[];
    if ((profile['homeAddress'] ?? '').isNotEmpty)
      personal.add((
        '$homeName 주변 침수 위험',
        '등록한 $homeName 주변 저지대 침수 가능성을 가정한 목업 경고입니다.',
        profile['homeAddress']!,
        '오늘 14:00 (가상)',
        '사용자 등록 주소 · 침수 경고 목업',
      ));
    if ((profile['workAddress'] ?? '').isNotEmpty)
      personal.add((
        '$workName 주변 침수 위험',
        '등록한 $workName 주변 저지대 침수 가능성을 가정한 목업 경고입니다.',
        profile['workAddress']!,
        '오늘 14:00 (가상)',
        '사용자 등록 주소 · 침수 경고 목업',
      ));
    if (jobs.isNotEmpty)
      for (final j in jobs) {
        personal.add((
          '직업 맞춤 기상 대비',
          switch (j) {
            '어업 종사자·뱃사람' =>
              '강한 바람과 높은 파도 가능성을 가정했습니다. 조업을 자제하고 출항 전 통제를 확인하세요.',
            '자영업자' => '매장 인근 집중호우 가능성을 가정했습니다. 배수구와 전기기기를 점검하세요.',
            '농업 종사자' => '농경지 주변 비와 강풍 가능성을 가정했습니다. 배수로와 시설물을 점검하세요.',
            '축산업 종사자' => '축사 주변 집중호우 가능성을 가정했습니다. 배수시설과 비상전원을 확인하세요.',
            '양식업 종사자·수산물 양식' => '높은 파도 가능성을 가정했습니다. 시설을 점검하고 해상 작업을 자제하세요.',
            _ => '등록 작업장 주변 기상 위험 확인을 위한 목업 경고입니다.',
          },
          profile['workAddress'] ?? '구룡포읍 (장소 미등록)',
          '오늘 14:00 (가상)',
          '사용자 직업 정보 · 맞춤 경고 목업',
        ));
      }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '선제 경고·알림',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const _DemoBanner(),
        const Text(
          '사용자 맞춤형 선제 경고',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        const _WeatherBulletins(),
        if (personal.isEmpty)
          const Card(
            child: ListTile(title: Text('맞춤 경고를 보려면 프로필에 집·직장·직업을 등록하세요.')),
          ),
        ...personal.map((warning) => Card(
              child: ExpansionTile(
                leading:
                    const Icon(Icons.personal_injury, color: Colors.deepOrange),
                title: Text(warning.$1),
                subtitle: const Text('목업 경고 · 눌러 상세 정보 보기'),
                children: [
                  ListTile(
                      title: const Text('경고 이유'), subtitle: Text(warning.$2)),
                  ListTile(
                      title: const Text('영향 위치'), subtitle: Text(warning.$3)),
                  ListTile(
                      title: const Text('영향 시각'), subtitle: Text(warning.$4)),
                  ListTile(title: const Text('출처'), subtitle: Text(warning.$5)),
                  const ListTile(
                    title: Text('권고 행동'),
                    subtitle: Text('기상 특보와 주변 상황을 확인하고 위험 구역 접근을 피하세요.'),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => context.go('/'),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('종합 지도 열기'),
                    ),
                  ),
                ],
              ),
            )),
        const SizedBox(height: 10),
        const Text(
          '일반 알림 · 재난문자',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        const _VirtualMessage(),
        const SizedBox(height: 8),
        const Text(
          '위험 지역 경고',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.warning, color: Colors.red),
            title: const Text('구룡포 해안가 강풍·높은 파도(가상)'),
            subtitle: const Text('대상 구룡포 해안 · 유효 시각 14:00 · 해변·방파제 방문 자제'),
            children: [
              ListTile(
                title: const Text('위험 원인·행동 안내'),
                subtitle: const Text('시연용 강풍·파고 가상 시나리오. 실제 상황은 공식 안내를 확인하세요.'),
                trailing: IconButton(
                  icon: const Icon(Icons.map),
                  onPressed: () => Navigator.of(c).pushNamed('/'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VirtualMessage extends StatefulWidget {
  const _VirtualMessage();
  @override
  State<_VirtualMessage> createState() => _VirtualMessageState();
}

class _VirtualMessageState extends State<_VirtualMessage> {
  bool open = false;
  @override
  Widget build(BuildContext c) => Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.sms),
              title: const Text('가상 재난문자 · 구룡포 해안 강풍주의 시연'),
              subtitle: const Text('발송 14:00 · 시연 시스템(가상) · 방파제 접근 자제'),
              trailing: TextButton(
                onPressed: () => setState(() => open = !open),
                child: Text(open ? '접기' : '원문 보기'),
              ),
            ),
            if (open)
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  '[가상 재난문자 원문] 구룡포 해안 시연구역에 강풍과 높은 파도가 예상되는 상황을 가정했습니다. 해안과 방파제 접근을 자제하고 실제 재난 상황에서는 공식 안내를 확인하세요.',
                ),
              ),
          ],
        ),
      );
}

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  Set<String> jobs = {};
  @override
  void initState() {
    super.initState();
    AccountService().optionalProfile().then((profile) {
      if (!mounted) return;
      final saved =
          (profile['jobs'] ?? '').split('|').where((x) => x.isNotEmpty).toSet();
      if (saved.isEmpty && (profile['직업'] ?? '').isNotEmpty)
        saved.add(profile['직업']!);
      setState(() => jobs = saved);
    });
  }

  @override
  Widget build(BuildContext c) {
    const jobGuides = <String, (IconData, String, String)>{
      '농업 종사자': (
        Icons.agriculture,
        '농업 지원·복구',
        '농작물·농업시설 피해를 기록하고 배수로와 시설 안전을 먼저 확인하세요. 실제 지원 대상과 보험 약관은 관할 기관에 문의하세요.'
      ),
      '축산업 종사자': (
        Icons.pets,
        '축산업 지원·복구',
        '축사·가축 피해와 복구 비용을 기록하고 배수시설과 비상전원을 점검하세요. 실제 지원 대상은 관할 기관에 확인하세요.'
      ),
      '어업 종사자·뱃사람': (
        Icons.sailing,
        '어업 지원·복구',
        '어선·어구 피해와 발생 시각을 기록하고 항만 통제와 출항 제한을 확인하세요. 실제 지원 대상은 관할 기관에 문의하세요.'
      ),
      '양식업 종사자·수산물 양식': (
        Icons.waves,
        '양식업 지원·복구',
        '양식시설과 수산생물 피해를 기록하고 전력·산소공급·취수시설 상태를 확인하세요. 실제 지원 대상은 관할 기관에 확인하세요.'
      ),
      '자영업자': (
        Icons.store,
        '사업장 지원·복구',
        '매장 침수와 시설 피해를 촬영·기록하고 전기와 가스를 안전하게 차단하세요. 실제 지원 대상은 관할 기관에 확인하세요.'
      ),
      '기타': (
        Icons.handyman_outlined,
        '일반 피해 신고·복구',
        '피해 사진과 발생 시각을 기록하고 관할 지자체 재난 담당 창구에 복구 절차를 문의하세요.'
      ),
      'farmer': (
        Icons.agriculture,
        '농업 지원·복구',
        '농작물·농업시설 피해를 기록하고 관할 기관에 실제 지원 요건을 확인하세요.'
      ),
      'livestock': (
        Icons.pets,
        '축산업 지원·복구',
        '축사·가축 피해를 기록하고 관할 기관에 실제 지원 요건을 확인하세요.'
      ),
      'fisher': (
        Icons.sailing,
        '어업 지원·복구',
        '어선·어구 피해를 기록하고 관할 기관에 실제 지원 요건을 확인하세요.'
      ),
      'aquaculture': (
        Icons.waves,
        '양식업 지원·복구',
        '양식시설 피해를 기록하고 관할 기관에 실제 지원 요건을 확인하세요.'
      ),
    };
    final selected = jobs
        .map((j) => jobGuides[j])
        .whereType<(IconData, String, String)>()
        .toSet()
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '지원 및 복구',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const _DemoBanner(),
        const Text(
          '목업 안내입니다. 실제 제도·자격·지원 금액은 관할 기관에 확인하세요.',
        ),
        if (jobs.isEmpty)
          Card(
              child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('직업 분야가 설정되지 않았습니다.'),
                  subtitle:
                      const Text('프로필에서 직업을 선택하면 해당 분야의 지원·복구 안내만 표시합니다.'),
                  trailing: TextButton(
                      onPressed: () => GoRouter.of(c).push('/profile'),
                      child: const Text('프로필')))),
        if (selected.isNotEmpty) ...[
          const Text('내 직업 분야 안내',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          for (final x in selected)
            Card(
              child: ExpansionTile(
                leading: Icon(x.$1),
                title: Text(x.$2),
                subtitle: const Text('목업 안내 · 실제 지원 요건 확인 필요'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                        '${x.$3}\n신청·문의: 관할 지자체 또는 가입 보험사에 자격과 서류를 확인하세요.'),
                  ),
                ],
              ),
            ),
        ],
        Card(
            child: ExpansionTile(
                leading: const Icon(Icons.report_outlined),
                title: const Text('공통 피해 신고·복구'),
                subtitle: const Text('분야와 관계없이 확인할 수 있는 기본 절차'),
                children: const [
              Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      '피해 사진과 발생 시각을 기록하고, 안전을 확인한 뒤 관할 지자체 재난 담당 창구에 신고 절차를 문의하세요.'))
            ])),
        Card(
            child: ExpansionTile(
                leading: const Icon(Icons.policy_outlined),
                title: const Text('공통 보험 확인'),
                subtitle: const Text('보험 가입 및 보장 범위 확인'),
                children: const [
              Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      '앱은 보험금 지급 여부를 확정하지 않습니다. 가입 보험사에 계약 내용과 필요한 서류를 확인하세요.'))
            ])),
      ],
    );
  }
}

class ProfileDetailsCard extends StatefulWidget {
  const ProfileDetailsCard({super.key});
  @override
  State<ProfileDetailsCard> createState() => _ProfileDetailsCardState();
}

class _ProfileDetailsCardState extends State<ProfileDetailsCard> {
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  final jobs = <String>{};
  String transport = '도보';
  String originMode = '현재 위치';
  bool loading = true;
  static const jobOptions = [
    '어업 종사자·뱃사람',
    '자영업자',
    '농업 종사자',
    '축산업 종사자',
    '양식업 종사자·수산물 양식',
    '기타',
  ];
  @override
  void initState() {
    super.initState();
    for (final k in [
      'age',
      'homeName',
      'homeAddress',
      'homeLat',
      'homeLon',
      'workName',
      'workAddress',
      'workLat',
      'workLon',
      'originName',
      'originAddress',
      'originLat',
      'originLon',
    ]) fields[k] = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final p = await AccountService().optionalProfile();
    for (final e in fields.entries) e.value.text = p[e.key] ?? '';
    jobs.addAll((p['jobs'] ?? '').split('|').where((x) => x.isNotEmpty));
    transport = p['transport'] ?? '도보';
    originMode = p['originMode'] == '직접 지정' ? '직접 지정' : '현재 위치';
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    if (!(form.currentState?.validate() ?? false)) return;
    await _persist();
  }

  Future<void> _persist({bool notify = true}) async {
    // 다른 화면이 저장한 항목(선택 정보 '보행 능력' 등)을 지우지 않게 기존 값에 덮어쓴다 (2026-10-05)
    final p = <String, String>{
      ...await AccountService().optionalProfile(),
      for (final e in fields.entries) e.key: e.value.text.trim(),
      'transport': transport,
      'jobs': jobs.join('|'),
      'originMode': originMode,
    };
    await AccountService().saveOptionalProfile(p);
    if (mounted && notify) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('프로필을 저장했습니다. 로그인 계정에도 함께 저장됩니다.')));
      setState(() {});
    }
  }

  Future<void> _editPlace(String key, String title) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final name = TextEditingController(text: fields['${key}Name']!.text),
            addr = TextEditingController(text: fields['${key}Address']!.text);
        return AlertDialog(
          title: Text('$title 수정'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '장소명'),
                ),
                TextField(
                  controller: addr,
                  decoration: const InputDecoration(
                    labelText: '도로명 주소',
                    hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () async {
                if (addr.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('도로명 주소를 입력해 주세요.')),
                  );
                  return;
                }
                try {
                  final resolved = await GeocodingService().resolve(addr.text);
                  fields['${key}Name']!.text = name.text;
                  fields['${key}Address']!.text = resolved.address;
                  fields['${key}Lat']!.text = '${resolved.position.latitude}';
                  fields['${key}Lon']!.text = '${resolved.position.longitude}';
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) setState(() {});
                  await _persist(notify: false);
                } on GeocodingException catch (e) {
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.message)),
                    );
                }
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '사용자 상세',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const Text('도로명 주소는 서버에서 좌표로 변환합니다. 좌표는 앱에서 입력하지 않습니다.'),
                      TextFormField(
                        controller: fields['age'],
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '나이'),
                        validator: (x) =>
                            x == null || x.isEmpty || int.tryParse(x) == null
                                ? '숫자를 입력하세요'
                                : null,
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: transport,
                        decoration:
                            const InputDecoration(labelText: '기본 이동 수단'),
                        items: const ['도보', '휠체어', '자동차']
                            .map((x) =>
                                DropdownMenuItem(value: x, child: Text(x)))
                            .toList(),
                        onChanged: (x) => setState(() => transport = x ?? '도보'),
                      ),
                      const SizedBox(height: 8),
                      const Text('직업 (복수 선택)'),
                      Wrap(
                        children: [
                          for (final j in jobOptions)
                            FilterChip(
                              label: Text(j),
                              selected: jobs.contains(j),
                              onSelected: (v) => setState(
                                  () => v ? jobs.add(j) : jobs.remove(j)),
                            ),
                        ],
                      ),
                      for (final k in ['home', 'work', 'origin'])
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(switch (k) {
                            'home' => '집',
                            'work' => '직장·대표 작업장',
                            _ => '출발 위치',
                          }),
                          subtitle: Text(fields['${k}Address']!.text.isEmpty
                              ? '${fields['${k}Name']!.text} · 주소 미등록'
                              : '${fields['${k}Name']!.text} · ${fields['${k}Address']!.text}\n주소 좌표 확인 완료'),
                          trailing: IconButton(
                            tooltip:
                                '${k == 'home' ? '집' : k == 'work' ? '직장' : '출발 위치'} 수정',
                            icon: const Icon(Icons.edit),
                            onPressed: () => _editPlace(
                              k,
                              k == 'home'
                                  ? '집'
                                  : k == 'work'
                                      ? '직장'
                                      : '출발 위치',
                            ),
                          ),
                        ),
                      DropdownButtonFormField<String>(
                        initialValue: originMode,
                        decoration: const InputDecoration(
                            labelText: '출발 위치 방식',
                            helperText: '직접 지정: 위 출발 위치를 앱 시작 때 기준 위치로 씀 (화면 위 "출발" 칩으로도 바꿀 수 있음)'),
                        items: const ['현재 위치', '직접 지정']
                            .map((x) =>
                                DropdownMenuItem(value: x, child: Text(x)))
                            .toList(),
                        onChanged: (x) {
                          originMode = x ?? '현재 위치';
                          fields['originName']!.text = x == '현재 위치'
                              ? '현재 위치'
                              : fields['originName']!.text;
                        },
                      ),
                      FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: const Text('프로필 저장'),
                      ),
                    ],
                  ),
                ),
        ),
      );
}


/// 지도 범례 (2026-10-07): 지도에 그려진 색·선·아이콘이 무엇인지. 지도 오른쪽 위 '범례' 버튼으로 연다.
/// 보이는 항목만 — 경로 모드인지, 켠 재난 종류(침수·강풍·산사태)에 따라 바뀐다. 색은 지도 그리기와 같은 함수를 쓴다.
void _showMapLegend(BuildContext context,
    {required bool routeMode,
    required Set<HazardKind> visible,
    required bool hasRoute,
    required bool hasSea,
    required bool hidesTownWide}) {
  Widget fill(Color c, {Color? border}) => Container(
      width: 22,
      height: 14,
      decoration: BoxDecoration(
          color: c.withValues(alpha: .35),
          border: Border.all(color: border ?? c, width: 2)));
  Widget dot(Color c) => Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)]));
  Widget line(Color c, {bool dotted = false}) => SizedBox(
      width: 22,
      child: dotted
          ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (var i = 0; i < 4; i++)
                Container(width: 3, height: 3, color: c)
            ])
          : Container(height: 5, color: c));
  Widget icon(IconData i, Color c, {double size = 20}) =>
      SizedBox(width: 22, child: Icon(i, color: c, size: size));
  Widget row(Widget mark, String title, [String? note]) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: mark),
        const SizedBox(width: 10),
        Expanded(
            child: Text.rich(TextSpan(children: [
          TextSpan(
              text: title,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (note != null)
            TextSpan(
                text: '  $note',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ]))),
      ]));
  Widget section(String t) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Text(t,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)));

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(c).size.height * .8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            const Text('지도 범례',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (!routeMode) ...[
              section('위험 영역 (면)'),
              const Text('채움색 = 위험 단계, 테두리색 = 재난 종류',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              row(fill(_floodColor('주의')), '주의', '위험 판정 엔진의 주의 단계'),
              row(fill(_floodColor('경계')), '경보', '앱 화면에서는 "경계"로도 표시'),
              row(fill(_floodColor('심각')), '위험', '가장 높은 단계'),
              row(fill(Colors.white, border: _hazardColor(HazardKind.flood)),
                  '파란 테두리 = 침수', '수위계·맨홀 주변 반경 100~500m'),
              row(fill(Colors.white, border: _hazardColor(HazardKind.slide)),
                  '갈색 테두리 = 산사태', '호우 특보 × 산사태위험지도 비탈 100m·지정 취약지역'),
              if (hidesTownWide)
                row(icon(Icons.visibility_off_outlined, Colors.black54),
                    '호우·강풍 특보는 칠하지 않음',
                    '구룡포읍 전체에 내려져 화면을 다 덮으므로 위쪽 특보 카드로 확인'),
            ],
            if (!routeMode && visible.contains(HazardKind.flood)) ...[
              section('수위계'),
              row(
                  Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: _hazardColor(HazardKind.flood), width: 2)),
                      child: Icon(Icons.water_drop, size: 14, color: _floodColor('경계'))),
                  '물방울',
                  '침수 판정의 원인 센서(수위계·맨홀) 실제 위치 = 침수 원의 중심. 색 = 단계, 누르면 측정값'),
              section('침수 격자'),
              row(fill(_floodColor('경계')), '작은 칸',
                  '위 침수 영역을 약 100m 칸으로 나눈 것 (경로가 피하는 범위와 같음)'),
              row(dot(_floodColor('경계')), '칸 가운데 점', '칸 위치 표시일 뿐 측정 지점이 아님 — 누르면 그 칸의 단계·출처'),
            ],
            if (!routeMode && visible.contains(HazardKind.wind)) ...[
              section('바람'),
              row(icon(Icons.navigation, Colors.blueGrey.shade700), '화살표 방향',
                  '바람이 불어가는 쪽'),
              row(icon(Icons.navigation, _windColor(10, 10)), '회색', '평균 14m/s 미만'),
              row(icon(Icons.navigation, _windColor(14, 14)), '주황',
                  '평균 14m/s 이상 (강풍주의보 기준)'),
              row(icon(Icons.navigation, _windColor(21, 21)), '빨강',
                  '평균 21m/s 이상 (강풍경보 기준) · 화살표가 클수록 셈'),
            ],
            section('표식'),
            row(icon(Icons.my_location, _riskColor('경계')), '현위치',
                '색 = 지금 위치의 위험 단계 (초록 정상 → 노랑 → 주황 → 빨강)'),
            if (!routeMode)
              row(icon(Icons.home, _riskColor('정상')), '등록한 집·직장',
                  '색 = 그 장소의 위험 단계'),
            if (routeMode) ...[
              row(icon(Icons.health_and_safety, Colors.teal.shade800), '대피소'),
              row(icon(Icons.local_hospital, Colors.red.shade700), '의료시설'),
              row(
                  CircleAvatar(
                      radius: 11,
                      backgroundColor: Colors.teal.shade800,
                      child: const Text('3',
                          style: TextStyle(color: Colors.white, fontSize: 11))),
                  '숫자 원',
                  '가까운 시설 묶음 — 누르면 확대'),
            ],
            row(icon(Icons.location_on, Colors.blue.shade800), '목적지',
                '고른 대피소·시설 (병원은 십자 표시)'),
            row(icon(Icons.warning_amber_rounded, Colors.deepOrange, size: 18),
                '주황 경고 표시', '위험 영역 안에 있는 시설 — 대피소로 고르지 않음'),
            if (routeMode || hasRoute) ...[
              section('경로'),
              row(line(Colors.blue.shade800), '파란 선',
                  '안내 경로 (위험 영역을 피해 계산, 못 피하면 화면에 경고)'),
              if (hasSea)
                row(line(Colors.teal.shade700, dotted: true), '청록 점선',
                    '바다 위에서 항구까지 바닷길'),
            ],
          ],
        ),
      ),
    ),
  );
}


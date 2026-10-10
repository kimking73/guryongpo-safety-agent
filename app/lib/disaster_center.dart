import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';

import 'services/account_service.dart';
import 'services/location_service.dart';
import 'services/demo_mode.dart';
import 'models/domain_models.dart';
import 'mobile/dashboard_cards.dart' show WeatherSection, warningIcon;
import 'ui/gk_theme.dart';
import 'ui/gk_widgets.dart';
import 'ui/map_menu.dart';

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
/// 바람 화살표 색 = 침수와 같은 세 단계 색 (2026-10-10): 경보 기준 이상 심각 · 주의보 기준 이상 경계 · 그 아래 주의
Color _windColor(double averageSpeed, double gustSpeed) {
  if (averageSpeed >= 21 || gustSpeed >= 26) return _floodColor('심각');
  if (averageSpeed >= 14 || gustSpeed >= 20) return _floodColor('경계');
  return _floodColor('주의');
}

/// 산사태는 단계 없이 한 색 (산사태 취약 지역 표시, 2026-10-10)
const _slideColor = Color(0xff8d6e63);

enum _DashboardMode { emergency, facilities }

/// 재난 지도 하위 항목 (2026-10-10): 위험 재난 표시 · 침수 격자 · 강풍 · 산사태 위험 지역 + 끝에 따로 '태풍 지도 열기'.
/// 태풍은 이 지도(구룡포 일대)에 그리지 않으므로 켜고 끄는 항목이 아니다 — 누르면 태풍 화면으로 간다
const _mapKinds = [HazardKind.flood, HazardKind.wind, HazardKind.slide];

/// 지금 위치가 육지·바다인지 (경로 안내 메뉴, 2026-10-09). checking = 판별 중, unknown = 판별 못 함 → '위치 확인 필요'
enum WhereKind { checking, land, sea, unknown }

class WhereNow {
  const WhereNow(this.kind, {this.reason, this.noGps = false});
  final WhereKind kind;
  /// unknown 일 때 이유 (화면에 그대로)
  final String? reason;
  /// GPS 위치가 없어 구룡포 기본 위치(육지의 정해진 점)에서 경로를 그리는 중
  final bool noGps;
}

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
    this.travelMode = TravelMode.walk,
    this.onTravelModeChanged,
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
    this.routePlanner,
    this.onMapPick,
    this.warnings = const [],
    this.messages,
    this.messagesReason,
    this.headline,
    this.statusText,
    this.updatedText,
    this.onRefresh,
    this.extraPolygons = const [],
    this.extraMarkers = const [],
    this.extraPolylines = const [],
    this.mapOnly = false,
    this.where = const WhereNow(WhereKind.unknown),
    this.onLocate,
    this.onSeaRoute,
    this.seaRoutePanel,
    this.seaRouteLines = const [],
    this.seaRouteMarkers = const [],
    this.showFacilities = false,
    this.focusPoint,
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
  final TravelMode travelMode;
  final ValueChanged<TravelMode>? onTravelModeChanged;
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
  /// 경로 안내 한 덩어리 (출발지·이동 수단·경로 방식·목적지·시간, 2026-10-10). 있으면 예전 경로 방식 묶음·경로 머리줄 대신 쓴다
  final Widget? routePlanner;
  /// 출발 'GPS 선택' 중이면 지도를 누른 곳을 넘긴다 (2026-10-11). null이면 평소처럼 침수 칸 설명
  final ValueChanged<LatLng>? onMapPick;
  /// 디자인 = web-prototype (2026-10-08): '경보·주의보' 카드의 기상청 특보 (/dashboard warnings 위젯 items)
  final List<Map<String, dynamic>> warnings;
  /// 빨간 '최근 재난문자' 카드 (/dashboard disaster_messages items, null = 수집 전 → messagesReason) · 없으면 서버 머리 경고(headline)
  final List<Map<String, dynamic>>? messages;
  final String? messagesReason;
  final Map<String, dynamic>? headline;
  /// 제목 아래 한 줄 (판정 시각 등) · '지금 구룡포 날씨' 옆 갱신 시각 · 새로고침
  final String? statusText, updatedText;
  final VoidCallback? onRefresh;

  /// 방재단 현황(2026-10-09)이 대시보드 지도 칸만 쓸 때: mapOnly = 지도 카드만 그린다,
  /// 지도 위에 더 올릴 영역(대피 상황)·표식(사람 아이콘, 맨 위 층)
  final List<Polygon> extraPolygons;
  final List<Marker> extraMarkers;
  /// 지도 위에 더 그릴 선 (방재단 다중 방문 경로, 2026-10-09)
  final List<Polyline> extraPolylines;
  final bool mapOnly;

  /// 경로 안내 메뉴: 지금 위치가 육지·바다인지 → 육상 경로 3종 / 해상 경로 안내 / 위치 확인 필요
  final WhereNow where;
  /// '현위치' 버튼: 위치를 다시 읽고 그 위치를 돌려준다 (지도를 그리로 옮긴다)
  final Future<LatLng> Function()? onLocate;
  /// '해상 경로 안내' 버튼
  final VoidCallback? onSeaRoute;
  /// 바다 위일 때 경로 안내 칸에 바로 보여 줄 해상 경로 안내 (있으면 '해상 경로 안내' 버튼 대신, 2026-10-10)
  final Widget? seaRoutePanel;
  /// 바다 위일 때 경로 안내 모드에서 지도에 겹쳐 그릴 해상 경로 선·표시
  final List<Polyline> seaRouteLines;
  final List<Marker> seaRouteMarkers;
  /// 경로 모드가 아니어도 대피소·의료시설을 그린다 (방재단 지도, 2026-10-09)
  final bool showFacilities;
  /// 바뀌면 지도를 이 점으로 옮기고 확대한다 (방재단 목록에서 가구를 고를 때)
  final LatLng? focusPoint;

  @override
  State<DisasterDashboard> createState() => _DisasterDashboardState();
}

class _DisasterDashboardState extends State<DisasterDashboard> {
  _DashboardMode dashboardMode = _DashboardMode.emergency;
  /// 재난 지도에서 켠 재난 (여러 개 동시). 처음엔 모두 켬
  final layers = <HazardKind>{};
  /// '위험 재난 표시' (2026-10-10, 사용자 결정): 빨강(심각) 침수·강풍 + 산사태 취약 지역만. 처음엔 이것만 켬.
  /// 켜면 개별 재난 선택은 꺼지고, 개별 재난을 고르면 꺼진다
  bool dangerOnly = true;
  /// '위험 재난 표시'가 켜지면 종합 보기: 침수·강풍은 심각만, 산사태는 취약 지역 모두, 범례도 심각 한 칸
  bool get compositeView => dangerOnly;
  /// 지도에 그리는 위험 층. 경로 모드는 경로가 피하는 침수·산사태
  Set<HazardKind> get _visible => dashboardMode == _DashboardMode.facilities
      ? const {HazardKind.flood, HazardKind.slide}
      : dangerOnly
          ? const {..._mapKinds, HazardKind.overlap}
          : {...layers};
  /// 상위 메뉴의 하위 항목이 펼쳐져 있는지 (보고 있는 메뉴 하나만 펼친다)
  bool submenuOpen = true;
  bool locating = false;
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
      if (widget.onMapPick != null) {
        widget.onMapPick!(point);
        return;
      }
      if (!_visible.contains(HazardKind.flood)) return;
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

  /// 재난 하나 켜기·끄기 (여러 개 동시 선택). 고르면 '위험 재난 표시'는 꺼진다
  void toggleLayer(HazardKind kind) => setState(() {
        dangerOnly = false;
        if (!layers.remove(kind)) layers.add(kind);
      });

  /// '위험 재난 표시' 켜기·끄기 (켜면 개별 선택은 비운다)
  void toggleDanger() => setState(() {
        dangerOnly = !dangerOnly;
        if (dangerOnly) layers.clear();
      });

  void setDashboardMode(_DashboardMode mode) {
    // 목적지 고르기 창은 육지(또는 기본 위치)에서만 — 바다 위면 해상 경로 안내를 쓴다
    final shouldChooseFacility = mode == _DashboardMode.facilities &&
        widget.selectedDestination == null &&
        (widget.where.kind == WhereKind.land || widget.where.noGps);
    setState(() {
      dashboardMode = mode;
      submenuOpen = true;
    });
    if (shouldChooseFacility) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && dashboardMode == _DashboardMode.facilities) {
          widget.onChooseFacility?.call();
        }
      });
    }
  }

  /// 상위 메뉴 누름: 다른 메뉴면 그 메뉴로 바꾸고 펼친다(이전 메뉴는 접힘), 보고 있는 메뉴면 접기·펼치기
  void tapMenu(_DashboardMode mode) {
    if (mode == dashboardMode) {
      setState(() => submenuOpen = !submenuOpen);
    } else {
      setDashboardMode(mode);
    }
  }

  /// '현위치': 위치를 다시 읽고 지도 가운데를 그리로
  Future<void> locate(MapController ctl) async {
    if (locating) return;
    setState(() => locating = true);
    try {
      final p = await (widget.onLocate?.call() ?? Future.value(widget.currentLocation));
      if (!mounted) return;
      setState(() => focus = p);
      ctl.move(p, math.max(ctl.camera.zoom, 15));
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Widget _locateButton(MapController ctl) => MapMenuButton(
        label: locating ? '확인 중' : '현위치',
        icon: MapIcons.locate,
        kind: MapButtonKind.action,
        tooltip: '내 위치를 확인하고 지도 가운데로 옮기기',
        onTap: locating ? null : () => locate(ctl),
      );

  /// 재난 지도 하위 항목: 위험 재난 표시 · 침수 격자 · 강풍 · 산사태 위험 지역 (여러 개 선택) / 태풍 지도 열기 (화면 이동)
  Widget _emergencyLayerControls() {
    MapMenuButton item(HazardKind k, String label, String icon) => MapMenuButton(
        label: label,
        icon: icon,
        kind: MapButtonKind.check,
        selected: !dangerOnly && layers.contains(k),
        onTap: () => toggleLayer(k));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        MapButtonGroup(label: '표시할 재난 (여러 개 선택)', children: [
          MapMenuButton(
              label: '위험 재난 표시',
              icon: MapIcons.all,
              kind: MapButtonKind.check,
              selected: dangerOnly,
              tooltip: '심각 단계 침수·강풍과 산사태 취약 지역만 보기',
              onTap: toggleDanger),
          item(HazardKind.flood, '침수 격자', MapIcons.flood),
          item(HazardKind.wind, '강풍', MapIcons.wind),
          item(HazardKind.slide, '산사태 위험 지역', MapIcons.landslide),
        ]),
        // 태풍은 켜고 끄는 층이 아니라 다른 화면으로 가는 버튼 — 묶음 밖에 두고 바깥으로 나가는 아이콘을 붙여 구분한다
        // (태풍 경로는 구룡포 밖까지 넓게 봐야 해서 이 지도에 그리지 않는다)
        MapMenuButton(
            label: '태풍 지도 열기',
            icon: MapIcons.typhoon,
            kind: MapButtonKind.action,
            trailing: MapIcons.external,
            tooltip: '태풍 경로와 구룡포 영향을 넓은 지도에서 보기',
            onTap: () => context.push('/typhoon', extra: 'local')),
      ]),
      if (!dangerOnly && layers.isEmpty) ...[
        const SizedBox(height: 8),
        const MapNotice(text: '켜진 재난이 없어 지도에 위험 정보를 표시하지 않아요. 보고 싶은 재난을 골라 주세요.'),
      ],
    ]);
  }

  /// 경로 안내 하위 항목: 육지면 최단 거리·안전한 경로·오르막 회피(하나만), 바다면 해상 경로 안내, 모르면 위치 확인 필요
  Widget _routeControls() {
    final where = widget.where;
    final locateAction = MapMenuButton(
        label: locating ? '확인 중' : '현위치 확인',
        icon: MapIcons.locate,
        kind: MapButtonKind.action,
        onTap: locating ? null : () => locate(mapController));
    if (where.kind == WhereKind.checking) {
      return const MapNotice(text: '현재 위치가 육지인지 바다인지 확인하고 있어요.');
    }
    if (where.kind == WhereKind.sea) {
      if (widget.seaRoutePanel != null) return widget.seaRoutePanel!;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MapButtonGroup(label: '해상 경로', children: [
          MapMenuButton(
              label: '해상 경로 안내', icon: MapIcons.anchor, kind: MapButtonKind.action, selected: true, onTap: widget.onSeaRoute),
        ]),
        const SizedBox(height: 6),
        const Text('지금 위치가 바다 위로 확인됐어요. 가까운 항구까지 바닷길과 항구에서 대피소까지 길을 안내해요.',
            style: TextStyle(fontSize: 15, color: GK.muted, height: 1.45)),
      ]);
    }
    // GPS 는 있는데 판별을 못 했으면 육지·바다 어느 쪽 경로도 내놓지 않는다
    if (where.kind == WhereKind.unknown && !where.noGps) {
      return MapNotice(
          warn: true,
          title: '위치 확인이 필요해요',
          text: '${where.reason ?? '바다·육지를 판별하지 못했습니다.'} 위치를 다시 확인해 주세요.',
          action: locateAction);
    }
    final types = widget.travelMode.routeTypes;
    MapMenuButton type(RouteType t, String label, String icon) => MapMenuButton(
          label: label,
          icon: icon,
          kind: MapButtonKind.radio,
          selected: widget.routeType == t,
          tooltip: types.contains(t) ? t.description : '${widget.travelMode.label}에서는 쓸 수 없어요',
          onTap: types.contains(t) ? () => widget.onRouteTypeChanged?.call(t) : null,
        );
    final noGpsNotice = MapNotice(
        warn: true,
        title: '위치 확인이 필요해요',
        text: '${where.reason ?? '현재 위치를 확인하지 못했습니다.'} 확인 전에는 구룡포 기본 위치에서 출발하는 경로를 보여 드려요.',
        action: locateAction);
    // 경로 방식은 아래 경로 안내 덩어리(routePlanner) 안에서 고른다 (2026-10-10)
    if (widget.routePlanner != null) return where.noGps ? noGpsNotice : const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (where.noGps) ...[noGpsNotice, const SizedBox(height: 8)],
      MapButtonGroup(label: '경로 방식 (하나만 선택)', children: [
        type(RouteType.nearest, '최단 거리', MapIcons.shortest),
        type(RouteType.safest, '안전한 경로', MapIcons.safe),
        type(RouteType.flat, '오르막 회피', MapIcons.flat),
      ]),
      const SizedBox(height: 6),
      Text(
          switch (widget.routeType) {
            RouteType.nearest => '최단 거리: 이동 거리가 가장 짧은 경로예요. 위험 구역을 피하지 않고, 지나는 구역은 알려 드려요.',
            RouteType.safest => '안전한 경로: 지금 판정된 침수·산사태 위험 구역(주의 이상)을 피해서 가요.',
            RouteType.flat => '오르막 회피: 위험 구역을 피하면서, 도로 경사(고도 자료)로 가파른 오르막을 되도록 줄여요.',
            RouteType.uphill => '오르막 회피: 도로 경사(고도 자료)로 가파른 오르막을 되도록 줄여요. 위험 구역은 피하지 않아요.',
          },
          style: const TextStyle(fontSize: 15, color: GK.muted, height: 1.45)),
    ]);
  }

  void focusOn(LatLng point) {
    setState(() => focus = point);
    mapController.move(point, 15);
  }

  @override
  void didUpdateWidget(covariant DisasterDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final fp = widget.focusPoint;
    if (fp != null && fp != oldWidget.focusPoint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) mapController.move(fp, math.max(mapController.camera.zoom, 16));
      });
    }
    if (!oldWidget.routeActive && widget.routeActive) {
      dashboardMode = _DashboardMode.facilities;
      submenuOpen = true;
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

  /// 지도 (대시보드 카드 안·전체 화면 공통). 전체 화면은 컨트롤러·옵션을 따로 쓴다 (한 컨트롤러는 지도 하나에만 붙는다)
  Widget _buildMap(BuildContext context, MapController ctl, MapOptions options) {
    final routeMode = dashboardMode == _DashboardMode.facilities;
    // 경로 모드(경로 안내)에서도 긴급 지도와 같은 침수·산사태 층을 보인다 (2026-10-07) — 경로가 무엇을 피하는지 보이게
    final visible = _visible;
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
    return FlutterMap(
              mapController: ctl,
              options: options,
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'guryongpo.safety.demo',
                ),
                // 침수는 큰 원(위험 판정 영역)만 (2026-10-10). 격자 칸은 원이 하나도 없을 때(예시 데이터)만 그린다
                if (visible.contains(HazardKind.flood) &&
                    !widget.riskAreas.any((a) => a.hazard == 'flood'))
                  PolygonLayer(
                      polygons: _disasterFloodPolygons(floodGrids,
                          severeOnly: compositeView)),
                if (widget.riskAreas.isNotEmpty)
                  PolygonLayer(
                      polygons: hazardAreaPolygons(widget.riskAreas, kinds: visible, severeOnly: compositeView)),
                if (widget.extraPolygons.isNotEmpty) PolygonLayer(polygons: widget.extraPolygons),
                if (widget.extraPolylines.isNotEmpty) PolylineLayer(polylines: widget.extraPolylines),
                if (routeMode && widget.seaRouteLines.isNotEmpty) PolylineLayer(polylines: widget.seaRouteLines),
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
                    // 수위계 위치 (2026-10-07): 침수 영역 원의 중심 = 판정 원인 센서의 실제 좌표 (포항 DT 수위계·맨홀)
                    if (visible.contains(HazardKind.flood))
                      ...floodSensorMarkers(context, widget.riskAreas, severeOnly: compositeView),
                    if (visible.contains(HazardKind.wind) && !widget.demo)
                      for (final w in widget.windPoints)
                        if (!compositeView || w.$2 >= 21)
                        Marker(
                          point: w.$1,
                          width: 76,
                          height: 64,
                          // 화살표만 (2026-10-10): 크고 붉을수록 강함, 숫자는 누르면 나오는 상세에서
                          child: GestureDetector(
                            onTap: () => _showLiveWind(context, w),
                            // 화살표는 불어가는 방향 = 풍향(불어오는 방향) + 180°
                            child: Transform.rotate(
                              angle: (w.$3 + 180) * math.pi / 180,
                              child: Icon(Icons.navigation,
                                  color: _windColor(w.$2, w.$2), size: 18 + math.min(w.$2, 24)),
                            ),
                          ),
                        ),
                    if (visible.contains(HazardKind.wind) && widget.demo)
                      for (final w in const [
                        (LatLng(35.9892, 129.5620), 21.0, '북동풍'),
                        (LatLng(35.9902, 129.5550), 17.0, '북동풍'),
                        (LatLng(35.9855, 129.5530), 10.0, '동풍'),
                        (LatLng(35.9955, 129.5480), 7.0, '동풍'),
                      ])
                        if (!compositeView || w.$2 >= 21)
                        Marker(
                          point: w.$1,
                          width: 76,
                          height: 64,
                          child: GestureDetector(
                            onTap: () => _showWind(context, w.$1, w.$2, w.$3),
                            child: Transform.rotate(
                              angle: (w.$3 == '북동풍' ? 225 : 270) *
                                  math.pi /
                                  180,
                              child: Icon(
                                Icons.navigation,
                                color: _windColor(w.$2, w.$2 + 9),
                                size: 18 + w.$2,
                              ),
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
                    if (routeMode || widget.showFacilities) ...facilityMarkers,
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
                if (widget.extraMarkers.isNotEmpty) MarkerLayer(markers: widget.extraMarkers),
                if (routeMode && widget.seaRouteMarkers.isNotEmpty) MarkerLayer(markers: widget.seaRouteMarkers),
                // 판단에 필요한 경고는 범례 안에 숨기지 않고 지도에 바로 (2026-10-09): 위험 구역을 못 피한 경로
                if (route != null && (route.stillInside.isNotEmpty || !route.hazardsOk))
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: RouteHazardBanner(route: route),
                  ),
                // 범례는 지도 왼쪽 위에 늘 펼쳐 둔다 (2026-10-10: '범례' 버튼·침수 범례·침수 위험 단계 상자 대신 하나로)
                Positioned(
                  left: 8,
                  top: 8,
                  child: MapLegendCard(
                    visible: visible,
                    severeOnly: !routeMode && compositeView,
                    showFacilities: routeMode || widget.showFacilities,
                    hasDestination: destination != null,
                    hasRoute: route != null,
                    hasSea: (route?.seaPoints.length ?? 0) > 1,
                  ),
                ),
              ],
            );
  }

  void _openFullMap(BuildContext context) {
    final ctl = MapController();
    final cam = mapController.camera;
    final options = MapOptions(
      initialCenter: cam.center,
      initialZoom: cam.zoom,
      cameraConstraint: CameraConstraint.contain(bounds: guryongpoBounds),
      onTap: mapOptions.onTap,
    );
    showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (dc) => Dialog.fullscreen(
        child: Stack(children: [
          Positioned.fill(child: _buildMap(dc, ctl, options)),
          Positioned(left: 13, bottom: 13, child: _locateButton(ctl)),
          Positioned(
            right: 16,
            bottom: 16,
            child: GkPill('전체 화면 닫기', icon: Icons.close_fullscreen_rounded, filled: true, big: true,
                onTap: () => Navigator.pop(dc)),
          ),
        ]),
      ),
    ).whenComplete(ctl.dispose);
  }

  /// 빨간 '최근 재난문자' 카드 (프로토타입) — 재난문자 → 없으면 서버 머리 경고 → 없으면 흰 카드
  Widget _messageCard(BuildContext context) {
    final msgs = widget.messages;
    final headline = widget.headline;
    final demoMsg = widget.demo ? demoHazards.first : null;
    final latest = (msgs ?? const <Map<String, dynamic>>[]).firstOrNull;
    final red = latest != null || headline != null || demoMsg != null;
    final fg = red ? Colors.white : GK.ink;
    final title = latest != null ? '최근 재난문자' : headline != null ? '지금 위험 알림' : demoMsg != null ? '최근 재난문자 · 예시' : '최근 재난문자';
    final from = latest != null
        ? '${latest['sender'] ?? ''} · ${_hhmm('${latest['sent_at']}')}'
        : headline != null
            ? '위험 판정 엔진'
            : demoMsg != null
                ? '가상 시연 · ${demoMsg.time}'
                : '';
    final head = latest != null
        ? '${latest['message']}'
        : headline != null
            ? '${headline['title']}'
            : demoMsg != null
                ? '${demoMsg.name} — ${demoMsg.guide}'
                : (widget.messagesReason ?? '최근 재난문자가 없습니다.');
    return GkCard(
      color: red ? GK.red : Colors.white,
      shadow: red,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GkCircleIcon(Icons.sms_rounded, size: 48, bg: red ? Colors.white : GK.tint, fg: red ? GK.red : GK.navy),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: fg))),
          if (from.isNotEmpty)
            Flexible(
                child: Text(from,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg.withValues(alpha: .9)))),
        ]),
        const SizedBox(height: 16),
        Text(head,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: red ? 26 : 19, fontWeight: red ? FontWeight.w800 : FontWeight.w600, height: 1.3, color: red ? fg : GK.muted)),
        if (headline != null || demoMsg != null) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 8, children: [
            GkPill('대피 경로 보기',
                icon: Icons.directions_run_rounded,
                bg: Colors.white,
                fg: GK.redDark,
                big: true,
                onTap: () => setDashboardMode(_DashboardMode.facilities)),
            GkPill('AI에게 행동 요령 묻기',
                icon: Icons.chat_bubble_rounded, bg: Colors.white, fg: GK.redDark, big: true, onTap: () => context.go('/ai')),
          ]),
        ],
        if (latest != null && '${latest['message']}'.length > 80) ...[
          const SizedBox(height: 12),
          Text('원문: ${latest['message']}', style: TextStyle(fontSize: 15, height: 1.5, color: fg.withValues(alpha: .85))),
        ],
      ]),
    );
  }

  /// '경보·주의보' 카드 — 기상청 특보(경보는 진한 색, 주의보는 연한 색) + 서버 위험 판정(누르면 지도 이동).
  /// 시연은 휴대폰 화면과 같은 가상 특보 네 가지 (2026-10-10)
  Widget _warningsCard(BuildContext context) {
    final labels = widget.demo
        ? const ['태풍 경보', '풍랑 경보', '강풍 주의보', '호우 주의보']
        : [
            for (final w in widget.warnings) '${w['label'] ?? w['region_name'] ?? ''}'.trim()
          ].where((l) => l.isNotEmpty).toSet().toList();
    // 기상청 특보만 (2026-10-10): 서버 위험 판정 칩(강우·산사태·침수·강풍 …)은 지도에서 보므로 뺀다.
    // 아이콘은 휴대폰 화면과 같은 Font Awesome (웹에서 Material 날씨 아이콘이 빈칸으로 보였다)
    final chips = <Widget>[
      for (final l in labels)
        GkPill(l,
            leading: FaIcon(warningIcon(l), size: 20, color: l.contains('경보') ? Colors.white : GK.navy),
            filled: l.contains('경보'),
            big: true,
            onTap: () => context.push('/alerts-hub')),
    ];
    final none = chips.isEmpty;
    return GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GkCardHeader('경보 · 주의보',
            icon: Icons.warning_rounded,
            trailing: Text(widget.demo ? '기상청 · 가상 시연' : '기상청',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: GK.muted))),
        const SizedBox(height: 16),
        if (none)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('지금 발효 중인 특보가 없습니다.',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: GK.green)),
          ),
        Wrap(spacing: 10, runSpacing: 10, children: chips),
        const SizedBox(height: 14),
        Text(none ? '알림 종에서 받은 경고와 예보를 볼 수 있어요.' : '해안가와 방파제 접근을 피하고 가까운 대피소 위치를 확인하세요.',
            style: const TextStyle(fontSize: 16, color: GK.muted, height: 1.5)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final routeMode = dashboardMode == _DashboardMode.facilities;
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final map = ClipRRect(
      borderRadius: BorderRadius.circular(GK.radiusInner),
      child: Stack(children: [
        Positioned.fill(child: _buildMap(context, mapController, mapOptions)),
        // 내 위치 확인 + 지도 가운데로 (출발 위치 표시 칸 대신, 2026-10-09)
        Positioned(left: 11, bottom: 11, child: _locateButton(mapController)),
        Positioned(
          right: 14,
          bottom: 14,
          child: GkPill('전체 화면', icon: Icons.open_in_full_rounded, filled: true, big: !narrow,
              onTap: () => _openFullMap(context)),
        ),
      ]),
    );
    final places = _SavedPlaceSummary(
      currentLocation: widget.currentLocation,
      onFocus: (p) => focusOn(p),
      levelAt: widget.demo ? null : _levelAt,
      showCurrent: !widget.mapOnly,
      header: const Padding(
        padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text('등록 장소 위험', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: GK.muted)),
      ),
    );
    // 지도 카드 — 재난 지도 / 대피 경로 (방재단 현황은 이 카드만 쓴다: mapOnly)
    final mapCard = GkCard(
          padding: EdgeInsets.all(narrow ? 12 : 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 방재단 현황(mapOnly)은 메뉴·하위 버튼 없이 지도만 (2026-10-11 사용자 요청) — 재난 층은 처음 값(모두 켬) 그대로 보인다
            // 상위 메뉴 두 개 (2026-10-09): 누르면 그 메뉴의 하위 항목만 펼친다. 보고 있는 메뉴를 다시 누르면 접고 펼친다
            if (!widget.mapOnly) Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              MapMenuButton(
                  label: '재난 지도',
                  icon: MapIcons.layers,
                  kind: MapButtonKind.menu,
                  big: !narrow, // 휴대폰 폭에서는 두 메뉴가 한 줄에 들어가게
                  selected: !routeMode,
                  expanded: !routeMode && submenuOpen,
                  onTap: () => tapMenu(_DashboardMode.emergency)),
              MapMenuButton(
                  label: '경로 안내',
                  icon: MapIcons.route,
                  kind: MapButtonKind.menu,
                  big: !narrow, // 휴대폰 폭에서는 두 메뉴가 한 줄에 들어가게
                  selected: routeMode,
                  expanded: routeMode && submenuOpen,
                  onTap: () => tapMenu(_DashboardMode.facilities)),
            ]),
            if (submenuOpen && !widget.mapOnly) ...[
              const SizedBox(height: 10),
              if (!routeMode) _emergencyLayerControls() else _routeControls(),
            ],
            // 목적지 고르기·경로 요약 (기존 기능) — 육지·기본 위치일 때, 또는 이미 그리는 경로가 있을 때
            if (routeMode &&
                (widget.selectedDestination != null ||
                    widget.where.kind == WhereKind.land ||
                    widget.where.noGps ||
                    // 바다 위여도 출발지를 바꿀 수 있게 (GPS 선택 · 2026-10-11) — RoutePlanner 가 바다면 출발 줄만 보인다
                    (widget.where.kind == WhereKind.sea && widget.routePlanner != null)))
              _integratedRoutePanel(context),
            if (!widget.mapOnly) const SizedBox(height: 12),
            // mapOnly 는 '현위치' 칸을 빼서 오른쪽 칸이 빌 수 있다 → 지도를 넓게 두고 남은 등록 장소는 지도 아래에
            if (wide && !widget.mapOnly)
              SizedBox(
                height: 520,
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: map),
                  if (!routeMode) ...[
                    const SizedBox(width: 16),
                    SizedBox(width: 262, child: SingleChildScrollView(child: places)),
                  ],
                ]),
              )
            else ...[
              SizedBox(height: narrow ? 380 : 460, child: map),
              if (!routeMode) ...[const SizedBox(height: 12), places],
            ],
          ]),
        );
    if (widget.mapOnly) return mapCard;
    return ListView(
      padding: gkPagePadding(context),
      children: [
        GkPageTitle('대시보드',
            subtitle: widget.statusText,
            trailing: widget.onRefresh == null
                ? null
                : IconButton(
                    tooltip: '새로고침', onPressed: widget.onRefresh, icon: const Icon(Icons.refresh_rounded, size: 30))),
        if (widget.demo) const _DemoBanner() else if (widget.liveTop != null) widget.liveTop!,
        const SizedBox(height: 12),
        GkColumns(minWidth: 440, children: [_messageCard(context), _warningsCard(context)]),
        const SizedBox(height: 20),
        mapCard,
        const SizedBox(height: 28),
        // 날씨 = 휴대폰 화면과 같은 작은 칸 (2026-10-10 사용자 요청: 크기·규격 통일). 누르면 자세한 설명
        WeatherSection(demo: widget.demo),
        // 태풍 정보 카드는 뺐다 — 지도 카드 재난 지도 메뉴 오른쪽 태풍 지도 버튼과 중복 (2026-10-10 사용자 요청).
        // 시연 버튼 카드(3주차 안전 기능 시연)도 뺐다 — 대피 현황·프로필·방재단 대시보드·경로 안내와 모두 중복.
        // 재난 후 지원 · 복구 카드도 뺐다 — AI 대화창 추천 질문으로 묻는다 (2026-10-11 사용자 요청)
      ],
    );
  }

  Widget _integratedRoutePanel(BuildContext context) {
    final destination = widget.selectedDestination;
    final route = widget.safetyRoute;
    final warning = destination == null
        ? null
        : shelterExclusion(destination, widget.riskAreas);
    if (widget.routePlanner != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        widget.routePlanner!,
        if (warning != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.warning_amber_rounded, color: Colors.deepOrange),
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
                : IconButton(tooltip: '경로 다시 찾기', onPressed: widget.onRetryRoute, icon: const Icon(Icons.refresh)),
          ),
        if (route != null && destination != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
                '최대 오르막 ${route.maxUphillPercent}%${route.hazardsOk ? '' : ' · 위험 정보 확인 불가'} · ${route.riskAvoidanceSummary}',
                style: const TextStyle(fontSize: 15, color: GK.muted, height: 1.45)),
          ),
        if (widget.routeExtras != null) ...[const SizedBox(height: 8), widget.routeExtras!],
      ]);
    }
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
                '${route.distanceMeters >= 1000 ? '${(route.distanceMeters / 1000).toStringAsFixed(1)}km' : '${route.distanceMeters}m'} · ${route.mode.label} ${route.estimatedMinutes}분 · ${route.routeType.label} · 최대 오르막 ${route.maxUphillPercent}%${route.hazardsOk ? '' : ' · 위험 정보 확인 불가'}\n${route.riskAvoidanceSummary}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          // 경로 방식(최단·안전·오르막 회피)은 위 '경로 안내' 하위 항목에서 고른다 (2026-10-09). 여기는 이동 수단만
          if (destination != null)
            Wrap(spacing: 6, children: [
              for (final m in TravelMode.values)
                ChoiceChip(
                  avatar: Icon(m.icon, size: 16),
                  label: Text(m.label),
                  selected: widget.travelMode == m,
                  onSelected: (_) => widget.onTravelModeChanged?.call(m),
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
// ── 대시보드·경로 지도 공통 위험 층 (2026-10-07: 경로 안내 지도를 대시보드 지도와 같게) ──────────────

/// 위험 영역 → 지도 재난 구분 (산사태·침수·강풍, 그 밖은 null = 늘 그림)
HazardKind? _areaKind(String hazard) => switch (hazard) {
      'landslide' => HazardKind.slide,
      'flood' || 'heavy_rain' => HazardKind.flood,
      'strong_wind' || 'wind' || 'high_seas' => HazardKind.wind,
      _ => null,
    };

/// 위험 영역 면 (2026-10-10): 침수·강풍은 채움·테두리 모두 위험 단계 색, 산사태는 단계 없이 한 색(취약 지역).
/// kinds = 켠 재난만 (null 이면 모두), severeOnly = '위험 재난 표시' (침수·강풍은 심각만, 산사태는 모두).
/// 시연 모드면 읍 전체 특보는 뺀다
List<Polygon> hazardAreaPolygons(List<RiskArea> areas, {Set<HazardKind>? kinds, bool severeOnly = false}) => [
      for (final area in DemoData.mapAreas(areas))
        if ((kinds == null || _areaKind(area.hazard) == null || kinds.contains(_areaKind(area.hazard))) &&
            (!severeOnly || area.hazard == 'landslide' || area.level == '심각'))
        for (final ring in area.polygons)
          if (ring.length >= 3)
            Polygon(
              points: ring,
              color: (area.hazard == 'landslide' ? _slideColor : _floodColor(area.level)).withValues(alpha: .22),
              borderColor: area.hazard == 'landslide' ? _slideColor : _floodColor(area.level),
              borderStrokeWidth: 2,
            ),
    ];

/// 침수 격자 칸 면 (단계 색)
List<Polygon> floodGridAreaPolygons(List<FloodGrid> grids, {bool severeOnly = false}) =>
    _disasterFloodPolygons(grids, severeOnly: severeOnly);

/// 침수 격자 칸 가운데 점 — 누르면 칸 상세
List<Marker> floodGridDotMarkers(BuildContext context, List<FloodGrid> grids,
        {bool severeOnly = false}) =>
    [
      for (final g in grids.where((g) => g.hasRisk && (!severeOnly || g.level == '심각')))
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
                    border: Border.all(color: Colors.white, width: 2))),
          ),
        ),
    ];

/// 수위계 표식: 침수 영역 원의 중심(판정 원인 센서 실제 좌표). 누르면 센서 측정값
List<Marker> floodSensorMarkers(BuildContext context, List<RiskArea> areas, {bool severeOnly = false}) => [
      for (final a in _floodSensors(DemoData.mapAreas(areas)))
        if (!severeOnly || a.level == '심각')
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
                    border: Border.all(color: _sensorColor(a.level), width: 2),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)]),
                child: Icon(Icons.water_drop, size: 18, color: _sensorColor(a.level)),
              ),
            ),
          ),
        ),
    ];

/// 수위계 표식 색: 주의 이상은 단계 색, 그 아래는 회색 (파란 테두리 없앰, 2026-10-10)
Color _sensorColor(String level) =>
    const ['주의', '경계', '심각'].contains(level) ? _floodColor(level) : Colors.blueGrey.shade400;

/// 지도 왼쪽 위에 늘 펼쳐 두는 범례 (2026-10-10, 사용자 결정): 지금 켠 층에 맞는 것만.
/// 색 = 위험 단계는 침수·강풍만, 산사태는 취약 지역 한 색. 수치는 쓰지 않는다
class MapLegendCard extends StatelessWidget {
  const MapLegendCard(
      {super.key,
      required this.visible,
      this.severeOnly = false,
      this.showFacilities = false,
      this.hasDestination = false,
      this.hasRoute = false,
      this.hasSea = false});
  final Set<HazardKind> visible;
  /// '위험 재난 표시': 심각 단계만 그리므로 범례도 심각 한 칸
  final bool severeOnly;
  final bool showFacilities, hasDestination, hasRoute, hasSea;

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: GK.navy);
    const note = TextStyle(fontSize: 11, color: GK.muted, height: 1.3);
    Widget swatch(Color c) => Container(
        width: 16,
        height: 12,
        decoration: BoxDecoration(
            color: c.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c, width: 2)));
    Widget mark(IconData i, Color c) => SizedBox(width: 18, child: Icon(i, color: c, size: 17));
    Widget section(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 3),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: GK.navy)));
    Widget row(Widget m, String t, [String? n]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          m,
          const SizedBox(width: 6),
          Flexible(
              child: Text.rich(TextSpan(children: [
            TextSpan(text: t, style: label),
            if (n != null) TextSpan(text: '  $n', style: note),
          ]))),
        ]));
    final leveled = visible.contains(HazardKind.flood) || visible.contains(HazardKind.wind);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Material(
        color: Colors.white.withValues(alpha: .94),
        elevation: 1,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (leveled) ...[
              section('위험 단계'),
              Wrap(spacing: 8, runSpacing: 2, children: [
                for (final l in severeOnly ? const ['심각'] : const ['주의', '경계', '심각'])
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    swatch(_floodColor(l)),
                    const SizedBox(width: 4),
                    Text(l, style: label),
                  ]),
              ]),
            ],
            if (visible.contains(HazardKind.slide)) ...[
              section('산사태'),
              row(swatch(_slideColor), '산사태 취약 지역'),
            ],
            if (visible.contains(HazardKind.wind)) ...[
              section('바람'),
              row(mark(Icons.navigation, _windColor(21, 21)), '화살표', '불어가는 쪽 · 크고 붉을수록 강함'),
            ],
            section('주요 표식'),
            row(mark(Icons.my_location, _riskColor('경계')), '현위치', '색 = 지금 위치의 위험 단계'),
            if (showFacilities) ...[
              row(mark(Icons.health_and_safety, Colors.teal.shade800), '대피소'),
              row(mark(Icons.local_hospital, Colors.red.shade700), '의료시설'),
            ],
            if (hasDestination) row(mark(Icons.location_on, Colors.blue.shade800), '목적지'),
            if (hasRoute)
              row(SizedBox(width: 18, child: Container(height: 4, color: Colors.blue.shade800)), '안내 경로'),
            if (hasSea)
              row(SizedBox(width: 18, child: Container(height: 3, color: Colors.teal.shade700)), '바닷길'),
          ]),
        ),
      ),
    );
  }
}

/// 지도 오른쪽 위 '범례' 버튼 (FlutterMap children 안에 둔다)
Widget mapLegendButton(BuildContext context,
        {required bool routeMode,
        required Set<HazardKind> visible,
        required bool hasRoute,
        required bool hasSea,
        bool? hasDestination,
        bool? showFacilities,
        bool showPlaces = true}) =>
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
            hasRoute: hasRoute,
            hasSea: hasSea,
            hasDestination: hasDestination ?? hasRoute,
            showFacilities: showFacilities ?? routeMode,
            hidesTownWide: DemoData.on,
            showPlaces: showPlaces),
        icon: const Icon(Icons.info_outline, size: 18),
        label: const Text('범례'),
      ),
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
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(color: GK.orangeTint, borderRadius: BorderRadius.circular(24)),
        child: const Row(children: [
          Icon(Icons.info_rounded, color: GK.orangeInk, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '모든 위험·좌표·측정값·시설 정보는 실제 발생 정보가 아닌 시연용 가상 데이터입니다. 기상청 실시간 자료 미연동.',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: GK.orangeInk),
            ),
          ),
        ]),
      );
}

class _SavedPlaceSummary extends StatefulWidget {
  const _SavedPlaceSummary({
    required this.currentLocation,
    required this.onFocus,
    this.levelAt,
    this.showCurrent = true,
    this.header,
  });
  final LatLng currentLocation;
  final ValueChanged<LatLng> onFocus;
  /// false = '현위치' 칸을 뺀다 (방재단 현황 지도, 2026-10-11 사용자 요청)
  final bool showCurrent;
  /// 칸들 위 제목. 보여 줄 칸이 하나도 없으면 제목도 그리지 않는다
  final Widget? header;
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
        if (!widget.showCurrent && home == null && work == null && places.isEmpty) return const SizedBox.shrink();
        final tiles = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (widget.showCurrent)
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
        if (widget.header == null) return tiles;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [widget.header!, tiles]);
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

/// 자료 구분 배지: 예시(가상) · 실측 · 예보 · 자료 없음
Widget _badge(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
          color: text == '실측' ? GK.tint : text == '예보' ? GK.orangeTint : GK.bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text,
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700, color: text == '예보' ? GK.orangeInk : GK.navy)),
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
    return GkMetricGrid(children: [
      _ok(rain)
          ? _liveRainfall(rain, simulated: simulated)
          : _metric(Icons.water_drop_outlined, '강수', '자료 없음', '${rain['reason']}', '구룡포 AWS', Colors.indigo,
              badge: '자료 없음', suffix: ''),
      _ok(wind)
          ? _metric(Icons.navigation, '바람', '평균 ${_n(wind['value'])} · 순간 ${_n(wind['wind_gust'])}m/s',
              '${_windFromKo(wind['wind_dir'])} · 화살표는 바람이 불어가는 방향', '${wind['station_name']} · ${_hhmm('${wind['observed_at']}')}',
              Colors.deepOrange,
              rotation: wind['wind_dir'] is num ? ((wind['wind_dir'] as num) + 180) * math.pi / 180 : 0, badge: _obs, suffix: simulated ? ' · 시연값' : ' · 기상청 관측',
              level: wind['level'] as String?)
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
              suffix: '',
              level: i['level'] as String?),
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
  final label = now <= 0 ? '비 없음' : now < 3 ? '약한 비' : now < 15 ? '보통 비' : now < 30 ? '강한 비' : '매우 강한 비';
  return GkMetricCard(
    icon: Icons.water_drop_rounded,
    title: '강수',
    value: '${now.toStringAsFixed(1)} mm/h',
    description: '$label · 오늘 누적 ${((d['rain_day'] as num?) ?? 0).toStringAsFixed(1)}mm',
    footnote: '${d['station_name']} · ${_hhmm('${d['observed_at']}')} · ${simulated ? '시연값' : '기상청 관측'}',
    badge: simulated ? '시연' : '실측',
    level: d['level'] as String?,
    extra: bars.length < 2 ? null : _rainBars(bars),
  );
}

/// 시간별 강수 막대 (프로토타입 AI 대화창의 '시간별 강수량' 막대 모양)
Widget _rainBars(List<(String, double)> bars) {
  final top = bars.map((e) => e.$2).reduce(math.max);
  return SizedBox(
    height: 92,
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (var i = 0; i < bars.length; i++)
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            Text(bars[i].$2.toStringAsFixed(bars[i].$2 < 10 ? 1 : 0),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: i == bars.length - 1 ? GK.navy : GK.muted)),
            const SizedBox(height: 4),
            Container(
              width: 24,
              height: top <= 0 ? 4 : math.max(4, 46 * bars[i].$2 / top),
              decoration: BoxDecoration(
                  color: i >= bars.length - 3 ? GK.navy : const Color(0xFFB8C2DE), borderRadius: BorderRadius.circular(999)),
            ),
            const SizedBox(height: 4),
            Text(bars[i].$1, style: const TextStyle(fontSize: 12, color: GK.muted)),
          ]),
        ),
    ]),
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
  String? level,
}) =>
    GkMetricCard(
      icon: icon,
      title: title,
      value: value,
      description: description,
      footnote: '$locationTime$suffix',
      badge: badge,
      level: level,
      rotation: rotation,
    );

/// 지표 카드 (프로토타입 MetricCard): 원 아이콘 · 이름·설명 · 큰 값 · 단계 칩/자료 구분 · 관측소·시각
class GkMetricCard extends StatelessWidget {
  const GkMetricCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.value,
      required this.description,
      required this.footnote,
      required this.badge,
      this.level,
      this.rotation = 0,
      this.extra});
  final IconData icon;
  final String title, value, description, footnote, badge;
  /// 서버 위험 단계 (있으면 원·칩 색)
  final String? level;
  final double rotation;
  final Widget? extra;
  @override
  Widget build(BuildContext c) {
    final lv = level == null ? null : gkLevelOf(level);
    return GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: lv?.bg ?? GK.tint, shape: BoxShape.circle),
            child: Transform.rotate(angle: rotation, child: Icon(icon, size: 40, color: lv?.fg ?? GK.navy)),
          ),
          const SizedBox(width: 14),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(description, style: const TextStyle(fontSize: 16, height: 1.4)),
          ])),
        ]),
        const SizedBox(height: 14),
        Text(value,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: GK.navy, letterSpacing: -0.6, height: 1.2)),
        if (extra != null) ...[const SizedBox(height: 10), extra!],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (lv != null) GkLevelChip(lv),
          _badge(badge),
          Text(footnote, style: const TextStyle(fontSize: 14, color: GK.muted)),
        ]),
      ]),
    );
  }
}

/// 지표 카드 격자 (프로토타입 auto-fill minmax(280px,1fr))
class GkMetricGrid extends StatelessWidget {
  const GkMetricGrid({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
        const gap = 16.0;
        final cols = (box.maxWidth / 300).floor().clamp(1, 4);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final x in children) SizedBox(width: w, child: x)]);
      });
}

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
      padding: gkPagePadding(context),
      children: [
        const GkPageTitle('선제 경고·알림'),
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
      padding: gkPagePadding(context),
      children: [
        const GkPageTitle('선제 경고·알림'),
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
      padding: gkPagePadding(c),
      children: [
        const GkPageTitle('지원 및 복구'),
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

// 사용자 화면 '내 정보' 카드(ProfileDetailsCard)는 profile_cards.dart 로 옮겼다 (2026-10-09)

/// 경로가 위험 구역을 다 피하지 못했을 때 지도 위에 바로 띄우는 경고 (범례·작은 글씨에만 두지 않는다, 2026-10-09)
class RouteHazardBanner extends StatelessWidget {
  const RouteHazardBanner({super.key, required this.route});
  final SafetyRoute route;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xffd93232), width: 2),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xffd93232)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  if (route.stillInside.isNotEmpty) '다른 길이 없어 위험 구역을 지나는 경로입니다: ${route.stillInside.join(', ')}',
                  if (!route.hazardsOk) '위험 정보를 확인하지 못해 위험 구역을 피하지 않고 계산한 경로입니다',
                ].join('\n'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xff8a1c17)),
              ),
            ),
          ]),
        ),
      );
}

/// 지도 범례 (2026-10-07, 2026-10-09 간소화): 기본은 지도를 읽는 데 꼭 필요한 것만 — 위험 단계·재난 구분·주요 표식·경로.
/// 긴 설명과 기술 세부(수위계·침수 격자·숫자 원·채움/테두리·판단 근거·출처·칠하지 않는 특보)는 접힌 '범례 자세히' 안.
/// 지금 켠 층·경로 상태에 맞는 항목만 보인다 (경로 안내 전에는 목적지·경로 없음). 색은 지도 그리기와 같은 함수를 쓰고,
/// 단계 이름도 지도 데이터(위험 판정 → 주의·경계·심각)와 같다.
void _showMapLegend(BuildContext context,
    {required bool routeMode,
    required Set<HazardKind> visible,
    required bool hasRoute,
    required bool hasSea,
    required bool hidesTownWide,
    bool hasDestination = false,
    bool showFacilities = false,
    bool showPlaces = true}) {
  Widget fill(Color c, {Color? border}) => Container(
      width: 22,
      height: 14,
      decoration: BoxDecoration(
          color: c.withValues(alpha: .35),
          border: Border.all(color: border ?? c, width: 2)));
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
  Widget chip(Widget mark, String label) => Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
      decoration: BoxDecoration(color: const Color(0xFFF3F5FA), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        mark,
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ]));
  final hasAreas = visible.contains(HazardKind.flood) || visible.contains(HazardKind.slide);
  final showRoute = routeMode || hasRoute;
  final facilityMark = CircleAvatar(
      radius: 11,
      backgroundColor: Colors.teal.shade800,
      child: const Text('3', style: TextStyle(color: Colors.white, fontSize: 11)));

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
            // ---------------------------------------------------------------- 기본
            // 색 = 위험 단계는 침수·강풍만, 산사태는 취약 지역 한 색 (2026-10-10). 색 이름·수치는 쓰지 않는다
            if (visible.contains(HazardKind.flood) || visible.contains(HazardKind.wind)) ...[
              section('위험 단계'),
              Wrap(spacing: 8, runSpacing: 6, children: [
                chip(fill(_floodColor('주의')), '주의'),
                chip(fill(_floodColor('경계')), '경계'),
                chip(fill(_floodColor('심각')), '심각'),
              ]),
            ],
            if (visible.contains(HazardKind.slide)) ...[
              section('산사태'),
              Wrap(spacing: 8, runSpacing: 6, children: [chip(fill(_slideColor), '산사태 취약 지역')]),
            ],
            if (visible.contains(HazardKind.wind)) ...[
              section('바람'),
              row(icon(Icons.navigation, _windColor(21, 21)), '화살표', '바람이 불어가는 쪽 · 크고 붉을수록 강함'),
            ],
            section('주요 표식'),
            row(icon(Icons.my_location, _riskColor('경계')), '현위치', '색 = 지금 위치의 위험 단계'),
            if (showFacilities) ...[
              row(icon(Icons.health_and_safety, Colors.teal.shade800), '대피소'),
              row(icon(Icons.local_hospital, Colors.red.shade700), '의료시설'),
              row(icon(Icons.warning_amber_rounded, Colors.deepOrange, size: 18), '주황 경고 표시',
                  '위험지역 안에 있는 시설 — 대피소로 고르지 않음'),
            ],
            if (hasDestination)
              row(icon(Icons.location_on, Colors.blue.shade800), '목적지'),
            if (showRoute && (hasRoute || hasDestination)) ...[
              section('안내 경로'),
              row(line(Colors.blue.shade800), '파란 선', '위험 구역을 피해 계산한 길'),
              if (hasSea)
                row(line(Colors.teal.shade700, dotted: true), '청록 점선', '바다 위에서 항구까지 바닷길'),
            ],
            // ---------------------------------------------------------------- 자세히 (기본은 접힘)
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(c).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const Key('legend-details'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: const Text('범례 자세히', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                subtitle: const Text('센서·묶음 표시, 판단 근거와 출처', style: TextStyle(fontSize: 12)),
                children: [
                  if (hasAreas) ...[
                    section('판단 근거·범위·출처'),
                    if (visible.contains(HazardKind.flood))
                      row(fill(_floodColor('경계')), '침수',
                          '수위계·맨홀 측정값(포항 디지털 트윈) 기준, 센서 주변 반경 100~500m. 서버 위험 판정 단계이며 실측 수심 구간이 아님'),
                    if (visible.contains(HazardKind.slide))
                      row(fill(_slideColor), '산사태',
                          '호우 특보(기상청) × 산사태 취약지역 100m'),
                  ],
                  if (visible.contains(HazardKind.flood)) ...[
                    section('수위계·센서'),
                    row(
                        Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(color: _floodColor('경계'), width: 2)),
                            child: Icon(Icons.water_drop, size: 14, color: _floodColor('경계'))),
                        '물방울',
                        '침수 판정의 원인 센서(수위계·맨홀) 실제 위치 = 침수 원의 중심. 색 = 단계, 누르면 측정값'),
                  ],
                  if (visible.contains(HazardKind.wind)) ...[
                    section('바람 기준'),
                    row(icon(Icons.navigation, _windColor(10, 10)), '주의', '강풍주의보 기준 아래'),
                    row(icon(Icons.navigation, _windColor(14, 14)), '경계', '강풍주의보 기준 이상'),
                    row(icon(Icons.navigation, _windColor(21, 21)), '심각', '강풍경보 기준 이상'),
                  ],
                  section('표식 더 보기'),
                  if (showFacilities) row(facilityMark, '숫자 원', '가까운 시설 묶음 — 누르면 그곳으로 확대'),
                  if (!routeMode && showPlaces)
                    row(icon(Icons.home, _riskColor('정상')), '등록한 집·직장', '색 = 그 장소의 위험 단계'),
                  row(icon(Icons.my_location, _riskColor('정상')), '현위치 색',
                      '정상 → 주의 → 경계 → 심각'),
                  if (hasDestination) row(icon(Icons.local_hospital, Colors.blue.shade800), '목적지 십자', '고른 곳이 병원이면 십자 표시'),
                  if (hidesTownWide) ...[
                    section('지도에 칠하지 않는 기상특보'),
                    row(icon(Icons.visibility_off_outlined, Colors.black54), '호우·강풍 특보',
                        '구룡포읍 전체에 내려져 화면을 다 덮으므로 칠하지 않음 — 위쪽 특보 카드로 확인'),
                  ],
                  if (showRoute)
                    row(line(Colors.blue.shade800), '경로 경고',
                        '위험 구역을 다 피하지 못한 경로는 지도 아래에 빨간 경고를 바로 띄웁니다'),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

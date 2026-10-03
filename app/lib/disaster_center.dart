import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';

import 'services/account_service.dart';
import 'services/geocoding_service.dart';
import 'models/domain_models.dart';

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

class DemoGrid {
  const DemoGrid(this.id, this.point, this.depth, this.time);
  final String id, time;
  final LatLng point;
  final double depth;
}

const demoGrids = <DemoGrid>[
  DemoGrid('C-01', LatLng(35.9817, 129.5495), 0, '13:40'),
  DemoGrid('C-02', LatLng(35.9817, 129.5510), .1, '13:40'),
  DemoGrid('C-03', LatLng(35.9817, 129.5525), .2, '13:40'),
  DemoGrid('C-04', LatLng(35.9831, 129.5495), .3, '13:40'),
  DemoGrid('C-05', LatLng(35.9831, 129.5510), .4, '13:40'),
  DemoGrid('C-06', LatLng(35.9831, 129.5525), .6, '13:40'),
];

Color _floodColor(double d) => Color.lerp(
  Colors.lightBlue.shade300,
  Colors.red.shade800,
  (d / .6).clamp(0.0, 1.0),
)!;
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
IconData _hazardIcon(HazardKind k) => switch (k) {
  HazardKind.flood => Icons.flood,
  HazardKind.wind => Icons.air,
  HazardKind.slide => Icons.terrain,
  HazardKind.overlap => Icons.warning_amber_rounded,
  HazardKind.storm => Icons.cyclone,
};

class DisasterDashboard extends StatefulWidget {
  const DisasterDashboard({super.key});
  @override
  State<DisasterDashboard> createState() => _DisasterDashboardState();
}

class _DisasterDashboardState extends State<DisasterDashboard> {
  bool compositeView = true;
  final activeLayers = <HazardKind>{
    HazardKind.flood,
    HazardKind.wind,
    HazardKind.slide,
    HazardKind.overlap,
  };
  DemoHazard? selected;
  LatLng focus = guryongpo;
  final MapController mapController = MapController();
  late final MapOptions mapOptions = MapOptions(
    initialCenter: guryongpo,
    initialZoom: 13.3,
  );

  void choose(String value) {
    if (value == '태풍') {
      context.push('/typhoon', extra: 'local');
      return;
    }
    setState(() {
      selected = null;
      compositeView = true;
      activeLayers
        ..clear()
        ..addAll({
          HazardKind.flood,
          HazardKind.wind,
          HazardKind.slide,
          HazardKind.overlap,
        });
      focus = guryongpo;
    });
    mapController.move(guryongpo, 13.3);
  }

  void toggleLayer(HazardKind layer, bool on) => setState(() {
    compositeView = false;
    if (on) {
      activeLayers.add(layer);
    } else {
      activeLayers.remove(layer);
    }
  });

  void focusOn(LatLng point) {
    setState(() => focus = point);
    mapController.move(point, 15);
  }

  @override
  Widget build(BuildContext context) {
    final visible = activeLayers;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '긴급 재난 종합',
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
        const _DemoBanner(),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _riskCard(context, demoHazards[0]),
            _riskCard(context, demoHazards[1]),
            _riskCard(context, demoHazards[2]),
            _riskCard(context, demoHazards[3]),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ActionChip(
              avatar: const Icon(Icons.dashboard_outlined, size: 18),
              label: const Text('긴급 재난 종합'),
              onPressed: () => choose('긴급 재난 종합'),
            ),
            ActionChip(
              avatar: const Icon(Icons.cyclone, size: 18),
              label: const Text('태풍'),
              onPressed: () => choose('태풍'),
            ),
            FilterChip(
              label: const Text('침수 격자'),
              selected: visible.contains(HazardKind.flood),
              onSelected: (on) => toggleLayer(HazardKind.flood, on),
            ),
            FilterChip(
              label: const Text('강풍 화살표·풍속'),
              selected: visible.contains(HazardKind.wind),
              onSelected: (on) => toggleLayer(HazardKind.wind, on),
            ),
            FilterChip(
              label: const Text('산사태 위험'),
              selected: visible.contains(HazardKind.slide),
              onSelected: (on) => toggleLayer(HazardKind.slide, on),
            ),
          ],
        ),
        const SizedBox(height: 8),
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
                    polygons: [
                      for (final g in demoGrids.where((g) => g.depth > 0))
                        Polygon(
                          points: [
                            LatLng(
                              g.point.latitude - .00055,
                              g.point.longitude - .0006,
                            ),
                            LatLng(
                              g.point.latitude - .00055,
                              g.point.longitude + .0006,
                            ),
                            LatLng(
                              g.point.latitude + .00055,
                              g.point.longitude + .0006,
                            ),
                            LatLng(
                              g.point.latitude + .00055,
                              g.point.longitude - .0006,
                            ),
                          ],
                          color: _floodColor(g.depth).withValues(alpha: .6),
                          borderColor: Colors.white,
                          borderStrokeWidth: 1,
                          label: '${g.id} · ${(g.depth * 100).round()}cm',
                        ),
                    ],
                  ),
                if (visible.contains(HazardKind.wind))
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: const [
                          LatLng(35.987, 129.558),
                          LatLng(35.987, 129.567),
                          LatLng(35.990, 129.570),
                        ],
                        color: Colors.deepOrange,
                        strokeWidth: 9,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (visible.contains(HazardKind.flood))
                      for (final g in demoGrids.where((g) => g.depth > 0))
                        Marker(
                          point: g.point,
                          width: 45,
                          height: 45,
                          child: GestureDetector(
                            onTap: () => _showGrid(context, g),
                            child: Icon(
                              Icons.water_drop,
                              color: _floodColor(g.depth),
                              size: 22,
                            ),
                          ),
                        ),
                    if (visible.contains(HazardKind.wind))
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
                                  angle:
                                      (w.$3 == '북동풍' ? 225 : 270) *
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
                    if (visible.contains(HazardKind.slide))
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
                    if (visible.contains(HazardKind.overlap))
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
                              h.kind != HazardKind.overlap &&
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
                    Marker(
                      point: guryongpo,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.teal,
                        size: 24,
                      ),
                    ),
                  ],
                ),
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
                          Text(compositeView ? '지도 범례' : '침수·산사태', style: const TextStyle(fontWeight: FontWeight.bold)),
                          if (compositeView) ...const [
                            Text('재난 표식은 영향 위치', style: TextStyle(fontSize: 11)),
                            Text('바람 화살표는 불어가는 방향·풍속', style: TextStyle(fontSize: 11)),
                          ],
                          if (!compositeView && visible.contains(HazardKind.flood)) ...const [
                            Text('침수 격자 색은 관측 수심 비교용', style: TextStyle(fontSize: 11)),
                            Text('단계 경계가 아닌 수심(cm) 표시', style: TextStyle(fontSize: 10)),
                          ],
                          if (!compositeView && visible.contains(HazardKind.slide))
                            const Text('산사태 표식은 목업 알림 위치입니다.', style: TextStyle(fontSize: 11)),
                          const Text('가상 시연 데이터', style: TextStyle(fontSize: 10)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!compositeView && visible.contains(HazardKind.wind))
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Text('강풍 범례', style: TextStyle(fontWeight: FontWeight.bold)),
                            Text('화살표: 불어가는 방향', style: TextStyle(fontSize: 11)),
                            Text('색·크기: 풍속', style: TextStyle(fontSize: 11)),
                            Text('주의보: 평균 14m/s 또는 순간 20m/s', style: TextStyle(fontSize: 10)),
                            Text('경보: 평균 21m/s 또는 순간 26m/s', style: TextStyle(fontSize: 10)),
                            Text('기준: 기상청 · 예시 관측값', style: TextStyle(fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (visible.contains(HazardKind.slide))
          Card(
            child: ListTile(
              leading: const Icon(Icons.terrain, color: Colors.brown),
              title: const Text('산림청 산사태 위험지도(2025)'),
              subtitle: const Text('위험등급 1~5 · 1등급이 가장 높음 · 현재 목업 지도에는 등급 격자 미포함'),
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
        _SavedPlaceSummary(onFocus: (p) => focusOn(p)),
        const SizedBox(height: 8),
        const Text(
          '실시간 정보 · 각 지점은 서로 다른 측정 위치의 가상 자료',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const _RealtimeCards(),
        const SizedBox(height: 20),
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
}

void _showHazard(BuildContext c, DemoHazard h) => showModalBottomSheet<void>(
  context: c,
  showDragHandle: true,
  builder: (_) =>
      _detailSheet(c, h.name, h.summary, h.time, h.guide, '위험 안내 목업 데이터 · 실제 발생 정보 아님'),
);
void _showGrid(BuildContext c, DemoGrid g) => showModalBottomSheet<void>(
  context: c,
  showDragHandle: true,
  builder: (context) => _detailSheet(
    context,
    '침수 관측 그리드 ${g.id}',
    '침수 관측 수심 ${(g.depth * 100).round()}cm',
    g.time,
    '침수된 도로와 지하 공간에 진입하지 마세요.',
    '침수 관측(가상 목업 데이터) · 수심 구간 기준 없음',
  ),
);
void _showWind(
  BuildContext c,
  LatLng p,
  double speed,
  String from,
) => showModalBottomSheet<void>(
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
Widget _detailSheet(
  BuildContext context,
  String title,
  String summary,
  String time,
  String guide,
  String source,
) => SafeArea(
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
  const _SavedPlaceSummary({required this.onFocus});
  final ValueChanged<LatLng> onFocus;
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
              guryongpo,
              '강풍 영향 시연 구역 인근',
              Icons.my_location,
            ),
            if (home != null)
              _placeTile(
                c,
                profile['homeName'] ?? '집',
                home,
                '저지대 침수 경고(가상)',
                Icons.home,
              ),
            if (work != null)
              _placeTile(
                c,
                profile['workName'] ?? '직장',
                work,
                '강풍 경고(가상)',
                Icons.business,
              ),
            ...places.map(
              (p) => _placeTile(
                c,
                p.name,
                p.position,
                '등록 장소 · 가상 위험 요약',
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
    String summary,
    IconData icon,
  ) => SizedBox(
    width: 235,
    child: Card(
      child: ListTile(
        onTap: () {
          widget.onFocus(p);
          _placeDetail(c, title, p, summary);
        },
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(
          '$summary\n눌러 지도 이동·상세 보기',
          style: const TextStyle(fontSize: 11),
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.open_in_full, size: 16),
      ),
    ),
  );
}

LatLng? _position(Map<String, String> p, String key) {
  final a = double.tryParse(p['${key}Lat'] ?? '');
  final b = double.tryParse(p['${key}Lon'] ?? '');
  return a == null || b == null ? null : LatLng(a, b);
}

void _placeDetail(
  BuildContext c,
  String name,
  LatLng p,
  String risk,
) => showDialog<void>(
  context: c,
  builder: (ctx) => AlertDialog(
    title: Text(name),
    content: Text(
      '주소: ${name == '현위치' ? '구룡포 시연 중심' : '저장한 주소'}\n위치: ${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}\n위험 요약: $risk\n특이사항: 가상 시연 정보',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
    ],
  ),
);

class _RealtimeCards extends StatelessWidget {
  const _RealtimeCards();
  @override
  Widget build(BuildContext c) => Column(
    children: [
      _metric('🌧️', '강수', '시간당 32mm · 누적 118mm', '구룡포 강수 시연지점 · mm', '14:00', [
        5,
        7,
        12,
        18,
        25,
        32,
      ]),
      _metric(
        '💨',
        '바람',
        '평균 21m/s · 순간최대 30m/s · 북동풍',
        '해안 시연지점 A · m/s · 풍향은 불어오는 방향',
        '14:00',
        [7, 8, 10, 14, 17, 21],
      ),
      _metric('🌊', '파고', '유의파고 3.2m · 최대파고 4.8m', '해상 시연지점 · m', '14:00', [
        1,
        1.3,
        1.8,
        2.2,
        2.7,
        3.2,
      ]),
      _metric(
        '〰️',
        '수위',
        '현재 2.4m · 최근 1시간 +0.3m',
        '수위 시연지점 · m · 침수 깊이와 별도 지표',
        '14:00',
        [1.7, 1.8, 1.9, 2.0, 2.2, 2.4],
      ),
    ],
  );
}

Widget _metric(
  String icon,
  String title,
  String value,
  String location,
  String time,
  List<double> data,
) => Card(
  child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(time),
          ],
        ),
        Text(value),
        Text('$location · $demoTime', style: const TextStyle(fontSize: 10)),
        SizedBox(
          height: 48,
          width: double.infinity,
          child: CustomPaint(painter: _SparkPainter(data)),
        ),
      ],
    ),
  ),
);

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce(math.min),
        maxV = values.reduce(math.max),
        range = (maxV - minV) == 0 ? 1 : maxV - minV;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final p = Offset(
        i * size.width / (values.length - 1),
        size.height - (values[i] - minV) / range * size.height,
      );
      if (i == 0)
        path.moveTo(p.dx, p.dy);
      else
        path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.teal
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < values.length; i++) {
      final p = Offset(
        i * size.width / (values.length - 1),
        size.height - (values[i] - minV) / range * size.height,
      );
      canvas.drawCircle(p, 3, Paint()..color = Colors.teal);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.values != values;
}

class TyphoonScreen extends StatefulWidget {
  const TyphoonScreen({super.key, this.initialLocal = false});
  final bool initialLocal;
  @override
  State<TyphoonScreen> createState() => _TyphoonScreenState();
}

class _TyphoonScreenState extends State<TyphoonScreen> {
  late bool local;
  final MapController mapController = MapController();
  late final MapOptions mapOptions;
  @override
  void initState() {
    super.initState();
    local = widget.initialLocal;
    mapOptions = MapOptions(
      initialCenter: local ? guryongpo : const LatLng(35.0, 130.0),
      initialZoom: local ? 7.5 : 5.1,
    );
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
  Widget build(BuildContext c) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '태풍 정보',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const _DemoBanner(),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('태풍 전체')),
            ButtonSegment(value: true, label: Text('구룡포 지역 위주')),
          ],
          selected: {local},
          onSelectionChanged: (v) {
            final next = v.first;
            setState(() => local = next);
            mapController.move(
              next ? guryongpo : const LatLng(35.0, 130.0),
              next ? 7.5 : 5.1,
            );
          },
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 440,
          child: FlutterMap(
            mapController: mapController,
            options: mapOptions,
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'guryongpo.safety.demo',
              ),
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
                      height: 42,
                      child: Column(
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
                          Text(times[i], style: const TextStyle(fontSize: 8)),
                        ],
                      ),
                    ),
                  Marker(
                    point: guryongpo,
                    width: 60,
                    height: 40,
                    child: const Column(
                      children: [
                        Icon(Icons.home, color: Colors.teal),
                        Text('구룡포', style: TextStyle(fontSize: 9)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('가상 태풍 DEMO'),
            subtitle: Text(
              '최대풍속 35m/s · 북북동진 25km/h · 영향반경 150km\n${local ? '구룡포 해안 시연구역 A가 현재 가상 강풍 영향반경 안에 있습니다.' : '과거 실선 · 예측 점선 · 반경 원은 강풍 영향 반경입니다.'}\n구룡포 최근접/영향 예상: 서비스 계산 시연값 14:00 (기상청 발표값 아님)\n${demoTime}',
            ),
            isThreeLine: true,
          ),
        ),
        const Text(
          '실제 KMA 자료 연결 전입니다. 태풍 이름·경로·반경·시각은 전부 시연용 가상값이며 공식 발표 시각을 표시하지 않습니다.',
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
  const _WeatherBulletins();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 10),
      const Text('기상 특보', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      Card(
        child: ListTile(
          leading: const Icon(Icons.warning_amber_rounded, color: Colors.deepOrange),
          title: const Text('호우주의보 · 예시 데이터'),
          subtitle: const Text(
            '대상: 포항시 남구 구룡포읍\n발표: 오늘 13:00 (가상) · 유효: 오늘 18:00까지 (가상)\n기준 안내: 3시간 60mm 또는 12시간 110mm 이상 예상',
          ),
          isThreeLine: true,
        ),
      ),
      const Text('기상 예보', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
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
        child: Text('출처: 기상청 기준을 참고한 화면 검토용 목업. 실제 발표 정보가 아닙니다.', style: TextStyle(fontSize: 11)),
      ),
    ],
  );
}

class AlertHubScreen extends StatefulWidget {
  const AlertHubScreen({super.key});
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

  @override
  Widget build(BuildContext c) {
    final jobs = (profile['jobs'] ?? '')
        .split('|')
        .where((e) => e.isNotEmpty)
        .toList();
    final personal = <(String, String, String, String, String)>[];
    if ((profile['homeAddress'] ?? '').isNotEmpty)
      personal.add((
        '집 주변 침수 위험',
        '등록한 집 주변 저지대에 침수가 발생할 수 있는 상황을 가정한 목업 경고입니다.',
        profile['homeAddress']!,
        '오늘 14:00 (가상)',
        '사용자 등록 주소 · 침수 경고 목업',
      ));
    if ((profile['workAddress'] ?? '').isNotEmpty)
      personal.add((
        '등록 장소 주변 강풍',
        '등록한 장소 주변 강풍 영향을 가정한 목업 경고입니다.',
        profile['workAddress']!,
        '오늘 14:00 (가상)',
        '사용자 등록 주소 · 강풍 경고 목업',
      ));
    if (jobs.isNotEmpty)
      for (final j in jobs) {
        personal.add((
          '직업 맞춤 기상 대비',
          switch (j) {
            '어업 종사자·뱃사람' => '강한 바람과 높은 파도 가능성을 가정했습니다. 조업을 자제하고 출항 전 통제를 확인하세요.',
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
            leading: const Icon(Icons.personal_injury, color: Colors.deepOrange),
            title: Text(warning.$1),
            subtitle: const Text('목업 경고 · 눌러 상세 정보 보기'),
            children: [
              ListTile(title: const Text('경고 이유'), subtitle: Text(warning.$2)),
              ListTile(title: const Text('영향 위치'), subtitle: Text(warning.$3)),
              ListTile(title: const Text('영향 시각'), subtitle: Text(warning.$4)),
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

class RecoveryScreen extends StatelessWidget {
  const RecoveryScreen({super.key});
  @override
  Widget build(BuildContext c) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        '지원 및 복구',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      const _DemoBanner(),
      const Text(
        '아래 내용은 메뉴 동작을 위한 가상 안내입니다. 실재 제도·대상·금액·지급 가능성으로 해석하지 말고 관할 기관에 확인하세요.',
      ),
      for (final x in const [
        ('피해 신고·복구', '피해 사진과 발생 시각을 기록하고 지방자치단체 재난 담당 창구에 신청 절차를 확인하세요.'),
        ('농업', '농작물·농업시설 피해 지원을 가정한 가상 안내. 실제 대상과 재해보험 약관 확인 필요.'),
        ('축산업', '축사·가축 피해 지원을 가정한 가상 안내. 피해 조사와 가입 계약 확인 필요.'),
        ('어업', '어선·어구 피해 지원을 가정한 가상 안내. 등록 상태와 피해 조사 확인 필요.'),
        ('양식업', '양식시설·수산생물 피해 지원을 가정한 가상 안내. 양식장 등록·보험 약관 확인 필요.'),
        ('보험 안내', '보험 가입 여부·보장 범위·보험금 지급 가능성은 앱에서 확정하지 않습니다. 계약서와 보험사에 확인하세요.'),
      ])
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.handyman_outlined),
            title: Text(x.$1),
            subtitle: const Text('가상 안내 · 실제 지원 제도와 다를 수 있음'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('${x.$2}\n신청·문의: 관할 지자체 또는 가입 보험사에 자격과 서류를 확인하세요.'),
              ),
            ],
          ),
        ),
    ],
  );
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
    ])
      fields[k] = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final p = await AccountService().optionalProfile();
    for (final e in fields.entries) e.value.text = p[e.key] ?? '';
    jobs.addAll((p['jobs'] ?? '').split('|').where((x) => x.isNotEmpty));
    transport = p['transport'] ?? '도보';
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    if (!(form.currentState?.validate() ?? false)) return;
    final p = <String, String>{
      for (final e in fields.entries) e.key: e.value.text.trim(),
      'transport': transport,
      'jobs': jobs.join('|'),
    };
    await AccountService().saveOptionalProfile(p);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('프로필을 기기에 저장했습니다.')));
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
                  await _save();
                } on GeocodingException catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
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
    await _save();
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
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                    decoration: const InputDecoration(labelText: '기본 이동 수단'),
                    items: const ['도보', '휠체어', '자동차']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
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
                          onSelected: (v) =>
                              setState(() => v ? jobs.add(j) : jobs.remove(j)),
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
                            '${k == 'home'
                                ? '집'
                                : k == 'work'
                                ? '직장'
                                : '출발 위치'} 수정',
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
                    initialValue: '현재 위치',
                    decoration: const InputDecoration(labelText: '출발 위치 방식'),
                    items: const ['현재 위치', '직접 지정']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (x) {
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
  @override
  void dispose() {
    for (final x in fields.values) x.dispose();
    super.dispose();
  }
}

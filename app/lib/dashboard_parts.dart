import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'main.dart';
import 'models/domain_models.dart';
import 'repositories/remote_repository.dart' show RemoteError;
import 'services/app_config.dart';
import 'services/voice_service.dart';
import 'services/account_service.dart';

Color riskColor(String level) => switch (level) {
      '주의' || 'advisory' || 'watch' => const Color(0xffe7ac16),
      '경계' || 'warning' => const Color(0xffe56717),
      '심각' || 'critical' => const Color(0xffd93232),
      _ => const Color(0xff718096)
    };

List<Polygon> floodGridPolygons(List<FloodGrid> grids,
        {bool severeOnly = false}) =>
    [
      for (final g in grids)
        if (g.hasRisk && (!severeOnly || g.level == '심각') || !severeOnly)
          Polygon(
              points: [
                LatLng(g.south, g.west),
                LatLng(g.south, g.east),
                LatLng(g.north, g.east),
                LatLng(g.north, g.west)
              ],
              color: g.hasRisk && (!severeOnly || g.level == '심각')
                  ? riskColor(g.level).withValues(alpha: .24)
                  : Colors.transparent,
              borderColor: Colors.blueGrey.withValues(alpha: .24),
              borderStrokeWidth: .35),
    ];

/// 서버 위험 영역(/risk/areas) → 지도 폴리곤. 단계 색은 침수 그리드와 같은 기준
List<Polygon> riskAreaPolygons(List<RiskArea> areas) => [
      for (final a in areas)
        for (final ring in a.polygons)
          Polygon(
              points: ring,
              color: riskColor(a.level == '관심' ? '주의' : a.level)
                  .withValues(alpha: .35),
              borderColor: riskColor(a.level == '관심' ? '주의' : a.level),
              borderStrokeWidth: 1.5,
              label: a.label)
    ];

class FloodGridLegend extends StatelessWidget {
  const FloodGridLegend({super.key});
  @override
  Widget build(BuildContext context) => Positioned(
      right: 12,
      bottom: 58,
      child: Material(
          color: Colors.white.withValues(alpha: .90),
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
              width: 178,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('침수 위험도',
                            style: TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 8),
                        ...const [
                          ('주의', '서버 판정 주의 단계'),
                          ('경계', '서버 판정 경계 단계'),
                          ('심각', '서버 판정 심각 단계')
                        ].map((x) => Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                      width: 13,
                                      height: 20,
                                      decoration: BoxDecoration(
                                          color: riskColor(x.$1)
                                              .withValues(alpha: .7),
                                          borderRadius:
                                              BorderRadius.circular(3))),
                                  const SizedBox(width: 7),
                                  Expanded(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        Text(x.$1,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12)),
                                        Text(x.$2,
                                            style:
                                                const TextStyle(fontSize: 10))
                                      ]))
                                ]))),
                        const Text('색은 앱 표시용 위험 단계이며 수심 구간 기준이 아닙니다.',
                            style: TextStyle(fontSize: 9)),
                      ])))));
}

/// "음성으로 듣기": audio(음성 질문의 답 음성)가 있으면 그것을, 없으면 text를 ai /api/tts로 합성해 재생 (B5)
class VoiceButton extends ConsumerStatefulWidget {
  const VoiceButton({super.key, required this.text, this.audio});
  final String text;
  final Uint8List? audio;
  @override
  ConsumerState<VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends ConsumerState<VoiceButton> {
  bool playing = false, preparing = false;

  Future<void> toggle() async {
    if (playing || preparing) {
      await VoicePlayer.instance.stop();
      if (mounted) setState(() => playing = preparing = false);
      return;
    }
    setState(() => preparing = true);
    final mp3 = widget.audio ?? await ref.read(repo).speak(widget.text);
    if (!mounted || !preparing) return;
    if (mp3 == null) {
      setState(() => preparing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          AppConfig.isRemote ? '음성 기능을 지금 쓸 수 없습니다. 잠시 후 다시 시도해 주세요.' : '예시 모드에서는 음성을 재생하지 않습니다.')));
      return;
    }
    setState(() { preparing = false; playing = true; });
    try {
      await VoicePlayer.instance.play(mp3);
    } catch (_) {}
    if (mounted) setState(() => playing = false);
  }

  @override Widget build(BuildContext context) => Tooltip(
    message: '${ref.watch(voiceLanguage)} 음성 안내',
    child: TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: playing ? Colors.red : null),
      onPressed: toggle,
      icon: preparing
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(playing ? Icons.stop_circle_outlined : Icons.volume_up_outlined),
      label: Text(preparing ? '음성 준비 중' : playing ? '재생 중지' : '음성으로 듣기', overflow: TextOverflow.ellipsis),
    ),
  );
}

/// AI 답 아래 "지도에서 경로 보기" 버튼
class RouteButton extends StatelessWidget {
  const RouteButton({super.key, required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: const Icon(Icons.map_outlined),
          label: const Text('지도에서 경로 보기')));
}

class ServiceMap extends StatelessWidget {
  const ServiceMap({super.key});
  @override
  Widget build(BuildContext context) => const MapCard(height: 470);
}

class RouteMap extends ConsumerStatefulWidget {
  const RouteMap({super.key, required this.facilityId});
  final String facilityId;

  @override
  ConsumerState<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends ConsumerState<RouteMap> {
  final mapController = MapController();
  final mapOptions = const MapOptions();
  String? fittedBounds;

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final facility = routeDestination(ref, widget.facilityId);
    final routeType = ref.watch(routeKind);
    final routeAsync = ref.watch(routeProvider(widget.facilityId));
    final route = routeAsync.valueOrNull;
    final loading = routeAsync.isLoading;
    final current = ref.watch(userLocation).position;
    if (facility == null || route == null) {
      return Card(
          child: SizedBox(
              height: 470,
              child: Center(
                  child: routeAsync.hasError
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('${routeAsync.error}',
                                  textAlign: TextAlign.center)),
                          FilledButton(
                              onPressed: () => ref
                                  .invalidate(routeProvider(widget.facilityId)),
                              child: const Text('다시 시도')),
                          TextButton(
                              onPressed: () => ref
                                  .read(routeFacilityId.notifier)
                                  .state = null,
                              child: const Text('경로 안내 종료'))
                        ])
                      : const Column(mainAxisSize: MainAxisSize.min, children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 10),
                          Text('안전 경로를 준비하고 있습니다')
                        ]))));
    }
    final bounds = LatLngBounds.fromPoints([current, ...route.polylinePoints]);
    final boundsKey = '${bounds.northWest}:${bounds.southEast}';
    if (fittedBounds != boundsKey) {
      fittedBounds = boundsKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          mapController.fitCamera(
            CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(54)),
          );
        }
      });
    }
    final warn = shelterExclusion(
        facility, ref.watch(riskAreasProvider).valueOrNull ?? const []);
    return Card(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
            height: 470,
            child: Column(children: [
              Expanded(
                  child: FlutterMap(
                mapController: mapController,
                options: mapOptions,
                children: [
                  TileLayer(
                      urlTemplate:
                          'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                      subdomains: const ['a', 'b', 'c'],
                      userAgentPackageName: 'com.example.guryongpo_safety'),
                  if (AppConfig.isRemote)
                    PolygonLayer(
                        polygons: riskAreaPolygons(
                            ref.watch(riskAreasProvider).valueOrNull ??
                                const []))
                  else
                    PolygonLayer(polygons: floodGridPolygons(demoFloodGrid(0))),
                  PolylineLayer(polylines: [
                    Polyline(
                        points: route.polylinePoints,
                        color: Colors.white,
                        strokeWidth: 10),
                    Polyline(
                        points: route.polylinePoints,
                        color: Colors.blue.shade700,
                        strokeWidth: 6),
                    if (!AppConfig.isRemote)
                      Polyline(points: const [
                        LatLng(35.9911, 129.5520),
                        LatLng(35.9919, 129.5530)
                      ], color: Colors.red.shade200, strokeWidth: 8)
                  ]),
                  MarkerLayer(markers: [
                    Marker(
                        point: current,
                        width: 44,
                        height: 44,
                        child: Icon(Icons.my_location,
                            color: Colors.blue, size: 34)),
                    Marker(
                        point: facility.position,
                        width: 150,
                        height: 64,
                        child: Column(children: [
                          const Icon(Icons.location_on,
                              color: Colors.teal, size: 40),
                          Container(
                              color: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(facility.name.replaceAll(' (예시)', ''),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)))
                        ]))
                  ]),
                  if (!AppConfig.isRemote) const FloodGridLegend(),
                  if (loading)
                    const Positioned.fill(
                        child: ColoredBox(
                            color: Color(0x88000000),
                            child: Center(
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                  CircularProgressIndicator(
                                      color: Colors.white),
                                  SizedBox(height: 10),
                                  Text('안전 경로를 준비하고 있습니다',
                                      style: TextStyle(color: Colors.white))
                                ])))),
                ],
              )),
              Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                          child: Text(
                              '${warn != null ? '⚠ $warn — 다른 대피소를 먼저 확인하세요\n' : ''}${routeType == RouteType.nearest ? '최단 시간 우선 · 확인된 위험 구역 회피' : '안전·접근성 우선 · 확인된 위험 구역 회피'} · ${AppConfig.dataLabel}\n${facility.name} · ${(route.distanceMeters / 1000).toStringAsFixed(1)}km · 도보 ${route.estimatedMinutes}분\n${route.riskAvoidanceSummary}',
                              style: const TextStyle(fontSize: 12))),
                      IconButton(
                          tooltip: '경로 안내 종료',
                          onPressed: () =>
                              ref.read(routeFacilityId.notifier).state = null,
                          icon: const Icon(Icons.close))
                    ]),
                    Wrap(spacing: 4, runSpacing: 4, children: [
                      TextButton.icon(
                          onPressed: () => showModalBottomSheet<void>(
                              context: context,
                              showDragHandle: true,
                              builder: (_) => const ShelterPickerSheet()),
                          icon: const Icon(Icons.place_outlined),
                          label: const Text('다른 시설 선택')),
                      FilledButton.tonal(
                          style: FilledButton.styleFrom(
                              backgroundColor: routeType == RouteType.nearest
                                  ? const Color(0xff16803c)
                                  : Colors.grey.shade100,
                              foregroundColor: routeType == RouteType.nearest
                                  ? Colors.white
                                  : Colors.black87),
                          onPressed: () => startRouteToShelter(ref, facility.id,
                              routeType: RouteType.nearest),
                          child: const Text('가까운 경로')),
                      FilledButton.tonal(
                          style: FilledButton.styleFrom(
                              backgroundColor: routeType == RouteType.safest
                                  ? const Color(0xff16803c)
                                  : Colors.grey.shade100,
                              foregroundColor: routeType == RouteType.safest
                                  ? Colors.white
                                  : Colors.black87),
                          onPressed: () => startRouteToShelter(ref, facility.id,
                              routeType: RouteType.safest),
                          child: const Text('안전 경로')),
                    ])
                  ])),
            ])));
  }
}

class ShelterPickerSheet extends ConsumerWidget {
  const ShelterPickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routeType = ref.watch(routeKind);
    final areas =
        ref.watch(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
    return SafeArea(
        child: ListView(shrinkWrap: true, children: [
      const ListTile(
          title: Text('대피소·의료시설 선택'),
          subtitle: Text('선택하면 현재 대시보드 지도에서 새 경로를 바로 표시합니다.')),
      // 걸어서 갈 만한 곳만 (의료시설은 5km 안), 갈 만한 대피소 먼저. 거리는 경로 계산 전 대략값
      ...([...?ref.watch(facilitiesProvider).valueOrNull]
              .where((f) => f.type == FacilityType.shelter || f.distanceKm <= 5)
              .toList()
            ..sort((a, b) {
              final ua = shelterExclusion(a, areas) == null ? 0 : 1,
                  ub = shelterExclusion(b, areas) == null ? 0 : 1;
              return ua != ub ? ua - ub : a.distanceKm.compareTo(b.distanceKm);
            }))
          .map((facility) {
        final warn = shelterExclusion(facility, areas);
        final label = warn ??
            (routeType == RouteType.safest ? '가장 안전한 경로' : '가까운 대피소 경로');
        return ListTile(
            leading: Icon(
                warn != null
                    ? Icons.warning_amber_rounded
                    : facility.type == FacilityType.shelter
                        ? Icons.home_work_outlined
                        : Icons.local_hospital,
                color: warn != null ? Colors.orange.shade800 : null),
            title: Text(facility.name),
            subtitle: Text(
                '약 ${facility.distanceKm}km · 도보 ${facility.walkMinutes}분 · $label'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final messenger = ScaffoldMessenger.of(context);
              startRouteToShelter(ref, facility.id, routeType: routeType);
              Navigator.pop(context);
              messenger.showSnackBar(
                  SnackBar(content: Text('${facility.name} 경로를 표시합니다.')));
            });
      })
    ]));
  }
}

class ModeCards extends ConsumerWidget {
  const ModeCards({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(children: [
        // 등록 장소 위험은 장소 등록(/user/places, A5) 연결 전이라 목업에서만 보인다
        if (!AppConfig.isRemote) ...const [
          PlaceRiskSummary(),
          SizedBox(height: 12)
        ],
        const AlertCards(), const SizedBox(height: 12),
        const SupportCard(),
        Card(
            child: ListTile(
                leading: const Icon(Icons.directions_walk),
                title: const Text('안전한 대피 안내'),
                subtitle: Text(risk.guide),
                trailing: VoiceButton(text: risk.guide),
                onTap: () => startRouteToShelter(ref, nearestShelterId(ref))))
      ]);
}

class PlaceRiskSummary extends StatelessWidget {
  const PlaceRiskSummary({super.key});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.place_outlined),
              SizedBox(width: 7),
              Text('등록 장소 위험 요약',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
              Spacer(),
              Text('10:42 갱신', style: TextStyle(fontSize: 11))
            ]),
            const SizedBox(height: 10),
            const Wrap(spacing: 10, runSpacing: 10, children: [
              _PlaceTile(
                  icon: Icons.my_location,
                  name: '현재 위치',
                  level: '경계',
                  depth: '18cm',
                  guide: '고지대 방향 이동 권고'),
              _PlaceTile(
                  icon: Icons.home,
                  name: '집',
                  level: '주의',
                  depth: '8cm',
                  guide: '배수 상태 확인'),
              _PlaceTile(
                  icon: Icons.business,
                  name: '직장',
                  level: '안전',
                  depth: '2cm',
                  guide: '특이사항 없음')
            ])
          ])));
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile(
      {required this.icon,
      required this.name,
      required this.level,
      required this.depth,
      required this.guide});
  final IconData icon;
  final String name, level, depth, guide;
  @override
  Widget build(BuildContext c) {
    final color = riskColor(level);
    return SizedBox(
        width: 210,
        child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: color.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withValues(alpha: .3))),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: color),
                const SizedBox(width: 6),
                Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle))
              ]),
              const SizedBox(height: 7),
              Row(children: [
                Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                        color: color, borderRadius: BorderRadius.circular(20)),
                    child: Text(level,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                const SizedBox(width: 7),
                Text('예상 $depth')
              ]),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                  value: level == '경계'
                      ? .62
                      : level == '주의'
                          ? .35
                          : .12,
                  color: color,
                  backgroundColor: color.withValues(alpha: .15)),
              const SizedBox(height: 5),
              Text(guide, style: const TextStyle(fontSize: 11))
            ])));
  }
}

class AlertCards extends ConsumerWidget {
  const AlertCards({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => AppConfig.isRemote
      ? _live(ref)
      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('선제 경고 알림',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...const [
            (
              '09:20',
              '구룡포항 북측',
              '경계',
              '해안 저지대 침수 확대 가능성',
              '차량 이동 자제 및 고지대 이동 권고',
              '09:15'
            ),
            (
              '10:05',
              '구룡포 시장 인근',
              '주의',
              '배수로 수위 상승',
              '상가 지하층 및 배수 시설 점검 권고',
              '10:00'
            ),
            (
              '10:30',
              '병포리 해안도로',
              '심각',
              '도로 일부 침수 진행',
              '해당 구간 진입 금지 및 우회 경로 이용',
              '10:25'
            )
          ].map((a) {
            final color = riskColor(a.$3);
            return Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(width: 4, height: 72, color: color),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Row(children: [
                                  Text(a.$1,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(a.$2,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold))),
                                  Chip(
                                      label: Text(a.$3),
                                      backgroundColor:
                                          color.withValues(alpha: .14),
                                      labelStyle:
                                          TextStyle(color: color, fontSize: 11))
                                ]),
                                Text(a.$4),
                                const SizedBox(height: 3),
                                Text(a.$5,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12)),
                                Text('${a.$6} 업데이트',
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.black54))
                              ]))
                        ])));
          })
        ]);

  /// 실시간 위험 판정 항목 (/risk items)
  Widget _live(WidgetRef ref) {
    final alerts = ref.watch(alertsProvider).valueOrNull ?? const <AlertItem>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('선제 경고 알림',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if (alerts.isEmpty)
        const Card(
            child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('현재 위치 주변에 발효 중인 경고가 없습니다'))),
      ...alerts.map((a) {
        final color = riskColor(a.level == '관심' ? '주의' : a.level);
        return Card(
            child: ListTile(
                leading: Container(width: 4, height: 40, color: color),
                title: Text(a.title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('${a.summary}\n${a.guide}'),
                isThreeLine: true,
                trailing: Text(a.time, style: const TextStyle(fontSize: 11))));
      }),
    ]);
  }
}

class SupportCard extends StatefulWidget {
  const SupportCard({super.key});
  @override
  State<SupportCard> createState() => _SupportCardState();
}

class _SupportCardState extends State<SupportCard> {
  Set<String> jobs = {};
  @override
  void initState() {
    super.initState();
    AccountService().optionalProfile().then((profile) {
      if (mounted)
        setState(() => jobs = (profile['jobs'] ?? '')
            .split('|')
            .where((x) => x.isNotEmpty)
            .toSet());
    });
  }

  @override
  Widget build(BuildContext context) {
    const support = <String, (IconData, String, List<(String, String)>)>{
      '농업 종사자': (
        Icons.agriculture,
        '농업 지원·복구',
        [
          ('농작물 피해', '피해 구역과 작물 상태를 촬영하고 발생 시각을 기록하세요.'),
          ('농업시설', '비닐하우스·관개·배수시설 손상을 기록하고 안전 확인 후 복구를 시작하세요.'),
          ('신청 확인', '관할 지자체와 농업 관련 기관에 실제 지원 요건을 확인하세요.')
        ]
      ),
      '축산업 종사자': (
        Icons.pets,
        '축산업 지원·복구',
        [
          ('축사·가축 피해', '가축 수와 시설 피해를 기록하고 안전한 장소로 이동시키세요.'),
          ('시설 점검', '배수·전력·환기·비상전원을 확인하세요.'),
          ('신청 확인', '관할 지자체와 축산 관련 기관에 실제 지원 요건을 확인하세요.')
        ]
      ),
      '어업 종사자·뱃사람': (
        Icons.sailing,
        '어업 지원·복구',
        [
          ('어선·어구 피해', '피해 사진과 선박·어구 정보를 기록하세요.'),
          ('안전 확인', '항만 통제와 출항 제한을 확인하고 안전 통보 전에는 출항하지 마세요.'),
          ('신청 확인', '관할 지자체와 수산 관련 기관에 실제 지원 요건을 확인하세요.')
        ]
      ),
      '양식업 종사자·수산물 양식': (
        Icons.waves,
        '양식업 지원·복구',
        [
          ('양식시설 피해', '시설과 수산생물 피해를 기록하세요.'),
          ('긴급 점검', '전력·산소공급·취수시설을 확인하고 안전 지침을 따르세요.'),
          ('신청 확인', '관할 지자체와 수산 관련 기관에 실제 지원 요건을 확인하세요.')
        ]
      ),
      '자영업자': (
        Icons.store,
        '사업장 지원·복구',
        [
          ('사업장 피해', '침수·시설 피해를 촬영하고 영업 중단 시각을 기록하세요.'),
          ('안전 조치', '전기·가스는 안전이 확인된 후 점검하세요.'),
          ('신청 확인', '관할 지자체와 소상공인 지원 기관에 실제 지원 요건을 확인하세요.')
        ]
      ),
    };
    final selected = jobs
        .map((j) => support[j])
        .whereType<(IconData, String, List<(String, String)>)>();
    if (selected.isEmpty)
      return const Card(
          child: ListTile(
              leading: Icon(Icons.handyman_outlined),
              title: Text('지원 및 복구 안내'),
              subtitle: Text('프로필에서 직업 분야를 선택하면 해당 분야의 안내를 표시합니다.')));
    return Column(children: [
      for (final entry in selected)
        Card(
            child: ExpansionTile(
          leading: Icon(entry.$1, color: const Color(0xff16803c)),
          title: Text(entry.$2),
          subtitle: const Text('목업 안내 · 실제 자격과 지원 범위는 기관 확인 필요'),
          children: [
            for (final item in entry.$3) _Detail(item.$1, item.$2),
            const _Detail('공통 절차', '피해 사진·발생 시각을 기록하고 관할 기관에 신청 절차를 확인하세요.')
          ],
        ))
    ]);
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.title, this.text);
  final String title, text;
  @override
  Widget build(BuildContext c) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.check_circle, color: Color(0xff16803c), size: 17),
        const SizedBox(width: 7),
        Expanded(
            child: Text('$title\n$text', style: const TextStyle(fontSize: 12)))
      ]));
}

class AiPanel extends ConsumerStatefulWidget {
  const AiPanel({super.key, required this.risk});
  final RiskStatus risk;
  @override
  ConsumerState<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends ConsumerState<AiPanel> {
  final input = TextEditingController();
  final scroll = ScrollController();
  bool loading = false, recording = false;
  VoiceRecorder? recorder;

  void scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients)
          scroll.animateTo(scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      });

  void addMessages(List<ChatMessage> m) =>
      ref.read(chatMessages.notifier).state = [...ref.read(chatMessages), ...m];

  /// 마이크: 누르면 녹음 시작, 다시 누르면(또는 28초가 지나면) 서버로 보내 받아쓴 질문·답을 보여 주고 답 음성을 바로 재생
  Future<void> toggleMic() async {
    if (loading) return;
    if (recording) return finishVoice();
    await VoicePlayer.instance.stop();
    recorder ??= VoiceRecorder();
    final ok = await recorder!.start(onLimit: finishVoice);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('마이크 권한이 필요합니다. 브라우저·기기 설정에서 허용해 주세요.')));
      return;
    }
    setState(() => recording = true);
  }

  Future<void> finishVoice() async {
    if (!recording) return;
    setState(() { recording = false; loading = true; });
    final wav = await recorder!.stop();
    if (wav == null) {
      if (mounted) setState(() => loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('녹음이 너무 짧습니다. 버튼을 누르고 말씀한 뒤 다시 눌러 주세요.')));
      return;
    }
    ChatAnswer? answer;
    try {
      final v = await ref.read(repo).askVoice(wav, UserMode.user, ref.read(userLocation).position);
      answer = v.answer;
      if (mounted) addMessages([ChatMessage('🎤 ${v.transcript}', true), ChatMessage(v.answer.text, false, answer: v.answer)]);
    } catch (e) {
      if (mounted) addMessages([ChatMessage(e is RemoteError ? e.message : '음성 질문을 처리하지 못했습니다. 다시 시도해 주세요.', false)]);
    }
    if (mounted) setState(() => loading = false);
    scrollToEnd();
    if (answer?.audio != null) {
      try {
        await VoicePlayer.instance.play(answer!.audio!);
      } catch (_) {}
    }
  }

  Future<void> ask(String question) async {
    if (question.trim().isEmpty) return;
    ref.read(chatMessages.notifier).state = [
      ...ref.read(chatMessages),
      ChatMessage(question, true)
    ];
    setState(() => loading = true);
    final answer = await ref
        .read(repo)
        .ask(question, UserMode.user, ref.read(userLocation).position);
    const personaGuide = '사용자 예시 안내: 등록한 장소와 현재 위치를 확인하고 안전한 실내로 이동하세요.';
    if (mounted)
      ref.read(chatMessages.notifier).state = [
        ...ref.read(chatMessages),
        ChatMessage(
            AppConfig.isRemote
                ? answer.text
                : '${answer.text}\n$personaGuide\n예시 AI 안내',
            false,
            answer: answer)
      ];
    if (mounted) setState(() => loading = false);
    scrollToEnd();
  }

  @override
  Widget build(BuildContext context) => Card(
      child: SizedBox(
          height: 470,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text('사용자 AI 대화 · ${AppConfig.dataLabel}')),
            Wrap(
                spacing: 4,
                children: [
                  '지금 침수 위험이 있어?',
                  '대피할 때 무엇을 조심해야 해?',
                  '오늘 생활 안전 정보는?',
                  '오늘 미세먼지 상태는 어때?',
                  '오늘 자외선이 높은가요?'
                ]
                    .map((q) =>
                        ActionChip(label: Text(q), onPressed: () => ask(q)))
                    .toList()),
            Expanded(child: Builder(builder: (_) {
              final messages = ref.watch(chatMessages);
              return ListView(
                  controller: scroll,
                  children: messages.isEmpty
                      ? [
                          const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('예시 질문을 선택하거나 질문을 입력하세요.'))
                        ]
                  : [...messages
                          .map((m) => Align(
                              alignment: m.mine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                  margin: const EdgeInsets.all(6),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                      color: m.mine
                                          ? Colors.teal.shade100
                                          : Colors.grey.shade200,
                                      borderRadius: BorderRadius.circular(12)),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(m.text),
                                    if (m.answer?.route != null) RouteButton(onPressed: () => showAiRoute(ref, m.answer!)),
                                    if (!m.mine) VoiceButton(text: m.answer?.voiceText ?? m.text, audio: m.answer?.audio)]))))
                          .toList(), if (loading) const Padding(padding: EdgeInsets.all(10), child: _FloodChatLoader())]);
            })),
            Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(
                      child: TextField(
                          controller: input,
                          onSubmitted: ask,
                          decoration: const InputDecoration(
                              hintText: '질문 입력',
                              border: OutlineInputBorder()))),
                  IconButton(
                      tooltip: recording ? '말하기 끝' : '음성으로 질문',
                      onPressed: loading && !recording ? null : toggleMic,
                      color: recording ? Colors.red : null,
                      icon: Icon(recording ? Icons.stop_circle : Icons.mic)),
                  IconButton(
                      onPressed: () {
                        ask(input.text);
                        input.clear();
                      },
                      icon: const Icon(Icons.send))
                ])),
            if (recording)
              const Padding(padding: EdgeInsets.only(left: 12, bottom: 8),
                  child: Text('듣고 있어요… 말씀이 끝나면 빨간 버튼을 눌러 주세요.', style: TextStyle(color: Colors.red, fontSize: 12))),
          ])));
  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    recorder?.dispose();
    super.dispose();
  }
}

class _FloodChatLoader extends StatelessWidget {
  const _FloodChatLoader();
  @override
  Widget build(BuildContext c) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.waves, color: Color(0xff16803c)),
        const SizedBox(width: 7),
        const Text('침수 정보를 분석하고 있습니다.', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 7),
        SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xff16803c)))
      ]);
}

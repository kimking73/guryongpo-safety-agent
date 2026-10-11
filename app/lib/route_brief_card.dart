import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'main.dart';
import 'models/domain_models.dart';
import 'origin_picker.dart';
import 'services/app_config.dart';
import 'services/demo_mode.dart';
import 'ui/gk_theme.dart';

/// AI 경로 설명 (2026-10-11 사용자 요청): 지도에 그린 경로의 주의할 점·위험 요소.
/// AI 서버 `/api/ai/route-brief` 가 경로 값 + 출발·도착 지점 위험 + 특보·비·바람으로 쓴다 (대화 그래프를 거치지 않는 가벼운 호출).
class RouteBrief {
  const RouteBrief({required this.summary, this.cautions = const [], this.hazards = const [], this.note = '', this.fromAi = true});
  final String summary, note;
  final List<String> cautions, hazards;

  /// false 면 AI 서버에 닿지 못해 앱이 경로 값으로 만든 문장
  final bool fromAi;

  factory RouteBrief.fromJson(Map<String, dynamic> j) => RouteBrief(
      summary: '${j['summary'] ?? ''}',
      cautions: [for (final c in j['cautions'] as List? ?? const []) '$c'],
      hazards: [for (final h in j['hazards'] as List? ?? const []) '$h'],
      note: '${j['note'] ?? ''}');

  /// 서버 없이(예시 모드·연결 실패) 경로 값으로 만든 설명
  factory RouteBrief.local(SafetyRoute r, String destination) => RouteBrief(
        fromAi: false,
        summary: '$destination까지 ${r.distanceMeters}m, ${r.mode == TravelMode.car ? '차로' : '걸어서'} 약 ${r.estimatedMinutes}분입니다.',
        hazards: [
          if (r.stillInside.isNotEmpty) '다른 길이 없어 위험 구역을 지납니다: ${r.stillInside.toSet().join(', ')}',
          if (!r.hazardsOk) '위험 구역 정보를 확인하지 못해, 위험 구역을 피하지 않고 계산한 경로입니다.',
        ],
        cautions: [
          if (r.mode == TravelMode.walk && r.steepUpMeters >= 20)
            '급한 오르막이 ${r.steepUpMeters}m 있습니다 (가장 급한 곳 ${r.maxUphillPercent}%).',
          if (r.mode == TravelMode.walk && r.stepsMeters >= 20) '계단이 ${r.stepsMeters}m 있습니다.',
        ],
      );
}

/// 서버 없이(예시 모드·연결 실패) 요청 값으로 만든 설명 — 해상 경로·방문 경로용
RouteBrief localBriefOfBody(Map<String, dynamic> body) {
  final r = body['route'] as Map?, sea = body['sea'] as Map?, visits = body['visits'] as Map?;
  final how = r?['mode'] == 'car' ? '차로' : '걸어서';
  final land = r == null ? '' : '${r['distance_m']}m, $how 약 ${((r['duration_s'] as num? ?? 0) / 60).ceil()}분입니다.';
  final dest = (body['destination'] as Map?)?['name'] ?? '도착지';
  final String summary;
  if (visits != null) {
    summary = '${visits['stops']}곳을 모두 도는 길은 $land';
  } else if (sea != null) {
    final dir = '${sea['bearing_label'] ?? ''}';
    summary = '${dir.isEmpty ? '' : '$dir '}${sea['port_name']}까지 바닷길 ${sea['distance_m']}m입니다.'
        '${r == null ? '' : ' 항구에서 $dest까지 $land'}';
  } else {
    summary = '$dest까지 $land';
  }
  final inside = (r?['still_inside'] as List? ?? const []).length + (visits?['blocked_zones'] as List? ?? const []).length;
  return RouteBrief(fromAi: false, summary: summary, hazards: [
    if (inside > 0) '다른 길이 없어 위험 구역 $inside곳을 지납니다.',
    if (r != null && r['hazards_ok'] == false) '위험 구역 정보를 확인하지 못해, 위험 구역을 피하지 않고 계산한 경로입니다.',
  ], cautions: [
    if (sea != null && sea['direct'] == false && sea['path_found'] != false) '바닷길은 곶·방파제를 돌아서 들어갑니다. 지도의 파란 점선을 따라가세요.',
    if (sea != null && sea['path_found'] == false) '바닷길을 찾지 못해 지도에 선이 없습니다. 방향만 참고하세요.',
  ]);
}

/// 경로 서버 응답(육상 구간)에서 설명에 쓰는 값만
Map<String, dynamic> _landFacts(Map land, String mode) => {
      'distance_m': (land['distance_m'] as num? ?? 0).round(),
      'duration_s': (land['duration_s'] as num? ?? 0).round(),
      for (final k in const ['ascend_m', 'max_uphill_pct', 'steps_m', 'steep_up_m', 'very_steep_up_m'])
        if (land[k] is num) k: (land[k] as num).round(),
      'avoided': [for (final z in land['avoided'] as List? ?? const []) '$z'],
      'still_inside': [for (final z in land['still_inside'] as List? ?? const []) '$z'],
      'hazards_ok': land['hazards_ok'] != false,
      'mode': mode,
      if (land['profile'] is String) 'profile': land['profile'],
      'geometry': '${land['geometry'] ?? ''}',
    };

/// 해상 경로(/api/route/sea 응답) → 설명 요청. 바닷길도 육상 경로도 없으면 null
Map<String, dynamic>? seaBriefBody(Map<String, dynamic> raw, double lat, double lon) {
  final leg = raw['sea_leg'] as Map?, port = raw['port'] as Map?, land = raw['land_route'] as Map?;
  final dest = raw['destination'] as Map?;
  final sea = raw['at_sea'] == true && leg != null && port != null;
  if (!sea && land == null) return null;
  final end = dest ?? (port?['berth'] as Map?) ?? const {};
  return {
    'origin': {'lat': lat, 'lon': lon, 'name': sea ? '배 위치' : '현위치'},
    'destination': {
      'lat': end['lat'] ?? lat,
      'lon': end['lon'] ?? end['lng'] ?? lon,
      'name': '${dest?['name'] ?? (sea ? port['name'] : '도착지')}',
    },
    if (land != null) 'route': _landFacts(land, 'walk'),
    if (sea)
      'sea': {
        'port_name': '${port['name']}',
        'distance_m': (leg['distance_m'] as num? ?? 0).round(),
        'bearing_label': '${leg['bearing_label'] ?? ''}',
        'direct': leg['direct'] != false,
        'path_found': leg['path_found'] != false,
      },
    if (DemoData.on) 'demo': true,
  };
}

/// 방재단 방문 경로(/api/route/visits 응답에서 고른 shortest·priority) → 설명 요청
Map<String, dynamic>? visitBriefBody(Map<String, dynamic> result, String tab, double lat, double lon, String originName,
    {double? endLat, double? endLon}) {
  final plan = result[tab] as Map?;
  final stops = (plan?['order'] as List? ?? const []).length;
  if (plan == null || stops == 0) return null;
  return {
    'origin': {'lat': lat, 'lon': lon, 'name': originName},
    'destination': {'lat': endLat ?? lat, 'lon': endLon ?? lon, 'name': '마지막 방문지'},
    'route': _landFacts({...plan, 'hazards_ok': result['hazards_ok']}, '${result['mode'] ?? 'walk'}'),
    'visits': {
      'stops': stops,
      'by_priority': tab == 'priority',
      'blocked_zones': [for (final z in result['blocked_zones'] as List? ?? const []) '$z'],
    },
    if (DemoData.on) 'demo': true,
  };
}

/// 요청 값(JSON 글자)으로 받는 설명 — 해상 경로·방문 경로처럼 routeProvider 밖에서 그린 경로용. 같은 경로면 다시 부르지 않는다
final routeBriefByBody = FutureProvider.family<RouteBrief?, String>((ref, json) async {
  final body = Map<String, dynamic>.from(jsonDecode(json) as Map);
  if (!AppConfig.isRemote) return localBriefOfBody(body);
  try {
    final r = await routeBriefDio.post<Map<String, dynamic>>('/api/ai/route-brief', data: body);
    return RouteBrief.fromJson(r.data!);
  } on DioException {
    return localBriefOfBody(body);
  }
});

/// 테스트에서 바꿔 끼운다
Dio routeBriefDio = Dio(BaseOptions(
    baseUrl: AppConfig.aiBaseUrl, connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 20)));

/// 경로 서버 요청의 strategy 와 같은 이름 (AI 서버가 '경로 방식' 근거로 쓴다)
String _strategy(RouteType t) => switch (t) {
      RouteType.nearest => 'shortest',
      RouteType.safest => 'safest',
      RouteType.flat => 'flat',
      RouteType.uphill => 'uphill',
    };

/// 지금 지도에 그린 경로(routeFacilityId)의 설명. 경로가 바뀌면 다시 받는다. 바닷길이 섞인 경로는 설명하지 않는다 (null)
final routeBriefProvider = FutureProvider.family<RouteBrief?, String>((ref, id) async {
  final route = await ref.watch(routeProvider(id).future);
  if (route.polylinePoints.length < 2 || route.seaPoints.isNotEmpty) return null;
  final snap = ref.watch(routeFacilitySnapshot);
  final placeName = id == aiRouteId
      ? (ref.watch(aiRoute)?.destinationName ?? '도착지')
      : (snap?.id == id
          ? snap!.name
          : (ref.watch(facilitiesProvider).valueOrNull ?? const <Facility>[]).where((f) => f.id == id).firstOrNull?.name ??
              '도착지');
  final here = ref.watch(originLabelProvider) ?? '현위치';
  final reversed = id != customRouteId && id != aiRouteId && ref.watch(routeReversed);
  final originName = reversed ? placeName : here, destName = reversed ? here : placeName;
  if (!AppConfig.isRemote) return RouteBrief.local(route, destName);
  final o = route.polylinePoints.first, d = route.polylinePoints.last;
  try {
    final r = await routeBriefDio.post<Map<String, dynamic>>('/api/ai/route-brief', data: {
      'origin': {'lat': o.latitude, 'lon': o.longitude, 'name': originName},
      'destination': {'lat': d.latitude, 'lon': d.longitude, 'name': destName},
      'route': {
        'distance_m': route.distanceMeters,
        'duration_s': route.estimatedMinutes * 60,
        'ascend_m': route.ascendMeters,
        'max_uphill_pct': route.maxUphillPercent,
        'steps_m': route.stepsMeters,
        'steep_up_m': route.steepUpMeters,
        'very_steep_up_m': route.verySteepUpMeters,
        // 앱은 구역 id 를 이미 이름으로 바꿔 들고 있다 → 이름 그대로 보낸다
        'avoided': route.avoided,
        'still_inside': route.stillInside,
        'hazards_ok': route.hazardsOk,
        'mode': route.mode == TravelMode.car ? 'car' : 'walk',
        'strategy': _strategy(route.routeType),
        'profile': route.profile,
        'geometry': route.encodedGeometry ?? '',
      },
      if (DemoData.on) 'demo': true,
    });
    return RouteBrief.fromJson(r.data!);
  } on DioException {
    return RouteBrief.local(route, destName);
  }
});

/// 지도 오른쪽 위에 겹쳐 놓는 칸. 접을 수 있고, 좁은 화면은 접힌 채로 시작한다.
/// 지도에 그리는 경로 모두에 쓴다 (2026-10-11 사용자 요청): [body] 가 없으면 대시보드에서 고른 경로(routeFacilityId),
/// 있으면 그 요청 값의 경로(해상 경로 seaBriefBody, 방재단 방문 경로 visitBriefBody)
class RouteBriefCard extends ConsumerStatefulWidget {
  const RouteBriefCard({super.key, required this.maxWidth, this.startCollapsed = false, this.body});
  final double maxWidth;
  final bool startCollapsed;
  final Map<String, dynamic>? body;

  @override
  ConsumerState<RouteBriefCard> createState() => _RouteBriefCardState();
}

class _RouteBriefCardState extends ConsumerState<RouteBriefCard> {
  late bool open = !widget.startCollapsed;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<RouteBrief?> async;
    if (widget.body != null) {
      async = ref.watch(routeBriefByBody(jsonEncode(widget.body)));
    } else {
      final id = ref.watch(routeFacilityId);
      if (id == null) return const SizedBox.shrink();
      async = ref.watch(routeBriefProvider(id));
    }
    final brief = async.valueOrNull;
    if (!async.isLoading && brief == null) return const SizedBox.shrink();
    final danger = brief?.hazards.isNotEmpty ?? false;
    final header = InkWell(
      onTap: () => setState(() => open = !open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome_rounded, size: 18, color: danger ? GK.red : GK.navy),
          const SizedBox(width: 6),
          Flexible(
              child: Text('AI 경로 설명',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: GK.ink))),
          if (danger && !open) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: GK.redTint, borderRadius: BorderRadius.circular(999)),
              child: Text('위험 ${brief!.hazards.length}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: GK.redDeep)),
            ),
          ],
          const SizedBox(width: 4),
          Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: GK.muted),
        ]),
      ),
    );
    Widget lines(String title, List<String> items, Color color, IconData icon) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color)),
            for (final t in items)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 14, color: color)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(t,
                          style: const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: GK.ink))),
                ]),
              ),
          ],
        );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: brief == null
          ? const Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Flexible(child: Text('이 경로를 살펴보는 중…', style: TextStyle(fontSize: 13, color: GK.muted))),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(brief.summary,
                  style: const TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w700, color: GK.ink)),
              if (brief.hazards.isNotEmpty) lines('위험한 요소', brief.hazards, GK.redDeep, Icons.warning_amber_rounded),
              if (brief.cautions.isNotEmpty) lines('주의할 점', brief.cautions, GK.orangeInk, Icons.info_outline_rounded),
              if (brief.hazards.isEmpty && brief.cautions.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('이 경로에서 따로 알릴 위험·주의 사항을 찾지 못했습니다.',
                      style: TextStyle(fontSize: 13, color: GK.muted)),
                ),
              if (brief.note.isNotEmpty || !brief.fromAi)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(brief.fromAi ? brief.note : 'AI 서버에 닿지 못해 경로 값만으로 만든 설명입니다.',
                      style: const TextStyle(fontSize: 11, height: 1.35, color: GK.muted)),
                ),
            ]),
    );
    return Semantics(
      container: true,
      label: 'AI 경로 설명',
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Material(
          color: Colors.white.withValues(alpha: .97),
          elevation: 3,
          shadowColor: const Color(0x3314245C),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: danger ? GK.red : GK.line, width: danger ? 2 : 1)),
          clipBehavior: Clip.antiAlias,
          // 스크롤 영역을 두지 않는다 — 항목은 최대 3 + 3줄이라 지도 안에 들어온다 (대시보드 안에 스크롤이 하나 더 생기면 화면 스크롤과 엉킨다)
          child: open
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [header, body])
              : header,
        ),
      ),
    );
  }
}

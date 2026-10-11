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

/// 지도 오른쪽 위에 겹쳐 놓는 칸. 접을 수 있고, 좁은 화면은 접힌 채로 시작한다
class RouteBriefCard extends ConsumerStatefulWidget {
  const RouteBriefCard({super.key, required this.maxWidth, this.startCollapsed = false});
  final double maxWidth;
  final bool startCollapsed;

  @override
  ConsumerState<RouteBriefCard> createState() => _RouteBriefCardState();
}

class _RouteBriefCardState extends ConsumerState<RouteBriefCard> {
  late bool open = !widget.startCollapsed;

  @override
  Widget build(BuildContext context) {
    final id = ref.watch(routeFacilityId);
    if (id == null) return const SizedBox.shrink();
    final async = ref.watch(routeBriefProvider(id));
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

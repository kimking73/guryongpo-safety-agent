import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'disaster_center.dart';
import 'main.dart';
import 'origin_picker.dart';
import 'services/demo_mode.dart';
import 'services/live_api.dart';

/// 실측 데이터 화면 (2026-10-05). 시연 모드를 끄면(기본) 이 화면들이, 켜면 disaster_center.dart·prototype_safety_screens.dart의
/// 가상 시나리오 화면이 나온다. 자료가 없으면 지어내지 않고 "자료 없음 · 사유"를 보여 준다.

final liveApiProvider = Provider<LiveApi>((_) => LiveApi());

/// 서버 맞춤 대시보드 (GET /api/v1/dashboard). 위치가 30m 넘게 바뀌면 다시 받는다. 새로고침은 ref.invalidate
final liveDashboardProvider = FutureProvider<Map<String, dynamic>>((ref) {
  final p = ref.watch(userLocation).position;
  return ref.watch(liveApiProvider).dashboard(p.latitude, p.longitude);
});

/// 시연 모드면 [demo], 아니면 [live]
class DemoSwitch extends ConsumerWidget {
  const DemoSwitch({super.key, required this.demo, required this.live});
  final Widget demo, live;
  @override
  Widget build(BuildContext c, WidgetRef ref) => ref.watch(showDemoProvider) ? demo : live;
}

/// 시연 모드에서만 쓰는 화면 (대피 확인 시연·음성 시연·해상 경로 데모)
class DemoOnlyNotice extends ConsumerWidget {
  const DemoOnlyNotice({super.key, required this.title, required this.demo});
  final String title;
  final Widget demo;
  @override
  Widget build(BuildContext c, WidgetRef ref) => ref.watch(showDemoProvider)
      ? demo
      : _Page(title: title, children: [
          const Card(
              child: ListTile(
                  leading: Icon(Icons.science_outlined),
                  title: Text('시연 모드에서만 볼 수 있는 화면입니다'),
                  subtitle: Text('가상 시나리오로 흐름을 보여 주는 화면이라 실측 모드에서는 숨깁니다. 프로필 → 시연 모드를 켜면 볼 수 있습니다.'))),
          if (title.contains('대피'))
            FilledButton.icon(
                onPressed: () => c.go('/alerts'),
                icon: const Icon(Icons.notifications_outlined),
                label: const Text('실제 경고·대피 확인 보기')),
        ]);
}

// ------------------------------------------------------------------ 공통 표시
const levelKo = {'normal': '정상', 'watch': '관심', 'advisory': '주의', 'warning': '경보', 'critical': '위험'};
const hazardKo = {
  'flood': '침수', 'heavy_rain': '호우', 'strong_wind': '강풍', 'typhoon': '태풍', 'landslide': '산사태', 'high_seas': '풍랑',
  'uv': '자외선', 'fine_dust': '미세먼지', 'ultrafine_dust': '초미세먼지',
};

Color levelColor(String? level) => switch (level) {
      'critical' => const Color(0xff9b1c1c),
      'warning' => const Color(0xffd93232),
      'advisory' => const Color(0xffe56717),
      'watch' => const Color(0xffc99a06),
      _ => const Color(0xff2e7d32),
    };

String hhmm(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (t == null) return '-';
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return t.year == now.year && t.month == now.month && t.day == now.day ? hm : '${t.month}/${t.day} $hm';
}

String _num(Object? v, [int digits = 1]) => v is num ? (v == v.roundToDouble() && digits > 0 ? v.toStringAsFixed(digits) : v.toStringAsFixed(digits)) : '-';

const _dirs = ['북', '북북동', '북동', '동북동', '동', '동남동', '남동', '남남동', '남', '남남서', '남서', '서남서', '서', '서북서', '북서', '북북서'];
String windFrom(Object? deg) => deg is num ? '${_dirs[((deg % 360) / 22.5).round() % 16]}풍' : '';

bool _available(Map<String, dynamic>? d) => d != null && d['available'] != false;

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children, this.onRefresh});
  final String title;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext c) {
    final list = ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
        if (onRefresh != null) IconButton(tooltip: '새로고침', onPressed: onRefresh, icon: const Icon(Icons.refresh)),
      ]),
      const SizedBox(height: 8),
      ...children,
      const SizedBox(height: 24),
    ]);
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class _NoData extends StatelessWidget {
  const _NoData(this.reason);
  final String reason;
  @override
  Widget build(BuildContext c) => Row(children: [
        Icon(Icons.info_outline, size: 16, color: Colors.grey.shade600),
        const SizedBox(width: 6),
        Expanded(child: Text('자료 없음 · $reason', style: TextStyle(color: Colors.grey.shade700))),
      ]);
}

class _LevelChip extends StatelessWidget {
  const _LevelChip(this.level);
  final String? level;
  @override
  Widget build(BuildContext c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: levelColor(level), borderRadius: BorderRadius.circular(10)),
      child: Text(levelKo[level] ?? '정상', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)));
}

/// 작은 추이 막대 (최근 값)
class _Spark extends StatelessWidget {
  const _Spark(this.series, {this.color = Colors.indigo});
  final List<dynamic> series;
  final Color color;
  @override
  Widget build(BuildContext c) {
    final vs = [for (final p in series) ((p as Map)['v'] as num?)?.toDouble() ?? 0.0];
    if (vs.length < 2) return const SizedBox.shrink();
    final top = vs.reduce(math.max);
    return SizedBox(
        height: 28,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final v in vs)
            Expanded(
                child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: .5),
                    height: top <= 0 ? 1 : math.max(1, 28 * v / top),
                    color: color.withValues(alpha: .55))),
        ]));
  }
}

// ------------------------------------------------------------------ 홈 (김다인 대시보드 UI에 넣는 실측 부분, 2026-10-05)
/// 실측 바람 화살표 (구룡포 AWS + 포항 DT 대기 센서): 관측소 레이어에서 wind_speed·wind_dir이 있는 지점
class WindPoint {
  const WindPoint(this.position, this.speed, this.dirDeg, this.name, {this.gust, this.observedAt});
  final LatLng position;
  final double speed;
  final double dirDeg;
  final double? gust;
  final String name;
  final String? observedAt;
}

final windPointsProvider = FutureProvider<List<WindPoint>>((ref) async {
  final fc = await ref.watch(liveApiProvider).stationsLayer();
  return [
    for (final f in fc['features'] as List? ?? const [])
      if (((f as Map)['properties'] as Map)['metrics'] case final Map m
          when m['wind_speed'] is num && m['wind_dir'] is num && f['properties']['stale'] != true)
        WindPoint(
            LatLng(((f['geometry'] as Map)['coordinates'] as List)[1].toDouble(), ((f['geometry'] as Map)['coordinates'] as List)[0].toDouble()),
            (m['wind_speed'] as num).toDouble(),
            (m['wind_dir'] as num).toDouble(),
            '${f['properties']['name']}',
            gust: (m['wind_gust'] as num?)?.toDouble(),
            observedAt: f['properties']['observed_at'] as String?),
  ];
});

/// 대시보드 위쪽: 판정 시각·출발 위치·바로가기·머리 배너
class LiveDashboardTop extends ConsumerWidget {
  const LiveDashboardTop({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final d = ref.watch(liveDashboardProvider).valueOrNull;
    final point = Map<String, dynamic>.from(d?['point_risk'] as Map? ?? const {});
    final headline = d?['headline'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
          d == null
              ? '실시간 정보를 불러오는 중…'
              : '실시간 데이터 · 위험 판정 ${hhmm(point['computed_at'])} 기준'
                  '${point['data_stale'] == true ? ' · 판정이 30분 넘게 갱신되지 않았습니다' : ''}',
          style: Theme.of(c).textTheme.bodySmall),
      if (ref.watch(liveDashboardProvider).hasError)
        Text('실시간 정보를 불러오지 못했습니다: ${liveError(ref.watch(liveDashboardProvider).error!)}',
            style: TextStyle(color: Theme.of(c).colorScheme.error)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 6, children: [
        const OriginChip(),
        ActionChip(avatar: const Icon(Icons.alt_route, size: 18), label: const Text('길찾기'), onPressed: () => c.push('/route-search')),
        ActionChip(avatar: const Icon(Icons.chat_bubble_outline, size: 18), label: const Text('AI 채팅'), onPressed: () => c.go('/ai')),
        ActionChip(
            avatar: const Icon(Icons.refresh, size: 18),
            label: const Text('새로고침'),
            onPressed: () {
              ref.invalidate(liveDashboardProvider);
              ref.invalidate(riskAreasProvider);
              ref.invalidate(floodGridProvider);
              ref.invalidate(windPointsProvider);
            }),
      ]),
      if (headline != null) ...[const SizedBox(height: 8), _Headline(headline: Map<String, dynamic>.from(headline))],
    ]);
  }
}

/// 서버 판정 위험 항목 (대시보드 위험 카드용)
List<Map<String, dynamic>> liveRiskItems(Map<String, dynamic>? dashboard) => [
      for (final i in (dashboard?['point_risk'] as Map?)?['items'] as List? ?? const []) Map<String, dynamic>.from(i as Map)
    ];

/// 대시보드 아래쪽 '실시간 정보': 김다인 디자인 카드(LiveRealtimeCards, disaster_center.dart)에 서버 위젯 값
class LiveRealtimeSection extends ConsumerWidget {
  const LiveRealtimeSection({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => ref.watch(liveDashboardProvider).when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Card(child: Padding(padding: const EdgeInsets.all(12), child: _NoData(liveError(e)))),
        data: (d) => LiveRealtimeCards(
            widgets: [for (final w in d['widgets'] as List? ?? const []) Map<String, dynamic>.from(w as Map)]),
      );
}

/// 태풍 정보 (실측): 김다인 TyphoonScreen 디자인 + 서버 typhoon 위젯
class LiveTyphoonRoute extends ConsumerWidget {
  const LiveTyphoonRoute({super.key, this.initialLocal = false});
  final bool initialLocal;
  @override
  Widget build(BuildContext c, WidgetRef ref) => ref.watch(liveDashboardProvider).when(
        loading: () => const DashboardLoading(),
        error: (e, _) => TyphoonScreen(
            key: const ValueKey('typhoon-error'),
            initialLocal: initialLocal,
            demo: false,
            live: {'available': false, 'reason': '태풍 정보를 불러오지 못했습니다 (${liveError(e)})'}),
        data: (d) {
          final t = Map<String, dynamic>.from(
              (d['widgets'] as List? ?? const []).cast<Map>().where((w) => w['type'] == 'typhoon').firstOrNull?['data'] as Map? ??
                  const {'available': false, 'reason': '현재 진행 중인 태풍이 없습니다'});
          return TyphoonScreen(
              key: ValueKey('typhoon-${t['code']}-${(t['current'] as Map?)?['t']}'), initialLocal: initialLocal, demo: false, live: t);
        },
      );
}

/// 선제 경고·알림 (실측): 김다인 AlertHubScreen 디자인 + 서버 특보·예보·재난문자·내 경고·위험 영역
class LiveAlertHubRoute extends ConsumerWidget {
  const LiveAlertHubRoute({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => AlertHubScreen(
        demo: false,
        dashboard: ref.watch(liveDashboardProvider).valueOrNull,
        alerts: ref.watch(alertCenterProvider).reversed.toList(),
        areas: ref.watch(riskAreasProvider).valueOrNull ?? const [],
      );
}

class _Headline extends ConsumerWidget {
  const _Headline({required this.headline});
  final Map<String, dynamic> headline;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final risk = Map<String, dynamic>.from(headline['risk'] as Map? ?? const {});
    final action = headline['action'];
    return Card(
        color: levelColor(risk['level'] as String?),
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 32),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${headline['title']}',
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                if (risk['reason'] != null) Text('${risk['reason']}', style: const TextStyle(color: Colors.white)),
              ])),
              if (action == 'open_route')
                TextButton(
                    onPressed: () => startRouteToShelter(ref, nearestShelterId(ref)),
                    child: const Text('대피 경로', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))
              else if (action == 'open_chat')
                TextButton(
                    onPressed: () => c.go('/ai'),
                    child: const Text('행동 요령', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
            ])));
  }
}

class LiveWidgetCard extends StatelessWidget {
  const LiveWidgetCard({super.key, required this.widget});
  final Map<String, dynamic> widget;

  static const _titles = {
    'warnings': ('기상특보', Icons.campaign_outlined),
    'rain': ('강수', Icons.water_drop_outlined),
    'wind': ('바람', Icons.air),
    'water_level': ('수위·침수 센서', Icons.waves),
    'wave': ('파고', Icons.tsunami_outlined),
    'typhoon': ('태풍', Icons.cyclone),
    'forecast': ('단기예보 (12시간)', Icons.wb_cloudy_outlined),
    'life_safety': ('자외선·미세먼지', Icons.wb_sunny_outlined),
    'disaster_messages': ('재난문자', Icons.sms_outlined),
    'checklist': ('준비 체크리스트', Icons.checklist),
  };

  @override
  Widget build(BuildContext c) {
    final type = '${widget['type']}';
    final d = Map<String, dynamic>.from(widget['data'] as Map? ?? const {});
    final (title, icon) = _titles[type] ?? (type, Icons.info_outline);
    final emphasized = widget['emphasized'] == true;
    return Card(
        shape: emphasized
            ? RoundedRectangleBorder(side: const BorderSide(color: Color(0xffd93232), width: 2), borderRadius: BorderRadius.circular(12))
            : null,
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 20),
                const SizedBox(width: 6),
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
                if (_available(d) && d['level'] != null) _LevelChip(d['level'] as String?),
              ]),
              const SizedBox(height: 6),
              if (!_available(d)) _NoData('${d['reason'] ?? '서버에 자료가 없습니다'}') else _body(c, type, d),
            ])));
  }

  Widget _body(BuildContext c, String type, Map<String, dynamic> d) {
    final small = Theme.of(c).textTheme.bodySmall;
    switch (type) {
      case 'warnings':
        final items = d['items'] as List? ?? const [];
        if (items.isEmpty) return const Text('발효 중인 기상특보가 없습니다.');
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final w in items)
            Text('• ${(w as Map)['label']} (${w['region_name']}) · ${hhmm(w['issued_at'])} 발표'),
          Text('출처: 기상청 특보', style: small),
        ]);
      case 'rain':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('1시간 ${_num(d['value'])}mm · 오늘 누적 ${_num(d['rain_day'])}mm · 12시간 ${_num(d['rain_12h'])}mm',
              style: const TextStyle(fontSize: 16)),
          _Spark(d['series'] as List? ?? const [], color: Colors.indigo),
          Text('${d['station_name']} · ${hhmm(d['observed_at'])} 관측', style: small),
        ]);
      case 'wind':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('평균 ${_num(d['value'])}m/s · 순간 ${_num(d['wind_gust'])}m/s · ${windFrom(d['wind_dir'])}',
              style: const TextStyle(fontSize: 16)),
          _Spark(d['series'] as List? ?? const [], color: Colors.deepOrange),
          Text('${d['station_name']} · ${hhmm(d['observed_at'])} 관측 · 주의보 평균 14m/s·순간 20m/s', style: small),
        ]);
      case 'water_level':
        final st = d['stations'] as List? ?? const [];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final s in st)
            Row(children: [
              Expanded(child: Text('${(s as Map)['station_name']}', overflow: TextOverflow.ellipsis)),
              Text(s['value'] == null ? '${s['source_level_label'] ?? '-'}' : '${_num(s['value'], 0)}${s['unit']}'),
              const SizedBox(width: 6),
              _LevelChip(s['level'] as String?),
            ]),
          Text('포항 디지털 트윈 · ${hhmm(d['observed_at'])} 수집', style: small),
        ]);
      case 'wave':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_num(d['value'])}m (예보)', style: const TextStyle(fontSize: 16)),
          _Spark(d['series'] as List? ?? const [], color: Colors.blue),
          Text('${d['station_name']} · ${hhmm(d['observed_at'])}부터 24시간 · 실측 파고는 수집하지 않습니다', style: small),
        ]);
      case 'typhoon':
        final cur = Map<String, dynamic>.from(d['current'] as Map? ?? const {});
        return InkWell(
            onTap: () => c.push('/typhoon'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d['name_ko'] ?? d['code']} · 구룡포에서 ${d['distance_km']}km', style: const TextStyle(fontSize: 16)),
              Text('예상 최근접 ${d['closest_km']}km (${hhmm(d['eta_closest'])}) · 최대풍속 ${_num(cur['max_wind_ms'], 0)}m/s'),
              Text('${d['source'] ?? '기상청'} · ${hhmm(cur['t'])} 분석 · 눌러서 경로 보기', style: small),
            ]));
      case 'forecast':
        final slots = d['slots'] as List? ?? const [];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              height: 92,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final s in slots)
                  Container(
                      width: 70,
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: Colors.blueGrey.withValues(alpha: .07), borderRadius: BorderRadius.circular(8)),
                      child: Column(children: [
                        Text(hhmm((s as Map)['t']).split(' ').last, style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('${_num(s['tmp'], 0)}℃'),
                        Text('${s['pty'] == '없음' ? '강수 ' : '${s['pty']} '}${s['pop'] ?? '-'}%', style: const TextStyle(fontSize: 11)),
                        Text('${_num(s['wsd'])}m/s', style: const TextStyle(fontSize: 11)),
                      ])),
              ])),
          Text('${d['source'] ?? '기상청 단기예보'}', style: small),
        ]);
      case 'life_safety':
        final items = d['items'] as List? ?? const [];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final i in items)
            Row(children: [
              Expanded(child: Text('${(i as Map)['label']} ${_num(i['value'], i['hazard'] == 'uv' ? 0 : 0)}${i['unit'] ?? ''}')),
              _LevelChip(i['level'] as String?),
            ]),
          if (items.isNotEmpty) Text('${(items.first as Map)['station_name']} 외 · ${hhmm((items.first as Map)['observed_at'])} 측정', style: small),
        ]);
      case 'disaster_messages':
        final items = d['items'] as List? ?? const [];
        if (items.isEmpty) return const Text('최근 24시간 재난문자가 없습니다.');
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final m in items) Text('• [${(m as Map)['sender'] ?? ''}] ${m['message']} (${hhmm(m['sent_at'])})'),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }
}


// ------------------------------------------------------------------ 복구 지원 (실측)
final supportProgramsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) => ref.watch(liveApiProvider).supportPrograms());
final hotlinesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) => ref.watch(liveApiProvider).hotlines());

class LiveRecoveryScreen extends ConsumerWidget {
  const LiveRecoveryScreen({super.key});
  static const _cat = {'insurance': '보험', 'recovery': '복구 지원', 'legal': '법률', 'fishery': '어업', 'livelihood': '생계'};
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final programs = ref.watch(supportProgramsProvider);
    final hot = ref.watch(hotlinesProvider);
    Future<void> refresh() async {
      ref.invalidate(supportProgramsProvider);
      ref.invalidate(hotlinesProvider);
    }

    return _Page(title: '복구 지원', onRefresh: refresh, children: [
      const Text('재난 뒤 신청할 수 있는 지원 제도와 연락처입니다. 실제 대상·기간은 담당 기관에 확인하세요.'),
      const SizedBox(height: 8),
      ...programs.when(
        loading: () => [const LinearProgressIndicator()],
        error: (e, _) => [_NoData(liveError(e))],
        data: (list) => list.isEmpty
            ? [const _NoData('등록된 지원 제도가 없습니다')]
            : [
                for (final p in list)
                  Card(
                      child: ExpansionTile(
                          leading: const Icon(Icons.volunteer_activism_outlined),
                          title: Text('${p['name']}'),
                          subtitle: Text('${_cat[p['category']] ?? p['category']} · ${p['summary']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p['summary']}'),
                            if (p['eligibility'] != null) Text('대상: ${p['eligibility']}'),
                            if (p['how_to_apply'] != null) Text('신청: ${p['how_to_apply']}'),
                            if (p['apply_period'] != null) Text('기간: ${p['apply_period']}'),
                            if (p['department'] != null) Text('담당: ${p['department']}${p['contact'] != null ? ' · ${p['contact']}' : ''}'),
                            if (p['url'] != null)
                              TextButton.icon(
                                  onPressed: () => launchUrl(Uri.parse('${p['url']}')),
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('안내 페이지')),
                          ])),
              ],
      ),
      const SizedBox(height: 12),
      const Text('긴급 연락처', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ...hot.when(
        loading: () => [const LinearProgressIndicator()],
        error: (e, _) => [_NoData(liveError(e))],
        data: (list) => [
          for (final h in list)
            Card(
                child: ListTile(
                    leading: const Icon(Icons.phone_outlined),
                    title: Text('${h['name']}'),
                    subtitle: h['note'] != null ? Text('${h['note']}') : null,
                    trailing: Text('${h['phone']}'),
                    onTap: () => launchUrl(Uri.parse('tel:${h['phone']}')))),
        ],
      ),
    ]);
  }
}

// ------------------------------------------------------------------ 방재단 (실측, 역할 필요)
final meProvider = FutureProvider<Map<String, dynamic>>((ref) => ref.watch(liveApiProvider).me());

class LiveResponderScreen extends ConsumerStatefulWidget {
  const LiveResponderScreen({super.key});
  @override
  ConsumerState<LiveResponderScreen> createState() => _LiveResponderScreenState();
}

class _LiveResponderScreenState extends ConsumerState<LiveResponderScreen> {
  Future<(Map<String, dynamic>, List<Map<String, dynamic>>, List<Map<String, dynamic>>)>? data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>, List<Map<String, dynamic>>)> _fetch() async {
    final api = ref.read(liveApiProvider);
    return (await api.adminOverview(), await api.adminIncidents(), await api.adminHouseholds());
  }

  void _load() => setState(() => data = _fetch());

  @override
  Widget build(BuildContext c) {
    final role = '${ref.watch(meProvider).valueOrNull?['role'] ?? 'resident'}';
    final staff = const {'responder', 'caregiver', 'admin'}.contains(role);
    if (!staff) {
      return _Page(title: '방재단 대시보드', children: const [
        Card(
            child: ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('방재단 역할이 필요합니다'),
                subtitle: Text('방재단·돌봄 담당자는 받은 초대 코드로 역할을 등록하세요.'))),
        RoleClaimCard(),
      ]);
    }
    return FutureBuilder(
        future: data,
        builder: (c, snap) {
          if (snap.hasError) return LoadError(message: liveError(snap.error!), onRetry: _load);
          if (!snap.hasData) return const DashboardLoading();
          final (ov, incidents, households) = snap.data!;
          final needs = Map<String, dynamic>.from(ov['needs_counts'] as Map? ?? const {});
          return _Page(title: '방재단 대시보드', onRefresh: () async => _load(), children: [
            Text('역할: $role · 실시간 대피 현황'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              Chip(label: Text('취약 가구 ${ov['households_total'] ?? households.length}')),
              Chip(label: Text('앱 사용 ${ov['with_app'] ?? '-'}')),
              for (final e in needs.entries) Chip(label: Text('${_need[e.key] ?? e.key} ${e.value}')),
            ]),
            const SizedBox(height: 10),
            const Text('진행 중인 대피 상황', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (incidents.isEmpty) const Card(child: ListTile(title: Text('진행 중인 대피 상황이 없습니다'))),
            for (final i in incidents)
              Card(
                  child: ListTile(
                      leading: CircleAvatar(backgroundColor: levelColor(i['level'] as String?), child: const Icon(Icons.campaign, color: Colors.white)),
                      title: Text('${i['title']}'),
                      subtitle: Text(_summary(Map<String, dynamic>.from(i['summary'] as Map? ?? const {})) + ' · ${hhmm(i['started_at'])} 시작'))),
            const SizedBox(height: 10),
            const Text('취약 가구', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (households.isEmpty) const Card(child: ListTile(title: Text('등록된 취약 가구가 없습니다'))),
            for (final h in households)
              Card(
                  child: ListTile(
                      leading: const Icon(Icons.home_outlined),
                      title: Text('${h['label']}'),
                      subtitle: Text([
                        if (h['address'] != null) '${h['address']}',
                        [for (final n in h['needs'] as List? ?? const []) _need[n] ?? n].join(', '),
                        if (h['landslide_zone'] != null) '⚠ ${h['landslide_zone']}',
                      ].where((x) => '$x'.isNotEmpty).join(' · ')),
                      trailing: h['phone'] != null
                          ? IconButton(icon: const Icon(Icons.phone), onPressed: () => launchUrl(Uri.parse('tel:${h['phone']}')))
                          : null)),
          ]);
        });
  }

  static String _summary(Map<String, dynamic> s) =>
      '대상 ${s['total'] ?? 0} · 대피 완료 ${s['evacuated'] ?? 0} · 대피 중 ${s['evacuating'] ?? 0} · 도움 필요 ${s['need_help'] ?? 0} · 무응답 ${s['no_response'] ?? 0}';
}

const _need = {
  'elderly': '고령', 'living_alone': '독거', 'mobility_limited': '거동 불편', 'wheelchair': '휠체어', 'bedridden': '와상',
  'hearing': '청각', 'vision': '시각', 'cognitive': '인지', 'medical_device': '의료기기', 'infant': '영유아', 'pet': '반려동물',
};

/// 초대 코드로 방재단·돌봄 역할 받기 (POST /user/role)
class RoleClaimCard extends ConsumerStatefulWidget {
  const RoleClaimCard({super.key});
  @override
  ConsumerState<RoleClaimCard> createState() => _RoleClaimCardState();
}

class _RoleClaimCardState extends ConsumerState<RoleClaimCard> {
  final code = TextEditingController();
  bool busy = false;
  String? message;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    setState(() => busy = true);
    try {
      final r = await ref.read(liveApiProvider).claimRole(code.text);
      ref.invalidate(meProvider);
      setState(() => message = '${r['label'] ?? r['role']} 역할을 받았습니다.');
    } catch (e) {
      setState(() => message = liveError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: code, decoration: const InputDecoration(labelText: '초대 코드', border: OutlineInputBorder())),
            const SizedBox(height: 8),
            FilledButton(onPressed: busy ? null : _claim, child: const Text('역할 받기')),
            if (message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!)),
          ])));
}

// ------------------------------------------------------------------ 내 취약 가구 등록 (실측)
class LiveHouseholdScreen extends ConsumerStatefulWidget {
  const LiveHouseholdScreen({super.key});
  @override
  ConsumerState<LiveHouseholdScreen> createState() => _LiveHouseholdScreenState();
}

class _LiveHouseholdScreenState extends ConsumerState<LiveHouseholdScreen> {
  final label = TextEditingController(), phone = TextEditingController(), note = TextEditingController();
  final needs = <String>{};
  int members = 1;
  bool consent = false, busy = false, loaded = false, registered = false;
  String? message;

  @override
  void initState() {
    super.initState();
    ref.read(liveApiProvider).myHousehold().then((h) {
      if (!mounted) return;
      setState(() {
        loaded = true;
        if (h == null) return;
        registered = true;
        label.text = '${h['label'] ?? ''}';
        phone.text = '${h['phone'] ?? ''}';
        note.text = '${h['note'] ?? ''}';
        members = (h['members'] as num?)?.toInt() ?? 1;
        needs.addAll([for (final n in h['needs'] as List? ?? const []) '$n']);
        consent = true;
      });
    }).catchError((Object e) {
      if (mounted) {
        setState(() {
          loaded = true;
          message = liveError(e);
        });
      }
    });
  }

  @override
  void dispose() {
    label.dispose();
    phone.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final here = ref.read(userLocation);
    setState(() => busy = true);
    try {
      await ref.read(liveApiProvider).saveHousehold({
        if (label.text.trim().isNotEmpty) 'label': label.text.trim(),
        'location': {'lat': here.position.latitude, 'lng': here.position.longitude},
        if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
        'members': members,
        'needs': needs.toList(),
        if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
        'consent': true,
      });
      setState(() {
        registered = true;
        message = '등록했습니다. 대피 상황 때 방재단이 이 정보로 먼저 확인합니다.';
      });
    } catch (e) {
      setState(() => message = liveError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _withdraw() async {
    setState(() => busy = true);
    try {
      await ref.read(liveApiProvider).deleteHousehold();
      setState(() {
        registered = false;
        consent = false;
        message = '동의를 철회하고 가구 정보를 지웠습니다.';
      });
    } catch (e) {
      setState(() => message = liveError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final here = ref.watch(userLocation);
    return _Page(title: '내 가구 등록 (취약 가구)', children: [
      const Text('고령·거동 불편 등으로 대피에 도움이 필요하면 등록하세요. 대피 상황 때 구룡포 자율방재단이 먼저 확인합니다.'),
      if (!loaded) const LinearProgressIndicator(),
      const SizedBox(height: 8),
      TextField(controller: label, decoration: const InputDecoration(labelText: '이름 또는 호칭 (예: 김○○ 댁)', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: '연락처', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      Row(children: [
        const Text('함께 사는 사람 수'),
        IconButton(onPressed: members > 1 ? () => setState(() => members--) : null, icon: const Icon(Icons.remove)),
        Text('$members명'),
        IconButton(onPressed: () => setState(() => members++), icon: const Icon(Icons.add)),
      ]),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in _need.entries)
          FilterChip(
              label: Text(e.value),
              selected: needs.contains(e.key),
              onSelected: (on) => setState(() => on ? needs.add(e.key) : needs.remove(e.key))),
      ]),
      const SizedBox(height: 8),
      TextField(controller: note, maxLength: 300, decoration: const InputDecoration(labelText: '방재단이 알아야 할 점 (선택)', border: OutlineInputBorder())),
      Text('위치: ${here.fromGps ? '현재 위치' : '구룡포 기본 위치'} (${here.position.latitude.toStringAsFixed(4)}, ${here.position.longitude.toStringAsFixed(4)})',
          style: Theme.of(c).textTheme.bodySmall),
      CheckboxListTile(
          value: consent,
          onChanged: (v) => setState(() => consent = v ?? false),
          title: const Text('민감정보(건강·거동) 수집과 방재단 제공에 동의합니다'),
          subtitle: const Text('언제든 철회할 수 있고, 철회하면 바로 지웁니다.')),
      FilledButton(onPressed: busy || !consent ? null : _save, child: Text(registered ? '수정 저장' : '등록')),
      if (registered) TextButton(onPressed: busy ? null : _withdraw, child: const Text('동의 철회·삭제')),
      if (message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!)),
    ]);
  }
}

/// 프로필의 기능 바로가기 (실측 모드): 실제 서버 기능만
class LiveFeatureLinks extends ConsumerWidget {
  const LiveFeatureLinks({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final role = '${ref.watch(meProvider).valueOrNull?['role'] ?? ''}';
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('안전 기능', style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                    onPressed: () => c.go('/alerts'), icon: const Icon(Icons.campaign_outlined), label: const Text('경고·대피 확인')),
                FilledButton.tonalIcon(
                    onPressed: () => c.push('/accessibility'), icon: const Icon(Icons.accessibility_new), label: const Text('접근성 설정')),
                FilledButton.tonalIcon(
                    onPressed: () => c.push('/household'), icon: const Icon(Icons.home_work_outlined), label: const Text('내 가구 등록')),
                FilledButton.tonalIcon(
                    onPressed: () => c.push('/responder'),
                    icon: const Icon(Icons.groups_outlined),
                    label: Text(const {'responder', 'caregiver', 'admin'}.contains(role) ? '방재단 대시보드 · $role' : '방재단 (초대 코드)')),
              ]),
            ])));
  }
}

/// 프로필의 시연 모드 스위치 (서버 연결 상태에서만 의미 있음)
class DemoModeSwitch extends ConsumerWidget {
  const DemoModeSwitch({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => Card(
      child: SwitchListTile(
          value: ref.watch(demoModeProvider),
          onChanged: (v) => ref.read(demoModeProvider.notifier).set(v),
          secondary: const Icon(Icons.science_outlined),
          title: const Text('시연 모드'),
          subtitle: const Text('켜면 가상 시나리오 화면(가상 태풍·가상 위험 구역·예시 가구)을 보여 줍니다. 끄면 실측 데이터만.')));
}

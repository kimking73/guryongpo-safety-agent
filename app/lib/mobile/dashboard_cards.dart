import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../disaster_center.dart' show LiveRealtimeCards;
import '../live_screens.dart';
import '../main.dart';
import '../models/domain_models.dart';
import '../origin_picker.dart';
import '../services/account_service.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart' show inServiceArea;
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// 대시보드 카드 (디자인: 최근 재난문자 · 경보·주의보 · 지금 구룡포 날씨).
/// 실측은 서버 맞춤 대시보드(GET /api/v1/dashboard)의 widgets, 시연은 예시 값

/// 서버 대시보드 위젯 중 [type]의 data (없으면 null)
Map<String, dynamic>? dashWidget(Map<String, dynamic>? dashboard, String type) {
  for (final w in dashboard?['widgets'] as List? ?? const []) {
    if ((w as Map)['type'] == type) {
      return Map<String, dynamic>.from(w['data'] as Map? ?? const {});
    }
  }
  return null;
}

bool _ok(Map<String, dynamic>? d) => d != null && d['available'] != false;

/// 서버 단계 → 디자인 단계 (좋음·관심·주의·경보)
String levelLabel(String? level) => switch (level) {
      'normal' || 'good' => '좋음',
      'watch' || 'moderate' => '관심',
      'advisory' || 'bad' => '주의',
      'warning' || 'critical' || 'very_bad' => '경보',
      _ => '',
    };

const _levelOrder = ['좋음', '관심', '주의', '경보'];
String _worse(String a, String b) =>
    _levelOrder.indexOf(a) >= _levelOrder.indexOf(b) ? a : b;

String fmtNum(Object? v, [int digits = 1]) {
  if (v is! num) return '-';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(digits);
}

// ------------------------------------------------------------------ 최근 재난문자

class DisasterMessageCard extends ConsumerStatefulWidget {
  const DisasterMessageCard({super.key, required this.demo});
  final bool demo;
  @override
  ConsumerState<DisasterMessageCard> createState() => _DisasterMessageCardState();
}

class _DisasterMessageCardState extends ConsumerState<DisasterMessageCard> {
  bool raw = false;

  /// 문자 내용에서 할 일 칩 뽑기
  List<(FaIconData, String, VoidCallback?)> _actions(String text) {
    void shelter() => startRouteToShelter(ref, nearestShelterId(ref));
    return [
      if (RegExp('해안|방파제|바닷가|해변|항구').hasMatch(text))
        (FontAwesomeIcons.umbrellaBeach, '바닷가·방파제 가지 않기', null),
      if (RegExp('대피|저지대').hasMatch(text))
        (FontAwesomeIcons.houseMedical, '가까운 대피소 확인', shelter),
      if (RegExp('침수|호우|하천|물').hasMatch(text))
        (FontAwesomeIcons.houseFloodWater, '하천·지하 공간 피하기', null),
      if (RegExp('산사태|급경사|비탈').hasMatch(text))
        (FontAwesomeIcons.mountain, '산비탈 가까이 가지 않기', null),
      if (RegExp('강풍|태풍').hasMatch(text))
        (FontAwesomeIcons.wind, '외출 자제·창문 고정', null),
    ];
  }

  @override
  Widget build(BuildContext context) {
    late final List<(String, String, String)> items; // (보낸 곳, 시각, 내용)
    if (widget.demo) {
      items = const [
        ('포항시', '14:20', '[포항시] 태풍 북상, 해안가·방파제 접근 금지. 저지대 주민은 대피 준비 바랍니다.')
      ];
    } else {
      final d = dashWidget(ref.watch(liveDashboardProvider).valueOrNull, 'disaster_messages');
      items = [
        for (final m in (_ok(d) ? d!['items'] as List? : null) ?? const [])
          ('${(m as Map)['sender'] ?? '재난문자'}', hhmm(m['sent_at']), '${m['message'] ?? ''}')
      ];
    }
    if (items.isEmpty) {
      return AppCard(
        child: Row(children: [
          const IconCircle(FontAwesomeIcons.commentDots, size: 30, iconSize: 13),
          const SizedBox(width: 8),
          Expanded(child: Text('최근 재난문자', style: dsText(16, weight: FontWeight.w800))),
          Text('24시간 동안 없어요', style: dsText(13, color: Ds.muted)),
        ]),
      );
    }
    final top = items.first;
    final headline = widget.demo ? '태풍이 오고 있어요. 바닷가에 가지 마세요.' : top.$3.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '');
    final actions = _actions(top.$3);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
          color: Ds.danger,
          borderRadius: BorderRadius.circular(Ds.rCard),
          boxShadow: const [BoxShadow(color: Color(0x38D9342B), blurRadius: 18, offset: Offset(0, 8))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconCircle(FontAwesomeIcons.commentDots,
              size: 30, iconSize: 13, bg: Colors.white, fg: Ds.danger),
          const SizedBox(width: 8),
          Expanded(
              child: Text('최근 재난문자',
                  style: dsText(16, weight: FontWeight.w800, color: Colors.white))),
          Text('${top.$1} · ${top.$2}',
              style: dsText(13, weight: FontWeight.w700, color: Colors.white)),
          SizedBox(
            width: 36,
            height: 30,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '원문 보기',
              onPressed: () => setState(() => raw = !raw),
              icon: FaIcon(raw ? FontAwesomeIcons.chevronUp : FontAwesomeIcons.chevronDown,
                  size: 14, color: Colors.white),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text(headline,
            maxLines: raw ? null : 3,
            overflow: raw ? null : TextOverflow.ellipsis,
            style: dsText(19, weight: FontWeight.w800, color: Colors.white, height: 1.35, spacing: -.2)),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          HScroll(children: [
            for (final a in actions)
              PillChip(a.$2,
                  icon: a.$1, fg: Ds.danger, iconBg: Ds.dangerSoft, onTap: a.$3),
          ]),
        ],
        if (raw) ...[
          const SizedBox(height: 10),
          for (final m in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('원문(${m.$2}): ${m.$3}',
                  style: dsText(15, color: Colors.white, height: 1.5)),
            ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ 경보·주의보

FaIconData warningIcon(String label) => switch (label) {
      final l when l.contains('태풍') => FontAwesomeIcons.hurricane,
      final l when l.contains('풍랑') || l.contains('해일') => FontAwesomeIcons.water,
      final l when l.contains('강풍') => FontAwesomeIcons.wind,
      final l when l.contains('호우') => FontAwesomeIcons.cloudShowersHeavy,
      final l when l.contains('대설') => FontAwesomeIcons.snowflake,
      final l when l.contains('폭염') => FontAwesomeIcons.temperatureHigh,
      final l when l.contains('한파') => FontAwesomeIcons.temperatureLow,
      final l when l.contains('건조') => FontAwesomeIcons.fire,
      _ => FontAwesomeIcons.triangleExclamation,
    };

class WarningsCard extends ConsumerWidget {
  const WarningsCard({super.key, required this.demo, this.riskJudgment});
  final bool demo;

  /// 내 위치 위험 판정 카드들 (기존 위험 카드)
  final Widget? riskJudgment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    late final List<String> labels;
    late final String text;
    Map<String, dynamic>? headline;
    if (demo) {
      labels = const ['태풍 경보', '풍랑 경보', '강풍 주의보', '호우 주의보'];
      text = '해안가와 방파제 접근을 피하고 가까운 대피소 위치를 확인하세요.';
    } else {
      final dash = ref.watch(liveDashboardProvider).valueOrNull;
      final d = dashWidget(dash, 'warnings');
      labels = [
        for (final w in (_ok(d) ? d!['items'] as List? : null) ?? const [])
          '${(w as Map)['label'] ?? ''}'.trim()
      ].where((l) => l.isNotEmpty).toSet().toList();
      headline = dash?['headline'] is Map ? Map<String, dynamic>.from(dash!['headline'] as Map) : null;
      final reason = (headline?['risk'] as Map?)?['reason'];
      text = [
        if (headline?['title'] != null) '${headline!['title']}',
        if (reason != null) '$reason',
      ].join(' · ');
    }
    return AppCard(
      radius: Ds.rCardLg,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CardTitle('경보 · 주의보',
            icon: FontAwesomeIcons.triangleExclamation,
            size: 20,
            trailing: Text('기상청', style: dsText(14, color: Ds.muted))),
        const SizedBox(height: 14),
        if (labels.isEmpty)
          Text('지금 구룡포에 발효 중인 특보가 없어요.',
              style: dsText(16, weight: FontWeight.w700, color: Ds.sub))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final l in labels)
              PillChip(l,
                  icon: warningIcon(l),
                  height: 44,
                  fontSize: 16,
                  bg: l.contains('경보') ? Ds.navy : Ds.soft,
                  fg: l.contains('경보') ? Colors.white : Ds.navy),
          ]),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(text, style: dsText(16, color: Ds.muted, height: 1.5)),
        ],
        if (headline?['action'] == 'open_route') ...[
          const SizedBox(height: 10),
          PillButton('가까운 대피소로 경로 보기',
              icon: FontAwesomeIcons.diamondTurnRight,
              height: 48,
              fontSize: 16,
              onPressed: () => startRouteToShelter(ref, nearestShelterId(ref))),
        ] else if (headline?['action'] == 'open_chat') ...[
          const SizedBox(height: 10),
          PillButton('AI에게 행동 요령 묻기',
              icon: FontAwesomeIcons.solidMessage,
              height: 48,
              fontSize: 16,
              outlined: true,
              onPressed: () => context.go('/ai')),
        ],
        if (riskJudgment != null) ...[
          const SizedBox(height: 10),
          const Divider(height: 1),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text('내 위치 위험 판정 자세히', style: dsText(15, weight: FontWeight.w800)),
              children: [riskJudgment!],
            ),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ 지금 구룡포 날씨 (2열 6칸)

class WeatherItem {
  const WeatherItem(
      {required this.key,
      required this.title,
      required this.value,
      required this.unit,
      required this.level,
      required this.note,
      required this.icon,
      required this.badge,
      this.source = ''});
  final String key, title, value, unit, level, note, source;
  final FaIconData icon, badge;

  /// 누르면 보이는 '실시간 관측·예보 자세히' 카드 (LiveRealtimeCards.only)
  Set<String> get detailKeys => switch (key) {
        'river' => const {'water'},
        'dust' => const {'fine_dust', 'ultrafine_dust'},
        _ => {key},
      };

  Color get color => level.isEmpty ? Ds.track : Ds.level(level);
  Color get onColor => level.isEmpty ? Ds.navy : Ds.onLevel(color);
  String get levelText => level.isEmpty ? '자료 없음' : level;

  /// 쉬운 말 설명 (디자인: 고령자도 바로 이해)
  String get description {
    const d = {
      'wind': ['바람이 약해요', '바람이 조금 불어요', '바람이 강해요. 간판·나뭇가지를 조심하세요', '우산이 뒤집힐 만큼 센 바람이에요'],
      'rain': ['비가 오지 않거나 약해요', '비가 조금 와요', '비가 많이 와요. 낮은 길을 피하세요', '길에 물이 찰 만큼 비가 많이 와요'],
      'wave': ['바다가 잔잔해요', '파도가 조금 있어요', '파도가 높아요. 해안에 가지 마세요', '파도가 매우 높아요. 바닷가에 절대 가지 마세요'],
      'river': ['하천 물높이가 안정적이에요', '아직 괜찮지만 물이 불어나고 있어요', '물이 많이 불었어요. 하천에서 멀어지세요', '물이 넘칠 수 있어요. 바로 높은 곳으로 가세요'],
      'dust': ['공기가 깨끗해요. 마스크 없어도 돼요', '공기가 보통이에요', '공기가 나빠요. 마스크를 쓰세요', '공기가 매우 나빠요. 바깥 활동을 줄이세요'],
      'uv': ['햇볕이 약해요. 모자 없어도 돼요', '햇볕이 조금 강해요', '햇볕이 강해요. 모자·양산을 쓰세요', '햇볕이 매우 강해요. 한낮 외출을 피하세요'],
    };
    final i = _levelOrder.indexOf(level);
    if (i < 0) return '지금은 자료가 없어요';
    return d[key]![i];
  }
}

/// 날씨 6칸 값. 시연은 예시, 실측은 서버 위젯에서 뽑는다 (자료 없으면 '-')
List<WeatherItem> weatherItems(Map<String, dynamic>? dashboard, {required bool demo}) {
  if (demo) {
    return const [
      WeatherItem(key: 'wind', title: '강풍', value: '21', unit: 'm/s', level: '경보', note: '북동풍 · 순간 30m/s', icon: FontAwesomeIcons.wind, badge: FontAwesomeIcons.hurricane, source: '예시 자료'),
      WeatherItem(key: 'rain', title: '강우량', value: '32', unit: 'mm/h', level: '주의', note: '오늘 누적 118mm', icon: FontAwesomeIcons.houseFloodWater, badge: FontAwesomeIcons.cloudShowersHeavy, source: '예시 자료'),
      WeatherItem(key: 'wave', title: '파고', value: '3.2', unit: 'm', level: '주의', note: '최대 4.8m · 해안 접근 금지', icon: FontAwesomeIcons.houseTsunami, badge: FontAwesomeIcons.water, source: '예시 자료'),
      WeatherItem(key: 'river', title: '수위', value: '2.4', unit: 'm', level: '관심', note: '최근 1시간 +0.3m', icon: FontAwesomeIcons.houseChimney, badge: FontAwesomeIcons.water, source: '예시 자료'),
      WeatherItem(key: 'dust', title: '미세 / 초미세먼지', value: '18 / 9', unit: '㎍', level: '좋음', note: '환기 가능', icon: FontAwesomeIcons.faceSmile, badge: FontAwesomeIcons.maskFace, source: '예시 자료'),
      WeatherItem(key: 'uv', title: '자외선 지수', value: '1', unit: '', level: '좋음', note: '흐림', icon: FontAwesomeIcons.cloud, badge: FontAwesomeIcons.sun, source: '예시 자료'),
    ];
  }
  final wind = dashWidget(dashboard, 'wind');
  final rain = dashWidget(dashboard, 'rain');
  final wave = dashWidget(dashboard, 'wave');
  final water = dashWidget(dashboard, 'water_level');
  final life = dashWidget(dashboard, 'life_safety');
  String src(Map<String, dynamic>? d, [String suffix = '관측']) =>
      _ok(d) && d!['station_name'] != null ? '${d['station_name']} · ${hhmm(d['observed_at'])} $suffix' : '';
  String why(Map<String, dynamic>? d) => '${d?['reason'] ?? '서버에 자료가 없어요'}';

  // 수위: 값이 있는 지점 중 가장 높은 단계
  var waterLv = '', waterV = '-', waterU = '', waterNote = why(water);
  if (_ok(water)) {
    final st = [for (final s in water!['stations'] as List? ?? const []) Map<String, dynamic>.from(s as Map)];
    int rank(Map<String, dynamic> s) => _levelOrder.indexOf(levelLabel(s['level'] as String?));
    final worst = st.isEmpty ? null : st.reduce((a, b) => rank(b) > rank(a) ? b : a);
    if (worst != null) {
      waterLv = levelLabel(worst['level'] as String?);
      waterV = worst['value'] == null ? '${worst['source_level_label'] ?? '-'}' : fmtNum(worst['value'], 0);
      waterU = worst['value'] == null ? '' : '${worst['unit'] ?? ''}';
      waterNote = '${worst['station_name'] ?? ''} · 지점 ${st.length}곳 중 가장 높은 단계';
    }
  }
  // 생활 안전: 미세·초미세먼지·자외선
  final lifeItems = [
    for (final i in (_ok(life) ? life!['items'] as List? : null) ?? const []) Map<String, dynamic>.from(i as Map)
  ];
  Map<String, dynamic>? lifeOf(String h) => lifeItems.where((i) => i['hazard'] == h).firstOrNull;
  final pm10 = lifeOf('fine_dust'), pm25 = lifeOf('ultrafine_dust'), uv = lifeOf('uv');
  final dustLv = [pm10, pm25].whereType<Map<String, dynamic>>().map((i) => levelLabel(i['level'] as String?)).fold('', (a, b) => a.isEmpty ? b : _worse(a, b));

  return [
    WeatherItem(
        key: 'wind', title: '강풍', icon: FontAwesomeIcons.wind, badge: FontAwesomeIcons.hurricane,
        value: _ok(wind) ? fmtNum(wind!['value']) : '-', unit: 'm/s',
        level: _ok(wind) ? levelLabel(wind!['level'] as String?) : '',
        note: _ok(wind) ? '${windFrom(wind!['wind_dir'])} · 순간 ${fmtNum(wind['wind_gust'])}m/s' : why(wind),
        source: src(wind)),
    WeatherItem(
        key: 'rain', title: '강우량', icon: FontAwesomeIcons.houseFloodWater, badge: FontAwesomeIcons.cloudShowersHeavy,
        value: _ok(rain) ? fmtNum(rain!['value']) : '-', unit: 'mm/h',
        level: _ok(rain) ? levelLabel(rain!['level'] as String?) : '',
        note: _ok(rain) ? '오늘 누적 ${fmtNum(rain!['rain_day'])}mm' : why(rain),
        source: src(rain)),
    WeatherItem(
        key: 'wave', title: '파고', icon: FontAwesomeIcons.houseTsunami, badge: FontAwesomeIcons.water,
        value: _ok(wave) ? fmtNum(wave!['value']) : '-', unit: 'm',
        level: _ok(wave) ? levelLabel(wave!['level'] as String?) : '',
        note: _ok(wave) ? '예보 값 · 실측 파고는 수집하지 않아요' : why(wave),
        source: src(wave, '부터 24시간 예보')),
    WeatherItem(
        key: 'river', title: '수위', icon: FontAwesomeIcons.houseChimney, badge: FontAwesomeIcons.water,
        value: waterV, unit: waterU, level: waterLv, note: waterNote,
        source: _ok(water) ? '포항 디지털 트윈 · ${hhmm(water!['observed_at'])} 수집' : ''),
    WeatherItem(
        key: 'dust', title: '미세 / 초미세먼지', icon: FontAwesomeIcons.faceSmile, badge: FontAwesomeIcons.maskFace,
        value: pm10 == null && pm25 == null ? '-' : '${fmtNum(pm10?['value'], 0)} / ${fmtNum(pm25?['value'], 0)}',
        unit: '㎍', level: dustLv,
        note: pm10 == null && pm25 == null ? why(life) : '미세먼지 ${levelLabel(pm10?['level'] as String?)} · 초미세먼지 ${levelLabel(pm25?['level'] as String?)}',
        source: pm10 == null ? '' : '${pm10['station_name'] ?? ''} · ${hhmm(pm10['observed_at'])} 측정'),
    WeatherItem(
        key: 'uv', title: '자외선 지수', icon: FontAwesomeIcons.cloud, badge: FontAwesomeIcons.sun,
        value: uv == null ? '-' : fmtNum(uv['value'], 0), unit: '',
        level: uv == null ? '' : levelLabel(uv['level'] as String?),
        note: uv == null ? why(life) : '${uv['label'] ?? '자외선'}',
        source: uv == null ? '' : '${uv['station_name'] ?? ''} · ${hhmm(uv['observed_at'])}'),
  ];
}

class WeatherSection extends ConsumerWidget {
  const WeatherSection({super.key, required this.demo});
  final bool demo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = demo ? null : ref.watch(liveDashboardProvider);
    final items = weatherItems(async?.valueOrNull, demo: demo);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        TextSpan(text: '지금 구룡포 날씨 ', style: dsText(21, weight: FontWeight.w800)),
        TextSpan(
            text: demo
                ? '· 예시 자료'
                : async!.isLoading
                    ? '· 불러오는 중'
                    : '· 실시간',
            style: dsText(17, weight: FontWeight.w700, color: Ds.muted)),
      ])),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final l in _levelOrder)
          Container(
            height: 34,
            padding: const EdgeInsets.only(left: 8, right: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Ds.pill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 16, height: 16, decoration: BoxDecoration(color: Ds.level(l), shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(l, style: dsText(15, weight: FontWeight.w700)),
            ]),
          ),
      ]),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (_, c) {
        // 휴대폰은 2열, 넓은 웹 화면은 3열 (칸 크기는 그대로)
        final cols = c.maxWidth >= 900 ? 3 : 2;
        final w = (c.maxWidth - 6 * (cols - 1)) / cols;
        return Wrap(spacing: 6, runSpacing: 6, children: [
          for (final it in items) SizedBox(width: w, child: _WeatherTile(item: it, dashboard: async?.valueOrNull)),
        ]);
      }),
      const SizedBox(height: 6),
      // 태풍 정보 (2026-10-11 사용자 요청 — 사용자 탭 '더 보기'에서 옮김)
      Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/typhoon'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            child: Row(children: [
              const IconCircle(FontAwesomeIcons.hurricane, size: 38, iconSize: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('태풍 정보 자세히 보기', style: dsText(15, weight: FontWeight.w800)),
                  Text('태풍 경로와 구룡포 영향', style: dsText(13, color: Ds.muted)),
                ]),
              ),
              const FaIcon(FontAwesomeIcons.chevronRight, size: 13, color: Ds.muted),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _WeatherTile extends StatelessWidget {
  const _WeatherTile({required this.item, this.dashboard});
  final WeatherItem item;
  /// 실측 대시보드 (시연이면 null)
  final Map<String, dynamic>? dashboard;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showWeatherDetail(context, item, dashboard: dashboard),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              _WeatherIcon(item: item, size: 38),
              const SizedBox(width: 9),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: dsText(13, weight: FontWeight.w800, height: 1.2)),
                  const SizedBox(height: 2),
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Flexible(
                      child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: item.value, style: dsText(19, weight: FontWeight.w800, color: Ds.navy, height: 1.1, spacing: -.4)),
                            TextSpan(text: ' ${item.unit}', style: dsText(11, weight: FontWeight.w700, color: Ds.navy)),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 4),
                    LevelBadge(item.levelText, color: item.color),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _WeatherIcon extends StatelessWidget {
  const _WeatherIcon({required this.item, required this.size});
  final WeatherItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = size * .45;
    return SizedBox(
      width: size + 4,
      height: size + 3,
      child: Stack(clipBehavior: Clip.none, children: [
        IconCircle(item.icon, size: size, iconSize: size * .42, bg: item.color, fg: item.onColor),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: b,
            height: b,
            decoration: BoxDecoration(
                color: Colors.white, shape: BoxShape.circle, border: Border.all(color: item.color, width: 1.5)),
            alignment: Alignment.center,
            child: FaIcon(item.badge, size: b * .48, color: Ds.navy),
          ),
        ),
      ]),
    );
  }
}

/// 날씨 상세 (아래에서 올라오는 시트). 실측이면 쉬운 설명 아래에 '실시간 관측·예보 자세히'의 그 항목 카드를 보인다
/// (2026-10-11 사용자 요청). 시연(대시보드 없음)은 예시 값·설명만
Future<void> showWeatherDetail(BuildContext context, WeatherItem w, {Map<String, dynamic>? dashboard}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      barrierColor: const Color(0x8014225B),
      // 기본 시트 높이(화면의 9/16)를 넘으면 아래 '닫기'가 잘린다 → 내용 높이만큼, 넘치면 스크롤
      isScrollControlled: true,
      builder: (c) => SingleChildScrollView(
        // 휴대폰 앱은 아래 탭바에 '닫기'가 가리지 않게
        padding: EdgeInsets.fromLTRB(20, 0, 20, useMobileUi ? 110 : 34),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _WeatherIcon(item: w, size: 72),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(w.title, style: dsText(24, weight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(w.description, style: dsText(17, color: Ds.sub, height: 1.45)),
              ]),
            ),
          ]),
          if (dashboard != null) ...[
            const SizedBox(height: 18),
            LiveRealtimeCards(
                simulated: dashboard['demo'] != null,
                only: w.detailKeys,
                widgets: [for (final x in dashboard['widgets'] as List? ?? const []) Map<String, dynamic>.from(x as Map)]),
          ] else ...[
          const SizedBox(height: 22),
          Text.rich(TextSpan(children: [
            TextSpan(text: w.value, style: dsText(56, weight: FontWeight.w800, color: Ds.navy, height: 1, spacing: -1.6)),
            TextSpan(text: ' ${w.unit}', style: dsText(20, weight: FontWeight.w700, color: Ds.navy)),
          ])),
          const SizedBox(height: 10),
          Row(children: [
            LevelBadge(w.levelText, color: w.color, fontSize: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(w.note, style: dsText(17, color: Ds.muted))),
          ]),
          if (w.source.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(w.source, style: dsText(13, color: Ds.muted)),
          ],
          ],
          const SizedBox(height: 24),
          PillButton('닫기', height: 58, fontSize: 18, onPressed: () => Navigator.of(c).pop()),
        ]),
      ),
    );

// ------------------------------------------------------------------ 지도 카드 아래 경로 안내 줄

/// 경로 안내 줄 (2026-10-11 사용자 요청, web-prototype RouteBar 모양):
/// [출발지 ⌃] → [대피소 ⌄] · ⇄ · 도보/자동차 · 시간·거리.
/// 출발지를 누르면 현위치·집·내 장소·지도에서 선택하기·주소로 찾기, 대피소를 누르면 출발지에서 가까운 순 대피소 목록.
/// ⇄ 는 대피소 → 출발지 방향으로 다시 계산한다 (routeReversed).
/// 넓으면 한 줄, 휴대폰은 두 줄(출발·도착 / 나머지).
/// [withRouteTypes] (웹 대시보드): 아래에 경로 방식(최단·안전·오르막 회피)과 설명
class RouteSummaryRows extends ConsumerStatefulWidget {
  const RouteSummaryRows({super.key, this.withRouteTypes = false});
  final bool withRouteTypes;

  @override
  ConsumerState<RouteSummaryRows> createState() => _RouteSummaryRowsState();
}

class _RouteSummaryRowsState extends ConsumerState<RouteSummaryRows> {
  /// 지금 열린 목록 ('from' 출발지 · 'to' 대피소) — 그 칸 테두리를 강조한다
  String? open;

  /// 출발지를 바꾼 뒤: 대피소 경로를 보고 있었으면 새 출발지로 다시 계산
  void _reroute() {
    final active = ref.read(routeFacilityId);
    if (active != null && active != customRouteId && active != aiRouteId) {
      startRouteToShelter(ref, active, routeType: ref.read(routeKind), reversed: ref.read(routeReversed));
    }
  }

  Future<void> _setOrigin(LatLng p, String label, {String address = ''}) async {
    if (!inServiceArea(p)) {
      showDsToast(context, '구룡포 서비스 지역(경로 안내 범위) 밖이라 출발지로 쓸 수 없어요');
      return;
    }
    await chooseOrigin(ref, p, label, address: address);
    _reroute();
  }

  Future<void> _pickOrigin() async {
    final o = await AccountService().optionalProfile();
    final places = await AccountService().places();
    if (!mounted) return;
    final here = ref.read(userLocation);
    final label = ref.read(originLabelProvider);
    final homeLat = double.tryParse(o['homeLat'] ?? ''), homeLon = double.tryParse(o['homeLon'] ?? '');
    final homeName = (o['homeName'] ?? '').trim().isEmpty ? '집' : o['homeName']!.trim();
    setState(() => open = 'from');
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => _PickSheet(title: '출발지 선택', children: [
        _OptionRow(
            icon: FontAwesomeIcons.locationCrosshairs,
            label: '현위치',
            sub: here.fromGps ? 'GPS' : '구룡포 기본 위치',
            on: !here.manual,
            onTap: () => Navigator.pop(sheet, 'cur')),
        _OptionRow(
            icon: FontAwesomeIcons.house,
            label: '집',
            sub: homeLat == null ? '사용자 탭에서 집 주소를 등록해 주세요' : (o['homeAddress'] ?? homeName),
            on: here.manual && label == homeName,
            onTap: () => Navigator.pop(sheet, 'home')),
        if (places.isEmpty)
          _OptionRow(
              icon: FontAwesomeIcons.bookmark,
              label: '내 장소',
              sub: '등록된 장소가 없어요',
              on: false,
              onTap: () => Navigator.pop(sheet, 'noplace'))
        else
          for (final (i, p) in places.indexed)
            _OptionRow(
                icon: FontAwesomeIcons.bookmark,
                label: p.name,
                sub: p.address.isEmpty ? '내 장소' : p.address,
                on: here.manual && label == p.name,
                onTap: () => Navigator.pop(sheet, 'place$i')),
        _OptionRow(
            icon: FontAwesomeIcons.map,
            label: '지도에서 선택하기',
            sub: '지도를 눌러 출발지를 골라요',
            on: false,
            onTap: () => Navigator.pop(sheet, 'map')),
        _OptionRow(
            icon: FontAwesomeIcons.magnifyingGlass,
            label: '주소로 찾기',
            sub: '도로명 주소 · 예: 구룡포읍 호미로 152',
            on: false,
            onTap: () => Navigator.pop(sheet, 'addr')),
      ]),
    );
    if (mounted) setState(() => open = null);
    if (pick == null || !mounted) return;
    switch (pick) {
      case 'cur':
        final note = await useGpsOrigin(ref);
        if (note != null && mounted) showDsToast(context, note);
        _reroute();
      case 'home':
        if (homeLat == null || homeLon == null) {
          showDsToast(context, '사용자 탭에서 집 주소를 먼저 등록해 주세요');
          return;
        }
        await _setOrigin(LatLng(homeLat, homeLon), homeName, address: o['homeAddress'] ?? '');
      case 'noplace':
        showDsToast(context, '사용자 탭에서 내 장소를 먼저 추가해 주세요');
      case 'map':
        final p = await showDialog<LatLng>(context: context, builder: (_) => MapPickDialog(start: here.position));
        if (p != null && mounted) await _setOrigin(p, '지도에서 고른 위치');
      case 'addr':
        final r = await showDialog<GeocodedAddress>(context: context, builder: (_) => const AddressDialog());
        if (r != null && mounted) await _setOrigin(r.position, r.address, address: r.address);
      default:
        final p = places[int.parse(pick.substring(5))];
        await _setOrigin(p.position, p.name, address: p.address);
    }
  }

  Future<void> _pickShelter(List<(Facility, double)> shelters) async {
    final current = ref.read(routeFacilityId);
    final areas = ref.read(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
    setState(() => open = 'to');
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => _PickSheet(title: '대피소 선택 · 가까운 순', children: [
        if (shelters.isEmpty)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text('대피소 목록을 불러오지 못했어요', style: dsText(15, color: Ds.muted))),
        for (final (f, m) in shelters)
          _OptionRow(
              icon: FontAwesomeIcons.houseMedical,
              label: f.name,
              sub: shelterExclusion(f, areas) ?? (f.address.isEmpty ? '대피소' : f.address),
              warn: shelterExclusion(f, areas) != null,
              right: _km(m.round()),
              on: f.id == current,
              onTap: () => Navigator.pop(sheet, f.id)),
      ]),
    );
    if (mounted) setState(() => open = null);
    if (picked != null) {
      startRouteToShelter(ref, picked, routeType: ref.read(routeKind), reversed: ref.read(routeReversed));
    }
  }

  static String _km(int m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)}km' : '${m}m';

  @override
  Widget build(BuildContext context) {
    final here = ref.watch(userLocation);
    final label = ref.watch(originLabelProvider);
    final mode = ref.watch(travelMode);
    final kind = ref.watch(routeKind);
    final reversed = ref.watch(routeReversed);
    final id = ref.watch(routeFacilityId);
    final routeAsync = id == null ? null : ref.watch(routeProvider(id));
    final route = routeAsync?.valueOrNull;
    final dest = id == null ? null : routeDestination(ref, id);
    const dist = Distance();
    final shelters = [
      for (final f in [...?ref.watch(facilitiesProvider).valueOrNull].where((f) => f.type == FacilityType.shelter))
        (f, dist.as(LengthUnit.Meter, here.position, f.position)),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final shelterRoute = id == null || (id != customRouteId && id != aiRouteId);
    final fromName = here.manual ? (label ?? '지도에서 고른 위치') : '현위치';
    final toName = dest?.name ?? (shelters.isEmpty ? '가까운 대피소' : shelters.first.$1.name);
    final flipped = reversed && shelterRoute;
    // 이동 수단 옆 예상 시간 (2026-10-11 사용자 요청): 고른 수단 = 경로 서버 계산값,
    // 다른 수단·경로 계산 전 = 거리로 어림 (도보 4km/h, 자동차 시내 30km/h; 직선거리는 ×1.3 — remote_repository 와 같은 어림)
    final etaMeters = route?.distanceMeters.toDouble() ?? (shelters.isEmpty ? null : shelters.first.$2 * 1.3);
    String? eta(TravelMode m) {
      if (route != null && m == mode) return '${route.estimatedMinutes}분';
      if (etaMeters == null) return null;
      final kmh = m == TravelMode.car ? 30 : 4;
      return '${math.max(1, (etaMeters / 1000 / kmh * 60).round())}분';
    }

    final fromPill = _EndPill(fromName, open: open == 'from', onTap: _pickOrigin);
    final toPill = _EndPill(toName, open: open == 'to', onTap: shelterRoute ? () => _pickShelter(shelters) : null);
    final ends = Row(children: [
      Expanded(child: flipped ? toPill : fromPill),
      const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: FaIcon(FontAwesomeIcons.arrowRightLong, size: 15, color: Ds.muted)),
      Expanded(child: flipped ? fromPill : toPill),
    ]);
    final controls = [
      if (shelterRoute)
        CircleButton(FontAwesomeIcons.arrowRightArrowLeft,
            size: 40,
            bg: Ds.soft,
            tooltip: '출발·도착 바꾸기',
            onPressed: () {
              ref.read(routeReversed.notifier).state = !reversed;
              if (id != null) ref.read(routeStartOrigin.notifier).state = here.position;
            }),
      const SizedBox(width: 8),
      _ModeToggle(
        value: mode,
        eta: {for (final m in TravelMode.values) m: eta(m)},
        onChanged: (m) => ref.read(travelMode.notifier).state = m,
      ),
      const Spacer(),
      if (id != null) ...[
        CircleButton(FontAwesomeIcons.xmark,
            size: 40, bg: Ds.bg, tooltip: '경로 안내 종료', onPressed: () => ref.read(routeFacilityId.notifier).state = null),
        const SizedBox(width: 6),
      ],
      if (id == null)
        PillButton('경로 보기',
            expand: false,
            height: 44,
            fontSize: 15,
            icon: FontAwesomeIcons.diamondTurnRight,
            onPressed: shelters.isEmpty
                ? null
                : () => startRouteToShelter(ref, shelters.first.$1.id, routeType: kind, reversed: reversed))
      else
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: Ds.navy, borderRadius: BorderRadius.circular(Ds.pill)),
          alignment: Alignment.center,
          child: routeAsync!.isLoading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text.rich(TextSpan(children: [
                  TextSpan(
                      text: route == null ? '경로 없음' : '${route.estimatedMinutes}분',
                      style: dsText(18, weight: FontWeight.w800, color: Colors.white)),
                  if (route != null)
                    TextSpan(text: ' ${_km(route.distanceMeters)}', style: dsText(13, weight: FontWeight.w600, color: Colors.white)),
                ])),
        ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      LayoutBuilder(
        builder: (_, c) => c.maxWidth >= 640
            ? Row(children: [Expanded(child: ends), const SizedBox(width: 12), ...controls])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ends,
                const SizedBox(height: 10),
                Row(children: controls),
              ]),
      ),
      if (widget.withRouteTypes) ...[
        const SizedBox(height: 10),
        Semantics(
          label: '경로 방식 선택',
          child: SegmentedPill<RouteType>(
            height: 42,
            items: [
              for (final t in mode.routeTypes)
                switch (t) {
                  RouteType.nearest => (t, '최단 거리', FontAwesomeIcons.arrowRightLong),
                  RouteType.safest => (t, '안전한 경로', FontAwesomeIcons.shieldHalved),
                  RouteType.flat => (t, '오르막 회피', FontAwesomeIcons.arrowTrendDown),
                },
            ],
            value: kind,
            onChanged: (t) => ref.read(routeKind.notifier).state = t,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 4, 0),
          child: Text(
              switch (kind) {
                RouteType.nearest => '가장 짧은 길이에요. 위험 구역을 피하지 않고, 지나는 구역은 알려 드려요.',
                RouteType.safest => '침수·산사태 위험 구역(주의 이상)을 피해서 가요.',
                RouteType.flat => '위험 구역을 피하면서 가파른 오르막을 되도록 줄여요.',
              },
              style: dsText(13, color: Ds.muted, height: 1.4)),
        ),
      ],
    ]);
  }
}

/// 도보/자동차 고르기 + 아이콘 옆 작은 예상 시간
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.value, required this.eta, required this.onChanged});
  final TravelMode value;
  final Map<TravelMode, String?> eta;
  final ValueChanged<TravelMode> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: Ds.soft, borderRadius: BorderRadius.circular(Ds.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final m in TravelMode.values)
            Semantics(
              selected: m == value,
              button: true,
              label: '${m.label}${eta[m] == null ? '' : ' 약 ${eta[m]}'}',
              child: Material(
                color: m == value ? Ds.navy : Colors.transparent,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onChanged(m),
                  child: Container(
                    height: 38,
                    constraints: const BoxConstraints(minWidth: 38),
                    padding: EdgeInsets.symmetric(horizontal: eta[m] == null ? 0 : 10),
                    alignment: Alignment.center,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      FaIcon(m == TravelMode.car ? FontAwesomeIcons.car : FontAwesomeIcons.personWalking,
                          size: 14, color: m == value ? Colors.white : Ds.navy),
                      if (eta[m] != null) ...[
                        const SizedBox(width: 4),
                        Text(eta[m]!, style: dsText(12, weight: FontWeight.w700, color: m == value ? Colors.white : Ds.navy)),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// 출발·도착 칸: 회색 pill + ⌄ (목록이 열리면 노란 테두리 + ⌃)
class _EndPill extends StatelessWidget {
  const _EndPill(this.text, {required this.open, required this.onTap});
  final String text;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: open ? Colors.white : Ds.bg,
        shape: StadiumBorder(side: BorderSide(color: open ? Ds.caution : Colors.transparent, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 44,
            padding: const EdgeInsets.only(left: 14, right: 10),
            child: Row(children: [
              Expanded(
                  child: Text(text,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(16, weight: FontWeight.w800))),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                FaIcon(open ? FontAwesomeIcons.chevronUp : FontAwesomeIcons.chevronDown, size: 12, color: Ds.muted),
              ],
            ]),
          ),
        ),
      );
}

/// 출발지·대피소 목록 시트
class _PickSheet extends StatelessWidget {
  const _PickSheet({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .75),
          // 아래 탭바에 가리지 않게 아래 여백 (휴대폰 앱)
          child: ListView(shrinkWrap: true, padding: EdgeInsets.fromLTRB(16, 0, 16, useMobileUi ? 110 : 16), children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                child: Text(title, style: dsText(16, weight: FontWeight.w700, color: Ds.muted))),
            for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c),
          ]),
        ),
      );
}

/// 목록 한 줄 (web-prototype OptionRow): 동그란 아이콘 · 이름/설명 · 오른쪽 거리. 고른 줄은 남색
class _OptionRow extends StatelessWidget {
  const _OptionRow(
      {required this.icon,
      required this.label,
      required this.sub,
      required this.on,
      required this.onTap,
      this.right,
      this.warn = false});
  final FaIconData icon;
  final String label, sub;
  final String? right;
  final bool on, warn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = on ? Colors.white : Ds.ink;
    return Material(
      color: on ? Ds.navy : Ds.bg,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            IconCircle(warn ? FontAwesomeIcons.triangleExclamation : icon,
                size: 42,
                iconSize: 18,
                bg: on ? Colors.white.withValues(alpha: .16) : Colors.white,
                fg: on ? Colors.white : (warn ? Ds.warnDeep : Ds.navy)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(17, weight: FontWeight.w800, color: fg)),
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: dsText(13, color: on ? Colors.white70 : (warn ? Ds.warnDeep : Ds.muted))),
              ]),
            ),
            if (right != null) ...[
              const SizedBox(width: 8),
              Text(right!, style: dsText(15, weight: FontWeight.w700, color: fg)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// 프로필의 집 이름 (출발지 선택 표시용)
final homeLabelProvider = FutureProvider<String>((ref) async {
  ref.watch(profileRevision);
  final o = await AccountService().optionalProfile();
  final n = (o['homeName'] ?? '').trim();
  return n.isEmpty ? '집' : n;
});

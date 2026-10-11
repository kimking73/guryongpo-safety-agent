import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';

import 'disaster_center.dart' show LiveRealtimeCards;
import 'live_screens.dart';
import 'ui/tokens.dart';
import 'ui/widgets.dart';

/// 대시보드 '지금 구룡포 날씨' 칸과 경보 아이콘.
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
      this.source = '',
      this.tableTitle = '',
      this.tableHead = '시각',
      this.table = const []});
  final String key, title, value, unit, level, note, source;
  final FaIconData icon, badge;

  /// 눌렀을 때 보이는 표 (2026-10-11 사용자 요청): 시각(또는 지점) · 값. 서버가 시간별 값을 주는 항목만 (강풍·강우량·파고),
  /// 수위는 지점별 지금 값. 비어 있으면 표 대신 안내 한 줄
  final String tableTitle, tableHead;
  final List<(String, String)> table;

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
      'wind': ['바람이 약해요', '바람이 조금 불어요', '바람이 강해요. 간판·나뭇가지를 조심하세요', '우산이 뒤집힐 만큼 센 바람이에요. 외출을 삼가세요'],
      'rain': ['비가 오지 않거나 약해요', '비가 조금 와요. 우산을 챙기세요', '비가 많이 와요. 우산을 챙기고 낮은 길을 피하세요', '길에 물이 찰 만큼 비가 많이 와요. 외출을 미루세요'],
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
      WeatherItem(key: 'wind', title: '강풍', value: '21', unit: 'm/s', level: '경보', note: '북동풍 · 순간 30m/s', icon: FontAwesomeIcons.wind, badge: FontAwesomeIcons.hurricane, source: '예시 자료',
          tableTitle: '최근 6시간 (시간별 최대)', table: [('지금', '21'), ('1시간 전', '19'), ('2시간 전', '16'), ('3시간 전', '12'), ('4시간 전', '9'), ('5시간 전', '7')]),
      WeatherItem(key: 'rain', title: '강우량', value: '32', unit: 'mm/h', level: '주의', note: '오늘 누적 118mm', icon: FontAwesomeIcons.houseFloodWater, badge: FontAwesomeIcons.cloudShowersHeavy, source: '예시 자료',
          tableTitle: '최근 6시간 (1시간 강수)', table: [('지금', '32'), ('1시간 전', '28'), ('2시간 전', '24'), ('3시간 전', '18'), ('4시간 전', '11'), ('5시간 전', '5')]),
      WeatherItem(key: 'wave', title: '파고', value: '3.2', unit: 'm', level: '주의', note: '최대 4.8m · 해안 접근 금지', icon: FontAwesomeIcons.houseTsunami, badge: FontAwesomeIcons.water, source: '예시 자료',
          tableTitle: '앞으로 12시간 예보', table: [('지금', '3.2'), ('3시간 뒤', '3.9'), ('6시간 뒤', '4.8'), ('9시간 뒤', '4.1'), ('12시간 뒤', '3.0')]),
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

  // 시간별 표: 관측(10분 간격)은 시각별로 묶어 최근 것부터 (peak = 그 시각 최대, 아니면 마지막 값), 예보는 시간 순서 그대로
  List<(String, String)> hourly(Map<String, dynamic>? d, {bool peak = false, bool forecast = false}) {
    if (!_ok(d)) return const [];
    final pts = <(DateTime, double)>[];
    for (final p in d!['series'] as List? ?? const []) {
      final t = DateTime.tryParse('${(p as Map)['t']}')?.toLocal();
      final v = (p['v'] as num?)?.toDouble();
      if (t != null && v != null) pts.add((t, v));
    }
    pts.sort((a, b) => a.$1.compareTo(b.$1));
    if (forecast) return [for (final (t, v) in pts) ('${t.day}일 ${t.hour}시', fmtNum(v))];
    final byHour = <DateTime, double>{};
    for (final (t, v) in pts) {
      final h = DateTime(t.year, t.month, t.day, t.hour);
      byHour[h] = peak && byHour[h] != null ? math.max(byHour[h]!, v) : v;
    }
    final hours = byHour.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final h in hours) ('${h.hour}시', fmtNum(byHour[h]))];
  }

  // 수위: 값이 있는 지점 중 가장 높은 단계
  var waterTable = const <(String, String)>[];
  var waterLv = '', waterV = '-', waterU = '', waterNote = why(water);
  if (_ok(water)) {
    final st = [for (final s in water!['stations'] as List? ?? const []) Map<String, dynamic>.from(s as Map)];
    int rank(Map<String, dynamic> s) => _levelOrder.indexOf(levelLabel(s['level'] as String?));
    final worst = st.isEmpty ? null : st.reduce((a, b) => rank(b) > rank(a) ? b : a);
    waterTable = [
      for (final s in [...st]..sort((a, b) => rank(b).compareTo(rank(a))))
        ('${s['station_name'] ?? '-'}',
            '${s['value'] == null ? (s['source_level_label'] ?? '-') : '${fmtNum(s['value'], 0)}${s['unit'] ?? ''}'}'
                '${levelLabel(s['level'] as String?).isEmpty ? '' : ' · ${levelLabel(s['level'] as String?)}'}'),
    ];
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
        source: src(wind), tableTitle: '최근 6시간 (시간별 최대)', table: hourly(wind, peak: true)),
    WeatherItem(
        key: 'rain', title: '강우량', icon: FontAwesomeIcons.houseFloodWater, badge: FontAwesomeIcons.cloudShowersHeavy,
        value: _ok(rain) ? fmtNum(rain!['value']) : '-', unit: 'mm/h',
        level: _ok(rain) ? levelLabel(rain!['level'] as String?) : '',
        note: _ok(rain) ? '오늘 누적 ${fmtNum(rain!['rain_day'])}mm' : why(rain),
        source: src(rain), tableTitle: '최근 6시간 (1시간 강수)', table: hourly(rain)),
    WeatherItem(
        key: 'wave', title: '파고', icon: FontAwesomeIcons.houseTsunami, badge: FontAwesomeIcons.water,
        value: _ok(wave) ? fmtNum(wave!['value']) : '-', unit: 'm',
        level: _ok(wave) ? levelLabel(wave!['level'] as String?) : '',
        note: _ok(wave) ? '예보 값 · 실측 파고는 수집하지 않아요' : why(wave),
        source: src(wave, '부터 24시간 예보'), tableTitle: '앞으로 24시간 예보', table: hourly(wave, forecast: true)),
    WeatherItem(
        key: 'river', title: '수위', icon: FontAwesomeIcons.houseChimney, badge: FontAwesomeIcons.water,
        value: waterV, unit: waterU, level: waterLv, note: waterNote,
        source: _ok(water) ? '포항 디지털 트윈 · ${hhmm(water!['observed_at'])} 수집' : '',
        tableTitle: '지점별 지금 값', tableHead: '지점', table: waterTable),
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
        // 권고 문구 길이가 달라도 같은 줄의 칸 높이는 같게
        return Column(children: [
          for (var i = 0; i < items.length; i += cols) ...[
            if (i > 0) const SizedBox(height: 6),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var j = i; j < i + cols; j++) ...[
                  if (j > i) const SizedBox(width: 6),
                  SizedBox(
                      width: w,
                      child: j < items.length
                          ? _WeatherTile(item: items[j], dashboard: async?.valueOrNull)
                          : null),
                ],
              ]),
            ),
          ],
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
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
            // 권고 문구 (2026-10-11 사용자 요청 — 예전에는 눌러야 보였다)
            const SizedBox(height: 6),
            Text(item.description, style: dsText(13, weight: FontWeight.w600, color: Ds.sub, height: 1.35)),
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
        padding: EdgeInsets.fromLTRB(20, 0, 20, 34),
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
          const SizedBox(height: 18),
          _WeatherTable(item: w),
          const SizedBox(height: 24),
          PillButton('닫기', height: 58, fontSize: 18, onPressed: () => Navigator.of(c).pop()),
        ]),
      ),
    );

/// 날씨 상세의 표: 시각(또는 지점) · 값. 표로 줄 자료가 없으면 안내 한 줄
class _WeatherTable extends StatelessWidget {
  const _WeatherTable({required this.item});
  final WeatherItem item;

  @override
  Widget build(BuildContext context) {
    if (item.table.isEmpty) {
      return Text(
          item.tableTitle.isEmpty ? '이 항목은 시간별 값을 아직 모으지 않아요. 지금 값만 보여 드려요.' : '시간별 값이 아직 없어요.',
          style: dsText(14, color: Ds.muted));
    }
    Widget row(String a, String b, {bool head = false, bool first = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
              color: head ? Ds.track : Colors.white,
              border: head ? null : const Border(top: BorderSide(color: Ds.track))),
          child: Row(children: [
            Expanded(
                child: Text(a,
                    style: dsText(head ? 14 : 16,
                        weight: head || first ? FontWeight.w800 : FontWeight.w600, color: head ? Ds.sub : Ds.navy))),
            const SizedBox(width: 12),
            Text(b,
                style: dsText(head ? 14 : 16,
                    weight: head || first ? FontWeight.w800 : FontWeight.w600, color: head ? Ds.sub : Ds.navy)),
          ]),
        );
    final unit = item.tableHead == '시각' && item.unit.isNotEmpty ? '값 (${item.unit})' : '값';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(item.tableTitle, style: dsText(16, weight: FontWeight.w800)),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: Ds.track), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            row(item.tableHead, unit, head: true),
            for (var i = 0; i < item.table.length; i++)
              row(item.table[i].$1, item.table[i].$2, first: i == 0 && item.tableHead == '시각' && !item.tableTitle.contains('예보')),
          ]),
        ),
      ),
    ]);
  }
}

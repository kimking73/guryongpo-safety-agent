import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart';
import 'models/domain_models.dart';
import 'origin_picker.dart';
import 'services/account_service.dart';
import 'services/geocoding_service.dart';
import 'services/location_service.dart';
import 'ui/gk_widgets.dart';

/// 길찾기 (2026-10-05): 출발지·목적지를 주소(또는 집·직장·저장 장소)로 정하면 가까운 경로와 안전 경로를 함께 계산해 비교하고,
/// 고른 경로를 지도(Dashboard 경로 화면)에 띄운다. 경로 서버 POST /api/route — strategy fastest(가까운) · safest(안전).
/// 두 경로 모두 지금 판정된 위험 구역(침수·산사태 주의 이상)은 피한다. 안전 경로는 급경사·계단도 피해 조금 더 돌아갈 수 있다.

class _Spot {
  const _Spot(this.label, this.position, {this.address = '', this.isMine = false});
  final String label, address;
  final LatLng position;
  /// 지금 내 출발 위치(GPS 또는 '출발' 칩) — 이걸 출발지로 하면 이동 중 경로 재확인을 켠다
  final bool isMine;
}

class _Result {
  _Result(this.type, {this.route, this.error});
  final RouteType type;
  final SafetyRoute? route;
  final String? error;
}

class CustomRouteScreen extends ConsumerStatefulWidget {
  const CustomRouteScreen({super.key});
  @override
  ConsumerState<CustomRouteScreen> createState() => _CustomRouteScreenState();
}

class _CustomRouteScreenState extends ConsumerState<CustomRouteScreen> {
  final fromText = TextEditingController(), toText = TextEditingController();
  _Spot? from, to;
  List<_Spot> quick = [];
  bool busy = false;
  String? error;
  List<_Result> results = [];
  RiskStatus? destRisk;

  @override
  void initState() {
    super.initState();
    _loadQuick();
  }

  Future<void> _loadQuick() async {
    final o = await AccountService().optionalProfile();
    final places = await AccountService().places();
    _Spot? at(String k, String name) {
      final lat = double.tryParse(o['${k}Lat'] ?? ''), lng = double.tryParse(o['${k}Lon'] ?? '');
      if (lat == null || lng == null) return null;
      return _Spot((o['${k}Name'] ?? '').isEmpty ? name : o['${k}Name']!, LatLng(lat, lng), address: o['${k}Address'] ?? '');
    }

    if (!mounted) return;
    setState(() => quick = [
          if (at('home', '집') case final s?) s,
          if (at('work', '직장') case final s?) s,
          for (final p in places) _Spot(p.name, p.position, address: p.address),
        ]);
  }

  _Spot _mine() {
    final here = ref.read(userLocation);
    final label = here.manual ? (ref.read(originLabelProvider) ?? '지정한 출발 위치') : (here.fromGps ? '현재 위치 (GPS)' : '구룡포 기본 위치');
    return _Spot(label, here.position, isMine: true);
  }

  @override
  void dispose() {
    fromText.dispose();
    toText.dispose();
    super.dispose();
  }

  /// 입력칸 글자 → 위치. 고른 장소가 있으면 그대로, 아니면 주소 검색(서버 → 카카오)
  Future<_Spot> _resolve(TextEditingController text, _Spot? chosen, String what) async {
    if (chosen != null && text.text == chosen.label) return chosen;
    final q = text.text.trim();
    if (q.isEmpty) throw GeocodingException('$what 주소를 입력하거나 아래에서 장소를 고르세요.');
    final r = await GeocodingService().resolve(q);
    return _Spot(r.address, r.position, address: r.address);
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
      results = [];
      destRisk = null;
    });
    try {
      final a = fromText.text.trim().isEmpty ? _mine() : await _resolve(fromText, from, '출발지');
      final b = await _resolve(toText, to, '목적지');
      for (final (s, what) in [(a, '출발지'), (b, '목적지')]) {
        if (!inServiceArea(s.position)) throw GeocodingException('$what(${s.label})가 구룡포 경로 안내 범위 밖입니다.');
      }
      if (const Distance().as(LengthUnit.Meter, a.position, b.position) < 15) {
        throw const GeocodingException('출발지와 목적지가 같은 곳입니다.');
      }
      from = a;
      to = b;
      final dest = _facility(b);
      final repository = ref.read(repo);
      Future<_Result> one(RouteType t) async {
        try {
          return _Result(t, route: await repository.routeFor(dest, UserMode.user, t, a.position));
        } catch (e) {
          return _Result(t, error: '$e');
        }
      }

      TravelSetting.mode = ref.read(travelMode);
      final rs = await Future.wait([for (final t in ref.read(travelMode).routeTypes) one(t)]);
      RiskStatus? risk;
      try {
        risk = await repository.risk(b.position);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        results = rs;
        destRisk = risk;
        fromText.text = a.label;
        toText.text = b.label;
      });
    } on GeocodingException catch (e) {
      setState(() => error = e.message);
    } catch (e) {
      setState(() => error = '경로를 찾지 못했습니다. ($e)');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Facility _facility(_Spot s) => Facility(
      id: customRouteId,
      name: s.label,
      type: FacilityType.place,
      position: s.position,
      address: s.address,
      description: '길찾기 목적지',
      distanceKm: 0,
      walkMinutes: 0,
      accessible: false);

  void _show(RouteType t) {
    startCustomRoute(ref,
        origin: from!.position, followUser: from!.isMine, destination: _facility(to!), routeType: t);
    context.go('/');
  }

  Widget _quickChips(void Function(_Spot) onPick, {bool includeMine = false}) => Wrap(spacing: 6, runSpacing: 4, children: [
        if (includeMine)
          ActionChip(avatar: const Icon(Icons.my_location, size: 16), label: Text(_mine().label), onPressed: () => onPick(_mine())),
        for (final s in quick)
          ActionChip(avatar: const Icon(Icons.place_outlined, size: 16), label: Text(s.label), onPressed: () => onPick(s)),
      ]);

  @override
  Widget build(BuildContext c) {
    final ok = results.where((r) => r.route != null).toList();
    final near = ok.where((r) => r.type == RouteType.nearest).firstOrNull?.route;
    final safe = ok.where((r) => r.type == RouteType.safest).firstOrNull?.route;
    final flat = ok.where((r) => r.type == RouteType.flat).firstOrNull?.route;
    String? advice;
    if (near != null && safe != null) {
      if (near.stillInside.length > safe.stillInside.length) {
        advice = '가까운 경로는 위험 구역을 지납니다 (${near.stillInside.join(', ')}). 안전 경로를 권합니다.';
      } else if (safe.distanceMeters - near.distanceMeters < 100) {
        advice = '가까운 경로와 안전 경로의 차이가 거의 없습니다. 안전 경로를 권합니다.';
      } else {
        advice = '안전 경로는 위험 구역을 피해 ${((safe.distanceMeters - near.distanceMeters) / 1000).toStringAsFixed(1)}km 더 깁니다.';
      }
      if (flat != null && flat.maxUphillPercent < safe.maxUphillPercent) {
        advice = '$advice 오르막이 힘들면 오르막 회피 경로 (최대 오르막 ${safe.maxUphillPercent}% → ${flat.maxUphillPercent}%).';
      }
    }
    return ListView(padding: gkPagePadding(context), children: [
      Row(children: [
        const Expanded(child: GkPageTitle('길찾기')),
        IconButton(tooltip: '출발·도착 바꾸기', icon: const Icon(Icons.swap_vert), onPressed: () {
          setState(() {
            final t = fromText.text, s = from;
            fromText.text = toText.text;
            from = to;
            toText.text = t;
            to = s;
          });
        }),
      ]),
      const Text('출발지와 목적지를 도로명 주소로 입력하거나 장소를 고르세요. 구룡포 일대 도보·자동차 경로를 안내합니다.'),
      const SizedBox(height: 8),
      // 도보·자동차 (2026-10-07) — 대시보드 경로와 같은 설정. 바꾸면 비교 결과를 지우고 다시 찾게 한다
      Wrap(spacing: 6, children: [
        for (final m in TravelMode.values)
          ChoiceChip(
              avatar: Icon(m.icon, size: 16),
              label: Text(m.label),
              selected: ref.watch(travelMode) == m,
              onSelected: (_) => setState(() {
                    ref.read(travelMode.notifier).state = m;
                    results = [];
                  })),
      ]),
      const SizedBox(height: 12),
      TextField(
          controller: fromText,
          decoration: InputDecoration(
              labelText: '출발지',
              hintText: '비우면 ${_mine().label}',
              prefixIcon: const Icon(Icons.trip_origin),
              border: const OutlineInputBorder())),
      const SizedBox(height: 4),
      _quickChips((s) => setState(() {
            from = s;
            fromText.text = s.label;
          }), includeMine: true),
      const SizedBox(height: 12),
      TextField(
          controller: toText,
          onSubmitted: (_) => busy ? null : _search(),
          decoration: const InputDecoration(
              labelText: '목적지', hintText: '예: 구룡포읍 호미로 152', prefixIcon: Icon(Icons.flag_outlined), border: OutlineInputBorder())),
      const SizedBox(height: 4),
      _quickChips((s) => setState(() {
            to = s;
            toText.text = s.label;
          })),
      const SizedBox(height: 12),
      FilledButton.icon(
          onPressed: busy ? null : _search,
          icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.alt_route),
          label: Text(busy ? '경로 계산 중…' : '경로 비교')),
      if (error != null)
        Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
      if (results.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('${from?.label} → ${to?.label}', style: const TextStyle(fontWeight: FontWeight.bold)),
        if (destRisk != null)
          Text('목적지 위험: ${destRisk!.level} · ${destRisk!.title}', style: TextStyle(color: destRisk!.color)),
        if (advice != null) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text('💡 $advice')),
        for (final r in results) _RouteOption(result: r, onShow: () => _show(r.type)),
      ],
    ]);
  }
}

class _RouteOption extends StatelessWidget {
  const _RouteOption({required this.result, required this.onShow});
  final _Result result;
  final VoidCallback onShow;
  @override
  Widget build(BuildContext c) {
    final title = result.type.label;
    final what = result.type.description;
    final r = result.route;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(switch (result.type) { RouteType.nearest => Icons.bolt, RouteType.safest => Icons.shield_outlined, RouteType.flat || RouteType.uphill => Icons.trending_flat }, color: const Color(0xff16803c)),
                const SizedBox(width: 6),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
                if (r != null) FilledButton.tonal(onPressed: onShow, child: const Text('지도에서 보기')),
              ]),
              Text(what, style: Theme.of(c).textTheme.bodySmall),
              const SizedBox(height: 6),
              if (r == null)
                Text('이 경로를 찾지 못했습니다. ${result.error ?? ''}', style: TextStyle(color: Theme.of(c).colorScheme.error))
              else ...[
                Text('${(r.distanceMeters / 1000).toStringAsFixed(1)}km · ${r.mode.label} ${r.estimatedMinutes}분 · 최대 오르막 ${r.maxUphillPercent}%',
                    style: const TextStyle(fontSize: 16)),
                if (r.avoided.isNotEmpty) Text('피한 위험 구역: ${r.avoided.join(', ')}'),
                if (r.stillInside.isNotEmpty)
                  Text('⚠ 다른 길이 없어 지나는 위험 구역: ${r.stillInside.join(', ')}', style: TextStyle(color: Theme.of(c).colorScheme.error)),
                if (!r.hazardsOk) const Text('⚠ 위험 구역 정보를 불러오지 못한 경로입니다.'),
              ],
            ])));
  }
}

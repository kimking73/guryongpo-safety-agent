import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:latlong2/latlong.dart';

import 'dashboard_parts.dart' show ShelterPickerSheet, facilityKindText;
import 'disaster_center.dart' show WhereKind;
import 'live_screens.dart' show whereNowProvider;
import 'main.dart';
import 'models/domain_models.dart';
import 'origin_picker.dart';
import 'patrol_screens.dart' show seaRoutePlanProvider;
import 'services/account_service.dart';
import 'services/geocoding_service.dart';
import 'services/location_service.dart';
import 'ui/tokens.dart';
import 'ui/widgets.dart';

/// 웹 대시보드·방재단 현황 지도의 '경로 안내' 한 덩어리 (2026-10-10 사용자 요청, 두 화면이 같은 것을 쓴다).
/// 1줄: 출발: [ ] → 도착: [ ] + 도보/자동차. 누르면 집·현위치·내 장소를 고르거나 주소로 찾는다 (도착은 대피소도).
/// 2줄: 경로 방식(최단·안전·오르막 회피). 3줄: 설명 + 출발↔도착 바꾸기·종료·시간.
/// 출발지는 경로에만 쓴다 (routeOriginPoint) — 앱의 현재 위치(위험도·AI 기준)는 그대로
class RoutePlanner extends ConsumerWidget {
  const RoutePlanner({super.key});

  static const _h = 32.0; // 버튼 높이 (compact)

  /// 지금 출발점. 고른 곳이 없으면 현위치
  static LatLng _originAt(WidgetRef ref) => ref.read(routeOriginPoint)?.at ?? ref.read(userLocation).position;

  /// 아무 곳(집·내 장소·주소·현위치)으로 가는 경로 — 길찾기 경로(customRouteId)로 그린다
  static void _routeTo(WidgetRef ref, RoutePoint to) => startCustomRoute(ref,
      origin: _originAt(ref),
      followUser: ref.read(routeOriginPoint) == null,
      destination: Facility(
          id: customRouteId,
          name: to.label,
          type: FacilityType.place,
          position: to.at,
          address: '',
          description: '경로 안내 목적지',
          distanceKm: 0,
          walkMinutes: 0,
          accessible: false),
      routeType: ref.read(routeKind));

  /// 출발지를 바꾸면 그리던 경로를 같은 목적지로 다시 받는다
  static void _setOrigin(WidgetRef ref, RoutePoint? p) {
    ref.read(routeOriginPoint.notifier).state = p;
    final id = ref.read(routeFacilityId);
    if (id == null) return;
    final dest = routeDestination(ref, id);
    if (dest == null) return;
    if (id == customRouteId || id == aiRouteId) {
      _routeTo(ref, RoutePoint(dest.name, dest.position));
    } else {
      startRouteToShelter(ref, id, routeType: ref.read(routeKind));
    }
  }

  /// 출발 'GPS 선택'으로 지도를 누른 곳 = 현재 위치 (GPS로 받은 것처럼, 2026-10-11).
  /// 앱의 현재 위치가 바뀌므로 바다·육지 판별(whereNowProvider)이 다시 돌고, 바다면 경로 안내에 해상 경로가 나온다
  static Future<void> useMapPoint(BuildContext context, WidgetRef ref, LatLng p) async {
    ref.read(mapPickMode.notifier).state = false;
    if (!inServiceArea(p)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('구룡포 서비스 지역(경로 안내 범위) 밖이에요. 다른 곳을 눌러 주세요.')));
      ref.read(mapPickMode.notifier).state = true;
      return;
    }
    await chooseOrigin(ref, p, 'GPS 선택 위치');
    final where = await ref.read(whereNowProvider.future);
    if (where.kind == WhereKind.sea) {
      // 바다: 해상 경로(SeaRoutePanel)가 그린다 — 그리던 육상 경로는 닫는다
      ref.read(routeOriginPoint.notifier).state = null;
      ref.read(routeFacilityId.notifier).state = null;
      ref.read(seaRouteOff.notifier).state = false;
    } else {
      // 육지: 그리던 육상 경로를 새 위치에서 다시 받는다
      _setOrigin(ref, null);
    }
  }

  /// 바다 위에서 현위치 출발 = 해상 경로 안내 중 (육지 출발지를 고르면 일반 경로)
  static bool _seaMode(WidgetRef ref) =>
      ref.read(routeOriginPoint) == null && ref.read(whereNowProvider).valueOrNull?.kind == WhereKind.sea;

  /// 출발 ↔ 도착
  static void _swap(WidgetRef ref) {
    final id = ref.read(routeFacilityId);
    final dest = id == null ? null : routeDestination(ref, id);
    if (dest == null) return;
    final from = ref.read(routeOriginPoint) ?? RoutePoint('현위치', ref.read(userLocation).position);
    ref.read(routeOriginPoint.notifier).state = RoutePoint(dest.name, dest.position);
    _routeTo(ref, from);
  }

  /// 출발·도착 고르기: 주소 검색 + 현위치·집·내 장소 (+ 도착은 가까운 대피소·대피소 목록)
  static Future<void> _pick(BuildContext context, WidgetRef ref, {required bool origin}) async {
    final o = await AccountService().optionalProfile();
    final places = await AccountService().places();
    if (!context.mounted) return;
    final homeLat = double.tryParse(o['homeLat'] ?? ''), homeLon = double.tryParse(o['homeLon'] ?? '');
    final home = homeLat == null || homeLon == null
        ? null
        : RoutePoint((o['homeName'] ?? '').trim().isEmpty ? '집' : o['homeName']!.trim(), LatLng(homeLat, homeLon));
    void toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    // 바다 위 해상 경로의 도착 (2026-10-11): 고른 곳을 해상 경로 도착으로 (null = 항구에서 가장 가까운 대피소)
    final sea = !origin && _seaMode(ref);
    void seaTo(RoutePoint? p) {
      ref.read(seaDestPoint.notifier).state = p;
      ref.read(seaRouteOff.notifier).state = false;
    }

    void choose(RoutePoint? p) {
      if (p != null && !inServiceArea(p.at)) {
        toast('구룡포 서비스 지역(경로 안내 범위) 밖이라 쓸 수 없어요.');
        return;
      }
      if (origin) {
        // 집·내 장소·직접 입력을 고르면 'GPS 선택'으로 정해 둔 현재 위치는 풀고 GPS로 돌아간다
        if (p != null && ref.read(userLocation).manual) useGpsOrigin(ref);
        ref.read(seaRouteOff.notifier).state = false;
        _setOrigin(ref, p);
      } else if (sea) {
        seaTo(p);
      } else {
        _routeTo(ref, p ?? RoutePoint('현위치', ref.read(userLocation).position));
      }
    }

    final result = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => _PointSheet(origin: origin, home: home, places: places),
    );
    if (!context.mounted || result == null) return;
    switch (result) {
      case 'cur':
        if (origin) {
          final note = await useGpsOrigin(ref);
          if (note != null && context.mounted) toast(note);
        }
        choose(null);
      case 'home':
        if (home == null) {
          toast('사용자 탭에서 집 주소를 먼저 등록해 주세요');
        } else {
          choose(home);
        }
      case 'map':
        ref.read(mapPickMode.notifier).state = true;
        toast('지도에서 출발할 곳을 눌러 주세요. 바다를 누르면 해상 경로를 안내해요.');
      case 'nearest':
        if (sea) {
          seaTo(null);
        } else {
          startRouteToShelter(ref, nearestShelterId(ref), routeType: ref.read(routeKind));
        }
      case 'shelters':
        if (sea) {
          final f = await showModalBottomSheet<Facility>(
              context: context, showDragHandle: true, builder: (_) => const _FacilityListSheet());
          if (f != null) seaTo(RoutePoint(f.name, f.position));
        } else {
          await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (_) => const ShelterPickerSheet());
        }
      case RoutePoint p:
        choose(p);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final here = ref.watch(userLocation);
    final from = ref.watch(routeOriginPoint);
    final mode = ref.watch(travelMode);
    final kind = ref.watch(routeKind);
    final id = ref.watch(routeFacilityId);
    final routeAsync = id == null ? null : ref.watch(routeProvider(id));
    final route = routeAsync?.valueOrNull;
    final dest = id == null ? null : routeDestination(ref, id);
    String km(int m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)}km' : '${m}m';
    final picking = ref.watch(mapPickMode);
    final atSea = ref.watch(whereNowProvider).valueOrNull?.kind == WhereKind.sea;
    final originButton = RouteEndButton(
      title: '출발',
      icon: from != null
          ? FontAwesomeIcons.locationDot
          : here.manual
              ? FontAwesomeIcons.mapPin
              : FontAwesomeIcons.locationCrosshairs,
      label: from?.label ??
          (here.manual
              ? (ref.watch(originLabelProvider) ?? 'GPS 선택 위치')
              : here.fromGps
                  ? '현위치'
                  : '현위치 (기본 위치)'),
      onTap: () => _pick(context, ref, origin: true),
    );
    // 'GPS 선택' 중: 지도를 누르면 그곳이 현재 위치 (바다면 해상 경로)
    final pickBanner = Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(color: Ds.soft, borderRadius: BorderRadius.circular(Ds.pill)),
      child: Row(children: [
        const FaIcon(FontAwesomeIcons.handPointer, size: 13, color: Ds.navy),
        const SizedBox(width: 8),
        Expanded(
            child: Text('지도에서 출발할 곳을 눌러 주세요. 바다를 누르면 해상 경로를 안내해요.',
                style: dsText(13, weight: FontWeight.w700, color: Ds.navy))),
        TextButton(onPressed: () => ref.read(mapPickMode.notifier).state = false, child: const Text('취소')),
      ]),
    );
    // 바다 위: 해상 경로는 위 '경로 안내' 칸(SeaRoutePanel)이 그린다. 여기서도 출발·도착을 바꾸고 X로 끝낼 수 있게
    // (2026-10-11 사용자 요청). 도착을 안 골랐으면 경로 서버가 고른 대피소(항구에서 가장 가까운 곳)를 보여 준다
    if (atSea && from == null) {
      final off = ref.watch(seaRouteOff);
      final plan = off ? null : ref.watch(seaRoutePlanProvider).valueOrNull;
      final seaDest = ref.watch(seaDestPoint);
      final serverDest = plan?.destination?['name'];
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: originButton),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: FaIcon(FontAwesomeIcons.arrowRightLong, size: 12, color: Ds.muted),
          ),
          Expanded(
            child: RouteEndButton(
              title: '도착',
              icon: FontAwesomeIcons.houseFlag,
              label: seaDest?.label ?? (serverDest is String && serverDest.isNotEmpty ? serverDest : '가까운 대피소'),
              onTap: () => _pick(context, ref, origin: false),
            ),
          ),
          const SizedBox(width: 6),
          if (off)
            PillButton('경로 보기',
                expand: false,
                height: _h,
                fontSize: 13,
                icon: FontAwesomeIcons.diamondTurnRight,
                onPressed: () => ref.read(seaRouteOff.notifier).state = false)
          else
            CircleButton(FontAwesomeIcons.xmark,
                size: _h,
                iconSize: 13,
                bg: Ds.bg,
                tooltip: '경로 안내 종료',
                onPressed: () => ref.read(seaRouteOff.notifier).state = true),
        ]),
        if (picking) pickBanner,
        if (off)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: Text("해상 경로 안내를 끝냈어요. 출발·도착을 바꾸거나 '경로 보기'를 누르면 다시 안내해요.",
                style: dsText(13, color: Ds.muted, height: 1.4)),
          ),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: originButton),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: FaIcon(FontAwesomeIcons.arrowRightLong, size: 12, color: Ds.muted),
        ),
        Expanded(
          child: RouteEndButton(
            title: '도착',
            icon: FontAwesomeIcons.houseFlag,
            label: dest?.name ?? '가까운 대피소',
            onTap: () => _pick(context, ref, origin: false),
          ),
        ),
        const SizedBox(width: 6),
        Semantics(
          label: '이동 수단',
          child: SegmentedPill<TravelMode>(
            expand: false,
            height: _h,
            items: const [
              (TravelMode.walk, null, FontAwesomeIcons.personWalking),
              (TravelMode.car, null, FontAwesomeIcons.car),
            ],
            value: mode,
            onChanged: (m) {
              ref.read(travelMode.notifier).state = m;
              // 자동차는 오르막 회피가 없다 — 켜 둔 오르막 회피는 끈다
              if (!m.routeTypes.contains(RouteType.flat)) {
                ref.read(routeKind.notifier).state = routeTypeOf(safe: kind.avoidsHazards, uphill: false);
              }
            },
          ),
        ),
      ]),
      if (picking) pickBanner,
      const SizedBox(height: 6),
      // 최단 거리 = 둘 다 끔. 안전한 경로·오르막 회피는 따로 켜고 끈다 (2026-10-11 사용자 요청: 함께 고를 수 있다)
      Semantics(
        label: '경로 방식 선택',
        child: RouteOptions(
          kind: kind,
          uphillOk: mode.routeTypes.contains(RouteType.flat),
          onChanged: (t) => ref.read(routeKind.notifier).state = t,
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
                switch (kind) {
                  RouteType.nearest => '가장 짧은 길이에요. 위험 구역을 피하지 않고, 지나는 구역은 알려 드려요.',
                  RouteType.safest => '침수·산사태 위험 구역(주의 이상)을 피해서 가요.',
                  RouteType.flat => '위험 구역을 피하면서 가파른 오르막을 되도록 줄여요.',
                  RouteType.uphill => '가파른 오르막을 되도록 줄여요. 위험 구역은 피하지 않고, 지나는 구역은 알려 드려요.',
                },
                style: dsText(13, color: Ds.muted, height: 1.4)),
          ),
        ),
        const SizedBox(width: 6),
        if (id == null)
          PillButton('경로 보기',
              expand: false,
              height: _h,
              fontSize: 13,
              icon: FontAwesomeIcons.diamondTurnRight,
              onPressed: () => startRouteToShelter(ref, nearestShelterId(ref), routeType: kind))
        else ...[
          CircleButton(FontAwesomeIcons.arrowRightArrowLeft,
              size: _h, iconSize: 13, bg: Ds.bg, tooltip: '출발·도착 바꾸기', onPressed: () => _swap(ref)),
          const SizedBox(width: 4),
          CircleButton(FontAwesomeIcons.xmark,
              size: _h,
              iconSize: 13,
              bg: Ds.bg,
              tooltip: '경로 안내 종료',
              onPressed: () => ref.read(routeFacilityId.notifier).state = null),
          const SizedBox(width: 4),
          Container(
            height: _h,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: Ds.navy, borderRadius: BorderRadius.circular(Ds.pill)),
            alignment: Alignment.center,
            child: routeAsync!.isLoading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text.rich(TextSpan(children: [
                    TextSpan(
                        text: route == null ? '경로 없음' : '${route.estimatedMinutes}분',
                        style: dsText(14, weight: FontWeight.w800, color: Colors.white)),
                    if (route != null)
                      TextSpan(text: ' ${km(route.distanceMeters)}', style: dsText(11, weight: FontWeight.w600, color: Colors.white)),
                  ])),
          ),
        ],
      ]),
    ]);
  }
}

/// 경로 방식: [최단 거리 ✓|안전한 경로 ✓] 중 하나 + [오르막 회피 ✓] 켜고 끄기 → nearest · safest · uphill(최단+오르막) · flat(안전+오르막)
/// 휴대폰 대시보드 경로 안내 줄(RouteSummaryRows)도 같은 것을 쓴다 (2026-10-11)
class RouteOptions extends StatelessWidget {
  const RouteOptions({super.key, required this.kind, required this.uphillOk, required this.onChanged, this.height = RoutePlanner._h});
  final RouteType kind;
  final bool uphillOk;
  final double height;
  final ValueChanged<RouteType> onChanged;

  @override
  Widget build(BuildContext context) {
    final safe = kind.avoidsHazards, uphill = uphillOk && kind.avoidsUphill;
    // 켜도 원래 아이콘은 그대로 두고, 켜진 것은 글자 뒤 체크로 알린다 (2026-10-11 사용자 요청: 켜면 아이콘이 사라졌다)
    Widget seg(String label, FaIconData icon, bool on, VoidCallback? onTap, {bool toggle = true, String? tooltip}) {
      final fg = onTap == null ? Ds.off : (on ? Colors.white : Ds.navy);
      Widget body = Semantics(
        button: !toggle,
        toggled: toggle ? on : null,
        selected: toggle ? null : on,
        child: Material(
          color: on ? Ds.navy : Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: height,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                FaIcon(icon, size: 11, color: fg),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: dsText(14, weight: FontWeight.w800, color: onTap == null ? Ds.off : (on ? Colors.white : Ds.sub))),
                ),
                if (toggle && on) ...[
                  const SizedBox(width: 4),
                  const FaIcon(FontAwesomeIcons.check, size: 10, color: Colors.white),
                ],
              ]),
            ),
          ),
        ),
      );
      if (tooltip != null) body = Tooltip(message: tooltip, child: body);
      return Expanded(child: body);
    }
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Ds.bg, borderRadius: BorderRadius.circular(Ds.pill)),
      child: Row(children: [
        // 최단 거리 ↔ 안전한 경로는 둘 중 하나 (위험 구역을 피하는지), 오르막 회피는 어느 쪽과도 함께 켠다
        // (2026-10-11 사용자 요청: 최단 거리 + 오르막 회피 = 위험 구역은 그대로, 오르막만 줄이기)
        seg('최단 거리', FontAwesomeIcons.arrowRightLong, !safe, () => onChanged(routeTypeOf(safe: false, uphill: uphill))),
        const SizedBox(width: 2),
        seg('안전한 경로', FontAwesomeIcons.shieldHalved, safe, () => onChanged(routeTypeOf(safe: !safe, uphill: uphill))),
        // 자동차면 오르막 회피는 숨기지 않고 흐리게 둔다 (버튼·아이콘이 사라지지 않게)
        const SizedBox(width: 2),
        seg('오르막 회피', FontAwesomeIcons.arrowTrendDown, uphill,
            uphillOk ? () => onChanged(routeTypeOf(safe: safe, uphill: !uphill)) : null,
            tooltip: uphillOk ? null : '자동차는 오르막 회피를 쓸 수 없어요 (도보만)'),
      ]),
    );
  }
}

/// '출발: 현위치 ▾' 같은 한 칸 (방재단 현황 '내 방문 경로' 출발 칸도 쓴다)
class RouteEndButton extends StatelessWidget {
  const RouteEndButton({super.key, required this.title, required this.icon, required this.label, required this.onTap});
  final String title, label;
  final FaIconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '$title 선택: $label',
        excludeSemantics: true,
        child: Material(
          color: Ds.bg,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: RoutePlanner._h,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(children: [
                  Text('$title:', style: dsText(12, weight: FontWeight.w700, color: Ds.muted)),
                  const SizedBox(width: 5),
                  FaIcon(icon, size: 11, color: Ds.navy),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(13, weight: FontWeight.w800)),
                  ),
                  const Icon(Icons.expand_more_rounded, size: 16, color: Ds.muted),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// 해상 경로 도착으로 쓸 대피소·의료시설 목록 (고른 시설을 돌려준다, 2026-10-11). 대피소 먼저, 가까운 순
class _FacilityListSheet extends ConsumerWidget {
  const _FacilityListSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = [...?ref.watch(facilitiesProvider).valueOrNull]..sort((a, b) {
        final sa = a.type == FacilityType.shelter ? 0 : 1, sb = b.type == FacilityType.shelter ? 0 : 1;
        return sa != sb ? sa - sb : a.distanceKm.compareTo(b.distanceKm);
      });
    return SafeArea(
      child: ListView(shrinkWrap: true, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('도착할 대피소·의료시설', style: dsText(18, weight: FontWeight.w800)),
        ),
        if (list.isEmpty)
          const ListTile(title: Text('시설 목록을 불러오지 못했어요.'))
        else
          for (final f in list)
            ListTile(
              dense: true,
              leading: FaIcon(f.type == FacilityType.shelter ? FontAwesomeIcons.houseFlag : FontAwesomeIcons.hospital,
                  size: 16, color: Ds.navy),
              title: Text(f.name, style: dsText(15, weight: FontWeight.w700)),
              subtitle: Text(facilityKindText(f), style: dsText(12, color: Ds.muted)),
              onTap: () => Navigator.pop(context, f),
            ),
      ]),
    );
  }
}

/// 출발·도착 고르는 시트. 돌려주는 값: 'cur' · 'home' · 'map'(GPS 선택) · 'nearest' · 'shelters' · RoutePoint(내 장소·직접 입력)
class _PointSheet extends StatefulWidget {
  const _PointSheet({required this.origin, required this.home, required this.places});
  final bool origin;
  final RoutePoint? home;
  final List<SavedPlace> places;

  @override
  State<_PointSheet> createState() => _PointSheetState();
}

class _PointSheetState extends State<_PointSheet> {
  final query = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (query.text.trim().isEmpty || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await GeocodingService().resolve(query.text);
      if (mounted) Navigator.pop(context, RoutePoint(r.address, r.position));
    } on GeocodingException catch (e) {
      setState(() => error = e.message);
    } catch (_) {
      setState(() => error = '주소를 찾지 못했습니다. 도로명 주소를 확인해 주세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = widget.home;
    Widget tile(FaIconData icon, String title, Object value, {String? sub}) => ListTile(
          dense: true,
          leading: FaIcon(icon, size: 16, color: Ds.navy),
          title: Text(title, style: dsText(15, weight: FontWeight.w700)),
          subtitle: sub == null || sub.isEmpty ? null : Text(sub, style: dsText(12, color: Ds.muted)),
          onTap: () => Navigator.pop(context, value),
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        // 출발: 현위치 · 집 · 내 장소 · GPS 선택 · 직접 입력 (2026-10-11 사용자 요청). 도착은 GPS 선택 대신 대피소
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(widget.origin ? '출발 위치' : '도착 위치', style: dsText(18, weight: FontWeight.w800)),
          ),
          tile(FontAwesomeIcons.locationCrosshairs, '현위치', 'cur', sub: widget.origin ? '휴대폰·브라우저 GPS로 받은 지금 위치' : null),
          tile(FontAwesomeIcons.house, home == null || home.label == '집' ? '집' : '집 · ${home.label}', 'home',
              sub: home == null ? '사용자 탭에서 집 주소를 등록하면 쓸 수 있어요' : null),
          if (widget.places.isEmpty)
            ListTile(
              dense: true,
              enabled: false,
              leading: const FaIcon(FontAwesomeIcons.bookmark, size: 16, color: Ds.off),
              title: Text('내 장소', style: dsText(15, weight: FontWeight.w700, color: Ds.off)),
              subtitle: Text('사용자 탭에서 내 장소를 추가하면 쓸 수 있어요', style: dsText(12, color: Ds.muted)),
            )
          else
            for (final p in widget.places)
              tile(FontAwesomeIcons.bookmark, '내 장소 · ${p.name}', RoutePoint(p.name, p.position), sub: p.address),
          if (widget.origin)
            tile(FontAwesomeIcons.mapPin, 'GPS 선택', 'map', sub: '대시보드 지도에서 직접 눌러 고르기 · 바다를 누르면 해상 경로')
          else ...[
            tile(FontAwesomeIcons.houseFlag, '가까운 대피소', 'nearest'),
            tile(FontAwesomeIcons.listUl, '대피소·의료시설 목록에서 고르기', 'shelters'),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const FaIcon(FontAwesomeIcons.keyboard, size: 16, color: Ds.navy),
              const SizedBox(width: 16),
              Text('직접 입력', style: dsText(15, weight: FontWeight.w700)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: TextField(
              controller: query,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '도로명 주소 (예: 구룡포읍 호미로 152)',
                errorText: error,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(tooltip: '검색', icon: const Icon(Icons.arrow_forward_rounded), onPressed: _search),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'disaster_center.dart' show WhereKind;
import 'live_screens.dart';
import 'main.dart';
import 'models/domain_models.dart';
import 'origin_picker.dart';
import 'route_planner.dart' show RouteEndButton;
import 'services/geocoding_service.dart';
import 'ui/gk_theme.dart';
import 'services/live_api.dart';
import 'services/demo_live_api.dart';
import 'services/prototype_safety_store.dart';
import 'ui/gk_widgets.dart';
import 'ui/tokens.dart' show Ds, dsText;
import 'ui/widgets.dart' show PillButton, SegmentedPill;
import 'services/location_service.dart';
import 'services/polyline.dart';

/// C8 (2026-10-05) 실측 화면: 취약 가구 등록 + 민감정보 동의(별도 화면), 방재단 대시보드(우선순위 명단·지도),
/// 방문 결과 입력, 방재단 대리 등록, 해상 → 최근접 항 → 육상 경로(B11 /api/route/sea).
/// 서버: server/app/routers/user.py(/user/household)·admin.py(/admin/*), route/guardian_route/sea.py.
/// 시연 모드 화면은 prototype_safety_screens.dart (기기 저장).

// ------------------------------------------------------------------ 공통
/// 방재단 전용 화면에 들어갈 수 있는 역할 (사용자 결정 2026-10-05: 돌봄 담당 caregiver 제외).
/// 서버 require_staff는 caregiver도 받지만, 앱의 방재단 화면은 방재단·관리자만 연다.
const patrolRoles = {'responder', 'admin'};
bool isPatrolRole(String? role) => patrolRoles.contains(role);
const roleKo = {'resident': '주민', 'responder': '방재단', 'caregiver': '돌봄 담당', 'admin': '관리자'};

/// 서버 HouseholdNeed 코드 → 한글
const needKo = {
  'elderly': '고령', 'living_alone': '독거', 'mobility_limited': '지체', 'wheelchair': '휠체어', 'bedridden': '와상',
  'hearing': '청각', 'vision': '시각', 'cognitive': '인지', 'medical_device': '의료기기', 'infant': '영유아', 'pet': '반려동물',
};

/// 취약 가구 분류 — 방재단 지도 아이콘·필터. 장애인 가구는 대피 상황이 아니어도 지도에 표시 (2026-10-05).
/// 독거노인 분류는 뺐다 — 서비스 대상이 아님 (사용자 결정 2026-10-10)
const disabilityNeeds = {'wheelchair', 'hearing', 'vision', 'cognitive', 'bedridden', 'mobility_limited'};
Set<String> _needSet(Object? needs) => {for (final x in needs as List? ?? const []) '$x'};
bool isDisabledHousehold(Object? needs) => _needSet(needs).any(disabilityNeeds.contains);

enum VulnerableKind { disabled, other }

/// 지도 아이콘 하나를 고른다: 장애가 있으면 장애인, 그 밖은 기타
VulnerableKind vulnerableKind(Object? needs) => isDisabledHousehold(needs) ? VulnerableKind.disabled : VulnerableKind.other;
const kindKo = {VulnerableKind.disabled: '장애인', VulnerableKind.other: '기타 취약'};
const kindIcon = {VulnerableKind.disabled: Icons.accessible, VulnerableKind.other: Icons.home};
const kindColor = {
  VulnerableKind.disabled: Color(0xff6a1b9a),
  VulnerableKind.other: Color(0xff546e7a),
};

/// 지도·목록 필터
enum HouseholdFilter { all, disabled }

bool matchesFilter(HouseholdFilter f, Object? needs) => switch (f) {
      HouseholdFilter.all => true,
      HouseholdFilter.disabled => isDisabledHousehold(needs),
    };

/// 대피 상태 (A12) → 한글·색. 명단 정렬도 서버(priority_rank)를 따르고 앱은 표시만 한다
const statusKo = {'need_help': '도움 필요', 'no_response': '응답 없음', 'evacuating': '대피 중', 'evacuated': '대피 완료'};
Color statusColor(String? s) => switch (s) {
      'need_help' => GK.red,
      'no_response' => const Color(0xff8e2a1e),
      'evacuating' => const Color(0xffc25a0c),
      'evacuated' => const Color(0xff178a4c),
      _ => Colors.grey,
    };

/// 방문 결과 (서버 VisitInput.result) — 앞 3개는 대상 상태를 '대피 완료'로 바꾼다
const visitResults = <(String, String)>[
  ('evacuated_with_help', '함께 대피함'),
  ('already_evacuated', '이미 대피함'),
  ('transported', '차량·구급 이송'),
  ('refused', '대피 거부'),
  ('not_home', '부재'),
  ('other', '기타'),
];
final visitKo = {for (final r in visitResults) r.$1: r.$2};

String needsText(Object? needs) => [for (final n in needs as List? ?? const []) needKo[n] ?? '$n'].join(', ');

LatLng? latLng(Object? loc) {
  if (loc is! Map) return null;
  final lat = loc['lat'], lng = loc['lng'] ?? loc['lon'];
  return lat is num && lng is num ? LatLng(lat.toDouble(), lng.toDouble()) : null;
}

/// GeoJSON Polygon·MultiPolygon → 지도 다각형 외곽선들
List<List<LatLng>> geoJsonRings(Object? geom) {
  if (geom is! Map) return const [];
  List<LatLng> ring(Object? r) => [for (final p in r as List) LatLng(((p as List)[1] as num).toDouble(), (p[0] as num).toDouble())];
  return switch (geom['type']) {
    'Polygon' => [ring((geom['coordinates'] as List).first)],
    'MultiPolygon' => [for (final poly in geom['coordinates'] as List) ring((poly as List).first)],
    _ => const [],
  };
}

TileLayer _tiles() => TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'kr.guryong.guardian');
const _osm = RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]);

/// 지도를 눌러 한 점 고르기 (가구 위치 등)
Future<LatLng?> pickPointOnMap(BuildContext c, {required LatLng start, required String title}) =>
    showDialog<LatLng>(context: c, builder: (_) => _PointPickDialog(start: start, title: title));

class _PointPickDialog extends StatefulWidget {
  const _PointPickDialog({required this.start, required this.title});
  final LatLng start;
  final String title;
  @override
  State<_PointPickDialog> createState() => _PointPickDialogState();
}

class _PointPickDialogState extends State<_PointPickDialog> {
  LatLng? picked;
  @override
  Widget build(BuildContext c) => Dialog.fullscreen(
      child: Scaffold(
          appBar: AppBar(title: Text(widget.title), actions: [
            TextButton(onPressed: picked == null ? null : () => Navigator.pop(c, picked), child: const Text('이 위치로')),
          ]),
          body: FlutterMap(
              options: MapOptions(
                  initialCenter: widget.start,
                  initialZoom: 16,
                  minZoom: 11,
                  cameraConstraint: CameraConstraint.containCenter(bounds: guryongpoBounds),
                  onTap: (_, p) => setState(() => picked = p)),
              children: [
                _tiles(),
                MarkerLayer(markers: [
                  if (picked != null)
                    Marker(point: picked!, width: 44, height: 44, alignment: Alignment.topCenter,
                        child: const Icon(Icons.location_on, color: Colors.red, size: 44)),
                ]),
                _osm,
              ])));
}

// ------------------------------------------------------------------ 가구 입력 (본인 등록·대리 등록 공통)
class _HouseholdDraft {
  final label = TextEditingController(), address = TextEditingController(), phone = TextEditingController(),
      note = TextEditingController();
  final needs = <String>{};
  int members = 1;
  LatLng? location;

  void dispose() {
    for (final t in [label, address, phone, note]) {
      t.dispose();
    }
  }

  void fill(Map<String, dynamic> h) {
    label.text = '${h['label'] ?? ''}';
    address.text = '${h['address'] ?? ''}';
    phone.text = '${h['phone'] ?? ''}';
    note.text = '${h['note'] ?? ''}';
    members = (h['members'] as num?)?.toInt() ?? 1;
    needs
      ..clear()
      ..addAll([for (final n in h['needs'] as List? ?? const []) '$n']);
    location = latLng(h['location']);
  }

  /// 서버 SelfHouseholdInput·HouseholdInput 공통 칸
  Map<String, dynamic> body() => {
        if (label.text.trim().isNotEmpty) 'label': label.text.trim(),
        if (address.text.trim().isNotEmpty) 'address': address.text.trim(),
        'location': {'lat': location!.latitude, 'lng': location!.longitude},
        if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
        'members': members,
        'needs': needs.toList(),
        if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
      };
}

class _HouseholdFields extends StatelessWidget {
  const _HouseholdFields({required this.draft, required this.onChanged, required this.labelHint, required this.here});
  final _HouseholdDraft draft;
  final VoidCallback onChanged;
  final String labelHint;
  final LatLng here;

  @override
  Widget build(BuildContext c) {
    final loc = draft.location;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: draft.label, decoration: InputDecoration(labelText: labelHint, border: const OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: draft.address, decoration: const InputDecoration(labelText: '주소 (선택)', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: draft.phone, keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: '연락처', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      Card(
          child: ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(loc == null ? '집 위치를 정해 주세요' : '집 위치 (${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)})'),
              subtitle: const Text('대피 상황 때 방재단이 이 위치로 찾아갑니다'),
              trailing: Wrap(spacing: 4, children: [
                TextButton(
                    onPressed: () {
                      draft.location = here;
                      onChanged();
                    },
                    child: const Text('현재 위치')),
                TextButton(
                    onPressed: () async {
                      final p = await pickPointOnMap(c, start: loc ?? here, title: '지도를 눌러 집 위치 고르기');
                      if (p != null) {
                        draft.location = p;
                        onChanged();
                      }
                    },
                    child: const Text('지도에서')),
              ]))),
      Row(children: [
        const Text('함께 사는 사람 수'),
        IconButton(onPressed: draft.members > 1 ? () {
          draft.members--;
          onChanged();
        } : null, icon: const Icon(Icons.remove)),
        Text('${draft.members}명'),
        IconButton(onPressed: () {
          draft.members++;
          onChanged();
        }, icon: const Icon(Icons.add)),
      ]),
      const Text('대피에 도움이 필요한 점 (건강·장애 정보 — 다음 화면에서 따로 동의)'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in needKo.entries)
          FilterChip(
              label: Text(e.value),
              selected: draft.needs.contains(e.key),
              onSelected: (on) {
                on ? draft.needs.add(e.key) : draft.needs.remove(e.key);
                onChanged();
              }),
      ]),
      const SizedBox(height: 8),
      TextField(controller: draft.note, maxLength: 300,
          decoration: const InputDecoration(labelText: '방재단이 알아야 할 점 (선택)', border: OutlineInputBorder())),
    ]);
  }
}

// ------------------------------------------------------------------ 민감정보 동의 (일반 동의와 별도 화면)
/// 동의서 버전 — 서버 households.CONSENT_VERSION 과 같게 둔다
const consentVersion = 'v1';

/// 건강·장애 등 민감정보 수집·이용과 방재단 제공에 대한 별도 동의 (개인정보 보호법 제23조).
/// 두 항목을 모두 체크해야 [true]로 닫힌다. 서버 PUT /user/household 의 consent:true 가 이 동의다.
class SensitiveConsentScreen extends StatefulWidget {
  const SensitiveConsentScreen({super.key, required this.needs, this.hasNote = false});
  final List<String> needs;
  final bool hasNote;
  @override
  State<SensitiveConsentScreen> createState() => _SensitiveConsentScreenState();
}

class _SensitiveConsentScreenState extends State<SensitiveConsentScreen> {
  bool collect = false, share = false;

  @override
  Widget build(BuildContext c) {
    final items = [
      '이름 또는 호칭, 주소, 집 위치, 연락처, 함께 사는 사람 수',
      if (widget.needs.isNotEmpty) '건강·장애 관련 정보: ${[for (final n in widget.needs) needKo[n] ?? n].join(', ')}',
      if (widget.hasNote) '방재단에게 남긴 메모',
    ];
    Widget section(String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(body),
        ]));
    return Scaffold(
        appBar: AppBar(title: const Text('민감정보 수집·이용 동의')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('이 동의는 앱 이용 약관·일반 개인정보 동의와 별도입니다. 동의하지 않아도 앱의 다른 기능은 그대로 쓸 수 있습니다.'),
          const SizedBox(height: 12),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    section('수집 항목', items.map((x) => '• $x').join('\n')),
                    section('목적', '재난(침수·산사태·태풍 등)으로 대피 상황이 생기면 구룡포 자율방재단이 도움이 필요한 가구를 먼저 확인하고 방문하기 위해'),
                    section('받는 사람', '구룡가디언에 등록된 방재단·관리자 (방재단 전용 화면에서만 보입니다)'),
                    section('보관 기간', '동의를 철회하거나 계정을 지울 때까지. 철회하면 바로 지웁니다.'),
                    section('동의하지 않을 권리', '동의하지 않을 수 있습니다. 그 경우 가구 등록만 되지 않고, 대피 경고·경로 안내는 그대로 받습니다.'),
                    Text('동의서 버전 $consentVersion', style: Theme.of(c).textTheme.bodySmall),
                  ]))),
          CheckboxListTile(
              value: collect,
              onChanged: (v) => setState(() => collect = v ?? false),
              title: const Text('(필수) 위 민감정보를 수집·이용하는 데 동의합니다')),
          CheckboxListTile(
              value: share,
              onChanged: (v) => setState(() => share = v ?? false),
              title: const Text('(필수) 대피 상황 때 방재단에게 제공하는 데 동의합니다')),
          const SizedBox(height: 8),
          FilledButton(onPressed: collect && share ? () => Navigator.pop(c, true) : null, child: const Text('동의하고 등록')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('동의하지 않음')),
        ]));
  }
}

// ------------------------------------------------------------------ 내 취약 가구 등록 (실측)
class LiveHouseholdScreen extends ConsumerStatefulWidget {
  const LiveHouseholdScreen({super.key});
  @override
  ConsumerState<LiveHouseholdScreen> createState() => _LiveHouseholdScreenState();
}

class _LiveHouseholdScreenState extends ConsumerState<LiveHouseholdScreen> {
  final draft = _HouseholdDraft();
  Map<String, dynamic>? saved;
  bool busy = false, loaded = false;
  String? message;

  @override
  void initState() {
    super.initState();
    ref.read(liveApiProvider).myHousehold().then((h) {
      if (!mounted) return;
      setState(() {
        loaded = true;
        saved = h;
        if (h != null) draft.fill(h);
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
    draft.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (draft.location == null) {
      setState(() => message = '집 위치를 먼저 정해 주세요.');
      return;
    }
    // 저장할 때마다 동의를 새로 받는다 (서버도 저장마다 동의 시각·버전을 다시 적는다)
    final agreed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => SensitiveConsentScreen(needs: draft.needs.toList(), hasNote: draft.note.text.trim().isNotEmpty)));
    if (agreed != true) {
      setState(() => message = '동의하지 않아 등록하지 않았습니다.');
      return;
    }
    setState(() => busy = true);
    try {
      final h = await ref.read(liveApiProvider).saveHousehold({...draft.body(), 'consent': true});
      setState(() {
        saved = h;
        message = '등록했습니다. 대피 상황 때 방재단이 이 정보로 먼저 확인합니다.';
      });
    } catch (e) {
      setState(() => message = liveError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _withdraw() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('동의 철회'),
                content: const Text('동의를 철회하면 등록한 가구 정보(건강·장애 정보 포함)를 바로 지웁니다.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('철회하고 지우기')),
                ]));
    if (ok != true) return;
    setState(() => busy = true);
    try {
      await ref.read(liveApiProvider).deleteHousehold();
      setState(() {
        saved = null;
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
    final here = ref.watch(userLocation).position;
    final consent = saved?['consent'] as Map?;
    return LivePage(title: '내 가구 등록 (취약 가구)', children: [
      const Text('고령·거동 불편 등으로 대피에 도움이 필요하면 등록하세요. 대피 상황 때 구룡포 자율방재단이 먼저 확인합니다.'),
      if (!loaded) const LinearProgressIndicator(),
      if (saved != null)
        Card(
            color: Colors.green.shade50,
            child: ListTile(
                leading: const Icon(Icons.verified_user_outlined, color: Colors.green),
                title: Text('등록됨 · ${saved!['label'] ?? ''}'),
                subtitle: Text([
                  if (consent != null) '민감정보 동의 ${hhmm(consent['at'])} · 동의서 ${consent['version'] ?? '-'}',
                  if (saved!['landslide_zone'] != null) '⚠ ${saved!['landslide_zone']}',
                ].join('\n')))),
      const SizedBox(height: 8),
      _HouseholdFields(draft: draft, onChanged: () => setState(() {}), labelHint: '이름 또는 호칭 (예: 김○○ 댁)', here: here),
      FilledButton(onPressed: busy ? null : _save, child: Text(saved != null ? '수정 저장 (동의 다시 받기)' : '다음: 민감정보 동의')),
      if (saved != null) TextButton(onPressed: busy ? null : _withdraw, child: const Text('동의 철회·삭제')),
      if (message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!)),
    ]);
  }
}

/// 방재단·관리자가 아니면 잠금 + 초대 코드 입력
class _PatrolGate extends ConsumerWidget {
  const _PatrolGate({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final me = ref.watch(meProvider);
    if (me.isLoading && !me.hasValue) return const DashboardLoading();
    if (me.hasError && !me.hasValue) return LoadError(message: liveError(me.error!), onRetry: () => ref.invalidate(meProvider));
    final role = '${me.valueOrNull?['role'] ?? 'resident'}';
    if (isPatrolRole(role)) return child;
    return LivePage(title: title, children: [
      Card(
          child: ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('방재단·관리자만 볼 수 있는 화면입니다'),
              subtitle: Text('지금 역할: ${roleKo[role] ?? role}. 방재단은 받은 초대 코드로 역할을 등록하세요.'))),
      const RoleClaimCard(),
    ]);
  }
}

// ------------------------------------------------------------------ 방재단 대리 등록
class LiveDelegatedHouseholdScreen extends StatelessWidget {
  const LiveDelegatedHouseholdScreen({super.key});
  @override
  Widget build(BuildContext c) => const _PatrolGate(title: '가구 대리 등록', child: _DelegatedForm());
}

class _DelegatedForm extends ConsumerStatefulWidget {
  const _DelegatedForm();
  @override
  ConsumerState<_DelegatedForm> createState() => _DelegatedFormState();
}

/// 대리 등록의 장애 유형 → 서버 HouseholdNeed (2026-10-11 사용자 요청: 장애 유형만 묻는다).
/// 지체 = 보행 불편(mobility_limited) — B13 우선순위의 장애 가점에 들어간다
const delegatedDisabilities = [('body', '지체', 'mobility_limited'), ('hear', '청각', 'hearing'), ('see', '시각', 'vision'), ('none', '해당 없음', null)];

class _DelegatedFormState extends ConsumerState<_DelegatedForm> {
  final label = TextEditingController(), address = TextEditingController(), phone = TextEditingController();
  Set<String> dis = {};
  String method = 'written';
  bool confirmed = false, busy = false;
  String? message;

  @override
  void dispose() {
    for (final t in [label, address, phone]) {
      t.dispose();
    }
    super.dispose();
  }

  void _toggleDis(String k) => setState(() {
        if (k == 'none') {
          dis = dis.contains('none') ? {} : {'none'};
        } else {
          dis = {...dis}..remove('none');
          dis.contains(k) ? dis.remove(k) : dis.add(k);
        }
      });

  /// 집 위치 = 주소를 서버가 좌표로 바꾼 곳 (따로 위치를 고르는 칸은 뺐다, 2026-10-11).
  /// 시연(앱 안 시연 가구)은 서버가 없을 수 있어 바꾸지 못하면 지금 위치로 둔다
  Future<(String, LatLng)> _locate() async {
    try {
      final r = await GeocodingService().resolve(address.text);
      return (r.address, r.position);
    } catch (_) {
      if (ref.read(liveApiProvider) is DemoLiveApi) return (address.text.trim(), ref.read(userLocation).position);
      rethrow;
    }
  }

  Future<void> _save() async {
    if (label.text.trim().isEmpty || address.text.trim().isEmpty) {
      setState(() => message = '이름과 주소를 모두 넣어 주세요.');
      return;
    }
    if (dis.isEmpty) {
      setState(() => message = '장애 유형을 골라 주세요. 없으면 \'해당 없음\'을 고르세요.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final (addr, at) = await _locate();
      final h = await ref.read(liveApiProvider).createHousehold({
        'label': label.text.trim(),
        'address': addr,
        'location': {'lat': at.latitude, 'lng': at.longitude},
        if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
        'members': 1,
        'needs': [for (final (k, _, need) in delegatedDisabilities) if (need != null && dis.contains(k)) need],
        'consent_method': method,
        // '동의한 사람' 칸은 뺐다 (2026-10-11 사용자 요청). 서버는 값이 꼭 있어야 해 본인·보호자로 적는다
        'consent_by': '본인 또는 보호자',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${h['label']} 가구를 등록했습니다.')));
      context.pop();
    } catch (e) {
      setState(() => message = liveError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => LivePage(title: '가구 대리 등록', children: [
        const Text('앱을 쓰지 않는 어르신 등을 방재단이 대신 등록합니다. 등록 전에 본인(또는 보호자)에게 민감정보 수집·제공 동의를 받아야 합니다.'),
        const SizedBox(height: 8),
        TextField(controller: label, decoration: const InputDecoration(labelText: '이름 또는 호칭 (필수)', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: address,
            decoration: const InputDecoration(
                labelText: '주소 (필수)', hintText: '도로명 주소 (예: 구룡포읍 호미로 152)', helperText: '방재단이 이 주소로 찾아가요', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: phone, keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: '연락처', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        const Text('장애 유형 (필수 · 중복 가능)', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (k, l, _) in delegatedDisabilities)
            FilterChip(label: Text(l), selected: dis.contains(k), onSelected: (_) => _toggleDis(k)),
        ]),
        const SizedBox(height: 12),
        SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'written', label: Text('서면 동의')), ButtonSegment(value: 'verbal', label: Text('구두 동의'))],
            selected: {method},
            onSelectionChanged: (v) => setState(() => method = v.first)),
        CheckboxListTile(
            value: confirmed,
            onChanged: (v) => setState(() => confirmed = v ?? false),
            title: const Text('수집 항목·목적·보관 기간·철회 방법을 설명하고 동의를 받았습니다'),
            subtitle: Text('동의서 버전 $consentVersion')),
        FilledButton(onPressed: busy || !confirmed ? null : _save, child: const Text('등록')),
        if (message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!)),
      ]);
}

// ------------------------------------------------------------------ 방재단 대시보드
class LiveResponderScreen extends StatelessWidget {
  const LiveResponderScreen({super.key});
  @override
  Widget build(BuildContext c) => const _PatrolGate(title: '방재단 대시보드', child: _PatrolDashboard());
}

class _PatrolDashboard extends ConsumerStatefulWidget {
  const _PatrolDashboard();
  @override
  ConsumerState<_PatrolDashboard> createState() => _PatrolDashboardState();
}

class _PatrolDashboardState extends ConsumerState<_PatrolDashboard> {
  List<Map<String, dynamic>>? incidents, households;
  Map<String, dynamic>? detail;
  String? incidentId, selected, error;
  HouseholdFilter filter = HouseholdFilter.all;
  Timer? poll;
  /// 마지막으로 받은 시각 (서버, 시연이면 앱 안 예시 데이터)
  DateTime? updatedAt;
  /// 배정 현황 업무 상태 필터 (null = 전체)
  WorkStatus? workFilter;
  /// 지도를 옮길 점 — 목록에서 가구를 고를 때만 (지도 표식을 누를 때는 옮기지 않는다)
  LatLng? focus;

  // 내 방문 경로 (2026-10-09): 명단에서 '경로에 추가'한 곳(이 기기에서만)을 모두 도는 길 — 최단 / 우선순위 최단
  Set<String> visitStops = {};
  LatLng? visitOrigin;               // null = 내 위치
  String visitOriginLabel = '내 위치';
  TravelMode visitMode = TravelMode.walk;
  Map<String, dynamic>? visitResult;
  String visitTab = 'shortest';
  bool visitLoading = false;
  String? visitError;

  /// 시연 대시보드인지 (앱 안 예시 데이터, 서버 기록과 분리)
  bool get _demo => ref.read(liveApiProvider) is DemoLiveApi;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(liveApiProvider);
    try {
      final list = await api.adminIncidents();
      final id = list.any((i) => i['id'] == incidentId) ? incidentId : (list.isEmpty ? null : '${list.first['id']}');
      // 등록 취약 가구는 대피 상황과 상관없이 늘 지도에 (장애인 가구 평시 확인)
      final hh = await api.adminHouseholds();
      if (!mounted) return;
      setState(() {
        incidents = list;
        incidentId = id;
        households = hh;
        error = null;
        updatedAt = DateTime.now();
        if (id == null) detail = null;
      });
      if (id != null) await _loadDetail();
    } catch (e) {
      if (mounted) setState(() => error = liveError(e));
    }
  }

  /// 선택한 대피 상황의 대상 명단. 서버가 알려 준 주기(next_poll_sec, 기본 10초)로 다시 받는다
  Future<void> _loadDetail() async {
    poll?.cancel();
    final id = incidentId;
    if (id == null) return;
    try {
      // 내 위치(GPS·지도에서 고른 곳, 구룡포 안)일 때만 보낸다 — 예시 위치로 거리를 재면 순서가 틀어진다
      final me = ref.read(userLocation);
      final d = await ref.read(liveApiProvider).incident(id,
          lat: me.fromGps ? me.position.latitude : null, lng: me.fromGps ? me.position.longitude : null);
      if (!mounted || id != incidentId) return;
      setState(() {
        detail = d;
        error = null;
        updatedAt = DateTime.now();
      });
      final sec = (d['next_poll_sec'] as num?)?.toInt() ?? 10;
      if (d['closed_at'] == null) poll = Timer(Duration(seconds: sec.clamp(5, 60)), _loadDetail);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = liveError(e));
      poll = Timer(const Duration(seconds: 30), _loadDetail);
    }
  }

  List<Map<String, dynamic>> get _targets {
    final ts = [for (final t in detail?['targets'] as List? ?? const []) Map<String, dynamic>.from(t as Map)];
    ts.sort((a, b) => ((a['priority_rank'] as num?) ?? 999).compareTo((b['priority_rank'] as num?) ?? 999));
    return ts;
  }

  Future<void> _visit(Map<String, dynamic> t) async {
    final ok = await showVisitSheet(context, ref, incidentId: incidentId!, target: t);
    if (ok) await _loadDetail();
  }

  /// 방재단 업무 단계 바꾸기 (주민 대피 응답은 바꾸지 않는다)
  Future<void> _setWork(Map<String, dynamic> t, WorkStatus w) =>
      _patch(t, {'work_status': workWire[w]}, '업무 상태: ${workKo[w]}');

  Future<void> _patch(Map<String, dynamic> t, Map<String, dynamic> body, String done) async {
    try {
      await ref.read(liveApiProvider).patchTarget(incidentId!, '${t['id']}', body);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t['label']}: $done')));
      await _loadDetail();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(liveError(e))));
    }
  }

  /// 목록에서 고르기 → 지도에서 그 위치를 강조하고 지도를 옮긴다
  void _pick(Map<String, dynamic> t) => setState(() {
        selected = '${t['id']}';
        focus = latLng(t['location']);
      });

  @override
  Widget build(BuildContext c) {
    // 대피 경보 팝업에서 응답을 바꾸면 바로 다시 받는다 (시연 = 기기 시연 기록, 실제 = 서버 대피 상황)
    ref.listen(prototypeSafetyProvider, (_, next) {
      if (!_demo) return;
      syncDemoPatrol(next);
      _loadDetail();
    });
    ref.listen(alertEvacuationProvider, (_, __) {
      if (!_demo) _loadDetail();
    });
    if (error != null && incidents == null) return LoadError(message: error!, onRetry: _load);
    if (incidents == null) return const DashboardLoading();
    final targets = _targets;
    final priority = priorityTargets(targets);
    final numbers = {for (var i = 0; i < priority.length; i++) '${priority[i]['id']}': i + 1};
    final incident = detail ?? incidents!.cast<Map<String, dynamic>?>().firstWhere((i) => i?['id'] == incidentId, orElse: () => null);
    final closed = detail?['closed_at'] != null;
    final demo = _demo;
    return LivePage(title: '방재단 대시보드', onRefresh: _load, children: [
      // ① 접속 상태와 방재단원 계정
      _ConnectionBar(onDelegate: () => c.push('/household/delegate')),
      const SizedBox(height: 16),
      // ② 주민 대피 현황 요약
      _summary(c, targets, incident, closed),
      const SizedBox(height: 20),
      // ③ 우선 확인 가구·대피소 지도
      _mapSection(c, targets, numbers, demo),
      const SizedBox(height: 20),
      // ④ 우선 확인 가구 (왼쪽) · ⑤ 방재단 배정 현황 (오른쪽) — 넓은 화면에서 나란히 (2026-10-10 사용자 요청), 좁으면 위아래
      if (incidentId == null)
        _prioritySection(c, priority, numbers, closed)
      else
        LayoutBuilder(builder: (c, box) {
          final left = _prioritySection(c, priority, numbers, closed), right = _assignSection(c, targets, numbers, closed);
          if (box.maxWidth < 900) return Column(children: [left, const SizedBox(height: 20), right]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: left),
            const SizedBox(width: 20),
            Expanded(child: right),
          ]);
        }),
      // 내 방문 경로는 지도 카드의 '경로 안내' 칸으로 옮겼다 (2026-10-11 사용자 요청, _visitPanel)
    ]);
  }

  // ------------------------------------------------------------------ ② 주민 대피 현황
  /// 디자인 (2026-10-10 사용자 요청): 큰 제목 · '구룡포읍 자율방재단 · 갱신 시각' · 상태 4칸 (흰 칸, 색 원 아이콘, 오른쪽 큰 숫자)
  Widget _summary(BuildContext c, List<Map<String, dynamic>> targets, Map<String, dynamic>? incident, bool closed) {
    final updated = updatedAt == null ? '갱신 전' : '갱신 ${_hms(updatedAt!)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('주민 대피 현황', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: GK.ink, height: 1.25)),
      const SizedBox(height: 4),
      Text('구룡포읍 자율방재단 · $updated', style: const TextStyle(fontSize: 17, color: GK.muted)),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _Notice(Icons.sync_problem_rounded, '연결 오류 · 마지막으로 받은 정보를 보여 줍니다 (30초 뒤 다시 시도)', error!, GK.orangeInk),
        ),
      if (incidents!.length > 1)
        DropdownButton<String>(
            isExpanded: true,
            value: incidentId,
            items: [for (final i in incidents!) DropdownMenuItem(value: '${i['id']}', child: Text('${i['title']}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) {
              setState(() {
                incidentId = v;
                detail = null;
                selected = null;
                focus = null;
                _clearVisit(pick: true);
              });
              _loadDetail();
            }),
      const SizedBox(height: 14),
      if (incidentId == null)
        const _Notice(Icons.verified_user_outlined, '진행 중인 대피 경보가 없습니다',
            '경보가 시작되면 응답 대상과 상태별 집계가 여기에 나옵니다. 평시에도 아래 지도에서 등록 취약 가구를 볼 수 있습니다.', GK.muted)
      else ...[
        if (incident != null) ...[
          Row(children: [
            Icon(Icons.campaign_rounded, color: levelColor(incident['level'] as String?)),
            const SizedBox(width: 6),
            Expanded(
                child: Text('${incident['title']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
            const SizedBox(width: 6),
            Text(closed ? '종료됨' : '${hhmm(incident['started_at'])} 시작', style: Theme.of(c).textTheme.bodySmall),
          ]),
          const SizedBox(height: 10),
        ],
        if (detail == null)
          const _Notice(Icons.hourglass_top_rounded, '불러오는 중', '응답 대상과 상태를 받고 있습니다.', GK.muted)
        else
          _StatusGrid(counts: {for (final s in residentStatuses) s: targets.where((t) => t['status'] == s).length}),
      ],
    ]);
  }

  // ------------------------------------------------------------------ ③ 지도
  Widget _mapSection(BuildContext c, List<Map<String, dynamic>> targets, Map<String, int> numbers, bool demo) {
    final sel = targets.where((t) => '${t['id']}' == selected).firstOrNull;
    final points = incidentId == null
        ? _householdPoints(const {})
        : [
            ..._householdPoints({for (final t in targets) if (t['household_id'] != null) '${t['household_id']}'}),
            for (final t in targets)
              if (latLng(t['location']) != null)
                _MapPoint('${t['id']}', latLng(t['location'])!, numbers['${t['id']}'], t['status'] as String?, '${t['label']}'),
          ];
    return GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.end, children: [
          const Text('지도', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: GK.ink)),
          Text(incidentId == null ? '등록 취약 가구 · 대피소' : '우선 확인 가구 · 대피소',
              style: const TextStyle(fontSize: 17, color: GK.muted, height: 1.6)),
          if (demo) const _Tag('예시 위치 · 실제 지도 연결 전', icon: Icons.info_outline_rounded),
        ]),
        const SizedBox(height: 8),
        _map(points, geoJsonRings(detail?['area'])),
        _FilterBar(households: households ?? const [], filter: filter, onChanged: (f) => setState(() => filter = f)),
        _MapLegend(withTargets: incidentId != null),
        if (sel != null) ...[
          const SizedBox(height: 10),
          _TargetDetail(
              t: sel,
              no: numbers['${sel['id']}'],
              closed: detail?['closed_at'] != null,
              inRoute: visitStops.contains('${sel['id']}'),
              onClose: () => setState(() => selected = null)),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------------ ④ 우선 확인 가구
  Widget _prioritySection(BuildContext c, List<Map<String, dynamic>> priority, Map<String, int> numbers, bool closed) {
    return GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('우선 확인 가구', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: GK.ink)),
        const SizedBox(height: 4),
        const Text.rich(
          TextSpan(style: TextStyle(fontSize: 16, color: GK.muted, height: 1.5), children: [
            TextSpan(text: '위험지역 안', style: TextStyle(color: GK.redDark, fontWeight: FontWeight.w800)),
            TextSpan(text: ' 가구만 · 도움 필요+장애 › 도움 필요 › 응답 없음+장애 › 응답 없음'),
          ]),
        ),
        const SizedBox(height: 14),
        if (incidentId == null)
          const _Notice(Icons.verified_user_outlined, '대피 경보가 없어 우선 확인할 곳이 없습니다', null, GK.muted)
        else if (detail == null)
          const LinearProgressIndicator()
        else if (priority.isEmpty)
          const _Notice(Icons.check_circle_outline_rounded, '지금 우선 확인할 곳이 없습니다', '위험지역 안 도움 필요·응답 없음이 0곳입니다.', GK.green)
        else
          for (final t in priority)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PriorityRow(
                  t: t,
                  no: numbers['${t['id']}']!,
                  selected: '${t['id']}' == selected,
                  closed: closed,
                  inRoute: visitStops.contains('${t['id']}'),
                  onTap: () => _pick(t),
                  onVisit: () => _visit(t),
                  onRoute: () => _toggleRoute(t)),
            ),
      ]),
    );
  }

  // ------------------------------------------------------------------ ⑤ 방재단 배정 현황
  Widget _assignSection(BuildContext c, List<Map<String, dynamic>> targets, Map<String, int> numbers, bool closed) {
    final supports = ref.read(liveApiProvider).supportsWorkStatus;
    final counts = <WorkStatus, int>{};
    for (final t in targets) {
      final w = workStatusOf(t);
      counts[w] = (counts[w] ?? 0) + 1;
    }
    final assigned = targets.where((t) => t['assigned_to'] != null).length;
    final shown = [for (final t in targets) if (workFilter == null || workStatusOf(t) == workFilter) t]
      ..sort((a, b) {
        final w = workStatusOf(a).index.compareTo(workStatusOf(b).index);
        if (w != 0) return w;
        return (numbers['${a['id']}'] ?? 999).compareTo(numbers['${b['id']}'] ?? 999);
      });
    // 단계 칩 (디자인: 연회색 알약 · 색 점 · 이름 개수). 누르면 그 단계만, 다시 누르면 전체
    Widget chip(WorkStatus w) {
      final on = workFilter == w;
      return Semantics(
        button: true,
        selected: on,
        child: Material(
          color: GK.bg,
          shape: StadiumBorder(side: BorderSide(color: on ? GK.navy : Colors.transparent, width: 2)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => setState(() => workFilter = on ? null : w),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 14, height: 14, decoration: BoxDecoration(color: workColor[w], shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text('${workKo[w]} ${counts[w] ?? 0}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: GK.ink)),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 10, runSpacing: 4, alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('방재단 배정 현황', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: GK.ink)),
          Text('배정 $assigned가구 · 미배정 ${targets.length - assigned}가구',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: GK.muted)),
        ]),
        if (!supports)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('업무 단계(가는 중·방문 중·대피 중·대피 완료)는 서버에 저장 칸이 아직 없어 배정·미배정까지만 표시합니다.',
                style: Theme.of(c).textTheme.bodySmall?.copyWith(color: GK.orangeInk, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final w in WorkStatus.values)
            if (w != WorkStatus.assigned || (counts[w] ?? 0) > 0) chip(w),
        ]),
        const SizedBox(height: 14),
        if (detail == null)
          const LinearProgressIndicator()
        else if (targets.isEmpty)
          const _Notice(Icons.inbox_outlined, '이 대피 상황의 대상이 없습니다', null, GK.muted)
        else if (shown.isEmpty)
          const _Notice(Icons.filter_alt_off_outlined, '이 상태인 곳이 없습니다', null, GK.muted)
        else
          for (final t in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _AssignCard(
                  t: t,
                  selected: '${t['id']}' == selected,
                  closed: closed,
                  supportsWork: supports,
                  onWork: (w) => _setWork(t, w),
                  onTap: () => _pick(t)),
            ),
      ]),
    );
  }

  /// 지도 = 대시보드 지도 칸 그대로(재난 층·전체 화면·등록 장소 위험) + 대피 영역(빨간 테두리) + 사람 아이콘 (2026-10-09 사용자 요청)
  /// + 대피소·의료시설, 목록에서 고른 곳으로 이동
  Widget _map(List<_MapPoint> points, List<List<LatLng>> rings) {
    final plan = _visitPlan;
    final line = plan == null ? const <LatLng>[] : decodePolyline('${plan['geometry']}');
    final at = {for (final p in points) p.id: p.at};
    return Dashboard(
      mapOnly: true,
      // 경로 안내 = 내 방문 경로, 열면 우선 확인 가구 고르기 창 (대시보드는 대피소 고르기, 2026-10-11)
      routePanel: _visitPanel(),
      onRouteOpen: incidentId == null ? () {} : _showRouteAddSheet, // 대피 경보가 없으면 창 없음
      showFacilities: true,
      focusPoint: focus,
      extraPolygons: [
        for (final r in rings)
          Polygon(points: r, color: Colors.red.withValues(alpha: .10), borderColor: Colors.red.shade700, borderStrokeWidth: 2.5),
      ],
      extraPolylines: [
        if (line.length > 1) ...[
          Polyline(points: line, color: Colors.white, strokeWidth: 10),
          Polyline(points: line, color: GK.navy, strokeWidth: 6),
        ],
      ],
      extraMarkers: [
        ..._peopleMarkers(points, selected, (id) => setState(() => selected = id)),
        if (plan != null) ...[
          // 방문 순서: 사람 아이콘 왼쪽 아래 남색 번호 (오른쪽 위 흰 번호 = 우선 확인 번호)
          for (final o in plan['order'] as List)
            if (at['${o['id']}'] != null)
              Marker(
                point: at['${o['id']}']!,
                width: 24,
                height: 24,
                alignment: const Alignment(-1.9, 1.9),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: GK.navy, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                  child: Text('${o['seq']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
              ),
          Marker(
            point: _visitStart,
            width: 40,
            height: 40,
            child: Tooltip(message: '출발: $visitOriginLabel', child: const Icon(Icons.flag_circle_rounded, color: GK.navy, size: 38)),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ 내 방문 경로
  LatLng get _visitStart => visitOrigin ?? ref.read(userLocation).position;

  Map<String, dynamic>? get _visitPlan => visitResult == null ? null : Map<String, dynamic>.from(visitResult![visitTab] as Map);

  void _clearVisit({bool pick = false}) {
    visitResult = null;
    visitError = null;
    if (pick) visitStops = {};
  }

  /// 경로에 추가한 대상 (명단 순서 = B13 순위). 대피 상황에서 빠진 대상은 저절로 빠진다
  List<Map<String, dynamic>> _routeTargets(List<Map<String, dynamic>> targets) =>
      [for (final t in targets) if (visitStops.contains('${t['id']}') && latLng(t['location']) != null) t];

  /// 카드의 '경로에 추가' / '경로에서 빼기'
  void _toggleRoute(Map<String, dynamic> t) {
    final id = '${t['id']}';
    if (!visitStops.contains(id) && visitStops.length >= maxVisitStops) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('경로에는 한 번에 $maxVisitStops곳까지 넣을 수 있습니다.')));
      return;
    }
    setState(() {
      visitStops = visitStops.contains(id) ? ({...visitStops}..remove(id)) : {...visitStops, id};
      _clearVisit();
    });
  }

  Future<void> _chooseVisitOrigin(String how) async {
    if (how == 'me') {
      setState(() {
        visitOrigin = null;
        visitOriginLabel = '내 위치';
        _clearVisit();
      });
      return;
    }
    if (how == 'map') {
      final p = await showDialog<LatLng>(context: context, builder: (_) => MapPickDialog(start: _visitStart));
      if (p == null || !mounted) return;
      setState(() {
        visitOrigin = p;
        visitOriginLabel = '지도에서 고른 위치';
        _clearVisit();
      });
      return;
    }
    final r = await showDialog<GeocodedAddress>(context: context, builder: (_) => const AddressDialog());
    if (r == null || !mounted) return;
    setState(() {
      visitOrigin = r.position;
      visitOriginLabel = r.address;
      _clearVisit();
    });
  }

  Future<void> _calcVisit(List<Map<String, dynamic>> picked) async {
    final stops = [
      for (final t in picked)
          {
            'id': '${t['id']}',
            'lat': latLng(t['location'])!.latitude,
            'lon': latLng(t['location'])!.longitude,
            'tier': (t['priority_tier'] as num?)?.toInt() ?? 4,
          },
    ];
    if (stops.isEmpty) return;
    setState(() {
      visitLoading = true;
      visitError = null;
    });
    try {
      final start = _visitStart;
      final r = await ref.read(liveApiProvider).visitRoute(start.latitude, start.longitude, stops, mode: visitMode.api);
      if (mounted) setState(() => visitResult = r);
    } catch (e) {
      if (mounted) setState(() => visitError = liveError(e));
    } finally {
      if (mounted) setState(() => visitLoading = false);
    }
  }

  /// 우선 확인 번호 (지도·목록과 같은 번호)
  Map<String, int> _numbersOf(List<Map<String, dynamic>> priority) =>
      {for (var i = 0; i < priority.length; i++) '${priority[i]['id']}': i + 1};

  /// 지도 '경로 안내'를 열면(또는 '가구 추가') 뜨는 창 (2026-10-11 사용자 요청: 대시보드처럼 대피소 고르기가 아니라
  /// 우선 확인 가구 중 경로에 넣을 곳 고르기). 고른 곳은 경로 안내 칸의 '내 방문 경로'에 나온다
  Future<void> _showRouteAddSheet() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheet) => StatefulBuilder(builder: (sheet, setSheet) {
          final priority = priorityTargets(_targets);
          final numbers = _numbersOf(priority);
          return SafeArea(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              Text('경로에 넣을 가구', style: dsText(18, weight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('우선 확인 가구 순서예요. 넣은 곳을 모두 도는 길을 계산해요 (최대 $maxVisitStops곳).',
                  style: dsText(13, color: Ds.muted)),
              const SizedBox(height: 8),
              if (incidentId == null)
                const _Notice(Icons.verified_user_outlined, '대피 경보가 없어 우선 확인할 곳이 없습니다', null, GK.muted)
              else if (detail == null)
                const LinearProgressIndicator()
              else if (priority.isEmpty)
                const _Notice(Icons.check_circle_outline_rounded, '지금 우선 확인할 곳이 없습니다', null, GK.green)
              else
                for (final t in priority)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: visitStops.contains('${t['id']}'),
                    onChanged: (_) {
                      _toggleRoute(t);
                      setSheet(() {});
                    },
                    secondary: _NoCircle(numbers['${t['id']}']!, t['status'] as String?, size: 28),
                    title: Text('${t['label']}', style: dsText(15, weight: FontWeight.w700)),
                    subtitle: Text(
                        [statusKo[t['status']] ?? '${t['status']}', if (registeredSupport(t).isNotEmpty) '장애'].join(' · '),
                        style: dsText(12, color: statusColor(t['status'] as String?))),
                  ),
              const SizedBox(height: 8),
              PillButton('완료', height: 44, fontSize: 15, onPressed: () => Navigator.pop(sheet)),
            ]),
          );
        }),
      );

  /// '출발' 고르기: 내 위치 · 지도에서 고르기 · 주소로 찾기
  Future<void> _pickVisitOrigin() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        Widget tile(FaIconData icon, String title, String how) => ListTile(
              dense: true,
              leading: FaIcon(icon, size: 16, color: Ds.navy),
              title: Text(title, style: dsText(15, weight: FontWeight.w700)),
              onTap: () => Navigator.pop(sheet, how),
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('출발 위치', style: dsText(18, weight: FontWeight.w800))),
            tile(FontAwesomeIcons.locationCrosshairs, '내 위치', 'me'),
            tile(FontAwesomeIcons.mapPin, '지도에서 고르기', 'map'),
            tile(FontAwesomeIcons.magnifyingGlass, '주소로 찾기', 'address'),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
    if (how != null && mounted) await _chooseVisitOrigin(how);
  }

  /// 지도 '경로 안내' 칸 = 내 방문 경로 (2026-10-11 사용자 요청: 아래쪽 카드를 여기로 옮기고, 출발·이동 수단·계산을
  /// 대시보드 경로 안내처럼 한 줄로)
  Widget _visitPanel() {
    final targets = _targets;
    final numbers = _numbersOf(priorityTargets(targets));
    final picked = _routeTargets(targets);
    final label = {for (final t in targets) '${t['id']}': '${t['label']}'};
    final plan = _visitPlan;
    final me = ref.watch(userLocation);
    String km(num m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)}km' : '${m.round()}m';
    String min(num s) => '${(s / 60).ceil()}분';
    const h = 32.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      Row(children: [
        const FaIcon(FontAwesomeIcons.route, size: 15, color: Ds.navy),
        const SizedBox(width: 8),
        Expanded(child: Text('내 방문 경로', style: dsText(16, weight: FontWeight.w800))),
        if (incidentId != null)
          TextButton.icon(
              onPressed: _showRouteAddSheet,
              icon: const FaIcon(FontAwesomeIcons.plus, size: 12),
              label: const Text('가구 추가')),
      ]),
      Text("우선 확인 가구에서 '경로에 추가'한 곳을 모두 도는 길이에요. 위험 구역은 피하고, 방문할 집이 있는 구역만 들어가요.",
          style: dsText(13, color: Ds.muted, height: 1.4)),
      const SizedBox(height: 8),
      if (incidentId == null)
        Text('대피 경보가 없어 방문할 곳이 없어요.', style: dsText(13, color: Ds.muted))
      else if (picked.isEmpty)
        Text("아직 넣은 곳이 없어요. '가구 추가'로 우선 확인 가구를 넣어 주세요.", style: dsText(13, color: Ds.muted))
      else ...[
        Text('경로에 넣은 곳 ${picked.length}/$maxVisitStops', style: dsText(13, weight: FontWeight.w800)),
        const SizedBox(height: 4),
        for (final t in picked)
          InkWell(
            onTap: () => _pick(t),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                if (numbers['${t['id']}'] != null)
                  _NoCircle(numbers['${t['id']}']!, t['status'] as String?, size: 28)
                else
                  const SizedBox(width: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${t['label']}', style: dsText(14, weight: FontWeight.w700)),
                        TextSpan(
                            text: '  ${statusKo[t['status']] ?? '${t['status']}'}',
                            style: dsText(12, color: statusColor(t['status'] as String?))),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                    tooltip: '경로에서 빼기',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => _toggleRoute(t)),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 8),
      // 출발 · 이동 수단 · 계산 — 대시보드 경로 안내 줄과 같은 모양
      Row(children: [
        Expanded(
          child: RouteEndButton(
            title: '출발',
            icon: visitOrigin == null ? FontAwesomeIcons.locationCrosshairs : FontAwesomeIcons.locationDot,
            label: visitOrigin == null ? (me.fromGps ? '내 위치' : '내 위치 (예시 위치)') : visitOriginLabel,
            onTap: _pickVisitOrigin,
          ),
        ),
        const SizedBox(width: 6),
        Semantics(
          label: '이동 수단',
          child: SegmentedPill<TravelMode>(
            expand: false,
            height: h,
            items: const [
              (TravelMode.walk, null, FontAwesomeIcons.personWalking),
              (TravelMode.car, null, FontAwesomeIcons.car),
            ],
            value: visitMode,
            onChanged: (m) => setState(() {
              visitMode = m;
              _clearVisit();
            }),
          ),
        ),
        const SizedBox(width: 6),
        if (visitLoading)
          const SizedBox(
              width: h, height: h, child: Padding(padding: EdgeInsets.all(7), child: CircularProgressIndicator(strokeWidth: 2)))
        else
          PillButton(picked.isEmpty ? '경로 계산' : '${picked.length}곳 경로 계산',
              expand: false,
              height: h,
              fontSize: 13,
              icon: FontAwesomeIcons.diamondTurnRight,
              onPressed: picked.isEmpty ? null : () => _calcVisit(picked)),
      ]),
      if (visitError != null)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(visitError!, style: dsText(13, color: Ds.danger))),
      if (plan != null) ...[
        const SizedBox(height: 10),
        SegmentedPill<String>(
          height: h,
          items: const [('shortest', '최단 경로', null), ('priority', '우선순위 최단 경로', null)],
          value: visitTab,
          onChanged: (v) => setState(() => visitTab = v),
        ),
        const SizedBox(height: 6),
        Text('${visitMode.label} · 총 ${km(plan['distance_m'] as num)} · 약 ${min(plan['duration_s'] as num)}',
            style: dsText(15, weight: FontWeight.w800)),
        Text(visitTab == 'priority' ? '순위 단계(도움 요청+장애 → 도움 요청 → 응답 없음+장애 → …)를 지키고, 같은 단계 안에서 가장 짧게' : '순위와 상관없이 가장 짧게',
            style: dsText(12, color: Ds.muted)),
        for (final o in plan['order'] as List)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
                radius: 12,
                backgroundColor: Ds.navy,
                child: Text('${o['seq']}', style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold))),
            title: Text(label['${o['id']}'] ?? '${o['id']}'),
            subtitle: Text('앞 지점에서 ${km(o['leg_distance_m'] as num)} · ${min(o['leg_duration_s'] as num)}'),
            onTap: () => setState(() => selected = '${o['id']}'),
          ),
        if ((plan['still_inside'] as List? ?? const []).isNotEmpty)
          Text('⚠ 위험 구역 ${(plan['still_inside'] as List).length}곳을 지납니다 (방문할 집이 구역 안에 있거나 다른 길이 없음).',
              style: TextStyle(color: Colors.deepOrange.shade800)),
        if ((visitResult!['blocked_zones'] as List? ?? const []).isNotEmpty)
          Text('⚠ 막아야 할 위험 구역을 지나지 않고는 갈 수 없는 곳이 있어, 그 구역을 지나는 길로 계산했습니다.',
              style: TextStyle(color: Colors.red.shade800)),
      ],
    ]);
  }

  /// 필터에 맞는 등록 가구 (선택한 가구를 맨 앞으로)
  List<Map<String, dynamic>> get _shownHouseholds {
    final hs = [for (final h in households ?? const <Map<String, dynamic>>[]) if (matchesFilter(filter, h['needs'])) h];
    return [...hs.where((h) => '${h['id']}' == selected), ...hs.where((h) => '${h['id']}' != selected)];
  }

  /// 등록 가구 지도 점 (대피 대상인 가구는 번호 점으로 따로 그리므로 뺀다)
  List<_MapPoint> _householdPoints(Set<String> targetHouseholds) => [
        for (final h in _shownHouseholds)
          if (latLng(h['location']) != null && !targetHouseholds.contains('${h['id']}'))
            _MapPoint('${h['id']}', latLng(h['location'])!, null, null, '${h['label']}', kind: vulnerableKind(h['needs']),
                detail: needsText(h['needs'])),
      ];
}

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

// ------------------------------------------------------------------ 우선순위·업무 상태 (화면 계산)
/// 주민 대피 응답 상태 (집계 순서)
const residentStatuses = ['need_help', 'no_response', 'evacuating', 'evacuated'];

/// 지체 = mobility_limited (2026-10-11: 가구 대리 등록의 장애 유형 이름과 같게)
/// 등록된 지원 필요 정보 중 장애 — 등록 가구의 needs(본인·보호자 동의로 등록)만 본다.
/// 앱 사용자의 시각·청각 화면 설정으로는 장애를 추정하지 않는다 (2026-10-09 사용자 요청)
const supportNeedKo = {'vision': '시각', 'hearing': '청각', 'wheelchair': '휠체어', 'bedridden': '와상', 'mobility_limited': '지체'};
List<String> registeredSupport(Map<String, dynamic> t) {
  if (t['kind'] == 'app_user') return const [];
  return [for (final n in t['needs'] as List? ?? const []) if (supportNeedKo['$n'] != null) supportNeedKo['$n']!];
}

int _priorityTier(Map<String, dynamic> t) {
  final dis = registeredSupport(t).isNotEmpty;
  return t['status'] == 'need_help' ? (dis ? 0 : 1) : (dis ? 2 : 3);
}

/// 우선 확인 가구: 위험지역 안의 도움 필요·응답 없음만. 도움 필요 → 응답 없음, 같은 상태 안에서는 등록된 장애 정보가 있으면 먼저,
/// 그다음 서버 순위(가까운 순 또는 오래 기다린 순). 화면 번호 = 이 순서 (지도 번호와 같다)
List<Map<String, dynamic>> priorityTargets(List<Map<String, dynamic>> targets) {
  final out = [
    for (final t in targets)
      if (t['in_area'] != false && (t['status'] == 'need_help' || t['status'] == 'no_response')) t
  ];
  out.sort((a, b) {
    final c = _priorityTier(a).compareTo(_priorityTier(b));
    if (c != 0) return c;
    final r = ((a['priority_rank'] as num?) ?? 999).compareTo((b['priority_rank'] as num?) ?? 999);
    if (r != 0) return r;
    return ((b['minutes_since_alert'] as num?) ?? 0).compareTo((a['minutes_since_alert'] as num?) ?? 0);
  });
  return out;
}

/// 방재단 업무 상태 (주민 대피 응답과 따로). assigned = 배정은 됐지만 업무 단계를 모름 (서버에 단계 칸이 없을 때)
enum WorkStatus { unassigned, enRoute, visiting, escorting, done, assigned }

const workKo = {
  WorkStatus.unassigned: '미배정',
  WorkStatus.enRoute: '가는 중',
  WorkStatus.visiting: '방문 중',
  WorkStatus.escorting: '대피 중',
  WorkStatus.done: '대피 완료',
  WorkStatus.assigned: '배정됨 · 단계 미연결',
};
const workWire = {
  WorkStatus.enRoute: 'en_route',
  WorkStatus.visiting: 'visiting',
  WorkStatus.escorting: 'escorting',
  WorkStatus.done: 'done',
};
const workIcon = {
  WorkStatus.unassigned: Icons.person_off_outlined,
  WorkStatus.enRoute: Icons.directions_run_rounded,
  WorkStatus.visiting: Icons.door_front_door_outlined,
  WorkStatus.escorting: Icons.transfer_within_a_station_rounded,
  WorkStatus.done: Icons.task_alt_rounded,
  WorkStatus.assigned: Icons.assignment_ind_outlined,
};
const workColor = {
  WorkStatus.unassigned: Color(0xffc9372c),
  WorkStatus.enRoute: Color(0xffc8691c),
  WorkStatus.visiting: GK.navy,
  WorkStatus.escorting: Color(0xff5b6690),
  WorkStatus.done: Color(0xff178a4c),
  WorkStatus.assigned: GK.muted,
};

WorkStatus workStatusOf(Map<String, dynamic> t) {
  if (t['assigned_to'] == null) return WorkStatus.unassigned;
  return switch (t['work_status']) {
    'en_route' => WorkStatus.enRoute,
    'visiting' => WorkStatus.visiting,
    'escorting' => WorkStatus.escorting,
    'done' => WorkStatus.done,
    _ => WorkStatus.assigned,
  };
}

/// 진행 단계 '출발 → 방문 → 대피 동행 → 완료' 중 지금 칸 (모르면 -1)
int workStep(WorkStatus w) => switch (w) {
      WorkStatus.enRoute => 0,
      WorkStatus.visiting => 1,
      WorkStatus.escorting => 2,
      WorkStatus.done => 3,
      _ => -1,
    };
const workSteps = ['출발', '방문', '대피 동행', '완료'];

String assigneeText(Map<String, dynamic> t) {
  final a = t['assigned_to'] as Map?;
  if (a == null) return '미배정';
  return a['is_me'] == true ? '내가 담당' : '${a['nickname'] ?? '방재단'} 담당';
}

/// 우선순위 근거: 서버 priority_reasons(B13 — 상태·장애·거리 또는 기다린 시간)를 그대로 잇는다. 없으면(예전 서버) 상태만
String priorityReason(Map<String, dynamic> t) {
  final reasons = [for (final r in t['priority_reasons'] as List? ?? const []) if (r is Map) '${r['label'] ?? r['factor']}'];
  if (reasons.isNotEmpty) return reasons.join(' · ');
  return '${statusKo[t['status']] ?? t['status']}';
}

// ------------------------------------------------------------------ 화면 조각
/// 작은 표시 칩 (시연·예시 위치 등)
class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.icon});
  final String text;
  final IconData? icon;
  static const bg = GK.tint, fg = GK.navy;
  @override
  Widget build(BuildContext c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 4)],
          Flexible(child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: fg))),
        ]),
      );
}

/// 빈 상태·불러오는 중·연결 오류 안내 한 줄
class _Notice extends StatelessWidget {
  const _Notice(this.icon, this.title, this.detail, this.color);
  final IconData icon;
  final String title;
  final String? detail;
  final Color color;
  @override
  Widget build(BuildContext c) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: GK.bg, borderRadius: BorderRadius.circular(GK.radiusInner)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: color == GK.muted ? GK.ink : color)),
              if (detail != null) Text(detail!, style: Theme.of(c).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}

/// ① 머리 줄: 가구 대리 등록만 (2026-10-10 사용자 요청 — 온라인·계정·시연 표시 칩은 뺐다)
class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({required this.onDelegate});
  final VoidCallback onDelegate;
  @override
  Widget build(BuildContext c) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
            onPressed: onDelegate,
            icon: const FaIcon(FontAwesomeIcons.userPlus, size: 18),
            label: const Text('가구 대리 등록')),
      );
}

/// ② 상태별 집계 칸 (디자인: 흰 칸 · 색 원 아이콘 · 이름 · 오른쪽 큰 숫자). 넓으면 4열, 아니면 2열
class _StatusGrid extends StatelessWidget {
  const _StatusGrid({required this.counts});
  final Map<String, int> counts;
  // Font Awesome (휴대폰 화면과 같은 짝) — 웹에서 Material 아이콘 일부가 빈 원으로 보였다 (2026-10-10)
  static const _icon = {
    'need_help': FontAwesomeIcons.lifeRing,
    'no_response': FontAwesomeIcons.headset,
    'evacuating': FontAwesomeIcons.personWalking,
    'evacuated': FontAwesomeIcons.check,
  };
  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
        final cols = box.maxWidth < 900 ? 2 : 4;
        const gap = 12.0;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        final narrow = w < 240;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final s in residentStatuses)
            SizedBox(
              width: w,
              child: Semantics(
                label: '${statusKo[s]} ${counts[s] ?? 0}곳',
                excludeSemantics: true,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 84),
                  padding: EdgeInsets.fromLTRB(narrow ? 12 : 16, 12, narrow ? 14 : 20, 12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(GK.radiusInner)),
                  child: Row(children: [
                    Container(
                      width: narrow ? 44 : 56,
                      height: narrow ? 44 : 56,
                      decoration: BoxDecoration(color: statusColor(s), shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: FaIcon(_icon[s]!, color: Colors.white, size: narrow ? 20 : 24),
                    ),
                    SizedBox(width: narrow ? 10 : 14),
                    Expanded(
                        child: Text(statusKo[s]!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: narrow ? 16 : 19, fontWeight: FontWeight.w800, color: GK.ink))),
                    Text.rich(
                        key: ValueKey('evac-count-$s'),
                        TextSpan(
                            text: '${counts[s] ?? 0}',
                            style: TextStyle(fontSize: narrow ? 32 : 40, fontWeight: FontWeight.w800, color: statusColor(s), height: 1))),
                  ]),
                ),
              ),
            ),
        ]);
      });
}

/// 번호 원 (지도 번호와 같은 번호, 색 = 응답 상태)
class _NoCircle extends StatelessWidget {
  const _NoCircle(this.no, this.status, {this.size = 34});
  final int? no;
  final String? status;
  final double size;
  @override
  Widget build(BuildContext c) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: statusColor(status), shape: BoxShape.circle),
        child: no == null
            ? Icon(Icons.person_rounded, color: Colors.white, size: size * .6)
            : Text('$no', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * .45)),
      );
}

/// ④ 우선 확인 가구 한 줄 (2026-10-10 간결하게): 상태색 옅은 바탕 · 번호 원 · 이름 / 상태 · 담당 / 위치 ·
/// 오른쪽 아이콘 '방문 결과'·'경로에 추가(빼기)'. 줄을 누르면 지도에서 위치를 보여 준다
class _PriorityRow extends StatelessWidget {
  const _PriorityRow(
      {required this.t,
      required this.no,
      required this.selected,
      required this.closed,
      required this.inRoute,
      required this.onTap,
      required this.onVisit,
      required this.onRoute});
  final Map<String, dynamic> t;
  final int no;
  final bool selected, closed, inRoute;
  final VoidCallback onTap, onVisit, onRoute;
  @override
  Widget build(BuildContext c) {
    final status = t['status'] as String?;
    final dis = registeredSupport(t);
    final a = t['assigned_to'] as Map?;
    final assignee = a == null ? '미배정' : (a['is_me'] == true ? '내가 맡음' : '${a['nickname'] ?? '방재단'} 배정');
    return Material(
      color: Color.alphaBlend(statusColor(status).withValues(alpha: status == 'need_help' ? .10 : .07), GK.bg),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GK.radiusInner),
          side: selected ? const BorderSide(color: GK.navy, width: 2) : BorderSide.none),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(children: [
            _NoCircle(no, status, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${t['label']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: GK.ink)),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: [statusKo[status] ?? '$status', if (dis.isNotEmpty) '장애'].join(' · '),
                        style: TextStyle(fontWeight: FontWeight.w800, color: statusColor(status))),
                    const TextSpan(text: ' · ', style: TextStyle(color: GK.muted)),
                    TextSpan(text: assignee, style: TextStyle(fontWeight: FontWeight.w700, color: a == null ? GK.redDark : GK.muted)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                Text(t['address'] == null ? '위치 정보: 지도 표식 참고' : '${t['address']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: GK.muted)),
              ]),
            ),
            if (!closed) ...[
              IconButton(
                  tooltip: '방문 결과',
                  onPressed: onVisit,
                  icon: const Icon(Icons.assignment_turned_in_outlined, color: GK.navy)),
              IconButton(
                  tooltip: inRoute ? '경로에서 빼기' : '경로에 추가',
                  onPressed: onRoute,
                  isSelected: inRoute,
                  icon: const Icon(Icons.add_road_rounded, color: GK.navy),
                  selectedIcon: const Icon(Icons.remove_road_rounded, color: Colors.white),
                  style: IconButton.styleFrom(backgroundColor: inRoute ? GK.navy : null)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// 지도에서 고른(또는 목록에서 고른) 대상 정보. 방문 결과·경로에 추가는 우선 확인 가구 줄의 아이콘으로 (2026-10-10)
class _TargetDetail extends StatelessWidget {
  const _TargetDetail({required this.t, required this.no, required this.closed, required this.inRoute, required this.onClose});
  final Map<String, dynamic> t;
  final int? no;
  final bool closed, inRoute;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext c) {
    final status = t['status'] as String?;
    final visit = t['last_visit'] as Map?;
    final mins = t['minutes_since_alert'];
    final dis = registeredSupport(t);
    return GkCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _NoCircle(no, status, size: 30),
          const SizedBox(width: 10),
          Expanded(
              child: Text('${no != null ? '$no번 · ' : ''}${t['label']}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          IconButton(tooltip: '닫기', onPressed: onClose, icon: const Icon(Icons.close_rounded)),
        ]),
        Text('주민 응답: ${statusKo[status] ?? status} · ${assigneeText(t)} · 업무: ${workKo[workStatusOf(t)]}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        Text([
          if (t['address'] != null) '${t['address']}',
          if (dis.isNotEmpty) '등록된 지원 필요: ${dis.join(', ')}',
          if (mins is num) '경고 후 $mins분',
          if (t['escalated'] == true) '재알림 ${t['reminder_count'] ?? ''}회 무응답',
        ].join(' · ')),
        if (visit != null)
          Text('마지막 방문 ${hhmm(visit['visited_at'])} · ${visitKo[visit['result']] ?? visit['result']}'
              '${(visit['responder'] as Map?)?['nickname'] != null ? ' (${(visit['responder'] as Map)['nickname']})' : ''}',
              style: Theme.of(c).textTheme.bodySmall),
        if (inRoute)
          Text('내 방문 경로에 넣음', style: Theme.of(c).textTheme.bodySmall?.copyWith(color: GK.navy, fontWeight: FontWeight.w700)),
        if (t['phone'] != null)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(tooltip: '전화', icon: const Icon(Icons.phone), onPressed: () => launchUrl(Uri.parse('tel:${t['phone']}'))),
          ),
      ]),
    );
  }
}

/// ⑤ 배정 현황 카드 (디자인): 이름 + 위치 · 오른쪽 담당(배지 아이콘 + 이름)과 업무 상태 알약 · 4칸 진행 막대(출발 → 방문 → 대피 동행 → 완료).
/// 카드를 누르면 지도에서 위치를 보여 주고, 고른 카드에만 '업무 단계 바꾸기'가 나온다 ('내가 맡기'는 뺐다 — 2026-10-10 사용자 요청)
class _AssignCard extends StatelessWidget {
  const _AssignCard(
      {required this.t,
      required this.selected,
      required this.closed,
      required this.supportsWork,
      required this.onWork,
      required this.onTap});
  final Map<String, dynamic> t;
  final bool selected, closed, supportsWork;
  final VoidCallback onTap;
  final ValueChanged<WorkStatus> onWork;
  @override
  Widget build(BuildContext c) {
    final w = workStatusOf(t);
    final a = t['assigned_to'] as Map?;
    final mine = a?['is_me'] == true;
    final status = t['status'] as String?;
    final who = a == null ? null : (mine ? '나' : '${a['nickname'] ?? '방재단'}');
    return Material(
      color: GK.bg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GK.radiusInner),
          side: selected ? const BorderSide(color: GK.navy, width: 2) : BorderSide.none),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text('${t['label']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: GK.ink)),
              ),
              if (who != null) ...[
                const SizedBox(width: 8),
                Semantics(
                  label: '담당 $who',
                  excludeSemantics: true,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.badge_rounded, size: 18, color: GK.navy),
                    const SizedBox(width: 4),
                    Text(who, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: GK.navy)),
                  ]),
                ),
              ],
              const SizedBox(width: 8),
              _WorkPill(w),
            ]),
            const SizedBox(height: 8),
            _WorkProgress(w),
            if (selected) ...[
              const SizedBox(height: 6),
              Text('주민 응답 ${statusKo[status] ?? status}', style: const TextStyle(fontSize: 14, color: GK.muted)),
              if (!closed)
                Wrap(spacing: 6, runSpacing: 0, children: [
                  if (supportsWork && a != null)
                    PopupMenuButton<WorkStatus>(
                      tooltip: '업무 단계 바꾸기',
                      onSelected: onWork,
                      itemBuilder: (_) => [
                        for (final s in const [WorkStatus.enRoute, WorkStatus.visiting, WorkStatus.escorting, WorkStatus.done])
                          PopupMenuItem(
                              value: s,
                              child: Row(children: [
                                Icon(workIcon[s], color: workColor[s]),
                                const SizedBox(width: 8),
                                Text(workKo[s]!),
                                if (s == w) const Text('  (지금)'),
                              ])),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.swap_horiz_rounded, color: GK.navy, size: 20),
                          SizedBox(width: 4),
                          Text('업무 단계 바꾸기', style: TextStyle(color: GK.navy, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                ]),
            ],
          ]),
        ),
      ),
    );
  }
}

/// 업무 상태 알약 (디자인: 상태색 바탕 · 흰 글자)
class _WorkPill extends StatelessWidget {
  const _WorkPill(this.w);
  final WorkStatus w;
  @override
  Widget build(BuildContext c) => Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: workColor[w], borderRadius: BorderRadius.circular(999)),
        child: Text(w == WorkStatus.assigned ? '배정됨' : workKo[w]!,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
      );
}

/// 진행 단계 막대 (디자인): 지난 칸·지금 칸은 업무 상태 색, 그 칸 글자는 진하게. 모르면 회색과 안내
class _WorkProgress extends StatelessWidget {
  const _WorkProgress(this.w);
  final WorkStatus w;
  @override
  Widget build(BuildContext c) {
    final step = workStep(w);
    final note = w == WorkStatus.assigned ? '단계 정보 없음 (서버 연결 필요)' : null;
    return Semantics(
      label: step < 0 ? '진행 단계: ${note ?? '시작 전'}' : '진행 단계: ${workSteps[step]} (${step + 1}/4)',
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          for (var i = 0; i < workSteps.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: Column(children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(color: i <= step ? workColor[w] : GK.line, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(height: 4),
                Text(workSteps[i],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: i <= step ? FontWeight.w800 : FontWeight.w500,
                        color: i <= step ? GK.ink : GK.grey)),
              ]),
            ),
          ],
        ]),
        if (note != null) Text(note, style: const TextStyle(fontSize: 12, color: GK.muted)),
      ]),
    );
  }
}

/// 전체 / 장애인 필터 (개수 포함)
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.households, required this.filter, required this.onChanged});
  final List<Map<String, dynamic>> households;
  final HouseholdFilter filter;
  final ValueChanged<HouseholdFilter> onChanged;
  @override
  Widget build(BuildContext c) {
    int count(HouseholdFilter f) => households.where((h) => matchesFilter(f, h['needs'])).length;
    Widget chip(HouseholdFilter f, String label, IconData icon, Color color) => ChoiceChip(
        avatar: Icon(icon, size: 18, color: color),
        label: Text('$label ${count(f)}'),
        selected: filter == f,
        onSelected: (_) => onChanged(f));
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Wrap(spacing: 8, runSpacing: 6, children: [
          chip(HouseholdFilter.all, '등록 취약 가구 전체', Icons.home_work_outlined, kindColor[VulnerableKind.other]!),
          chip(HouseholdFilter.disabled, '장애인', kindIcon[VulnerableKind.disabled]!, kindColor[VulnerableKind.disabled]!),
        ]));
  }
}

class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.withTargets});
  final bool withTargets;
  @override
  Widget build(BuildContext c) {
    Widget item(Widget mark, String label) => Row(mainAxisSize: MainAxisSize.min, children: [mark, const SizedBox(width: 4), Text(label)]);
    Widget icon(VulnerableKind k) => CircleAvatar(radius: 10, backgroundColor: kindColor[k], child: Icon(personIcon(k), size: 14, color: Colors.white));
    return Wrap(spacing: 14, runSpacing: 4, children: [
      if (withTargets) ...[
        item(const _NoCircle(1, 'need_help', size: 20), '우선 확인 번호 (목록과 같음, 색 = 응답 상태)'),
        item(Container(width: 18, height: 12, decoration: BoxDecoration(border: Border.all(color: Colors.red.shade700, width: 2))),
            '빨간 테두리 = 대피 경보 지역'),
      ],
      item(Icon(Icons.health_and_safety, color: Colors.teal.shade800, size: 20), '대피소'),
      item(icon(VulnerableKind.disabled), '장애인 가구'),
      item(icon(VulnerableKind.other), '기타 취약 가구'),
    ]);
  }
}

class _MapPoint {
  const _MapPoint(this.id, this.at, this.rank, this.status, this.label, {this.kind, this.detail});
  final String id;
  final LatLng at;
  final int? rank;              // 우선 확인 대상이면 화면 번호 (목록 번호와 같다)
  final String? status;         // 대피 대상이면 대피 상태
  final String label;
  final VulnerableKind? kind;   // 등록 가구(대피 대상 아님)면 장애인·기타
  final String? detail;
}

/// 방문 경로 한 번에 고를 수 있는 곳 (route 서버 visits.MAX_STOPS와 같게)
const maxVisitStops = 10;

/// 대시보드 지도 위 사람 아이콘 (2026-10-09): 대피 대상은 사람 + 우선 확인 번호(색 = 대피 상태),
/// 등록 취약 가구는 장애인·기타 사람 아이콘. 누르면 그 대상 정보가 지도 아래에
List<Marker> _peopleMarkers(List<_MapPoint> points, String? selected, ValueChanged<String> onTap) => [
      for (final p in [...points.where((p) => p.id != selected), ...points.where((p) => p.id == selected)])
        Marker(
          point: p.at,
          width: p.id == selected ? 54 : 42,
          height: p.id == selected ? 54 : 42,
          child: GestureDetector(
            onTap: () => onTap(p.id),
            child: Tooltip(
              message: p.kind != null
                  ? '${p.label} · ${kindKo[p.kind]}${p.detail?.isNotEmpty ?? false ? ' (${p.detail})' : ''}'
                  : '${p.rank != null ? '${p.rank}번 ' : ''}${p.label} · ${statusKo[p.status] ?? '대피 대상'}',
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                        color: p.kind != null ? kindColor[p.kind] : statusColor(p.status),
                        shape: BoxShape.circle,
                        border: Border.all(color: p.id == selected ? GK.navy : Colors.white, width: p.id == selected ? 4 : 2),
                        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)]),
                    child: Icon(personIcon(p.kind), color: Colors.white, size: p.id == selected ? 30 : 26),
                  ),
                ),
                if (p.rank != null)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 22),
                      height: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: Colors.white, borderRadius: BorderRadius.circular(11), border: Border.all(color: statusColor(p.status), width: 2)),
                      child: Text('${p.rank}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: statusColor(p.status))),
                    ),
                  ),
              ]),
            ),
          ),
        ),
    ];

/// 지도 사람 아이콘 모양: 대피 대상(kind 없음)은 사람, 등록 가구는 장애인·사람
IconData personIcon(VulnerableKind? kind) => switch (kind) {
      VulnerableKind.disabled => Icons.accessible_rounded,
      _ => Icons.person_rounded,
    };

/// 방문 결과 입력: 결과 고르기 → 메모 → POST .../visits. 기록하면 true
Future<bool> showVisitSheet(BuildContext context, WidgetRef ref,
    {required String incidentId, required Map<String, dynamic> target}) async {
  final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text('방문 결과 · ${target['label']}'), subtitle: const Text('앞의 세 가지는 대상 상태를 "대피 완료"로 바꿉니다.')),
            for (final r in visitResults)
              ListTile(leading: const Icon(Icons.assignment_turned_in_outlined), title: Text(r.$2), onTap: () => Navigator.pop(s, r)),
          ])));
  if (picked == null || !context.mounted) return false;
  final memo = await showDialog<String>(context: context, builder: (_) => _MemoDialog(title: picked.$2));
  if (memo == null) return false;
  try {
    await ref.read(liveApiProvider).recordVisit(incidentId, '${target['id']}', {
      'result': picked.$1,
      if (memo.trim().isNotEmpty) 'note': memo.trim(),
    });
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${target['label']}: ${picked.$2} 기록했습니다.')));
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(liveError(e))));
    return false;
  }
}

/// 방문 메모 입력. 입력 상자 컨트롤러는 대화상자가 닫히는 애니메이션이 끝난 뒤 정리되도록 대화상자가 갖는다
class _MemoDialog extends StatefulWidget {
  const _MemoDialog({required this.title});
  final String title;
  @override
  State<_MemoDialog> createState() => _MemoDialogState();
}

class _MemoDialogState extends State<_MemoDialog> {
  final note = TextEditingController();
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(widget.title),
          content: TextField(controller: note, maxLength: 300, maxLines: 2, decoration: const InputDecoration(labelText: '메모 (선택)')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(c, note.text), child: const Text('기록')),
          ]);
}

// ------------------------------------------------------------------ 해상 → 최근접 항 → 육상 경로 (B11)
/// route 서버 /api/route/sea 응답 → 지도에 그릴 두 구간
class SeaRoutePlan {
  SeaRoutePlan(this.raw, this.origin);
  final Map<String, dynamic> raw;
  final LatLng origin;

  bool get atSea => raw['at_sea'] == true;
  Map<String, dynamic>? get port => raw['port'] == null ? null : Map<String, dynamic>.from(raw['port'] as Map);
  Map<String, dynamic>? get seaLeg => raw['sea_leg'] == null ? null : Map<String, dynamic>.from(raw['sea_leg'] as Map);
  Map<String, dynamic>? get destination => raw['destination'] == null ? null : Map<String, dynamic>.from(raw['destination'] as Map);
  Map<String, dynamic>? get landRoute => raw['land_route'] == null ? null : Map<String, dynamic>.from(raw['land_route'] as Map);
  LatLng? get berth => latLng(port?['berth']);
  LatLng? get landPoint => latLng(port?['land_point']);

  /// 해상 구간: 출발 → 접안점. 서버가 준 바닷길(육지·방파제를 돌아가는 꺾은선)이 있으면 그것, 없으면 직선
  List<LatLng> get seaPoints {
    if (berth == null) return const [];
    // 바닷길을 못 찾았으면 선을 그리지 않는다 — 직선은 육지를 뚫을 수 있다 (방위·거리 글만)
    if (seaLeg?['path_found'] == false) return const [];
    final p = seaLeg?['path'];
    final path = p is String && p.isNotEmpty ? decodePolyline(p) : <LatLng>[];
    return path.length >= 2 ? path : [origin, berth!];
  }

  /// 육상 구간: 접안점 → 도로 시작점 + 경로 (해상일 때), 육지면 경로만
  List<LatLng> get landPoints {
    final g = landRoute?['geometry'];
    final road = g is String && g.isNotEmpty ? decodePolyline(g) : <LatLng>[];
    return [if (berth != null) berth!, if (landPoint != null) landPoint!, ...road];
  }
}

/// 점선 (짧은 선분들) — 해상 구간은 도로가 아니라 대략의 바닷길이라 점선으로 그린다
List<Polyline> dashedLine(List<LatLng> pts, Color color, {double width = 5, int dashes = 24}) => [
      for (var i = 0; i < pts.length - 1; i++)
        for (var j = 0; j < dashes; j += 2)
          Polyline(points: [
            LatLng(pts[i].latitude + (pts[i + 1].latitude - pts[i].latitude) * j / dashes,
                pts[i].longitude + (pts[i + 1].longitude - pts[i].longitude) * j / dashes),
            LatLng(pts[i].latitude + (pts[i + 1].latitude - pts[i].latitude) * (j + 1) / dashes,
                pts[i].longitude + (pts[i + 1].longitude - pts[i].longitude) * (j + 1) / dashes),
          ], color: color, strokeWidth: width),
    ];

const seaColor = Color(0xff1565c0), landColor = Color(0xff2e7d32), portColor = Colors.deepOrange;

/// 대시보드 '경로 안내' (2026-10-10 사용자 요청): 지금 위치(GPS 또는 직접 지정한 출발지)가 바다 위면 화면을 따로 열지 않고
/// 그 위치에서 바로 해상 경로(바다 → 가까운 항구 → 대피소)를 받아 대시보드 지도에 그린다. 바다가 아니면 null
final seaRoutePlanProvider = FutureProvider<SeaRoutePlan?>((ref) async {
  final where = await ref.watch(whereNowProvider.future);
  if (where.kind != WhereKind.sea) return null;
  final p = ref.watch(userLocation).position;
  final r = await ref.watch(liveApiProvider).seaRoute(p.latitude, p.longitude);
  return SeaRoutePlan(r, p);
});

/// 대시보드 지도에 겹쳐 그릴 해상 경로: 바닷길(파란 점선) + 항구에서 대피소까지 육상 경로(초록)
List<Polyline> seaRoutePolylines(SeaRoutePlan p) => [
      if (p.landPoints.length >= 2) Polyline(points: p.landPoints, color: Colors.white, strokeWidth: 9),
      if (p.landPoints.length >= 2) Polyline(points: p.landPoints, color: landColor, strokeWidth: 5),
      ...dashedLine(p.seaPoints, seaColor),
    ];

/// 배 위치(출발)·항구 접안점·도착 대피소 표시
List<Marker> seaRouteMarkers(SeaRoutePlan p) => [
      Marker(point: p.origin, width: 36, height: 36, child: const Icon(Icons.sailing, color: seaColor, size: 32)),
      if (p.berth != null)
        Marker(point: p.berth!, width: 34, height: 34, child: const Icon(Icons.anchor, color: portColor, size: 30)),
      if (latLng(p.destination) != null)
        Marker(point: latLng(p.destination)!, width: 34, height: 34, alignment: Alignment.topCenter,
            child: const Icon(Icons.health_and_safety, color: landColor, size: 32)),
    ];

/// 대시보드 경로 안내의 바다 위 안내 칸: 찾는 중 / 못 찾음(다시 찾기) / 1. 항구까지 바닷길 2. 항구에서 대피소까지
class SeaRoutePanel extends ConsumerWidget {
  const SeaRoutePanel({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final plan = ref.watch(seaRoutePlanProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('지금 위치가 바다 위로 확인됐어요. 가까운 항구까지 바닷길과 항구에서 대피소까지 길을 지도에 그려요.',
          style: TextStyle(fontSize: 15, color: GK.muted, height: 1.45)),
      const SizedBox(height: 8),
      ...plan.when(
        loading: () => const [
          Row(children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('해상 경로를 찾고 있어요'),
          ]),
        ],
        error: (e, _) => [
          Card(
              child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: const Text('해상 경로를 불러오지 못했어요'),
                  subtitle: Text(liveError(e)),
                  trailing: IconButton(
                      tooltip: '다시 찾기',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(seaRoutePlanProvider)))),
        ],
        data: (p) => p == null
            ? const <Widget>[]
            : [
                const Wrap(spacing: 14, runSpacing: 6, children: [
                  _Legend(color: seaColor, label: '바닷길', dashed: true),
                  _Legend(color: portColor, label: '항구 접안점'),
                  _Legend(color: landColor, label: '항구 → 대피소'),
                ]),
                const SizedBox(height: 6),
                SeaRouteSummary(plan: p),
              ],
      ),
    ]);
  }
}

class LiveSeaRouteScreen extends ConsumerStatefulWidget {
  const LiveSeaRouteScreen({super.key});
  @override
  ConsumerState<LiveSeaRouteScreen> createState() => _LiveSeaRouteScreenState();
}

class _LiveSeaRouteScreenState extends ConsumerState<LiveSeaRouteScreen> {
  LatLng? origin;
  SeaRoutePlan? plan;
  bool busy = false, elderly = false;
  String? error;

  Future<void> _go(LatLng p) async {
    setState(() {
      origin = p;
      busy = true;
      error = null;
    });
    try {
      final r = await ref.read(liveApiProvider).seaRoute(p.latitude, p.longitude, profile: elderly ? 'elderly' : 'adult');
      if (mounted && origin == p) setState(() => plan = SeaRoutePlan(r, p));
    } catch (e) {
      if (mounted) {
        setState(() {
          plan = null;
          error = liveError(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = plan;
    // 풍랑 특보는 경로 서버가 아니라 대시보드 특보(warnings)에서 (B11 명세)
    final warnings = (ref.watch(liveDashboardProvider).valueOrNull?['warnings'] as Map?)?['items'] as List? ?? const [];
    final highSeas = warnings.where((w) => w is Map && w['hazard'] == 'high_seas').toList();
    return LivePage(title: '바다 위 대피 경로', children: [
      const Text('배 위에서 대피해야 할 때: 지도에서 지금 배 위치(바다)를 누르면 가장 가까운 항구와 방향, 항구에서 대피소까지 길을 보여 줍니다.'),
      const SizedBox(height: 6),
      if (highSeas.isNotEmpty)
        Card(
            color: Colors.red.shade50,
            child: ListTile(
                leading: const Icon(Icons.warning_amber, color: Colors.red),
                title: Text('풍랑 특보 발효 중 · ${(highSeas.first as Map)['label'] ?? ''}'),
                subtitle: const Text('먼바다로 나가지 말고 가까운 항구로 바로 들어오세요.'))),
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(onPressed: busy ? null : () => _go(ref.read(userLocation).position), icon: const Icon(Icons.my_location),
            label: const Text('현재 위치로')),
        FilterChip(label: const Text('노약자 경로'), selected: elderly, onSelected: (v) {
          setState(() => elderly = v);
          if (origin != null) _go(origin!);
        }),
        if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
      const SizedBox(height: 6),
      Card(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
              height: 420,
              child: FlutterMap(
                  options: MapOptions(
                      initialCenter: const LatLng(35.985, 129.565),
                      initialZoom: 12.8,
                      minZoom: 11,
                      cameraConstraint: CameraConstraint.containCenter(bounds: guryongpoBounds),
                      onTap: (_, q) => busy ? null : _go(q)),
                  children: [
                    _tiles(),
                    if (p != null)
                      PolylineLayer(polylines: [
                        if (p.landPoints.length >= 2) Polyline(points: p.landPoints, color: Colors.white, strokeWidth: 9),
                        if (p.landPoints.length >= 2) Polyline(points: p.landPoints, color: landColor, strokeWidth: 5),
                        ...dashedLine(p.seaPoints, seaColor),
                      ]),
                    MarkerLayer(markers: [
                      if (origin != null)
                        Marker(point: origin!, width: 36, height: 36,
                            child: Icon(p?.atSea == false ? Icons.person_pin_circle : Icons.sailing, color: seaColor, size: 32)),
                      if (p?.berth != null)
                        Marker(point: p!.berth!, width: 34, height: 34, child: const Icon(Icons.anchor, color: portColor, size: 30)),
                      if (latLng(p?.destination) != null)
                        Marker(point: latLng(p!.destination)!, width: 34, height: 34, alignment: Alignment.topCenter,
                            child: const Icon(Icons.health_and_safety, color: landColor, size: 32)),
                    ]),
                    _osm,
                  ]))),
      const Wrap(spacing: 14, runSpacing: 6, children: [
        _Legend(color: seaColor, label: '해상 구간 (방파제·곶을 피한 바닷길)', dashed: true),
        _Legend(color: portColor, label: '항구 접안점'),
        _Legend(color: landColor, label: '육상 경로 (위험 구역 회피)'),
      ]),
      const SizedBox(height: 8),
      if (error != null) Card(child: ListTile(leading: const Icon(Icons.error_outline), title: Text(error!))),
      if (origin == null && error == null) const Card(child: ListTile(leading: Icon(Icons.touch_app_outlined), title: Text('지도에서 배 위치(바다)를 눌러 주세요'))),
      if (p != null) SeaRouteSummary(plan: p),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, this.dashed = false});
  final Color color;
  final String label;
  final bool dashed;
  @override
  Widget build(BuildContext c) => Row(mainAxisSize: MainAxisSize.min, children: [
        dashed
            ? Row(children: [for (var i = 0; i < 3; i++) Container(width: 6, height: 4, margin: const EdgeInsets.only(right: 2), color: color)])
            : Container(width: 22, height: 5, color: color),
        const SizedBox(width: 6),
        Text(label),
      ]);
}

class SeaRouteSummary extends StatelessWidget {
  const SeaRouteSummary({super.key, required this.plan});
  final SeaRoutePlan plan;
  @override
  Widget build(BuildContext c) {
    final leg = plan.seaLeg, port = plan.port, dest = plan.destination, land = plan.landRoute;
    String km(Object? m) => m is num ? (m >= 1000 ? '${(m / 1000).toStringAsFixed(1)}km' : '${m.round()}m') : '-';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!plan.atSea)
        const Card(child: ListTile(leading: Icon(Icons.landscape_outlined), title: Text('바다 위가 아닙니다'),
            subtitle: Text('육지 위치라 일반 대피 경로만 보여 줍니다. 배 위치는 바다를 눌러 주세요.'))),
      if (leg != null && port != null)
        Card(
            child: ListTile(
                leading: const Icon(Icons.anchor, color: portColor),
                title: Text('1. ${leg['bearing_label']} ${port['name']}까지 바닷길 ${km(leg['distance_m'])}'),
                subtitle: Text([
                  '방위 ${(leg['bearing_deg'] as num?)?.round() ?? '-'}° (진북 기준) · 직선 ${km(leg['straight_m'] ?? leg['distance_m'])}',
                  if (leg['direct'] == false && leg['path_found'] != false) '곶·방파제를 피해 지도의 파란 점선을 따라 돌아 들어가세요',
                  if (leg['path_found'] == false) '바닷길을 찾지 못해 지도에 선을 그리지 않았습니다. 방위만 참고하고 해안·방파제에 주의하세요',
                  if ((leg['alternatives'] as List?)?.isNotEmpty ?? false)
                    '다른 항구: ${[for (final a in leg['alternatives'] as List) '${(a as Map)['name']} ${a['bearing_label']} ${km(a['distance_m'])}'].join(', ')}',
                ].join('\n')))),
      if (land != null)
        Card(
            child: ListTile(
                leading: const Icon(Icons.directions_walk, color: landColor),
                title: Text('${plan.atSea ? '2. 항구에서 ' : ''}${dest?['name'] ?? '목적지'}까지 ${km(land['distance_m'])} · 약 ${((land['duration_s'] as num? ?? 0) / 60).ceil()}분'),
                subtitle: Text([
                  if (dest?['note'] != null) '${dest!['note']}',
                  if ((land['avoided'] as List?)?.isNotEmpty ?? false) '위험 구역 ${(land['avoided'] as List).length}곳을 피해 갑니다',
                  if ((land['still_inside'] as List?)?.isNotEmpty ?? false) '⚠ 피할 수 없는 위험 구역을 지납니다',
                  if (land['hazards_ok'] == false) '위험 구역 정보를 읽지 못해 회피 없이 계산했습니다',
                ].join('\n')))),
      if (plan.raw['land_route_error'] != null)
        Card(child: ListTile(leading: const Icon(Icons.error_outline), title: Text('${plan.raw['land_route_error']}'))),
      Text('해상 구간은 육지·방파제만 피한 대략의 바닷길입니다(수심·암초 미반영). 실제 항해는 선장 판단과 해경 안내를 따르세요.',
          style: Theme.of(c).textTheme.bodySmall),
    ]);
  }
}

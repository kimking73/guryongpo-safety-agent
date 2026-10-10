import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../live_screens.dart';
import '../main.dart';
import '../services/live_api.dart';
import '../services/location_service.dart';
import '../services/polyline.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

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
  'elderly': '고령', 'living_alone': '독거', 'mobility_limited': '거동 불편', 'wheelchair': '휠체어', 'bedridden': '와상',
  'hearing': '청각', 'vision': '시각', 'cognitive': '인지', 'medical_device': '의료기기', 'infant': '영유아', 'pet': '반려동물',
};

/// 취약 가구 분류 — 방재단 지도 아이콘·필터. 대피 상황이 아니어도 지도에 표시 (2026-10-05).
/// 시각·청각·지체 장애로 나눈다 (2026-10-11 사용자 요청 — 가구 대리 등록이 묻는 유형과 같게). '기타 취약 가구'는 없앴다:
/// 세 유형이 없는 가구는 지도·필터에 나오지 않는다. 휠체어·와상은 지체로 본다
enum VulnerableKind { vision, hearing, mobility }

Set<String> _needSet(Object? needs) => {for (final x in needs as List? ?? const []) '$x'};
const _kindNeeds = {
  VulnerableKind.vision: {'vision'},
  VulnerableKind.hearing: {'hearing'},
  VulnerableKind.mobility: {'mobility_limited', 'wheelchair', 'bedridden'},
};

/// 가구의 장애 유형들 (시각 → 청각 → 지체 순)
List<VulnerableKind> vulnerableKinds(Object? needs) {
  final s = _needSet(needs);
  return [for (final k in VulnerableKind.values) if (_kindNeeds[k]!.any(s.contains)) k];
}

/// 지도 아이콘 하나를 고른다 (여러 유형이면 앞의 것). 세 유형이 없으면 null
VulnerableKind? vulnerableKind(Object? needs) => vulnerableKinds(needs).firstOrNull;
bool isDisabledHousehold(Object? needs) => vulnerableKind(needs) != null;
const kindKo = {VulnerableKind.vision: '시각장애', VulnerableKind.hearing: '청각장애', VulnerableKind.mobility: '지체장애'};
const kindIcon = {
  VulnerableKind.vision: Icons.blind_rounded,
  VulnerableKind.hearing: Icons.hearing_disabled_rounded,
  VulnerableKind.mobility: Icons.accessible_rounded,
};
const kindColor = {
  VulnerableKind.vision: Color(0xff1565c0),
  VulnerableKind.hearing: Color(0xff00796b),
  VulnerableKind.mobility: Color(0xff6a1b9a),
};

/// 지도·목록 필터: 전체(세 유형 모두) · 시각 · 청각 · 지체
enum HouseholdFilter { all, vision, hearing, mobility }

const _filterKind = {
  HouseholdFilter.vision: VulnerableKind.vision,
  HouseholdFilter.hearing: VulnerableKind.hearing,
  HouseholdFilter.mobility: VulnerableKind.mobility,
};

bool matchesFilter(HouseholdFilter f, Object? needs) =>
    f == HouseholdFilter.all ? isDisabledHousehold(needs) : vulnerableKinds(needs).contains(_filterKind[f]);

/// 대피 상태 (A12) → 한글·색. 명단 정렬도 서버(priority_rank)를 따르고 앱은 표시만 한다
const statusKo = {'need_help': '도움 필요', 'no_response': '미응답', 'evacuating': '대피 중', 'evacuated': '대피 완료'};
Color statusColor(String? s) => switch (s) {
      'need_help' => const Color(0xffc62828),
      'no_response' => const Color(0xffe65100),
      'evacuating' => const Color(0xffc99a06),
      'evacuated' => const Color(0xff2e7d32),
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

class _DelegatedFormState extends ConsumerState<_DelegatedForm> {
  final draft = _HouseholdDraft();
  final consentBy = TextEditingController();
  String method = 'written';
  bool confirmed = false, busy = false;
  String? message;

  @override
  void dispose() {
    draft.dispose();
    consentBy.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (draft.label.text.trim().isEmpty || draft.location == null || consentBy.text.trim().isEmpty) {
      setState(() => message = '이름·집 위치·동의한 사람을 모두 넣어 주세요.');
      return;
    }
    setState(() => busy = true);
    try {
      final h = await ref.read(liveApiProvider).createHousehold(
          {...draft.body(), 'consent_method': method, 'consent_by': consentBy.text.trim()});
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
        _HouseholdFields(draft: draft, onChanged: () => setState(() {}), labelHint: '이름 또는 호칭 (필수)',
            here: ref.watch(userLocation).position),
        const Text('민감정보 동의 (별도)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        TextField(controller: consentBy,
            decoration: const InputDecoration(labelText: '동의한 사람 (예: 본인, 딸 김○○)', border: OutlineInputBorder())),
        const SizedBox(height: 6),
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
class MLiveResponderScreen extends StatelessWidget {
  const MLiveResponderScreen({super.key});
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
      // 등록 취약 가구는 대피 상황과 상관없이 늘 지도에 (장애 가구 평시 확인)
      final hh = await api.adminHouseholds();
      if (!mounted) return;
      setState(() {
        incidents = list;
        incidentId = id;
        households = hh;
        error = null;
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
      final d = await ref.read(liveApiProvider).incident(id);
      if (!mounted || id != incidentId) return;
      setState(() {
        detail = d;
        error = null;
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

  Future<void> _assign(Map<String, dynamic> t) async {
    final mine = (t['assigned_to'] as Map?)?['is_me'] == true;
    try {
      await ref.read(liveApiProvider).patchTarget(incidentId!, '${t['id']}', {'assigned_to': mine ? null : 'me'});
      await _loadDetail();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(liveError(e))));
    }
  }

  Future<void> _visit(Map<String, dynamic> t) async {
    final ok = await showVisitSheet(context, ref, incidentId: incidentId!, target: t);
    if (ok) await _loadDetail();
  }

  @override
  Widget build(BuildContext c) {
    if (error != null && incidents == null) return LoadError(message: error!, onRetry: _load);
    if (incidents == null) return const DashboardLoading();
    final targets = _targets;
    final incident = detail ?? incidents!.cast<Map<String, dynamic>?>().firstWhere((i) => i?['id'] == incidentId, orElse: () => null);
    final inTab = GoRouter.maybeOf(c)?.state.uri.path == '/team';
    final now = DateTime.now();
    final points = incidentId == null
        ? _householdPoints(const {})
        : [
            ..._householdPoints({for (final t in targets) if (t['household_id'] != null) '${t['household_id']}'}),
            for (final t in targets)
              if (latLng(t['location']) != null)
                _MapPoint('${t['id']}', latLng(t['location'])!, (t['priority_rank'] as num?)?.toInt(), t['status'] as String?, '${t['label']}'),
          ];
    final rings = incidentId == null ? const <List<LatLng>>[] : geoJsonRings(detail?['area']);
    final focus = incidentId == null
        ? null
        : [
            for (final t in targets)
              if (latLng(t['location']) != null) latLng(t['location'])!,
            for (final r in rings) ...r,
          ];
    Widget map({double height = 240}) => _PatrolMap(
        points: points,
        rings: rings,
        selected: selected,
        onTap: (id) => setState(() => selected = id),
        focus: focus,
        height: height);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
        if (inTab) const ScreenTitle('주민 대피 현황'),
        Row(children: [
          Expanded(
              child: Text('구룡포읍 자율방재단 · ${incidentId == null ? '' : '10초마다 '}갱신 ${now.hour}:${'${now.minute}'.padLeft(2, '0')}',
                  style: dsText(14, color: Ds.muted))),
          CircleButton(FontAwesomeIcons.userPlus,
              size: 40, tooltip: '가구 대리 등록', onPressed: () => c.push('/household/delegate')),
        ]),
        if (error != null) ErrorLine(error!),
        if (incidents!.length > 1)
          DropdownButton<String>(
              isExpanded: true,
              value: incidentId,
              items: [for (final i in incidents!) DropdownMenuItem(value: '${i['id']}', child: Text('${i['title']}'))],
              onChanged: (v) {
                setState(() {
                  incidentId = v;
                  detail = null;
                  selected = null;
                });
                _loadDetail();
              }),
        const SizedBox(height: 8),
        if (incidentId != null && incident != null) ...[
          _IncidentHeader(incident: incident),
          const SizedBox(height: 12),
        ],
        // 지도 (누르면 전체화면)
        AppCard(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('지도', style: dsText(19, weight: FontWeight.w800)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(incidentId == null ? '등록 취약 가구' : '우선 확인 가구 · 대피 영역',
                        style: dsText(13, color: Ds.muted))),
                CircleButton(FontAwesomeIcons.expand,
                    size: 34,
                    bg: Ds.bg,
                    tooltip: '지도 전체화면으로 보기',
                    onPressed: () => showGeneralDialog<void>(
                        context: c,
                        barrierDismissible: false,
                        pageBuilder: (dc, __, ___) => Scaffold(
                              body: Stack(children: [
                                Positioned.fill(child: StatefulBuilder(builder: (_, __) => map(height: double.infinity))),
                                Positioned(
                                  left: 16,
                                  right: 16,
                                  top: MediaQuery.paddingOf(dc).top + 12,
                                  child: Row(children: [
                                    PillChip('지도', height: 44, fontSize: 17, fg: Ds.ink),
                                    const SizedBox(width: 8),
                                    if (rings.isNotEmpty)
                                      const PillChip('대피 영역', height: 32, fontSize: 13, fg: Ds.dangerDeep),
                                    const Spacer(),
                                    CircleButton(FontAwesomeIcons.compress,
                                        size: 44, bg: Ds.navy, fg: Colors.white, tooltip: '전체화면 닫기',
                                        onPressed: () => Navigator.of(dc).pop()),
                                  ]),
                                ),
                              ]),
                            ))),
              ]),
            ),
            ClipRRect(borderRadius: BorderRadius.circular(16), child: map()),
            const SizedBox(height: 8),
            _FilterBar(households: households ?? const [], filter: filter, onChanged: (f) => setState(() => filter = f)),
            _MapLegend(withTargets: incidentId != null),
          ]),
        ),
        const SizedBox(height: 12),
        if (incidentId == null) ...[
          AppCard(
            child: Row(children: [
              const IconCircle(FontAwesomeIcons.circleCheck, size: 40, iconSize: 17, bg: Ds.goodSoft, fg: Ds.goodDeep),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('진행 중인 대피 상황이 없습니다', style: dsText(16, weight: FontWeight.w800)),
                  Text('평시에도 장애 가구를 지도에서 확인할 수 있어요. 대피 상황이 생기면 대상 가구가 번호(우선순위)로 바뀌어요.',
                      style: dsText(13, color: Ds.muted, height: 1.45)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          for (final h in _shownHouseholds) _HouseholdTile(h: h, selected: selected == '${h['id']}'),
          if (_shownHouseholds.isEmpty)
            AppCard(child: Text('조건에 맞는 등록 가구가 없습니다', style: dsText(15, weight: FontWeight.w700))),
        ] else ...[
          _PriorityCard(targets: targets, onSelect: (id) => setState(() => selected = id)),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(child: Text('방재단 배정 현황', style: dsText(19, weight: FontWeight.w800))),
                  Text(
                      '배정 ${targets.where((t) => t['assigned_to'] != null).length}가구 · 미배정 ${targets.where((t) => t['assigned_to'] == null).length}가구',
                      style: dsText(12, weight: FontWeight.w700, color: Ds.muted)),
                ]),
              ),
              HScroll(fade: false, children: [
                for (final (i, st) in patrolStages.indexed)
                  Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(color: Ds.bg, borderRadius: BorderRadius.circular(Ds.pill)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: st.$2, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text('${st.$1} ${targets.where((t) => patrolStage(t) == i).length}',
                          style: dsText(13, weight: FontWeight.w800)),
                    ]),
                  ),
              ]),
              const SizedBox(height: 10),
              if (detail == null) const LinearProgressIndicator(),
              if (detail != null && targets.isEmpty)
                Text('이 대피 상황의 대상 가구가 없습니다', style: dsText(15, weight: FontWeight.w700)),
              for (final t in [...targets.where((t) => '${t['id']}' == selected), ...targets.where((t) => '${t['id']}' != selected)])
                _TargetCard(t: t, selected: '${t['id']}' == selected, closed: detail?['closed_at'] != null,
                    onVisit: () => _visit(t), onAssign: () => _assign(t), onSelect: () => setState(() => selected = '${t['id']}')),
              // 대피 대상이 아닌 등록 가구도 지도에서 눌러 볼 수 있게
              for (final h in _shownHouseholds.where((h) => '${h['id']}' == selected)) _HouseholdTile(h: h, selected: true),
            ]),
          ),
        ],
      ]),
    );
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

/// 전체 / 시각 / 청각 / 지체 필터 (개수 포함)
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
          chip(HouseholdFilter.all, '등록 장애 가구 전체', Icons.home_work_outlined, Ds.navy),
          for (final e in _filterKind.entries) chip(e.key, kindKo[e.value]!, kindIcon[e.value]!, kindColor[e.value]!),
        ]));
  }
}

class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.withTargets});
  final bool withTargets;
  @override
  Widget build(BuildContext c) {
    Widget item(Widget mark, String label) => Row(mainAxisSize: MainAxisSize.min, children: [mark, const SizedBox(width: 4), Text(label)]);
    Widget icon(VulnerableKind k) => Icon(kindIcon[k], size: 18, color: kindColor[k]);
    return Wrap(spacing: 14, runSpacing: 4, children: [
      if (withTargets)
        item(CircleAvatar(radius: 8, backgroundColor: statusColor('need_help'),
            child: const Text('1', style: TextStyle(fontSize: 10, color: Colors.white))), '대피 대상 (번호 = 우선순위, 색 = 상태)'),
      for (final k in VulnerableKind.values) item(icon(k), '${kindKo[k]} 가구'),
    ]);
  }
}

class _IncidentHeader extends StatelessWidget {
  const _IncidentHeader({required this.incident});
  final Map<String, dynamic> incident;
  @override
  Widget build(BuildContext c) {
    final s = Map<String, dynamic>.from(incident['summary'] as Map? ?? const {});
    final tiles = [
      ('도움 필요', s['need_help'], Ds.danger, FontAwesomeIcons.lifeRing),
      ('미응답', s['no_response'], Ds.noResp, FontAwesomeIcons.headset),
      ('대피 중', s['evacuating'], Ds.warnDeep, FontAwesomeIcons.personWalking),
      ('대피 완료', s['evacuated'], Ds.goodDeep, FontAwesomeIcons.check),
    ];
    Widget tile((String, Object?, Color, FaIconData) t) => Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            IconCircle(t.$4, size: 36, iconSize: 14, bg: t.$3, fg: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(t.$1, maxLines: 1, style: dsText(14, weight: FontWeight.w800))),
            Text('${t.$2 ?? 0}', style: dsText(26, weight: FontWeight.w800, color: t.$3, height: 1)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        FaIcon(FontAwesomeIcons.bullhorn, size: 15, color: levelColor(incident['level'] as String?)),
        const SizedBox(width: 6),
        Expanded(child: Text('${incident['title']}', style: dsText(16, weight: FontWeight.w800))),
        Text('${hhmm(incident['started_at'])} 시작 · 대상 ${s['total'] ?? 0} · 방문 ${s['visited'] ?? 0}',
            style: dsText(12, color: Ds.muted)),
      ]),
      const SizedBox(height: 8),
      Row(children: [Expanded(child: tile(tiles[0])), const SizedBox(width: 8), Expanded(child: tile(tiles[1]))]),
      const SizedBox(height: 8),
      Row(children: [Expanded(child: tile(tiles[2])), const SizedBox(width: 8), Expanded(child: tile(tiles[3]))]),
    ]);
  }
}

/// 방재단 배정 단계 (디자인: 미배정 → 가는 중 → 방문 중 → 대피 중 → 대피 완료)
const patrolStages = [
  ('미배정', Ds.danger),
  ('가는 중', Ds.warnDeep),
  ('방문 중', Ds.navy),
  ('대피 중', Color(0xFF5B6690)),
  ('대피 완료', Ds.goodDeep),
];

int patrolStage(Map<String, dynamic> t) {
  if (t['status'] == 'evacuated') return 4;
  if (t['status'] == 'evacuating') return 3;
  if (t['last_visit'] != null) return 2;
  if (t['assigned_to'] != null) return 1;
  return 0;
}

/// 우선 확인 가구: 도움 필요·미응답 대상만 우선순위 순서로
class _PriorityCard extends StatelessWidget {
  const _PriorityCard({required this.targets, required this.onSelect});
  final List<Map<String, dynamic>> targets;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext c) {
    final urgent = targets.where((t) => t['status'] == 'need_help' || t['status'] == 'no_response').toList();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('우선 확인 가구', style: dsText(19, weight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('도움 필요 › 미응답 · 장애·고령 가구 먼저 (서버 우선순위)', style: dsText(12, color: Ds.muted, height: 1.5)),
        const SizedBox(height: 10),
        if (urgent.isEmpty)
          Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Ds.bg, borderRadius: BorderRadius.circular(14)),
            child: Text('급한 가구가 없어요', style: dsText(15, weight: FontWeight.w700, color: Ds.muted)),
          ),
        for (final t in urgent)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: statusColor(t['status'] as String?).withValues(alpha: .09),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelect('${t['id']}'),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(children: [
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: statusColor(t['status'] as String?), shape: BoxShape.circle),
                      child: Text('${t['priority_rank'] ?? '-'}',
                          style: dsText(13, weight: FontWeight.w900, color: Colors.white)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text.rich(TextSpan(children: [
                          TextSpan(text: '${t['label']}  ', style: dsText(15, weight: FontWeight.w800)),
                          TextSpan(
                              text: [statusKo[t['status']] ?? '', if ((t['needs'] as List?)?.isNotEmpty ?? false) needsText(t['needs'])].join(' · '),
                              style: dsText(11, weight: FontWeight.w800, color: statusColor(t['status'] as String?))),
                        ]), maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (t['address'] != null)
                          Text('${t['address']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(12, color: Ds.muted)),
                      ]),
                    ),
                    Text(t['assigned_to'] == null ? '미배정' : '${(t['assigned_to'] as Map)['is_me'] == true ? '내가' : (t['assigned_to'] as Map)['nickname'] ?? '방재단'} 배정',
                        style: dsText(12, weight: FontWeight.w800, color: t['assigned_to'] == null ? Ds.danger : Ds.muted)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _MapPoint {
  const _MapPoint(this.id, this.at, this.rank, this.status, this.label, {this.kind, this.detail});
  final String id;
  final LatLng at;
  final int? rank;              // 대피 대상이면 우선순위
  final String? status;         // 대피 대상이면 대피 상태
  final String label;
  final VulnerableKind? kind;   // 등록 가구(대피 대상 아님)면 시각·청각·지체
  final String? detail;
}

/// 방재단 지도: 대피 대상은 번호(우선순위)·색(대피 상태), 등록 취약 가구는 장애인·기타 아이콘. 대피 영역은 붉은 다각형
class _PatrolMap extends StatefulWidget {
  const _PatrolMap({required this.points, required this.rings, required this.selected, required this.onTap, this.focus, this.height = 320});
  final List<_MapPoint> points;
  final List<List<LatLng>> rings;
  final String? selected;
  final ValueChanged<String> onTap;
  /// 처음 화면에 맞출 좌표 (대피 상황이면 대상 가구·영역, 없으면 전체 점)
  final List<LatLng>? focus;
  final double height;

  @override
  State<_PatrolMap> createState() => _PatrolMapState();
}

class _PatrolMapState extends State<_PatrolMap> {
  final controller = MapController();

  List<LatLng> get _focus =>
      widget.focus ?? [for (final p in widget.points) p.at, for (final r in widget.rings) ...r];

  /// 지도가 준비된 뒤 화면을 맞춘다. initialCameraFit으로 맞추면 웹에서 처음 타일을 안 받아 회색으로 남았다 (2026-10-05)
  void _fit() {
    final f = _focus;
    if (f.length >= 2) {
      controller.fitCamera(CameraFit.coordinates(coordinates: f, padding: const EdgeInsets.all(36), maxZoom: 16.5));
    } else if (f.length == 1) {
      controller.move(f.first, 16);
    }
  }

  @override
  void didUpdateWidget(covariant _PatrolMap old) {
    super.didUpdateWidget(old);
    // 대피 상황이 바뀌거나 점 개수가 바뀌면 다시 맞춘다 (10초 갱신마다 움직이지 않게 개수로만 본다)
    if (old.focus?.length != widget.focus?.length || old.points.length != widget.points.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _fit() : null);
    }
  }

  @override
  Widget build(BuildContext c) {
    final points = widget.points, rings = widget.rings, selected = widget.selected, onTap = widget.onTap;
    return SizedBox(
            height: widget.height,
            child: FlutterMap(
                mapController: controller,
                options: MapOptions(
                    initialCenter: const LatLng(35.987, 129.552),
                    initialZoom: 14.5,
                    onMapReady: _fit),
                children: [
                  _tiles(),
                  if (rings.isNotEmpty)
                    PolygonLayer(polygons: [
                      for (final r in rings)
                        Polygon(points: r, color: Colors.red.withValues(alpha: .12), borderColor: Colors.red.shade700, borderStrokeWidth: 2),
                    ]),
                  MarkerLayer(markers: [
                    for (final p in points)
                      Marker(
                          point: p.at,
                          width: p.id == selected ? 40 : 30,
                          height: p.id == selected ? 40 : 30,
                          child: GestureDetector(
                              onTap: () => onTap(p.id),
                              child: Tooltip(
                                  message: p.kind != null
                                      ? '${p.label} · ${kindKo[p.kind]}${p.detail?.isNotEmpty ?? false ? ' (${p.detail})' : ''}'
                                      : '${p.rank != null ? '${p.rank}순위 ' : ''}${p.label} · ${statusKo[p.status] ?? '대피 대상'}',
                                  child: Container(
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                          color: p.kind != null ? kindColor[p.kind] : statusColor(p.status),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white, width: p.id == selected ? 3 : 2),
                                          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)]),
                                      child: p.kind != null
                                          ? Icon(kindIcon[p.kind], color: Colors.white, size: 18)
                                          : Text('${p.rank ?? '-'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))))),
                  ]),
                  _osm,
                ]));
  }
}

/// 우선순위 근거: 서버 priority_reasons(B13) 가 있으면 그대로, 없으면 지금 쓰는 대체 순서(상태 → 필요 항목 수)를 밝힌다
String priorityReason(Map<String, dynamic> t) {
  final reasons = [for (final r in t['priority_reasons'] as List? ?? const []) if (r is Map) '${r['label'] ?? r['factor']}'];
  if (reasons.isNotEmpty) return reasons.join(' · ');
  final n = (t['needs'] as List?)?.length ?? 0;
  return '${statusKo[t['status']] ?? t['status']} 우선${n > 0 ? ' · 도움 필요한 점 $n개' : ''}';
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.t, required this.selected, required this.closed, required this.onVisit,
      required this.onAssign, required this.onSelect});
  final Map<String, dynamic> t;
  final bool selected, closed;
  final VoidCallback onVisit, onAssign, onSelect;

  @override
  Widget build(BuildContext c) {
    final status = t['status'] as String?;
    final assigned = t['assigned_to'] as Map?;
    final visit = t['last_visit'] as Map?;
    final mins = t['minutes_since_alert'];
    final stage = patrolStage(t);
    final st = patrolStages[stage];
    final small = dsText(12, color: Ds.muted, height: 1.45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Ds.bg,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: selected ? const BorderSide(color: Ds.navy, width: 2) : BorderSide.none),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: statusColor(status), shape: BoxShape.circle),
                  child: Text('${t['priority_rank'] ?? '-'}', style: dsText(12, weight: FontWeight.w900, color: Colors.white)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('${t['label']}', style: dsText(16, weight: FontWeight.w800))),
                if (assigned != null) ...[
                  const FaIcon(FontAwesomeIcons.idBadge, size: 11, color: Ds.navy),
                  const SizedBox(width: 4),
                  Text(assigned['is_me'] == true ? '내가 맡음' : '담당: ${assigned['nickname'] ?? '방재단'}',
                      style: dsText(13, weight: FontWeight.w800, color: Ds.navy)),
                  const SizedBox(width: 6),
                ],
                Container(
                  height: 26,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: statusColor(status), borderRadius: BorderRadius.circular(Ds.pill)),
                  child: Text(statusKo[status] ?? '$status', style: dsText(12, weight: FontWeight.w800, color: Colors.white)),
                ),
              ]),
              const SizedBox(height: 4),
              Text([
                if (t['address'] != null) '${t['address']}',
                if ((t['needs'] as List?)?.isNotEmpty ?? false) needsText(t['needs']),
                if (mins is num) '경고 후 $mins분',
                if (t['escalated'] == true) '재알림 ${t['reminder_count'] ?? ''}회 무응답',
              ].join(' · '), style: dsText(13, color: Ds.sub, height: 1.45)),
              Text('순위 근거: ${priorityReason(t)}', style: small),
              if (visit != null)
                Text('마지막 방문 ${hhmm(visit['visited_at'])} · ${visitKo[visit['result']] ?? visit['result']}'
                    '${(visit['responder'] as Map?)?['nickname'] != null ? ' (${(visit['responder'] as Map)['nickname']})' : ''}',
                    style: small),
              const SizedBox(height: 8),
              // 출발 → 방문 → 대피 동행 → 완료
              Row(children: [
                for (final (i, l) in const ['출발', '방문', '대피 동행', '완료'].indexed) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Column(children: [
                      Container(
                          height: 6,
                          decoration: BoxDecoration(
                              color: i < stage ? st.$2 : const Color(0xFFDDE1EC), borderRadius: BorderRadius.circular(3))),
                      const SizedBox(height: 4),
                      Text(l,
                          style: dsText(11,
                              weight: i < stage ? FontWeight.w800 : FontWeight.w600,
                              color: i < stage ? Ds.ink : Ds.faint)),
                    ]),
                  ),
                ]
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (!closed)
                  FilledButton.icon(
                      onPressed: onVisit,
                      icon: const FaIcon(FontAwesomeIcons.clipboardCheck, size: 14),
                      label: const Text('방문 결과')),
                if (!closed) TextButton(onPressed: onAssign, child: Text(assigned?['is_me'] == true ? '맡기 취소' : '내가 맡기')),
                if (t['phone'] != null)
                  IconButton(tooltip: '전화', icon: const FaIcon(FontAwesomeIcons.phone, size: 16), onPressed: () => launchUrl(Uri.parse('tel:${t['phone']}'))),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _HouseholdTile extends StatelessWidget {
  const _HouseholdTile({required this.h, required this.selected});
  final Map<String, dynamic> h;
  final bool selected;
  @override
  Widget build(BuildContext c) => Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? Ds.soft : Colors.white,
      child: ListTile(
          leading: Icon(kindIcon[vulnerableKind(h['needs'])], color: kindColor[vulnerableKind(h['needs'])]),
          title: Text('${h['label']}'),
          subtitle: Text([
            if (h['address'] != null) '${h['address']}',
            needsText(h['needs']),
            if (h['landslide_zone'] != null) '⚠ ${h['landslide_zone']}',
          ].where((x) => x.isNotEmpty).join(' · ')),
          trailing: h['phone'] != null
              ? IconButton(icon: const Icon(Icons.phone), onPressed: () => launchUrl(Uri.parse('tel:${h['phone']}')))
              : null));
}

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
      if (p != null) _SeaRouteSummary(plan: p),
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

class _SeaRouteSummary extends StatelessWidget {
  const _SeaRouteSummary({required this.plan});
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

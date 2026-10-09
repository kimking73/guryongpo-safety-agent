import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'live_screens.dart';
import 'main.dart';
import 'models/domain_models.dart';
import 'patrol_screens.dart' show isPatrolRole, roleKo;
import 'services/account_service.dart';
import 'services/demo_mode.dart';
import 'services/geocoding_service.dart';
import 'services/live_api.dart';
import 'services/prototype_safety_store.dart';
import 'ui/gk_theme.dart';
import 'ui/gk_widgets.dart';

/// 사용자 화면(웹) 카드 모음 (2026-10-09 사용자 요청: 간결한 요약 카드 · 알림 목록 · 안전 기능 2개 · 방재단 로그인).
/// 보행 능력·보호가 필요한 동반자·출발 위치는 어디서도 묻거나 보여 주지 않는다.

// ------------------------------------------------------------------ 접근성 지원 (시각·청각)

/// 프로필의 시각·청각 지원 값 (선택 정보 '시각 지원'·'청각 지원', 서버 vision_impaired·hearing_impaired와 같은 칸).
/// 빈 값 = 아직 정하지 않음, '필요 없음' = 꺼 둠, 그 밖(지원 필요·저시력 …) = 켬
const _supportKeys = {'시각 지원': ['시각 지원', '시각'], '청각 지원': ['청각 지원', '청각']};

String _support(Map<String, String> p, String key) {
  for (final k in _supportKeys[key]!) {
    final v = (p[k] ?? '').trim();
    if (v.isNotEmpty) return v;
  }
  return '';
}

bool _supportOn(String v) => v.isNotEmpty && v != '필요 없음' && v != 'false';

/// 요약 카드 '접근성 지원' 값: 켠 것 이름 / 둘 다 정하지 않음 → '설정 안 함' / 정했지만 켠 것 없음 → '사용 안 함'
String accessibilitySummary(Map<String, String> p) {
  final vision = _support(p, '시각 지원'), hearing = _support(p, '청각 지원');
  final on = [if (_supportOn(vision)) '시각', if (_supportOn(hearing)) '청각'];
  if (on.isNotEmpty) return on.join(' · ');
  if (vision.isEmpty && hearing.isEmpty) return '설정 안 함';
  return '사용 안 함';
}

/// 알림 카드의 시각·청각 지원 스위치를 프로필 값에도 남긴다 — 요약 카드·서버·AI가 같은 뜻을 보게.
/// 켤 때 이미 '저시력'처럼 자세한 값이 있으면 그대로 둔다
Future<void> saveSupportToProfile(String key, bool on) async {
  final p = await AccountService().optionalProfile();
  final now = _support(p, key);
  if (on && _supportOn(now)) return;
  if (!on && now == '필요 없음') return;
  await AccountService().saveOptionalProfile({
    ...p,
    for (final legacy in _supportKeys[key]!.skip(1)) legacy: '',
    key: on ? '지원 필요' : '필요 없음',
  }..removeWhere((k, v) => v.isEmpty && _supportKeys[key]!.skip(1).contains(k)));
}

// ------------------------------------------------------------------ 내 정보 (요약 카드 ↔ 수정)

class ProfileDetailsCard extends ConsumerStatefulWidget {
  const ProfileDetailsCard({super.key});
  @override
  ConsumerState<ProfileDetailsCard> createState() => _ProfileDetailsCardState();
}

class _ProfileDetailsCardState extends ConsumerState<ProfileDetailsCard> {
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  /// 고른 직업 칩 ('기타' 제외). '기타'는 [jobOther] + 직접 입력 [jobOtherText]
  final jobs = <String>{};
  final jobOtherText = TextEditingController();
  final jobOtherFocus = FocusNode();
  bool jobOther = false;
  String transport = '';
  Map<String, String> saved = const {};
  // 보행 능력·보호 동반자·출발 위치는 여기서 묻지 않는다 (2026-10-09). 출발 위치는 대시보드 '경로 안내'에서 고른다
  bool loading = true;
  bool editing = false;
  static const jobOptions = [
    '어업 종사자·뱃사람',
    '자영업자',
    '농업 종사자',
    '축산업 종사자',
    '양식업 종사자·수산물 양식',
    '기타',
  ];
  static const transports = ['도보', '휠체어', '자동차'];

  @override
  void initState() {
    super.initState();
    for (final k in [
      'age',
      'homeName',
      'homeAddress',
      'homeLat',
      'homeLon',
      'workName',
      'workAddress',
      'workLat',
      'workLon',
    ]) {
      fields[k] = TextEditingController();
    }
    _load();
  }

  Future<void> _load() async {
    final p = await AccountService().optionalProfile();
    saved = p;
    for (final e in fields.entries) {
      e.value.text = p[e.key] ?? '';
    }
    // 칩에 없는 직업(직접 입력·AI가 기억한 직업)은 '기타' + 직접 입력칸으로 보여 준다
    final jobList = (p['jobs'] ?? '').split('|').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    final others = jobList.where((x) => !jobOptions.contains(x)).toList();
    jobs
      ..clear()
      ..addAll(jobList.where((x) => jobOptions.contains(x) && x != '기타'));
    jobOther = jobList.contains('기타') || others.isNotEmpty;
    jobOtherText.text = others.join(', ');
    transport = transports.contains(p['transport']) ? p['transport']! : '';
    if (mounted) setState(() => loading = false);
  }

  /// 저장할 직업 목록: 고른 칩 + '기타'면 직접 입력한 글자 (비었으면 '기타')
  List<String> _jobList() {
    final other = jobOtherText.text.replaceAll('|', ',').trim();
    return [
      for (final j in jobOptions)
        if (j != '기타' && jobs.contains(j)) j,
      if (jobOther) other.isEmpty ? '기타' : other,
    ];
  }

  Future<void> _save() async {
    if (!(form.currentState?.validate() ?? false)) return;
    await _persist();
    if (mounted) setState(() => editing = false);
  }

  Future<void> _persist({bool notify = true}) async {
    // 다른 화면이 저장한 항목(선택 정보 등)을 지우지 않게 지금 저장된 값에 이 카드 칸만 덮어쓴다
    final p = <String, String>{
      ...await AccountService().optionalProfile(),
      for (final e in fields.entries) e.key: e.value.text.trim(),
      'transport': transport,
      'jobs': _jobList().join('|'),
    };
    await AccountService().saveOptionalProfile(p);
    saved = p;
    if (mounted && notify) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('내 정보를 저장했어요. 로그인 계정에도 함께 저장돼요.')));
      setState(() {});
    }
  }

  void _cancel() {
    setState(() => editing = false);
    _load();
  }

  String _placeText(String k, String fallback) {
    final name = fields['${k}Name']!.text.trim(), addr = fields['${k}Address']!.text.trim();
    if (addr.isEmpty) return '';
    return name.isEmpty || name == fallback ? addr : '$name · $addr';
  }

  // ---------------------------------------------------------------- 요약 카드 (이미지 3)

  Widget _summary(List<SavedPlace> places) {
    final age = fields['age']!.text.trim();
    final jobList = _jobList();
    final a11y = accessibilitySummary(saved);
    // 집 = 프로필 집 주소. 비었으면 '집'으로 등록한 장소 하나를 집으로 보여 준다. 나머지는 모두 '내 장소'
    var home = _placeText('home', '집');
    final homeFromList = home.isEmpty ? places.where((p) => p.type == '집').firstOrNull : null;
    if (homeFromList != null) home = _savedText(homeFromList);
    final work = _placeText('work', '직장');
    final mine = [
      if (work.isNotEmpty) ('직장', work),
      for (final p in places)
        if (p != homeFromList) (p.type == '기타' ? '' : p.type, _savedText(p)),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GkInfoRow(icon: Icons.cake_rounded, label: '나이', value: age.isEmpty ? '입력 안 함' : '$age세', empty: age.isEmpty),
      GkInfoRow(
          icon: Icons.accessibility_new_rounded,
          label: '접근성 지원',
          value: a11y,
          empty: a11y == '설정 안 함' || a11y == '사용 안 함'),
      GkInfoRow(
          icon: Icons.directions_walk_rounded,
          label: '이동 수단',
          value: transport.isEmpty ? '선택 안 함' : transport,
          empty: transport.isEmpty),
      GkInfoRow(
          icon: Icons.work_rounded,
          label: '직업',
          value: jobList.isEmpty ? '입력 안 함' : jobList.join(' · '),
          empty: jobList.isEmpty),
      GkInfoRow(icon: Icons.home_rounded, label: '집', value: home.isEmpty ? '등록 안 함' : home, empty: home.isEmpty),
      GkInfoRow(
          icon: Icons.bookmark_rounded,
          label: '내 장소',
          divider: false,
          value: mine.isEmpty ? '등록 안 함' : '',
          empty: mine.isEmpty,
          valueWidget: mine.isEmpty
              ? null
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final (kind, text) in mine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text.rich(
                          TextSpan(children: [
                            if (kind.isNotEmpty)
                              TextSpan(text: '$kind · ', style: const TextStyle(color: GK.muted, fontWeight: FontWeight.w500)),
                            TextSpan(text: text),
                          ]),
                          style: const TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.w700, color: GK.ink)),
                    ),
                ])),
    ]);
  }

  String _savedText(SavedPlace p) =>
      p.address.isEmpty || p.address == p.name ? p.name : '${p.name} · ${p.address}';

  // ---------------------------------------------------------------- 수정 화면 (라벨은 칸 바깥 위)

  static const _labelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: GK.ink, height: 1.35);
  static const _subStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: GK.muted);
  static const _fieldGap = SizedBox(height: 20);

  /// 라벨(위) + 칸(아래). 입력칸이면([input]) 라벨을 칸의 이름으로 붙여 화면 읽기에서 '나이 (선택), 입력칸'처럼 읽힌다.
  /// 칩 묶음은 라벨을 제목으로 두고 칩마다 따로 읽힌다
  Widget _labeled(String label, Widget field, {String? sub, bool input = true}) {
    final title = Text.rich(TextSpan(text: label, children: [if (sub != null) TextSpan(text: ' $sub', style: _subStyle)]),
        style: _labelStyle);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      input ? ExcludeSemantics(child: title) : Semantics(header: true, child: title),
      const SizedBox(height: 8),
      input ? Semantics(label: sub == null ? label : '$label $sub', child: field) : field,
    ]);
  }

  Future<void> _editPlace(String key, String title) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final name = TextEditingController(text: fields['${key}Name']!.text),
            addr = TextEditingController(text: fields['${key}Address']!.text);
        var busy = false;
        return StatefulBuilder(
          builder: (ctx, setInner) => AlertDialog(
            title: Text('$title 수정'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: '장소명')),
                const SizedBox(height: 8),
                TextField(
                  controller: addr,
                  decoration: const InputDecoration(
                      labelText: '도로명 주소', hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152'),
                ),
              ]),
            ),
            actions: [
              if (fields['${key}Address']!.text.isNotEmpty)
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          for (final f in ['Name', 'Address', 'Lat', 'Lon']) {
                            fields['$key$f']!.clear();
                          }
                          Navigator.pop(ctx);
                          await _persist(notify: false);
                          if (mounted) setState(() {});
                        },
                  child: const Text('지우기'),
                ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (addr.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('도로명 주소를 입력해 주세요.')));
                          return;
                        }
                        setInner(() => busy = true);
                        try {
                          final resolved = await GeocodingService().resolve(addr.text);
                          fields['${key}Name']!.text = name.text;
                          fields['${key}Address']!.text = resolved.address;
                          fields['${key}Lat']!.text = '${resolved.position.latitude}';
                          fields['${key}Lon']!.text = '${resolved.position.longitude}';
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) setState(() {});
                          await _persist(notify: false);
                        } on GeocodingException catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                          }
                          if (ctx.mounted) setInner(() => busy = false);
                        }
                      },
                child: Text(busy ? '주소 확인 중…' : '저장'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _placeTile(String k) {
    final title = k == 'home' ? '집' : '직장·대표 작업장';
    final text = _placeText(k, k == 'home' ? '집' : '직장');
    return Row(children: [
      Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: _labelStyle),
        Text(text.isEmpty ? '등록 안 함' : text, style: TextStyle(fontSize: 15, color: text.isEmpty ? GK.grey : GK.ink)),
      ])),
      IconButton(
        tooltip: '$title 수정',
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        icon: const Icon(Icons.edit_rounded, size: 20),
        onPressed: () => _editPlace(k, k == 'home' ? '집' : '직장'),
      ),
    ]);
  }

  Widget _editForm(List<SavedPlace> places) => Form(
        key: form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _labeled(
            '나이',
            sub: '(선택)',
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: TextFormField(
                  controller: fields['age'],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 16),
                  decoration: const InputDecoration(hintText: '예: 35', suffixText: '세'),
                  validator: (x) {
                    final t = (x ?? '').trim();
                    if (t.isEmpty) return null;
                    final n = int.tryParse(t);
                    return n == null || n < 1 || n > 119 ? '1~119 사이 숫자를 입력하세요' : null;
                  },
                ),
              ),
            ),
          ),
          _fieldGap,
          _labeled(
            '기본 이동 수단',
            sub: '(선택 · 하나)',
            input: false,
            // 경로 안내·AI가 하나를 기준으로 길을 계산한다. '선택 안 함'이면 도보로 안내
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in ['', ...transports])
                ChoiceChip(
                  label: Text(t.isEmpty ? '선택 안 함' : t, style: const TextStyle(fontSize: 15)),
                  selected: transport == t,
                  onSelected: (_) => setState(() => transport = t),
                ),
            ]),
          ),
          _fieldGap,
          const Text.rich(TextSpan(text: '직업', children: [TextSpan(text: ' (선택 · 복수 선택)', style: _subStyle)]),
              style: _labelStyle),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final j in jobOptions)
              FilterChip(
                label: Text(j, style: const TextStyle(fontSize: 15)),
                selected: j == '기타' ? jobOther : jobs.contains(j),
                onSelected: (v) => setState(() {
                  if (j != '기타') {
                    v ? jobs.add(j) : jobs.remove(j);
                  } else {
                    jobOther = v;
                    // '기타'를 끄면 적어 둔 글자도 지운다 — 저장·표시되지 않게. 켠 직후에만 입력칸으로 커서를 옮긴다
                    // (autofocus면 수정 화면을 열 때마다 커서가 이 칸으로 간다)
                    if (!v) jobOtherText.clear();
                    if (v) WidgetsBinding.instance.addPostFrameCallback((_) => jobOtherFocus.requestFocus());
                  }
                }),
              ),
          ]),
          if (jobOther) ...[
            const SizedBox(height: 12),
            _labeled(
              '직업 직접 입력',
              TextFormField(
                controller: jobOtherText,
                focusNode: jobOtherFocus,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(hintText: '직업을 입력해 주세요'),
              ),
            ),
          ],
          _fieldGap,
          const Text('도로명 주소는 서버에서 좌표로 바꿔요.', style: TextStyle(fontSize: 14, color: GK.muted)),
          const SizedBox(height: 6),
          _placeTile('home'),
          const Divider(height: 16, color: GK.tint),
          _placeTile('work'),
          if (places.isNotEmpty) ...[
            const Divider(height: 16, color: GK.tint),
            const Text('내 장소', style: _labelStyle),
            for (final p in places)
              Row(children: [
                Expanded(child: Text(_savedText(p), style: const TextStyle(fontSize: 15, color: GK.ink, height: 1.4))),
                IconButton(
                  tooltip: '${p.name} 삭제',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () async {
                    await AccountService().removePlace(p.id);
                    ref.invalidate(placesProvider);
                  },
                ),
              ]),
          ],
          const SizedBox(height: 16),
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(88, 44)),
                onPressed: _cancel,
                child: const Text('취소')),
            FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
                onPressed: _save,
                icon: const Icon(Icons.check_rounded, size: 20),
                label: const Text('저장')),
          ]),
        ]),
      );

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    jobOtherText.dispose();
    jobOtherFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final places = ref.watch(placesProvider).valueOrNull ?? const <SavedPlace>[];
    return GkCard(
      padding: gkCompactPad,
      child: loading
          ? const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: GkCardTitle(editing ? '내 정보 수정' : '내 정보')),
                if (!editing)
                  Tooltip(
                    message: '내 정보 수정',
                    child: GkPill('수정', icon: Icons.edit_rounded, onTap: () => setState(() => editing = true)),
                  ),
              ]),
              const SizedBox(height: 6),
              if (editing) _editForm(places) else _summary(places),
              const SizedBox(height: 12),
              AddPlaceButton(onTap: () => showPlaceForm(c)),
            ]),
    );
  }
}

/// 이미지 3의 점선 '+ 내 장소 추가하기'
class AddPlaceButton extends StatelessWidget {
  const AddPlaceButton({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext c) => Semantics(
        button: true,
        child: CustomPaint(
          painter: _DashedStadium(),
          child: Material(
            color: Colors.transparent,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: const SizedBox(
                height: 52,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add_rounded, size: 22, color: GK.navy),
                  SizedBox(width: 6),
                  Text('내 장소 추가하기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GK.navy)),
                ]),
              ),
            ),
          ),
        ),
      );
}

class _DashedStadium extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(size.height / 2)));
    final paint = Paint()
      ..color = GK.navy.withValues(alpha: .55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, (d + 5).clamp(0, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Future<void> showPlaceForm(BuildContext c) => showModalBottomSheet<void>(
    context: c, showDragHandle: true, isScrollControlled: true, builder: (_) => const PlaceForm());

/// 내 장소 등록 (주소 → 서버가 좌표 확인)
class PlaceForm extends ConsumerStatefulWidget {
  const PlaceForm({super.key});
  @override
  ConsumerState<PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends ConsumerState<PlaceForm> {
  String type = '기타';
  bool alert = true;
  bool resolving = false;
  final name = TextEditingController();
  final address = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (resolving || address.text.trim().isEmpty) return;
    setState(() => resolving = true);
    try {
      final resolved = await GeocodingService().resolve(address.text);
      final label = name.text.trim().isEmpty ? (type == '기타' ? '내 장소' : type) : name.text.trim();
      await AccountService().addPlace(SavedPlace(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: label,
        type: type,
        address: resolved.address,
        position: resolved.position,
        alert: alert,
      ));
      ref.invalidate(placesProvider);
      if (mounted) Navigator.pop(context);
    } on GeocodingException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext c) => SafeArea(
      child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(c).bottom),
          child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('내 장소 추가', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
            const SizedBox(height: 4),
            const Text('지도에 표시하고, 위험해지면 알려 드려요. AI에게 "집까지"처럼 물을 수도 있어요.',
                style: TextStyle(fontSize: 14, color: GK.muted)),
            const SizedBox(height: 12),
            TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '장소명', hintText: '예: 단골 식당', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: '유형', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: '기타', child: Text('내 장소')),
                  DropdownMenuItem(value: '직장', child: Text('직장')),
                  DropdownMenuItem(value: '집', child: Text('집')),
                ],
                onChanged: (v) => setState(() => type = v!)),
            const SizedBox(height: 10),
            TextField(
                controller: address,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
                decoration: const InputDecoration(
                    labelText: '도로명 주소', hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152', border: OutlineInputBorder())),
            const SizedBox(height: 6),
            const Text('저장하면 서버가 주소로 좌표를 확인해요.', style: TextStyle(fontSize: 14, color: GK.muted)),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: alert,
                title: const Text('이 장소가 위험해지면 알림 받기', style: TextStyle(fontSize: 16)),
                onChanged: (v) => setState(() => alert = v)),
            FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: resolving || address.text.trim().isEmpty ? null : save,
                icon: resolving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_location_alt_outlined),
                label: Text(resolving ? '주소 확인 중…' : '주소 확인 후 추가')),
          ]))));
}

// ------------------------------------------------------------------ 알림 (이미지 2: 작은 아이콘 / 이름·설명 / 스위치)

class ProfileAlertsCard extends ConsumerWidget {
  const ProfileAlertsCard({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final acc = ref.watch(prototypeSafetyProvider);
    final a11y = acc.accessibility;
    Future<void> update(AccessibilitySettings next) => acc.updateAccessibility(next);
    Future<void> support(String key, bool on, AccessibilitySettings next) async {
      await update(next);
      await saveSupportToProfile(key, on);
      ref.read(profileRevision.notifier).state++;   // 내 정보 '접근성 지원' 줄 다시 읽기
    }

    return GkCard(
      padding: gkCompactPad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GkCardTitle('알림'),
        const SizedBox(height: 4),
        GkSwitchRow(
            icon: Icons.volume_up_rounded,
            label: '음성 안내 자동 재생',
            desc: '재난 경고를 소리로 읽어 줘요',
            value: ref.watch(autoVoiceAlerts),
            onChanged: (v) => ref.read(autoVoiceAlerts.notifier).state = v),
        GkSwitchRow(
            icon: Icons.vibration_rounded,
            label: '진동 알림',
            desc: '대피 알림이 오면 반복해서 진동해요',
            value: a11y.strongVibration,
            onChanged: (v) => update(a11y.copyWith(strongVibration: v))),
        GkSwitchRow(
            icon: Icons.flash_on_rounded,
            label: '화면 점멸',
            desc: '대피 알림이 오면 화면이 빨갛게 깜빡여요',
            note: '광과민성이 있으면 꺼 두세요',
            value: a11y.screenFlash,
            onChanged: (v) => update(a11y.copyWith(screenFlash: v))),
        GkSwitchRow(
            icon: Icons.hearing_rounded,
            label: '청각 지원',
            desc: '켜면 진동·화면 점멸·큰 글씨도 함께 켜져요',
            value: a11y.hearingSupport,
            onChanged: (v) => support(
                '청각 지원',
                v,
                v
                    ? a11y.copyWith(hearingSupport: true, strongVibration: true, screenFlash: true, largeText: true)
                    : a11y.copyWith(hearingSupport: false))),
        GkSwitchRow(
            icon: Icons.visibility_rounded,
            label: '시각 지원',
            desc: '켜면 음성 질문 자동 재생도 함께 켜져요',
            value: a11y.visionSupport,
            onChanged: (v) => support(
                '시각 지원',
                v,
                v ? a11y.copyWith(visionSupport: true, voicePrompts: true) : a11y.copyWith(visionSupport: false))),
        // '음성 언어'·'접근성 자세히' 버튼은 위 스위치와 겹쳐 뺐다 (2026-10-09)
        const FcmPushSettingsCard(),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 안전 기능 (이미지 4: 두 개만) + 방재단 로그인 (이미지 5)

/// 경고·대피 확인, 재난 후 지원·복구, 내 가구 등록은 프로필 진입점에서만 뺐다 (화면·주소는 그대로, 2026-10-09)
class SafetyFeaturesCard extends ConsumerStatefulWidget {
  const SafetyFeaturesCard({super.key});
  @override
  ConsumerState<SafetyFeaturesCard> createState() => _SafetyFeaturesCardState();
}

class _SafetyFeaturesCardState extends ConsumerState<SafetyFeaturesCard> {
  bool loginOpen = false;

  @override
  Widget build(BuildContext c) {
    final demo = ref.watch(showDemoProvider);
    final role = '${ref.watch(meProvider).valueOrNull?['role'] ?? ''}';
    // 시연 모드는 방재단 화면이 시연 데이터로 바로 열린다 (실제 역할을 주지 않음). 실측은 방재단·관리자만
    final crew = demo || isPatrolRole(role);
    final sea = _FeatureButton(
        icon: Icons.sailing_rounded, label: '바다 위 대피 경로', onTap: () => c.push('/sea-route'));
    final team = _FeatureButton(
        icon: crew ? Icons.shield_rounded : Icons.badge_rounded,
        label: crew ? (demo ? '방재단 현황 (시연)' : '방재단 현황 · ${roleKo[role] ?? role}') : '방재단 로그인',
        filled: !crew,
        expanded: crew ? null : loginOpen,
        onTap: crew ? () => c.push('/responder') : () => setState(() => loginOpen = !loginOpen));
    return GkCard(
      padding: gkCompactPad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GkCardTitle('안전 기능'),
        const SizedBox(height: 12),
        LayoutBuilder(
            builder: (_, box) => box.maxWidth < 420
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [sea, const SizedBox(height: 10), team])
                : Row(children: [Expanded(child: sea), const SizedBox(width: 10), Expanded(child: team)])),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: !crew && loginOpen
              ? const Padding(padding: EdgeInsets.only(top: 16), child: TeamLoginForm())
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

class _FeatureButton extends StatelessWidget {
  const _FeatureButton({required this.icon, required this.label, required this.onTap, this.filled = false, this.expanded});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  /// 펼치는 버튼이면 펼침 상태 (화면 읽기용)
  final bool? expanded;
  @override
  Widget build(BuildContext c) {
    final fg = filled ? Colors.white : GK.navy;
    return Semantics(
      expanded: expanded,
      child: Material(
        color: filled ? GK.navy : GK.tint,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 22, color: fg),
                const SizedBox(width: 8),
                Flexible(
                    child: Text(label,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg))),
                if (expanded != null) ...[
                  const SizedBox(width: 4),
                  Icon(expanded! ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: fg),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 방재단 전용 코드 로그인 = 서버 초대 코드 인증 (POST /api/v1/user/role → 역할 저장).
/// 성공해야만 방재단 화면으로 간다 — 화면에서 성공 상태를 만들지 않는다. '예: GRP-1234'는 예시일 뿐 형식 검사 없음
class TeamLoginForm extends ConsumerStatefulWidget {
  const TeamLoginForm({super.key});
  @override
  ConsumerState<TeamLoginForm> createState() => _TeamLoginFormState();
}

class _TeamLoginFormState extends ConsumerState<TeamLoginForm> {
  final code = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  static String teamLoginError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      final serverCode = data is Map ? '${data['code'] ?? ''}' : '';
      if (serverCode == 'INVALID_INVITE' || status == 400 || status == 404 || status == 422) {
        return '코드가 맞지 않거나 만료됐어요. 받은 전용 코드를 다시 확인해 주세요.';
      }
      if (status == 401) return '로그인 정보를 확인하지 못했어요. 앱을 다시 연 뒤 시도해 주세요.';
    }
    return liveError(e);
  }

  Future<void> _submit() async {
    if (busy || code.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await ref.read(liveApiProvider).claimRole(code.text);
      final role = '${r['role'] ?? ''}';
      ref.invalidate(meProvider);
      if (!mounted) return;
      if (!isPatrolRole(role)) {
        // 코드는 맞지만 방재단·관리자 역할이 아님 (예: 돌봄 담당)
        setState(() => error = '${roleKo[role] ?? role} 코드예요. 방재단 화면은 방재단·관리자 코드로 열 수 있어요.');
        return;
      }
      code.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('방재단원으로 로그인했어요.')));
      context.push('/responder');
    } catch (e) {
      if (mounted) setState(() => error = teamLoginError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final empty = code.text.trim().isEmpty;
    final field = Semantics(
      label: '방재단 전용 코드',
      textField: true,
      child: TextField(
      controller: code,
      enabled: !busy,
      autofocus: true,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.go,
      onChanged: (_) => setState(() => error = null),
      onSubmitted: (_) => _submit(),
      style: const TextStyle(fontSize: 16),
      decoration: InputDecoration(
        hintText: '예: GRP-1234',
        errorText: error,
        errorMaxLines: 3,
        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(999))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ));
    final button = FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size(96, 52), shape: const StadiumBorder()),
      onPressed: empty || busy ? null : _submit,
      child: busy
          ? const Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              SizedBox(width: 8),
              Text('확인 중…'),
            ])
          : const Text('로그인', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Row(children: [
        GkCircleIcon(Icons.badge_rounded, size: 52, bg: GK.navy, fg: Colors.white, iconSize: 26),
        SizedBox(width: 14),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('방재단 로그인', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: GK.ink)),
          Text('방재단원은 전용 코드로 로그인하세요', style: TextStyle(fontSize: 14, color: GK.muted)),
        ])),
      ]),
      const SizedBox(height: 14),
      const ExcludeSemantics(
          child: Text('방재단 전용 코드', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: GK.ink))),
      const SizedBox(height: 8),
      LayoutBuilder(
          builder: (_, box) => box.maxWidth < 360
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [field, const SizedBox(height: 10), button])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: field),
                  const SizedBox(width: 10),
                  button,
                ])),
    ]);
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'main.dart';
import 'services/account_service.dart';
import 'services/geocoding_service.dart';
import 'services/prototype_safety_store.dart';
import 'ui/gk_theme.dart';
import 'ui/gk_widgets.dart';
import 'ui/widgets.dart' show showDsToast;

/// 장애 유형 ↔ 프로필 키: 시각 지원·청각 지원·지체 지원 ('지원 필요'/'필요 없음').
/// 지체는 예전엔 '보행 능력'에 넣었다 — 보행 능력을 더 묻지 않아(2026-10-09) 따로 저장한다
const disabilityKeys = {
  'see': ('시각', FontAwesomeIcons.eye),
  'hear': ('청각', FontAwesomeIcons.earListen),
  'body': ('지체', FontAwesomeIcons.wheelchairMove),
  'none': ('해당 없음', FontAwesomeIcons.ban),
};

Set<String> disabilitiesOf(Map<String, String> p) {
  final s = <String>{};
  bool need(String? v) => v != null && v.isNotEmpty && v != '필요 없음';
  if (need(p['시각 지원'])) s.add('see');
  if (need(p['청각 지원'])) s.add('hear');
  if (need(p['지체 지원']) || p['transport'] == '휠체어') s.add('body');
  if (s.isEmpty && (p['시각 지원'] == '필요 없음' || p['청각 지원'] == '필요 없음' || p['지체 지원'] == '필요 없음')) {
    s.add('none');
  }
  return s;
}

/// 장애 유형에 맞춰 알림 방식을 켜고 끈다 (2026-10-12 사용자 요청): 시각 → 음성 안내, 청각 → 화면 점멸(·진동).
/// 고른 동안은 사용자 화면 스위치로 끌 수 없고, 유형을 빼면 그 기능도 꺼진다. 처음 화면(내 정보)·사용자 화면 내 정보 저장 때 부른다
Future<void> applyDisabilityAlerts(WidgetRef ref, Set<String> dis) async {
  final store = ref.read(prototypeSafetyProvider);
  final a = store.accessibility;
  final see = dis.contains('see'), hear = dis.contains('hear');
  await store.updateAccessibility(a.copyWith(
    visionSupport: see,
    voicePrompts: see ? true : a.voicePrompts,
    hearingSupport: hear,
    strongVibration: hear ? true : a.strongVibration,
    screenFlash: hear ? true : (a.hearingSupport ? false : a.screenFlash),
  ));
  final voice = ref.read(autoVoiceAlerts.notifier);
  if (see) {
    voice.state = true;
  } else if (a.visionSupport) {
    voice.state = false;
  }
}

List<String> jobsOf(Map<String, String> p) =>
    (p['jobs'] ?? '').split('|').where((x) => x.trim().isNotEmpty).toList();

// ------------------------------------------------------------------ 내 정보 입력 (첫 화면 2단계)

/// 내 정보 입력 폼 (웹 첫 화면 모양: 두 칸 카드, 아래 버튼 줄). [onboarding]이면 '시작하기', 아니면 '저장'
class ProfileForm extends ConsumerStatefulWidget {
  const ProfileForm({super.key, required this.onDone, this.onboarding = false});
  final VoidCallback onDone;
  final bool onboarding;
  @override
  ConsumerState<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<ProfileForm> {
  final age = TextEditingController(), home = TextEditingController(), job = TextEditingController();
  Set<String> dis = {};
  String transport = '';
  Map<String, String> loaded = {};
  bool busy = false, ready = false;

  static const jobChips = ['어업 종사자·뱃사람', '자영업자', '농업 종사자', '축산업 종사자', '양식업 종사자·수산물 양식'];

  @override
  void initState() {
    super.initState();
    AccountService().optionalProfile().then((p) {
      if (!mounted) return;
      setState(() {
        loaded = p;
        age.text = p['age'] ?? '';
        home.text = p['homeAddress'] ?? '';
        job.text = jobsOf(p).join(', ');
        dis = disabilitiesOf(p);
        transport = p['transport'] ?? '';
        ready = true;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [age, home, job]) {
      c.dispose();
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

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      final p = <String, String>{...await AccountService().optionalProfile()};
      p['age'] = age.text.replaceAll(RegExp(r'[^0-9]'), '');
      p['transport'] = transport;
      p['시각 지원'] = dis.contains('see') ? '지원 필요' : (dis.isEmpty ? (p['시각 지원'] ?? '') : '필요 없음');
      p['청각 지원'] = dis.contains('hear') ? '지원 필요' : (dis.isEmpty ? (p['청각 지원'] ?? '') : '필요 없음');
      p['지체 지원'] = dis.contains('body') ? '지원 필요' : (dis.isEmpty ? (p['지체 지원'] ?? '') : '필요 없음');
      p['jobs'] = job.text.split(RegExp(r'[,·|]')).map((x) => x.trim()).where((x) => x.isNotEmpty).join('|');
      Future<void> geocode(String key, String text, String label) async {
        final t = text.trim();
        if (t.isEmpty) {
          for (final f in ['Name', 'Address', 'Lat', 'Lon']) {
            p['$key$f'] = '';
          }
          return;
        }
        if (t == loaded['${key}Address']) return;
        final r = await GeocodingService().resolve(t);
        p['${key}Name'] = (p['${key}Name'] ?? '').isEmpty ? label : p['${key}Name']!;
        p['${key}Address'] = r.address;
        p['${key}Lat'] = '${r.position.latitude}';
        p['${key}Lon'] = '${r.position.longitude}';
      }

      await geocode('home', home.text, '집');
      await AccountService().saveOptionalProfile(p);
      await applyDisabilityAlerts(ref, disabilitiesOf(p));
      if (dis.contains('see')) {
        // 대피 경보 음성 확인(evac_voice_check.dart)은 잠금 화면에서 바로 마이크를 연다 — 권한 창을 그때 띄울 수 없으니 지금 묻는다
        final rec = AudioRecorder();
        unawaited(rec.hasPermission().catchError((_) => false).whenComplete(rec.dispose));
      }
      ref.read(profileRevision.notifier).state++;
      if (!mounted) return;
      showDsToast(context, widget.onboarding ? '내 정보를 저장했어요' : '내 정보를 저장했어요');
      widget.onDone();
    } on GeocodingException catch (e) {
      if (mounted) showDsToast(context, e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _webLabel(String t, {String? sub, bool first = false}) => Padding(
        padding: EdgeInsets.only(top: first ? 0 : 22, bottom: 10),
        child: Text.rich(
            TextSpan(children: [
              TextSpan(text: t, style: const TextStyle(fontWeight: FontWeight.w800, color: GK.ink)),
              if (sub != null) TextSpan(text: '  $sub', style: const TextStyle(fontWeight: FontWeight.w500, color: GK.muted)),
            ]),
            style: const TextStyle(fontSize: 17)),
      );

  Widget _webChoice(String label, IconData icon, bool on, VoidCallback onTap) => Semantics(
        selected: on,
        button: true,
        child: Material(
          color: on ? GK.navy : Colors.white,
          shape: const StadiumBorder(side: BorderSide(color: GK.navy, width: 1.5)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 20, color: on ? Colors.white : GK.navy),
                const SizedBox(width: 8),
                Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on ? Colors.white : GK.navy)),
              ]),
            ),
          ),
        ),
      );

  Widget _webField(TextEditingController c, String hint, {TextInputType? type}) =>
      TextField(controller: c, keyboardType: type, decoration: InputDecoration(hintText: hint));

  Widget _webBuild() {
    const disIcons = {
      'see': Icons.visibility_rounded,
      'hear': Icons.hearing_rounded,
      'body': Icons.accessible_rounded,
      'none': Icons.block_rounded,
    };
    final aboutCard = GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GkCardHeader('나에 대해', icon: Icons.person_rounded),
        const SizedBox(height: 22),
        _webLabel('나이', sub: '(선택)', first: true),
        Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: 200, child: _webField(age, '예: 72', type: TextInputType.number))),
        _webLabel('장애 유형', sub: '(선택 · 중복 가능)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in disabilityKeys.entries)
            _webChoice(e.value.$1, disIcons[e.key]!, dis.contains(e.key), () => _toggleDis(e.key)),
        ]),
        _webLabel('이동 수단', sub: '(선택)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in const [
            ('도보', Icons.directions_walk_rounded),
            ('자동차', Icons.directions_car_rounded)
          ])
            _webChoice(t.$1, t.$2, transport == t.$1, () => setState(() => transport = transport == t.$1 ? '' : t.$1)),
        ]),
      ]),
    );
    final placeCard = GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GkCardHeader('주소와 장소', icon: Icons.home_rounded),
        const SizedBox(height: 22),
        _webLabel('집 주소', sub: '(선택)', first: true),
        _webField(home, '예: 구룡포읍 호미로 152'),
        _webLabel('직업', sub: '(선택)'),
        _webField(job, '예: 어업'),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final j in jobChips)
            ActionChip(
                label: Text(j),
                avatar: const Icon(Icons.add_rounded, size: 18),
                onPressed: () {
                  final cur = job.text.split(RegExp(r'[,·|]')).map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
                  if (!cur.contains(j)) setState(() => job.text = [...cur, j].join(', '));
                }),
        ]),
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GkColumns(minWidth: 440, equalHeight: false, children: [aboutCard, placeCard]),
      const SizedBox(height: 28),
      Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 12, children: [
        if (widget.onboarding)
          TextButton(onPressed: busy ? null : widget.onDone, child: const Text('나중에 입력할게요')),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              minimumSize: const Size(180, 56), textStyle: const TextStyle(fontFamily: GK.font, fontSize: 19, fontWeight: FontWeight.w800)),
          onPressed: busy ? null : _save,
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Text(busy ? '저장 중…' : (widget.onboarding ? '시작하기' : '저장')),
        ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    return _webBuild();
  }
}

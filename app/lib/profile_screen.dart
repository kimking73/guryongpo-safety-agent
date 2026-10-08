import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';

import 'app_shell.dart';
import 'live_screens.dart';
import 'login_screen.dart';
import 'main.dart';
import 'models/domain_models.dart';
import 'profile_refresh.dart';
import 'services/account_service.dart';
import 'services/app_config.dart';
import 'services/auth_service.dart';
import 'services/demo_mode.dart';
import 'services/fcm_notification_service.dart';
import 'services/geocoding_service.dart';
import 'services/live_api.dart' show liveError;
import 'services/prototype_safety_store.dart';
import 'ui/tokens.dart';
import 'ui/widgets.dart';

/// 사용자 탭 (디자인: 내 정보 · 알림 · 시연 모드 · 이메일 로그인 · 방재단 로그인).
/// 디자인에 없던 기존 화면(선제 경고·태풍·지원·가구 등록·해상 경로·접근성 세부)은 '더 보기'로 옮겼다

/// 프로필(optional_profile) — 화면 밖에서 바뀌면(AI 기억 등) profileRevision으로 다시 읽는다
final profileMapProvider = FutureProvider<Map<String, String>>((ref) {
  ref.watch(profileRevision);
  return AccountService().optionalProfile();
});

/// 장애 유형 ↔ 기존 프로필 키 (AI도 같은 키를 읽는다)
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
  if (p['보행 능력'] == '보행 어려움' || p['transport'] == '휠체어') s.add('body');
  if (s.isEmpty && (p['시각 지원'] == '필요 없음' || p['청각 지원'] == '필요 없음')) s.add('none');
  return s;
}

List<String> jobsOf(Map<String, String> p) =>
    (p['jobs'] ?? '').split('|').where((x) => x.trim().isNotEmpty).toList();

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(c).width >= wideBreakpoint;
    return WebWidth(enabled: wide, maxWidth: 820, child: ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, wide ? 40 : 120), children: [
      const ScreenTitle('사용자'),
      const _MyInfoCard(),
      const SizedBox(height: 14),
      const ServerProfileRefresh(),
      const SizedBox(height: 14),
      const _AlertSettingsCard(),
      const SizedBox(height: 14),
      const _DemoCard(),
      const SizedBox(height: 14),
      const _AccountCard(),
      const SizedBox(height: 14),
      const _TeamLoginCard(),
      const SizedBox(height: 14),
      const _MoreCard(),
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text('앱 버전 ${AppConfig.build}',
              textAlign: TextAlign.center, style: dsText(11, color: Ds.faint))),
    ]));
  }
}

// ------------------------------------------------------------------ 내 정보

class _MyInfoCard extends ConsumerStatefulWidget {
  const _MyInfoCard();
  @override
  ConsumerState<_MyInfoCard> createState() => _MyInfoCardState();
}

class _MyInfoCardState extends ConsumerState<_MyInfoCard> {
  bool adding = false, saving = false;
  final name = TextEditingController(), addr = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    addr.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final n = name.text.trim(), a = addr.text.trim();
    if (n.isEmpty || a.isEmpty) {
      showDsToast(context, '장소 이름과 주소를 모두 입력해 주세요');
      return;
    }
    setState(() => saving = true);
    try {
      final r = await GeocodingService().resolve(a);
      await AccountService().addPlace(SavedPlace(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: n,
          type: '기타',
          address: r.address,
          position: r.position));
      ref.invalidate(placesProvider);
      name.clear();
      addr.clear();
      if (mounted) {
        setState(() => adding = false);
        showDsToast(context, '내 장소를 추가했어요');
      }
    } on GeocodingException catch (e) {
      if (mounted) showDsToast(context, e.message);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileMapProvider).valueOrNull ?? const <String, String>{};
    final places = ref.watch(placesProvider).valueOrNull ?? const <SavedPlace>[];
    final dis = disabilitiesOf(p);
    final rows = <(FaIconData, String, String, String?, VoidCallback?)>[
      (FontAwesomeIcons.cakeCandles, '나이', (p['age'] ?? '').isEmpty ? '입력 안 함' : '${p['age']}세', null, null),
      (
        FontAwesomeIcons.wheelchairMove,
        '장애',
        dis.isEmpty ? '선택 안 함' : dis.map((d) => disabilityKeys[d]!.$1).join(' · '),
        null,
        null
      ),
      (FontAwesomeIcons.personWalking, '이동 수단', (p['transport'] ?? '').isEmpty ? '도보 (기본)' : p['transport']!, p['보행 능력'], null),
      (FontAwesomeIcons.briefcase, '직업', jobsOf(p).isEmpty ? '입력 안 함' : jobsOf(p).join(' · '), null, null),
      (
        FontAwesomeIcons.house,
        '집',
        (p['homeAddress'] ?? '').isEmpty ? '입력 안 함' : ((p['homeName'] ?? '').isEmpty ? '집' : p['homeName']!),
        (p['homeAddress'] ?? '').isEmpty ? null : p['homeAddress'],
        null
      ),
      if ((p['workAddress'] ?? '').isNotEmpty)
        (FontAwesomeIcons.building, '직장', (p['workName'] ?? '').isEmpty ? '직장' : p['workName']!, p['workAddress'], null),
      for (final pl in places)
        (
          FontAwesomeIcons.bookmark,
          '내 장소',
          pl.name,
          pl.address.isEmpty ? null : pl.address,
          () async {
            await AccountService().removePlace(pl.id);
            ref.invalidate(placesProvider);
            if (context.mounted) showDsToast(context, '${pl.name}을(를) 지웠어요');
          }
        ),
    ];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CardTitle('내 정보',
            trailing: PillChip('수정',
                icon: FontAwesomeIcons.pen, height: 36, bg: Ds.soft, onTap: () => context.push('/profile/edit'))),
        const SizedBox(height: 4),
        for (final (i, r) in rows.indexed)
          Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(border: i == 0 ? null : const Border(top: BorderSide(color: Ds.divider))),
            child: Row(children: [
              SizedBox(width: 18, child: Center(child: FaIcon(r.$1, size: 14, color: Ds.navy))),
              const SizedBox(width: 10),
              SizedBox(width: 64, child: Text(r.$2, style: dsText(14, color: Ds.muted))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.$3, maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(15, weight: FontWeight.w800)),
                  if (r.$4 != null && r.$4!.isNotEmpty)
                    Text(r.$4!, maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(12, color: Ds.muted)),
                ]),
              ),
              if (r.$5 != null)
                IconButton(
                    tooltip: '지우기',
                    visualDensity: VisualDensity.compact,
                    onPressed: r.$5,
                    icon: const FaIcon(FontAwesomeIcons.xmark, size: 14, color: Ds.muted)),
            ]),
          ),
        if (adding)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Ds.bg, borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DsField(label: '장소 이름', controller: name, hint: '예: 구룡포 시장', fill: Colors.white),
              const SizedBox(height: 8),
              DsField(
                  label: '주소',
                  controller: addr,
                  hint: '예: 구룡포읍 구룡포길 1',
                  fill: Colors.white,
                  onSubmitted: (_) => _add()),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: PillButton('취소',
                        height: 50, fontSize: 16, bg: Colors.white, fg: Ds.navy, onPressed: () => setState(() => adding = false))),
                const SizedBox(width: 8),
                Expanded(
                    flex: 2,
                    child: PillButton(saving ? '주소 확인 중…' : '추가', height: 50, fontSize: 16, onPressed: saving ? null : _add)),
              ]),
            ]),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: Colors.white,
              shape: StadiumBorder(side: BorderSide(color: Ds.navy.withValues(alpha: .8), width: 1.5)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => setState(() => adding = true),
                child: SizedBox(
                  height: 44,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const FaIcon(FontAwesomeIcons.plus, size: 14, color: Ds.navy),
                    const SizedBox(width: 6),
                    Text('내 장소 추가하기', style: dsText(15, weight: FontWeight.w800, color: Ds.navy)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 알림 (접근성 · 푸시 · 음성)

class _AlertSettingsCard extends ConsumerStatefulWidget {
  const _AlertSettingsCard();
  @override
  ConsumerState<_AlertSettingsCard> createState() => _AlertSettingsCardState();
}

class _AlertSettingsCardState extends ConsumerState<_AlertSettingsCard> {
  bool push = false, pushBusy = true;

  @override
  void initState() {
    super.initState();
    FcmNotificationService.instance.isEnabled.then((v) {
      if (mounted) setState(() { push = v; pushBusy = false; });
    });
  }

  Future<void> _togglePush(bool v) async {
    setState(() => pushBusy = true);
    if (v) {
      final st = await FcmNotificationService.instance.enablePush();
      final ok = st.name == 'authorized' || st.name == 'provisional';
      if (!mounted) return;
      setState(() { push = ok; pushBusy = false; });
      if (!ok) showDsToast(context, '알림 권한을 허용하지 않아 앱을 열 때만 경고를 확인해요');
      return;
    }
    await FcmNotificationService.instance.disablePush();
    if (mounted) setState(() { push = false; pushBusy = false; });
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(prototypeSafetyProvider);
    final a = store.accessibility;
    void set(AccessibilitySettings s) => store.updateAccessibility(s);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const CardTitle('알림'),
        const SizedBox(height: 4),
        SettingRow(
          icon: FontAwesomeIcons.volumeHigh,
          title: '음성 안내 자동 재생',
          subtitle: '시각 장애 선택 시 자동으로 켜져요',
          trailing: NavySwitch(
              label: '음성 안내 자동 재생',
              value: ref.watch(autoVoiceAlerts) || (a.visionSupport && a.voicePrompts),
              onChanged: (v) {
                ref.read(autoVoiceAlerts.notifier).state = v;
                set(a.copyWith(voicePrompts: v));
              }),
        ),
        SettingRow(
          topBorder: true,
          icon: FontAwesomeIcons.mobileScreenButton,
          title: '진동 알림',
          subtitle: '청각 장애 선택 시 자동으로 켜져요',
          trailing: NavySwitch(
              label: '진동 알림', value: a.strongVibration, onChanged: (v) => set(a.copyWith(strongVibration: v))),
        ),
        SettingRow(
          topBorder: true,
          icon: FontAwesomeIcons.bolt,
          title: '화면 점멸',
          subtitle: '청각 장애 선택 시 자동으로 켜져요',
          trailing: NavySwitch(label: '화면 점멸', value: a.screenFlash, onChanged: (v) => set(a.copyWith(screenFlash: v))),
        ),
        SettingRow(
          topBorder: true,
          icon: FontAwesomeIcons.solidBell,
          title: '재난 푸시 알림',
          subtitle: AppConfig.isRemote ? '켜면 앱을 닫아도 경고를 받아요' : '서버에 연결한 앱에서 쓸 수 있어요',
          trailing: NavySwitch(
              label: '재난 푸시 알림', value: push, onChanged: pushBusy || !AppConfig.isRemote ? null : _togglePush),
        ),
        SettingRow(
          topBorder: true,
          icon: FontAwesomeIcons.language,
          title: '음성 언어',
          trailing: SizedBox(
            width: 150,
            child: SegmentedPill<String>(
              height: 32,
              items: const [('한국어', '한국어', null), ('English', 'English', null)],
              value: ref.watch(voiceLanguage),
              onChanged: (v) => ref.read(voiceLanguage.notifier).state = v,
            ),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 시연 모드

class _DemoCard extends ConsumerWidget {
  const _DemoCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(showDemoProvider);
    final store = ref.watch(prototypeSafetyProvider);
    final team = store.hasResponderAccess;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const CardTitle('시연 모드'),
        const SizedBox(height: 4),
        if (AppConfig.isRemote)
          SettingRow(
            icon: FontAwesomeIcons.flask,
            title: '시연 모드',
            subtitle: demo ? '서버 시연 데이터로 보여 주고 있어요 · 실제 경고는 보내지 않아요' : '켜면 실제 센서 위치에 시연용 값을 넣어 보여 줘요',
            highlight: demo,
            trailing: NavySwitch(
                label: '시연 모드', value: demo, onChanged: (v) => ref.read(demoModeProvider.notifier).set(v)),
          ),
        SettingRow(
          topBorder: AppConfig.isRemote,
          icon: FontAwesomeIcons.rotateLeft,
          title: '처음 화면 다시 보기',
          subtitle: '필수 동의 · 로그인 · 내 정보 입력 화면부터 다시 시작해요 (입력한 정보는 그대로)',
          trailing: PillChip('보기', height: 36, bg: Ds.soft, onTap: () async {
            await Onboarding.reset();
            if (context.mounted) context.go('/login');
          }),
        ),
        if (demo) ...[
          SettingRow(
            topBorder: true,
            icon: FontAwesomeIcons.userShield,
            title: '방재단 대피현황',
            subtitle: team ? '방재단원 화면을 보고 있어요' : '코드 없이 방재단원 화면을 시연해요',
            trailing: NavySwitch(
                label: '방재단 대피현황',
                value: team,
                onChanged: (v) async {
                  if (v) {
                    await store.claimDemoRole('DEMO-RESPONDER');
                    if (context.mounted) context.go('/team');
                  } else {
                    await store.dropDemoRole();
                  }
                }),
          ),
          SettingRow(
            topBorder: true,
            icon: FontAwesomeIcons.clockRotateLeft,
            title: '대피 경보 시연',
            subtitle: '누르면 실제와 같은 대피 확인 창이 떠요 (기기에만 기록)',
            trailing: PillChip('열기', height: 36, bg: Ds.soft, onTap: () => showEvacuationAlertDemo(context, ref)),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ 계정 (이메일 로그인)

class _AccountCard extends ConsumerStatefulWidget {
  const _AccountCard();
  @override
  ConsumerState<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<_AccountCard> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authService);
    final a = AuthService.ready ? (ref.watch(accountProvider).valueOrNull ?? auth.account) : null;
    final signedIn = a != null && !a.isAnonymous;
    return AppCard(
      radius: Ds.rCardLg,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(children: [
        const IconCircle(FontAwesomeIcons.solidEnvelope, size: 48, iconSize: 19),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(signedIn ? (a.email ?? '로그인했어요') : '이메일로 로그인 · 가입',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: dsText(17, weight: FontWeight.w800)),
            Text(
                !AuthService.ready
                    ? '예시 데이터 모드에서는 로그인을 쓰지 않아요'
                    : signedIn
                        ? '${a.providerLabel} 계정 · 다른 기기에서도 내 정보 사용'
                        : '다른 기기에서도 내 정보 사용',
                style: dsText(14, color: Ds.muted, height: 1.4)),
          ]),
        ),
        if (AuthService.ready)
          PillButton(signedIn ? '로그아웃' : '로그인',
              expand: false,
              height: 48,
              fontSize: 16,
              bg: signedIn ? Ds.bg : Ds.navy,
              fg: signedIn ? Ds.navy : Colors.white,
              onPressed: busy
                  ? null
                  : signedIn
                      ? () async {
                          setState(() => busy = true);
                          try {
                            await auth.signOut();
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        }
                      : () => context.push('/login')),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 방재단 로그인 (전용 코드)

class _TeamLoginCard extends ConsumerStatefulWidget {
  const _TeamLoginCard();
  @override
  ConsumerState<_TeamLoginCard> createState() => _TeamLoginCardState();
}

class _TeamLoginCardState extends ConsumerState<_TeamLoginCard> {
  final code = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final c = code.text.trim();
    if (c.length < 4) {
      setState(() => error = '코드를 4자리 이상 입력해 주세요');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (ref.read(showDemoProvider)) {
        final ok = await ref.read(prototypeSafetyProvider).claimDemoRole(c);
        if (!ok) throw StateError('시연 코드가 맞지 않아요 (예: DEMO-RESPONDER)');
      } else {
        await ref.read(liveApiProvider).claimRole(c);
        ref.invalidate(meProvider);
        await ref.read(meProvider.future);
      }
      code.clear();
      if (!mounted) return;
      if (ref.read(isResponderProvider)) {
        showDsToast(context, '방재단원으로 로그인했어요');
        context.go('/team');
      } else {
        showDsToast(context, '역할을 받았어요. 방재단 현황은 방재단·관리자만 볼 수 있어요');
      }
    } catch (e) {
      if (mounted) setState(() => error = e is StateError ? e.message : liveError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = ref.watch(isResponderProvider);
    final demo = ref.watch(showDemoProvider);
    return AppCard(
      radius: Ds.rCardLg,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconCircle(FontAwesomeIcons.idBadge, size: 48, iconSize: 19, bg: Ds.navy, fg: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('방재단 로그인', style: dsText(17, weight: FontWeight.w800)),
              Text(ok ? '방재단원으로 로그인했어요' : '방재단원은 전용 코드로 로그인하세요',
                  style: dsText(14, color: Ds.muted, height: 1.4)),
            ]),
          ),
          if (ok && demo)
            PillChip('로그아웃',
                icon: FontAwesomeIcons.rightFromBracket,
                height: 40,
                bg: Ds.bg,
                onTap: () async {
                  await ref.read(prototypeSafetyProvider).dropDemoRole();
                  if (context.mounted) showDsToast(context, '방재단에서 로그아웃했어요');
                }),
        ]),
        if (!ok) ...[
          const SizedBox(height: 12),
          Text('방재단 전용 코드', style: dsText(14, weight: FontWeight.w800, color: Ds.sub)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: DsField(
                controller: code,
                hint: demo ? '예: DEMO-RESPONDER' : '예: GRP-1234',
                fill: Colors.white,
                error: error != null,
                maxLength: 24,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() => error = null),
                onSubmitted: (_) => _login(),
              ),
            ),
            const SizedBox(width: 8),
            PillButton(busy ? '확인 중' : '로그인',
                expand: false,
                height: 52,
                fontSize: 16,
                onPressed: busy || code.text.trim().length < 4 ? null : _login),
          ]),
          if (error != null) ErrorLine(error!),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ 더 보기 (탭에서 옮긴 화면)

class _MoreCard extends ConsumerWidget {
  const _MoreCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(showDemoProvider);
    final rows = <(FaIconData, String, String, String)>[
      (FontAwesomeIcons.triangleExclamation, '선제 경고·알림', '내 위치·등록 장소 맞춤 경고, 재난문자', '/alerts-hub'),
      (FontAwesomeIcons.hurricane, '태풍 정보', '태풍 경로와 구룡포 영향', '/typhoon'),
      (FontAwesomeIcons.handHoldingHeart, '지원 및 복구', '직업에 맞는 보험·피해 신고·복구 지원', '/support'),
      (FontAwesomeIcons.personCircleCheck, '경고·대피 확인', '받은 경고와 내 대피 응답', '/alerts'),
      (FontAwesomeIcons.peopleRoof, '내 가구 등록', '도움이 필요한 가족을 방재단에 알리기', '/household'),
      (FontAwesomeIcons.ship, '바다 위 대피 경로', '배 위에서 가까운 항구로', '/sea-route'),
      (FontAwesomeIcons.universalAccess, '접근성 세부 설정', '큰 글씨·청각·시각 지원', '/accessibility'),
      if (demo) (FontAwesomeIcons.personRunning, '대피 확인 시연', '대피 경보 화면 흐름 시연', '/evacuation'),
      if (demo) (FontAwesomeIcons.microphoneLines, '음성 대피 확인 시연', '말로 대피 상태 알리기', '/evacuation-voice'),
    ];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const CardTitle('더 보기'),
        const SizedBox(height: 4),
        for (final (i, r) in rows.indexed)
          SettingRow(
            topBorder: i > 0,
            icon: r.$1,
            title: r.$2,
            subtitle: r.$3,
            onTap: () => context.push(r.$4),
            trailing: const FaIcon(FontAwesomeIcons.chevronRight, size: 13, color: Ds.muted),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 내 정보 입력·수정 (온보딩 2단계와 같은 모양)

/// 내 정보 입력 폼. [onboarding]이면 '시작하기', 아니면 '저장'
class ProfileForm extends ConsumerStatefulWidget {
  const ProfileForm({super.key, required this.onDone, this.onboarding = false});
  final VoidCallback onDone;
  final bool onboarding;
  @override
  ConsumerState<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<ProfileForm> {
  final age = TextEditingController(),
      home = TextEditingController(),
      work = TextEditingController(),
      placeName = TextEditingController(),
      placeAddr = TextEditingController(),
      job = TextEditingController();
  Set<String> dis = {};
  String transport = '';
  String walking = '', dependents = '';
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
        work.text = p['workAddress'] ?? '';
        job.text = jobsOf(p).join(', ');
        dis = disabilitiesOf(p);
        transport = p['transport'] ?? '';
        walking = p['보행 능력'] ?? '';
        dependents = p['보호가 필요한 동반자 여부'] ?? '';
        ready = true;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [age, home, work, placeName, placeAddr, job]) {
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
      if (dis.contains('body')) {
        p['보행 능력'] = '보행 어려움';
      } else {
        p['보행 능력'] = walking == '보행 어려움' && dis.isNotEmpty ? '' : walking;
      }
      p['보호가 필요한 동반자 여부'] = dependents;
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
      await geocode('work', work.text, '직장');
      await AccountService().saveOptionalProfile(p);
      if (placeName.text.trim().isNotEmpty && placeAddr.text.trim().isNotEmpty) {
        final r = await GeocodingService().resolve(placeAddr.text.trim());
        await AccountService().addPlace(SavedPlace(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: placeName.text.trim(),
            type: '기타',
            address: r.address,
            position: r.position));
        ref.invalidate(placesProvider);
      }
      // 장애 유형에 맞춰 알림 방식 자동 설정 (디자인: 시각 → 음성, 청각 → 진동·점멸)
      final store = ref.read(prototypeSafetyProvider);
      final a = store.accessibility;
      await store.updateAccessibility(a.copyWith(
        visionSupport: dis.contains('see'),
        voicePrompts: dis.contains('see') ? true : a.voicePrompts,
        hearingSupport: dis.contains('hear'),
        strongVibration: dis.contains('hear') ? true : a.strongVibration,
        screenFlash: dis.contains('hear') ? true : a.screenFlash,
      ));
      if (dis.contains('see')) ref.read(autoVoiceAlerts.notifier).state = true;
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

  Widget _label(String t, {String? sub, FaIconData? icon}) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Row(children: [
          if (icon != null) ...[FaIcon(icon, size: 15, color: Ds.navy), const SizedBox(width: 8)],
          Text(t, style: dsText(17, weight: FontWeight.w800)),
          if (sub != null) ...[const SizedBox(width: 6), Text(sub, style: dsText(17, weight: FontWeight.w500, color: Ds.muted))],
        ]),
      );

  Widget _choice(String label, FaIconData icon, bool on, VoidCallback onTap) => Material(
        color: on ? Ds.navy : Colors.white,
        shape: const StadiumBorder(side: BorderSide(color: Ds.navy, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              FaIcon(icon, size: 16, color: on ? Colors.white : Ds.navy),
              const SizedBox(width: 8),
              Text(label, style: dsText(17, weight: FontWeight.w700, color: on ? Colors.white : Ds.navy)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!ready) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    final field = (TextEditingController c, String hint, {TextInputType? type}) => TextField(
          controller: c,
          keyboardType: type,
          style: dsText(18),
          decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _label('나이', sub: '(선택)'),
      Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: .6, child: field(age, '예: 72', type: TextInputType.number))),
      _label('장애 유형', sub: '(선택 · 중복 가능)'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in disabilityKeys.entries) _choice(e.value.$1, e.value.$2, dis.contains(e.key), () => _toggleDis(e.key)),
      ]),
      _label('이동 수단', sub: '(선택)'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in const [('도보', FontAwesomeIcons.personWalking), ('휠체어', FontAwesomeIcons.wheelchair), ('자동차', FontAwesomeIcons.car)])
          _choice(t.$1, t.$2, transport == t.$1, () => setState(() => transport = transport == t.$1 ? '' : t.$1)),
      ]),
      _label('집 주소', icon: FontAwesomeIcons.house),
      field(home, '예: 구룡포읍 호미로 152'),
      _label('내 장소', sub: '(선택)', icon: FontAwesomeIcons.bookmark),
      field(placeName, '장소 이름 · 예: 구룡포 시장'),
      const SizedBox(height: 8),
      field(placeAddr, '주소 · 예: 구룡포읍 구룡포길 1'),
      _label('직업', sub: '(선택)', icon: FontAwesomeIcons.briefcase),
      field(job, '예: 어업'),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final j in jobChips)
          PillChip(j, height: 34, fontSize: 13, bg: Ds.soft, onTap: () {
            final cur = job.text.split(RegExp(r'[,·|]')).map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
            if (!cur.contains(j)) job.text = [...cur, j].join(', ');
          }),
      ]),
      if (!widget.onboarding) ...[
        _label('직장 주소', sub: '(선택)', icon: FontAwesomeIcons.building),
        field(work, '예: 구룡포읍 구룡포항'),
        _label('보행 능력', sub: '(선택)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final w in const ['보행 가능', '보행 불편', '보행 어려움'])
            _choice(w, FontAwesomeIcons.personWalking, walking == w, () => setState(() => walking = walking == w ? '' : w)),
        ]),
        _label('보호가 필요한 동반자', sub: '(선택)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in const ['예', '아니요'])
            _choice(d, FontAwesomeIcons.peopleGroup, dependents == d, () => setState(() => dependents = dependents == d ? '' : d)),
        ]),
      ],
      const SizedBox(height: 28),
      PillButton(busy ? '저장 중…' : (widget.onboarding ? '시작하기' : '저장'),
          height: 60, fontSize: 20, onPressed: busy ? null : _save),
      if (widget.onboarding)
        TextButton(onPressed: busy ? null : widget.onDone, child: const Text('나중에 입력할게요')),
    ]);
  }
}

/// 사용자 탭 '수정' → 내 정보 수정 (탭 밖 화면)
class ProfileEditScreen extends StatelessWidget {
  const ProfileEditScreen({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          Text('나에게 맞는 대피 안내를 위해 알려주세요. 모두 선택이에요.', style: dsText(17, color: Ds.muted, height: 1.5)),
          ProfileForm(onDone: () => context.canPop() ? context.pop() : context.go('/profile')),
          const SizedBox(height: 24),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('더 자세한 정보', style: dsText(17, weight: FontWeight.w800)),
            subtitle: Text('혈액형 · 비상 연락처 · 시각·청각 지원 정도', style: dsText(13, color: Ds.muted)),
            children: const [OptionalDetailsCard()],
          ),
        ],
      );
}

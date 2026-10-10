import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';

import 'app_shell.dart' show WebWidth;
import 'profile_screen.dart';
import '../login_screen.dart' show authService, accountProvider;
import '../main.dart' show useMobileUi;
import '../services/auth_service.dart';
import '../ui/gk_theme.dart';
import '../ui/gk_widgets.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';


/// 첫 화면 (디자인 온보딩). 1/2 = 필수 동의 + 로그인(/login), 2/2 = 내 정보(/setup, 모두 선택·건너뛰기 가능).
/// 앱을 열 때마다(웹은 새로 열기·새로고침마다) 처음부터 보여 준다 — 2026-10-10 사용자 결정.
/// 그래서 동의·완료 여부를 기기에 저장하지 않고 메모리에만 둔다. 로그인·입력한 내 정보는 그대로 남아 미리 채워진다.
/// 기기에 저장해 '한 번 동의하면 건너뛰기'로 되돌리지 말 것 (test/design_ui_test.dart 가 지킴)
class Onboarding {
  Onboarding._();
  static bool consented = false;
  static bool done = false;

  static Future<void> setConsented() async => consented = true;

  static Future<void> setDone() async => done = true;

  /// 처음 화면(동의·로그인·내 정보)을 다시 보기 — 시연용. 입력한 내 정보·로그인은 그대로 둔다
  static Future<void> reset() async {
    consented = false;
    done = false;
  }
}

/// 웹(브라우저)용 첫 화면 틀 (2026-10-09 사용자 요청: 휴대폰처럼 좁은 한 줄 말고 웹 화면처럼).
/// 위 흰 머리띠(방패·이름·단계 표시) + 가운데 최대 1080px 본문. 본문은 넓으면 두 칸 카드
class WebOnboardingFrame extends StatelessWidget {
  const WebOnboardingFrame({super.key, required this.step, required this.title, required this.subtitle, required this.body});
  final int step;
  final String title, subtitle;
  final Widget body;

  static const maxWidth = 1080.0;

  Widget _stepDot(int n, String label) {
    final done = n < step, now = n == step;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? GK.green : (now ? GK.navy : Colors.white),
          border: Border.all(color: done ? GK.green : (now ? GK.navy : GK.line), width: 2),
        ),
        child: done
            ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
            : Text('$n',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: now ? Colors.white : GK.grey)),
      ),
      const SizedBox(width: 8),
      Text(label,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: now ? GK.ink : (done ? GK.muted : GK.grey))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final narrow = w < 640;
    final side = narrow ? 16.0 : (w < 1100 ? 28.0 : 40.0);
    Widget centered(Widget child) =>
        Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: maxWidth), child: child));
    return Scaffold(
      backgroundColor: GK.bg,
      body: SafeArea(
        child: Column(children: [
          Container(
            color: Colors.white,
            padding: EdgeInsets.symmetric(horizontal: side, vertical: 14),
            child: centered(Row(children: [
              const GkCircleIcon(Icons.shield_rounded, size: 44, bg: GK.navy, fg: Colors.white),
              const SizedBox(width: 12),
              const Text('구룡포 안전 비서', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: GK.ink)),
              const Spacer(),
              if (narrow)
                Text('$step / 2', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GK.muted))
              else ...[
                _stepDot(1, '동의·로그인'),
                Container(width: 40, height: 2, margin: const EdgeInsets.symmetric(horizontal: 12), color: GK.line),
                _stepDot(2, '내 정보'),
              ],
            ])),
          ),
          const Divider(height: 1, color: GK.line),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(side, narrow ? 24 : 40, side, 56),
              child: centered(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(title,
                    style: TextStyle(
                        fontSize: narrow ? 30 : 40, fontWeight: FontWeight.w800, color: GK.ink, letterSpacing: -0.8, height: 1.2)),
                const SizedBox(height: 8),
                Text(subtitle, style: const TextStyle(fontSize: 18, color: GK.muted, height: 1.5)),
                SizedBox(height: narrow ? 20 : 28),
                body,
              ])),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 웹 첫 화면의 '필수' 표시
class WebRequiredTag extends StatelessWidget {
  const WebRequiredTag({super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: GK.redTint, borderRadius: BorderRadius.circular(99)),
        child: const Text('필수', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: GK.redDark)),
      );
}

/// 남색 바탕 위 흰 시트 (온보딩 화면 틀)
class _ObSheet extends StatelessWidget {
  const _ObSheet({required this.step, required this.children, this.onBack});
  final int step;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          bottom: false,
          child: WebWidth(
            maxWidth: 600,
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 28, 20, 32), children: [
              Row(children: [
                onBack != null
                    ? CircleButton(FontAwesomeIcons.arrowLeft, bg: Ds.bg, tooltip: '뒤로', onPressed: onBack)
                    : const IconCircle(FontAwesomeIcons.shield, size: 56, iconSize: 24, bg: Ds.navy, fg: Colors.white),
                const Spacer(),
                Text('$step / 2', style: dsText(15, weight: FontWeight.w700, color: Ds.muted)),
              ]),
              ...children,
            ]),
          ),
        ),
      );
}

//// 1/2: 필수 동의 + 로그인 (디자인 온보딩 1단계). 처음 들어온 기기는 무조건 이 화면부터 (동의는 기기에 저장).
/// 두 동의와 로그인(서버 연결 모드만)이 끝나야 '다음'이 켜진다 → 2/2 내 정보(처음 한 번) 또는 가려던 화면
class MLoginScreen extends ConsumerStatefulWidget {
  const MLoginScreen({super.key, this.from});
  final String? from;
  @override
  ConsumerState<MLoginScreen> createState() => _MLoginScreenState();
}

class _MLoginScreenState extends ConsumerState<MLoginScreen> {
  final email = TextEditingController(), password = TextEditingController();
  bool signUp = false, busy = false;
  bool cLoc = Onboarding.consented, cDis = Onboarding.consented;
  String? error;

  bool get consented => cLoc && cDis;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      if (mounted && done != null) showDsToast(context, done);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _submit() {
    final auth = ref.read(authService);
    final e = email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(e)) {
      setState(() => error = '이메일 주소를 확인해 주세요');
      return Future.value();
    }
    if (password.text.isEmpty) {
      setState(() => error = '비밀번호를 입력해 주세요');
      return Future.value();
    }
    return _run(
        () => signUp ? auth.signUpWithEmail(e, password.text) : auth.signInWithEmail(e, password.text),
        done: signUp ? '가입했어요' : '로그인했어요');
  }

  Future<void> _reset() async {
    if (email.text.trim().isEmpty) {
      setState(() => error = '비밀번호를 찾을 이메일을 먼저 적어 주세요');
      return;
    }
    await _run(() => ref.read(authService).sendPasswordReset(email.text),
        done: '비밀번호 재설정 메일을 보냈어요. 메일함을 확인해 주세요.');
  }

  /// '다음': 동의를 기기에 저장하고 2/2(처음 한 번) 또는 가려던 화면으로
  Future<void> _next(bool loggedIn) async {
    if (!consented) {
      showDsToast(context, '필수 동의 항목을 모두 선택해 주세요');
      return;
    }
    if (!loggedIn) {
      showDsToast(context, '로그인을 먼저 해 주세요');
      return;
    }
    await Onboarding.setConsented();
    if (!mounted) return;
    final from = widget.from;
    final next = from != null && from.startsWith('/') && !from.startsWith('/login') && !from.startsWith('/boot') && !from.startsWith('/setup')
        ? from
        : '/';
    context.go(Onboarding.done ? next : Uri(path: '/setup', queryParameters: {'from': next}).toString());
  }

  Widget _consent(bool on, FaIconData icon, String text, bool soft, VoidCallback onTap) => Semantics(
        checked: on,
        child: Material(
          color: on ? Ds.soft : Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20), side: BorderSide(color: on ? Ds.navy : Ds.line, width: 2)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                SizedBox(width: 26, child: Center(child: FaIcon(icon, size: 22, color: Ds.navy))),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                      TextSpan(children: [
                        if (on)
                          const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: FaIcon(FontAwesomeIcons.check, size: 15, color: Ds.ink))),
                        TextSpan(text: text),
                      ]),
                      style: dsText(17, weight: FontWeight.w700, height: 1.35)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: soft ? Ds.soft : Colors.white, borderRadius: BorderRadius.circular(Ds.pill)),
                  child: Text('필수', style: dsText(13, weight: FontWeight.w700, color: Ds.navy)),
                ),
              ]),
            ),
          ),
        ),
      );

  // ---------------------------------------------------------------- 웹 모양 (상태·동작은 위와 같다)

  Widget _webConsent(bool on, IconData icon, String title, String desc, VoidCallback onTap) => Semantics(
        checked: on,
        child: Material(
          color: on ? GK.tint : Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GK.radiusInner), side: BorderSide(color: on ? GK.navy : GK.line, width: 2)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 16, 14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Checkbox(value: on, onChanged: (_) => onTap()),
                const SizedBox(width: 4),
                Padding(padding: const EdgeInsets.only(top: 10), child: Icon(icon, size: 22, color: GK.navy)),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: GK.ink, height: 1.35)),
                      const SizedBox(height: 4),
                      Text(desc, style: const TextStyle(fontSize: 15, color: GK.muted, height: 1.45)),
                    ]),
                  ),
                ),
                const SizedBox(width: 10),
                const Padding(padding: EdgeInsets.only(top: 8), child: WebRequiredTag()),
              ]),
            ),
          ),
        ),
      );

  Widget _webBuild(AccountInfo? account, bool signedIn, bool loggedIn, bool ready) {
    final consentCard = GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GkCardHeader('필수 동의', icon: Icons.fact_check_rounded),
        const SizedBox(height: 18),
        // 모두 동의
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => cLoc = cDis = !consented),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Checkbox(value: consented, onChanged: (_) => setState(() => cLoc = cDis = !consented)),
              const SizedBox(width: 4),
              const Text('모두 동의', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: GK.ink)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        _webConsent(cLoc, Icons.my_location_rounded, '위치 정보 수집 동의',
            '내 위치 주변의 위험 경고와 가장 가까운 대피소·대피 경로 안내에 써요.', () => setState(() => cLoc = !cLoc)),
        const SizedBox(height: 12),
        _webConsent(cDis, Icons.accessible_forward_rounded, '장애 정보(시각·청각·지체) 민감정보 수집 동의',
            '음성·진동 알림, 경사·계단을 피하는 경로처럼 나에게 맞는 안내에 써요.', () => setState(() => cDis = !cDis)),
      ]),
    );

    final Widget loginBody;
    if (!AuthService.enabled) {
      loginBody = const Text('예시 데이터 모드에서는 로그인을 쓰지 않아요. 동의만 하고 다음으로 가세요.',
          style: TextStyle(fontSize: 17, color: GK.muted, height: 1.5));
    } else if (signedIn) {
      loginBody = Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: const Color(0xFFE3F5EA), borderRadius: BorderRadius.circular(GK.radiusInner)),
        child: Row(children: [
          const GkCircleIcon(Icons.check_rounded, size: 44, bg: GK.green, fg: Colors.white),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('로그인했어요', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF0F5C33))),
              Text(account!.email ?? account.providerLabel,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: Color(0xFF2A5A40))),
            ]),
          ),
        ]),
      );
    } else {
      loginBody = AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OutlinedButton.icon(
              onPressed: busy ? null : () => _run(ref.read(authService).signInWithGoogle),
              icon: const Icon(Icons.g_mobiledata_rounded, size: 30),
              label: const Text('Google로 계속하기')),
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(children: [
                Expanded(child: Divider(color: GK.line)),
                Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('또는 이메일', style: TextStyle(color: GK.muted, fontWeight: FontWeight.w600))),
                Expanded(child: Divider(color: GK.line)),
              ])),
          SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('로그인')), ButtonSegment(value: true, label: Text('가입'))],
              selected: {signUp},
              showSelectedIcon: false,
              onSelectionChanged: busy ? null : (v) => setState(() => signUp = v.first)),
          const SizedBox(height: 16),
          TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: '이메일', hintText: 'example@email.com')),
          const SizedBox(height: 12),
          TextField(
              controller: password,
              obscureText: true,
              autofillHints: [signUp ? AutofillHints.newPassword : AutofillHints.password],
              onSubmitted: (_) => busy ? null : _submit(),
              decoration: InputDecoration(labelText: '비밀번호', hintText: signUp ? '6자 이상' : '비밀번호 입력')),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: const TextStyle(color: GK.red, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 16),
          Row(children: [
            if (!signUp) TextButton(onPressed: busy ? null : _reset, child: const Text('비밀번호를 잊었어요')),
            const Spacer(),
            FilledButton(onPressed: busy ? null : _submit, child: Text(busy ? '확인 중…' : (signUp ? '가입하기' : '로그인'))),
          ]),
        ]),
      );
    }
    final loginCard = GkCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const GkCardHeader('로그인', icon: Icons.person_rounded, trailing: WebRequiredTag()),
        const SizedBox(height: 18),
        loginBody,
      ]),
    );

    final left = [if (!consented) '필수 동의', if (!loggedIn) '로그인'];
    return WebOnboardingFrame(
      step: 1,
      title: '시작하기 전에',
      subtitle: '나에게 맞는 대피 안내를 위해 몇 가지만 알려주세요. 필수 동의와 로그인을 마치면 내 정보 입력으로 넘어가요.',
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GkColumns(minWidth: 440, equalHeight: false, children: [consentCard, loginCard]),
        const SizedBox(height: 28),
        Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 16, runSpacing: 12, children: [
          Text(ready ? '준비됐어요. 다음으로 넘어가세요.' : '남은 항목: ${left.join(' · ')}',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ready ? GK.green : GK.muted)),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: ready ? GK.navy : GK.grey,
                minimumSize: const Size(180, 56),
                textStyle: const TextStyle(fontFamily: GK.font, fontSize: 19, fontWeight: FontWeight.w800)),
            onPressed: () => _next(loggedIn),
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('다음'),
          ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext c) {
    final auth = ref.watch(authService);
    final account = AuthService.ready ? (ref.watch(accountProvider).valueOrNull ?? auth.account) : null;
    final signedIn = account != null && !account.isAnonymous;
    // 예시 데이터 모드(서버 없음)는 로그인을 쓰지 않으니 동의만 하면 된다.
    // 로컬 개발 dev uid(AppConfig.devUid)도 로그인으로 본다 — 라우터(AuthService.signedIn)와 같게
    final loggedIn = !AuthService.enabled || signedIn || AuthService.signedIn;
    final ready = consented && loggedIn;
    if (!useMobileUi) return _webBuild(account, signedIn, loggedIn, ready);
    // 흰 바탕 한 장 (그림대로). 넓은 화면(웹)은 가운데 600px
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: WebWidth(
          maxWidth: 600,
          child: LayoutBuilder(
            builder: (_, box) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight - 60),
                child: IntrinsicHeight(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      const IconCircle(FontAwesomeIcons.shield, size: 56, iconSize: 24, bg: Ds.navy, fg: Colors.white),
                      const Spacer(),
                      Text('1 / 2', style: dsText(15, weight: FontWeight.w700, color: Ds.muted)),
                    ]),
                    const SizedBox(height: 18),
                    Text('구룡포 안전 비서', style: dsText(32, weight: FontWeight.w800, spacing: -.6)),
                    const SizedBox(height: 6),
                    Text('나에게 맞는 대피 안내를 위해 몇 가지만 알려주세요.', style: dsText(17, color: Ds.muted, height: 1.5)),
                    const SizedBox(height: 22),
                    _consent(cLoc, FontAwesomeIcons.locationCrosshairs, '위치 정보 수집 동의', false, () => setState(() => cLoc = !cLoc)),
                    const SizedBox(height: 10),
                    _consent(cDis, FontAwesomeIcons.wheelchairMove, '장애 정보(시각·청각·지체) 민감정보 수집 동의', true,
                        () => setState(() => cDis = !cDis)),
                    const SizedBox(height: 26),
                    Row(children: [
                      Text('로그인', style: dsText(17, weight: FontWeight.w800)),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: Ds.soft, borderRadius: BorderRadius.circular(Ds.pill)),
                        child: Text('필수', style: dsText(13, weight: FontWeight.w700, color: Ds.navy)),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(child: Divider()),
                    ]),
                    const SizedBox(height: 12),
                    if (!AuthService.enabled)
                      Text('예시 데이터 모드에서는 로그인을 쓰지 않아요. 동의만 하고 다음으로 가세요.', style: dsText(15, color: Ds.muted, height: 1.5))
                    else if (signedIn)
                      Container(
                        constraints: const BoxConstraints(minHeight: 60),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(color: Ds.goodSoft, borderRadius: BorderRadius.circular(20)),
                        child: Row(children: [
                          const IconCircle(FontAwesomeIcons.check, size: 36, iconSize: 15, bg: Ds.goodDeep, fg: Colors.white),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('로그인했어요', style: dsText(16, weight: FontWeight.w800, color: const Color(0xFF0F5C33))),
                              Text(account.email ?? account.providerLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: dsText(14, color: const Color(0xFF2A5A40))),
                            ]),
                          ),
                        ]),
                      )
                    else ...[
                      DsField(
                          label: '이메일',
                          controller: email,
                          hint: 'example@email.com',
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email]),
                      const SizedBox(height: 10),
                      DsField(
                          label: '비밀번호',
                          controller: password,
                          hint: signUp ? '6자 이상' : '비밀번호 입력',
                          obscure: true,
                          autofillHints: [signUp ? AutofillHints.newPassword : AutofillHints.password],
                          onSubmitted: (_) => busy ? null : _submit()),
                      if (error != null) ...[const SizedBox(height: 6), ErrorLine(error!)],
                      const SizedBox(height: 10),
                      PillButton(busy ? '확인 중…' : (signUp ? '가입' : '로그인'),
                          height: 52, outlined: true, onPressed: busy ? null : _submit),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        TextButton(
                            onPressed: busy ? null : () => setState(() => signUp = !signUp),
                            child: Text(signUp ? '이미 계정이 있어요 · 로그인' : '처음이에요 · 가입하기')),
                        if (!signUp) TextButton(onPressed: busy ? null : _reset, child: const Text('비밀번호를 잊었어요')),
                      ]),
                      PillButton('Google로 계속하기',
                          icon: FontAwesomeIcons.google,
                          height: 48,
                          fontSize: 15,
                          bg: Ds.bg,
                          fg: Ds.navy,
                          onPressed: busy ? null : () => _run(ref.read(authService).signInWithGoogle)),
                    ],
                    const Spacer(),
                    const SizedBox(height: 28),
                    PillButton('다음', height: 60, fontSize: 20, bg: ready ? Ds.navy : Ds.off, onPressed: () => _next(loggedIn)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 2/2: 내 정보 (모두 선택 · 건너뛰기 가능 — 2026-10-07 '첫 설정 강제 안 함' 유지)
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, this.from});
  final String? from;

  @override
  Widget build(BuildContext context) {
    Future<void> finish() async {
      await Onboarding.setDone();
      if (!context.mounted) return;
      final next = from != null && from!.startsWith('/') && !from!.startsWith('/login') && !from!.startsWith('/setup')
          ? from!
          : '/';
      context.go(next);
    }

    if (!useMobileUi) {
      return WebOnboardingFrame(
        step: 2,
        title: '내 정보',
        subtitle: '나에게 맞는 대피 안내를 위해 몇 가지만 알려주세요. 모두 선택이고, 나중에 사용자 메뉴에서 바꿀 수 있어요.',
        body: ProfileForm(onboarding: true, web: true, onDone: finish),
      );
    }
    return _ObSheet(step: 2, onBack: null, children: [
      const SizedBox(height: 18),
      Text('내 정보', style: dsText(30, weight: FontWeight.w800, spacing: -.6)),
      const SizedBox(height: 6),
      Text('나에게 맞는 대피 안내를 위해 몇 가지만 알려주세요. 모두 선택이고, 나중에 사용자 탭에서 바꿀 수 있어요.',
          style: dsText(17, color: Ds.muted, height: 1.5)),
      ProfileForm(onboarding: true, onDone: finish),
    ]);
  }
}

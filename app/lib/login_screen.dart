import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_screen.dart';
import 'services/auth_service.dart';
import 'ui/tokens.dart';
import 'ui/widgets.dart';

final authService = Provider<AuthService>((_) => AuthService());
final accountProvider = StreamProvider<AccountInfo?>((ref) => ref.watch(authService).accountChanges());

/// 첫 화면 (디자인 온보딩). 1/2 = 필수 동의 + 로그인(/login), 2/2 = 내 정보(/setup, 모두 선택·건너뛰기 가능).
/// 동의·2단계 완료 여부는 기기에 저장 — BootScreen이 [loadOnboardingState]로 읽어 라우터 redirect가 쓴다
class Onboarding {
  Onboarding._();
  static const _consentKey = 'onboarding_consent_v1', _doneKey = 'onboarding_done_v1';
  static bool consented = false;
  static bool done = false;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      consented = p.getBool(_consentKey) ?? false;
      done = p.getBool(_doneKey) ?? false;
    } catch (_) {}
  }

  static Future<void> setConsented() async {
    consented = true;
    try {
      await (await SharedPreferences.getInstance()).setBool(_consentKey, true);
    } catch (_) {}
  }

  static Future<void> setDone() async {
    done = true;
    try {
      await (await SharedPreferences.getInstance()).setBool(_doneKey, true);
    } catch (_) {}
  }
}

/// 남색 바탕 위 흰 시트 (온보딩 화면 틀)
class _ObSheet extends StatelessWidget {
  const _ObSheet({required this.step, required this.children, this.onBack});
  final int step;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Ds.navy,
        body: SafeArea(
          bottom: false,
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: const BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
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
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.from});
  final String? from;
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
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

  @override
  Widget build(BuildContext c) {
    final auth = ref.watch(authService);
    final account = AuthService.ready ? (ref.watch(accountProvider).valueOrNull ?? auth.account) : null;
    final signedIn = account != null && !account.isAnonymous;
    // 예시 데이터 모드(서버 없음)는 로그인을 쓰지 않으니 동의만 하면 된다
    final loggedIn = !AuthService.enabled || signedIn;
    final ready = consented && loggedIn;
    return Scaffold(
      backgroundColor: Ds.navy,
      body: SafeArea(
        bottom: false,
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
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

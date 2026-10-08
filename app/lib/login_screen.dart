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

/// 1/2: 필수 동의 + 로그인 (로그인 강제 2026-10-08 — 로그인되면 라우터가 다음 화면으로 보낸다)
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
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
    if (!consented) {
      setState(() => error = '필수 동의 항목을 모두 선택해 주세요');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Onboarding.setConsented();
      await action();
      if (mounted && done != null) showDsToast(context, done);
      // 화면 이동은 라우터가 한다 (로그인되면 /login → 2단계 또는 가려던 화면, main.dart redirect)
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
    return _run(
        () => signUp ? auth.signUpWithEmail(e, password.text) : auth.signInWithEmail(e, password.text),
        done: signUp ? '가입했어요' : '로그인했어요');
  }

  Future<void> _reset() async {
    if (email.text.trim().isEmpty) {
      setState(() => error = '비밀번호를 찾을 이메일을 먼저 적어 주세요');
      return;
    }
    setState(() => busy = true);
    try {
      await ref.read(authService).sendPasswordReset(email.text);
      setState(() => error = null);
      if (mounted) showDsToast(context, '비밀번호 재설정 메일을 보냈어요. 메일함을 확인해 주세요.');
    } on AuthFailure catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _consent(bool on, FaIconData icon, String text, bool soft, VoidCallback onTap) => Material(
        color: on ? Ds.soft : Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: on ? Ds.navy : Ds.line, width: 2)),
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
                child: Text.rich(TextSpan(children: [
                  if (on)
                    const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: FaIcon(FontAwesomeIcons.check, size: 15, color: Ds.ink))),
                  TextSpan(text: text),
                ]), style: dsText(17, weight: FontWeight.w700, height: 1.35)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: soft ? Ds.soft : Colors.white, borderRadius: BorderRadius.circular(Ds.pill)),
                child: Text('필수', style: dsText(13, weight: FontWeight.w700, color: Ds.navy)),
              ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext c) => _ObSheet(step: 1, children: [
        const SizedBox(height: 18),
        Text('구룡포 안전 비서', style: dsText(32, weight: FontWeight.w800, spacing: -.6)),
        const SizedBox(height: 6),
        Text('나에게 맞는 대피 안내를 위해 몇 가지만 알려주세요.', style: dsText(17, color: Ds.muted, height: 1.5)),
        const SizedBox(height: 22),
        _consent(cLoc, FontAwesomeIcons.locationCrosshairs, '위치 정보 수집 동의', false,
            () => setState(() => cLoc = !cLoc)),
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
          Text('예시 데이터 모드에서는 로그인을 쓰지 않아요.', style: dsText(15, color: Ds.muted))
        else ...[
          SegmentedPill<bool>(
            height: 40,
            items: const [(false, '로그인', null), (true, '처음이에요 · 가입', null)],
            value: signUp,
            onChanged: (v) => setState(() => signUp = v),
          ),
          const SizedBox(height: 12),
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
          PillButton(busy ? '확인 중…' : (signUp ? '가입하고 다음' : '로그인하고 다음'),
              height: 60, fontSize: 20, bg: consented ? Ds.navy : Ds.off, onPressed: busy ? null : _submit),
          const SizedBox(height: 10),
          PillButton('Google로 계속하기',
              icon: FontAwesomeIcons.google,
              height: 52,
              outlined: true,
              onPressed: busy ? null : () => _run(ref.read(authService).signInWithGoogle)),
          if (!signUp)
            TextButton(onPressed: busy ? null : _reset, child: const Text('비밀번호를 잊었어요')),
        ],
      ]);
}

/// 2/2: 내 정보 (모두 선택 · 건너뛰기 가능 — 2026-10-07 '첫 설정 강제 안 함' 유지)
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

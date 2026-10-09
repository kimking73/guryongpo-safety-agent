import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'services/auth_service.dart';
import 'ui/gk_theme.dart';
import 'ui/gk_widgets.dart';

/// 로그인은 선택 — 익명으로도 앱을 전부 쓸 수 있다. 연결하면 다른 기기에서도 같은 계정으로 이어 쓴다.
final authService = Provider<AuthService>((_) => AuthService());
final accountProvider = StreamProvider<AccountInfo?>((ref) => ref.watch(authService).accountChanges());

/// 프로필 화면의 '계정' 카드: 익명이면 Google·이메일 로그인 버튼, 로그인했으면 계정과 로그아웃
class AccountCard extends ConsumerStatefulWidget {
  const AccountCard({super.key});
  @override
  ConsumerState<AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<AccountCard> {
  bool busy = false;

  Future<void> _do(Future<void> Function() action, String done) async {
    setState(() => busy = true);
    try {
      await action();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } on AuthFailure catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 계정 카드 = web-prototype MailCard (2026-10-08) → 2026-10-09 간결하게: 작은 계정 아이콘 · 이메일 · 로그아웃.
  /// 긴 이메일은 두 줄까지 줄바꿈 후 말줄임, 좁으면 버튼을 아래 줄로 내려 겹치지 않게
  @override
  Widget build(BuildContext c) {
    final auth = ref.watch(authService);
    Widget head(IconData icon, String title, String sub) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 24, color: GK.navy)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Tooltip(
              message: title,
              child: Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GK.ink, height: 1.35)),
            ),
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(fontSize: 14, color: GK.muted, height: 1.35)),
          ])),
        ]);
    if (!AuthService.ready) {
      return GkCard(
          padding: gkCompactPad,
          child: head(Icons.account_circle_outlined, '로그인 계정', '예시 데이터 모드에서는 로그인을 쓰지 않아요.'));
    }
    final a = ref.watch(accountProvider).valueOrNull ?? auth.account;
    final signedIn = a != null && !a.isAnonymous;
    final info = head(
        Icons.account_circle_outlined,
        signedIn ? (a.email ?? '로그인됨') : '로그인하지 않음',
        signedIn ? '${a.providerLabel} 계정으로 로그인됨' : '로그인하면 내 정보·맞춤 경고를 다른 기기에서도 써요');
    final button = signedIn
        ? OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: busy ? null : () => _do(auth.signOut, '로그아웃했습니다.'),
            child: const Text('로그아웃'))
        : FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: busy ? null : () => c.push('/login'),
            child: const Text('로그인'));
    return GkCard(
        padding: gkCompactPad,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(
          builder: (_, box) => box.maxWidth < 340
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  info,
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: button),
                ])
              : Row(children: [Expanded(child: info), const SizedBox(width: 12), button])),
      if (busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
      if (!signedIn) ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: GkPill('Google로 계속하기',
              icon: Icons.g_mobiledata_rounded,
              onTap: busy ? null : () => _do(auth.signInWithGoogle, 'Google 계정으로 로그인했습니다.')),
        ),
      ],
    ]));
  }
}

/// 이메일·비밀번호 로그인과 가입 (가입은 지금 익명 계정에 연결)
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final email = TextEditingController(), password = TextEditingController();
  bool signUp = false, busy = false;
  String? error;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = ref.read(authService);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      signUp
          ? await auth.signUpWithEmail(email.text, password.text)
          : await auth.signInWithEmail(email.text, password.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(signUp ? '가입했습니다.' : '로그인했습니다.')));
      // 화면 이동은 라우터가 한다 (로그인되면 /login → 가려던 화면, main.dart redirect)
    } on AuthFailure catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _reset() async {
    if (email.text.trim().isEmpty) {
      setState(() => error = '비밀번호를 찾을 이메일을 먼저 적어 주세요.');
      return;
    }
    setState(() => busy = true);
    try {
      await ref.read(authService).sendPasswordReset(email.text);
      setState(() => error = null);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('비밀번호 재설정 메일을 보냈습니다. 메일함을 확인해 주세요.')));
      }
    } on AuthFailure catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _google() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref.read(authService).signInWithGoogle();
    } on AuthFailure catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // 로그인 강제 화면 (2026-10-08): 로그인해야 앱을 쓴다. 뒤로 가기 없음. 디자인 = web-prototype 초기 화면 (가운데 큰 카드)
  @override
  Widget build(BuildContext c) => Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: GkCard(
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Center(child: GkCircleIcon(Icons.shield_rounded, size: 80, bg: GK.navy, fg: Colors.white)),
                  const SizedBox(height: 16),
                  const Text('구룡포 안전 비서',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                  const SizedBox(height: 8),
                  const Text('구룡포 재난 정보·대피 경로·AI 안내를 쓰려면 로그인해 주세요.\n'
                      '내 정보는 이 계정에 저장되어 다른 기기에서도 이어집니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 17, color: GK.muted, height: 1.5)),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                      onPressed: busy ? null : _google,
                      icon: const Icon(Icons.g_mobiledata_rounded, size: 30),
                      label: const Text('Google로 계속하기')),
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Row(children: [
                        Expanded(child: Divider()),
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text('또는 이메일', style: TextStyle(color: GK.muted, fontWeight: FontWeight.w600))),
                        Expanded(child: Divider()),
                      ])),
                  SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('로그인')),
                        ButtonSegment(value: true, label: Text('가입')),
                      ],
                      selected: {signUp},
                      onSelectionChanged: busy ? null : (v) => setState(() => signUp = v.first)),
                  const SizedBox(height: 18),
                  TextField(
                      controller: email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: '이메일')),
                  const SizedBox(height: 12),
                  TextField(
                      controller: password,
                      obscureText: true,
                      autofillHints: [signUp ? AutofillHints.newPassword : AutofillHints.password],
                      onSubmitted: (_) => busy ? null : _submit(),
                      decoration: InputDecoration(labelText: '비밀번호', helperText: signUp ? '6자 이상' : null)),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: GK.red, fontWeight: FontWeight.w700)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                      onPressed: busy ? null : _submit,
                      child: busy
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(signUp ? '가입하기' : '로그인')),
                  if (!signUp) TextButton(onPressed: busy ? null : _reset, child: const Text('비밀번호를 잊었어요')),
                ]),
              ),
            ),
          ),
        ),
      ));
}

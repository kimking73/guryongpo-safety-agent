import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'services/auth_service.dart';

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

  @override
  Widget build(BuildContext c) {
    final auth = ref.watch(authService);
    if (!AuthService.ready) {
      return const Card(
          child: ListTile(
              leading: Icon(Icons.person_outline),
              title: Text('계정'),
              subtitle: Text('예시 데이터 모드에서는 로그인을 쓰지 않습니다.')));
    }
    final a = ref.watch(accountProvider).valueOrNull ?? auth.account;
    final signedIn = a != null && !a.isAnonymous;
    return Card(
        child: Column(children: [
      ListTile(
          leading: Icon(signedIn ? Icons.verified_user_outlined : Icons.person_outline),
          title: Text(signedIn ? (a.email ?? '로그인됨') : '익명 사용자'),
          subtitle: Text(signedIn
              ? '${a.providerLabel} 계정으로 로그인 — 다른 기기에서도 같은 정보로 이어 씁니다.'
              : '로그인하지 않아도 모든 기능을 쓸 수 있습니다. 로그인하면 지금 정보가 계정에 저장됩니다.')),
      if (busy) const LinearProgressIndicator(),
      if (!signedIn) ...[
        ListTile(
            leading: const Icon(Icons.g_mobiledata, size: 32),
            title: const Text('Google로 계속하기'),
            enabled: !busy,
            onTap: () => _do(auth.signInWithGoogle, 'Google 계정으로 로그인했습니다.')),
        ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('이메일로 로그인·가입'),
            enabled: !busy,
            onTap: () => c.push('/login')),
      ] else
        ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('로그아웃'),
            enabled: !busy,
            onTap: () => _do(auth.signOut, '로그아웃했습니다. 익명으로 계속 사용합니다.')),
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
          .showSnackBar(SnackBar(content: Text(signUp ? '가입했습니다. 지금 정보가 이 계정에 저장됩니다.' : '로그인했습니다.')));
      context.pop();
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

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: Text(signUp ? '이메일로 가입' : '이메일로 로그인')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('로그인')),
              ButtonSegment(value: true, label: Text('가입')),
            ],
            selected: {signUp},
            onSelectionChanged: busy ? null : (v) => setState(() => signUp = v.first)),
        const SizedBox(height: 20),
        TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: '이메일', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(
            controller: password,
            obscureText: true,
            autofillHints: [signUp ? AutofillHints.newPassword : AutofillHints.password],
            onSubmitted: (_) => busy ? null : _submit(),
            decoration: InputDecoration(
                labelText: '비밀번호', helperText: signUp ? '6자 이상' : null, border: const OutlineInputBorder())),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
            onPressed: busy ? null : _submit,
            child: busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(signUp ? '가입하기' : '로그인')),
        if (!signUp) TextButton(onPressed: busy ? null : _reset, child: const Text('비밀번호를 잊었어요')),
      ]));
}

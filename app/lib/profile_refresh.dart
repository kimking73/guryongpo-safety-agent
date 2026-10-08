import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'main.dart';
import 'services/account_sync.dart';
import 'services/app_config.dart';

/// 프로필 화면 'AI가 대화에서 수집한 정보' (2026-10-08: 프로필은 서버 하나 — AI가 대화에서 들은 내용으로 같은 곳을 고친다).
/// - 화면을 열 때 서버 프로필을 내려받고, AI 대화 뒤 바뀌면(AccountSync.updated) 위 카드들이 다시 읽게 한다
/// - AI가 반영한 기록(서버 care.profile_updates: 무엇을·언제·사용자가 한 말)을 최신순으로 보여 준다. 지우면 기록만 지운다
class ServerProfileRefresh extends ConsumerStatefulWidget {
  const ServerProfileRefresh({super.key});
  @override
  ConsumerState<ServerProfileRefresh> createState() => _ServerProfileRefreshState();
}

class _ServerProfileRefreshState extends ConsumerState<ServerProfileRefresh> {
  List<ProfileUpdate>? items;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    AccountSync.updated.addListener(_onUpdated);
    AccountSync.instance.pullProfile();
    _load();
  }

  @override
  void dispose() {
    AccountSync.updated.removeListener(_onUpdated);
    super.dispose();
  }

  void _onUpdated() {
    if (!mounted) return;
    ref.read(profileRevision.notifier).state++;
    _load();
  }

  Future<void> _load() async {
    final r = await AccountSync.instance.profileUpdates();
    if (mounted) {
      setState(() {
        items = r;
        loading = false;
      });
    }
  }

  String _when(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext c) {
    if (!AppConfig.isRemote) return const SizedBox.shrink();
    final list = items;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.psychology_outlined, color: Color(0xff16803c)),
            const SizedBox(width: 6),
            const Expanded(
                child: Text('AI가 대화에서 수집한 정보', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
            IconButton(
                tooltip: '다시 불러오기',
                onPressed: () async {
                  setState(() => loading = true);
                  await AccountSync.instance.pullProfile();
                  await _load();
                },
                icon: const Icon(Icons.refresh)),
          ]),
          Text('AI 대화에서 말씀하신 나이·보행·이동 수단·직업·집·자주 가는 곳은 위 프로필에 바로 반영됩니다. '
              '여기서는 무엇을 언제 반영했는지 볼 수 있습니다. 프로필에서 고치시면 AI도 고친 값으로 답합니다.',
              style: Theme.of(c).textTheme.bodySmall),
          const SizedBox(height: 6),
          if (loading) const LinearProgressIndicator(),
          if (!loading && list == null) const Text('로그인하면 AI가 대화에서 반영한 정보가 여기에 나타납니다.'),
          if (list != null && list.isEmpty) const Text('아직 없습니다. 예: "저는 78살이고 무릎이 불편해요"'),
          for (final i in list ?? const <ProfileUpdate>[])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '${i.label}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: i.value),
                  ])),
                  if (i.quote != null)
                    Text('말씀하신 내용: "${i.quote}"', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  Text('${_when(i.createdAt)} 프로필에 반영',
                      style: TextStyle(fontSize: 12, color: Colors.green.shade700, fontWeight: FontWeight.w600)),
                ])),
                IconButton(
                    tooltip: '기록 지우기 (프로필 값은 그대로)',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      final ok = await AccountSync.instance.deleteProfileUpdate(i.id);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok ? '기록을 지웠습니다. 프로필 값은 그대로입니다.' : '지우지 못했습니다. 잠시 후 다시 시도해 주세요.')));
                      await _load();
                    }),
              ]),
            ),
        ]),
      ),
    );
  }
}

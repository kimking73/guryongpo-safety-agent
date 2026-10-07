import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'main.dart';
import 'services/account_sync.dart';
import 'services/app_config.dart';

/// 프로필 화면 안내 + 서버 프로필 내려받기 (2026-10-08: 프로필은 서버 하나 — AI가 대화에서 들은 내용으로 같은 곳을 고친다).
/// 화면을 열 때 서버 값을 내려받고, AI 대화 뒤 내려받은 값이 바뀌면(AccountSync.updated) 위 카드들이 다시 읽게 한다.
class ServerProfileRefresh extends ConsumerStatefulWidget {
  const ServerProfileRefresh({super.key});
  @override
  ConsumerState<ServerProfileRefresh> createState() => _ServerProfileRefreshState();
}

class _ServerProfileRefreshState extends ConsumerState<ServerProfileRefresh> {
  @override
  void initState() {
    super.initState();
    AccountSync.updated.addListener(_onUpdated);
    AccountSync.instance.pullProfile();
  }

  @override
  void dispose() {
    AccountSync.updated.removeListener(_onUpdated);
    super.dispose();
  }

  void _onUpdated() {
    if (mounted) ref.read(profileRevision.notifier).state++;
  }

  @override
  Widget build(BuildContext c) {
    if (!AppConfig.isRemote) return const SizedBox.shrink();
    return Row(children: [
      const Icon(Icons.psychology_outlined, size: 18, color: Color(0xff16803c)),
      const SizedBox(width: 6),
      Expanded(
          child: Text('AI 대화에서 말씀하신 나이·보행·이동 수단·직업·집·자주 가는 곳은 이 프로필에 바로 반영됩니다. '
              '여기서 고치시면 AI도 고친 값으로 답합니다.',
              style: Theme.of(c).textTheme.bodySmall)),
    ]);
  }
}

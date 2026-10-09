import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'main.dart';
import 'services/account_sync.dart';
import 'services/app_config.dart';
import 'ui/gk_theme.dart';
import 'ui/gk_widgets.dart';

/// 보행 능력·보호가 필요한 동반자는 더 다루지 않는다 (2026-10-09 사용자 결정) — 예전에 쌓인 기록도 보이지 않게 거른다
const hiddenProfileUpdateFields = {'walking_impaired', 'has_dependents', 'walking_ability'};
const _hiddenLabels = {'보행', '보호가 필요한 동반자'};

bool shownProfileUpdate(ProfileUpdate u) =>
    !hiddenProfileUpdateFields.contains(u.field) && !_hiddenLabels.contains(u.label);

/// 프로필 화면 'AI가 반영한 정보' (2026-10-08: 프로필은 서버 하나 — AI가 대화에서 들은 내용으로 같은 곳을 고친다).
/// - 화면을 열 때 서버 프로필을 내려받고, AI 대화 뒤 바뀌면(AccountSync.updated) 위 카드들이 다시 읽게 한다
/// - 기본은 '항목 · 값'만. '자세히 보기'를 펼치면 사용자가 한 말과 반영 시각 (서버 care.profile_updates, 최신순)
/// - 지우면 기록만 지운다 (프로필 값은 그대로)
class ServerProfileRefresh extends ConsumerStatefulWidget {
  const ServerProfileRefresh({super.key});
  @override
  ConsumerState<ServerProfileRefresh> createState() => _ServerProfileRefreshState();
}

class _ServerProfileRefreshState extends ConsumerState<ServerProfileRefresh> {
  List<ProfileUpdate>? items;
  bool loading = true;
  bool details = false;

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
        items = r?.where(shownProfileUpdate).toList();
        loading = false;
      });
    }
  }

  String _when(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _delete(ProfileUpdate i) async {
    final ok = await AccountSync.instance.deleteProfileUpdate(i.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '기록을 지웠어요. 프로필 값은 그대로예요.' : '지우지 못했어요. 잠시 후 다시 시도해 주세요.')));
    await _load();
  }

  static const _small = BoxConstraints(minWidth: 44, minHeight: 44);

  Widget _row(ProfileUpdate i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: '${i.label} · ', style: const TextStyle(color: GK.muted, fontWeight: FontWeight.w500)),
                TextSpan(text: i.value, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]), style: const TextStyle(fontSize: 16, color: GK.ink)),
              if (details) ...[
                if (i.quote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('말씀하신 내용: "${i.quote}"', style: const TextStyle(fontSize: 14, color: GK.muted)),
                  ),
                if (i.createdAt != null)
                  Text('${_when(i.createdAt)} 반영',
                      style: const TextStyle(fontSize: 13.5, color: GK.green, fontWeight: FontWeight.w600)),
              ],
            ]),
          )),
          IconButton(
              tooltip: '${i.label} 기록 지우기 (프로필 값은 그대로)',
              constraints: _small,
              icon: const Icon(Icons.delete_outline_rounded, size: 20, color: GK.muted),
              onPressed: () => _delete(i)),
        ]),
      );

  @override
  Widget build(BuildContext c) {
    if (!AppConfig.isRemote) return const SizedBox.shrink();
    final list = items;
    return GkCard(
        padding: gkCompactPad,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Expanded(child: GkCardTitle('AI가 반영한 정보', icon: Icons.psychology_rounded)),
            IconButton(
                tooltip: '다시 불러오기',
                constraints: _small,
                onPressed: loading
                    ? null
                    : () async {
                        setState(() => loading = true);
                        await AccountSync.instance.pullProfile();
                        await _load();
                      },
                icon: const Icon(Icons.refresh_rounded, size: 22, color: GK.navy)),
          ]),
          const Text('대화에서 반영한 정보를 확인할 수 있어요.', style: TextStyle(fontSize: 14, color: GK.muted)),
          const SizedBox(height: 6),
          if (loading) const LinearProgressIndicator(),
          if (!loading && list == null)
            const Text('로그인하면 AI가 대화에서 반영한 정보가 여기에 보여요.', style: TextStyle(fontSize: 15, color: GK.muted)),
          if (list != null && list.isEmpty)
            const Text('아직 없어요. 예: "저는 72살이고 어업을 해요"', style: TextStyle(fontSize: 15, color: GK.muted)),
          for (final i in list ?? const <ProfileUpdate>[]) _row(i),
          if (list != null && list.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
                  onPressed: () => setState(() => details = !details),
                  icon: Icon(details ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20),
                  label: Text(details ? '간단히 보기' : '자세히 보기', style: const TextStyle(fontSize: 14))),
            ),
        ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'main.dart';
import 'services/ai_memory.dart';
import 'services/app_config.dart';

/// 프로필 화면 'AI가 기억한 정보' (2026-10-07): AI 장기 기억 → 프로필.
/// 열 때 빈 프로필 칸은 자동으로 채우고(위 카드들이 다시 읽도록 profileRevision 증가), 다른 값이 있으면
/// '프로필과 다름'으로 보여 [반영]을 고르게 한다. 기억에서 지우면 AI가 다음 대화부터 쓰지 않는다.
class AiMemoryCard extends ConsumerStatefulWidget {
  const AiMemoryCard({super.key});
  @override
  ConsumerState<AiMemoryCard> createState() => _AiMemoryCardState();
}

class _AiMemoryCardState extends ConsumerState<AiMemoryCard> {
  final service = AiMemoryService();
  List<AiMemoryItem>? items;

  @override
  void initState() {
    super.initState();
    _sync();
    AiMemoryService.changed.addListener(_onChanged);   // 대화 뒤 자동 반영이 화면이 열려 있을 때 일어나도 바로 보이게
  }

  @override
  void dispose() {
    AiMemoryService.changed.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    _profileChanged();
    service.sync().then((r) {
      if (mounted) setState(() => items = r);
    });
  }

  Future<void> _sync() async {
    final r = await service.sync();
    if (!mounted) return;
    setState(() => items = r);
    // 프로필에 써 넣었으면 service 가 changed 를 올리고 _onChanged 가 카드들을 다시 읽게 한다
  }

  void _profileChanged() => ref.read(profileRevision.notifier).state++;

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
                child: Text('AI가 기억한 정보', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
            IconButton(tooltip: '다시 불러오기', onPressed: _sync, icon: const Icon(Icons.refresh)),
          ]),
          Text(
              service.available
                  ? 'AI 대화에서 직접 말씀하신 내용입니다. 새로 말씀하신 내용은 프로필에 바로 반영합니다. 그 뒤에 프로필을 직접 고치시면 고친 값을 유지합니다.'
                  : '로그인하면 AI 대화에서 말씀하신 내용(나이·보행·이동 수단 등)이 여기에 나타나고 프로필에 반영됩니다.',
              style: Theme.of(c).textTheme.bodySmall),
          const SizedBox(height: 6),
          if (service.available && list == null) const LinearProgressIndicator(),
          if (list != null && list.isEmpty && service.available)
            const Text('아직 기억한 정보가 없습니다. 예: "저는 78살이고 무릎이 불편해요"'),
          for (final i in list ?? const <AiMemoryItem>[]) _row(c, i),
        ]),
      ),
    );
  }

  Widget _row(BuildContext c, AiMemoryItem i) {
    final (tag, color) = switch (i.status) {
      AiMemoryStatus.same => ('프로필에 반영됨', Colors.green.shade700),
      AiMemoryStatus.filled => ('빈 칸에 채움', Colors.green.shade700),
      AiMemoryStatus.overwritten => ('최근 대화 내용으로 바꿈', Colors.green.shade700),
      AiMemoryStatus.differs => ('프로필에서 직접 바꾼 값을 유지', Colors.deepOrange),
      AiMemoryStatus.noField => ('참고용 (프로필 칸 없음)', Colors.blueGrey),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: '${i.label}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: i.value),
          ])),
          if (i.quote.isNotEmpty)
            Text('말씀하신 내용: "${i.quote}"', style: const TextStyle(fontSize: 12, color: Colors.black54)),
          Text(switch (i.status) {
                AiMemoryStatus.differs => '$tag · 지금 프로필: ${i.current}',
                AiMemoryStatus.overwritten => '$tag (이전 프로필: ${i.current})',
                _ => tag,
              },
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ])),
        if (i.status == AiMemoryStatus.differs)
          TextButton(
              onPressed: () async {
                await service.apply(i);
                await _sync();
              },
              child: const Text('반영')),
        IconButton(
            tooltip: 'AI 기억에서 지우기',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () async {
              final ok = await service.forget(i);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok ? '${i.label} 기억을 지웠습니다. 프로필 값은 그대로입니다.' : '지우지 못했습니다. 잠시 후 다시 시도해 주세요.')));
              await _sync();
            }),
      ]),
    );
  }
}

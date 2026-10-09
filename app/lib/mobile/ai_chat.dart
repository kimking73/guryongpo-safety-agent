import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_shell.dart' show WebWidth, wideBreakpoint;
import 'dashboard_cards.dart';
import 'm_core.dart';
import '../dashboard_parts.dart' show VoiceButton;
import '../live_screens.dart';
import '../main.dart';
import '../models/domain_models.dart';
import '../repositories/remote_repository.dart' show RemoteError;
import '../services/app_config.dart';
import '../services/voice_service.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// AI 대화창 (디자인: 마스코트 말풍선 · 내 정보에 맞춘 추천 질문 가로 줄 · 입력 pill(마이크·보내기) · 녹음 파형).
/// 답은 모두 실제 AI(repo.ask / askVoice). 체크리스트·태풍·지원 질문에는 앱이 카드를 덧붙인다 (태풍·지원 탭을 여기로 옮김)

/// 답 메시지(chatMessages 순번) → 덧붙일 카드 종류 (checklist · typhoon · support)
final chatCards = StateProvider<Map<int, String>>((_) => const {});

/// 태풍 대비 체크리스트 (디자인 문구). 체크 상태는 기기에 저장
const typhoonChecklist = [
  '창문을 테이프로 고정하고 베란다 물건 치우기',
  '물·상비약·충전기·신분증 챙기기',
  '해안가·방파제·지하 공간 가지 않기',
  '가까운 대피소 위치와 이동 경로 확인하기',
  '어선은 미리 단단히 묶고 항구에 가지 않기',
  '정전에 대비해 손전등·보조배터리 준비하기',
];

class ChecklistNotifier extends StateNotifier<List<bool>> {
  ChecklistNotifier() : super(List.filled(typhoonChecklist.length, false)) {
    _load();
  }
  static const _key = 'chat_typhoon_checklist_v1';

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getStringList(_key);
      if (v != null && v.length == typhoonChecklist.length) state = [for (final x in v) x == '1'];
    } catch (_) {}
  }

  Future<void> toggle(int i) async {
    state = [for (final (j, x) in state.indexed) j == i ? !x : x];
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_key, [for (final x in state) x ? '1' : '0']);
    } catch (_) {}
  }
}

final checklistProvider = StateNotifierProvider<ChecklistNotifier, List<bool>>((_) => ChecklistNotifier());

/// 질문 → 덧붙일 카드
String? cardFor(String q) {
  if (RegExp('체크|할 일|준비물').hasMatch(q)) return 'checklist';
  if (q.contains('태풍')) return 'typhoon';
  if (RegExp('보험|지원|복구|보상|피해 신고').hasMatch(q)) return 'support';
  return null;
}

/// 내 정보에 맞춘 추천 질문 (디자인 5개 + 기존 질문)
const suggestedQuestions = [
  '태풍 대비 체크리스트 알려줘',
  '지금 태풍 정보 알려줘',
  '내 위치에서 가장 가까운 대피소 알려줘',
  '재난 후 내가 받을 수 있는 보험이 있는지 알려줘',
  '대피할 때 뭘 해야 해?',
  '지금 침수 위험이 있어?',
  '도보로 안전하게 갈 수 있어?',
];

class MAiScreen extends ConsumerStatefulWidget {
  const MAiScreen({super.key});
  @override
  ConsumerState<MAiScreen> createState() => _MAiScreenState();
}

class _MAiScreenState extends ConsumerState<MAiScreen> {
  final input = TextEditingController();
  final scroll = ScrollController();
  final _lastBotKey = GlobalKey();
  bool loading = false;

  // 녹음
  VoiceRecorder? recorder;
  bool recording = false;
  Timer? _recTick;
  int _recMs = 0;
  List<double> _wave = List.filled(22, 6);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(chatMessages).isEmpty) {
        ref.read(chatMessages.notifier).state = [
          ChatMessage(
            AppConfig.isRemote
                ? '구룡가디언 AI예요. 지금 위험, 가까운 대피소, 가고 싶은 곳까지의 길을 물어보세요.'
                : '예시 AI 안내예요. 지금 위험과 대피소에 대해 물어보세요.',
            false,
          )
        ];
      }
      _jumpToEnd();
    });
  }

  void _jumpToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
      });

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) {
          scroll.animateTo(scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
        }
      });

  /// 새 답이 오면 답의 첫 줄이 화면 위쪽에 오게 (긴 답을 처음부터 읽도록 — 디자인)
  void _scrollToAnswer() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _lastBotKey.currentContext;
        if (ctx == null) return _scrollToEnd();
        Scrollable.ensureVisible(ctx,
            alignment: 0, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
      });

  void _add(List<ChatMessage> m) => ref.read(chatMessages.notifier).state = [...ref.read(chatMessages), ...m];

  void _addAnswer(ChatAnswer answer, String question) {
    _add([ChatMessage(answer.text, false, answer: answer)]);
    final kind = cardFor(question);
    if (kind != null && answer.isError != true) {
      ref.read(chatCards.notifier).state = {...ref.read(chatCards), ref.read(chatMessages).length - 1: kind};
    }
    _scrollToAnswer();
  }

  Future<void> send([String? q]) async {
    final question = (q ?? input.text).trim();
    if (question.isEmpty || loading) return;
    _add([ChatMessage(question, true)]);
    setState(() {
      loading = true;
      input.clear();
    });
    _scrollToEnd();
    try {
      final answer = await ref.read(repo).ask(question, UserMode.user, ref.read(userLocation).position);
      if (mounted) _addAnswer(answer, question);
    } catch (_) {
      if (mounted) {
        _addAnswer(
            const ChatAnswer('AI 서비스에 연결하지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요.', isError: true),
            question);
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------------------------------------------------------------- 음성 입력
  Future<void> startRec() async {
    if (loading || recording) return;
    await VoicePlayer.instance.stop();
    recorder ??= VoiceRecorder();
    final ok = await recorder!.start(onLimit: stopRec);
    if (!mounted) return;
    if (!ok) {
      showDsToast(context, '마이크 권한이 필요해요. 브라우저·기기 설정에서 허용해 주세요.');
      return;
    }
    final t0 = DateTime.now();
    setState(() {
      recording = true;
      _recMs = 0;
    });
    _recTick = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      final ms = DateTime.now().difference(t0).inMilliseconds;
      final rnd = math.Random();
      setState(() {
        _recMs = ms;
        // 소리 크기를 흉내 낸 파형 (실제 음량과 무관)
        _wave = [
          for (var i = 0; i < 22; i++)
            math.max(4, (6 + rnd.nextDouble() * 28) * (0.55 + 0.45 * math.sin(ms / 260 + i * .55)))
        ];
      });
      if (ms > 30000) stopRec();
    });
  }

  Future<void> stopRec() async {
    if (!recording) return;
    _recTick?.cancel();
    setState(() {
      recording = false;
      loading = true;
    });
    final wav = await recorder!.stop();
    if (wav == null) {
      if (mounted) {
        setState(() => loading = false);
        showDsToast(context, '녹음이 너무 짧아요. 마이크를 누르고 말씀한 뒤 네모 버튼을 눌러 주세요.');
      }
      return;
    }
    ChatAnswer? answer;
    try {
      final v = await ref.read(repo).askVoice(wav, UserMode.user, ref.read(userLocation).position);
      answer = v.answer;
      if (mounted) {
        _add([ChatMessage(v.transcript, true)]);
        _addAnswer(v.answer, v.transcript);
      }
    } catch (e) {
      if (mounted) {
        showDsToast(context, e is RemoteError ? e.message : '음성 입력을 쓸 수 없어요. 글자로 물어봐 주세요.');
      }
    }
    if (mounted) setState(() => loading = false);
    if (answer?.audio != null) {
      try {
        await VoicePlayer.instance.play(answer!.audio!);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _recTick?.cancel();
    recorder?.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final messages = ref.watch(chatMessages);
    final cards = ref.watch(chatCards);
    final lastBot = messages.lastIndexWhere((m) => !m.mine);
    return WebWidth(
        enabled: MediaQuery.sizeOf(c).width >= wideBreakpoint,
        maxWidth: 900,
        child: Column(children: [
      Expanded(
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const ScreenTitle('AI 대화창'),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                  AppConfig.isRemote
                      ? '실시간 데이터 기반 AI 답변이에요 · 공식 재난 안내도 함께 확인하세요.'
                      : '예시 데이터 기반 답변이에요 · 실제 재난 지시가 아니에요.',
                  style: dsText(13, color: Ds.muted)),
            ),
            for (final (i, m) in messages.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: m.mine
                    ? _UserBubble(text: m.text)
                    : _BotMessage(
                        key: i == lastBot ? _lastBotKey : null,
                        message: m,
                        card: cards[i],
                        retry: m.answer?.isError == true
                            ? () {
                                for (var j = i - 1; j >= 0; j--) {
                                  if (messages[j].mine) {
                                    send(messages[j].text);
                                    return;
                                  }
                                }
                              }
                            : null,
                      ),
              ),
            if (loading)
              Row(children: [
                const _Mascot(),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(15),
                          bottomLeft: Radius.circular(15),
                          bottomRight: Radius.circular(15))),
                  child: Text('답변을 준비하고 있어요…', style: dsText(15, color: Ds.muted)),
                ),
              ]),
          ],
        ),
      ),
      // 하단: 추천 질문 + 입력 pill
      Container(
        color: Ds.bg,
        padding: const EdgeInsets.only(top: 8, bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              const FaIcon(FontAwesomeIcons.wandMagicSparkles, size: 13, color: Ds.navy),
              const SizedBox(width: 6),
              Text('내 정보에 맞춘 추천 질문', style: dsText(14, weight: FontWeight.w700, color: Ds.navy)),
            ]),
          ),
          HScroll(
            gap: 8,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final q in suggestedQuestions)
                Material(
                  color: Colors.white,
                  shape: const StadiumBorder(side: BorderSide(color: Ds.navy, width: 2)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: loading ? null : () => send(q),
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      child: Text(q, style: dsText(16, weight: FontWeight.w700, color: Ds.navy)),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: recording ? _recordingBar() : _inputBar(),
          ),
        ]),
      ),
    ]));
  }

  Widget _inputBar() => Container(
        height: 60,
        padding: const EdgeInsets.only(left: 18, right: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Ds.pill)),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: input,
              onSubmitted: send,
              style: dsText(17),
              decoration: const InputDecoration(
                hintText: '무엇이든 물어보세요',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          CircleButton(FontAwesomeIcons.microphone,
              size: 46, iconSize: 17, bg: Ds.soft, tooltip: '음성 입력', onPressed: loading ? null : startRec),
          const SizedBox(width: 6),
          loading
              ? const SizedBox(
                  width: 46,
                  height: 46,
                  child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.5)))
              : CircleButton(FontAwesomeIcons.arrowUp,
                  size: 46, iconSize: 18, bg: Ds.navy, fg: Colors.white, tooltip: '보내기', onPressed: () => send()),
        ]),
      );

  Widget _recordingBar() {
    final sec = _recMs ~/ 1000;
    return Semantics(
      label: '음성 녹음 중',
      child: Container(
        height: 60,
        padding: const EdgeInsets.only(left: 16, right: 6),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(Ds.pill),
            border: Border.all(color: Ds.danger, width: 2)),
        child: Row(children: [
          Opacity(
            opacity: (_recMs ~/ 500).isOdd ? .3 : 1,
            child: Container(
                width: 10, height: 10, decoration: const BoxDecoration(color: Ds.danger, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 10),
          Text('0:${'$sec'.padLeft(2, '0')}',
              style: dsText(15, weight: FontWeight.w800, color: Ds.danger)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 36,
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (final h in _wave)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 3,
                    height: h,
                    decoration: BoxDecoration(color: Ds.navy, borderRadius: BorderRadius.circular(2)),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: '녹음 끝내기',
            child: Material(
              color: Ds.danger,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: stopRec,
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: Center(
                    child: Container(
                        width: 16,
                        height: 16,
                        decoration:
                            BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3))),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Mascot extends StatelessWidget {
  const _Mascot();
  @override
  Widget build(BuildContext context) => ClipOval(
        child: Image.asset('assets/images/mascot.png',
            width: 31, height: 31, fit: BoxFit.cover, semanticLabel: 'AI 캐릭터'),
      );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: const BoxDecoration(
                color: Ds.navy,
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(15),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(15),
                    bottomRight: Radius.circular(15))),
            child: Text(text, style: dsText(15, color: Colors.white, height: 1.5)),
          ),
        ),
      );
}

class _BotMessage extends ConsumerWidget {
  const _BotMessage({super.key, required this.message, this.card, this.retry});
  final ChatMessage message;
  final String? card;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = message.answer;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Mascot(),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(15),
                    bottomLeft: Radius.circular(15),
                    bottomRight: Radius.circular(15))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(message.text, style: dsText(15, height: 1.55)),
              if (retry != null)
                TextButton.icon(
                    onPressed: retry,
                    icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 14),
                    label: const Text('다시 시도')),
              if (a != null && a.isError != true)
                Align(
                    alignment: Alignment.centerLeft,
                    child: VoiceButton(text: a.voiceText ?? message.text, audio: a.audio)),
            ]),
          ),
          if (a?.route != null) ...[const SizedBox(height: 10), _RouteCard(answer: a!)],
          if (card == 'checklist') ...[const SizedBox(height: 10), const _ChecklistCard()],
          if (card == 'typhoon') ...[const SizedBox(height: 10), const _TyphoonCard()],
          if (card == 'support') ...[
            const SizedBox(height: 10),
            PillButton('지원·복구 안내 보기',
                icon: FontAwesomeIcons.handHoldingHeart,
                height: 48,
                fontSize: 16,
                outlined: true,
                onPressed: () => context.push('/support')),
          ],
        ]),
      ),
    ]);
  }
}

/// 경로가 있는 답: 지도 자리 + '경로 안내 화면 보기' → 대시보드 지도 전체화면
class _RouteCard extends ConsumerWidget {
  const _RouteCard({required this.answer});
  final ChatAnswer answer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = answer.route!;
    final km = r.distanceMeters >= 1000 ? '${(r.distanceMeters / 1000).toStringAsFixed(1)}km' : '${r.distanceMeters}m';
    return AppCard(
      padding: const EdgeInsets.all(10),
      child: Column(children: [
        Container(
          height: 110,
          decoration: BoxDecoration(color: Ds.bg, borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const IconCircle(FontAwesomeIcons.diamondTurnRight, size: 52, iconSize: 22, bg: Ds.navy, fg: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('현위치 → ${answer.destinationName ?? '목적지'}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: dsText(15, weight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('${r.mode.label} ${r.estimatedMinutes}분 · $km · ${r.routeType.label}',
                    style: dsText(14, color: Ds.muted)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        PillButton('경로 안내 화면 보기',
            icon: FontAwesomeIcons.diamondTurnRight,
            onPressed: () {
              showAiRoute(ref, answer);
              ref.read(dashMapFull.notifier).state = true;
              context.go('/');
            }),
      ]),
    );
  }
}

class _ChecklistCard extends ConsumerWidget {
  const _ChecklistCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checks = ref.watch(checklistProvider);
    final done = checks.where((x) => x).length;
    return AppCard(
      radius: 15,
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
          child: Row(children: [
            Expanded(child: Text('지금 할 일', style: dsText(14, weight: FontWeight.w800))),
            Text('$done / ${typhoonChecklist.length} 완료', style: dsText(13, weight: FontWeight.w700, color: Ds.muted)),
          ]),
        ),
        for (final (i, t) in typhoonChecklist.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              checked: checks[i],
              child: Material(
                color: Ds.bg,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => ref.read(checklistProvider.notifier).toggle(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                            color: checks[i] ? Ds.navy : Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: Ds.navy, width: 2)),
                        alignment: Alignment.center,
                        child: checks[i] ? const FaIcon(FontAwesomeIcons.check, size: 11, color: Colors.white) : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(t,
                            style: dsText(14, weight: FontWeight.w700, color: checks[i] ? Ds.muted : Ds.ink, height: 1.4)
                                .copyWith(decoration: checks[i] ? TextDecoration.lineThrough : null)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// 태풍 요약 (실측: 서버 typhoon 위젯 · 시연: 예시). 진행 중인 태풍이 없으면 그렇게 알린다
class _TyphoonCard extends ConsumerWidget {
  const _TyphoonCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = !AppConfig.isRemote;
    final t = demo ? null : dashWidget(ref.watch(liveDashboardProvider).valueOrNull, 'typhoon');
    final live = t != null && t['available'] != false;
    if (!demo && !live) {
      return AppCard(
        radius: 15,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const IconCircle(FontAwesomeIcons.hurricane, size: 34, iconSize: 15),
          const SizedBox(width: 8),
          Expanded(child: Text('${t?['reason'] ?? '지금 진행 중인 태풍이 없어요'}', style: dsText(14, weight: FontWeight.w700))),
        ]),
      );
    }
    final cur = Map<String, dynamic>.from((t?['current'] as Map?) ?? const {});
    final name = demo ? '힌남노' : '${t!['name_ko'] ?? t['code'] ?? '태풍'}';
    final sub = demo ? '제11호 태풍 (예시)' : '태풍 · 구룡포에서 ${t!['distance_km'] ?? '-'}km';
    final eta = demo ? '내일 오전 7시' : hhmm(t!['eta_closest']);
    final stats = demo
        ? const [('중심기압', '950hPa'), ('최대풍속', '43m/s'), ('최근접', '30km')]
        : [
            ('중심기압', cur['pressure'] == null ? '-' : '${fmtNum(cur['pressure'], 0)}hPa'),
            ('최대풍속', '${fmtNum(cur['max_wind_ms'], 0)}m/s'),
            ('최근접', '${t!['closest_km'] ?? '-'}km'),
          ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Ds.navy, borderRadius: BorderRadius.circular(15)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconCircle(FontAwesomeIcons.hurricane, size: 34, iconSize: 16, bg: Colors.white, fg: Ds.navy),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sub, style: dsText(11, color: Colors.white.withValues(alpha: .85))),
            Text(name, style: dsText(17, weight: FontWeight.w800, color: Colors.white, height: 1.15)),
          ]),
        ]),
        const SizedBox(height: 10),
        Text('구룡포 최근접 예상', style: dsText(12, weight: FontWeight.w800, color: Colors.white)),
        Text(eta, style: dsText(22, weight: FontWeight.w800, color: Colors.white, spacing: -.4)),
        const SizedBox(height: 8),
        Row(children: [
          for (final (i, st) in stats.indexed) ...[
            if (i > 0) const SizedBox(width: 5),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(st.$1, style: dsText(11, color: Colors.white.withValues(alpha: .85))),
                  Text(st.$2, style: dsText(14, weight: FontWeight.w800, color: Colors.white)),
                ]),
              ),
            ),
          ]
        ]),
        const SizedBox(height: 10),
        PillButton('태풍 경로 자세히 보기',
            icon: FontAwesomeIcons.mapLocationDot,
            height: 46,
            fontSize: 15,
            bg: Colors.white,
            fg: Ds.navy,
            onPressed: () => context.push('/typhoon')),
      ]),
    );
  }
}

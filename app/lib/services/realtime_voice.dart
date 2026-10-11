import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'realtime_link.dart';
import 'voice_conversation.dart';

/// 서버가 준 실시간 음성 세션 (ai `POST /api/voice/session`): OpenAI 임시 키와 약속한 도구 이름
class RealtimeSession {
  const RealtimeSession(
      {required this.clientSecret,
      required this.callsUrl,
      required this.askTool,
      required this.endTool,
      required this.readOutPrefix});

  factory RealtimeSession.fromJson(Map<String, dynamic> j) => RealtimeSession(
      clientSecret: j['client_secret'] as String,
      callsUrl: j['calls_url'] as String,
      askTool: j['ask_tool'] as String,
      endTool: j['end_tool'] as String,
      readOutPrefix: j['read_out_prefix'] as String);

  final String clientSecret, callsUrl, askTool, endTool, readOutPrefix;
}

/// 실시간 음성 대화 (2026-10-11, OpenAI Realtime `gpt-realtime-2`): 모델이 듣고 말하고, **답 내용은 LangGraph가 만든다**.
/// - 모델은 사용자가 말할 때마다 도구만 부른다 (서버 세션 설정 tool_choice=required).
///   `ask_guardian(question)` → [ask]가 `/api/chat`으로 답을 받아 대화창에 붙이고 음성 문장을 돌려준다 →
///   그 문장을 "그대로 읽어라"는 지시로 모델에게 읽힌다. `end_conversation` → 인사하고 끝.
/// - 말 끝 감지·끼어들기는 모델(서버)이 한다. 화면 상태만 이벤트로 따라간다.
/// - 한동안([idleLimit]) 아무 말이 없으면 마이크를 열어 둔 채 두지 않고 끝낸다.
/// 웹에서만 된다 ([RealtimeLink]). 시작하지 못하면 [start]가 false → 녹음 올리기 방식으로 넘어간다 (VoiceHub).
class RealtimeVoice extends StateNotifier<VoiceState> {
  RealtimeVoice({
    required this.openSession,
    required this.ask,
    required this.say,
    RealtimeLink? Function()? link,
    this.idleLimit = const Duration(seconds: 60),
  })  : _newLink = link ?? createRealtimeLink,
        super(VoiceState.off);

  /// 서버에서 세션을 받는다. 실시간 음성을 쓸 수 없으면 null (목업·서버 503)
  final Future<RealtimeSession?> Function() openSession;

  /// 질문을 LangGraph에 묻고 (질문·답 말풍선도 붙이고) 읽을 문장을 돌려준다
  final Future<String> Function(String question) ask;

  /// 대화창에 안내 한 줄 (끝난 이유)
  final void Function(String text) say;
  final RealtimeLink? Function() _newLink;
  final Duration idleLimit;

  static const endReply = '네, 음성 대화를 마칠게요.';

  RealtimeLink? _link;
  RealtimeSession? _session;
  Timer? _idle;
  bool _active = false, _ending = false, _speaking = false;
  int _asking = 0;
  int _round = 0;
  Future<void> _queue = Future.value(); // 도구 호출은 온 순서대로 하나씩

  bool get active => _active;

  /// 시작. 웹이 아니거나, 서버가 세션을 주지 않거나, 마이크·연결에 실패하면 false.
  Future<bool> start() async {
    if (_active) return true;
    final link = _newLink();
    if (link == null) return false;
    _active = true;
    final round = ++_round;
    try {
      final session = await openSession();
      if (session == null || round != _round) {
        if (round == _round) _active = false;
        return false;
      }
      _session = session;
      _link = link;
      await link.connect(
          callsUrl: session.callsUrl,
          clientSecret: session.clientSecret,
          onEvent: (e) {
            if (round == _round) _onEvent(e);
          },
          onClosed: () {
            if (round == _round && _active) _close('연결이 끊겨 음성 대화를 마쳤어요. 다시 하려면 마이크를 눌러 주세요.');
          });
    } catch (_) {
      await link.close();
      if (round == _round) _reset();
      return false;
    }
    if (round != _round) {
      await link.close(); // 연결하는 사이 중지를 눌렀다
      return true;
    }
    _ending = _speaking = false;
    _asking = 0;
    state = VoiceState.listening;
    _touch();
    return true;
  }

  /// 중지 버튼: 마이크·연결을 닫고 나오던 말도 멈춘다.
  Future<void> stop() => _close(null);

  Future<void> _close(String? notice) async {
    if (!_active) return;
    _round++;
    final link = _link;
    _reset();
    if (notice != null) say(notice);
    await link?.close();
  }

  void _reset() {
    _active = false;
    _idle?.cancel();
    _link = null;
    _session = null;
    if (mounted) state = VoiceState.off;
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(idleLimit, () {
      if (_asking > 0 || _speaking) return _touch(); // 답을 만들거나 말하는 중은 조용한 것이 아니다
      _close('말씀이 없어 음성 대화를 마쳤어요. 다시 하려면 마이크를 눌러 주세요.');
    });
  }

  void _show() {
    if (!_active) return;
    state = _asking > 0 ? VoiceState.thinking : (_speaking ? VoiceState.speaking : VoiceState.listening);
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'input_audio_buffer.speech_started': // 사용자가 말하기 시작 (모델이 말하던 중이면 서버가 멈춘다)
        _speaking = false;
        _touch();
        _show();
      case 'output_audio_buffer.started':
        _speaking = true;
        _touch();
        _show();
      case 'output_audio_buffer.stopped' || 'output_audio_buffer.cleared':
        _speaking = false;
        _touch();
        if (_ending) {
          _close('음성 대화를 마쳤어요.');
        } else {
          _show();
        }
      case 'response.done':
        final output = (e['response'] as Map?)?['output'];
        if (output is! List) return;
        for (final item in output) {
          if (item is Map && item['type'] == 'function_call') _onCall(Map<String, dynamic>.from(item));
        }
    }
  }

  void _onCall(Map<String, dynamic> call) {
    final session = _session;
    if (session == null) return;
    final round = _round;
    final callId = call['call_id'];
    if (call['name'] == session.endTool) {
      _ending = true;
      _reply(callId, endReply);
      // 인사 소리가 끝나면(output_audio_buffer.stopped) 닫는다. 소리가 오지 않아도 닫히게 한 번 더 본다
      Timer(const Duration(seconds: 8), () {
        if (round == _round && _ending) _close('음성 대화를 마쳤어요.');
      });
      return;
    }
    var question = '';
    try {
      question = ((jsonDecode(call['arguments'] as String? ?? '{}') as Map)['question'] as String? ?? '').trim();
    } catch (_) {}
    _asking++;
    _show();
    _queue = _queue.then((_) async {
      var text = '죄송해요, 잘 듣지 못했어요. 다시 말씀해 주세요.';
      if (question.isNotEmpty && round == _round) {
        try {
          text = await ask(question);
        } catch (_) {
          text = '지금은 답을 가져오지 못했어요. 잠시 후 다시 말씀해 주세요.';
        }
      }
      if (round != _round) return;
      _asking--;
      _reply(callId, text);
      _touch();
      _show();
    });
  }

  /// 도구 결과를 돌려주고, 그 문장을 그대로 읽게 한다 (이번 응답은 도구를 부르지 않는다)
  void _reply(Object? callId, String text) {
    final link = _link, session = _session;
    if (link == null || session == null) return;
    link.send({
      'type': 'conversation.item.create',
      'item': {'type': 'function_call_output', 'call_id': callId, 'output': jsonEncode({'answer': text})}
    });
    link.send({
      'type': 'response.create',
      'response': {'tool_choice': 'none', 'instructions': '${session.readOutPrefix}$text'}
    });
  }

  @override
  void dispose() {
    _round++;
    _idle?.cancel();
    _link?.close();
    super.dispose();
  }
}

/// 마이크 버튼이 부르는 창구: 실시간 음성(웹)을 먼저 해 보고, 안 되면 녹음 올리기 방식([VoiceConversation])으로.
/// 화면은 이 상태 하나만 본다.
class VoiceHub extends StateNotifier<VoiceState> {
  VoiceHub({required this.realtime, required this.upload}) : super(VoiceState.off) {
    _subs = [realtime.addListener(_from(true)), upload.addListener(_from(false))];
  }

  final RealtimeVoice realtime;
  final VoiceConversation upload;
  late final List<void Function()> _subs;
  bool _realtime = true;

  void Function(VoiceState) _from(bool isRealtime) => (s) {
        if (mounted && isRealtime == _realtime) state = s;
      };

  bool get active => realtime.active || upload.active;

  /// 마이크 권한이 없어 어느 쪽도 시작하지 못하면 false
  Future<bool> start() async {
    if (active) return true;
    _realtime = true;
    if (await realtime.start()) return true;
    _realtime = false;
    return upload.start();
  }

  Future<void> stop() async {
    await realtime.stop();
    await upload.stop();
  }

  @override
  void dispose() {
    for (final cancel in _subs) {
      cancel();
    }
    super.dispose();
  }
}

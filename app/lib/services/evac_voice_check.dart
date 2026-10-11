import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'realtime_link.dart';

/// 시각장애인 대피 음성 확인 (B12, 2026-10-12) — OpenAI Realtime(`gpt-realtime-2`)이 묻고 듣는다.
///
/// - [check]: 대피 경보가 울리면 "대피 완료, 대피 중, 도움 필요 중 하나"를 묻고, 모델이 `set_evacuation_status`를 부르면
///   [check]의 save(서버 POST /alerts/{id}/response via=voice)로 저장한 뒤 그 결과 문장을 그대로 읽게 하고 끝낸다.
///   [answerTimeout] 동안 대답이 없으면 한 번 더 묻고, 그래도 없으면 [EvacVoiceResult.noAnswer] → 화면은 사이렌·버튼으로 돌아간다.
/// - [announce]: 방재단 배정 안내(서버 FCM responder_assigned 의 tts_text)처럼 정해진 문장을 마이크 없이 한 번 읽는다.
/// - Google 음성(받아쓰기·합성, flutter_tts)은 쓰지 않는다. 연결하지 못하면 [EvacVoiceResult.unavailable] — 음성 없이 버튼만.
/// 세션은 ai `POST /api/voice/evac-session` (ai/guardian_ai/realtime.py evac_session_config).
class EvacVoiceSession {
  const EvacVoiceSession(
      {required this.clientSecret,
      required this.callsUrl,
      required this.statusTool,
      required this.endTool,
      required this.readOutPrefix});

  factory EvacVoiceSession.fromJson(Map<String, dynamic> j) => EvacVoiceSession(
      clientSecret: j['client_secret'] as String,
      callsUrl: j['calls_url'] as String,
      statusTool: j['status_tool'] as String,
      endTool: j['end_tool'] as String,
      readOutPrefix: j['read_out_prefix'] as String? ?? '');

  final String clientSecret, callsUrl, statusTool, endTool, readOutPrefix;
}

enum EvacVoiceResult { saved, noAnswer, unavailable, stopped }

/// 서버 응답값 (EvacuationResponseStatus.wireValue 와 같다)
const evacVoiceStatuses = {'evacuated', 'evacuating', 'need_help'};

class EvacVoiceCheck {
  EvacVoiceCheck({
    required this.openSession,
    RealtimeLink? Function()? link,
    this.answerTimeout = const Duration(seconds: 45),
    this.readOutLimit = const Duration(seconds: 20),
  }) : _newLink = link ?? createRealtimeLink;

  /// mode: evac_check | announce. 쓸 수 없으면 null (서버 503·키 없음·꺼짐)
  final Future<EvacVoiceSession?> Function(String mode, {String alertText, String announceText}) openSession;
  final RealtimeLink? Function() _newLink;

  /// 대답을 기다리는 시간 (한 번 더 묻고 같은 시간을 더 기다린다)
  final Duration answerTimeout;

  /// 마지막 문장을 읽는 소리가 오지 않아도 연결을 닫을 때까지
  final Duration readOutLimit;

  RealtimeLink? _link;
  int _round = 0;
  void Function(EvacVoiceResult)? _finish; // 진행 중인 check 를 [stop]이 끝낼 때

  /// 지금 마이크를 열고 대답을 기다리는 중인지 (저장 뒤 확인 문장을 읽는 중은 아님)
  bool get listening => _listening;
  bool _listening = false;

  /// 경보 화면이 대피 음성 확인을 쓸 사용자인지 — 내 정보에서 '시각장애'를 고른 사람
  /// (prototype_safety_store.dart AccessibilitySettings.visionSupport). FCM 백그라운드 isolate 에서도 읽는다
  static Future<bool> visionSupportSaved() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('prototype_accessibility_v1');
      return raw != null && (jsonDecode(raw) as Map)['visionSupport'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 대피 상태를 음성으로 묻고 저장한다. [save]는 저장 결과를 사람에게 읽어 줄 문장으로 돌려준다.
  Future<EvacVoiceResult> check({
    required String alertText,
    required Future<String> Function(String status, String transcript) save,
  }) async {
    await stop();
    final round = ++_round;
    final link = _newLink();
    if (link == null) return EvacVoiceResult.unavailable;
    final session = await _open('evac_check', alertText: alertText);
    if (session == null || round != _round) return EvacVoiceResult.unavailable;

    final done = Completer<EvacVoiceResult>();
    void finish(EvacVoiceResult r) {
      if (!done.isCompleted) done.complete(r);
    }

    _finish = finish;

    Timer? answer;
    var reprompted = false, saving = false, ending = false;

    void closeLater() => Timer(readOutLimit, () {
          if (round == _round) unawaited(stop());
        });

    void waitAnswer() {
      answer?.cancel();
      answer = Timer(answerTimeout, () {
        if (round != _round || saving) return;
        if (!reprompted) {
          reprompted = true;
          link.send({
            'type': 'response.create',
            'response': {
              'instructions': '주민이 아직 대답하지 않았다. "대피 완료, 대피 중, 도움 필요 중에서 하나를 말씀해 주세요."라고 다시 묻는다.'
            }
          });
          waitAnswer();
        } else {
          finish(EvacVoiceResult.noAnswer);
          unawaited(stop());
        }
      });
    }

    Future<void> onCall(Map<String, dynamic> call) async {
      final callId = call['call_id'];
      if (call['name'] == session.endTool) {
        if (!saving) finish(EvacVoiceResult.noAnswer); // 고르지 않고 끝냄 → 버튼으로
        if (!ending) unawaited(stop());
        return;
      }
      if (call['name'] != session.statusTool || saving) return;
      var status = '', transcript = '';
      try {
        final args = jsonDecode(call['arguments'] as String? ?? '{}') as Map;
        status = '${args['status'] ?? ''}';
        transcript = '${args['transcript'] ?? ''}'.trim();
      } catch (_) {}
      if (!evacVoiceStatuses.contains(status)) return;
      saving = true;
      _listening = false;
      answer?.cancel();
      String text;
      try {
        text = await save(status, transcript);
      } catch (_) {
        text = '상태를 저장하지 못했어요. 화면의 버튼을 눌러 주세요.';
      }
      if (round != _round) return;
      finish(EvacVoiceResult.saved);
      ending = true;
      _reply(link, session, callId, text);
      closeLater();
    }

    _link = link;
    try {
      await link.connect(
        callsUrl: session.callsUrl,
        clientSecret: session.clientSecret,
        onEvent: (e) {
          if (round != _round) return;
          switch (e['type']) {
            case 'input_audio_buffer.speech_started':
              if (!saving) waitAnswer(); // 말하는 중에는 기다림을 늘린다
            case 'output_audio_buffer.stopped':
              if (ending) unawaited(stop());
            case 'response.done':
              final output = (e['response'] as Map?)?['output'];
              if (output is! List) return;
              for (final item in output) {
                if (item is Map && item['type'] == 'function_call') unawaited(onCall(Map<String, dynamic>.from(item)));
              }
          }
        },
        onClosed: () {
          if (round != _round) return;
          answer?.cancel();
          _reset();
          finish(EvacVoiceResult.stopped);
        },
      );
    } catch (_) {
      await link.close();
      if (round == _round) _reset();
      return EvacVoiceResult.unavailable;
    }
    if (round != _round) {
      await link.close();
      return EvacVoiceResult.stopped;
    }
    _listening = true;
    link.send({'type': 'response.create'}); // 모델이 먼저 경보를 알리고 묻는다 (세션 지시 1번)
    waitAnswer();
    final result = await done.future;
    answer?.cancel();
    return result;
  }

  /// 정해진 문장을 마이크 없이 한 번 읽는다. 다 읽으면(또는 [readOutLimit]) true, 연결하지 못하면 false
  Future<bool> announce(String text) async {
    if (text.trim().isEmpty) return false;
    await stop();
    final round = ++_round;
    final link = _newLink();
    if (link == null) return false;
    final session = await _open('announce', announceText: text);
    if (session == null || round != _round) return false;
    final done = Completer<void>();
    _finish = (_) {
      if (!done.isCompleted) done.complete();
    };
    _link = link;
    var spoke = false;
    try {
      await link.connect(
        callsUrl: session.callsUrl,
        clientSecret: session.clientSecret,
        microphone: false,
        onEvent: (e) {
          if (round != _round) return;
          if (e['type'] == 'output_audio_buffer.started') spoke = true;
          if (e['type'] == 'output_audio_buffer.stopped' && spoke) unawaited(stop());
        },
        onClosed: () {
          if (round == _round) unawaited(stop());
        },
      );
    } catch (_) {
      await link.close();
      if (round == _round) _reset();
      return false;
    }
    if (round != _round) {
      await link.close();
      return false;
    }
    link.send({'type': 'response.create'}); // 세션 지시: 받은 문장을 그대로 한 번 읽는다
    final limit = Timer(readOutLimit, () {
      if (round == _round) unawaited(stop());
    });
    await done.future;
    limit.cancel();
    return true;
  }

  /// 마이크·연결을 닫는다 (경보 화면을 닫거나 버튼으로 응답했을 때)
  Future<void> stop() async {
    _round++;
    final link = _link, finish = _finish;
    _finish = null;
    _reset();
    finish?.call(EvacVoiceResult.stopped);
    await link?.close();
  }

  void _reset() {
    _link = null;
    _listening = false;
  }

  Future<EvacVoiceSession?> _open(String mode, {String alertText = '', String announceText = ''}) async {
    try {
      return await openSession(mode, alertText: alertText, announceText: announceText);
    } catch (_) {
      return null;
    }
  }

  /// 도구 결과를 돌려주고 그 문장을 그대로 읽게 한다 (이번 응답은 도구를 부르지 않는다)
  void _reply(RealtimeLink link, EvacVoiceSession session, Object? callId, String text) {
    link.send({
      'type': 'conversation.item.create',
      'item': {'type': 'function_call_output', 'call_id': callId, 'output': jsonEncode({'result': text})}
    });
    link.send({
      'type': 'response.create',
      'response': {'tool_choice': 'none', 'instructions': '${session.readOutPrefix}$text'}
    });
  }
}

/// 저장 결과 → 읽어 줄 문장 (서버 응답 message 와 같은 뜻, 음성용으로 짧게)
String evacVoiceSavedText(String status, {bool queued = false}) {
  if (queued) return '인터넷이 끊겨 휴대폰에 저장해 두었어요. 연결되면 바로 보낼게요.';
  return switch (status) {
    'evacuated' => '대피 완료로 저장했어요. 안전한 곳에 계세요.',
    'evacuating' => '대피 중으로 저장했어요. 조심해서 이동하세요. 10분 뒤에 다시 여쭤볼게요.',
    'need_help' => '도움 필요로 저장했어요. 방재단에 바로 알렸어요. 그 자리에서 기다려 주세요. 위급하면 119에 전화하세요.',
    _ => '저장했어요.',
  };
}

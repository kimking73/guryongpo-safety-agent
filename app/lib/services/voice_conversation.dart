import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_service.dart';

/// 연속 음성 대화의 지금 상태 (화면의 마이크 칸이 본다)
enum VoiceState { off, listening, thinking, speaking }

/// 음성 질문 한 번의 결과
enum VoiceTurn {
  /// 답을 받았다 (답 음성 재생까지 끝남)
  answered,

  /// 말을 알아듣지 못했다 (서버 422)
  notHeard,

  /// 사용자가 "그만" 등으로 끝내자고 했다 (서버 end_conversation)
  ended,

  /// 서버·네트워크 오류, 음성 기능 꺼짐
  failed,
}

/// 녹음기 (테스트에서 가짜로 바꾼다). 실제는 [VoiceRecorder]
abstract class VoiceInput {
  Future<bool> start({void Function()? onLimit, void Function()? onSpeechEnd, void Function()? onNoSpeech});
  Future<Uint8List?> stop();
}

class _MicInput implements VoiceInput {
  final _rec = VoiceRecorder();
  @override
  Future<bool> start({void Function()? onLimit, void Function()? onSpeechEnd, void Function()? onNoSpeech}) =>
      _rec.start(onLimit: onLimit, onSpeechEnd: onSpeechEnd, onNoSpeech: onNoSpeech);
  @override
  Future<Uint8List?> stop() => _rec.stop();
}

enum _Heard { speech, nothing, stopped }

/// 손 안 대는 연속 음성 대화 (2026-10-11): 마이크를 한 번 누르면
/// 듣기 → 말이 끝나면 자동 전송 → 답 음성 재생 → 다시 듣기를 되풀이한다.
/// 끝나는 때: [stop](중지 버튼), "그만" 같은 끝내는 말, 말이 없거나 못 알아들은 것이 연속 [maxMisses]번, 오류.
/// 답 음성을 재생하는 동안에는 녹음하지 않는다 (자기 목소리를 질문으로 듣지 않게).
/// 앱 전체에 하나라 다른 메뉴로 가도 이어진다 (main.dart `voiceConversation`).
class VoiceConversation extends StateNotifier<VoiceState> {
  VoiceConversation({required this.ask, required this.say, VoiceInput Function()? input, this.stopPlayback})
      : _newInput = input ?? _MicInput.new,
        super(VoiceState.off);

  /// 녹음(WAV)으로 질문하고 답 음성 재생까지 끝낸 뒤 결과를 돌려준다. [onSpeaking]은 답 음성을 틀기 시작할 때,
  /// [shouldPlay]가 false면 답 음성을 틀지 않는다 (그 사이 중지를 누른 경우).
  final Future<VoiceTurn> Function(Uint8List wav, {void Function()? onSpeaking, bool Function()? shouldPlay}) ask;

  /// 대화창에 안내 한 줄 (끝난 이유)
  final void Function(String text) say;
  final Future<void> Function()? stopPlayback;
  final VoiceInput Function() _newInput;

  static const maxMisses = 2;
  VoiceInput? _input;
  Completer<_Heard>? _heard;
  bool _active = false;
  int _round = 0; // 중지 뒤 곧바로 다시 시작해도 앞 대화의 남은 처리가 끼어들지 않게

  bool get active => _active;

  /// 시작. 마이크 권한이 없으면 false (대화는 시작되지 않는다).
  Future<bool> start() async {
    if (_active) return true;
    _active = true;
    await stopPlayback?.call();
    _input ??= _newInput();
    if (!await _listen()) {
      _active = false;
      state = VoiceState.off;
      return false;
    }
    unawaited(_run(++_round));
    return true;
  }

  /// 중지 버튼: 듣던 것은 버리고, 나오던 답 음성도 멈춘다.
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    final listening = state == VoiceState.listening;
    _finish(_Heard.stopped);
    await stopPlayback?.call();
    if (!listening) state = VoiceState.off; // 듣는 중이었으면 _run이 녹음을 닫고 끈다
  }

  Future<bool> _listen() async {
    final heard = _heard = Completer<_Heard>();
    void done(_Heard h) {
      if (!heard.isCompleted) heard.complete(h);
    }

    final ok = await _input!.start(
        onLimit: () => done(_Heard.speech), onSpeechEnd: () => done(_Heard.speech), onNoSpeech: () => done(_Heard.nothing));
    if (ok && _active) state = VoiceState.listening;
    return ok;
  }

  void _finish(_Heard h) {
    final heard = _heard;
    if (heard != null && !heard.isCompleted) heard.complete(h);
  }

  Future<void> _run(int round) async {
    var misses = 0;
    try {
      while (true) {
        final heard = await _heard!.future;
        final wav = await _input!.stop();
        if (round != _round) return;
        if (!_active || heard == _Heard.stopped) break;
        var turn = VoiceTurn.notHeard;
        if (heard == _Heard.speech && wav != null) {
          state = VoiceState.thinking;
          turn = await ask(wav, onSpeaking: () {
            if (_active) state = VoiceState.speaking;
          }, shouldPlay: () => _active);
          if (round != _round) return;
          if (!_active) break;
        }
        if (turn == VoiceTurn.ended || turn == VoiceTurn.failed) break;
        misses = turn == VoiceTurn.answered ? 0 : misses + 1;
        if (misses >= maxMisses) {
          say('말씀이 없어 음성 대화를 마쳤어요. 다시 하려면 마이크를 눌러 주세요.');
          break;
        }
        if (!await _listen()) break;
      }
    } finally {
      if (round == _round) {
        _active = false;
        if (mounted) state = VoiceState.off;
      }
    }
  }
}

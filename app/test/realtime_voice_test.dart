// 실시간 음성 대화 (OpenAI Realtime + LangGraph): 도구 호출 → /api/chat 답 → 그대로 읽히기, 끝내기, 실패 시 녹음 올리기로
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/realtime_link.dart';
import 'package:guryongpo_safety/services/realtime_voice.dart';
import 'package:guryongpo_safety/services/voice_conversation.dart';

class FakeLink implements RealtimeLink {
  bool failConnect = false, closed = false;
  final sent = <Map<String, dynamic>>[];
  late void Function(Map<String, dynamic>) emit;
  late void Function() drop;
  String? secret;

  @override
  Future<void> connect({required callsUrl, required clientSecret, required onEvent, required onClosed}) async {
    if (failConnect) throw StateError('마이크 권한 없음');
    secret = clientSecret;
    emit = onEvent;
    drop = onClosed;
  }

  @override
  void send(Map<String, dynamic> event) => sent.add(event);

  @override
  Future<void> close() async => closed = true;
}

class NoMic implements VoiceInput {
  int starts = 0;
  @override
  Future<bool> start({onLimit, onSpeechEnd, onNoSpeech}) async {
    starts++;
    return true;
  }

  @override
  Future<Uint8List?> stop() async => null;
}

const session = RealtimeSession(
    clientSecret: 'ek_test', callsUrl: 'https://x/calls', askTool: 'ask_guardian', endTool: 'end_conversation', readOutPrefix: '그대로 읽어라:');

Map<String, dynamic> call(String name, [Map<String, dynamic> args = const {}, String id = 'c1']) => {
      'type': 'response.done',
      'response': {
        'output': [
          {'type': 'function_call', 'name': name, 'call_id': id, 'arguments': jsonEncode(args)}
        ]
      }
    };

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeLink link;
  late List<String> asked, said;
  late List<VoiceState> states;
  late RealtimeVoice voice;
  Completer<String>? hold;
  RealtimeSession? given;

  setUp(() {
    link = FakeLink();
    asked = [];
    said = [];
    states = [];
    hold = null;
    given = session;
    voice = RealtimeVoice(
        link: () => link,
        openSession: () async => given,
        say: said.add,
        ask: (q) async {
          asked.add(q);
          return hold?.future ?? '침수심이 230mm입니다.';
        });
    voice.addListener(states.add, fireImmediately: false);
  });

  tearDown(() => voice.stop());

  test('질문 도구 호출 → LangGraph 답을 도구 결과로 돌려주고 그대로 읽게 한다 (이 응답은 도구 금지)', () async {
    expect(await voice.start(), isTrue);
    expect([voice.state, link.secret], [VoiceState.listening, 'ek_test']);
    link.emit(call('ask_guardian', {'question': '지금 여기 침수 위험 있어?'}));
    expect(voice.state, VoiceState.thinking);
    await settle();
    expect(asked, ['지금 여기 침수 위험 있어?']);
    expect(link.sent[0]['item'], {
      'type': 'function_call_output',
      'call_id': 'c1',
      'output': jsonEncode({'answer': '침수심이 230mm입니다.'})
    });
    expect(link.sent[1], {
      'type': 'response.create',
      'response': {'tool_choice': 'none', 'instructions': '그대로 읽어라:침수심이 230mm입니다.'}
    });
    link.emit({'type': 'output_audio_buffer.started'});
    expect(voice.state, VoiceState.speaking);
    link.emit({'type': 'input_audio_buffer.speech_started'}); // 끼어들기
    expect(voice.state, VoiceState.listening);
  });

  test('답을 만드는 동안은 말소리 이벤트가 와도 "답을 만드는 중", 두 번째 질문은 차례대로', () async {
    hold = Completer<String>();
    await voice.start();
    link.emit(call('ask_guardian', {'question': '첫째'}));
    link.emit({'type': 'output_audio_buffer.started'}); // "확인해 볼게요" 같은 짧은 말
    link.emit({'type': 'output_audio_buffer.stopped'});
    expect(voice.state, VoiceState.thinking);
    link.emit(call('ask_guardian', {'question': '둘째'}, 'c2'));
    await settle();
    expect(asked, ['첫째']);
    hold!.complete('답');
    await settle();
    expect(asked, ['첫째', '둘째']);
    expect(link.sent.where((e) => e['type'] == 'response.create').length, 2);
    expect(voice.state, VoiceState.listening);
  });

  test('끝내기 도구 → 인사를 읽히고, 인사 소리가 끝나면 닫는다 (LangGraph는 부르지 않음)', () async {
    await voice.start();
    link.emit(call('end_conversation'));
    await settle();
    expect(asked, isEmpty);
    expect((link.sent[1]['response'] as Map)['instructions'], '그대로 읽어라:${RealtimeVoice.endReply}');
    expect(voice.active, isTrue);
    link.emit({'type': 'output_audio_buffer.started'});
    link.emit({'type': 'output_audio_buffer.stopped'});
    await settle();
    expect([voice.active, voice.state, link.closed], [false, VoiceState.off, true]);
    expect(said, ['음성 대화를 마쳤어요.']);
  });

  test('질문을 못 알아들었거나 답을 못 가져오면 사과 문장을 읽힌다', () async {
    await voice.start();
    link.emit(call('ask_guardian', {'question': '  '}));
    await settle();
    expect(asked, isEmpty);
    expect((link.sent[1]['response'] as Map)['instructions'], contains('다시 말씀해 주세요'));
  });

  test('중지·끊김·한동안 말 없음이면 닫는다', () async {
    await voice.start();
    await voice.stop();
    expect([voice.state, link.closed, said], [VoiceState.off, true, <String>[]]);

    link = FakeLink();
    await voice.start();
    link.drop();
    await settle();
    expect([voice.state, said.length], [VoiceState.off, 1]);

    link = FakeLink();
    final quick = RealtimeVoice(
        link: () => link, openSession: () async => session, say: said.add, ask: (q) async => q, idleLimit: const Duration(milliseconds: 30));
    await quick.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect([quick.state, link.closed, said.length], [VoiceState.off, true, 2]);
  });

  test('실시간이 안 되면(세션 없음·연결 실패·웹 아님) 녹음 올리기 방식으로 넘어간다', () async {
    final mic = NoMic();
    VoiceHub hub(RealtimeVoice rt) => VoiceHub(
        realtime: rt,
        upload: VoiceConversation(input: () => mic, say: said.add, ask: (wav, {onSpeaking, shouldPlay}) async => VoiceTurn.ended));

    given = null; // 서버가 세션을 주지 않음
    var h = hub(voice);
    expect(await h.start(), isTrue);
    expect([voice.active, h.upload.active, h.state, mic.starts], [false, true, VoiceState.listening, 1]);
    await h.stop();
    await settle(); // 녹음을 닫은 뒤 꺼짐
    expect(h.state, VoiceState.off);

    given = session;
    link.failConnect = true; // 마이크·연결 실패
    expect(await voice.start(), isFalse);
    expect([voice.state, link.closed], [VoiceState.off, true]);

    final notWeb = RealtimeVoice(link: () => null, openSession: () async => session, say: said.add, ask: (q) async => q);
    expect(await notWeb.start(), isFalse);

    link = FakeLink();
    h = hub(voice);
    expect(await h.start(), isTrue); // 실시간이 되면 녹음은 시작하지 않는다
    expect([voice.active, h.upload.active, h.state, mic.starts], [true, false, VoiceState.listening, 1]);
    await h.stop();
  });
}

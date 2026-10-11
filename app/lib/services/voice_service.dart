import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

/// 음성 질문·답 (B5). 녹음은 16kHz mono PCM으로 받아 WAV로 감싸 ai 서버(/api/voice)에 보낸다.
/// 웹·안드로이드·iOS 모두 같은 형식이라 파일 경로·코덱 차이를 신경 쓰지 않아도 된다 (서버가 ffmpeg로 다시 읽음).
const voiceSampleRate = 16000;

/// 서버 제한(30초)보다 조금 짧게 자동으로 멈춘다
const maxVoiceSeconds = 28;

/// PCM 16bit mono → WAV 파일 바이트 (44바이트 머리말 + 원본)
Uint8List pcmToWav(Uint8List pcm, {int sampleRate = voiceSampleRate}) {
  final h = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  h.setUint32(16, 16, Endian.little); // fmt 길이
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // mono
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 2, Endian.little); // 초당 바이트
  h.setUint16(32, 2, Endian.little); // 블록 정렬
  h.setUint16(34, 16, Endian.little); // 16bit
  ascii(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(h.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}

/// 말이 끝났는지 소리 크기로 알아챈다 (연속 음성 대화 — 버튼을 다시 누르지 않아도 보내려고).
/// 16kHz mono 16bit PCM 조각을 [add]로 넣으면 20ms 단위 크기(RMS)를 보고 한 번만 알린다:
/// 말을 시작한 뒤 [endSilence] 동안 조용하면 [onSpeechEnd], [noSpeechAfter] 동안 말이 없으면 [onNoSpeech].
/// 주변 소음은 처음 0.3초 크기로 가늠해 기준을 올린다 (조용한 방 600 ~ 시끄러운 곳 3000).
class SpeechEndDetector {
  SpeechEndDetector({
    this.onSpeechEnd,
    this.onNoSpeech,
    this.sampleRate = voiceSampleRate,
    this.endSilence = const Duration(milliseconds: 1200),
    this.noSpeechAfter = const Duration(seconds: 8),
  });

  final void Function()? onSpeechEnd;
  final void Function()? onNoSpeech;
  final int sampleRate;
  final Duration endSilence;
  final Duration noSpeechAfter;

  static const _frameMs = 20;
  static const _calibrateFrames = 15; // 0.3초
  static const _startFrames = 5; // 0.1초 이어서 소리가 나면 말 시작
  static const minThreshold = 600.0, maxThreshold = 3000.0;

  int _frames = 0, _voiced = 0, _silent = 0, _n = 0;
  double _sumSq = 0, _noise = 0;
  int? _carry; // 조각이 홀수 바이트로 끊겼을 때 남은 아래 바이트
  bool started = false;
  bool _done = false;

  double get threshold => (_noise * 2.5).clamp(minThreshold, maxThreshold);

  void add(Uint8List pcm) {
    if (_done) return;
    final perFrame = sampleRate * _frameMs ~/ 1000;
    var i = 0;
    if (_carry != null && pcm.isNotEmpty) {
      _sample(_carry! | (pcm[0] << 8), perFrame);
      _carry = null;
      i = 1;
    }
    for (; i + 1 < pcm.length && !_done; i += 2) {
      _sample(pcm[i] | (pcm[i + 1] << 8), perFrame);
    }
    if (i < pcm.length && !_done) _carry = pcm[i];
  }

  void _sample(int u16, int perFrame) {
    final v = u16 >= 0x8000 ? u16 - 0x10000 : u16;
    _sumSq += v * v;
    if (++_n < perFrame) return;
    final rms = math.sqrt(_sumSq / _n);
    _sumSq = 0;
    _n = 0;
    _frame(rms);
  }

  void _frame(double rms) {
    _frames++;
    if (_frames <= _calibrateFrames) {
      // 처음부터 말하고 있을 수도 있으니 소음 추정은 위 한도로 막는다 (threshold의 clamp)
      _noise += (rms - _noise) / _frames;
    }
    final voiced = rms >= threshold;
    if (!started) {
      _voiced = voiced ? _voiced + 1 : 0;
      if (_voiced >= _startFrames) {
        started = true;
        _silent = 0;
      } else if (_frames * _frameMs >= noSpeechAfter.inMilliseconds) {
        _done = true;
        onNoSpeech?.call();
      }
      return;
    }
    _silent = voiced ? 0 : _silent + 1;
    if (_silent * _frameMs >= endSilence.inMilliseconds) {
      _done = true;
      onSpeechEnd?.call();
    }
  }
}

/// 마이크 녹음. start() → stop()이 WAV를 돌려준다. 권한이 없으면 start()가 false.
/// [onSpeechEnd]·[onNoSpeech]를 주면 말이 끝난 때·말이 없는 때를 알려 준다 (연속 음성 대화, [SpeechEndDetector]).
class VoiceRecorder {
  final _rec = AudioRecorder();
  final _buf = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  Timer? _limit;

  Future<bool> start({void Function()? onLimit, void Function()? onSpeechEnd, void Function()? onNoSpeech}) async {
    if (!await _rec.hasPermission()) return false;
    _buf.clear();
    final detector = onSpeechEnd == null && onNoSpeech == null
        ? null
        : SpeechEndDetector(onSpeechEnd: onSpeechEnd, onNoSpeech: onNoSpeech);
    final stream = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits, sampleRate: voiceSampleRate, numChannels: 1, noiseSuppress: true, echoCancel: true));
    _sub = stream.listen((chunk) {
      _buf.add(chunk);
      detector?.add(chunk);
    });
    _limit = Timer(const Duration(seconds: maxVoiceSeconds), () => onLimit?.call());
    return true;
  }

  /// 녹음을 멈추고 WAV를 돌려준다. 거의 말하지 않았으면(0.3초 미만) null
  Future<Uint8List?> stop() async {
    _limit?.cancel();
    await _rec.stop();
    await _sub?.cancel();
    _sub = null;
    final pcm = _buf.takeBytes();
    if (pcm.length < voiceSampleRate * 2 * 3 ~/ 10) return null;
    return pcmToWav(pcm);
  }

  Future<void> dispose() async {
    _limit?.cancel();
    await _sub?.cancel();
    await _rec.dispose();
  }
}

/// 답 음성(mp3) 재생. 앱 전체에서 하나만 재생한다 (새로 누르면 이전 것은 멈춤)
class VoicePlayer {
  VoicePlayer._();
  static final instance = VoicePlayer._();
  final _player = AudioPlayer();

  /// 재생이 끝나면 완료된다
  Future<void> play(Uint8List mp3) async {
    await _player.stop();
    final done = _player.onPlayerComplete.first;
    await _player.play(BytesSource(mp3, mimeType: 'audio/mpeg'));
    await done;
  }

  Future<void> stop() => _player.stop();
}

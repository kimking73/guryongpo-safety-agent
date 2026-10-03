import 'dart:async';
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

/// 마이크 녹음. start() → stop()이 WAV를 돌려준다. 권한이 없으면 start()가 false.
class VoiceRecorder {
  final _rec = AudioRecorder();
  final _buf = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  Timer? _limit;

  Future<bool> start({void Function()? onLimit}) async {
    if (!await _rec.hasPermission()) return false;
    _buf.clear();
    final stream = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits, sampleRate: voiceSampleRate, numChannels: 1, noiseSuppress: true, echoCancel: true));
    _sub = stream.listen(_buf.add);
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';

/// 시연 모드 (2026-10-05). 끄면(기본) 실측 데이터, 켜면 서버 시연 데이터 — 실제 센서 위치에 시연 측정값(호우·침수 + 강풍)을
/// 넣어 실측과 같은 판정 규칙으로 계산한 위험 영역·침수 격자·바람·실시간 정보 (api risk/demo.py). 화면은 실측과 같다.
/// APP_MODE=mock(서버 없이 실행)이면 앱 안 가상 화면.

/// 서버 시연 데이터를 쓸지 (서버 연결 + 시연 모드 켬). 저장소·API 호출이 읽는다 — 바뀌면 provider 들이 다시 받는다
class DemoData {
  static bool on = false;
  /// 실측 경로 → 시연 경로 (/api/v1/X → /api/v1/demo/X)
  static String path(String live, String demo) => on ? demo : live;
}

class DemoModeNotifier extends StateNotifier<bool> {
  DemoModeNotifier() : super(false) {
    _load();
  }

  @override
  set state(bool v) {
    DemoData.on = AppConfig.isRemote && v;
    super.state = v;
  }
  static const _key = 'demo_mode';

  Future<void> _load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
      if (mounted) state = v;
    } catch (_) {}
  }

  Future<void> set(bool on) async {
    state = on;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, on);
    } catch (_) {}
  }
}

final demoModeProvider = StateNotifierProvider<DemoModeNotifier, bool>((_) => DemoModeNotifier());

/// 가상(예시) 화면을 보여 줄지: 서버 없이 실행 중이거나, 사용자가 시연 모드를 켰을 때
final showDemoProvider = Provider<bool>((ref) => !AppConfig.isRemote || ref.watch(demoModeProvider));

/// 서버 연결 상태에서 시연 모드 — 화면은 실측과 같고 데이터만 서버 시연 데이터(실제 센서 위치 + 시연 측정값)
final serverDemoProvider = Provider<bool>((ref) => AppConfig.isRemote && ref.watch(demoModeProvider));

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';

/// 시연 모드 (2026-10-05). 끄면(기본) 실측 데이터 화면만, 켜면 가상 시나리오 화면(가상 태풍·가상 위험 구역·예시 가구 등).
/// APP_MODE=mock(서버 없이 실행)이면 늘 가상 화면.
class DemoModeNotifier extends StateNotifier<bool> {
  DemoModeNotifier() : super(false) {
    _load();
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/domain_models.dart';
import 'app_config.dart';

/// 시연 모드 (2026-10-05). 기본은 켬 (2026-10-11 사용자 요청) — 켜면 서버 시연 데이터, 끄면 실측 데이터 — 실제 센서 위치에 시연 측정값(호우·침수 + 강풍)을
/// 넣어 실측과 같은 판정 규칙으로 계산한 위험 영역·침수 격자·바람·실시간 정보 (api risk/demo.py). 화면은 실측과 같다.
/// APP_MODE=mock(서버 없이 실행)이면 앱 안 가상 화면.

/// 서버 시연 데이터를 쓸지 (서버 연결 + 시연 모드 켬). 저장소·API 호출이 읽는다 — 바뀌면 provider 들이 다시 받는다
class DemoData {
  static bool on = AppConfig.isRemote; // 기본 켬 (서버 연결일 때만 의미가 있다)
  /// 실측 경로 → 시연 경로 (/api/v1/X → /api/v1/demo/X)
  static String path(String live, String demo) => on ? demo : live;

  /// 시연 모드 지도에서 칠하지 않는 위험 영역: 읍 전체(반경 4km)에 내려진 호우·강풍 특보 (2026-10-07).
  /// 화면 전체를 노랑·주황으로 덮어 침수·산사태 영역이 안 보였다. 데이터는 그대로라 상황판 제목·특보 카드·AI 답에는 남는다
  /// (경로 서버도 같은 이유로 호우 영역은 피하지 않는다).
  static const townWideHazards = {'heavy_rain', 'strong_wind'};

  /// 지도에 그릴 위험 영역. 시연 모드면 읍 전체 특보 영역을 뺀다 (실측 화면은 그대로)
  static List<RiskArea> mapAreas(List<RiskArea> areas) =>
      on ? [for (final a in areas) if (!townWideHazards.contains(a.hazard)) a] : areas;
}

class DemoModeNotifier extends StateNotifier<bool> {
  DemoModeNotifier() : super(true) {
    _load();
  }

  @override
  set state(bool v) {
    DemoData.on = AppConfig.isRemote && v;
    super.state = v;
  }
  /// 기본값을 켬으로 바꾸며 키도 새로 (2026-10-11) — 예전에 끈 기록이 남은 기기도 처음엔 시연 모드로 연다
  static const _key = 'demo_mode_v2';

  Future<void> _load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getBool(_key) ?? true;
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

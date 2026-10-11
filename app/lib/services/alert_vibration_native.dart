import 'package:flutter/services.dart';

/// 한 번 진동한다 ([ms]는 웹에서만 쓰는 길이)
void alertVibrate([int ms = 500]) {
  HapticFeedback.vibrate().catchError((Object _) {});
}

/// 진동을 멈춘다 (앱 진동은 짧아서 할 일 없음)
void alertVibrateStop() {}

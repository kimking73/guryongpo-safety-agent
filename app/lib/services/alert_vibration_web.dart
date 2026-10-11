import 'dart:js_interop';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external bool vibrate(JSNumber ms);
}

/// 한 번 [ms] 밀리초 진동한다. 진동을 못 하는 브라우저(아이폰·PC)는 조용히 넘어간다
void alertVibrate([int ms = 500]) {
  try {
    _navigator.vibrate(ms.toJS);
  } catch (_) {}
}

/// 진동을 멈춘다
void alertVibrateStop() {
  try {
    _navigator.vibrate(0.toJS);
  } catch (_) {}
}

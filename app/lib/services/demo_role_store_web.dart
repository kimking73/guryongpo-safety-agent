import 'dart:js_interop';

@JS('window.sessionStorage')
external _Storage get _session;

extension type _Storage(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
}

/// 이 창(탭)에만 남는 값 — 같은 브라우저의 다른 창과 나누지 않고, 새로고침해도 남는다
String? readWindowValue(String key) {
  try {
    return _session.getItem(key.toJS)?.toDart;
  } catch (_) {
    return null;
  }
}

void writeWindowValue(String key, String value) {
  try {
    _session.setItem(key.toJS, value.toJS);
  } catch (_) {}
}

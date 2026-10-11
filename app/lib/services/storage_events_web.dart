import 'dart:js_interop';

@JS('window.addEventListener')
external void _addEventListener(JSString type, JSFunction listener);

/// 같은 브라우저의 다른 창(탭)이 localStorage 를 바꾸면 [callback] — 'storage' 이벤트는 바꾼 창 자신에는 오지 않는다
void onOtherWindowStorageChange(void Function() callback) {
  try {
    _addEventListener('storage'.toJS, ((JSAny? _) => callback()).toJS);
  } catch (_) {}
}

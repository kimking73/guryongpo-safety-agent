// 같은 브라우저의 다른 창이 기기 저장소(localStorage)를 바꿨을 때 알림 — 웹만. 앱은 창이 하나라 할 일 없음
export 'storage_events_native.dart' if (dart.library.js_interop) 'storage_events_web.dart';

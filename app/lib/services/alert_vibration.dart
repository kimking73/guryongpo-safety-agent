// 대피 알림 진동: 웹은 브라우저 진동(navigator.vibrate — 안드로이드 크롬 등에서만 동작), 앱은 기기 진동
export 'alert_vibration_native.dart' if (dart.library.js_interop) 'alert_vibration_web.dart';

// 시연 역할(사용자·방재단원)을 창마다 따로 저장 — 웹은 sessionStorage(탭마다 따로), 앱은 메모리
export 'demo_role_store_native.dart' if (dart.library.js_interop) 'demo_role_store_web.dart';

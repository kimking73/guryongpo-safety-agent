import 'package:dio/dio.dart';
import 'app_config.dart';
import 'auth_service.dart';

/// 서버별 Dio. 모든 요청에 Firebase ID 토큰을 붙인다 (Firebase 미설정이면 생략).
class ApiClient {
  ApiClient(this._auth)
      : api = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl, connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 15))),
        // AI 답변은 평균 8초, 검증 재시도 시 더 걸린다
        ai = Dio(BaseOptions(baseUrl: AppConfig.aiBaseUrl, connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 60))),
        route = Dio(BaseOptions(baseUrl: AppConfig.routeBaseUrl, connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 15))) {
    for (final d in [api, ai, route]) {
      d.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
        String? token;
        try { token = await _auth.token(); } catch (_) {}
        if (token != null) o.headers['Authorization'] = 'Bearer $token';
        h.next(o);
      }));
    }
  }
  final AuthService _auth;
  final Dio api, ai, route;
}

import 'package:dio/dio.dart';
import 'app_config.dart';
import 'auth_service.dart';

class ApiClient {
  ApiClient(this._auth) : dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl)) { dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async { final token = await _auth.token(); if (token != null) o.headers['Authorization'] = 'Bearer $token'; h.next(o); })); }
  final AuthService _auth;
  final Dio dio;
}

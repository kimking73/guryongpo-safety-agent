import 'package:dio/dio.dart';
import 'api_client.dart';
import 'auth_service.dart';

/// 실측 화면용 서버 호출 (2026-10-05). 응답은 명세(server/spec/openapi.yaml) 그대로 Map으로 쓴다.
class LiveApi {
  LiveApi({Dio? api}) : _api = api ?? ApiClient(AuthService()).api;
  final Dio _api;

  Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic>? q]) async =>
      Map<String, dynamic>.from((await _api.get<Map<String, dynamic>>(path, queryParameters: q)).data ?? const {});

  Future<List<Map<String, dynamic>>> _list(String path, [Map<String, dynamic>? q]) async =>
      [for (final x in (await _api.get<List<dynamic>>(path, queryParameters: q)).data ?? const []) Map<String, dynamic>.from(x as Map)];

  /// 맞춤 대시보드: 위험도·특보·강수·바람·수위·파고·태풍·예보·재난문자·자외선/미세먼지·장소별 위험·가까운 대피소
  Future<Map<String, dynamic>> dashboard(double lat, double lng) => _get('/api/v1/dashboard', {'lat': lat, 'lng': lng});

  Future<List<Map<String, dynamic>>> supportPrograms({String? hazard}) =>
      _list('/api/v1/support-programs', {if (hazard != null) 'hazard': hazard});

  Future<List<Map<String, dynamic>>> hotlines({String? hazard}) =>
      _list('/api/v1/hotlines', {if (hazard != null) 'hazard': hazard});

  // ---- 방재단 (역할 필요: 초대 코드로 받음) ----
  Future<Map<String, dynamic>> me() => _get('/api/v1/user');
  Future<Map<String, dynamic>> claimRole(String code) async => Map<String, dynamic>.from(
      (await _api.post<Map<String, dynamic>>('/api/v1/user/role', data: {'invite_code': code.trim()})).data ?? const {});
  Future<void> dropRole() => _api.delete<Object?>('/api/v1/user/role');
  Future<Map<String, dynamic>> adminOverview() => _get('/api/v1/admin/overview');
  Future<List<Map<String, dynamic>>> adminHouseholds() => _list('/api/v1/admin/households');
  Future<List<Map<String, dynamic>>> adminIncidents() => _list('/api/v1/admin/incidents');

  // ---- 내 취약 가구 등록 (동의 필수) ----
  Future<Map<String, dynamic>?> myHousehold() async {
    try {
      return await _get('/api/v1/user/household');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> saveHousehold(Map<String, dynamic> body) async => Map<String, dynamic>.from(
      (await _api.put<Map<String, dynamic>>('/api/v1/user/household', data: body)).data ?? const {});
  Future<void> deleteHousehold() => _api.delete<Object?>('/api/v1/user/household');
}

/// 서버 오류 → 한국어 한 줄
String liveError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    final data = e.response?.data;
    final msg = data is Map ? data['message'] as String? : null;
    if (msg != null && msg.isNotEmpty) return msg;
    if (code == 401) return '로그인 정보를 확인하지 못했습니다. 앱을 다시 열어 주세요.';
    if (code == 403) return '권한이 없습니다.';
    if (code == null) return '서버에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.';
    return '서버 오류 ($code)';
  }
  return '$e';
}

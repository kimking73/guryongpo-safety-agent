import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';
import 'auth_service.dart';

/// 앱 입력값을 로그인 계정(서버)과 맞춘다. 화면은 지금처럼 AccountService(기기 저장)만 쓰고, 여기서 서버로 올리고 내려받는다.
///
/// - 통째 저장: GET·PUT /api/v1/user/app-state — 아래 [syncedKeys] 그대로 (다른 기기에서 같은 계정이면 그대로 복원)
/// - 서버 판단용 칸: PATCH /api/v1/user (출생연도·이동수단·직업·보행·시각·청각), /api/v1/user/places (집·직장·저장 장소)
///   → 선제 경고(A5)가 이 값으로 대상자를 고른다
/// - 언제: 앱 시작·로그인 때 [pullOrPush], 화면에서 저장할 때 [changed] (1초 모아서 올림)
/// - 충돌: 올리지 못한 변경(오프라인)이 기기에 있으면 기기 값이 이기고, 아니면 서버 값이 이긴다
class AccountSync {
  AccountSync._();
  static final instance = AccountSync._();

  /// 계정을 따라가는 기기 저장 항목 (AccountService 키)
  static const syncedKeys = [
    'profile_age', 'profile_transport', 'profile_setup_complete', 'optional_profile', 'saved_places', _placeIdsKey,
  ];
  static const _dirtyKey = 'account_sync_dirty';
  /// 앱 장소 → 서버 장소 id·내용 지문 ({"home": {"id": "...", "fp": "..."}, "saved:123": …}). 통째 저장에 함께 실어 다른 기기에서도 중복 등록 안 함
  static const _placeIdsKey = 'server_place_ids';

  bool get enabled => AuthService.enabled && AuthService.ready;
  Timer? _debounce;
  Future<void>? _running;

  /// 화면에서 무언가 저장했을 때 — 표시만 하고 1초 뒤 서버로
  Future<void> changed() async {
    if (!enabled) return;
    (await SharedPreferences.getInstance()).setBool(_dirtyKey, true);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => unawaited(push()));
  }

  /// 앱 시작·로그인 직후: 서버에 저장본이 있으면 내려받고(기기에 못 올린 변경이 없을 때), 없으면 기기 값을 올린다
  Future<void> pullOrPush() async {
    if (!enabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final r = await (await _dio()).get<Map<String, dynamic>>('/api/v1/user/app-state');
      final state = r.data?['state'];
      if (state is Map && !(prefs.getBool(_dirtyKey) ?? false)) {
        await applySnapshot(prefs, Map<String, dynamic>.from(state));
        return;
      }
      if (hasLocalData(prefs)) await push();
    } catch (_) {}
  }

  /// 로그아웃: 이 기기에 남은 계정 정보를 지운다 (계정에는 저장돼 있음). 다음 익명 사용자는 빈 상태로 시작
  Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [...syncedKeys, _dirtyKey]) {
      await prefs.remove(k);
    }
  }

  /// 기기 값 → 서버 (통째 + 판단용 칸 + 장소). 동시에 두 번 돌지 않게 묶는다
  Future<void> push() => _running ??= _push().whenComplete(() => _running = null);

  Future<void> _push() async {
    if (!enabled) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final dio = await _dio();
      final profile = profilePatch(prefs);
      if (profile.isNotEmpty) await dio.patch<Object?>('/api/v1/user', data: profile);
      await _syncPlaces(dio, prefs);
      await dio.put<Object?>('/api/v1/user/app-state', data: {'state': snapshot(prefs)});
      await prefs.setBool(_dirtyKey, false);
    } catch (_) {
      await prefs.setBool(_dirtyKey, true); // 다음 시작·저장 때 다시
    }
  }

  Future<Dio> _dio() async {
    final t = await AuthService().token();
    return Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl, connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 15), headers: {if (t != null) 'Authorization': 'Bearer $t'}));
  }

  /// 앱 장소 목록을 서버 장소와 맞춘다: 새것 등록, 바뀐 것 수정, 없어진 것 삭제
  Future<void> _syncPlaces(Dio dio, SharedPreferences prefs) async {
    final known = _placeIds(prefs);
    final desired = desiredPlaces(prefs);
    for (final e in desired.entries) {
      final fp = jsonEncode(e.value);
      final k = known[e.key];
      if (k != null && k['fp'] == fp) continue;
      if (k != null) {
        try {
          await dio.patch<Object?>('/api/v1/user/places/${k['id']}', data: e.value);
          known[e.key] = {'id': k['id']!, 'fp': fp};
          continue;
        } on DioException catch (err) {
          if (err.response?.statusCode != 404) rethrow; // 서버에서 지워졌으면 새로 등록
        }
      }
      final r = await dio.post<Map<String, dynamic>>('/api/v1/user/places', data: e.value);
      known[e.key] = {'id': '${r.data?['id']}', 'fp': fp};
    }
    for (final key in known.keys.where((k) => !desired.containsKey(k)).toList()) {
      try {
        await dio.delete<Object?>('/api/v1/user/places/${known[key]!['id']}');
      } on DioException catch (err) {
        if (err.response?.statusCode != 404) rethrow;
      }
      known.remove(key);
    }
    await prefs.setString(_placeIdsKey, jsonEncode(known));
  }

  static Map<String, Map<String, String>> _placeIds(SharedPreferences prefs) {
    final raw = prefs.getString(_placeIdsKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', Map<String, String>.from(v as Map)));
  }

  // ---- 아래는 순수 변환 (테스트 대상) ----

  static bool hasLocalData(SharedPreferences prefs) =>
      syncedKeys.any((k) => k != _placeIdsKey && prefs.containsKey(k));

  /// 기기 저장 항목 → 통째 저장본
  static Map<String, Object> snapshot(SharedPreferences prefs) => {
        'version': 1,
        'prefs': {
          for (final k in syncedKeys)
            if (prefs.get(k) != null) k: prefs.get(k)!,
        },
      };

  /// 통째 저장본 → 기기 저장 항목 (저장본에 없는 항목은 지운다 — 서버 계정 상태와 똑같이)
  static Future<void> applySnapshot(SharedPreferences prefs, Map<String, dynamic> state) async {
    final values = Map<String, dynamic>.from((state['prefs'] as Map?) ?? const {});
    for (final k in syncedKeys) {
      final v = values[k];
      if (v is String) {
        await prefs.setString(k, v);
      } else if (v is bool) {
        await prefs.setBool(k, v);
      } else {
        await prefs.remove(k);
      }
    }
    await prefs.setBool(_dirtyKey, false);
  }

  static Map<String, String> _optional(SharedPreferences prefs) {
    final raw = prefs.getString('optional_profile');
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
  }

  /// 서버 판단용 칸 (PATCH /user). 값이 있는 것만
  static Map<String, Object> profilePatch(SharedPreferences prefs, {DateTime? now}) {
    final o = _optional(prefs);
    String v(String k) => (o[k] ?? '').trim();
    final age = int.tryParse(prefs.getString('profile_age') ?? '') ?? int.tryParse(v('age'));
    final transport = prefs.getString('profile_transport') ?? (v('transport').isEmpty ? null : v('transport'));
    final jobs = v('jobs').split('|').where((e) => e.isNotEmpty).toList();
    final occupation = [v('직업'), ...jobs].where((e) => e.isNotEmpty).join(', ');
    return {
      if (age != null && age > 0 && age < 120) 'birth_year': (now ?? DateTime.now()).year - age,
      if (transport != null) 'mobility': transport == '휠체어' ? 'wheelchair' : 'walk',
      if (occupation.isNotEmpty) 'occupation': occupation,
      if (jobs.any((j) => j.contains('어업') || j.contains('뱃사람'))) 'owns_vessel': true,
      if (v('보행 능력').isNotEmpty) 'walking_ability': 'limited',
      if (v('시각 지원').isNotEmpty) 'vision_impaired': true,
      if (v('청각 지원').isNotEmpty) 'hearing_impaired': true,
    };
  }

  static const _placeType = {'집': 'home', '직장': 'work', '숙소': 'lodging'};

  /// 서버에 있어야 할 장소 (키 → POST /user/places 본문): 집·직장(프로필 주소) + 저장 장소 목록
  static Map<String, Map<String, Object>> desiredPlaces(SharedPreferences prefs) {
    final o = _optional(prefs);
    final out = <String, Map<String, Object>>{};
    for (final (key, type, label) in [('home', 'home', '집'), ('work', 'work', '직장')]) {
      final lat = double.tryParse(o['${key}Lat'] ?? ''), lon = double.tryParse(o['${key}Lon'] ?? '');
      final address = (o['${key}Address'] ?? '').trim();
      if (lat == null || lon == null) continue;
      out[key] = {
        'place_type': type,
        'label': (o['${key}Name'] ?? '').trim().isEmpty ? label : o['${key}Name']!.trim(),
        if (address.isNotEmpty) 'address': address,
        'location': {'lat': lat, 'lng': lon},
        'notify': true,
      };
    }
    final raw = prefs.getString('saved_places');
    for (final p in raw == null ? const [] : jsonDecode(raw) as List) {
      final m = p as Map;
      final lat = (m['lat'] as num?)?.toDouble(), lon = (m['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final address = '${m['address'] ?? ''}'.trim();
      out['saved:${m['id']}'] = {
        'place_type': _placeType['${m['type']}'] ?? 'frequent',
        'label': '${m['name'] ?? m['type'] ?? '장소'}',
        if (address.isNotEmpty) 'address': address,
        'location': {'lat': lat, 'lng': lon},
        'notify': m['alert'] != false,
      };
    }
    return out;
  }
}

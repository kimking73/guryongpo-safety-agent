import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';
import 'auth_service.dart';

/// 앱 입력값을 로그인 계정(서버)과 맞춘다. 화면은 지금처럼 AccountService(기기 저장)만 쓰고, 여기서 서버로 올리고 내려받는다.
///
/// 사용자 프로필은 서버 한 곳(user_profiles·user_places·emergency_contacts)이 기준 (2026-10-08 사용자 결정):
/// AI도 대화에서 들은 내용으로 같은 곳을 고친다. 기기 저장은 화면 표시용 사본 — [pullProfile]이 서버 값으로 다시 채운다
/// (앱 시작·로그인, 프로필 화면 열 때, AI 대화 뒤). 올릴 때는 마지막으로 맞춘 서버 값과 달라진 칸만 보낸다 (AI가 고친 값을 덮어쓰지 않게).
///
/// - 통째 저장: GET·PUT /api/v1/user/app-state — 아래 [syncedKeys] 그대로 (다른 기기에서 같은 계정이면 그대로 복원)
/// - 서버 판단용 칸: PATCH /api/v1/user (출생연도·이동수단·직업·보행·시각·청각·보호 동반자·혈액형), /api/v1/user/places
///   (집·직장·저장 장소), /api/v1/user/contacts (비상 연락처) — 통째 저장의 프로필 화면 값과 같게 (2026-10-08)
///   → 선제 경고(A5)가 이 값으로 대상자를 고른다
/// - 언제: 앱 시작·로그인 때 [pullOrPush] + [pullProfile], 화면에서 저장할 때 [changed] (1초 모아서 올림)
/// - 충돌: 올리지 못한 변경(오프라인)이 기기에 있으면 기기 값이 이기고, 아니면 서버 값이 이긴다
class AccountSync {
  AccountSync._();
  static final instance = AccountSync._();

  /// 계정을 따라가는 기기 저장 항목 (AccountService 키)
  static const syncedKeys = [
    'profile_age', 'profile_transport', 'profile_setup_complete', 'optional_profile', 'saved_places', _placeIdsKey,
    _contactKey,
  ];
  static const _dirtyKey = 'account_sync_dirty';
  /// 앱 장소 → 서버 장소 id·내용 지문 ({"home": {"id": "...", "fp": "..."}, "saved:123": …}). 통째 저장에 함께 실어 다른 기기에서도 중복 등록 안 함
  static const _placeIdsKey = 'server_place_ids';
  /// 서버 비상연락처 id·내용 지문 ({"id": "...", "fp": "..."}) — 다른 기기에서도 중복 등록 안 하게 통째 저장에 실음
  static const _contactKey = 'server_contact_id';
  /// profilePatch 번역 규칙 버전 — 올리면 로그인한 기기가 판단용 칸을 한 번 다시 보낸다
  static const patchVersion = 2;
  static const _patchVersionKey = 'account_sync_patch_version';
  /// 마지막으로 서버와 맞춘 판단용 칸 (profilePatch 형태). 올릴 때 이것과 다른 칸만 보낸다 — 기기마다 따로 (통째 저장에 안 실음)
  static const _baseKey = 'server_profile_base';
  /// 서버 프로필을 내려받아 화면 값이 바뀌면 올라간다 — 프로필 화면이 다시 읽는다
  static final updated = ValueNotifier<int>(0);

  // 로그인(익명 제외)한 사람만 계정에 저장한다 (2026-10-08). 로그인 안 하면 프로필은 이 기기에만
  bool get enabled => AuthService.enabled && AuthService.signedIn;
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
        // 번역 규칙이 바뀌면(판단용 칸 = 화면 값, 2026-10-08) 내려받은 값으로 판단용 칸을 한 번 다시 맞춘다
        if (prefs.getInt(_patchVersionKey) != patchVersion) {
          await push(full: true);
          await prefs.setInt(_patchVersionKey, patchVersion);
        }
      } else if (hasLocalData(prefs)) {
        await push();
      }
    } catch (_) {}
    await pullProfile();
  }

  /// 서버 프로필 → 이 기기 화면 값. 기기에서 고치고 아직 못 올린 것이 있으면 먼저 올린다. 화면 값이 바뀌었으면 true
  Future<bool> pullProfile() async {
    if (!enabled) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getBool(_dirtyKey) ?? false) || (_debounce?.isActive ?? false)) {
        _debounce?.cancel();
        await push();
      }
      final r = await (await _dio()).get<Map<String, dynamic>>('/api/v1/user');
      final changed = await applyServerProfile(prefs, r.data ?? const {});
      if (changed) updated.value++;
      return changed;
    } catch (_) {
      return false;
    }
  }

  /// AI가 대화에서 수집해 프로필에 반영한 기록 (최신순, GET /api/v1/user/profile-updates — care.profile_updates).
  /// 로그인 안 함·서버 오류면 null
  Future<List<ProfileUpdate>?> profileUpdates({int limit = 30}) async {
    if (!enabled) return null;
    try {
      final r = await (await _dio()).get<Map<String, dynamic>>('/api/v1/user/profile-updates',
          queryParameters: {'limit': limit});
      return [
        for (final j in (r.data?['items'] as List?) ?? const []) ProfileUpdate.fromJson(Map<String, dynamic>.from(j as Map))
      ];
    } catch (_) {
      return null;
    }
  }

  /// 수집 기록 하나 지우기 (프로필 값은 그대로)
  Future<bool> deleteProfileUpdate(int id) async {
    if (!enabled) return false;
    try {
      await (await _dio()).delete<Object?>('/api/v1/user/profile-updates/$id');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// AI 대화 뒤: AI가 답한 다음 백그라운드로 프로필을 고치므로(보통 수 초) 조금 뒤 두 번 내려받는다
  void pullAfterChat() {
    if (!enabled) return;
    for (final s in const [8, 20]) {
      Timer(Duration(seconds: s), () => unawaited(pullProfile()));
    }
  }

  /// 로그아웃: 이 기기에 남은 계정 정보를 지운다 (계정에는 저장돼 있음). 다음 익명 사용자는 빈 상태로 시작
  Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [...syncedKeys, _dirtyKey]) {
      await prefs.remove(k);
    }
  }

  /// 기기 값 → 서버 (통째 + 판단용 칸 + 장소). 동시에 두 번 돌지 않게 묶는다.
  /// 판단용 칸은 마지막으로 서버와 맞춘 값([_baseKey])과 달라진 칸만 (full 이면 전부)
  Future<void> push({bool full = false}) => _running ??= _push(full).whenComplete(() => _running = null);

  Future<void> _push(bool full) async {
    if (!enabled) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final dio = await _dio();
      final patch = profilePatch(prefs);
      final profile = full ? patch : changedFields(patch, _base(prefs));
      if (profile.isNotEmpty) await dio.patch<Object?>('/api/v1/user', data: profile);
      await prefs.setString(_baseKey, jsonEncode({..._base(prefs), ...patch}));
      await _syncPlaces(dio, prefs);
      await _syncContact(dio, prefs);
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

  /// 비상 연락처를 서버와 맞춘다 (서버에는 고칠 API가 없어 바뀌면 지우고 새로 등록)
  Future<void> _syncContact(Dio dio, SharedPreferences prefs) async {
    final raw = prefs.getString(_contactKey);
    final known = raw == null ? null : Map<String, String>.from(jsonDecode(raw) as Map);
    final want = desiredContact(prefs);
    final fp = want == null ? null : jsonEncode(want);
    if (known?['fp'] == fp) return;
    if (known != null) {
      try {
        await dio.delete<Object?>('/api/v1/user/contacts/${known['id']}');
      } on DioException catch (err) {
        if (err.response?.statusCode != 404) rethrow;
      }
      await prefs.remove(_contactKey);
    }
    if (want == null) return;
    final r = await dio.post<Map<String, dynamic>>('/api/v1/user/contacts', data: want);
    await prefs.setString(_contactKey, jsonEncode({'id': '${r.data?['id']}', 'fp': fp}));
  }

  static Map<String, Object?> _base(SharedPreferences prefs) {
    final raw = prefs.getString(_baseKey);
    return raw == null ? {} : Map<String, Object?>.from(jsonDecode(raw) as Map);
  }

  /// 올릴 칸: 마지막으로 서버와 맞춘 값과 다른 것만
  static Map<String, Object?> changedFields(Map<String, Object?> patch, Map<String, Object?> base) => {
        for (final e in patch.entries)
          if (!base.containsKey(e.key) || jsonEncode(base[e.key]) != jsonEncode(e.value)) e.key: e.value,
      };

  static Map<String, Map<String, String>> _placeIds(SharedPreferences prefs) {
    final raw = prefs.getString(_placeIdsKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', Map<String, String>.from(v as Map)));
  }

  // ---- 아래는 순수 변환 (테스트 대상) ----

  static bool hasLocalData(SharedPreferences prefs) =>
      syncedKeys.any((k) => k != _placeIdsKey && k != _contactKey && prefs.containsKey(k));

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

  /// 서버 판단용 칸 (PATCH /user) — 통째 저장(app_state)의 프로필 화면 값과 같게 맞춘다 (2026-10-08).
  /// 프로필 화면을 한 번이라도 저장했으면(optional_profile 있음) 지운 칸은 서버 기본값(아니오·보통·없음)으로 되돌린다.
  /// 아무것도 입력 안 했으면 첫 설정 값(연령·이동수단)만 보낸다
  static Map<String, Object?> profilePatch(SharedPreferences prefs, {DateTime? now}) {
    final o = _optional(prefs);
    final screen = prefs.containsKey('optional_profile');
    String v(String k) => (o[k] ?? o[_legacy[k]] ?? '').trim();
    // 프로필 화면(optional_profile)이 첫 설정(profile_*)보다 나중에 고친 값이라 먼저 본다
    final age = int.tryParse(v('age')) ?? int.tryParse(prefs.getString('profile_age') ?? '');
    final transport = v('transport').isNotEmpty ? v('transport') : prefs.getString('profile_transport');
    final jobs = [v('직업'), ...v('jobs').split('|')].where((e) => e.isNotEmpty).map((j) => jobCode[j] ?? j).toSet();
    final blood = v('혈액형');
    final visual = v('시각 지원'), hearing = v('청각 지원');
    return {
      if (age != null && age > 0 && age < 120) 'birth_year': (now ?? DateTime.now()).year - age,
      if (transport != null) 'mobility': _mobility[transport] ?? 'walk',
      if (screen) ...{
        // 직업: 화면 이름 → 서버 코드 (서버 경고의 어업 판단이 'fisher' 를 본다). 직접 입력한 직업은 글자 그대로
        'occupation': jobs.isEmpty ? null : jobs.join(', '),
        'owns_vessel': jobs.contains('fisher'),
        'walking_ability': switch (v('보행 능력')) { '보행 불편' => 'limited', '보행 어려움' => 'unable', _ => 'normal' },
        // '필요 없음'은 아니오 (예전엔 값이 있기만 하면 예로 보냈다)
        'vision_impaired': visual.isNotEmpty && visual != '필요 없음',
        'hearing_impaired': hearing.isNotEmpty && hearing != '필요 없음',
        'has_dependents': v('보호가 필요한 동반자 여부') == '예',
        // 혈액형은 서버가 보호 구역(care.user_health)에 둔다. '모름'은 없음
        'blood_type': _bloodTypes.contains(blood) ? blood : null,
      },
    };
  }

  /// 프로필 화면 직업 이름 → 서버 코드 (서버 user_profiles.occupation 주석의 값)
  static const jobCode = {
    '어업 종사자·뱃사람': 'fisher', '자영업자': 'merchant', '농업 종사자': 'farmer', '직장인': 'office', '학생': 'student', '기타': 'other',
  };
  static const _bloodTypes = {'A+', 'A-', 'B+', 'B-', 'O+', 'O-', 'AB+', 'AB-'};
  /// 예전 버전 앱이 쓰던 칸 이름 (main.dart legacyFieldLabels)
  static const _legacy = {
    '보호가 필요한 동반자 여부': '보호 동반자', '보행 능력': '보행능력', '시각 지원': '시각', '청각 지원': '청각', '비상 연락처': '비상연락처',
  };

  /// 프로필 화면 '비상 연락처'(글자 하나) → 서버 비상연락처. 전화번호를 찾지 못하면 null (예: "딸 010-1234-5678")
  static Map<String, Object>? desiredContact(SharedPreferences prefs) {
    final o = _optional(prefs);
    final text = (o['비상 연락처'] ?? o['비상연락처'] ?? '').trim();
    final m = RegExp(r'(\+?82[- ]?|0)\d{1,2}[- .]?\d{3,4}[- .]?\d{4}').firstMatch(text);
    if (m == null) return null;
    final name = text.replaceRange(m.start, m.end, '').replaceAll(RegExp(r'[\s:,/()]+'), ' ').trim();
    return {'name': name.isEmpty ? '비상 연락처' : name, 'phone': m.group(0)!, 'priority': 1};
  }

  static const _placeType = {'집': 'home', '직장': 'work', '숙소': 'lodging'};
  /// 앱 이동수단 → 서버 mobility (명세 ProfileInput)
  static const _mobility = {'도보': 'walk', '휠체어': 'wheelchair', '자동차': 'car', '자전거': 'bicycle', '대중교통': 'public_transit'};

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

  static const _transportName = {'walk': '도보', 'wheelchair': '휠체어', 'car': '자동차', 'bicycle': '자전거', 'public_transit': '대중교통'};
  static const _placeTypeName = {'home': '집', 'work': '직장', 'lodging': '숙소'};

  /// 서버 프로필(GET /api/v1/user) → 기기 화면 값 (2026-10-08: 프로필은 서버 하나, 기기는 표시용 사본).
  /// 화면 값이 서버와 같은 뜻이면 그대로 둔다 (예: 시각 '저시력'과 서버 '예'). 서버에 없는 장소는 화면에서도 지우고,
  /// 서버에만 있는 장소(AI가 더한 곳·다른 기기)는 화면에 더한다. 끝나면 '마지막으로 맞춘 값'을 지금 값으로. 바뀌었으면 true
  static Future<bool> applyServerProfile(SharedPreferences prefs, Map<String, dynamic> user, {DateTime? now}) async {
    final before = jsonEncode(snapshot(prefs));
    final profile = Map<String, dynamic>.from((user['profile'] as Map?) ?? const {});
    final o = _optional(prefs);
    String v(String k) => (o[k] ?? o[_legacy[k]] ?? '').trim();
    final local = profilePatch(prefs, now: now);
    void set(String k, String value) {
      o.remove(_legacy[k]);
      if (value.isEmpty) {
        o.remove(k);
      } else {
        o[k] = value;
      }
    }

    // 나이·이동수단
    final by = profile['birth_year'];
    if (by is num) {
      if (local['birth_year'] != by) set('age', '${(now ?? DateTime.now()).year - by.toInt()}');
    }
    final mobility = '${profile['mobility'] ?? ''}';
    if (_transportName.containsKey(mobility) && local['mobility'] != mobility) set('transport', _transportName[mobility]!);
    // 직업: 서버 코드 → 화면 칩 이름 (직접 입력한 직업은 그대로)
    final names = {for (final e in jobCode.entries) e.value: e.key};
    final jobs = '${profile['occupation'] ?? ''}'.split(',').map((j) => j.trim()).where((j) => j.isNotEmpty).toList();
    if (jsonEncode(local['occupation']) != jsonEncode(jobs.isEmpty ? null : jobs.join(', ')) && profile.containsKey('occupation')) {
      set('jobs', jobs.map((j) => names[j] ?? j).join('|'));
      set('직업', '');
    }
    // 보행·시각·청각·보호 동반자·혈액형: 화면 값의 뜻이 서버와 다를 때만 바꾼다
    final walking = '${profile['walking_ability'] ?? 'normal'}';
    final localWalking = switch (v('보행 능력')) { '보행 불편' => 'limited', '보행 어려움' => 'unable', _ => 'normal' };
    if (walking != localWalking) {
      set('보행 능력', switch (walking) { 'limited' => '보행 불편', 'unable' => '보행 어려움', _ => '보행 가능' });
    }
    for (final (key, field) in [('시각 지원', 'vision_impaired'), ('청각 지원', 'hearing_impaired')]) {
      final want = profile[field] == true;
      final has = v(key).isNotEmpty && v(key) != '필요 없음';
      if (want != has) set(key, want ? '지원 필요' : (v(key).isEmpty ? '' : '필요 없음'));
    }
    final dependents = profile['has_dependents'] == true;
    if (dependents != (v('보호가 필요한 동반자 여부') == '예')) {
      set('보호가 필요한 동반자 여부', dependents ? '예' : (v('보호가 필요한 동반자 여부').isEmpty ? '' : '아니요'));
    }
    if (profile.containsKey('blood_type')) {
      final blood = '${profile['blood_type'] ?? ''}';
      if (blood != (_bloodTypes.contains(v('혈액형')) ? v('혈액형') : '')) set('혈액형', blood);
    }

    // 장소: 서버 장소 id ↔ 화면 장소 (집·직장 = 프로필 주소, 나머지 = 저장 장소)
    final known = _placeIds(prefs);
    final byId = {for (final e in known.entries) e.value['id']: e.key};
    final saved = [
      for (final p in jsonDecode(prefs.getString('saved_places') ?? '[]') as List) Map<String, dynamic>.from(p as Map)
    ];
    final seen = <String>{};
    void setPlaceFields(String key, Map<String, dynamic> pl) {
      final loc = Map<String, dynamic>.from(pl['location'] as Map);
      set('${key}Lat', '${loc['lat']}');
      set('${key}Lon', '${loc['lng']}');
      set('${key}Address', '${pl['address'] ?? ''}');
      final label = '${pl['label'] ?? ''}';
      set('${key}Name', label == (key == 'home' ? '집' : '직장') ? '' : label);
    }
    for (final raw in (user['places'] as List?) ?? const []) {
      final pl = Map<String, dynamic>.from(raw as Map);
      final id = '${pl['id']}';
      var key = byId[id];
      final type = '${pl['place_type']}';
      // 처음 보는 서버 장소: 화면에 집·직장이 비어 있으면 그 칸으로, 아니면 저장 장소로
      if (key == null && (type == 'home' || type == 'work') && !known.containsKey(type) && v('${type}Lat').isEmpty) key = type;
      if (key == null) {
        key = 'saved:srv-$id';
        saved.add({'id': 'srv-$id'});
      }
      seen.add(key);
      known[key] = {'id': id, 'fp': ''};
      if (key == 'home' || key == 'work') {
        setPlaceFields(key, pl);
        continue;
      }
      final i = saved.indexWhere((m) => 'saved:${m['id']}' == key);
      if (i < 0) continue;
      final loc = Map<String, dynamic>.from(pl['location'] as Map);
      saved[i] = {
        ...saved[i],
        'name': '${pl['label'] ?? '장소'}',
        'type': _placeTypeName[type] ?? (saved[i]['type'] ?? '기타'),
        'address': '${pl['address'] ?? ''}',
        'lat': loc['lat'],
        'lon': loc['lng'],
        'alert': pl['notify'] != false,
      };
    }
    // 서버에서 지워진 장소는 화면에서도 지운다
    for (final key in known.keys.where((k) => !seen.contains(k)).toList()) {
      known.remove(key);
      if (key == 'home' || key == 'work') {
        for (final f in ['Lat', 'Lon', 'Address', 'Name']) {
          set('$key$f', '');
        }
      } else {
        saved.removeWhere((m) => 'saved:${m['id']}' == key);
      }
    }

    // 비상 연락처 (서버 첫 번째)
    final contacts = (user['contacts'] as List?) ?? const [];
    if (contacts.isEmpty) {
      if (prefs.containsKey(_contactKey)) set('비상 연락처', '');
      await prefs.remove(_contactKey);
    } else {
      final c = Map<String, dynamic>.from(contacts.first as Map);
      final mine = desiredContact(prefs);
      if (mine == null || mine['phone'] != c['phone']) set('비상 연락처', '${c['name'] ?? ''} ${c['phone']}'.trim());
    }

    if (o.isNotEmpty || prefs.containsKey('optional_profile')) await prefs.setString('optional_profile', jsonEncode(o));
    await prefs.setString('saved_places', jsonEncode(saved));
    // 지금 화면 값 = 서버 값 → 다음 올림에서 다시 보내지 않게 지문·기준값을 맞춘다
    final desired = desiredPlaces(prefs);
    for (final k in known.keys) {
      known[k] = {'id': known[k]!['id']!, 'fp': desired[k] == null ? '' : jsonEncode(desired[k])};
    }
    await prefs.setString(_placeIdsKey, jsonEncode(known));
    if (contacts.isNotEmpty) {
      final want = desiredContact(prefs);
      await prefs.setString(_contactKey,
          jsonEncode({'id': '${(contacts.first as Map)['id']}', 'fp': want == null ? '' : jsonEncode(want)}));
    }
    await prefs.setString(_baseKey, jsonEncode(profilePatch(prefs, now: now)));
    return before != jsonEncode(snapshot(prefs));
  }
}

/// AI가 대화에서 들은 사용자 정보로 프로필을 고친 기록 한 줄 (서버 care.profile_updates)
class ProfileUpdate {
  const ProfileUpdate({required this.id, required this.label, required this.value, this.quote, this.createdAt});
  final int id;
  final String label, value;
  final String? quote;
  final DateTime? createdAt;
  factory ProfileUpdate.fromJson(Map<String, dynamic> j) => ProfileUpdate(
      id: (j['id'] as num).toInt(),
      label: '${j['label'] ?? j['field'] ?? ''}',
      value: '${j['value'] ?? ''}',
      quote: (j['quote'] as String?)?.trim().isEmpty ?? true ? null : (j['quote'] as String).trim(),
      createdAt: DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal());
}

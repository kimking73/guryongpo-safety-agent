import 'dart:convert';
import 'dart:math';
import '../models/domain_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SignInMethod { anonymous, google, naver, email }

class AccountService {
  static const _modeKey = 'user_mode';
  static const _methodKey = 'sign_in_method';
  Future<String?> savedMode() async =>
      (await SharedPreferences.getInstance()).getString(_modeKey);
  Future<void> saveMode(String mode) async =>
      (await SharedPreferences.getInstance()).setString(_modeKey, mode);
  Future<void> saveRequiredSetup({required String age, required String transport}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_age', age);
    await prefs.setString('profile_transport', transport);
    await prefs.setBool('profile_setup_complete', true);
  }
  /// (연령, 이동수단). 입력 전이면 null
  Future<(int?, String?)> requiredSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return (int.tryParse(prefs.getString('profile_age') ?? ''), prefs.getString('profile_transport'));
  }
  /// Firebase 없이도 기기마다 다른 사용자 ID (AI 대화·기억을 사용자별로 나눈다). 처음 부를 때 만들어 저장한다.
  Future<String> deviceUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('device_user_id');
    if (saved != null) return saved;
    final r = Random.secure();
    final id = 'device-${List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join()}';
    await prefs.setString('device_user_id', id);
    return id;
  }
  /// 선택 정보 '보행 능력'에 무엇이든 적었으면 보행 불편으로 본다 (노약자 경로)
  Future<bool> walkingImpaired() async => ((await optionalProfile())['보행 능력'] ?? '').trim().isNotEmpty;

  static const _placesKey = 'saved_places';
  Future<List<SavedPlace>> places() async {
    final raw = (await SharedPreferences.getInstance()).getString(_placesKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((j) => SavedPlace.fromJson(j as Map<String, dynamic>)).toList();
  }
  Future<void> _savePlaces(List<SavedPlace> places) async =>
      (await SharedPreferences.getInstance()).setString(_placesKey, jsonEncode(places.map((p) => p.toJson()).toList()));
  Future<void> addPlace(SavedPlace place) async => _savePlaces([...await places(), place]);
  Future<void> removePlace(String id) async => _savePlaces([...(await places()).where((p) => p.id != id)]);

  Future<bool> hasCompletedSetup() async => (await SharedPreferences.getInstance()).getBool('profile_setup_complete') ?? false;
  Future<Map<String, String>> optionalProfile() async {
    final raw = (await SharedPreferences.getInstance()).getString('optional_profile');
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).map((key, value) => MapEntry('$key', '$value'));
  }
  Future<void> saveOptionalProfile(Map<String, String> values) async =>
      (await SharedPreferences.getInstance()).setString('optional_profile', jsonEncode(values));
  Future<String?> savedMethod() async =>
      (await SharedPreferences.getInstance()).getString(_methodKey);
  Future<void> signInMock(SignInMethod method) async =>
      (await SharedPreferences.getInstance())
          .setString(_methodKey, method.name);
}

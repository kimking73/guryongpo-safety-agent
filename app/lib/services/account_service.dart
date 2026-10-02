import 'dart:convert';
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

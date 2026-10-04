import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/account_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('서버 판단용 칸: 연령→출생연도, 휠체어→wheelchair, 직업·보행·시각·청각', () async {
    final prefs = await prefsWith({
      'profile_age': '67',
      'profile_transport': '휠체어',
      'optional_profile': jsonEncode({'jobs': '어업 종사자·뱃사람|기타', '보행 능력': '지팡이', '시각 지원': '저시력'}),
    });
    expect(AccountSync.profilePatch(prefs, now: DateTime(2026, 10, 5)), {
      'birth_year': 1959,
      'mobility': 'wheelchair',
      'occupation': '어업 종사자·뱃사람, 기타',
      'owns_vessel': true,
      'walking_ability': 'limited',
      'vision_impaired': true,
    });
  });

  test('아무것도 입력 안 했으면 보낼 칸 없음', () async {
    final prefs = await prefsWith({});
    expect(AccountSync.profilePatch(prefs), isEmpty);
    expect(AccountSync.desiredPlaces(prefs), isEmpty);
    expect(AccountSync.hasLocalData(prefs), isFalse);
  });

  test('장소: 프로필의 집·직장 + 저장 장소 목록 → 서버 장소', () async {
    final prefs = await prefsWith({
      'optional_profile': jsonEncode({
        'homeName': '우리집', 'homeAddress': '구룡포읍 호미로 152', 'homeLat': '35.98', 'homeLon': '129.55',
        'workAddress': '주소만 있고 좌표 없음',
      }),
      'saved_places': jsonEncode([
        {'id': '1', 'name': '어머니댁', 'type': '자주 가는 곳', 'address': '', 'lat': 35.99, 'lon': 129.56, 'alert': false},
        {'id': '2', 'name': '펜션', 'type': '숙소', 'address': '구룡포 펜션', 'lat': 35.97, 'lon': 129.55},
      ]),
    });
    final d = AccountSync.desiredPlaces(prefs);
    expect(d.keys, ['home', 'saved:1', 'saved:2']); // 좌표 없는 직장은 빠짐
    expect(d['home'], {
      'place_type': 'home', 'label': '우리집', 'address': '구룡포읍 호미로 152',
      'location': {'lat': 35.98, 'lng': 129.55}, 'notify': true,
    });
    expect(d['saved:1']!['place_type'], 'frequent');
    expect(d['saved:1']!['notify'], false);
    expect(d['saved:1']!.containsKey('address'), isFalse);
    expect(d['saved:2']!['place_type'], 'lodging');
  });

  test('통째 저장본: 저장 → 다른 기기에 복원하면 같은 값, 저장본에 없는 항목은 지움', () async {
    final a = await prefsWith({
      'profile_age': '30',
      'profile_setup_complete': true,
      'optional_profile': jsonEncode({'직업': '자영업자'}),
      'unrelated': 'x',
    });
    final snap = AccountSync.snapshot(a);
    expect((snap['prefs'] as Map).keys.toSet(), {'profile_age', 'profile_setup_complete', 'optional_profile'});

    final b = await prefsWith({'saved_places': '[]', 'profile_age': '99'});
    await AccountSync.applySnapshot(b, jsonDecode(jsonEncode(snap)) as Map<String, dynamic>);
    expect(b.getString('profile_age'), '30');
    expect(b.getBool('profile_setup_complete'), isTrue);
    expect(b.getString('optional_profile'), jsonEncode({'직업': '자영업자'}));
    expect(b.containsKey('saved_places'), isFalse);
  });

  test('예시 데이터 모드에서는 서버와 주고받지 않는다', () async {
    expect(AccountSync.instance.enabled, isFalse);
    await AccountSync.instance.changed();
    await AccountSync.instance.pullOrPush();
  });
}

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
      'occupation': 'fisher, other',
      'owns_vessel': true,
      'walking_ability': 'normal',     // '지팡이'는 화면 선택지가 아니다 → 보통
      'vision_impaired': true,
      'hearing_impaired': false,
      'has_dependents': false,
      'blood_type': null,
    });
  });

  test('프로필 화면에서 고친 이동수단·연령이 첫 설정 값보다 우선, 자동차 → car', () async {
    final prefs = await prefsWith({
      'profile_age': '30',
      'profile_transport': '도보',
      'optional_profile': jsonEncode({'age': '45', 'transport': '자동차'}),
    });
    final p = AccountSync.profilePatch(prefs, now: DateTime(2026, 10, 5));
    expect(p['mobility'], 'car');
    expect(p['birth_year'], 1981);
  });

  test('보행 능력: 보행 가능 → normal, 보행 어려움 → unable (AI가 서버 프로필을 읽는다, 2026-10-08)', () async {
    for (final (choice, want) in [('보행 가능', 'normal'), ('보행 불편', 'limited'), ('보행 어려움', 'unable')]) {
      final prefs = await prefsWith({'optional_profile': jsonEncode({'보행 능력': choice})});
      expect(AccountSync.profilePatch(prefs)['walking_ability'], want, reason: choice);
    }
  });

  test('판단용 칸 = 화면 값 (2026-10-08): 필요 없음 → 아니오, 보호 동반자·혈액형, 직접 입력한 직업은 그대로', () async {
    final prefs = await prefsWith({
      'optional_profile': jsonEncode({
        '시각 지원': '필요 없음', '청각 지원': '난청', '보호가 필요한 동반자 여부': '예', '혈액형': 'O+',
        '직업': '수산업자', 'jobs': '학생',
      }),
    });
    final p = AccountSync.profilePatch(prefs);
    expect(p['vision_impaired'], false);
    expect(p['hearing_impaired'], true);
    expect(p['has_dependents'], true);
    expect(p['blood_type'], 'O+');
    expect(p['occupation'], '수산업자, student');
    expect(p['owns_vessel'], false);
  });

  test('프로필 화면에서 지운 칸은 서버 기본값으로 되돌린다, 예전 칸 이름도 읽는다', () async {
    final prefs = await prefsWith({'optional_profile': jsonEncode({'보호 동반자': '예', '혈액형': '모름'})});
    final p = AccountSync.profilePatch(prefs);
    expect(p['has_dependents'], true);
    expect(p['blood_type'], null);
    expect(p.containsKey('blood_type'), isTrue);
    expect(p['occupation'], null);
    expect(p['walking_ability'], 'normal');
  });

  test('비상 연락처 글자 → 이름·전화번호, 번호가 없으면 보내지 않음', () async {
    var prefs = await prefsWith({'optional_profile': jsonEncode({'비상 연락처': '딸 010-1234-5678'})});
    expect(AccountSync.desiredContact(prefs), {'name': '딸', 'phone': '010-1234-5678', 'priority': 1});
    prefs = await prefsWith({'optional_profile': jsonEncode({'비상연락처': '01098765432'})});
    expect(AccountSync.desiredContact(prefs)!['name'], '비상 연락처');
    prefs = await prefsWith({'optional_profile': jsonEncode({'비상 연락처': '옆집 아주머니'})});
    expect(AccountSync.desiredContact(prefs), isNull);
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

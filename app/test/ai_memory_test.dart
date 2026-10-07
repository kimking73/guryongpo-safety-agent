import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/account_service.dart';
import 'package:guryongpo_safety/services/ai_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI 기억 → 프로필 칸 (2026-10-07)
void main() {
  test('AI 기억 항목을 프로필 칸·값으로 바꾼다', () {
    expect(memoryToProfile('age', '78'), ('age', '78'));
    expect(memoryToProfile('age', '78세'), ('age', '78'));
    expect(memoryToProfile('mobility', 'wheelchair'), ('transport', '휠체어'));
    expect(memoryToProfile('mobility', 'public_transport'), isNull);       // 프로필에 고를 칸 없음
    expect(memoryToProfile('walking_impaired', 'true'), ('보행 능력', '보행 불편'));
    expect(memoryToProfile('walking_impaired', 'false'), ('보행 능력', '보행 가능'));
    expect(memoryToProfile('has_dependents', 'true'), ('보호가 필요한 동반자 여부', '예'));
    expect(memoryToProfile('occupation', '어선을 가진 어부'), ('직업', '어업 종사자·뱃사람'));
    expect(memoryToProfile('occupation', '목수'), ('직업', '기타'));          // 선택지에 없으면 기타
    expect(memoryToProfile('frequent_place:구룡포시장', '구룡포시장'), ('자주 방문하는 장소', '구룡포시장'));
    expect(memoryToProfile('note:보청기 사용', '보청기 사용'), isNull);
    expect(factLabel('frequent_place:구룡포시장'), '자주 가는 곳');
  });

  test("'보행 가능'은 보행 불편이 아니다", () async {
    SharedPreferences.setMockInitialValues({});
    final acc = AccountService();
    await acc.saveOptionalProfile({'보행 능력': '보행 가능'});
    expect(await acc.walkingImpaired(), isFalse);
    await acc.saveOptionalProfile({'보행 능력': '보행 불편'});
    expect(await acc.walkingImpaired(), isTrue);
  });

  test('가장 최근 값이 이긴다: 새 기억은 덮어쓰고, 반영 뒤 직접 고친 값은 유지', () {
    Map<String, dynamic> facts(String age, String at) => {'age': {'value': age, 'quote': '$age살', 'updated_at': at}};
    final applied = <String, String>{};
    // 1) 프로필 30 · 새 기억 50 → 덮어씀
    var (items, fill) = planMemorySync(facts('50', 't1'), {'age': '30'}, applied);
    expect(items.single.status, AiMemoryStatus.overwritten);
    expect(fill, {'age': '50'});
    // 2) 그 뒤 사용자가 프로필을 40으로 직접 고침 · 기억은 그대로(t1) → 유지
    (items, fill) = planMemorySync(facts('50', 't1'), {'age': '40'}, applied);
    expect(items.single.status, AiMemoryStatus.differs);
    expect(fill, isEmpty);
    // 3) 대화에서 다시 말함 (t2) → 덮어씀
    (items, fill) = planMemorySync(facts('51', 't2'), {'age': '40'}, applied);
    expect(items.single.status, AiMemoryStatus.overwritten);
    expect(fill, {'age': '51'});
    // 빈 칸은 채움, 자주 가는 곳은 덧붙임
    (items, fill) = planMemorySync({'frequent_place:시장': {'value': '시장', 'updated_at': 't3'}},
        {'자주 방문하는 장소': '항구'}, applied);
    expect(fill, {'자주 방문하는 장소': '항구, 시장'});
  });

  test('직업은 사용자 상세 카드의 직업 칩에도 들어간다', () {
    var (_, fill) = planMemorySync({'occupation': {'value': '어선을 가진 어부', 'updated_at': 't1'}}, {}, {});
    expect(fill, {'직업': '어업 종사자·뱃사람', 'jobs': '어업 종사자·뱃사람'});
    (_, fill) = planMemorySync({'occupation': {'value': '목수', 'updated_at': 't1'}}, {'jobs': '자영업자'}, {});
    expect(fill['jobs'], '자영업자|기타');      // 칩에 없는 직업은 '기타'를 덧붙임
    // 칩 반영 전에 '선택 정보' 직업 칸에만 들어간 기억(same)도 칩을 더한다
    final applied = {'occupation': 't1'};
    (_, fill) = planMemorySync({'occupation': {'value': '전복 양식', 'updated_at': 't1'}}, {'직업': '기타'}, applied);
    expect(fill, {'jobs': '양식업 종사자·수산물 양식'});
    // 사용자가 직업을 직접 바꾼 뒤(differs)에는 칩도 건드리지 않는다
    (_, fill) = planMemorySync({'occupation': {'value': '어부', 'updated_at': 't1'}}, {'직업': '학생'}, applied);
    expect(fill, isEmpty);
  });

  test('첫 버전이 원문으로 넣은 직업("수산업자")도 같은 직업으로 보고 칩을 고른다', () {
    final applied = {'occupation': 't1'};
    final (items, fill) = planMemorySync({'occupation': {'value': '수산업자', 'updated_at': 't1'}}, {'직업': '수산업자'}, applied);
    expect(items.single.status, AiMemoryStatus.same);
    expect(fill, {'직업': '어업 종사자·뱃사람', 'jobs': '어업 종사자·뱃사람'});
  });
}


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
}

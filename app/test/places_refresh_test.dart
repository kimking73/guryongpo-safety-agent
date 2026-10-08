import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/services/account_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('서버 프로필을 내려받아 바뀌면 등록 장소 목록을 다시 읽는다 (AI가 더한 장소가 바로 보이게, 2026-10-08)', () async {
    SharedPreferences.setMockInitialValues({'saved_places': '[]'});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sub = c.listen(placesProvider, (_, __) {});
    addTearDown(sub.close);
    expect(await c.read(placesProvider.future), isEmpty);
    (await SharedPreferences.getInstance()).setString('saved_places', jsonEncode([
      {'id': 'srv-p9', 'name': '구룡포수협 위판장', 'type': '기타', 'address': '', 'lat': 35.99, 'lon': 129.56, 'alert': true}
    ]));
    AccountSync.updated.value++;
    expect((await c.read(placesProvider.future)).single.name, '구룡포수협 위판장');
  });
}

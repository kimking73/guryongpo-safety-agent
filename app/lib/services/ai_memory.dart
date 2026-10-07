import 'dart:convert';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latlong2/latlong.dart';
import '../models/domain_models.dart';
import 'account_service.dart';
import 'api_client.dart';
import 'app_config.dart';
import 'auth_service.dart';
import 'demo_mode.dart';

/// AI가 기억한 사용자 정보 → 앱 프로필 (2026-10-07).
///
/// AI는 대화에서 사용자가 자기에 대해 직접 말한 것(나이·보행 불편·이동 수단 등)을 장기 기억에 남긴다
/// (ai/guardian_ai/memory.py). 여기서 로그인한 본인 기억(GET /api/ai/me/memory)을 받아 '가장 최근 값'으로 맞춘다:
///   - 프로필 칸이 비어 있으면 채운다
///   - 새로 생기거나 바뀐 기억(updated_at 이 지난번 반영과 다름)이면 프로필 값이 달라도 덮어쓴다 (사용자 요청)
///   - 이미 반영한 기억인데 프로필이 다르면 = 그 뒤에 사용자가 프로필을 직접 고친 것 → 유지하고 [반영]만 보여 준다
/// 반영 기록은 'ai_memory_applied' ({기억 키: updated_at}, 계정 동기화 항목).
/// 프로필 값이 AI 요청에서 항상 우선이므로(앱이 보낸 값 > 기억), 프로필에 들어가야 경로·답에 확실히 쓰인다.
enum AiMemoryStatus { same, filled, overwritten, differs, noField }

class AiMemoryItem {
  const AiMemoryItem({
    required this.key,
    required this.label,
    required this.value,
    required this.quote,
    required this.status,
    this.profileKey,
    this.profileValue,
    this.current,
    this.fill,
    this.place,
  });

  /// AI 기억의 키 (age, mobility, frequent_place:… 등) — 지우기에 쓴다
  final String key;
  final String label;

  /// 화면에 보이는 값 (프로필 칸 값으로 바꾼 것, 칸이 없으면 기억 원문)
  final String value;

  /// 근거가 된 사용자 발언
  final String quote;
  final AiMemoryStatus status;

  /// 이 기억이 들어갈 프로필 칸 (optional_profile 키)과 넣을 값. 칸이 없으면 null
  final String? profileKey, profileValue;

  /// 지금 프로필 값 (다를 때 비교용)
  final String? current;

  /// 집 주소처럼 여러 칸을 한 번에 쓰는 기억 ([반영] 때 그대로 저장), 내 장소에 넣을 장소 (자주 가는 곳)
  final Map<String, String>? fill;
  final SavedPlace? place;
}

class AiMemoryService {
  AiMemoryService({AccountService? account, ApiClient? client, AuthService? auth})
      : _account = account ?? AccountService(),
        _auth = auth ?? AuthService(),
        _client = client ?? ApiClient(auth ?? AuthService());
  final AccountService _account;
  final AuthService _auth;
  final ApiClient _client;

  /// 서버 연결 + 로그인 (Firebase uid) 일 때만 — 기기 ID 사용자는 기억 조회 토큰이 없다
  bool get available => AppConfig.isRemote && _auth.uid != null;

  /// 기억을 받아 빈 프로필 칸을 채우고, 항목별 상태를 돌려준다. 받지 못하면 빈 목록
  Future<List<AiMemoryItem>> sync() async {
    if (!available) return const [];
    final Map<String, dynamic> facts;
    try {
      final r = await _client.ai.get<Map<String, dynamic>>('/api/ai/me/memory');
      facts = (r.data?['facts'] as Map?)?.cast<String, dynamic>() ?? const {};
    } on DioException {
      return const [];
    }
    final profile = await _profileValues();
    final applied = await _applied();
    final (items, fill) = planMemorySync(facts, profile, applied);   // applied 도 이 안에서 갱신
    // 집 주소·자주 가는 곳(좌표 있는 것) → 프로필 집 주소·내 장소 (2026-10-08)
    final (placeItems, homeFill, newPlaces) = planPlaceSync(facts, profile, await _account.places(), applied);
    fill.addAll(homeFill);
    if (fill.isNotEmpty) await _save(fill);
    for (final p in newPlaces) {
      await _account.addPlace(p);
    }
    if (fill.isNotEmpty || newPlaces.isNotEmpty) changed.value++;     // 열려 있는 프로필 화면이 다시 읽게
    await _saveApplied(applied);
    return [...items, ...placeItems];
  }

  /// '프로필과 다름' 항목을 프로필에 반영 (자주 가는 곳은 덧붙임)
  Future<void> apply(AiMemoryItem item) async {
    if (item.place != null) {
      await _account.addPlace(item.place!);
      changed.value++;
      return;
    }
    if (item.fill != null) {
      await _save(item.fill!);
      changed.value++;
      return;
    }
    final k = item.profileKey, v = item.profileValue;
    if (k == null || v == null) return;
    final cur = (await _profileValues())[k] ?? '';
    await _save({k: mergedProfileValue(k, cur, v), if (k == '직업') ..._jobsWith(jobChip(v), await _account.optionalProfile())});
    changed.value++;
  }

  /// 기억에서 지우기 (AI가 다음 대화부터 쓰지 않는다)
  Future<bool> forget(AiMemoryItem item) async {
    try {
      await _client.ai.delete<Map<String, dynamic>>('/api/ai/me/memory/facts/${Uri.encodeComponent(item.key)}');
      return true;
    } on DioException {
      return false;
    }
  }

  /// 프로필에 AI 기억을 써 넣을 때마다 오른다 — 프로필 화면(AiMemoryCard)이 듣고 카드들을 다시 읽게 한다
  static final changed = ValueNotifier<int>(0);

  /// 대화 뒤 몇 초 기다렸다 빈 칸 채우기 (기억 저장은 답이 나간 뒤 백그라운드라 바로는 없다). 시연 대화는 기억에 안 남는다
  static void fillAfterChat() {
    if (DemoData.on || !AppConfig.isRemote) return;
    Future<void>.delayed(const Duration(seconds: 12), () async {
      try {
        await AiMemoryService().sync();
      } catch (_) {}
    });
  }

  /// 지금 프로필 값 — 첫 설정(나이·이동 수단)도 포함
  Future<Map<String, String>> _profileValues() async {
    final o = await _account.optionalProfile();
    final (age, transport) = await _account.requiredSetup();
    return {
      ...o,
      if ((o['age'] ?? '').isEmpty && age != null) 'age': '$age',
      if ((o['transport'] ?? '').isEmpty && transport != null) 'transport': transport,
    };
  }

  Future<void> _save(Map<String, String> values) async {
    await _account.saveOptionalProfile({...await _account.optionalProfile(), ...values});
  }


  static const _appliedKey = 'ai_memory_applied';

  Future<Map<String, String>> _applied() async {
    final raw = (await SharedPreferences.getInstance()).getString(_appliedKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveApplied(Map<String, String> applied) async {
    await (await SharedPreferences.getInstance()).setString(_appliedKey, jsonEncode(applied));
  }
}

const _factLabels = {
  'age': '나이',
  'walking_impaired': '보행 불편',
  'has_dependents': '보호가 필요한 동반자',
  'mobility': '이동 수단',
  'occupation': '직업',
  'frequent_place': '자주 가는 곳',
  'home_address': '집 주소',
  'note': '기타',
};

String factLabel(String key) => _factLabels[key.split(':').first] ?? '기타';

bool _yes(String v) => const ['true', '1', 'yes', '예'].contains(v.trim().toLowerCase());

/// AI 기억 (키, 값) → (프로필 칸, 넣을 값). 들어갈 칸이 없으면 null
(String, String)? memoryToProfile(String key, String value) {
  final v = value.trim();
  if (v.isEmpty) return null;
  switch (key.split(':').first) {
    case 'age':
      final n = int.tryParse(RegExp(r'\d+').firstMatch(v)?.group(0) ?? '');
      return n == null ? null : ('age', '$n');
    case 'mobility':
      final t = switch (v) { 'walk' => '도보', 'wheelchair' => '휠체어', 'car' => '자동차', _ => null };
      return t == null ? null : ('transport', t);
    case 'walking_impaired':
      return ('보행 능력', _yes(v) ? '보행 불편' : '보행 가능');
    case 'has_dependents':
      return ('보호가 필요한 동반자 여부', _yes(v) ? '예' : '아니요');
    case 'occupation':
      return ('직업', jobChoice(v));
    case 'frequent_place':
      return ('자주 방문하는 장소', v);
    default:
      return null;
  }
}

bool _same(String key, String cur, String v) => key == '자주 방문하는 장소' ? cur.contains(v) : cur == v;

/// 자주 가는 곳은 덧붙이고, 나머지는 바꾼다
String mergedProfileValue(String key, String cur, String v) =>
    key == '자주 방문하는 장소' && cur.trim().isNotEmpty ? '$cur, $v' : v;

/// 기억(facts: 키 → {value, quote, updated_at}) + 지금 프로필 + 반영 기록 → (항목별 상태, 프로필에 쓸 값).
/// 가장 최근 값이 이긴다: 빈 칸 채움 · 새로 말한 기억은 덮어씀 · 반영 뒤 사용자가 직접 고친 값은 유지. applied 를 갱신한다
(List<AiMemoryItem>, Map<String, String>) planMemorySync(
    Map<String, dynamic> facts, Map<String, String> profile, Map<String, String> applied) {
  final fill = <String, String>{};
  final items = <AiMemoryItem>[];
  for (final e in facts.entries) {
    final f = (e.value as Map).cast<String, dynamic>();
    if (_isPlaceFact(e.key, f)) continue;     // 집 주소·좌표 있는 자주 가는 곳은 planPlaceSync
    final mapped = memoryToProfile(e.key, '${f['value'] ?? ''}');
    final quote = '${f['quote'] ?? ''}';
    final stamp = '${f['updated_at'] ?? ''}';
    if (mapped == null) {
      items.add(AiMemoryItem(
          key: e.key, label: factLabel(e.key), value: '${f['value'] ?? ''}', quote: quote,
          status: AiMemoryStatus.noField));
      continue;
    }
    final (pk, pv) = mapped;
    final cur = (profile[pk] ?? '').trim();
    // 직업은 선택지 이름으로 바꿔 비교한다 (2026-10-08): 첫 버전이 원문("수산업자")을 칸에 넣었는데 지금은 "어업 종사자·뱃사람"으로
    // 바꾸므로, 그대로 비교하면 '사용자가 직접 바꾼 값'으로 오해해 칩 반영을 건너뛰었다. 같은 직업이면 칸도 선택지 이름으로 정리
    final sameJob = pk == '직업' && cur.isNotEmpty && cur != pv && jobChoice(cur) == pv;
    if (sameJob) fill[pk] = pv;
    final status = cur.isEmpty
        ? AiMemoryStatus.filled
        : sameJob || _same(pk, cur, pv)
            ? AiMemoryStatus.same
            : applied[e.key] != stamp
                ? AiMemoryStatus.overwritten     // 새로 말한 내용 → 덮어씀
                : AiMemoryStatus.differs;        // 반영한 뒤 사용자가 프로필을 직접 고침 → 유지
    if (status == AiMemoryStatus.filled) fill[pk] = pv;
    if (status == AiMemoryStatus.overwritten) fill[pk] = mergedProfileValue(pk, cur, pv);
    // 직업은 사용자 상세 카드의 직업 칩(jobs, '|'로 이음)에도 (2026-10-08). 이미 반영된(same) 기억도 칩이 없으면 더한다 —
    // 칩 반영 전에 저장된 기억은 '선택 정보' 직업 칸에만 들어가 있었다. 사용자가 직접 고친(differs) 경우만 건드리지 않는다
    if (pk == '직업' && status != AiMemoryStatus.differs) {
      fill.addAll(_jobsWith(jobChip('${f['value'] ?? ''}'), profile));
    }
    if (status != AiMemoryStatus.differs) applied[e.key] = stamp;
    items.add(AiMemoryItem(
        key: e.key, label: factLabel(e.key), value: pv, quote: quote, status: status,
        profileKey: pk, profileValue: pv, current: cur.isEmpty ? null : cur));
  }
  return (items, fill);
}

/// 사용자 상세 카드의 직업 칩 (disaster_center.dart ProfileDetailsCard.jobOptions 와 같게)
const profileJobOptions = ['어업 종사자·뱃사람', '자영업자', '농업 종사자', '축산업 종사자', '양식업 종사자·수산물 양식', '기타'];

/// 선택 정보 카드 '직업' 선택지 (main.dart OptionalDetailsCard.choices 와 같게)
const optionalJobChoices = ['어업 종사자·뱃사람', '자영업자', '농업 종사자', '직장인', '학생', '기타'];

/// 직업 기억(자유 문장) → 선택 정보 카드 '직업' 선택지
String jobChoice(String raw) =>
    RegExp('어업|어선|어부|뱃|선장|선원|해녀|수산').hasMatch(raw) ? '어업 종사자·뱃사람'
    : RegExp('농업|농사|농부|과수').hasMatch(raw) ? '농업 종사자'
    : RegExp('자영업|가게|식당|장사|상인').hasMatch(raw) ? '자영업자'
    : RegExp('회사|직장|공무원|사무').hasMatch(raw) ? '직장인'
    : RegExp('학생').hasMatch(raw) ? '학생'
    : optionalJobChoices.contains(raw) ? raw : '기타';

/// 직업 기억 → 사용자 상세 카드 직업 칩 (양식·축산은 칩이 따로 있다. 먼저 본다 — '수산물 양식'이 어업에 걸리지 않게)
String jobChip(String raw) =>
    RegExp('양식').hasMatch(raw) ? '양식업 종사자·수산물 양식'
    : RegExp('축산|가축|목장|소 키|돼지').hasMatch(raw) ? '축산업 종사자'
    : RegExp('어업|어선|어부|뱃|선장|선원|해녀|수산').hasMatch(raw) ? '어업 종사자·뱃사람'
    : RegExp('농업|농사|농부|과수').hasMatch(raw) ? '농업 종사자'
    : RegExp('자영업|가게|식당|장사|상인').hasMatch(raw) ? '자영업자'
    : profileJobOptions.contains(raw) ? raw : '기타';

/// 직업 칩 하나를 jobs 칩 목록에 더한 값 ({'jobs': 'a|b'}). 이미 있으면 빈 맵
Map<String, String> _jobsWith(String chip, Map<String, String> profile) {
  final jobs = (profile['jobs'] ?? '').split('|').where((x) => x.isNotEmpty).toList();
  if (jobs.contains(chip)) return const {};
  return {'jobs': [...jobs, chip].join('|')};
}

/// 집 주소, 또는 좌표를 찾은 자주 가는 곳 — 프로필 칸이 아니라 집 주소·내 장소로 간다
bool _isPlaceFact(String key, Map<String, dynamic> f) =>
    key == 'home_address' || (key.startsWith('frequent_place') && f['lat'] is num && f['lon'] is num);

/// 집 주소 → 프로필 집(homeAddress·좌표), 좌표 있는 자주 가는 곳 → 내 장소 (2026-10-08).
/// 규칙은 planMemorySync 와 같다: 빈 칸은 채움, 새로 말한 기억은 덮어씀, 반영한 뒤 사용자가 바꾸거나 지운 것은 유지.
/// 돌려주는 것: (항목별 상태, 프로필에 쓸 값, 내 장소에 더할 장소). applied 를 갱신한다
(List<AiMemoryItem>, Map<String, String>, List<SavedPlace>) planPlaceSync(Map<String, dynamic> facts,
    Map<String, String> profile, List<SavedPlace> places, Map<String, String> applied) {
  final items = <AiMemoryItem>[];
  final fill = <String, String>{};
  final add = <SavedPlace>[];
  const dist = Distance();
  for (final e in facts.entries) {
    final f = (e.value as Map).cast<String, dynamic>();
    if (!_isPlaceFact(e.key, f)) continue;
    final value = '${f['value'] ?? ''}'.trim();
    final address = '${f['address'] ?? ''}'.trim().isEmpty ? value : '${f['address']}'.trim();
    final stamp = '${f['updated_at'] ?? ''}';
    final quote = '${f['quote'] ?? ''}';
    final lat = (f['lat'] as num?)?.toDouble(), lon = (f['lon'] as num?)?.toDouble();
    if (e.key == 'home_address') {
      final cur = (profile['homeAddress'] ?? '').trim();
      final values = {
        'homeName': (profile['homeName'] ?? '').trim().isEmpty ? '집' : profile['homeName']!,
        'homeAddress': address,
        // 좌표를 못 찾았으면 예전 좌표를 지운다 (다른 집의 좌표가 남지 않게)
        'homeLat': lat == null ? '' : '$lat',
        'homeLon': lon == null ? '' : '$lon',
      };
      final status = cur.isEmpty
          ? AiMemoryStatus.filled
          : cur == address || cur == value
              ? AiMemoryStatus.same
              : applied[e.key] != stamp
                  ? AiMemoryStatus.overwritten
                  : AiMemoryStatus.differs;
      if (status == AiMemoryStatus.filled || status == AiMemoryStatus.overwritten) fill.addAll(values);
      if (status != AiMemoryStatus.differs) applied[e.key] = stamp;
      items.add(AiMemoryItem(
          key: e.key, label: '집 주소', value: address, quote: quote, status: status,
          current: cur.isEmpty ? null : cur, fill: values));
      continue;
    }
    final here = LatLng(lat!, lon!);
    final place = SavedPlace(
        id: 'ai-${e.key.hashCode.toUnsigned(31)}', name: value, type: '기타', position: here, address: address);
    final exists = places.any((p) => p.name == value || dist.as(LengthUnit.Meter, p.position, here) < 50);
    final status = exists
        ? AiMemoryStatus.same
        : applied[e.key] == stamp
            ? AiMemoryStatus.differs        // 내 장소에 넣은 뒤 사용자가 지움 → 다시 넣지 않는다
            : AiMemoryStatus.filled;
    if (status == AiMemoryStatus.filled) add.add(place);
    if (status != AiMemoryStatus.differs) applied[e.key] = stamp;
    items.add(AiMemoryItem(
        key: e.key, label: '자주 가는 곳 → 내 장소', value: '$value ($address)', quote: quote, status: status, place: place));
  }
  return (items, fill, add);
}


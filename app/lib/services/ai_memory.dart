import 'package:dio/dio.dart';
import 'account_service.dart';
import 'api_client.dart';
import 'app_config.dart';
import 'auth_service.dart';
import 'demo_mode.dart';

/// AI가 기억한 사용자 정보 → 앱 프로필 (2026-10-07).
///
/// AI는 대화에서 사용자가 자기에 대해 직접 말한 것(나이·보행 불편·이동 수단 등)을 장기 기억에 남긴다
/// (ai/guardian_ai/memory.py). 여기서 로그인한 본인 기억(GET /api/ai/me/memory)을 받아
///   - 프로필 칸이 비어 있으면 자동으로 채우고
///   - 이미 다른 값이 있으면 덮어쓰지 않고 '프로필과 다름'으로 보여 사용자가 고르게 한다 (AiMemoryCard).
/// 프로필 값이 AI 요청에서 항상 우선이므로(앱이 보낸 값 > 기억), 프로필에 들어가야 경로·답에 확실히 쓰인다.
enum AiMemoryStatus { same, filled, differs, noField }

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
    final fill = <String, String>{};
    final items = <AiMemoryItem>[];
    for (final e in facts.entries) {
      final f = (e.value as Map).cast<String, dynamic>();
      final mapped = memoryToProfile(e.key, '${f['value'] ?? ''}');
      final quote = '${f['quote'] ?? ''}';
      if (mapped == null) {
        items.add(AiMemoryItem(
            key: e.key, label: factLabel(e.key), value: '${f['value'] ?? ''}', quote: quote,
            status: AiMemoryStatus.noField));
        continue;
      }
      final (pk, pv) = mapped;
      final cur = (profile[pk] ?? '').trim();
      final status = cur.isEmpty
          ? AiMemoryStatus.filled
          : _same(pk, cur, pv)
              ? AiMemoryStatus.same
              : AiMemoryStatus.differs;
      if (status == AiMemoryStatus.filled) fill[pk] = pv;
      items.add(AiMemoryItem(
          key: e.key, label: factLabel(e.key), value: pv, quote: quote, status: status,
          profileKey: pk, profileValue: pv, current: cur.isEmpty ? null : cur));
    }
    if (fill.isNotEmpty) await _save(fill);
    return items;
  }

  /// '프로필과 다름' 항목을 프로필에 반영 (자주 가는 곳은 덧붙임)
  Future<void> apply(AiMemoryItem item) async {
    final k = item.profileKey, v = item.profileValue;
    if (k == null || v == null) return;
    final cur = (await _profileValues())[k] ?? '';
    await _save({k: k == '자주 방문하는 장소' && cur.trim().isNotEmpty ? '$cur, $v' : v});
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

  static bool _same(String key, String cur, String v) =>
      key == '자주 방문하는 장소' ? cur.contains(v) : cur == v;
}

const _factLabels = {
  'age': '나이',
  'walking_impaired': '보행 불편',
  'has_dependents': '보호가 필요한 동반자',
  'mobility': '이동 수단',
  'occupation': '직업',
  'frequent_place': '자주 가는 곳',
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
      final job = RegExp('어업|어선|어부|뱃|선장|선원|수산|해녀').hasMatch(v)
          ? '어업 종사자·뱃사람'
          : RegExp('농업|농사|농부|과수').hasMatch(v)
              ? '농업 종사자'
              : RegExp('학생').hasMatch(v)
                  ? '학생'
                  : RegExp('자영업|가게|식당|장사').hasMatch(v)
                      ? '자영업자'
                      : RegExp('회사|직장').hasMatch(v)
                          ? '직장인'
                          : v;
      return ('직업', job);
    case 'frequent_place':
      return ('자주 방문하는 장소', v);
    default:
      return null;
  }
}

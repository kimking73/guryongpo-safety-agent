import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_events.dart';

enum EvacuationResponseStatus { evacuated, evacuating, needHelp }

extension EvacuationResponseStatusLabel on EvacuationResponseStatus {
  String get label => switch (this) {
        EvacuationResponseStatus.evacuated => '대피 완료',
        EvacuationResponseStatus.evacuating => '대피 중',
        EvacuationResponseStatus.needHelp => '도움 필요',
      };

  String get wireValue => switch (this) {
        EvacuationResponseStatus.evacuated => 'evacuated',
        EvacuationResponseStatus.evacuating => 'evacuating',
        EvacuationResponseStatus.needHelp => 'need_help',
      };

  static EvacuationResponseStatus? fromWireValue(String? value) =>
      switch (value) {
        'evacuated' => EvacuationResponseStatus.evacuated,
        'evacuating' => EvacuationResponseStatus.evacuating,
        'need_help' => EvacuationResponseStatus.needHelp,
        _ => null,
      };
}

class AccessibilitySettings {
  const AccessibilitySettings({
    this.hearingSupport = false,
    this.visionSupport = false,
    this.strongVibration = true,
    this.screenFlash = false,
    this.largeText = true,
    this.voicePrompts = true,
  });

  final bool hearingSupport;
  final bool visionSupport;
  final bool strongVibration;
  final bool screenFlash;
  final bool largeText;
  final bool voicePrompts;

  AccessibilitySettings copyWith({
    bool? hearingSupport,
    bool? visionSupport,
    bool? strongVibration,
    bool? screenFlash,
    bool? largeText,
    bool? voicePrompts,
  }) =>
      AccessibilitySettings(
        hearingSupport: hearingSupport ?? this.hearingSupport,
        visionSupport: visionSupport ?? this.visionSupport,
        strongVibration: strongVibration ?? this.strongVibration,
        screenFlash: screenFlash ?? this.screenFlash,
        largeText: largeText ?? this.largeText,
        voicePrompts: voicePrompts ?? this.voicePrompts,
      );

  Map<String, Object> toJson() => {
        'hearingSupport': hearingSupport,
        'visionSupport': visionSupport,
        'strongVibration': strongVibration,
        'screenFlash': screenFlash,
        'largeText': largeText,
        'voicePrompts': voicePrompts,
      };

  factory AccessibilitySettings.fromJson(Map<String, dynamic> json) =>
      AccessibilitySettings(
        hearingSupport: json['hearingSupport'] == true,
        visionSupport: json['visionSupport'] == true,
        strongVibration: json['strongVibration'] != false,
        // Missing values in older or partially written preferences should be
        // safe by default. Explicitly saved user choices are preserved.
        screenFlash: json['screenFlash'] == true,
        largeText: json['largeText'] != false,
        voicePrompts: json['voicePrompts'] != false,
      );
}

class DemoHousehold {
  const DemoHousehold({
    required this.id,
    required this.label,
    required this.address,
    required this.members,
    required this.needs,
    required this.latitude,
    required this.longitude,
    required this.status,
    this.consentBy = '시연 동의',
    this.consentMethod = 'app',
    this.note = '',
  });

  final String id;
  final String label;
  final String address;
  final int members;
  final List<String> needs;
  final double latitude;
  final double longitude;
  final String status;
  final String consentBy;
  final String consentMethod;
  final String note;

  DemoHousehold copyWith({String? status}) => DemoHousehold(
        id: id,
        label: label,
        address: address,
        members: members,
        needs: needs,
        latitude: latitude,
        longitude: longitude,
        status: status ?? this.status,
        consentBy: consentBy,
        consentMethod: consentMethod,
        note: note,
      );

  Map<String, Object> toJson() => {
        'id': id,
        'label': label,
        'address': address,
        'members': members,
        'needs': needs,
        'latitude': latitude,
        'longitude': longitude,
        'status': status,
        'consentBy': consentBy,
        'consentMethod': consentMethod,
        'note': note,
      };

  factory DemoHousehold.fromJson(Map<String, dynamic> json) => DemoHousehold(
        id: '${json['id']}',
        label: '${json['label']}',
        address: '${json['address']}',
        members: (json['members'] as num?)?.toInt() ?? 1,
        needs: (json['needs'] as List? ?? const []).map((e) => '$e').toList(),
        latitude: (json['latitude'] as num?)?.toDouble() ?? 35.9918,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 129.5507,
        status: '${json['status'] ?? '미응답'}',
        consentBy: '${json['consentBy'] ?? '시연 동의'}',
        consentMethod: '${json['consentMethod'] ?? 'app'}',
        note: '${json['note'] ?? ''}',
      );
}

class DemoVisit {
  const DemoVisit({
    required this.householdId,
    required this.result,
    required this.note,
    required this.visitedAt,
  });

  final String householdId;
  final String result;
  final String note;
  final DateTime visitedAt;

  Map<String, Object> toJson() => {
        'householdId': householdId,
        'result': result,
        'note': note,
        'visitedAt': visitedAt.toIso8601String(),
      };

  factory DemoVisit.fromJson(Map<String, dynamic> json) => DemoVisit(
        householdId: '${json['householdId']}',
        result: '${json['result']}',
        note: '${json['note'] ?? ''}',
        visitedAt: DateTime.tryParse('${json['visitedAt']}') ?? DateTime.now(),
      );
}

/// 방재단 출동 기록 (시연, 2026-10-12): 방재단이 '내 방문 경로'에서 [출발]을 누르면 시민에게 출발 사실과 도착 예정 시각을 알린다.
/// stage: en_route(가는 중) · visiting(도착·방문 중) · done(완료)
class DemoDispatch {
  const DemoDispatch({required this.departedAt, required this.eta, required this.responder, this.stage = 'en_route'});

  final DateTime departedAt;
  final DateTime eta;
  final String responder;
  final String stage;

  DemoDispatch copyWith({String? stage}) =>
      DemoDispatch(departedAt: departedAt, eta: eta, responder: responder, stage: stage ?? this.stage);

  Map<String, Object> toJson() => {
        'departed_at': departedAt.toIso8601String(),
        'eta': eta.toIso8601String(),
        'responder': responder,
        'stage': stage,
      };

  factory DemoDispatch.fromJson(Map<String, dynamic> json) => DemoDispatch(
        departedAt: DateTime.parse('${json['departed_at']}'),
        eta: DateTime.parse('${json['eta']}'),
        responder: '${json['responder'] ?? '방재단'}',
        stage: '${json['stage'] ?? 'en_route'}',
      );
}

const _needsLabels = <String, String>{
  'elderly': '고령',
  'living_alone': '독거',
  'mobility_limited': '보행 불편',
  'wheelchair': '휠체어',
  'bedridden': '와상',
  'hearing': '청각 지원',
  'vision': '시각 지원',
  'cognitive': '인지 지원',
  'medical_device': '의료기기',
  'infant': '영유아',
  'pet': '반려동물',
};

String householdNeedLabel(String value) => _needsLabels[value] ?? value;

final prototypeSafetyProvider =
    ChangeNotifierProvider<PrototypeSafetyController>((ref) {
  final c = PrototypeSafetyController();
  // 같은 브라우저의 다른 창(예: 주민 창)이 시연 응답을 바꾸면 이 창(예: 방재단 창)도 바로 따라간다 (2026-10-11 사용자 요청)
  onOtherWindowStorageChange(c.syncFromStorage);
  return c;
});

class PrototypeSafetyController extends ChangeNotifier {
  static const _responsesKey = 'prototype_evacuation_responses_v1';
  static const _accessibilityKey = 'prototype_accessibility_v1';
  static const _roleKey = 'prototype_demo_role_v1';
  static const _householdsKey = 'prototype_households_v1';
  static const _visitsKey = 'prototype_visits_v1';
  static const _demoAlertKey = 'prototype_demo_alert_active_v1';
  static const _dispatchKey = 'prototype_demo_dispatch_v1';

  PrototypeSafetyController() {
    _instances.add(this);
  }

  /// 이 앱(창) 안의 컨트롤러들 — 방재단 시연 화면이 출동 기록을 쓰면 같은 창의 시민 표시도 바로 바뀌게
  static final _instances = <PrototypeSafetyController>{};

  @override
  void dispose() {
    _instances.remove(this);
    super.dispose();
  }

  bool _loaded = false;
  DemoDispatch? _dispatch;
  AccessibilitySettings _accessibility = const AccessibilitySettings();
  String? _demoRole;
  Map<String, EvacuationResponseStatus> _responses = {};
  List<DemoHousehold> _households = _seedHouseholds;
  List<DemoVisit> _visits = [];
  bool _demoAlertActive = false;

  bool get loaded => _loaded;
  /// 시연 대피 경보가 진행 중인지 ('대피 경보 팝업'을 누르면 새 경보가 시작된다, 2026-10-09)
  bool get demoAlertActive => _demoAlertActive;
  AccessibilitySettings get accessibility => _accessibility;
  String? get demoRole => _demoRole;
  // 방재단 화면은 방재단·관리자만 (C8, 2026-10-05 — 돌봄 담당 caregiver 제외, 실측 모드 patrolRoles와 같게)
  bool get hasResponderAccess => const {'responder', 'admin'}.contains(_demoRole);
  Map<String, EvacuationResponseStatus> get responses =>
      Map.unmodifiable(_responses);
  List<DemoHousehold> get households => List.unmodifiable(_households);
  List<DemoVisit> get visits => List.unmodifiable(_visits);

  EvacuationResponseStatus? responseFor(String alertId) => _responses[alertId];

  /// 방재단이 이 시연 주민에게 출발했는지·도착 예정 시각 (2026-10-12 사용자 요청: 방재단 → 시민 쌍방향). 없으면 null
  DemoDispatch? get demoDispatch => _dispatch;

  /// 시연 방(다른 계정·기기, services/demo_relay.dart)에서 받은 시연 주민의 장애 유형 (vision·hearing·mobility_limited).
  /// null = 시연 방을 안 씀 → 이 기기의 '내 정보'를 쓴다
  List<String>? get residentNeeds => _residentNeeds;
  List<String>? _residentNeeds;

  /// 새 시연 경보·로그아웃마다 1씩 — 시연 방에 '지난 출동 기록 지우기'를 보낼 때를 안다
  int get demoAlertSeq => _demoAlertSeq;
  int _demoAlertSeq = 0;

  /// 시연 방에서 받은 주민 쪽 상태 (방재단원 모드 창). 이 창 메모리에만 — 기기 기록은 그대로
  void applyRemoteResident({required bool alertActive, EvacuationResponseStatus? response, required List<String> needs}) {
    final same = _demoAlertActive == alertActive &&
        _responses[prototypeAlertKey] == response &&
        _residentNeeds != null &&
        _residentNeeds!.join(',') == needs.join(',');
    if (same) return;
    _demoAlertActive = alertActive;
    _responses = {..._responses}..remove(prototypeAlertKey);
    if (response != null) _responses[prototypeAlertKey] = response;
    _residentNeeds = needs;
    notifyListeners();
  }

  /// 시연 방에서 받은 출동 기록 (사용자 모드 창). 이 창 메모리에만
  void applyRemoteDispatch(DemoDispatch? d) {
    if (_dispatch?.toJson().toString() == d?.toJson().toString()) return;
    _dispatch = d;
    notifyListeners();
  }

  /// 시연 경보 id (prototype_safety_screens.dart prototypeEvacuationAlertId 와 같은 값 — 서로 import 하지 않으려고 여기 둔다)
  static const prototypeAlertKey = 'demo-flood-evacuation';

  static DemoDispatch? _readDispatch(SharedPreferences prefs) {
    final raw = prefs.getString(_dispatchKey);
    if (raw == null) return null;
    try {
      return DemoDispatch.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on TypeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// 출동 기록 쓰기·지우기 (방재단 시연 화면 DemoLiveApi 가 부른다). 같은 창은 바로, 다른 창은 storage 이벤트로 받는다
  static Future<void> saveDemoDispatch(DemoDispatch? d) async {
    final prefs = await SharedPreferences.getInstance();
    if (d == null) {
      await prefs.remove(_dispatchKey);
    } else {
      await prefs.setString(_dispatchKey, jsonEncode(d.toJson()));
    }
    for (final c in [..._instances]) {
      c._dispatch = d;
      c.notifyListeners();
    }
  }

  /// 시연 대피 상황을 처음부터 (로그아웃할 때, 2026-10-12 사용자 요청: 다시 로그인해도 방재단 출발 기록이 남았다).
  /// 시연 경보·시연 응답·출동 기록을 지운다 — 같은 브라우저의 다른 창도 storage 이벤트로 함께 비워진다
  static Future<void> clearDemoSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dispatchKey);
    await prefs.remove(_demoAlertKey);
    await prefs.remove(_responsesKey);
    for (final c in [..._instances]) {
      c._dispatch = null;
      c._demoAlertActive = false;
      c._responses = {};
      c._residentNeeds = null;
      c._demoAlertSeq++;
      c.notifyListeners();
    }
  }

  /// 저장된 출동 기록 (방재단 창을 새로 열었을 때 시연 대상 줄에 다시 붙인다)
  static Future<DemoDispatch?> storedDemoDispatch() async => _readDispatch(await SharedPreferences.getInstance());

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawResponses = prefs.getString(_responsesKey);
      if (rawResponses != null) {
        final decoded = jsonDecode(rawResponses) as Map<String, dynamic>;
        _responses = {
          for (final entry in decoded.entries)
            if (EvacuationResponseStatusLabel.fromWireValue('${entry.value}')
                case final status?)
              entry.key: status,
        };
      }
      final rawAccessibility = prefs.getString(_accessibilityKey);
      if (rawAccessibility != null) {
        _accessibility = AccessibilitySettings.fromJson(
            jsonDecode(rawAccessibility) as Map<String, dynamic>);
      }
      _demoRole = prefs.getString(_roleKey);
      _demoAlertActive = prefs.getBool(_demoAlertKey) ?? false;
      _dispatch = _readDispatch(prefs);
      final rawHouseholds = prefs.getString(_householdsKey);
      if (rawHouseholds != null) {
        _households = (jsonDecode(rawHouseholds) as List)
            .map((e) => DemoHousehold.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      final rawVisits = prefs.getString(_visitsKey);
      if (rawVisits != null) {
        _visits = (jsonDecode(rawVisits) as List)
            .map((e) => DemoVisit.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } on TypeError {
      // Corrupt demo preferences are ignored; the next save replaces them.
    } on FormatException {
      // Corrupt demo preferences are ignored; the next save replaces them.
    }
    _loaded = true;
    notifyListeners();
  }

  /// 다른 창이 바꾼 시연 응답·시연 경보만 다시 읽는다 (웹 'storage' 이벤트). 팝업은 띄우지 않는다.
  /// reload 는 SharedPreferences 캐시 전체를 새로 고치므로 프로필(optional_profile)도 최신이 된다
  Future<void> syncFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    var responses = <String, EvacuationResponseStatus>{};
    try {
      final raw = prefs.getString(_responsesKey);
      if (raw != null) {
        responses = {
          for (final entry in (jsonDecode(raw) as Map<String, dynamic>).entries)
            if (EvacuationResponseStatusLabel.fromWireValue('${entry.value}') case final status?) entry.key: status,
        };
      }
    } on TypeError {
      return;
    } on FormatException {
      return;
    }
    _responses = responses;
    _demoAlertActive = prefs.getBool(_demoAlertKey) ?? false;
    _dispatch = _readDispatch(prefs);
    notifyListeners();
  }

  Future<void> respond(String alertId, EvacuationResponseStatus status) async {
    _responses = {..._responses, alertId: status};
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _responsesKey,
      jsonEncode({
        for (final entry in _responses.entries)
          entry.key: entry.value.wireValue,
      }),
    );
  }

  /// 새 시연 대피 경보 시작: 이전 시연 경보의 응답은 지운다 — 지난 응답이 새 경보의 상태로 남지 않게 (2026-10-09)
  Future<void> startDemoAlert(String alertId) async {
    _responses = {..._responses}..remove(alertId);
    _demoAlertActive = true;
    _dispatch = null;   // 지난 경보의 방재단 도착 시간이 새 경보에 남지 않게
    _demoAlertSeq++;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_demoAlertKey, true);
    await prefs.remove(_dispatchKey);
    await prefs.setString(
      _responsesKey,
      jsonEncode({
        for (final entry in _responses.entries)
          entry.key: entry.value.wireValue,
      }),
    );
  }

  Future<void> updateAccessibility(AccessibilitySettings settings) async {
    _accessibility = settings;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessibilityKey, jsonEncode(settings.toJson()));
  }

  Future<bool> claimDemoRole(String code) async {
    final role = switch (code.trim().toUpperCase()) {
      'DEMO-RESPONDER' => 'responder',
      'DEMO-CAREGIVER' => 'caregiver',
      'DEMO-ADMIN' => 'admin',
      _ => null,
    };
    if (role == null) return false;
    _demoRole = role;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_roleKey, role);
    return true;
  }

  Future<void> dropDemoRole() async {
    _demoRole = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roleKey);
  }

  Future<void> registerHousehold({
    required String label,
    required String address,
    required int members,
    required List<String> needs,
    required bool consent,
    required String consentBy,
    required String consentMethod,
    required String note,
    required bool delegated,
  }) async {
    if (!consent) throw ArgumentError('민감정보 제공 동의가 필요합니다.');
    if (delegated && !hasResponderAccess) {
      throw StateError('방재단 역할이 필요합니다.');
    }
    final household = DemoHousehold(
      id: 'demo-${DateTime.now().microsecondsSinceEpoch}',
      label: label.trim().isEmpty ? '내 가구' : label.trim(),
      address: address.trim(),
      members: members,
      needs: List.unmodifiable(needs),
      // 합성 위치를 사용해 개인의 정확한 주소 좌표를 수집하지 않는다.
      latitude: 35.9918 + (_households.length % 5) * 0.0007,
      longitude: 129.5507 + (_households.length % 5) * 0.0006,
      status: '미응답',
      consentBy: consentBy,
      consentMethod: consentMethod,
      note: note.trim(),
    );
    _households = [..._households, household];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _householdsKey,
      jsonEncode(_households.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> recordVisit({
    required String householdId,
    required String result,
    required String note,
  }) async {
    if (!hasResponderAccess) throw StateError('방재단 역할이 필요합니다.');
    final visit = DemoVisit(
      householdId: householdId,
      result: result,
      note: note.trim(),
      visitedAt: DateTime.now(),
    );
    _visits = [visit, ..._visits];
    final index = _households.indexWhere((h) => h.id == householdId);
    if (index >= 0) {
      final status = switch (result) {
        'evacuated_with_help' ||
        'already_evacuated' ||
        'transported' =>
          '대피 완료',
        'refused' || 'not_home' => '재확인 필요',
        _ => _households[index].status,
      };
      _households = [
        for (var i = 0; i < _households.length; i++)
          if (i == index)
            _households[i].copyWith(status: status)
          else
            _households[i],
      ];
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _visitsKey,
      jsonEncode(_visits.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(
      _householdsKey,
      jsonEncode(_households.map((e) => e.toJson()).toList()),
    );
  }
}

const _seedHouseholds = <DemoHousehold>[
  DemoHousehold(
    id: 'sample-1',
    label: '예시 가구 A',
    address: '구룡포읍 시연로 10',
    members: 1,
    needs: ['elderly', 'living_alone'],
    latitude: 35.9942,
    longitude: 129.5502,
    status: '도움 필요',
  ),
  DemoHousehold(
    id: 'sample-2',
    label: '예시 가구 B',
    address: '구룡포읍 시연로 24',
    members: 2,
    needs: ['wheelchair'],
    latitude: 35.9904,
    longitude: 129.5541,
    status: '미응답',
  ),
  DemoHousehold(
    id: 'sample-3',
    label: '예시 가구 C',
    address: '구룡포읍 시연로 35',
    members: 1,
    needs: ['hearing'],
    latitude: 35.9877,
    longitude: 129.5483,
    status: '대피 중',
  ),
  DemoHousehold(
    id: 'sample-4',
    label: '예시 가구 D',
    address: '구룡포읍 시연로 51',
    members: 3,
    needs: ['infant', 'medical_device'],
    latitude: 35.9963,
    longitude: 129.5582,
    status: '대피 완료',
  ),
];

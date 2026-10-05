import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  return PrototypeSafetyController();
});

class PrototypeSafetyController extends ChangeNotifier {
  static const _responsesKey = 'prototype_evacuation_responses_v1';
  static const _accessibilityKey = 'prototype_accessibility_v1';
  static const _roleKey = 'prototype_demo_role_v1';
  static const _householdsKey = 'prototype_households_v1';
  static const _visitsKey = 'prototype_visits_v1';

  bool _loaded = false;
  AccessibilitySettings _accessibility = const AccessibilitySettings();
  String? _demoRole;
  Map<String, EvacuationResponseStatus> _responses = {};
  List<DemoHousehold> _households = _seedHouseholds;
  List<DemoVisit> _visits = [];

  bool get loaded => _loaded;
  AccessibilitySettings get accessibility => _accessibility;
  String? get demoRole => _demoRole;
  // 방재단 화면은 방재단·관리자만 (C8, 2026-10-05 — 돌봄 담당 caregiver 제외, 실측 모드 patrolRoles와 같게)
  bool get hasResponderAccess => const {'responder', 'admin'}.contains(_demoRole);
  Map<String, EvacuationResponseStatus> get responses =>
      Map.unmodifiable(_responses);
  List<DemoHousehold> get households => List.unmodifiable(_households);
  List<DemoVisit> get visits => List.unmodifiable(_visits);

  EvacuationResponseStatus? responseFor(String alertId) => _responses[alertId];

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

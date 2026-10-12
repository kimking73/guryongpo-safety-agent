import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../profile_form.dart' show disabilitiesOf;
import 'account_service.dart';
import 'app_config.dart';
import 'demo_live_api.dart';
import 'demo_mode.dart';
import 'demo_role.dart';
import 'prototype_safety_store.dart';

/// 시연 방 (2026-10-12 사용자 요청): 다른 계정·브라우저·기기로 로그인한 사용자 모드 창과 방재단원 모드 창을 잇는다.
/// 같은 '시연 코드'를 넣은 창끼리 AI 서버의 시연 방(GET·PUT /api/ai/demo-room/{코드}, ai/guardian_ai/demo_room.py)을 2초마다 주고받는다.
/// - 사용자 모드: 시연 경보·대피 응답·장애 유형을 보내고, 방재단 출동 기록(출발·도착 예정)을 받는다
/// - 방재단원 모드: 주민 쪽 상태를 받고, [실제 출발]·업무 단계로 바뀐 출동 기록을 보낸다
/// 같은 브라우저 창끼리는 지금처럼 기기 기록(storage 이벤트)으로도 바로 전해진다. 개인정보(이름·주소·위치)는 보내지 않는다.

class DemoRoomCodeNotifier extends StateNotifier<String?> {
  DemoRoomCodeNotifier() : super(null) {
    _load();
  }
  static const _key = 'demo_room_code_v1';

  Future<void> _load() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString(_key);
      if (mounted && v != null) state = v;
    } catch (_) {}
  }

  /// 코드 정하기 (대문자·숫자 4~8자). null 이면 연결 끊기
  Future<void> set(String? code) async {
    final c = code?.trim().toUpperCase();
    state = c == null || c.isEmpty ? null : c;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (state == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, state!);
      }
    } catch (_) {}
  }

  /// 헷갈리는 글자(0·O·1·I)를 뺀 4자리 새 코드
  static String newCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return [for (var i = 0; i < 4; i++) chars[r.nextInt(chars.length)]].join();
  }

  static bool valid(String code) => RegExp(r'^[A-Z0-9]{4,8}$').hasMatch(code.trim().toUpperCase());
}

final demoRoomCodeProvider = StateNotifierProvider<DemoRoomCodeNotifier, String?>((_) => DemoRoomCodeNotifier());

/// 시연 방과 마지막으로 주고받은 결과 (화면의 '연결됨' 표시용). null = 아직 없음
final demoRoomStatusProvider = StateProvider<String?>((_) => null);

/// 머리줄(Shell)이 watch 하면 시연 방 동기화가 돈다 — 서버 연결 + 시연 모드 + 시연 코드가 있을 때만
final demoRelayProvider = Provider.autoDispose<void>((ref) {
  if (!AppConfig.isRemote || !ref.watch(showDemoProvider)) return;
  final code = ref.watch(demoRoomCodeProvider);
  if (code == null) return;
  final relay = DemoRelay(
    code: code,
    // 방재단원 모드를 골랐어도 전용 코드로 로그인하기 전이면 사용자 쪽으로 (2026-10-12)
    role: ref.watch(demoResponderViewProvider) ? DemoRole.responder : DemoRole.user,
    store: ref.read(prototypeSafetyProvider),
    status: (s) => ref.read(demoRoomStatusProvider.notifier).state = s,
  )..start();
  ref.onDispose(relay.stop);
});

class DemoRelay {
  DemoRelay({required this.code, required this.role, required this.store, required this.status, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                baseUrl: AppConfig.aiBaseUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 8)));

  final String code;
  final DemoRole role;
  final PrototypeSafetyController store;
  final void Function(String) status;
  final Dio _dio;
  Timer? _timer;
  bool _busy = false;
  /// 가장 최근에 본 방 버전 — 늦게 온 예전 응답은 버린다
  int _seen = -1;
  /// 사용자 모드: 마지막으로 보낸 (경보, 응답, 경보 순번)
  String? _pushedResident;
  /// 방재단원 모드: 마지막으로 보낸 출동 기록
  String? _pushedDispatch;

  String get _path => '/api/ai/demo-room/$code';

  void start() {
    if (role == DemoRole.responder) _pushedDispatch = _dispatchKey(store.demoDispatch); // 처음 열 때 빈 기록으로 덮지 않게
    store.addListener(_onLocal);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    _onLocal();
    poll();
  }

  void stop() {
    _timer?.cancel();
    store.removeListener(_onLocal);
  }

  static String? _dispatchKey(DemoDispatch? d) => d == null ? null : '${d.toJson()}';

  String get _residentKey =>
      '${store.demoAlertActive}|${store.responseFor(PrototypeSafetyController.prototypeAlertKey)?.wireValue}|${store.demoAlertSeq}';

  /// 이 창에서 바뀐 것을 시연 방에 보낸다
  void _onLocal() {
    if (role == DemoRole.user) {
      final key = _residentKey;
      if (key == _pushedResident) return;
      final newAlert = _pushedResident == null || _pushedResident!.split('|').last != '${store.demoAlertSeq}';
      _pushedResident = key;
      unawaited(_pushResident(newAlert));
    } else {
      final key = _dispatchKey(store.demoDispatch);
      if (key == _pushedDispatch) return;
      _pushedDispatch = key;
      unawaited(_put({'dispatch': store.demoDispatch?.toJson()}));
    }
  }

  Future<void> _pushResident(bool newAlert) async {
    const toNeed = {'see': 'vision', 'hear': 'hearing', 'body': 'mobility_limited'};
    final needs = [for (final d in disabilitiesOf(await AccountService().optionalProfile())) if (toNeed[d] case final n?) n];
    await _put({
      'alert_active': store.demoAlertActive,
      'response': store.responseFor(PrototypeSafetyController.prototypeAlertKey)?.wireValue,
      'needs': needs,
      // 새 시연 경보·로그아웃이면 지난 출동 기록도 지운다
      if (newAlert || !store.demoAlertActive) 'dispatch': null,
    });
  }

  Future<void> _put(Map<String, dynamic> body) async {
    try {
      final r = await _dio.put<Map<String, dynamic>>(_path, data: body);
      if (r.data != null) _apply(r.data!);
    } catch (_) {
      status('시연 방에 보내지 못했어요');
    }
  }

  /// 시연 방을 한 번 읽어 반영 (2초마다)
  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await _dio.get<Map<String, dynamic>>(_path);
      if (r.data != null) _apply(r.data!);
    } catch (_) {
      status('시연 방에 연결하지 못했어요');
    } finally {
      _busy = false;
    }
  }

  /// 방 상태를 이 창에 반영 (내가 보낸 칸은 건드리지 않는다)
  void _apply(Map<String, dynamic> room) {
    final v = (room['version'] as num?)?.toInt() ?? 0;
    status('연결됨');
    // 바뀐 게 없거나(같은 버전) 늦게 온 예전 응답이면 그대로 — 내가 막 보낸 출발 기록을 예전 상태로 지우지 않게
    if (v <= _seen) return;
    _seen = v;
    final raw = room['dispatch'];
    DemoDispatch? d;
    try {
      d = raw is Map ? DemoDispatch.fromJson(Map<String, dynamic>.from(raw)) : null;
    } catch (_) {
      d = null;
    }
    if (role == DemoRole.user) {
      store.applyRemoteDispatch(d);
      return;
    }
    // 방재단원 모드: 주민 쪽 상태. 주민이 새 경보를 시작했거나 로그아웃해 출동 기록이 지워졌으면 이 창의 배정도 처음으로
    if (d == null && store.demoDispatch != null) {
      DemoLiveApi.resetDemoIncident();
      _pushedDispatch = null;
      unawaited(PrototypeSafetyController.saveDemoDispatch(null));
    }
    store.applyRemoteResident(
      alertActive: room['alert_active'] == true,
      response: EvacuationResponseStatusLabel.fromWireValue(room['response'] as String?),
      needs: [for (final n in room['needs'] as List? ?? const []) '$n'],
    );
  }
}

import 'profile_refresh.dart';
import 'profile_cards.dart';
import 'ui/gk_theme.dart';
import 'ui/gk_widgets.dart';
import 'services/account_sync.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'models/domain_models.dart';
import 'repositories/mock_repository.dart';
import 'repositories/remote_repository.dart';
import 'services/app_config.dart';
import 'services/auth_service.dart';
import 'services/account_service.dart';
import 'services/location_service.dart';
import 'services/geocoding_service.dart';
import 'services/demo_speech.dart';
import 'services/voice_service.dart';
import 'dashboard_parts.dart';
import 'disaster_center.dart';
import 'live_screens.dart';
import 'patrol_screens.dart';
import 'origin_picker.dart';
import 'route_planner.dart';
import 'custom_route.dart';
import 'login_screen.dart';
import 'services/demo_mode.dart';
import 'prototype_safety_screens.dart';
import 'services/demo_notifications.dart';
import 'services/prototype_safety_store.dart';
import 'services/fcm_notification_service.dart';
import 'services/evacuation_response_queue.dart';
import 'ui/tokens.dart' show buildAppTheme;
import 'mobile/ai_chat.dart' as m;
import 'mobile/app_shell.dart' as m;
import 'mobile/evac_sos.dart' as m;
import 'mobile/m_core.dart' as m;
import 'mobile/m_patrol_screens.dart' as m;
import 'mobile/onboarding.dart' as m;
import 'mobile/profile_screen.dart' as m;

/// 화면 디자인 고르기 (2026-10-09 사용자 결정): 웹(브라우저)은 web-prototype 디자인(이 파일의 Shell·Dashboard 등, 김종연),
/// 휴대폰 앱(안드로이드·iOS)은 '구룡포 안전 비서 모바일' 디자인(lib/mobile/, 김다인). 기능·데이터 코드는 함께 쓴다.
/// 테스트에서 바꿀 수 있게 변수로 둔다
bool useMobileUi = !kIsWeb;

/// APP_MODE=remote면 실제 서버, 아니면 예시 데이터
final repo = Provider<SafetyRepository>((_) =>
    AppConfig.isRemote ? RemoteSafetyRepository() : MockSafetyRepository());
final offline = StateProvider<bool>((_) => false);
final routeFacilityId = StateProvider<String?>((_) => null);
final routeFacilitySnapshot = StateProvider<Facility?>((_) => null);
final routeStartOrigin = StateProvider<LatLng?>((_) => null);

/// 경로 안내 '출발:'에서 고른 곳 (집·내 장소·검색, 2026-10-10). null = 현위치.
/// 앱의 현재 위치(userLocation)는 바꾸지 않고 경로 출발점만 바꾼다
class RoutePoint {
  const RoutePoint(this.label, this.at);
  final String label;
  final LatLng at;
}

final routeOriginPoint = StateProvider<RoutePoint?>((_) => null);

/// 출발 'GPS 선택'(2026-10-11): 켜져 있으면 대시보드 지도를 누른 곳이 현재 위치가 된다 (바다면 해상 경로 안내)
final mapPickMode = StateProvider<bool>((_) => false);

/// 길찾기(custom_route.dart)로 정한 목적지 id. 출발지가 내 위치가 아니면 이동 중 경로 재확인(GPS)을 끈다
const customRouteId = 'custom';
final customRouteFollowsUser = StateProvider<bool>((_) => true);

/// 길찾기 경로를 경로 지도에 띄운다
void startCustomRoute(WidgetRef ref,
    {required LatLng origin,
    required bool followUser,
    required Facility destination,
    required RouteType routeType}) {
  ref.read(routeKind.notifier).state = routeType;
  ref.read(routeFacilitySnapshot.notifier).state = destination;
  ref.read(routeStartOrigin.notifier).state = origin;
  ref.read(customRouteFollowsUser.notifier).state = followUser;
  ref.invalidate(routeProvider(customRouteId));
  ref.read(routeFacilityId.notifier).state = customRouteId;
}

/// 경로 화면의 '가까운/안전 경로' 전환. 길찾기 경로는 출발·목적지를 그대로 두고 종류만 바꾼다
void switchRouteType(WidgetRef ref, String facilityId, RouteType routeType) {
  if (facilityId == customRouteId) {
    ref.read(routeKind.notifier).state = routeType;
  } else {
    startRouteToShelter(ref, facilityId, routeType: routeType);
  }
}

final alertCenterProvider = StateProvider<List<AlertItem>>((_) => const []);
final alertFeedErrorProvider = StateProvider<String?>((_) => null);
final alertFeedLoadedProvider = StateProvider<bool>((_) => false);
final alertPollIntervalProvider = StateProvider<int>((_) => 60);
final alertModeProvider = StateProvider<String>((_) => 'normal');
final alertServerTimeProvider = StateProvider<DateTime?>((_) => null);
final alertEvacuationProvider =
    StateProvider<Map<String, dynamic>?>((_) => null);
final alertSinceProvider = StateProvider<String?>((_) => null);
final pendingResponseIdsProvider =
    StateProvider<Set<String>>((_) => <String>{});
final responseSendingProvider = StateProvider<String?>((_) => null);
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// `safe` avoids the illustrated hazard; `near` illustrates the shorter route.
final routeKind = StateProvider<RouteType>((_) => RouteType.safest);

/// 프로필 값이 화면 밖에서 바뀌면 올린다 (AI 기억 반영 등) — 프로필 카드들이 key 로 보고 다시 읽는다
final profileRevision = StateProvider<int>((_) => 0);

/// 도보·자동차 (2026-10-07). 경로 provider 가 watch → 바꾸면 경로를 다시 받는다
final travelMode = StateProvider<TravelMode>((_) => TravelMode.walk);
final chatMessages = StateProvider<List<ChatMessage>>((_) => []);

/// AI 답을 기다리는 중 — 화면이 아니라 앱 전체에 둔다 (대화창을 떠났다 돌아와도 '확인하고 있습니다'가 이어짐)
final chatLoading = StateProvider<bool>((_) => false);

/// 질문 보내기·답 붙이기를 화면 State 밖에서 한다 (2026-10-08): 답을 만드는 중에 프로필 등 다른 메뉴로 가도
/// 요청이 끝까지 가고, 답은 대화 기록(chatMessages)에 붙는다. 대화창(AiScreen)·대시보드 AiPanel이 함께 쓴다.
final chatController = Provider<ChatController>((ref) => ChatController(ref));

class ChatController {
  ChatController(this._ref);
  final Ref _ref;

  bool get busy => _ref.read(chatLoading);

  void add(List<ChatMessage> m) => _ref.read(chatMessages.notifier).state = [..._ref.read(chatMessages), ...m];

  /// 글 질문. [decorate]는 답 문구를 바꿀 때(대시보드 예시 모드)
  Future<void> ask(String question, {String Function(ChatAnswer)? decorate}) async {
    if (question.trim().isEmpty || busy) return;
    add([ChatMessage(question, true)]);
    _ref.read(chatLoading.notifier).state = true;
    try {
      final answer = await _ref.read(repo).ask(question, UserMode.user, _ref.read(userLocation).position);
      add([ChatMessage(decorate?.call(answer) ?? answer.text, false, answer: answer)]);
    } catch (_) {
      const answer = ChatAnswer('AI 서비스에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.', isError: true);
      add([ChatMessage(answer.text, false, answer: answer)]);
    } finally {
      _ref.read(chatLoading.notifier).state = false;
    }
  }

  /// 음성 질문 (녹음이 끝난 wav). 받아쓴 질문·답을 붙이고 답 음성을 재생한다 — 다른 메뉴에 있어도 재생
  Future<void> askVoice(Uint8List wav) async {
    _ref.read(chatLoading.notifier).state = true;
    ChatAnswer? answer;
    try {
      final v = await _ref.read(repo).askVoice(wav, UserMode.user, _ref.read(userLocation).position);
      answer = v.answer;
      add([ChatMessage('🎤 ${v.transcript}', true), ChatMessage(v.answer.text, false, answer: v.answer)]);
    } catch (e) {
      add([ChatMessage(e is RemoteError ? e.message : '음성 질문을 처리하지 못했습니다. 다시 시도해 주세요.', false)]);
    } finally {
      _ref.read(chatLoading.notifier).state = false;
    }
    if (answer?.audio != null) {
      try {
        await VoicePlayer.instance.play(answer!.audio!);
      } catch (_) {}
    }
  }
}

final userOccupation = StateProvider<String>((_) => '');
final autoVoiceAlerts = StateProvider<bool>((_) => false);
final voiceLanguage = StateProvider<String>((_) => '한국어');
final floodLayer = StateProvider<bool>((_) => false);
final floodTime = StateProvider<int>((_) => 0);

// --- 사용자 위치 ---------------------------------------------------------------
/// 사용자가 있는 곳. fromGps=false면 사용자 유형별 예시 좌표 (GPS가 없거나, 권한이 없거나, 구룡포 밖)
class UserLocation {
  const UserLocation(this.position,
      {required this.fromGps, this.manual = false});
  final LatLng position;
  final bool fromGps, manual;
}

final locationService = Provider<LocationService>((_) => LocationService());

/// 마지막으로 받은 위치 (GPS 또는 지도에서 직접 고른 곳). 구룡포 밖이어도 그대로 둔다 — 쓸지는 userLocation이 정한다
final gpsPosition =
    StateProvider<(LatLng, bool)?>((_) => null); // (위치, 지도에서 직접 고름)
final gpsNote = StateProvider<String?>((_) => null);
final userLocation = Provider<UserLocation>((ref) {
  final g = ref.watch(gpsPosition);
  if (g != null && inServiceArea(g.$1))
    return UserLocation(g.$1, fromGps: true, manual: g.$2);
  return UserLocation(originFor(UserMode.user), fromGps: false);
});

/// 30m 넘게 움직였을 때만 위치를 바꾼다 (첫 위치·지도 선택은 바로)
void setPosition(WidgetRef ref, LatLng p, {bool manual = false}) {
  final prev = ref.read(gpsPosition);
  if (manual ||
      prev == null ||
      prev.$2 ||
      const Distance().as(LengthUnit.Meter, prev.$1, p) > moveThresholdM) {
    ref.read(gpsPosition.notifier).state = (p, manual);
  }
}

/// 앱이 켜져 있는 동안 GPS를 따라간다 (Shell이 watch). 권한 거부·실패면 예시 위치 그대로
final gpsTracker = Provider<void>((ref) {
  StreamSubscription<LatLng>? sub;
  try {
    sub = ref.watch(locationService).watch().listen((p) {
      final prev = ref.read(gpsPosition);
      if (prev != null && prev.$2) return; // 지도에서 직접 고른 위치가 우선
      if (prev == null ||
          const Distance().as(LengthUnit.Meter, prev.$1, p) > moveThresholdM) {
        ref.read(gpsPosition.notifier).state = (p, false);
      }
      ref.read(gpsNote.notifier).state =
          inServiceArea(p) ? null : '현재 위치가 구룡포 밖이라 예시 위치를 씁니다.';
    },
        onError: (Object e) => ref.read(gpsNote.notifier).state =
            e is LocationUnavailable ? e.message : '위치를 읽지 못해 예시 위치를 씁니다.');
  } catch (_) {}
  ref.onDispose(() => sub?.cancel());
});

// 서버 데이터. 사용자 위치가 바뀌면(30m 넘게) 다시 불러온다. 새로고침은 ref.invalidate.
// 시연 모드를 켜고 끄면(serverDemoProvider) 서버 시연 데이터 ↔ 실측으로 다시 받는다
final riskProvider = FutureProvider<RiskStatus>((ref) {
  ref.watch(serverDemoProvider);
  return ref.watch(repo).risk(ref.watch(userLocation).position);
});
final riskAreasProvider = FutureProvider<List<RiskArea>>((ref) {
  ref.watch(serverDemoProvider);
  return ref.watch(repo).riskAreas();
});
final floodGridProvider = FutureProvider<List<FloodGrid>>((ref) {
  ref.watch(serverDemoProvider);
  return ref.watch(repo).floodGrid(timeIndex: ref.watch(floodTime));
});
final facilitiesProvider = FutureProvider<List<Facility>>(
    (ref) => ref.watch(repo).getFacilities(ref.watch(userLocation).position));
final alertsProvider = FutureProvider<List<AlertItem>>(
    (ref) => ref.watch(repo).alerts(ref.watch(userLocation).position));

void mergeAlertItems(WidgetRef ref, List<AlertItem> incoming) {
  ref.read(alertCenterProvider.notifier).state = mergeAlertsById(
    ref.read(alertCenterProvider),
    incoming,
  );
}

Future<void> refreshAlertFeed(WidgetRef ref, {bool fullRefresh = true}) async {
  if (!AppConfig.isRemote) {
    ref.invalidate(alertsProvider);
    return;
  }
  // 개인 경고 받기는 위치를 서버에 남기므로 로그인한 사람만 (2026-10-08). 공개 특보·재난문자는 대시보드에 그대로
  if (!AuthService.signedIn) return;
  try {
    final result = await ref.read(repo).pollAlerts(
          ref.read(userLocation).position,
          since: fullRefresh ? null : ref.read(alertSinceProvider),
          deviceId: await FcmNotificationService.instance.deviceId,
        );
    ref.read(alertSinceProvider.notifier).state =
        result.serverTime?.toUtc().toIso8601String();
    ref.read(alertServerTimeProvider.notifier).state = result.serverTime;
    ref.read(alertModeProvider.notifier).state = result.mode;
    mergeAlertItems(ref, result.alerts);
    ref.read(alertFeedErrorProvider.notifier).state = null;
    ref.read(alertFeedLoadedProvider.notifier).state = true;
    ref.read(alertPollIntervalProvider.notifier).state =
        result.nextPollSeconds.clamp(5, 300).toInt();
    ref.read(alertEvacuationProvider.notifier).state = result.evacuation;
  } catch (error) {
    ref.read(alertFeedErrorProvider.notifier).state = '$error';
  }
}

/// AI 답의 "지도에서 경로 보기"로 고른 경로 (routeFacilityId == aiRouteId일 때 지도에 그린다)
const aiRouteId = 'ai';
final aiRoute = StateProvider<ChatAnswer?>((_) => null);
/// 등록 장소. 서버 프로필을 내려받아 바뀌면(AI가 대화에서 들은 장소를 더함 등, AccountSync.updated) 다시 읽는다 —
/// 프로필 화면 목록·지도 표시가 바로 갱신되게 (2026-10-08)
final placesProvider = FutureProvider<List<SavedPlace>>((ref) {
  void reload() => ref.invalidateSelf();
  AccountSync.updated.addListener(reload);
  ref.onDispose(() => AccountSync.updated.removeListener(reload));
  return AccountService().places();
});
final routeProvider =
    FutureProvider.family<SafetyRoute, String>((ref, facilityId) async {
  if (facilityId == aiRouteId) {
    final route = ref.watch(aiRoute)?.route;
    if (route == null) throw StateError('AI 경로가 없습니다.');
    return route;
  }
  final selected = ref.watch(routeFacilitySnapshot);
  final facility = selected?.id == facilityId
      ? selected!
      : (await ref.read(facilitiesProvider.future))
          .firstWhere((f) => f.id == facilityId);
  final origin = ref.watch(routeStartOrigin) ?? ref.read(userLocation).position;
  TravelSetting.mode = ref.watch(travelMode);
  return ref
      .watch(repo)
      .routeFor(facility, UserMode.user, ref.watch(routeKind), origin);
});

/// AI가 안내한 경로를 대시보드 지도에 띄운다 (서버를 다시 부르지 않고 AI가 계산한 경로 그대로)
void showAiRoute(WidgetRef ref, ChatAnswer answer) {
  ref.read(aiRoute.notifier).state = answer;
  ref.invalidate(routeProvider(aiRouteId));
  startRouteToShelter(
    ref,
    aiRouteId,
    routeType: answer.route?.routeType ?? RouteType.safest,
  );
}

/// 지금 지도에 그리는 목적지 (대피소·의료시설 목록 또는 AI 경로의 목적지)
Facility? routeDestination(WidgetRef ref, String id) {
  if (id == aiRouteId) {
    final a = ref.watch(aiRoute);
    if (a == null || a.destinationPos == null) return null;
    final kind = a.destinationKind;
    return Facility(
        id: aiRouteId,
        name: a.destinationName ?? '목적지',
        type: kind == 'shelter'
            ? FacilityType.shelter
            : kind == 'medical'
                ? FacilityType.medical
                : FacilityType.place,
        position: a.destinationPos!,
        address: '',
        description: 'AI 안내 목적지',
        distanceKm: 0,
        walkMinutes: 0,
        accessible: false);
  }
  final selected = ref.watch(routeFacilitySnapshot);
  if (selected?.id == id) return selected;
  return ref
      .watch(facilitiesProvider)
      .valueOrNull
      ?.where((f) => f.id == id)
      .firstOrNull;
}

/// 가장 가까운 '갈 만한' 대피소 (shelterExclusion 규칙). 모두 위험하면 가장 가까운 곳, 못 불러왔으면 예시 대피소
String nearestShelterId(WidgetRef ref) {
  final areas = ref.read(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
  final shelters = [...?ref.read(facilitiesProvider).valueOrNull]
      .where((f) => f.type == FacilityType.shelter)
      .toList()
    ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  if (shelters.isEmpty) return 'gym';
  return (shelters
              .where((f) => shelterExclusion(f, areas) == null)
              .firstOrNull ??
          shelters.first)
      .id;
}

/// The only state transition that starts a route. Every shelter picker uses
/// this so a selected destination always opens the dashboard map route mode.
void startRouteToShelter(WidgetRef ref, String shelterId,
    {RouteType routeType = RouteType.safest}) {
  ref.read(routeKind.notifier).state = routeType;
  final facility = ref
      .read(facilitiesProvider)
      .valueOrNull
      ?.where((f) => f.id == shelterId)
      .firstOrNull;
  ref.read(routeFacilitySnapshot.notifier).state = facility;
  ref.read(routeStartOrigin.notifier).state = ref.read(routeOriginPoint)?.at ?? ref.read(userLocation).position;
  ref.read(routeFacilityId.notifier).state = shelterId;
}

Future<void> _recordPrototypeEvacuationResponse(
  WidgetRef ref,
  EvacuationResponseStatus status,
) async {
  if (ref.read(offline)) {
    _showResponseMessage('오프라인 상태입니다. 온라인 상태로 바꾸어서 다시 응답을 시도하십시오');
    return;
  }
  try {
    await ref
        .read(prototypeSafetyProvider)
        .respond(prototypeEvacuationAlertId, status);
    if (status == EvacuationResponseStatus.evacuating) {
      try {
        await ref.read(facilitiesProvider.future);
      } catch (_) {
        // Use the existing fallback shelter when live facility loading fails.
      }
      startRouteToShelter(ref, nearestShelterId(ref),
          routeType: RouteType.nearest);
      if (useMobileUi) ref.read(m.dashMapFull.notifier).state = true;
      appRouter.go('/');
    } else if (status == EvacuationResponseStatus.needHelp) {
      if (useMobileUi) {
        appRouter.push('/sos');
      } else {
        _showResponseMessage('방재단에게 도움을 요청했습니다');
      }
    }
  } catch (error) {
    _showResponseMessage('응답을 저장하지 못했습니다. $error');
  }
}

enum _ResponseSubmitResult { sent, queued, blockedOffline, failed }

final _responseQueue = EvacuationResponseQueue();
bool _retryingEvacuationResponses = false;

void _showResponseMessage(String message) {
  rootMessengerKey.currentState?.showSnackBar(SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 5),
  ));
}

void _setAlertResponse(WidgetRef ref, String alertId, String status) {
  final alerts = ref.read(alertCenterProvider);
  ref.read(alertCenterProvider.notifier).state = [
    for (final alert in alerts)
      if (alert.id == alertId) alert.copyWith(myStatus: status) else alert,
  ];
  // 상단 대피 현황·방재단 집계가 다음 폴링을 기다리지 않게: 진행 중인 대피 상황의 내 상태도 바로 바꾼다
  final evac = ref.read(alertEvacuationProvider);
  if (evac != null && evac['alert_id'] == alertId) {
    ref.read(alertEvacuationProvider.notifier).state = {...evac, 'status': status};
  }
  ref.read(pendingResponseIdsProvider.notifier).state = {
    ...ref.read(pendingResponseIdsProvider),
  }..remove(alertId);
}

Future<void> _afterResponseSuccess(
    WidgetRef ref, String alertId, String status) async {
  _setAlertResponse(ref, alertId, status);
  if (status == 'need_help') {
    if (useMobileUi) {
      appRouter.push('/sos');
    } else {
      _showResponseMessage('방재단에게 도움을 요청했습니다');
    }
  } else if (status == 'evacuating') {
    try {
      await ref.read(facilitiesProvider.future);
    } catch (_) {
      // Use the existing fallback shelter if live facility loading fails.
    }
    startRouteToShelter(ref, nearestShelterId(ref),
        routeType: RouteType.nearest);
    if (useMobileUi) ref.read(m.dashMapFull.notifier).state = true;
    appRouter.go('/');
  }
}

// 휴대폰 앱 화면(lib/mobile/)이 같은 대피 응답 처리를 쓰도록 공개
typedef ResponseSubmitResult = _ResponseSubmitResult;
Future<ResponseSubmitResult> submitEvacuationResponse(WidgetRef ref, AlertItem alert, String status) =>
    _submitEvacuationResponse(ref, alert, status);
Future<void> recordPrototypeEvacuationResponse(WidgetRef ref, EvacuationResponseStatus status) =>
    _recordPrototypeEvacuationResponse(ref, status);
void showResponseMessage(String message) => _showResponseMessage(message);

Future<_ResponseSubmitResult> _submitEvacuationResponse(
  WidgetRef ref,
  AlertItem alert,
  String status,
) async {
  if (ref.read(offline)) {
    _showResponseMessage('오프라인 상태입니다. 온라인 상태로 바꾸어서 다시 응답을 시도하십시오');
    return _ResponseSubmitResult.blockedOffline;
  }
  ref.read(responseSendingProvider.notifier).state = alert.id;
  final location = ref.read(userLocation).position;
  try {
    await ref.read(repo).respondToAlert(
          alertId: alert.id,
          status: status,
          location: location,
        );
    await _responseQueue.remove(alert.id);
    await _afterResponseSuccess(ref, alert.id, status);
    return _ResponseSubmitResult.sent;
  } catch (error) {
    if (isTransientNetworkFailure(error)) {
      try {
        await _responseQueue.enqueue(PendingEvacuationResponse(
          alertId: alert.id,
          status: status,
          location: location,
        ));
      } catch (_) {
        _showResponseMessage('응답을 기기에 저장하지 못했습니다. 온라인 연결 후 다시 시도해 주세요.');
        return _ResponseSubmitResult.failed;
      }
      ref.read(pendingResponseIdsProvider.notifier).state = {
        ...ref.read(pendingResponseIdsProvider),
        alert.id,
      };
      _showResponseMessage('네트워크가 끊겼습니다. 보관 후 전송하겠습니다');
      return _ResponseSubmitResult.queued;
    }
    _showResponseMessage('응답을 전송하지 못했습니다. $error');
    return _ResponseSubmitResult.failed;
  } finally {
    ref.read(responseSendingProvider.notifier).state = null;
  }
}

Future<void> retryQueuedEvacuationResponses(WidgetRef ref) async {
  if (_retryingEvacuationResponses || ref.read(offline)) return;
  _retryingEvacuationResponses = true;
  try {
    for (final response in await _responseQueue.read()) {
      if (ref.read(offline)) return;
      ref.read(responseSendingProvider.notifier).state = response.alertId;
      _showResponseMessage('재시도 중입니다');
      try {
        await ref.read(repo).respondToAlert(
              alertId: response.alertId,
              status: response.status,
              location: response.location,
            );
        await _responseQueue.remove(response.alertId);
        await _afterResponseSuccess(ref, response.alertId, response.status);
      } catch (error) {
        if (isTransientNetworkFailure(error)) {
          return;
        }
        await _responseQueue.remove(response.alertId);
        ref.read(pendingResponseIdsProvider.notifier).state = {
          ...ref.read(pendingResponseIdsProvider),
        }..remove(response.alertId);
        _showResponseMessage('저장한 응답을 전송하지 못했습니다. 다시 응답해 주세요. $error');
      } finally {
        ref.read(responseSendingProvider.notifier).state = null;
      }
    }
  } finally {
    _retryingEvacuationResponses = false;
  }
}

void main() => runApp(
    const ProviderScope(child: _NotificationBootstrap(child: GuryongpoApp())));

class _NotificationBootstrap extends ConsumerStatefulWidget {
  const _NotificationBootstrap({required this.child});
  final Widget child;

  @override
  ConsumerState<_NotificationBootstrap> createState() =>
      _NotificationBootstrapState();
}

class _NotificationBootstrapState extends ConsumerState<_NotificationBootstrap>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  bool _pollInFlight = false;
  String? _since;
  ProviderSubscription<bool>? _offlineSubscription;

  @override
  void initState() {
    super.initState();
    _offlineSubscription = ref.listenManual<bool>(offline, (previous, next) {
      if (previous == true && !next) {
        unawaited(retryQueuedEvacuationResponses(ref));
      }
    });
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final controller = ref.read(prototypeSafetyProvider);
      await controller.load();
      final queuedResponses = await _responseQueue.read();
      ref.read(pendingResponseIdsProvider.notifier).state = {
        for (final response in queuedResponses) response.alertId,
      };
      await DemoNotifications.instance.initialize(
        (alertId, status) => controller.respond(alertId, status),
      );
      try {
        await AuthService().initialize();
        await FcmNotificationService.instance.initialize(
          repository: ref.read(repo),
          onForeground: (alert) async {
            _mergeAlerts([alert]);
            rootMessengerKey.currentState?.showSnackBar(SnackBar(
              content: Text('새 알림: ${alert.title}'),
              duration: const Duration(seconds: 8),
              action: SnackBarAction(
                label: '확인',
                onPressed: () =>
                    appRouter.go('/alert/${Uri.encodeComponent(alert.id)}'),
              ),
            ));
            await _pollAlerts(fullRefresh: true);
          },
          onOpen: (id, preview) async {
            _mergeAlerts([preview]);
            await _pollAlerts(fullRefresh: true);
            try {
              await ref.read(repo).markAlertRead(id);
              _mergeAlerts([preview.copyWith(read: true)]);
            } catch (_) {
              // A stale push must not prevent opening the alert screen.
            }
            if (mounted) appRouter.go('/alert/$id');
          },
        );
      } catch (_) {
        // Auth or push setup must never prevent mock mode and polling fallback.
      }
      await _pollAlerts();
      unawaited(retryQueuedEvacuationResponses(ref));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pollTimer?.cancel();
      unawaited(_pollAlerts());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _mergeAlerts(List<AlertItem> incoming) {
    mergeAlertItems(ref, incoming);
  }

  Future<void> _pollAlerts({bool fullRefresh = false}) async {
    if (_pollInFlight || !mounted) return;
    unawaited(retryQueuedEvacuationResponses(ref));
    if (!AppConfig.isRemote || !AuthService.signedIn) return;   // 개인 경고는 로그인한 사람만 (2026-10-08)
    _pollInFlight = true;
    _pollTimer?.cancel();
    try {
      final result = await ref.read(repo).pollAlerts(
            ref.read(userLocation).position,
            since: fullRefresh ? null : _since,
            deviceId: await FcmNotificationService.instance.deviceId,
          );
      if (!mounted) return;
      _since = result.serverTime?.toUtc().toIso8601String() ?? _since;
      ref.read(alertSinceProvider.notifier).state = _since;
      ref.read(alertServerTimeProvider.notifier).state = result.serverTime;
      ref.read(alertModeProvider.notifier).state = result.mode;
      _mergeAlerts(result.alerts);
      ref.read(alertFeedErrorProvider.notifier).state = null;
      ref.read(alertFeedLoadedProvider.notifier).state = true;
      ref.read(alertPollIntervalProvider.notifier).state =
          result.nextPollSeconds.clamp(5, 300).toInt();
      ref.read(alertEvacuationProvider.notifier).state = result.evacuation;
      ref.invalidate(alertsProvider);
    } catch (error) {
      if (mounted) {
        ref.read(alertFeedErrorProvider.notifier).state = '$error';
        ref.read(alertPollIntervalProvider.notifier).state = 60;
      }
    } finally {
      _pollInFlight = false;
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _pollTimer = Timer(
          Duration(seconds: ref.read(alertPollIntervalProvider)),
          () => unawaited(_pollAlerts()),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _offlineSubscription?.close();
    unawaited(FcmNotificationService.instance.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class GuryongpoApp extends StatelessWidget {
  const GuryongpoApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp.router(
        title: '구룡포 안전',
        scaffoldMessengerKey: rootMessengerKey,
        debugShowCheckedModeBanner: false,
        // 디자인 = web-prototype (2026-10-08) — ui/gk_theme.dart
        theme: useMobileUi ? buildAppTheme() : gkTheme(),
        routerConfig: appRouter,
      );
}

/// 시작 화면(로그인·계정 정보 준비)을 거쳤는지. 웹에서 새로고침·주소 직접 입력으로 다른 화면부터 열리면
/// 로그인 준비 없이 서버를 불러 '로그인 정보를 확인하지 못했습니다'가 나므로 먼저 /boot 를 거치게 한다 (2026-10-05)
bool appBooted = false;

/// 메뉴(대시보드·AI 대화창·방재단 현황·사용자 …) 사이 이동을 깔끔하게 (2026-10-10 사용자 요청).
/// 기기 기본 전환은 탭 이동에 맞지 않는다 — 아이폰·맥 브라우저는 새 화면이 옆에서 밀려 들어오고, 그 밖은 확대되며 들어온다.
/// 머리줄·메뉴는 그대로 두고 안쪽 화면만: 이전 화면은 바로 가려지고 새 화면이 짧게 떠오른다.
/// 이전 화면은 새 화면의 전환이 끝날 때까지 아래에 남아 있다(Navigator 동작) — 새 화면만 투명하게 떠오르면 그동안 이전 화면이
/// 비쳐 잔상처럼 보였다. 그래서 화면 바탕색을 처음부터 불투명하게 깔고 그 위에서 내용만 떠오르게 한다.
const menuFadeDuration = Duration(milliseconds: 120);

List<RouteBase> _menuRoutes(List<GoRoute> routes) => [
      for (final r in routes)
        GoRoute(
            path: r.path,
            name: r.name,
            redirect: r.redirect,
            routes: r.routes,
            pageBuilder: (context, state) => CustomTransitionPage<void>(
                key: state.pageKey,
                child: r.builder!(context, state),
                transitionDuration: menuFadeDuration,
                reverseTransitionDuration: Duration.zero,
                transitionsBuilder: (context, animation, __, child) => ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: FadeTransition(opacity: CurveTween(curve: Curves.easeOut).animate(animation), child: child)))),
    ];

final appRouter = GoRouter(
    initialLocation: '/boot',
    refreshListenable: AuthService.changes,
    redirect: (_, state) {
      final loc = state.matchedLocation;
      if (!appBooted) {
        return loc == '/boot' ? null : Uri(path: '/boot', queryParameters: {'from': state.uri.toString()}).toString();
      }
      final from = state.uri.queryParameters['from'];
      String target() =>
          from != null && from.startsWith('/') && !from.startsWith('/login') && !from.startsWith('/boot') && !from.startsWith('/setup')
              ? from
              : '/';
      // 첫 화면 (2026-10-09 사용자 요청, 웹·앱 공통): 앱을 열 때마다 동의·로그인(1/2) → 내 정보(2/2) → 대시보드 (2026-10-10)
      if (!m.Onboarding.consented && loc != '/login') {
        return Uri(path: '/login', queryParameters: {'from': state.uri.toString()}).toString();
      }
      // 로그인 강제 (사용자 결정 2026-10-08): 로그인 안 했으면 로그인 화면만. 목업 모드는 제외
      if (AuthService.enabled && !AuthService.signedIn && loc != '/login') {
        return Uri(path: '/login', queryParameters: {'from': state.uri.toString()}).toString();
      }
      // 2/2 내 정보: '시작하기'나 '나중에 입력할게요'를 누를 때까지 먼저 보여 준다
      if (!m.Onboarding.done && loc != '/login' && loc != '/setup') {
        return Uri(path: '/setup', queryParameters: {'from': state.uri.toString()}).toString();
      }
      // 이미 동의한 사람이 다시 로그인하면 가려던 화면으로
      if (loc == '/login' && m.Onboarding.consented && (AuthService.signedIn || !AuthService.enabled)) {
        if (!m.Onboarding.done) return Uri(path: '/setup', queryParameters: {'from': target()}).toString();
        return target();
      }
      return null;
    },
    routes: [
  GoRoute(path: '/boot', builder: (_, s) => BootScreen(from: s.uri.queryParameters['from'])),
  // 첫 화면(동의·로그인·내 정보)은 웹·앱 공통 — web-prototype 온보딩과 같은 구성
  GoRoute(path: '/login', builder: (_, s) => m.MLoginScreen(from: s.uri.queryParameters['from'])),
  GoRoute(path: '/setup', builder: (_, s) => m.SetupScreen(from: s.uri.queryParameters['from'])),
  GoRoute(path: '/sos', builder: (_, __) => const m.SosScreen()),
  GoRoute(path: '/location', builder: (_, __) => const InitialSetupScreen()),
  ShellRoute(builder: (_, __, child) => useMobileUi ? m.MShell(child: child) : Shell(child: child), routes: _menuRoutes([
    GoRoute(path: '/', builder: (_, __) => useMobileUi ? const m.MDashboard() : const Dashboard()),
    GoRoute(path: '/map', builder: (_, __) => const FacilitiesScreen()),
    GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
    GoRoute(path: '/ai', builder: (_, __) => useMobileUi ? const m.MAiScreen() : const AiScreen()),
    GoRoute(path: '/profile', builder: (_, __) => useMobileUi ? const m.MProfileScreen() : const ProfileScreen()),
    GoRoute(path: '/profile/edit', builder: (_, __) => const m.ProfileEditScreen()),
    // 휴대폰 앱의 '방재단 현황' 탭 (웹은 /responder)
    GoRoute(
        path: '/team',
        builder: (_, __) => const DemoSwitch(
            demo: DemoPatrolScope(child: m.MLiveResponderScreen()), live: m.MLiveResponderScreen())),
    GoRoute(
        path: '/typhoon',
        builder: (_, s) => DemoSwitch(
            demo: TyphoonScreen(initialLocal: s.extra == 'local'),
            live: LiveTyphoonRoute(initialLocal: s.extra == 'local'),
            remoteAlwaysLive: true)),
    GoRoute(
        path: '/route-search', builder: (_, __) => const CustomRouteScreen()),
    GoRoute(path: '/route-follow', builder: (_, __) => const RouteFollowScreen()),
    GoRoute(
        path: '/support',
        builder: (_, __) => const DemoSwitch(
            demo: RecoveryScreen(), live: LiveRecoveryScreen())),
    GoRoute(
        path: '/alerts-hub',
        builder: (_, __) =>
            const DemoSwitch(demo: AlertHubScreen(), live: LiveAlertHubRoute(), remoteAlwaysLive: true)),
    GoRoute(
        path: '/evacuation',
        builder: (_, __) => const DemoOnlyNotice(
            title: '대피 확인 시연', demo: EvacuationDemoRoute())),
    GoRoute(
        path: '/evacuation-voice',
        builder: (_, __) => const DemoOnlyNotice(
            title: '음성 대피 확인 시연', demo: EvacuationVoiceDemoScreen())),
    GoRoute(
        path: '/accessibility',
        builder: (_, __) => const AccessibilitySettingsScreen()),
    GoRoute(
        path: '/household',
        builder: (_, __) => const DemoSwitch(
            demo: HouseholdRegistrationScreen(), live: LiveHouseholdScreen())),
    GoRoute(
        path: '/household/delegate',
        builder: (_, __) => const DemoSwitch(
            demo: DemoPatrolScope(child: LiveDelegatedHouseholdScreen()),
            live: LiveDelegatedHouseholdScreen())),
    GoRoute(
        path: '/responder',
        // 시연 모드: 실제 방재단 화면 + 앱 안 시연 가구 12곳 (DemoLiveApi)
        builder: (_, __) => const DemoSwitch(
            demo: DemoPatrolScope(child: LiveResponderScreen()), live: LiveResponderScreen())),
    GoRoute(
        path: '/sea-route',
        builder: (_, __) => const DemoSwitch(
            demo: SeaRouteDemoScreen(), live: LiveSeaRouteScreen())),
  ])),
  GoRoute(
      path: '/facility/:id',
      builder: (_, s) => FacilityScreen(id: s.pathParameters['id']!)),
  GoRoute(
      path: '/alert/:id',
      builder: (_, s) => AlertScreen(id: s.pathParameters['id']!)),
]);

class EvacuationDemoRoute extends ConsumerWidget {
  const EvacuationDemoRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => EvacuationDemoScreen(
        onResponse: (status) => _recordPrototypeEvacuationResponse(ref, status),
      );
}

class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key, this.from});
  /// 시작 화면을 거친 뒤 돌아갈 주소 (새로고침·주소 직접 입력으로 들어온 화면)
  final String? from;
  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen> {
  String text = '인증 상태를 확인하는 중…';
  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    final a = await AuthService().initialize();
    // 프로필에서 '직접 지정'한 출발 위치가 있으면 그 위치로 시작 (계정 정보를 내려받은 뒤)
    await restoreSavedOrigin(ref);
    await AccountService().clearLegacyMode();
    if (!mounted) return;
    setState(
        () => text = a.isMock ? 'Firebase 미설정: 목업 모드로 시작합니다.' : '로그인 확인 완료');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // 첫 설정(주소·나이·이동 수단)을 강제하지 않는다 (2026-10-07 사용자 요청) — 바로 시작하고 프로필에서 자유롭게 입력.
    // 비어 있으면 성인·도보 기준으로 안내하고, AI 대화에서 말한 정보는 'AI가 기억한 정보'로 빈 칸에 채워진다
    appBooted = true;
    final from = widget.from;
    final next = from != null && from.startsWith('/') && !from.startsWith('/boot') ? from : '/';
    if (mounted) context.go(next);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.health_and_safety_outlined, size: 72),
        const SizedBox(height: 16),
        const Text('구룡포 안전',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(text),
        const SizedBox(height: 20),
        const CircularProgressIndicator()
      ])));
}

class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('초기 위치 설정')),
      body: Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.location_on_outlined, size: 62),
                    const SizedBox(height: 16),
                    const Text('현재 위치를 설정하세요',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('목업에서는 구룡포 예시 좌표를 사용합니다.',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                        onPressed: () => c.go('/'),
                        icon: const Icon(Icons.my_location),
                        label: const Text('위치 권한 허용 (예시)')),
                    OutlinedButton.icon(
                        onPressed: () => c.go('/'),
                        icon: const Icon(Icons.map),
                        label: const Text('지도에서 직접 선택 (예시)'))
                  ]))));
}

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  bool _showingEvacuationAlert = false;
  final Set<String> _shownAlertIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _presentNextAlert());
  }

  void _scheduleAlertCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _presentNextAlert());
  }

  Future<void> _presentNextAlert() async {
    if (!mounted || _showingEvacuationAlert) return;
    final pending = ref.read(pendingResponseIdsProvider);
    final alert = ref
        .read(alertCenterProvider)
        .where((item) =>
            item.responseRequired &&
            item.myStatus == null &&
            !pending.contains(item.id) &&
            !_shownAlertIds.contains(item.id))
        .firstOrNull;
    if (alert == null) return;
    _showingEvacuationAlert = true;
    _shownAlertIds.add(alert.id);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => EvacuationAlertDialog(alert: alert),
      );
    } finally {
      _showingEvacuationAlert = false;
      _scheduleAlertCheck();
    }
  }

  @override
  Widget build(BuildContext c) {
    ref.listen<List<AlertItem>>(
        alertCenterProvider, (_, __) => _scheduleAlertCheck());
    ref.listen<Set<String>>(pendingResponseIdsProvider, (previous, next) {
      for (final id in previous ?? const <String>{}) {
        if (!next.contains(id) &&
            ref.read(alertCenterProvider).any((item) =>
                item.id == id &&
                item.responseRequired &&
                item.myStatus == null)) {
          _shownAlertIds.remove(id);
        }
      }
      _scheduleAlertCheck();
    });
    // 메뉴 4개 = web-prototype (2026-10-08 사용자 결정): 대시보드 · AI 대화창 · 사용자 · (방재단·관리자·시연) 방재단 현황.
    // 태풍 정보·선제 경고·지원 및 복구는 메뉴에서 빠지고 대시보드 카드·알림 종으로 간다 (주소는 그대로)
    final role = '${ref.watch(meProvider).valueOrNull?['role'] ?? ''}';
    final crew = isPatrolRole(role) || ref.watch(showDemoProvider);
    final List<GkNavItem> nav = [
      ('대시보드', Icons.grid_view_rounded, '/'),
      ('AI 대화창', Icons.chat_bubble_rounded, '/ai'),
      if (crew) ('방재단 현황', Icons.shield_rounded, '/responder'),
      ('사용자', Icons.person_rounded, '/profile'),
    ];
    final wide = MediaQuery.sizeOf(c).width >= 840;
    final here = GoRouterState.of(c).uri.path;
    final found = nav.indexWhere((x) => x.$3 == here);
    ref.watch(gpsTracker);
    final body = Column(children: [StatusLine(compact119: !wide), Expanded(child: widget.child)]);
    if (wide) {
      return Scaffold(
          body: Row(children: [
        GkSideNav(
            items: nav,
            selected: found,
            onTap: (i) => c.go(nav[i].$3),
            bottom: GkEmergencyCall(onCall: () => call119(c))),
        Expanded(child: body),
      ]));
    }
    return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: NavigationBar(
            selectedIndex: found < 0 ? 0 : found,
            indicatorColor: found < 0 ? Colors.transparent : null,
            onDestinationSelected: (i) => c.go(nav[i].$3),
            destinations: [for (final x in nav) NavigationDestination(icon: Icon(x.$2), label: x.$1)]));
  }
}

class EvacuationAlertDialog extends ConsumerStatefulWidget {
  const EvacuationAlertDialog({super.key, required this.alert, this.onRespond});
  final AlertItem alert;

  /// 시연용: 주면 서버로 보내지 않고 이 함수로 응답을 처리한다 (showEvacuationAlertDemo)
  final Future<void> Function(String status)? onRespond;

  @override
  ConsumerState<EvacuationAlertDialog> createState() =>
      _EvacuationAlertDialogState();
}

class _EvacuationAlertDialogState extends ConsumerState<EvacuationAlertDialog> {
  bool _busy = false;

  Future<void> _respond(String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    final demo = widget.onRespond;
    if (demo != null) {
      Navigator.of(context).pop();
      await demo(status);
      return;
    }
    final result = await _submitEvacuationResponse(ref, widget.alert, status);
    if (!mounted) return;
    if (result == _ResponseSubmitResult.sent ||
        result == _ResponseSubmitResult.queued) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = false);
  }

  /// 상태 버튼 (프로토타입 EvacModal: 원 아이콘 + 이름·설명, 도움 필요만 빨강)
  Widget _choice(String status, IconData icon, String label, String desc, Color color) {
    final help = status == 'need_help';
    return Material(
      color: help ? GK.red : GK.bg,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _busy ? null : () => _respond(status),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 22, 10),
          child: Row(children: [
            GkCircleIcon(icon, size: 52, bg: help ? Colors.white : color, fg: help ? GK.red : Colors.white),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: help ? Colors.white : GK.ink)),
                Text(desc, style: TextStyle(fontSize: 15, color: help ? Colors.white.withValues(alpha: .9) : GK.muted)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// 대피 확인 경보 = web-prototype EvacModal (2026-10-08)
  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(36)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Center(child: GkCircleIcon(Icons.directions_run_rounded, size: 72, bg: GK.red, fg: Colors.white)),
              const SizedBox(height: 10),
              Text('대피 필요 · ${widget.alert.title}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GK.red)),
              const SizedBox(height: 6),
              const Text('지금 당장 대피해야 합니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.6)),
              const SizedBox(height: 12),
              Text(widget.alert.summary, style: const TextStyle(fontSize: 16, height: 1.5, color: GK.ink)),
              if (widget.alert.guide.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: GK.orangeTint, borderRadius: BorderRadius.circular(20)),
                  child: Text(widget.alert.guide,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: GK.orangeInk, height: 1.45)),
                ),
              ],
              const SizedBox(height: 18),
              const Text('지금 상태를 알려주세요',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              _choice('evacuated', Icons.check_circle_rounded, '대피 완료', '대피소에 도착했어요', GK.green),
              const SizedBox(height: 10),
              _choice('evacuating', Icons.directions_walk_rounded, '대피 중', '지금 대피소로 가고 있어요', GK.orange),
              const SizedBox(height: 10),
              _choice('need_help', Icons.sos_rounded, '도움 필요', '혼자 이동하기 어려워요', GK.red),
              if (_busy)
                const Center(child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator())),
            ]),
          ),
        ),
      );
}

/// 시연: 실제 대피 확인 경보와 같은 팝업을 띄운다 (2026-10-05 사용자 요청). 응답은 서버로 보내지 않고 기기의
/// 시연 기록(prototypeSafetyProvider)에만 남는다 — '대피 중'이면 실제처럼 가까운 대피소 경로 안내를 시작한다
const _demoEvacuationAlert = AlertItem(
  id: prototypeEvacuationAlertId,
  title: '[대피 확인] 호우 경보 · 현재 위치 (시연)',
  level: 'warning',
  time: '',
  summary: '구룡포읍행정복지센터 강우량계 시간당 38.5mm · 포항 DT 4단계(경보) (시연 — 실제 경보가 아닙니다). '
      '지금 계신 곳이 위험 영역 안입니다. 하천·해안가·비탈면 가까이 가지 말고 안전한 실내에 머무르세요. '
      '대피를 시작하셨으면 \'대피 중\', 대피소에 도착하셨으면 \'대피 완료\', 혼자 움직이기 어려우면 \'도움 필요\'를 눌러 주세요.',
  guide: '즉시 안전한 실내나 지정 대피소로 이동하고, 물이 고인 도로·해안가·맨홀 주변에 접근하지 마세요.',
  responseRequired: true,
);

/// [newAlert] = 새 시연 경보로 시작 (이전 시연 응답을 지운다). 상단 대피 현황 칩에서 다시 열 때는 false (응답 바꾸기)
Future<void> showEvacuationAlertDemo(BuildContext context, WidgetRef ref, {bool newAlert = true}) async {
  if (newAlert) await ref.read(prototypeSafetyProvider).startDemoAlert(prototypeEvacuationAlertId);
  if (!context.mounted) return;
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EvacuationAlertDialog(
        alert: _demoEvacuationAlert,
        onRespond: (status) async {
          final s = EvacuationResponseStatusLabel.fromWireValue(status);
          if (s == null) return;
          await _recordPrototypeEvacuationResponse(ref, s);
          _showResponseMessage('시연 응답: ${s.label} (기기에만 기록, 서버로 보내지 않음)');
        },
      ),
    );
}

/// 공통 상단 '대피 현황' (2026-10-09 사용자 요청): 지금 진행 중인 대피 경보에 대한 내 응답만 본다.
/// 진행 중인 경보 = 서버가 알려 준 내 대피 상황(alertEvacuationProvider, 경보 폴링의 evacuation — 열린 대피 상황만).
/// 지난 경보의 응답은 쓰지 않는다. 시연 모드면 '대피 경보 팝업'으로 시작한 시연 경보(기기에만 기록)를 '시연' 표시와 함께.
class EvacHeaderState {
  const EvacHeaderState({this.status, this.alertId, this.demo = false});
  /// null = 진행 중인 대피 경보 없음, no_response = 응답 전, need_help · evacuating · evacuated
  final String? status;
  final String? alertId;
  final bool demo;
  bool get active => status != null;
}

const _evacResponses = {'need_help', 'evacuating', 'evacuated'};

EvacHeaderState evacHeaderState(WidgetRef ref) {
  final evac = ref.watch(alertEvacuationProvider);
  if (evac != null) {
    final s = evac['status'] as String?;
    return EvacHeaderState(
        status: _evacResponses.contains(s) ? s : 'no_response', alertId: evac['alert_id'] as String?);
  }
  if (ref.watch(showDemoProvider)) {
    final demo = ref.watch(prototypeSafetyProvider);
    if (demo.demoAlertActive) {
      return EvacHeaderState(
          status: demo.responseFor(prototypeEvacuationAlertId)?.wireValue ?? 'no_response',
          alertId: prototypeEvacuationAlertId,
          demo: true);
    }
  }
  return const EvacHeaderState();
}

/// 대피 현황 상태별 글자·아이콘·색 (색만으로 구분하지 않도록 아이콘·글자가 모두 다르다)
({String label, IconData icon, Color fg, Color iconBg}) evacHeaderStyle(String? status) => switch (status) {
      'no_response' => (label: '응답 전', icon: Icons.directions_run_rounded, fg: GK.navy, iconBg: GK.tint),
      'need_help' => (label: '도움 필요', icon: Icons.sos_rounded, fg: GK.redDark, iconBg: GK.redTint),
      'evacuating' => (label: '대피 중', icon: Icons.directions_walk_rounded, fg: GK.orangeInk, iconBg: GK.orangeTint),
      'evacuated' => (label: '대피 완료', icon: Icons.check_circle_rounded, fg: GK.green, iconBg: const Color(0xFFE3F4EA)),
      _ => (label: '대피 경보 없음', icon: Icons.verified_user_outlined, fg: GK.muted, iconBg: GK.bg),
    };

/// 대피 현황 칩을 누르면: 진행 중인 경보의 응답 팝업을 다시 연다 (응답 바꾸기)
void openEvacHeader(BuildContext c, WidgetRef ref, EvacHeaderState st) {
  if (!st.active) return;
  if (st.demo) {
    showEvacuationAlertDemo(c, ref, newAlert: false);
    return;
  }
  final alert = ref.read(alertCenterProvider).where((a) => a.id == st.alertId).firstOrNull;
  if (alert != null) {
    showDialog<void>(context: c, barrierDismissible: false, builder: (_) => EvacuationAlertDialog(alert: alert));
  } else if (st.alertId != null) {
    c.push('/alert/${Uri.encodeComponent(st.alertId!)}');
  }
}

/// 대피 현황 칩 (공통 상단)
class EvacStatusChip extends ConsumerWidget {
  const EvacStatusChip({super.key, this.narrow = false});
  final bool narrow;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final evac = evacHeaderState(ref);
    final st = evacHeaderStyle(evac.status);
    return Tooltip(
      message: evac.active ? '눌러서 대피 응답 바꾸기' : '진행 중인 대피 경보가 없습니다',
      child: Semantics(
        label: '대피 현황 ${st.label}${evac.demo ? ' (시연)' : ''}',
        button: evac.active,
        excludeSemantics: true,
        child: Material(
          color: Colors.white,
          shape: StadiumBorder(
              side: evac.status == 'need_help' ? const BorderSide(color: GK.red, width: 2) : BorderSide.none),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: evac.active ? () => openEvacHeader(c, ref, evac) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                GkCircleIcon(st.icon, size: narrow ? 34 : 40, bg: st.iconBg, fg: st.fg),
                const SizedBox(width: 8),
                Text('대피 현황',
                    style: TextStyle(fontSize: narrow ? 14 : 16, fontWeight: FontWeight.w700, color: GK.muted)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(st.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: narrow ? 17 : 20,
                          fontWeight: FontWeight.w800,
                          color: evac.active ? GK.ink : GK.muted)),
                ),
                if (evac.demo) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: GK.tint, borderRadius: BorderRadius.circular(999)),
                    child: const Text('시연',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: GK.navy)),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 위쪽 머리줄 = web-prototype ResidentHeader (2026-10-08): 온라인/오프라인 배지 · 대피 현황 칩(2026-10-09, 예전 현재 위치 알약) ·
/// 알림 종(선제 경고·알림 화면) · 좁은 화면이면 119. 현재 위치 확인은 지도의 '현위치' 버튼과 경로 안내에 그대로 있다
class StatusLine extends ConsumerWidget {
  const StatusLine({super.key, this.compact119 = false});
  final bool compact119;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final isOffline = ref.watch(offline);
    final unread = ref.watch(alertCenterProvider).where((a) => !a.read).length;
    final narrow = MediaQuery.sizeOf(c).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 12 : 40, narrow ? 10 : 20, narrow ? 12 : 40, narrow ? 6 : 12),
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            // 온라인 배지 — 누르면 오프라인 화면 보기 (예전 '오프라인 보기'·'다시 연결')
            Tooltip(
              message: isOffline ? '다시 연결' : '오프라인 보기 · ${AppConfig.dataLabel}',
              child: GkPill(isOffline ? '오프라인' : '온라인',
                  icon: isOffline ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
                  bg: isOffline ? GK.orange : Colors.white,
                  fg: isOffline ? Colors.white : GK.navy,
                  onTap: () => ref.read(offline.notifier).state = !isOffline),
            ),
            EvacStatusChip(narrow: narrow),
          ]),
        ),
        const SizedBox(width: 10),
        if (compact119) ...[GkEmergencyCall(compact: true, onCall: () => call119(c)), const SizedBox(width: 8)],
        // 알림 종 → 선제 경고·알림 화면 (메뉴에서 빠짐, 2026-10-08)
        Tooltip(
          message: '받은 알림',
          child: Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            backgroundColor: GK.navy,
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                // 알림 화면이 열려 있으면 종을 다시 눌러 닫는다 (2026-10-10)
                onTap: () {
                  final router = GoRouter.of(c);
                  if (router.routerDelegate.currentConfiguration.uri.path != '/alerts-hub') {
                    c.push('/alerts-hub');
                  } else if (router.canPop()) {
                    router.pop();
                  } else {
                    router.go('/');
                  }
                },
                child: const SizedBox(
                    width: 52, height: 52, child: Icon(Icons.notifications_rounded, color: GK.navy, size: 28)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class Dashboard extends ConsumerWidget {
  const Dashboard(
      {super.key,
      this.extraPolygons = const [],
      this.extraMarkers = const [],
      this.extraPolylines = const [],
      this.mapOnly = false,
      this.showFacilities = false,
      this.focusPoint});

  /// 방재단 현황(2026-10-09)이 대시보드 지도 칸만 쓸 때 (DisasterDashboard 참고)
  final List<Polygon> extraPolygons;
  final List<Marker> extraMarkers;
  final List<Polyline> extraPolylines;
  final bool mapOnly;
  /// 방재단 지도: 대피소·의료시설을 늘 그리고, 목록에서 고른 가구로 지도를 옮긴다 (2026-10-09)
  final bool showFacilities;
  final LatLng? focusPoint;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    // 방재단 현황(mapOnly)은 대시보드에서 정한 개인 경로(목적지·경로선·해상 경로)를 보이지 않는다 (2026-10-11 사용자 요청 —
    // 대시보드 경로 안내는 개인용, 방재단 경로 안내는 방문 경로로 따로)
    final route = mapOnly ? null : ref.watch(routeFacilityId);
    // 화면은 김다인 대시보드 UI 하나. 시연 모드면 가상 시나리오, 아니면 서버 실측 데이터로 채운다 (2026-10-05)
    // 앱 안 가상 화면은 서버 없이 실행(APP_MODE=mock)할 때만. 서버 연결이면 시연 모드도 실측 화면 + 서버 시연 데이터
    final demo = !AppConfig.isRemote;
    final serverDemo = ref.watch(serverDemoProvider);
    final routeAsync = route == null ? null : ref.watch(routeProvider(route));
    final routeType = ref.watch(routeKind);
    final facilities =
        ref.watch(facilitiesProvider).valueOrNull ?? const <Facility>[];
    final destination = route == null ? null : routeDestination(ref, route);
    final live = demo ? null : ref.watch(liveDashboardProvider).valueOrNull;
    final sea = demo || mapOnly ? null : ref.watch(seaRoutePlanProvider).valueOrNull;
    return DisasterDashboard(
      extraPolygons: extraPolygons,
      extraMarkers: extraMarkers,
      extraPolylines: extraPolylines,
      mapOnly: mapOnly,
      showFacilities: showFacilities,
      focusPoint: focusPoint,
      demo: demo,
      floodGrids: demo ? null : ref.watch(floodGridProvider).valueOrNull,
      riskItems: liveRiskItems(live),
      windPoints: demo
          ? const []
          : [
              for (final w in ref.watch(windPointsProvider).valueOrNull ?? const <WindPoint>[])
                (w.position, w.speed, w.dirDeg, w.name, w.observedAt)
            ],
      simulated: serverDemo,
      liveTop: demo ? null : const LiveDashboardTop(),
      liveBottom: demo ? null : const LiveRealtimeSection(),
      // 디자인 = web-prototype (2026-10-08): 재난문자·경보 카드와 제목 아래 판정 시각
      warnings: liveWidgetItems(live, 'warnings'),
      messages: liveWidgetAvailable(live, 'disaster_messages') ? liveWidgetItems(live, 'disaster_messages') : null,
      messagesReason: liveWidgetReason(live, 'disaster_messages'),
      headline: live?['headline'] == null ? null : Map<String, dynamic>.from(live!['headline'] as Map),
      statusText: demo ? '가상 시연 데이터' : liveStatusText(live),
      updatedText: live == null ? null : '${hhmm(live['updated_at'])} 갱신',
      onRefresh: demo
          ? null
          : () {
              ref.invalidate(liveDashboardProvider);
              ref.invalidate(riskAreasProvider);
              ref.invalidate(floodGridProvider);
              ref.invalidate(windPointsProvider);
            },
      // '출발: …' 표시와 '주소로 길찾기' 버튼은 뺐다 (2026-10-09 사용자 요청). 위치 확인은 지도의 '현위치' 버튼
      // 경로 안내 한 덩어리: 출발 → 도착·이동 수단·경로 방식·시간 (2026-10-10). 방재단 현황 지도(mapOnly)도 같은 것을 쓴다.
      // '이동 중 안내' 버튼은 뺐다 (2026-10-10 사용자 요청)
      routePlanner: mapOnly ? null : const RoutePlanner(),
      onMapPick: !mapOnly && ref.watch(mapPickMode) ? (p) => RoutePlanner.useMapPoint(c, ref, p) : null,
      where: ref.watch(whereNowProvider).when(
          data: (w) => w,
          loading: () => const WhereNow(WhereKind.checking),
          error: (_, __) => const WhereNow(WhereKind.unknown, reason: '바다·육지를 판별하지 못했습니다.')),
      onLocate: () async {
        final msg = await useGpsOrigin(ref);
        if (msg != null && c.mounted) {
          ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));
        }
        return ref.read(userLocation).position;
      },
      onSeaRoute: () => c.push('/sea-route'),
      // 바다 위면 경로 안내에서 바로 해상 경로를 받아 지도에 그린다 (2026-10-10 사용자 요청)
      seaRoutePanel: demo || mapOnly ? null : const SeaRoutePanel(),
      seaRouteLines: sea == null ? const [] : seaRoutePolylines(sea),
      seaRouteMarkers: sea == null ? const [] : seaRouteMarkers(sea),
      routeActive: route != null,
      facilities: facilities,
      riskAreas: ref.watch(riskAreasProvider).valueOrNull ?? const <RiskArea>[],
      // 길찾기 경로는 사용자가 정한 출발지에서 그린다
      currentLocation: route == customRouteId
          ? (ref.watch(routeStartOrigin) ?? ref.watch(userLocation).position)
          : ref.watch(userLocation).position,
      selectedDestination: destination,
      safetyRoute: routeAsync?.valueOrNull,
      routeLoading: routeAsync?.isLoading ?? false,
      routeError: routeAsync?.hasError == true ? '${routeAsync?.error}' : null,
      routeType: routeType,
      onChooseFacility: () => showModalBottomSheet<void>(
                context: c,
                showDragHandle: true,
                builder: (_) => const ShelterPickerSheet(),
              ),
      travelMode: ref.watch(travelMode),
      onTravelModeChanged: (m) => ref.read(travelMode.notifier).state = m,
      // 경로 방식은 목적지를 고르기 전에도 정해 둔다 — 고른 목적지 경로가 이 방식으로 나온다 (routeProvider 가 routeKind 를 본다)
      onRouteTypeChanged: (type) => ref.read(routeKind.notifier).state = type,
      onEndRoute: () => ref.read(routeFacilityId.notifier).state = null,
      onRetryRoute:
          route == null ? null : () => ref.invalidate(routeProvider(route)),
    );
  }
  /*Widget build(BuildContext c, WidgetRef ref) => ref.watch(riskProvider).when(
      loading: () => const DashboardLoading(),
      error: (e, _) => LoadError(message: '$e', onRetry: () => ref.invalidate(riskProvider)),
      data: (risk) {
        final route = ref.watch(routeFacilityId);
        final selectedRouteType = ref.watch(routeKind);
        final main = route == null
            ? const ServiceMap()
            : RouteMap(
                key: ValueKey(
                    'route-$route-${selectedRouteType.name}-${ref.watch(mode).name}'),
                facilityId: route);
        final side = AiPanel(risk: risk);
        return LayoutBuilder(
            builder: (_, b) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      b.maxWidth > 900
                          ? Row(children: [
                              const Icon(Icons.notifications_outlined),
                              const SizedBox(width: 6),
                              Text(
                                  '알림 | 사용자 맞춤 안내'),
                              const Spacer(),
                              FilledButton.icon(
                                  onPressed: () {
                                    startRouteToShelter(ref,
                                        ref.read(routeFacilityId) ?? nearestShelterId(ref));
                                  },
                                  icon: const Icon(Icons.directions_walk),
                                  label: const Text('경로 안내')),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                  onPressed: () => call119(c),
                                  icon: const Icon(Icons.phone_in_talk),
                                  label: const Text('119 연결 및 위치 전송'))
                            ])
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(children: [
                                  const Icon(Icons.notifications_outlined),
                                  const SizedBox(width: 6),
                                  Expanded(
                                      child: Text(
                                          '알림 | 사용자 맞춤 안내',
                                          overflow: TextOverflow.ellipsis))
                                ]),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                    onPressed: () {
                                      startRouteToShelter(ref,
                                          ref.read(routeFacilityId) ?? nearestShelterId(ref));
                                    },
                                    icon: const Icon(Icons.directions_walk),
                                    label: const Text('경로 안내')),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                    onPressed: () => call119(c),
                                    icon: const Icon(Icons.phone_in_talk),
                                    label: const Text('119 연결 및 위치 전송'))
                              ],
                            ),
                      const SizedBox(height: 10),
                      FloodWarningBanner(risk: risk),
                      const SizedBox(height: 12),
                      RainWaterInfographic(risk: risk),
                      const SizedBox(height: 12),
                      b.maxWidth > 900
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                  Expanded(flex: 3, child: main),
                                  const SizedBox(width: 12),
                                  SizedBox(width: 360, child: side)
                                ])
                          : Column(children: [
                              main,
                              const SizedBox(height: 12),
                              side
                            ]),
                      const SizedBox(height: 12),
                      ModeCards(risk: risk)
                    ])));
      });*/
}

/// 이동 중 안내: 경로 지도 + 30초마다 현재 위치로 경로 재확인 (POST /api/route/check, C5) — 대시보드 경로 패널의 '이동 중 안내'
class RouteFollowScreen extends ConsumerWidget {
  const RouteFollowScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final route = ref.watch(routeFacilityId);
    final routeType = ref.watch(routeKind);
    if (route == null) {
      return const Center(child: Text('진행 중인 경로가 없습니다. 대시보드에서 목적지를 고르세요.'));
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
            child: Text('이동 중 안내 · ${routeType.label}',
                style: Theme.of(c).textTheme.headlineSmall)),
        TextButton.icon(
            onPressed: () => c.pop(), icon: const Icon(Icons.dashboard_outlined), label: const Text('대시보드')),
      ]),
      RouteMap(key: ValueKey('follow-$route-${routeType.name}'), facilityId: route),
    ]);
  }
}

class RiskCard extends StatelessWidget {
  const RiskCard({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext c) => Card(
      color: risk.color,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 34),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('${risk.level} · ${risk.title}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  Text(risk.summary,
                      style: const TextStyle(color: Colors.white))
                ])),
            TextButton(
                onPressed: () => c.go('/map'),
                child:
                    const Text('대피소 보기', style: TextStyle(color: Colors.white)))
          ])));
}

class FloodWarningBanner extends StatelessWidget {
  const FloodWarningBanner({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context) => AppConfig.isRemote
      ? _live()
      : Card(
          color: risk.color,
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text('${risk.level} · 호우·침수 위험 · 예시 데이터',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold))),
                      VoiceButton(
                          text: '현재 위치와 등록 장소 주변의 침수 가능성을 확인하고 안전한 실내로 이동하세요.')
                    ]),
                    const SizedBox(height: 8),
                    const Text('선제 경고: 현재 위치와 등록 장소 주변의 저지대 침수 가능성을 확인하세요.',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text(
                        '예시 데이터 기준, 저지대·침수 구간·맨홀 주변 접근을 피하고 안전한 장소를 확인하세요.',
                        style: TextStyle(color: Colors.white)),
                  ])));

  /// 실제 위험도 판정 (/api/v1/risk)
  Widget _live() => Card(
      color: risk.color,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  risk.level == '정상' || risk.level == '관심'
                      ? Icons.verified_user_outlined
                      : Icons.warning_amber_rounded,
                  color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      '${risk.level} · ${risk.title} · ${risk.updatedAt} 판정',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              VoiceButton(text: '${risk.title}. ${risk.summary}. ${risk.guide}')
            ]),
            const SizedBox(height: 8),
            Text(risk.summary,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(risk.guide, style: const TextStyle(color: Colors.white)),
          ])));
}

/// 서버에서 못 불러왔을 때 (연결 실패 등)
class LoadError extends StatelessWidget {
  const LoadError({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'))
          ])));
}

class RainWaterInfographic extends StatelessWidget {
  const RainWaterInfographic({super.key, required this.risk});
  final RiskStatus risk;
  @override
  Widget build(BuildContext context) => AppConfig.isRemote
      ? _live()
      : Card(
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.water_drop, color: Colors.blue),
                    const SizedBox(width: 6),
                    const Text('침수 현황 인포그래픽',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('마지막 갱신 ${risk.updatedAt} · 예시 데이터',
                        style: const TextStyle(fontSize: 12))
                  ]),
                  const SizedBox(height: 12),
                  Row(children: const [
                    Expanded(
                        child: _Metric(
                            label: '현재 강수량',
                            value: '18 mm/h',
                            color: Colors.blue,
                            icon: Icons.umbrella)),
                    SizedBox(width: 8),
                    Expanded(
                        child: _Metric(
                            label: '최근 누적',
                            value: '86 mm',
                            color: Colors.indigo,
                            icon: Icons.bar_chart)),
                    SizedBox(width: 8),
                    Expanded(
                        child: _Metric(
                            label: '현재 수위',
                            value: '2.8 m',
                            color: Colors.deepOrange,
                            icon: Icons.waves)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    const Text('현재 위험 단계  '),
                    Chip(label: Text('${risk.level} · 예시 데이터')),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('현재 수위 위험도'))
                  ]),
                  Row(children: [
                    const SizedBox(width: 96),
                    Expanded(
                        child: LinearProgressIndicator(
                            value: .82,
                            minHeight: 12,
                            color: Colors.red,
                            backgroundColor: Colors.blue.shade100)),
                    const SizedBox(width: 8),
                    const Text('경계')
                  ]),
                ],
              )));

  /// 판정 근거 목록 (관측값·기준). 수치는 서버 판정 문구 그대로
  Widget _live() => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.water_drop, color: Colors.blue),
                const SizedBox(width: 6),
                const Text('현재 위험 판정 근거',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${risk.updatedAt} 판정${risk.stale ? ' · 갱신 지연' : ''}',
                    style: const TextStyle(fontSize: 12))
              ]),
              const SizedBox(height: 10),
              if (risk.details.isEmpty)
                const Text('발효 중인 호우·침수 등 위험 판정이 없습니다.'),
              ...risk.details.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.circle, size: 8, color: risk.color),
                        const SizedBox(width: 8),
                        Expanded(child: Text(d))
                      ]))),
              const SizedBox(height: 8),
              Row(children: [
                const Text('현재 위험 단계  '),
                Chip(label: Text(risk.level)),
                const SizedBox(width: 8),
                Expanded(
                    child: LinearProgressIndicator(
                        value: const {
                              '정상': .05,
                              '관심': .25,
                              '주의': .5,
                              '경계': .75,
                              '심각': 1.0
                            }[risk.level] ??
                            .05,
                        minHeight: 12,
                        color: risk.color,
                        backgroundColor: Colors.blue.shade100))
              ]),
            ],
          )));
}

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.label,
      required this.value,
      required this.color,
      required this.icon});
  final String label, value;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color),
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12))
      ]));
}

class DashboardLoading extends StatelessWidget {
  const DashboardLoading({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(children: [
        LinearProgressIndicator(),
        SizedBox(height: 16),
        _LoadingCard(height: 110),
        SizedBox(height: 12),
        _LoadingCard(height: 300)
      ]));
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.height});
  final double height;
  @override
  Widget build(BuildContext context) => Card(
      child: SizedBox(
          height: height,
          child: Center(child: Text('${AppConfig.dataLabel} 준비 중…'))));
}

class DashboardInfo extends ConsumerWidget {
  const DashboardInfo({super.key, required this.risk, required this.userMode});
  final RiskStatus risk;
  final UserMode userMode;
  @override
  Widget build(BuildContext c, WidgetRef ref) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('사용자 맞춤 안내',
                          style: Theme.of(c).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      const Text('현재 위치와 등록 장소를 바탕으로 안전 정보와 대피소를 안내합니다.'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed: () {
                            startRouteToShelter(ref, nearestShelterId(ref));
                            c.go('/');
                          },
                          icon: const Icon(Icons.directions_walk),
                          label: const Text('가장 안전한 경로 안내'))
                    ]))),
        const SizedBox(height: 10),
        Card(
            child: ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('즉시 행동 요령'),
                subtitle: Text(risk.guide),
                trailing: IconButton(
                    icon: const Icon(Icons.auto_awesome),
                    onPressed: () => c.go('/ai')))),
        Card(
            child: ListTile(
                leading: const Icon(Icons.home_work_outlined),
                title: const Text('가까운 예시 대피소'),
                subtitle: const Text('구룡포 실내체육관 · 0.8km · 12분'),
                onTap: () => c.go('/facility/gym'))),
        OutlinedButton.icon(
            onPressed: () => call119(c),
            icon: const Icon(Icons.phone_in_talk),
            label: const Text('119 연결 (예시 위치 표시)'))
      ]);
}

class MapCard extends ConsumerStatefulWidget {
  const MapCard({
    super.key,
    required this.height,
    this.showFloodControls = true,
  });
  final double height;
  final bool showFloodControls;
  @override
  ConsumerState<MapCard> createState() => _MapCardState();
}

class _MapCardState extends ConsumerState<MapCard> {
  String? locationNote;
  FloodGrid? selected;
  final mapController = MapController();
  late final MapOptions mapOptions;
  @override
  void initState() {
    super.initState();
    // Keep options stable while overlays and provider state rebuild. flutter_map
    // revalidates the active camera whenever MapOptions is replaced; doing that
    // on every parent rebuild can trip its cameraConstraint assertion.
    mapOptions = MapOptions(
      initialCenter: const LatLng(35.9922, 129.5531),
      initialZoom: 14.5,
      // 구룡포 일대로 한정: 화면 전체가 범위 안 (2026-10-05)
      cameraConstraint: CameraConstraint.contain(bounds: guryongpoBounds),
      onTap: (_, point) {
        if (locationNote != null) {
          setPosition(ref, point, manual: true);
          setState(() => locationNote = '지도에서 선택한 현재 위치입니다.');
        }
        if (ref.read(floodLayer)) setState(() => selected = gridAt(point));
      },
    );
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }

  /// GPS 버튼: 지금 위치를 한 번 읽어 앱 전체 위치(userLocation)에 반영. 못 읽으면 지도를 눌러 고를 수 있게 한다
  Future<void> locate() async {
    try {
      final p = await ref.read(locationService).current();
      if (!mounted) return;
      if (inServiceArea(p)) {
        ref.read(gpsPosition.notifier).state = (p, false);
        setState(() => locationNote = 'GPS 현재 위치를 반영했습니다.');
      } else {
        setState(() =>
            locationNote = '현재 위치가 구룡포 밖이라 예시 위치를 씁니다. 지도를 눌러 위치를 고를 수 있습니다.');
      }
    } on LocationUnavailable catch (e) {
      if (mounted)
        setState(() => locationNote = '${e.message} 지도를 눌러 현재 위치를 고를 수 있습니다.');
    } catch (_) {
      if (mounted)
        setState(() => locationNote = '위치를 읽지 못했습니다. 지도를 눌러 현재 위치를 고르세요.');
    }
  }

  FloodGrid? gridAt(LatLng p) {
    for (final g in ref.read(floodGridProvider).valueOrNull ??
        demoFloodGrid(ref.read(floodTime))) {
      if (p.latitude >= g.south &&
          p.latitude <= g.north &&
          p.longitude >= g.west &&
          p.longitude <= g.east) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext c) {
    final floodLayerEnabled = ref.watch(floodLayer);
    final active = widget.showFloodControls && floodLayerEnabled;
    final time = ref.watch(floodTime);
    final gridAsync = ref.watch(floodGridProvider);
    final grids = gridAsync.valueOrNull ??
        (AppConfig.isRemote ? const <FloodGrid>[] : demoFloodGrid(time));
    return Card(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
            height: widget.height,
            child: Stack(children: [
              FlutterMap(
                  mapController: mapController,
                  options: mapOptions,
                  children: [
                    TileLayer(
                        urlTemplate:
                            'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        subdomains: const ['a', 'b', 'c'],
                        userAgentPackageName: 'com.example.guryongpo_safety'),
                    if (active && grids.isNotEmpty)
                      PolygonLayer(polygons: floodGridPolygons(grids)),
                    if (AppConfig.isRemote)
                      PolygonLayer(
                          polygons: riskAreaPolygons(
                              ref.watch(riskAreasProvider).valueOrNull ??
                                  const [])),
                    MarkerLayer(markers: [
                      Marker(
                          point: ref.watch(userLocation).position,
                          width: 46,
                          height: 46,
                          child: const Icon(Icons.my_location,
                              color: Colors.blue, size: 34)),
                      // 등록 장소 (없고 목업 모드면 예시 집·직장)
                      ...[
                        for (final p in ref.watch(placesProvider).valueOrNull ??
                            const <SavedPlace>[])
                          (p.position, p.type)
                      ]
                          .followedBy(
                              (ref.watch(placesProvider).valueOrNull?.isEmpty ??
                                          true) &&
                                      !AppConfig.isRemote
                                  ? const [
                                      (LatLng(35.9935, 129.5498), '집'),
                                      (LatLng(35.9879, 129.5548), '직장')
                                    ]
                                  : const <(LatLng, String)>[])
                          .map((p) => Marker(
                              point: p.$1,
                              width: 46,
                              height: 46,
                              child: Icon(
                                  p.$2 == '집'
                                      ? Icons.home
                                      : p.$2 == '직장'
                                          ? Icons.business
                                          : Icons.place,
                                  color: p.$2 == '집'
                                      ? Colors.indigo
                                      : const Color(0xffe56717),
                                  size: 32))),
                      ...?ref.watch(facilitiesProvider).valueOrNull?.map((f) =>
                          Marker(
                              point: f.position,
                              width: 55,
                              height: 45,
                              child: Icon(
                                  f.type == FacilityType.shelter
                                      ? Icons.home_work_outlined
                                      : Icons.local_hospital,
                                  color: f.type == FacilityType.shelter
                                      ? Colors.teal
                                      : Colors.red))),
                      if (active)
                        for (final g in grids.where((g) => g.hasRisk))
                          Marker(
                              point: g.center,
                              width: 18,
                              height: 18,
                              child: GestureDetector(
                                  onTap: () => setState(() => selected = g),
                                  child: DecoratedBox(
                                      decoration: BoxDecoration(
                                          color: riskColor(g.level),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white,
                                              width: 1))))),
                    ])
                  ]),
              Positioned(
                  left: 10,
                  top: 10,
                  child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor:
                              active ? GK.navy : Colors.white,
                          foregroundColor:
                              active ? Colors.white : Colors.black87),
                      onPressed: () {
                        final next = !active;
                        ref.read(floodLayer.notifier).state = next;
                        mapController.move(
                            const LatLng(35.99, 129.55), next ? 11.5 : 14.5);
                      },
                      icon: const Icon(Icons.grid_on),
                      label: const Text('침수 위험도 확인'))),
              Positioned(
                  left: 12,
                  top: 58,
                  child: IconButton.filledTonal(
                      tooltip: 'GPS 현재 위치 확인',
                      onPressed: locate,
                      icon: const Icon(Icons.gps_fixed))),
              if (active) const FloodGridLegend(),
              if (active)
                Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Material(
                        color: Colors.white.withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 5),
                            child: Row(children: [
                              IconButton(
                                  tooltip: '시간 흐름 재생',
                                  onPressed: () => ref
                                      .read(floodTime.notifier)
                                      .state = (time + 1) % 5,
                                  icon: const Icon(Icons.play_circle_outline)),
                              Expanded(
                                  child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                          children: [
                                        '현재',
                                        '1시간 후',
                                        '3시간 후',
                                        '6시간 후',
                                        '오늘 밤'
                                      ]
                                              .asMap()
                                              .entries
                                              .map((e) => Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          right: 4),
                                                  child: ChoiceChip(
                                                      label: Text(e.value),
                                                      selected: time == e.key,
                                                      onSelected: (_) => ref
                                                          .read(floodTime
                                                              .notifier)
                                                          .state = e.key)))
                                              .toList())))
                            ])))),
              if (selected != null && active)
                Positioned(
                  left: 12,
                  bottom: 55,
                  child: Material(
                    elevation: 5,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 230,
                      padding: const EdgeInsets.all(10),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(selected!.id,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold))),
                              IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      setState(() => selected = null),
                                  icon: const Icon(Icons.close, size: 18)),
                            ]),
                            Text(
                                selected!.hasRisk
                                    ? '침수 위험 · ${selected!.level}'
                                    : '확인된 침수 위험 없음 · 침수 자료 미확인',
                                style: TextStyle(
                                    color: selected!.hasRisk
                                        ? riskColor(selected!.level)
                                        : Colors.blueGrey,
                                    fontWeight: FontWeight.bold)),
                            if (selected!.depthCm != null)
                              Text(
                                  '${selected!.isExample ? '예시 ' : ''}수심 ${selected!.depthCm!.toStringAsFixed(0)}cm'),
                            Text(
                                '시각: ${selected!.observedAt ?? '확인 불가'} · 출처: ${selected!.source.isEmpty ? '자료 없음' : selected!.source}',
                                style: const TextStyle(fontSize: 11)),
                            if (selected!.isExample)
                              const Text('예시 데이터 · 실제 침수 관측이 아닙니다.',
                                  style: TextStyle(fontSize: 10)),
                            if (selected!.hasRisk)
                              const Text(
                                  '권고: 저지대·침수 구간에 진입하지 말고 안전한 경로를 이용하세요.',
                                  style: TextStyle(fontSize: 11)),
                          ]),
                    ),
                  ),
                ),
              if (locationNote != null)
                Positioned(
                    left: 12,
                    right: 12,
                    top: 105,
                    child: Material(
                        color: Colors.white.withValues(alpha: .93),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(locationNote!,
                                style: const TextStyle(fontSize: 12)))))
            ])));
  }
}

void showPlaceInfo(BuildContext context, WidgetRef ref, String type,
        String name, String detail) =>
    showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text('유형: $type · $detail'),
                  const SizedBox(height: 4),
                  Text(AppConfig.isRemote
                      ? '거리는 직선거리 기준 대략값입니다.'
                      : '모든 시설·거리·운영 상태는 예시 데이터입니다.'),
                  if (type == '대피소') ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          final f = ref
                              .read(facilitiesProvider)
                              .requireValue
                              .firstWhere((f) => f.name == name);
                          startRouteToShelter(ref, f.id);
                          context.go('/');
                        },
                        icon: const Icon(Icons.directions_walk),
                        label: const Text('경로 안내'))
                  ]
                ])));

class FacilitiesScreen extends StatelessWidget {
  const FacilitiesScreen({super.key});
  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (_, b) {
        final list = const FacilityList();
        return b.maxWidth > 850
            ? Row(children: [
                const Expanded(
                    flex: 3,
                    child: Padding(
                        padding: EdgeInsets.all(16),
                        child: MapCard(height: 480, showFloodControls: false))),
                SizedBox(width: 360, child: list)
              ])
            : Column(children: [
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: MapCard(height: 300, showFloodControls: false)),
                Expanded(child: list)
              ]);
      });
}

class FacilityList extends ConsumerStatefulWidget {
  const FacilityList({super.key});
  @override
  ConsumerState<FacilityList> createState() => _FacilityListState();
}

class _FacilityListState extends ConsumerState<FacilityList> {
  bool nearest = false;
  @override
  Widget build(BuildContext c) {
    final areas =
        ref.watch(riskAreasProvider).valueOrNull ?? const <RiskArea>[];
    int unsafe(Facility f) => shelterExclusion(f, areas) == null ? 0 : 1;
    // 안전 추천: 갈 만한 곳 먼저, 그다음 도보 시간 순 / 가까운 순: 거리만
    final fs = [...?ref.watch(facilitiesProvider).valueOrNull]
      ..sort((a, b) => nearest
          ? a.distanceKm.compareTo(b.distanceKm)
          : unsafe(a) != unsafe(b)
              ? unsafe(a) - unsafe(b)
              : a.walkMinutes.compareTo(b.walkMinutes));
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: Text(AppConfig.isRemote ? '주변 대피·의료 시설' : '예시 시설',
                    style: Theme.of(c).textTheme.titleLarge)),
            FilterChip(
                label: Text(nearest ? '가까운 순' : '안전 추천'),
                selected: true,
                onSelected: (_) => setState(() => nearest = !nearest))
          ])),
      if (ref.watch(facilitiesProvider).hasError)
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text('${ref.watch(facilitiesProvider).error}')),
      if (ref.watch(facilitiesProvider).isLoading)
        const LinearProgressIndicator(),
      Expanded(
          child: ListView(
              children: fs.map((f) {
        final warn = shelterExclusion(f, areas);
        return Card(
            child: Column(children: [
          ListTile(
              leading: Icon(
                  warn != null
                      ? Icons.warning_amber_rounded
                      : f.type == FacilityType.shelter
                          ? Icons.home_work_outlined
                          : Icons.local_hospital,
                  color: warn != null ? Colors.orange.shade800 : null),
              title: Text(f.name),
              subtitle: Text(
                  '${AppConfig.isRemote ? '약 ' : ''}${f.distanceKm}km · 도보 ${f.walkMinutes}분 · ${warn ?? f.description}'),
              onTap: () {
                startRouteToShelter(ref, f.id);
                c.go('/');
              }),
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(children: [
                Expanded(
                    child: OutlinedButton.icon(
                  onPressed: () {
                    startRouteToShelter(ref, f.id,
                        routeType: RouteType.nearest);
                    c.go('/');
                  },
                  icon: const Icon(Icons.bolt),
                  label: const Text('가까운 경로'),
                )),
                const SizedBox(width: 8),
                Expanded(
                    child: FilledButton.tonalIcon(
                  onPressed: () {
                    startRouteToShelter(ref, f.id, routeType: RouteType.safest);
                    c.go('/');
                  },
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('안전 경로'),
                )),
              ])),
        ]));
      }).toList()))
    ]);
  }
}

class FacilityScreen extends ConsumerWidget {
  const FacilityScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final fs = ref.watch(facilitiesProvider).valueOrNull;
    final f = fs?.where((x) => x.id == id).firstOrNull;
    if (f == null) {
      return Scaffold(
          appBar: AppBar(title: const Text('시설 상세')),
          body: fs == null
              ? const Center(child: CircularProgressIndicator())
              : const Center(child: Text('시설 정보를 찾지 못했습니다.')));
    }
    final label = AppConfig.isRemote ? '' : '예시 ';
    return Scaffold(
        appBar: AppBar(title: const Text('시설 상세')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(f.name, style: Theme.of(c).textTheme.headlineSmall),
          Chip(
              label: Text(f.type == FacilityType.shelter
                  ? '$label대피소'
                  : f.type == FacilityType.medical
                      ? '$label의료시설'
                      : '목적지')),
          const MapCard(height: 240, showFloodControls: false),
          Card(
              child: Column(children: [
            ListTile(title: const Text('주소'), subtitle: Text(f.address)),
            ListTile(title: const Text('구분'), subtitle: Text(f.description)),
            ListTile(
                title: const Text('거리 및 도보 시간'),
                subtitle: Text('${f.distanceKm}km · ${f.walkMinutes}분')),
            ListTile(
                title: const Text('접근성'),
                subtitle: Text(AppConfig.isRemote
                    ? (f.accessible ? '휠체어 접근 가능' : '확인 필요')
                    : (f.accessible ? '휠체어 접근 가능 (예시)' : '확인 필요 (예시)'))),
            ListTile(
                title: const Text('연락처'),
                subtitle: Text(f.phone ??
                    (AppConfig.isRemote ? '정보 없음' : '054-000-0000 (예시)')))
          ])),
          Row(children: [
            Expanded(
                child: OutlinedButton.icon(
              onPressed: () {
                startRouteToShelter(ref, f.id, routeType: RouteType.nearest);
                c.go('/');
              },
              icon: const Icon(Icons.bolt),
              label: const Text('가까운 경로'),
            )),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton.icon(
              onPressed: () {
                startRouteToShelter(ref, f.id, routeType: RouteType.safest);
                c.go('/');
              },
              icon: const Icon(Icons.shield_outlined),
              label: const Text('안전 경로'),
            )),
          ])
        ]));
  }
}

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final s = ref.watch(alertsProvider);
    final liveAlerts = AppConfig.isRemote
        ? ref.watch(alertCenterProvider)
        : s.valueOrNull ?? const <AlertItem>[];
    final pollError = ref.watch(alertFeedErrorProvider);
    final feedLoaded = ref.watch(alertFeedLoadedProvider);
    final evacuation =
        AppConfig.isRemote ? ref.watch(alertEvacuationProvider) : null;
    final pollInterval = ref.watch(alertPollIntervalProvider);
    final alertMode = ref.watch(alertModeProvider);
    final serverTime = ref.watch(alertServerTimeProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text('알림', style: Theme.of(c).textTheme.headlineSmall)),
        IconButton(
          tooltip: '알림 새로고침',
          onPressed: () => unawaited(refreshAlertFeed(ref)),
          icon: const Icon(Icons.refresh),
        ),
      ]),
      Text(AppConfig.isRemote
          ? '현재 위치 주변의 실시간 위험 판정입니다. 공식 재난 문자를 함께 확인하세요.'
          : '모든 항목은 예시 알림이며 실제 재난 경보가 아닙니다.'),
      if (AppConfig.isRemote)
        Text(
          '${alertMode == 'emergency' ? '비상 모드' : '일반 모드'} · $pollInterval초마다 확인${serverTime == null ? '' : ' · 서버 ${TimeOfDay.fromDateTime(serverTime.toLocal()).format(c)} 기준'}',
          style: Theme.of(c).textTheme.bodySmall,
        ),
      if (kIsWeb && ref.watch(showDemoProvider))
        OutlinedButton.icon(
          onPressed: () {
            final alert = AlertItem(
              id: 'web-demo-${DateTime.now().microsecondsSinceEpoch}',
              title: '웹 알림 수신 시연',
              level: '경보',
              time: TimeOfDay.now().format(c),
              summary: 'FCM 없이 웹에서 알림 수신과 알림 화면 열기를 시험합니다.',
              guide: '주변 상황을 확인하고 안전한 장소로 이동하세요.',
            );
            mergeAlertItems(ref, [alert]);
            rootMessengerKey.currentState?.showSnackBar(SnackBar(
              content: Text('새 알림: ${alert.title}'),
              action: SnackBarAction(
                label: '확인',
                onPressed: () =>
                    c.go('/alert/${Uri.encodeComponent(alert.id)}'),
              ),
            ));
          },
          icon: const Icon(Icons.notification_add_outlined),
          label: const Text('웹 알림 수신 시뮬레이션'),
        ),
      const SizedBox(height: 10),
      if (evacuation != null)
        Card(
            color: Theme.of(c).colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.directions_run),
              title: Text(evacuation['title'] as String? ?? '진행 중인 대피 상황'),
              subtitle: Text(
                  '상태: ${evacuation['status'] == 'evacuating' ? '대피 중' : evacuation['status'] ?? '확인 필요'} · ${evacuation['hazard'] ?? ''}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final alertId = evacuation['alert_id'] as String?;
                if (alertId != null && alertId.isNotEmpty) {
                  c.go('/alert/${Uri.encodeComponent(alertId)}');
                }
              },
            )),
      // 가상 대피 확인 카드·시연 버튼은 시연 모드에서만 (실제 대피 확인은 위 서버 경고 카드)
      if (ref.watch(showDemoProvider)) ...[
        EvacuationResponseCard(
          alertId: prototypeEvacuationAlertId,
          title: '구룡포 저지대 침수 대피 확인',
          detail: '안전한 실내 또는 지정 대피소로 이동해 주세요.',
          onVoice: () => c.push('/evacuation-voice'),
          onReplayVoice: () => unawaited(DemoSpeech.instance.speak(
              '대피 확인 경보입니다. 현재 상태를 말하거나 화면에서 선택해 주세요. 대피 완료, 대피 중, 도움 필요.')),
          accessibleNavigation: MediaQuery.accessibleNavigationOf(c),
          onResponse: (status) =>
              _recordPrototypeEvacuationResponse(ref, status),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: () => showEvacuationAlertDemo(c, ref),
            icon: const Icon(Icons.warning_amber_rounded),
            label: const Text('대피 경보 팝업 시연'),
          ),
          OutlinedButton.icon(
            onPressed: () => c.push('/evacuation'),
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('3버튼 기기 알림 시연'),
          ),
        ]),
      ],
      if ((!AppConfig.isRemote && s.isLoading) ||
          (AppConfig.isRemote && !feedLoaded && pollError == null))
        const LinearProgressIndicator(),
      if ((!AppConfig.isRemote && s.hasError) || pollError != null)
        LoadError(
            message: pollError ?? '${s.error}',
            onRetry: () => unawaited(refreshAlertFeed(ref))),
      if (liveAlerts.isEmpty &&
          ((!AppConfig.isRemote && !s.isLoading) ||
              (AppConfig.isRemote && feedLoaded && pollError == null)))
        const Card(
            child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('현재 알림이 없습니다'))),
      ...liveAlerts.map((a) => Card(
          child: ListTile(
              leading: Icon(a.read
                  ? Icons.notifications_none
                  : Icons.notifications_active_outlined),
              title: Text('${a.level} · ${a.title}'),
              subtitle: Text('${a.summary}\n${a.time}'),
              isThreeLine: true,
              onTap: () {
                if (AppConfig.isRemote && !a.id.startsWith('web-demo-')) {
                  mergeAlertItems(ref, [a.copyWith(read: true)]);
                  unawaited(
                      ref.read(repo).markAlertRead(a.id).catchError((_) {}));
                }
                c.go('/alert/${Uri.encodeComponent(a.id)}');
              })))
    ]);
  }
}

class AlertScreen extends ConsumerWidget {
  const AlertScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final s = ref.watch(alertsProvider);
    final items = AppConfig.isRemote
        ? ref.watch(alertCenterProvider)
        : s.valueOrNull ?? const <AlertItem>[];
    final a = items.where((x) => x.id == id).firstOrNull;
    if (a == null)
      return Scaffold(
          appBar: AppBar(title: const Text('알림 상세')),
          body: Center(
              child: s.isLoading
                  ? const CircularProgressIndicator()
                  : const Text('이미 해제된 알림입니다.')));
    return Scaffold(
        appBar: AppBar(title: const Text('알림 상세')),
        body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Chip(
                      label: Text(
                          '${a.level} · ${AppConfig.isRemote ? a.time : '예시 알림'}')),
                  Text(a.title, style: Theme.of(c).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(a.summary),
                  const SizedBox(height: 20),
                  const Text('행동 요령',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(a.guide),
                  VoiceButton(text: '${a.title}. ${a.summary}. ${a.guide}'),
                  if (id == 'work-flood') const SupportCard(),
                  const Spacer(),
                  FilledButton(
                      onPressed: () {
                        startRouteToShelter(ref, nearestShelterId(ref));
                        c.go('/');
                      },
                      child: const Text('침수 위험 그리드·안전 경로 보기')),
                  OutlinedButton(
                      onPressed: () => c.go('/ai'),
                      child: const Text('AI에게 묻기'))
                ])));
  }
}

/// AI 대화창 = web-prototype Chat (2026-10-08): 모리 얼굴 + 흰 말풍선 · 내 말풍선 남색 · 내 정보에 맞춘 추천 질문 ·
/// 알약 입력창 + 마이크(음성 질문, 서버 /api/voice) + 보내기
class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});
  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final input = TextEditingController();
  final scroll = ScrollController();
  bool recording = false;
  VoiceRecorder? recorder;
  bool hasJob = false;

  /// 답을 기다리는 중 (앱 전체 상태 — 다른 메뉴에 갔다 와도 이어짐)
  bool get loading => ref.watch(chatLoading);
  late final ChatController _chat;

  @override
  void initState() {
    super.initState();
    _chat = ref.read(chatController);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 다른 메뉴에 있는 동안 답이 왔을 수 있으니 돌아오면 마지막 말풍선으로
      if (ref.read(chatMessages).isNotEmpty) return _scrollToEnd();
      ref.read(chatMessages.notifier).state = [
        ChatMessage(
          AppConfig.isRemote
              ? '안녕하세요, 구룡가디언 AI 모리예요. 지금 위험, 가까운 대피소, 가고 싶은 곳까지의 안전한 길을 물어보세요.'
              : '예시 AI 안내입니다. 현재 위험과 대피소에 대해 물어보세요.',
          false,
        )
      ];
    });
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final o = await AccountService().optionalProfile();
    if (mounted) {
      setState(() {
        hasJob = (o['jobs'] ?? '').isNotEmpty || (o['직업'] ?? '').isNotEmpty;
      });
    }
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) {
          scroll.animateTo(scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  /// 보내기는 chatController가 한다 — 이 화면을 떠나도 답이 대화 기록에 붙는다
  Future<void> send([String? q]) async {
    final question = q ?? input.text;
    if (question.trim().isEmpty || ref.read(chatLoading)) return;
    input.clear();
    await _chat.ask(question);
  }

  /// 마이크: 누르면 녹음, 다시 누르면(또는 28초) 서버로 보내 받아쓴 질문·답을 보여 주고 답 음성을 재생 (대시보드 AiPanel과 같은 흐름)
  Future<void> toggleMic() async {
    if (ref.read(chatLoading)) return;
    if (recording) return finishVoice();
    await VoicePlayer.instance.stop();
    recorder ??= VoiceRecorder();
    final ok = await recorder!.start(onLimit: finishVoice);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('마이크 권한이 필요합니다. 브라우저·기기 설정에서 허용해 주세요.')));
      return;
    }
    setState(() => recording = true);
  }

  /// 녹음은 이 화면에서 끝내고, 서버로 보내 답 받기는 chatController가 한다 (화면을 떠나도 이어짐)
  Future<void> finishVoice() async {
    if (!recording) return;
    final loadingNotifier = ref.read(chatLoading.notifier);
    setState(() => recording = false);
    loadingNotifier.state = true;
    final wav = await recorder!.stop();
    loadingNotifier.state = false;
    if (wav == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('녹음이 너무 짧습니다. 버튼을 누르고 말씀한 뒤 다시 눌러 주세요.')));
      }
      return;
    }
    await _chat.askVoice(wav);
  }

  List<String> get suggestions => [
        '가까운 대피소는 어디야?',
        '지금 침수 위험이 있어?',
        if (hasJob) '재난 후 내가 받을 수 있는 보험이 있는지 알려줘' else '도보로 안전하게 갈 수 있어?',
        '대피할 때 뭘 해야 해?',
        // 대시보드 '재난 후 지원 · 복구' 카드를 대신한다 (2026-10-11 사용자 요청)
        '내가 받을 수 있는 재난 지원 혹은 복구 사항 알려줘',
      ];

  Widget _avatar() => Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: Colors.white, border: Border.all(color: GK.navy, width: 3)),
        clipBehavior: Clip.antiAlias,
        child: Image.asset('assets/mori-face.png',
            fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.smart_toy_rounded, color: GK.navy)),
      );

  Widget _bubble(ChatMessage m, {String? retryQuestion, bool showAvatar = true}) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final body = Container(
      constraints: BoxConstraints(maxWidth: narrow ? 320 : 560),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      decoration: BoxDecoration(
        color: m.mine ? GK.navy : Colors.white,
        borderRadius: m.mine
            ? const BorderRadius.only(
                topLeft: Radius.circular(28), topRight: Radius.circular(8), bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28))
            : const BorderRadius.only(
                topLeft: Radius.circular(8), topRight: Radius.circular(28), bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(m.text,
            style: TextStyle(fontSize: narrow ? 17 : 19, height: 1.55, color: m.mine ? Colors.white : GK.ink)),
        if (retryQuestion != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: GkPill('다시 시도', icon: Icons.refresh_rounded, onTap: loading ? null : () => send(retryQuestion)),
          ),
        if (m.answer?.route != null)
          RouteButton(onPressed: () {
            showAiRoute(ref, m.answer!);
            context.go('/');
          }),
      ]),
    );
    if (m.mine) return Align(alignment: Alignment.centerRight, child: body);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (showAvatar) _avatar() else const SizedBox(width: 56),
      const SizedBox(width: 12),
      Flexible(child: body),
    ]);
  }

  @override
  Widget build(BuildContext c) {
    final messages = ref.watch(chatMessages);
    // 답은 chatController가 붙인다 — 이 화면에 있을 때 붙으면 아래로
    ref.listen(chatMessages, (_, __) => _scrollToEnd());
    final narrow = MediaQuery.sizeOf(c).width < 600;
    final pad = gkPagePadding(c);
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(children: [
          Expanded(
            child: ListView(controller: scroll, padding: pad.copyWith(bottom: 16), children: [
              GkPageTitle('AI 대화창',
                  subtitle: AppConfig.isRemote
                      ? '실시간 데이터 기반 답변 · 공식 재난 안내를 함께 확인하세요'
                      : '목업 데이터 기반 답변 · 실제 재난 지시가 아닙니다'),
              const SizedBox(height: 8),
              for (var index = 0; index < messages.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _bubble(messages[index],
                      showAvatar: index == 0 || messages[index - 1].mine,
                      retryQuestion: messages[index].answer?.isError == true
                          ? messages.sublist(0, index).lastWhere((x) => x.mine, orElse: () => const ChatMessage('', true)).text
                          : null),
                ),
              if (loading)
                _bubble(ChatMessage(recording ? '듣고 있어요…' : '구룡포 정보를 확인하고 있습니다…', false),
                    showAvatar: messages.isEmpty || messages.last.mine),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(pad.left, 4, pad.right, narrow ? 12 : 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.auto_awesome_rounded, size: 22, color: GK.navy),
                SizedBox(width: 8),
                Text('내 정보에 맞춘 추천 질문', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GK.muted)),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final q in suggestions)
                  OutlinedButton(
                      onPressed: loading ? null : () => send(q),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          textStyle: const TextStyle(fontFamily: GK.font, fontSize: 16, fontWeight: FontWeight.w600)),
                      child: Text(q)),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 8, 8, 8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), boxShadow: GK.shadow),
                child: Row(children: [
                  Expanded(
                    child: recording
                        ? const Row(children: [
                            Icon(Icons.graphic_eq_rounded, color: GK.red, size: 30),
                            SizedBox(width: 10),
                            Expanded(
                                child: Text('듣고 있어요… 말씀이 끝나면 중지를 누르세요',
                                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, color: GK.muted))),
                          ])
                        : TextField(
                            controller: input,
                            onSubmitted: send,
                            style: TextStyle(fontSize: narrow ? 17 : 20),
                            decoration: const InputDecoration(
                                hintText: '무엇이든 물어보세요',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(vertical: 12)),
                          ),
                  ),
                  if (recording)
                    GkPill('중지', icon: Icons.stop_circle_rounded, filled: true, bg: GK.red, big: true, onTap: toggleMic)
                  else
                    _roundButton(Icons.mic_rounded, '음성 질문', GK.tint, GK.navy, loading ? null : toggleMic),
                  const SizedBox(width: 8),
                  _roundButton(loading ? null : Icons.arrow_upward_rounded, '보내기', GK.navy, Colors.white,
                      loading ? null : () => send()),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _roundButton(IconData? icon, String tip, Color bg, Color fg, VoidCallback? onTap) => Tooltip(
        message: tip,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child: icon == null
                  ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Icon(icon, color: fg, size: 28),
            ),
          ),
        ),
      );

  @override
  void dispose() {
    // 녹음 중에 다른 메뉴로 가면 거기까지 녹음한 것으로 질문한다 (답은 대화 기록에 붙음)
    if (recording) {
      recording = false; // 28초 제한(onLimit)이 사라진 화면의 finishVoice를 부르지 않게
      recorder!.stop().then((wav) {
        if (wav != null) _chat.askVoice(wav);
      });
    }
    input.dispose();
    scroll.dispose();
    super.dispose();
  }
}

/// 사용자 = web-prototype UserPage (2026-10-08) → 2026-10-09 간결하게:
/// 왼쪽 내 정보(요약·내 장소)·AI가 반영한 정보·로그인 계정, 오른쪽 알림·시연 모드·안전 기능(바다 위 대피 경로·방재단 로그인)·방재단 로그인 상태.
/// 선택 정보 카드는 2026-10-10 사용자 요청으로 뺐다 (휴대폰 화면은 그대로)
/// 경고·대피 확인·재난 후 지원·내 가구 등록은 여기 진입점만 뺐다 (화면은 대시보드 카드·알림 종 등에서 그대로)
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    const gap = SizedBox(height: 16);
    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ProfileDetailsCard(key: ValueKey('profile-${ref.watch(profileRevision)}')),
      gap,
      const ServerProfileRefresh(),
      if (AppConfig.isRemote) gap,
      const AccountCard(),
    ]);
    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const ProfileAlertsCard(),
      gap,
      if (AppConfig.isRemote) ...[const DemoModeSwitch(), gap],
      const SafetyFeaturesCard(),
      const TeamStatusCard(),
    ]);
    return ListView(padding: gkPagePadding(c), children: [
      const GkPageTitle('사용자'),
      const SizedBox(height: 8),
      GkColumns(minWidth: 460, gap: 16, equalHeight: false, children: [left, right]),
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text('앱 버전 ${AppConfig.build}',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: GK.grey))),
    ]);
  }
}

/// 주소는 앱에서 좌표화하지 않는다. 카카오 키를 보관한 서버가 좌표를 반환한다.
class FcmPushSettingsCard extends ConsumerStatefulWidget {
  const FcmPushSettingsCard({super.key});

  @override
  ConsumerState<FcmPushSettingsCard> createState() =>
      _FcmPushSettingsCardState();
}

class _FcmPushSettingsCardState extends ConsumerState<FcmPushSettingsCard> {
  bool enabled = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    FcmNotificationService.instance.isEnabled.then((value) {
      if (mounted)
        setState(() {
          enabled = value;
          loading = false;
        });
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => loading = true);
    if (value) {
      final status = await FcmNotificationService.instance.enablePush();
      final granted =
          status.name == 'authorized' || status.name == 'provisional';
      if (mounted) {
        setState(() {
          enabled = granted;
          loading = false;
        });
        if (!granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('푸시 알림 권한을 허용하지 않아 알림 폴링을 계속 사용합니다.')),
          );
        }
      }
      return;
    }
    await FcmNotificationService.instance.disablePush();
    if (mounted)
      setState(() {
        enabled = false;
        loading = false;
      });
  }

  @override
  Widget build(BuildContext context) => GkSwitchRow(
        icon: Icons.notifications_active_rounded,
        label: '재난 푸시 알림',
        desc: !AppConfig.isRemote
            ? '서버에 연결한 앱에서 쓸 수 있어요'
            : enabled
                ? '이 기기로 재난 경고를 받아요'
                : '켜면 이 기기를 등록해요 · 꺼도 앱을 열면 경고를 확인해요',
        value: enabled,
        onChanged: loading || !AppConfig.isRemote ? null : _toggle,
      );
}

class OptionalDetailsCard extends StatefulWidget {
  const OptionalDetailsCard({super.key});
  @override
  State<OptionalDetailsCard> createState() => _OptionalDetailsCardState();
}

class _OptionalDetailsCardState extends State<OptionalDetailsCard> {
  final values = <String, String>{};
  final controller = TextEditingController();
  String field = '자주 방문하는 장소';
  String? selectedValue;
  static const fields = [
    '자주 방문하는 장소',
    '시각 지원',
    '청각 지원',
    '혈액형',
    '직업',
    '비상 연락처'
  ];
  static const choices = <String, List<String>>{
    '시각 지원': ['필요 없음', '저시력', '전맹', '지원 필요'],
    '청각 지원': ['필요 없음', '난청', '농·난청', '지원 필요'],
    '혈액형': ['A+', 'A-', 'B+', 'B-', 'O+', 'O-', 'AB+', 'AB-', '모름'],
    '직업': ['어업 종사자·뱃사람', '자영업자', '농업 종사자', '직장인', '학생', '기타'],
  };
  static const legacyFieldLabels = <String, String>{
    '자주 가는 장소': '자주 방문하는 장소',
    '시각': '시각 지원',
    '청각': '청각 지원',
    '비상연락처': '비상 연락처',
    'frequent_place': '자주 방문하는 장소',
    'frequent_places': '자주 방문하는 장소',
    'frequentplace': '자주 방문하는 장소',
    'frequentplaces': '자주 방문하는 장소',
    'vision': '시각 지원',
    'vision_impaired': '시각 지원',
    'visionimpaired': '시각 지원',
    'vision_support': '시각 지원',
    'visionsupport': '시각 지원',
    'hearing': '청각 지원',
    'hearing_impaired': '청각 지원',
    'hearingimpaired': '청각 지원',
    'hearing_support': '청각 지원',
    'hearingsupport': '청각 지원',
    'blood_type': '혈액형',
    'bloodtype': '혈액형',
    'occupation': '직업',
    'job': '직업',
    'emergency_contact': '비상 연락처',
    'emergencycontact': '비상 연락처',
  };

  String? _optionalLabel(String key) {
    if (fields.contains(key)) return key;
    return legacyFieldLabels[key.trim().toLowerCase()];
  }

  String _koreanValue(String label, String value) {
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    if (const {'true', 'yes', '1'}.contains(normalized)) {
      return switch (label) {
        '시각 지원' || '청각 지원' => '지원 필요',
        _ => '예',
      };
    }
    if (const {'false', 'no', '0'}.contains(normalized)) {
      return switch (label) {
        '시각 지원' || '청각 지원' => '필요 없음',
        _ => '아니요',
      };
    }
    return const <String, String>{
          'not_needed': '필요 없음',
          'none': '해당 없음',
          'needed': '지원 필요',
          'required': '지원 필요',
          'walk': '도보',
          'walking': '도보',
          'car': '자동차',
          'bicycle': '자전거',
          'public_transit': '대중교통',
          'wheelchair': '휠체어',
          'blind': '전맹',
          'low_vision': '저시력',
          'visually_impaired': '시각 지원 필요',
          'deaf': '농·난청',
          'hard_of_hearing': '난청',
          'hearing_impaired': '청각 지원 필요',
          'fisher': '어업 종사자·뱃사람',
          'merchant': '자영업자',
          'farmer': '농업 종사자',
          'office': '직장인',
          'student': '학생',
          'unknown': '미상',
        }[normalized] ??
        value;
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final v = await AccountService().optionalProfile();
    if (!mounted) return;
    setState(() {
      for (final entry in v.entries) {
        final label = _optionalLabel(entry.key);
        if (label == null) {
          values[entry.key] = entry.value;
        } else {
          values[label] = _koreanValue(label, entry.value);
        }
      }
    });
  }

  /// 이 카드의 항목만 바꾸고 다른 화면이 저장한 값(집·직장·출발 위치·직업 …)은 그대로 둔다 (2026-10-05)
  Future<void> save() async {
    final latest = await AccountService().optionalProfile();
    for (final f in fields) {
      latest.remove(f);
    }
    await AccountService().saveOptionalProfile({
      ...latest,
      for (final f in fields)
        if (values[f] != null) f: values[f]!
    });
  }

  @override
  Widget build(BuildContext c) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('선택 정보', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('개인정보는 선택 입력이며 기기와 로그인 계정(서버)에 저장됩니다.'),
            DropdownButton<String>(
                value: field,
                isExpanded: true,
                items: fields
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (x) => setState(() {
                      field = x!;
                      selectedValue = null;
                      controller.clear();
                    })),
            Row(children: [
              Expanded(
                  child: choices.containsKey(field)
                      ? DropdownButtonFormField<String>(
                          value: selectedValue,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: '$field 선택'),
                          items: choices[field]!
                              .map((x) =>
                                  DropdownMenuItem(value: x, child: Text(x)))
                              .toList(),
                          onChanged: (x) => setState(() => selectedValue = x),
                        )
                      : TextField(
                          controller: controller,
                          decoration: InputDecoration(
                              labelText:
                                  field == '비상 연락처' ? '연락처 입력' : '장소 입력'))),
              IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    final value = choices.containsKey(field)
                        ? selectedValue
                        : controller.text.trim();
                    if (value != null && value.isNotEmpty) {
                      setState(() => values[field] = value);
                      save();
                      controller.clear();
                      selectedValue = null;
                    }
                  })
            ]),
            ...values.entries
                .where((e) => fields.contains(e.key))
                .map((e) => ListTile(
                    title: Text(e.key),
                    subtitle: Text(e.value),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () {
                            setState(() {
                              field = e.key;
                              if (choices.containsKey(e.key)) {
                                selectedValue =
                                    choices[e.key]!.contains(e.value)
                                        ? e.value
                                        : null;
                              } else {
                                controller.text = e.value;
                              }
                            });
                          }),
                      IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() => values.remove(e.key));
                            save();
                          })
                    ])))
          ])));
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

Future<void> call119(BuildContext c) async {
  // 위치를 119에 자동 전송하지는 않는다 — 통화 중 직접 말해야 한다 (예전 '예시 위치' 문구 제거, 2026-10-05)
  ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
      content: Text('119에 연결합니다. 위치는 자동 전송되지 않으니 통화 중 현재 위치를 말해 주세요.')));
  await launchUrl(Uri.parse('tel:119'));
}

class InitialSetupScreen extends ConsumerStatefulWidget {
  const InitialSetupScreen({super.key});
  @override
  ConsumerState<InitialSetupScreen> createState() => _InitialSetupScreenState();
}

class _InitialSetupScreenState extends ConsumerState<InitialSetupScreen> {
  final age = TextEditingController();
  final address = TextEditingController();
  String transport = '도보';
  bool resolving = false;
  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('필수 정보 입력')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(padding: const EdgeInsets.all(24), children: [
                Text(AppConfig.isRemote ? '구룡포 서비스 지역' : '예시 데이터 · 구룡포 서비스 지역',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                TextField(
                    controller: address,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: '주거·출발 도로명 주소',
                        hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152',
                        border: OutlineInputBorder())),
                const SizedBox(height: 6),
                const Text('목업 모드에서는 주소와 구룡포 시연 좌표를 저장합니다.',
                    style: TextStyle(fontSize: 12)),
                TextField(
                    controller: age,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: '연령 (필수)', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                DropdownButtonFormField(
                    value: transport,
                    items: const [
                      DropdownMenuItem(value: '도보', child: Text('도보')),
                      DropdownMenuItem(value: '휠체어', child: Text('휠체어'))
                    ],
                    onChanged: (v) => setState(() => transport = v!),
                    decoration: const InputDecoration(
                        labelText: '이동수단', border: OutlineInputBorder())),
                const SizedBox(height: 20),
                FilledButton(
                    onPressed: age.text.isEmpty ||
                            int.tryParse(age.text) == null ||
                            int.parse(age.text) < 1 ||
                            int.parse(age.text) > 120 ||
                            address.text.trim().isEmpty ||
                            resolving
                        ? null
                        : () => complete(),
                    child: Text(resolving ? '주소 확인 중…' : '저장 후 대시보드 보기'))
              ]))));
  Future<void> complete() async {
    setState(() => resolving = true);
    try {
      final resolved = AppConfig.isRemote
          ? await GeocodingService().resolve(address.text)
          : GeocodedAddress(
              address.text.trim(), const LatLng(35.961875, 129.5578125));
      final account = AccountService();
      await account.saveRequiredSetup(age: age.text, transport: transport);
      final optional = await account.optionalProfile();
      optional.addAll({
        'homeName': '집',
        'homeAddress': resolved.address,
        'homeLat': '${resolved.position.latitude}',
        'homeLon': '${resolved.position.longitude}',
        'transport': transport,
      });
      await account.saveOptionalProfile(optional);
      if (mounted) context.go('/');
    } on GeocodingException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  void dispose() {
    age.dispose();
    address.dispose();
    super.dispose();
  }
}

import 'dart:async';
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
import 'dashboard_parts.dart';
import 'disaster_center.dart';
import 'live_screens.dart';
import 'patrol_screens.dart';
import 'origin_picker.dart';
import 'custom_route.dart';
import 'login_screen.dart';
import 'services/demo_mode.dart';
import 'prototype_safety_screens.dart';
import 'services/demo_notifications.dart';
import 'services/prototype_safety_store.dart';
import 'services/fcm_notification_service.dart';
import 'services/evacuation_response_queue.dart';

/// APP_MODE=remote면 실제 서버, 아니면 예시 데이터
final repo = Provider<SafetyRepository>((_) =>
    AppConfig.isRemote ? RemoteSafetyRepository() : MockSafetyRepository());
final offline = StateProvider<bool>((_) => false);
final routeFacilityId = StateProvider<String?>((_) => null);
final routeFacilitySnapshot = StateProvider<Facility?>((_) => null);
final routeStartOrigin = StateProvider<LatLng?>((_) => null);

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
final chatMessages = StateProvider<List<ChatMessage>>((_) => []);
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
final riskProvider = FutureProvider<RiskStatus>(
    (ref) => ref.watch(repo).risk(ref.watch(userLocation).position));
final riskAreasProvider =
    FutureProvider<List<RiskArea>>((ref) => ref.watch(repo).riskAreas());
final floodGridProvider = FutureProvider<List<FloodGrid>>(
    (ref) => ref.watch(repo).floodGrid(timeIndex: ref.watch(floodTime)));
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
final placesProvider =
    FutureProvider<List<SavedPlace>>((_) => AccountService().places());
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
  ref.read(routeStartOrigin.notifier).state = ref.read(userLocation).position;
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
      appRouter.go('/');
    } else if (status == EvacuationResponseStatus.needHelp) {
      _showResponseMessage('방재단에게 도움을 요청했습니다');
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
  ref.read(pendingResponseIdsProvider.notifier).state = {
    ...ref.read(pendingResponseIdsProvider),
  }..remove(alertId);
}

Future<void> _afterResponseSuccess(
    WidgetRef ref, String alertId, String status) async {
  _setAlertResponse(ref, alertId, status);
  if (status == 'need_help') {
    _showResponseMessage('방재단에게 도움을 요청했습니다');
  } else if (status == 'evacuating') {
    try {
      await ref.read(facilitiesProvider.future);
    } catch (_) {
      // Use the existing fallback shelter if live facility loading fails.
    }
    startRouteToShelter(ref, nearestShelterId(ref),
        routeType: RouteType.nearest);
    appRouter.go('/');
  }
}

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
    if (!AppConfig.isRemote) return;
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
        theme: ThemeData(
            useMaterial3: true,
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xff006b73))),
        routerConfig: appRouter,
      );
}

/// 시작 화면(로그인·계정 정보 준비)을 거쳤는지. 웹에서 새로고침·주소 직접 입력으로 다른 화면부터 열리면
/// 로그인 준비 없이 서버를 불러 '로그인 정보를 확인하지 못했습니다'가 나므로 먼저 /boot 를 거치게 한다 (2026-10-05)
bool appBooted = false;

final appRouter = GoRouter(
    initialLocation: '/boot',
    redirect: (_, state) {
      if (appBooted || state.matchedLocation == '/boot') return null;
      return Uri(path: '/boot', queryParameters: {'from': state.uri.toString()}).toString();
    },
    routes: [
  GoRoute(path: '/boot', builder: (_, s) => BootScreen(from: s.uri.queryParameters['from'])),
  GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
  GoRoute(path: '/location', builder: (_, __) => const InitialSetupScreen()),
  ShellRoute(builder: (_, __, child) => Shell(child: child), routes: [
    GoRoute(path: '/', builder: (_, __) => const Dashboard()),
    GoRoute(path: '/map', builder: (_, __) => const FacilitiesScreen()),
    GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
    GoRoute(path: '/ai', builder: (_, __) => const AiScreen()),
    GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
    GoRoute(
        path: '/typhoon',
        builder: (_, s) => DemoSwitch(
            demo: TyphoonScreen(initialLocal: s.extra == 'local'),
            live: LiveTyphoonRoute(initialLocal: s.extra == 'local'))),
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
            const DemoSwitch(demo: AlertHubScreen(), live: LiveAlertHubRoute())),
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
  ]),
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
    final setupComplete = await AccountService().hasCompletedSetup();
    appBooted = true;
    final from = widget.from;
    final next = !setupComplete
        ? '/location'
        : (from != null && from.startsWith('/') && !from.startsWith('/boot') ? from : '/');
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
    const nav = [
      ('대시보드', Icons.dashboard_outlined, '/'),
      ('태풍 정보', Icons.cyclone, '/typhoon'),
      ('선제 경고·알림', Icons.notifications_active_outlined, '/alerts-hub'),
      ('지원 및 복구', Icons.health_and_safety_outlined, '/support'),
      ('프로필', Icons.person_outline, '/profile'),
      ('AI 채팅', Icons.chat_bubble_outline, '/ai'),
    ];
    final wide = MediaQuery.sizeOf(c).width >= 840;
    final destinations = nav;
    final here = GoRouterState.of(c).uri.path;
    final selected = destinations
        .indexWhere((x) => x.$3 == here)
        .clamp(0, destinations.length - 1) as int;
    ref.watch(gpsTracker);
    final body =
        Column(children: [const StatusLine(), Expanded(child: widget.child)]);
    return Scaffold(
        appBar: wide
            ? null
            : AppBar(
                title: const Text('구룡포 안전'),
              ),
        body: wide
            ? Row(children: [
                NavigationRail(
                    selectedIndex: selected,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (i) => c.go(destinations[i].$3),
                    destinations: destinations
                        .map((x) => NavigationRailDestination(
                            icon: Icon(x.$2), label: Text(x.$1)))
                        .toList()),
                const VerticalDivider(width: 1),
                Expanded(child: body)
              ])
            : body,
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: selected,
                onDestinationSelected: (i) => c.go(nav[i].$3),
                destinations: nav
                    .map((x) =>
                        NavigationDestination(icon: Icon(x.$2), label: x.$1))
                    .toList()));
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

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: Colors.red, size: 38),
        title: const Text('지금 당장 대피해야 합니다'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.alert.title,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(widget.alert.summary),
              if (widget.alert.guide.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(widget.alert.guide),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _respond('evacuating'),
                  icon: const Icon(Icons.directions_run),
                  label: const Text('대피 중'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _respond('evacuated'),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('대피 완료'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _respond('need_help'),
                  icon: const Icon(Icons.support_agent),
                  label: const Text('도움 필요'),
                ),
              ),
              if (_busy)
                const Center(
                    child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                )),
            ],
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

Future<void> showEvacuationAlertDemo(BuildContext context, WidgetRef ref) => showDialog<void>(
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

class StatusLine extends ConsumerWidget {
  const StatusLine({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final isOffline = ref.watch(offline);
    final here = ref.watch(userLocation);
    final prototypeResponse = ref
        .watch(prototypeSafetyProvider)
        .responseFor(prototypeEvacuationAlertId)
        ?.wireValue;
    final responseStatus = ref
        .watch(alertCenterProvider)
        .reversed
        .map((alert) => alert.myStatus)
        .where((status) =>
            status == 'evacuating' ||
            status == 'evacuated' ||
            status == 'need_help')
        .firstOrNull;
    final status = prototypeResponse ??
        responseStatus ??
        (ref.watch(alertEvacuationProvider)?['status'] as String?);
    final statusLabel = switch (status) {
      'evacuating' => '대피 중',
      'evacuated' => '대피 완료',
      'need_help' => '도움 필요',
      _ => null,
    };
    return Material(
        color: isOffline ? Colors.amber.shade100 : Colors.teal.shade50,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(isOffline ? Icons.cloud_off : Icons.cloud_done, size: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(isOffline
                      ? '오프라인 · 저장된 예시 정보 · 10:42'
                      : '온라인 · ${AppConfig.dataLabel}${AppConfig.isRemote ? '' : ' · 10:42'} · ${here.fromGps ? (here.manual ? (ref.watch(originLabelProvider) ?? '지도에서 고른 위치') : 'GPS 위치') : (AppConfig.isRemote ? '구룡포 기본 위치' : '예시 위치')} 기준${!here.fromGps && ref.watch(gpsNote) != null ? ' (${ref.watch(gpsNote)})' : ''}')),
              if (statusLabel != null) ...[
                Chip(
                  avatar: const Icon(Icons.directions_run, size: 16),
                  label: Text(statusLabel),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
              TextButton(
                  onPressed: () =>
                      ref.read(offline.notifier).state = !isOffline,
                  child: Text(isOffline ? '다시 연결' : '오프라인 보기'))
            ])));
  }
}

class Dashboard extends ConsumerWidget {
  const Dashboard({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final route = ref.watch(routeFacilityId);
    // 화면은 김다인 대시보드 UI 하나. 시연 모드면 가상 시나리오, 아니면 서버 실측 데이터로 채운다 (2026-10-05)
    final demo = ref.watch(showDemoProvider);
    final routeAsync = route == null ? null : ref.watch(routeProvider(route));
    final routeType = ref.watch(routeKind);
    final facilities =
        ref.watch(facilitiesProvider).valueOrNull ?? const <Facility>[];
    final destination = route == null ? null : routeDestination(ref, route);
    final live = demo ? null : ref.watch(liveDashboardProvider).valueOrNull;
    return DisasterDashboard(
      demo: demo,
      floodGrids: demo ? null : ref.watch(floodGridProvider).valueOrNull,
      riskItems: liveRiskItems(live),
      windPoints: demo
          ? const []
          : [
              for (final w in ref.watch(windPointsProvider).valueOrNull ?? const <WindPoint>[])
                (w.position, w.speed, w.dirDeg, w.name, w.observedAt)
            ],
      liveTop: demo ? null : const LiveDashboardTop(),
      liveBottom: demo ? null : const LiveRealtimeSection(),
      routeExtras: Wrap(spacing: 8, runSpacing: 4, children: [
        if (route != customRouteId) const OriginChip(),
        ActionChip(
            avatar: const Icon(Icons.alt_route, size: 18),
            label: Text(route == customRouteId ? '길찾기 다시' : '길찾기 (주소로)'),
            onPressed: () => c.push('/route-search')),
        if (route != null && !demo)
          ActionChip(
              avatar: const Icon(Icons.navigation_outlined, size: 18),
              label: const Text('이동 중 안내'),
              onPressed: () => c.push('/route-follow')),
      ]),
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
      onRouteTypeChanged: (type) {
        if (destination != null) {
          ref.read(routeKind.notifier).state = type;
          ref.invalidate(routeProvider(destination.id));
        }
      },
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
            child: Text('이동 중 안내 · ${routeType == RouteType.nearest ? '가까운 경로' : '안전 경로'}',
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
                              active ? const Color(0xff16803c) : Colors.white,
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

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});
  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final input = TextEditingController();
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(chatMessages).isNotEmpty) return;
      ref.read(chatMessages.notifier).state = [
        ChatMessage(
          AppConfig.isRemote
              ? '구룡가디언 AI입니다. 현재 위험과 대피소, 가고 싶은 곳까지의 길을 물어보세요.'
              : '예시 AI 안내입니다. 현재 위험과 대피소에 대해 물어보세요.',
          false,
        )
      ];
    });
  }

  Future<void> send([String? q]) async {
    final question = q ?? input.text;
    if (question.trim().isEmpty || loading) return;
    ref.read(chatMessages.notifier).state = [
      ...ref.read(chatMessages),
      ChatMessage(question, true),
    ];
    setState(() {
      loading = true;
      input.clear();
    });
    try {
      final answer = await ref
          .read(repo)
          .ask(question, UserMode.user, ref.read(userLocation).position);
      if (mounted) {
        ref.read(chatMessages.notifier).state = [
          ...ref.read(chatMessages),
          ChatMessage(answer.text, false, answer: answer),
        ];
      }
    } catch (_) {
      if (mounted) {
        const answer = ChatAnswer(
          'AI 서비스에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.',
          isError: true,
        );
        ref.read(chatMessages.notifier).state = [
          ...ref.read(chatMessages),
          ChatMessage(answer.text, false, answer: answer),
        ];
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final messages = ref.watch(chatMessages);
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Text(AppConfig.isRemote
              ? '실시간 데이터 기반 AI 답변 · 공식 재난 안내를 함께 확인하세요.'
              : '목업 데이터 기반 답변 · 실제 재난 지시가 아닙니다.')),
      Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(
            spacing: 8,
            children: ['가까운 대피소는 어디야?', '지금 침수 위험이 있어?', '도보로 안전하게 갈 수 있어?']
                .map(
                    (q) => ActionChip(label: Text(q), onPressed: () => send(q)))
                .toList()),
        const SizedBox(height: 14),
        ...List.generate(messages.length, (index) {
          final m = messages[index];
          String? retryQuestion;
          if (m.answer?.isError == true) {
            for (var i = index - 1; i >= 0; i--) {
              if (messages[i].mine) {
                retryQuestion = messages[i].text;
                break;
              }
            }
          }
          return Align(
            alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Card(
                child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.text),
                    if (retryQuestion != null)
                      TextButton.icon(
                          onPressed: loading ? null : () => send(retryQuestion),
                          icon: const Icon(Icons.refresh),
                          label: const Text('다시 시도')),
                    if (m.answer?.route != null)
                      RouteButton(onPressed: () {
                        showAiRoute(ref, m.answer!);
                        context.go('/');
                      }),
                  ]),
            )),
          );
        }),
        if (loading)
          const Padding(
              padding: EdgeInsets.all(12),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('구룡포 정보를 확인하고 있습니다…')
              ])),
      ])),
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: input,
                    onSubmitted: send,
                    decoration: const InputDecoration(
                        border: OutlineInputBorder(), hintText: '메시지 입력…'))),
            IconButton(
                onPressed: loading ? null : send,
                icon: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send))
          ]))
    ]);
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('사용자 정보', style: Theme.of(c).textTheme.headlineSmall),
      const ProfileDetailsCard(),
      const SizedBox(height: 12),
      const AccountCard(),
      if (AppConfig.isRemote) const DemoModeSwitch(),
      // 시연 모드면 가상 시나리오 기능 모음, 아니면 실제 서버 기능만 (2026-10-05)
      if (ref.watch(showDemoProvider)) ...[
        const PrototypeFeatureLinks(),
        const DemoRoleClaimCard(),
      ] else
        const LiveFeatureLinks(),
      const FcmPushSettingsCard(),
      if (ref.watch(showDemoProvider))
        Card(
            child: Column(children: const [
          ListTile(title: Text('이동수단'), subtitle: Text('도보')),
          ListTile(title: Text('접근성'), subtitle: Text('휠체어 접근 우선 (예시)'))
        ])),
      Card(
          child: Column(children: [
        ListTile(
            title: const Text('음성 안내 설정'),
            subtitle: Text('언어: ${ref.watch(voiceLanguage)} · 접근성 기능')),
        SwitchListTile(
            value: ref.watch(autoVoiceAlerts),
            title: const Text('재난 경고 자동 음성 재생'),
            subtitle: const Text('기본값: 꺼짐 · 사용자가 설정한 경우에만 자동 재생'),
            onChanged: (v) => ref.read(autoVoiceAlerts.notifier).state = v),
        SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '한국어', label: Text('한국어')),
              ButtonSegment(value: 'English', label: Text('English'))
            ],
            selected: {
              ref.watch(voiceLanguage)
            },
            onSelectionChanged: (v) =>
                ref.read(voiceLanguage.notifier).state = v.first),
        const SizedBox(height: 10),
      ])),
      Card(
          child: Column(children: [
        const ListTile(
            title: Text('등록 장소'),
            subtitle:
                Text('지도에 표시하고, AI에게 "집까지", "직장까지"처럼 물을 수 있어요. 이 기기에만 저장됩니다.')),
        for (final p
            in ref.watch(placesProvider).valueOrNull ?? const <SavedPlace>[])
          ListTile(
              leading: Icon(p.type == '집'
                  ? Icons.home
                  : p.type == '직장'
                      ? Icons.business
                      : Icons.place),
              title: Text(p.type == '기타' ? p.name : '${p.type} · ${p.name}'),
              subtitle: Text(
                  '${p.address.isEmpty ? '주소 없음' : p.address} · 알림 ${p.alert ? '켜짐' : '꺼짐'}'),
              trailing: IconButton(
                  tooltip: '삭제',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await AccountService().removePlace(p.id);
                    ref.invalidate(placesProvider);
                  })),
        ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: const Text('장소 등록'),
            subtitle: const Text('장소명 · 유형 · 도로명 주소 · 알림 설정'),
            onTap: () => showModalBottomSheet<void>(
                context: c,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => const _PlaceForm())),
      ])),
      const OptionalDetailsCard()
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
  Widget build(BuildContext context) => Card(
        child: SwitchListTile(
          value: enabled,
          onChanged: loading || !AppConfig.isRemote ? null : _toggle,
          title: const Text('재난 푸시 알림'),
          subtitle: Text(!AppConfig.isRemote
              ? '실제 FCM은 원격 모드 Android/iOS에서 설정할 수 있습니다.'
              : enabled
                  ? 'FCM 토큰을 등록했습니다. 앱을 열면 경고도 주기적으로 확인합니다.'
                  : '켜면 기기 토큰을 등록합니다. 권한이 없어도 경고 폴링은 계속됩니다.'),
          secondary: loading
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.notifications_active_outlined),
        ),
      );
}

class _PlaceForm extends ConsumerStatefulWidget {
  const _PlaceForm();
  @override
  ConsumerState<_PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends ConsumerState<_PlaceForm> {
  String type = '집';
  bool alert = true;
  bool resolving = false;
  final name = TextEditingController();
  final address = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (resolving || address.text.trim().isEmpty) return;
    setState(() => resolving = true);
    try {
      final resolved = await GeocodingService().resolve(address.text);
      final label = name.text.trim().isEmpty ? type : name.text.trim();
      await AccountService().addPlace(SavedPlace(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: label,
        type: type,
        address: resolved.address,
        position: resolved.position,
        alert: alert,
      ));
      ref.invalidate(placesProvider);
      if (mounted) Navigator.pop(context);
    } on GeocodingException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext c) => SafeArea(
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, 24 + MediaQuery.viewInsetsOf(c).bottom),
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                const Text('장소 등록',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
                const SizedBox(height: 12),
                TextField(
                    controller: name,
                    decoration: const InputDecoration(
                        labelText: '장소명 (비우면 유형 이름)',
                        border: OutlineInputBorder())),
                const SizedBox(height: 9),
                DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(
                        labelText: '유형', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: '집', child: Text('집')),
                      DropdownMenuItem(value: '직장', child: Text('직장')),
                      DropdownMenuItem(value: '기타', child: Text('기타'))
                    ],
                    onChanged: (v) => setState(() => type = v!)),
                const SizedBox(height: 9),
                TextField(
                    controller: address,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: '도로명 주소',
                        hintText: '예: 경북 포항시 남구 구룡포읍 호미로 152',
                        border: OutlineInputBorder())),
                const SizedBox(height: 6),
                const Text('주소를 저장하면 서버가 카카오 주소 검색으로 좌표를 확인합니다.',
                    style: TextStyle(fontSize: 12)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: alert,
                    title: const Text('알림 수신'),
                    onChanged: (v) => setState(() => alert = v)),
                FilledButton.icon(
                    onPressed:
                        resolving || address.text.trim().isEmpty ? null : save,
                    icon: resolving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add_location_alt_outlined),
                    label: Text(resolving ? '주소 확인 중…' : '주소 확인 후 등록')),
              ]))));
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
    '보호가 필요한 동반자 여부',
    '보행 능력',
    '시각 지원',
    '청각 지원',
    '혈액형',
    '직업',
    '비상 연락처'
  ];
  static const choices = <String, List<String>>{
    '보호가 필요한 동반자 여부': ['예', '아니요'],
    '보행 능력': ['보행 가능', '보행 불편', '보행 어려움'],
    '시각 지원': ['필요 없음', '저시력', '전맹', '지원 필요'],
    '청각 지원': ['필요 없음', '난청', '농·난청', '지원 필요'],
    '혈액형': ['A+', 'A-', 'B+', 'B-', 'O+', 'O-', 'AB+', 'AB-', '모름'],
    '직업': ['어업 종사자·뱃사람', '자영업자', '농업 종사자', '직장인', '학생', '기타'],
  };
  static const legacyFieldLabels = <String, String>{
    '자주 가는 장소': '자주 방문하는 장소',
    '보호 동반자': '보호가 필요한 동반자 여부',
    '보행능력': '보행 능력',
    '시각': '시각 지원',
    '청각': '청각 지원',
    '비상연락처': '비상 연락처',
    'frequent_place': '자주 방문하는 장소',
    'frequent_places': '자주 방문하는 장소',
    'frequentplace': '자주 방문하는 장소',
    'frequentplaces': '자주 방문하는 장소',
    'has_dependents': '보호가 필요한 동반자 여부',
    'hasdependents': '보호가 필요한 동반자 여부',
    'dependents': '보호가 필요한 동반자 여부',
    'protected_companion': '보호가 필요한 동반자 여부',
    'has_protected_companion': '보호가 필요한 동반자 여부',
    'needs_companion': '보호가 필요한 동반자 여부',
    'walking_ability': '보행 능력',
    'walkingability': '보행 능력',
    'walking_impaired': '보행 능력',
    'walkingimpaired': '보행 능력',
    'mobility_limited': '보행 능력',
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
        '보호가 필요한 동반자 여부' => '예',
        '보행 능력' => '보행 불편',
        '시각 지원' || '청각 지원' => '지원 필요',
        _ => '예',
      };
    }
    if (const {'false', 'no', '0'}.contains(normalized)) {
      return switch (label) {
        '보호가 필요한 동반자 여부' => '아니요',
        '보행 능력' => '보행 가능',
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
          'limited': '보행 불편',
          'mobility_limited': '보행 불편',
          'unable': '보행 어려움',
          'normal': '보행 가능',
          'able': '보행 가능',
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

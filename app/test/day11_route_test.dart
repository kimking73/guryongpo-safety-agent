import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const origin = LatLng(35.9918, 129.5507);
  final shelter = MockSafetyRepository.facilities.first;

  test(
      'mock route applies the saved elderly profile to safest and nearest routes',
      () async {
    SharedPreferences.setMockInitialValues({
      'profile_age': '70',
      'profile_transport': '도보',
    });

    final repository = MockSafetyRepository();
    final safest = await repository.routeFor(
      shelter,
      UserMode.user,
      RouteType.safest,
      origin,
    );
    final nearest = await repository.routeFor(
      shelter,
      UserMode.user,
      RouteType.nearest,
      origin,
    );
    final aiRoute = await repository.ask('가까운 대피소 경로', UserMode.user, origin);

    expect(safest.profile, 'elderly');
    expect(nearest.profile, 'elderly');
    expect(aiRoute.route?.profile, 'elderly');
    expect(safest.maxSlopePercent, greaterThan(0));
    expect(nearest.maxSlopePercent, greaterThan(0));
  });

  test(
      'mock route uses wheelchair and walking difficulty for automatic profile',
      () async {
    SharedPreferences.setMockInitialValues({
      'profile_age': '30',
      'profile_transport': '휠체어',
    });
    final wheelchair = await MockSafetyRepository().routeFor(
      shelter,
      UserMode.user,
      RouteType.nearest,
      origin,
    );
    expect(wheelchair.profile, 'elderly');

    SharedPreferences.setMockInitialValues({
      'profile_age': '30',
      'profile_transport': '도보',
      'optional_profile': '{"보행 능력":"지팡이 사용"}',
    });
    final walkingSupport = await MockSafetyRepository().routeFor(
      shelter,
      UserMode.user,
      RouteType.nearest,
      origin,
    );
    expect(walkingSupport.profile, 'elderly');
  });
}

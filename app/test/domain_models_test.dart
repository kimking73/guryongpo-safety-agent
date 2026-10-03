import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';

void main() {
  test('every example facility has map route data for every user and type', () {
    final repository = MockSafetyRepository();
    for (final facility in MockSafetyRepository.facilities) {
      for (final userMode in UserMode.values) {
        for (final routeType in RouteType.values) {
          final route = repository.exampleRoute(facility.id, userMode, routeType);
          expect(route.shelterId, facility.id);
          expect(route.routeType, routeType);
          expect(route.polylinePoints.length, greaterThanOrEqualTo(3));
          expect(route.distanceMeters, greaterThan(0));
          expect(route.estimatedMinutes, greaterThan(0));
        }
      }
    }
  });
}

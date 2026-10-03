import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'auth_service.dart';

class GeocodedAddress {
  const GeocodedAddress(this.address, this.position);
  final String address;
  final LatLng position;
}

/// Resolves addresses through the API server so Kakao credentials never enter the app.
class GeocodingService {
  GeocodingService({Dio? api}) : _api = api ?? ApiClient(AuthService()).api;
  final Dio _api;

  Future<GeocodedAddress> resolve(String address) async {
    try {
      final response = await _api.post<Map<String, dynamic>>(
        '/api/v1/user/geocode',
        data: {'address': address.trim()},
      );
      final body = response.data!;
      final location = body['location'] as Map<String, dynamic>;
      return GeocodedAddress(
        body['address'] as String,
        LatLng(
          (location['lat'] as num).toDouble(),
          (location['lng'] as num).toDouble(),
        ),
      );
    } on DioException catch (e) {
      final data = e.response?.data;
      final message = data is Map<String, dynamic> ? data['message'] as String? : null;
      throw GeocodingException(message ?? '주소를 변환하지 못했습니다. 주소와 서버 연결을 확인해 주세요.');
    } on GeocodingException {
      rethrow;
    } catch (_) {
      throw GeocodingException('주소 결과를 읽지 못했습니다. 도로명 주소를 확인해 주세요.');
    }
  }
}

class GeocodingException implements Exception {
  const GeocodingException(this.message);
  final String message;
  @override
  String toString() => message;
}

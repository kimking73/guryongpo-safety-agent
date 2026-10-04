import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PendingEvacuationResponse {
  const PendingEvacuationResponse({
    required this.alertId,
    required this.status,
    required this.location,
  });

  final String alertId;
  final String status;
  final LatLng location;

  Map<String, Object> toJson() => {
        'alert_id': alertId,
        'status': status,
        'lat': location.latitude,
        'lng': location.longitude,
      };

  factory PendingEvacuationResponse.fromJson(Map<String, dynamic> json) =>
      PendingEvacuationResponse(
        alertId: json['alert_id'] as String,
        status: json['status'] as String,
        location: LatLng(
          (json['lat'] as num).toDouble(),
          (json['lng'] as num).toDouble(),
        ),
      );
}

class EvacuationResponseQueue {
  static const _storageKey = 'pending_evacuation_responses_v1';

  Future<List<PendingEvacuationResponse>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .map((item) => PendingEvacuationResponse.fromJson(
              item as Map<String, dynamic>))
          .toList();
    } on FormatException {
      await prefs.remove(_storageKey);
      return const [];
    } on TypeError {
      await prefs.remove(_storageKey);
      return const [];
    }
  }

  Future<void> enqueue(PendingEvacuationResponse response) async {
    final responses = await read();
    final updated = [
      ...responses.where((item) => item.alertId != response.alertId),
      response,
    ];
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _storageKey,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
    if (!saved) throw StateError('응답 대기열을 저장하지 못했습니다.');
  }

  Future<void> remove(String alertId) async {
    final responses = await read();
    final updated = responses.where((item) => item.alertId != alertId).toList();
    final prefs = await SharedPreferences.getInstance();
    if (updated.isEmpty) {
      await prefs.remove(_storageKey);
    } else {
      await prefs.setString(
          _storageKey, jsonEncode(updated.map((item) => item.toJson()).toList()));
    }
  }
}

bool isTransientNetworkFailure(Object error) =>
    error is DioException &&
    (error.response == null ||
        const {
          DioExceptionType.connectionError,
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout,
        }.contains(error.type));

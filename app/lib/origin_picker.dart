import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart';
import 'services/account_service.dart';
import 'services/geocoding_service.dart';
import 'services/location_service.dart';

/// 출발 위치 직접 지정 (2026-10-05). 고른 위치가 앱의 '현재 위치'가 되어 위험도·경로·AI 답변이 모두 그 위치 기준이 된다.
/// 고르는 법: 현재 위치(GPS) · 집 · 직장 · 저장 장소 · 지도에서 고르기 · 주소로 찾기.
/// 선택은 프로필(optional_profile)의 originMode·originName·originAddress·originLat·originLon에 저장 → 다음 실행·다른 기기(로그인)에서도 유지.

/// 직접 고른 출발 위치 이름. null = GPS(또는 구룡포 기본 위치)
final originLabelProvider = StateProvider<String?>((_) => null);

const _direct = '직접 지정';

/// 앱 시작 때: 프로필에 '직접 지정' 출발 위치가 있으면 그 위치로 시작
Future<void> restoreSavedOrigin(WidgetRef ref) async {
  final o = await AccountService().optionalProfile();
  if (o['originMode'] != _direct) return;
  final lat = double.tryParse(o['originLat'] ?? ''), lng = double.tryParse(o['originLon'] ?? '');
  if (lat == null || lng == null || !inServiceArea(LatLng(lat, lng))) return;
  setPosition(ref, LatLng(lat, lng), manual: true);
  ref.read(originLabelProvider.notifier).state = (o['originName'] ?? '').isEmpty ? '지정한 출발 위치' : o['originName'];
}

Future<void> _choose(WidgetRef ref, LatLng p, String label, {String address = ''}) async {
  setPosition(ref, p, manual: true);
  ref.read(originLabelProvider.notifier).state = label;
  final account = AccountService();
  final o = await account.optionalProfile();
  o.addAll({
    'originMode': _direct,
    'originName': label,
    'originAddress': address,
    'originLat': '${p.latitude}',
    'originLon': '${p.longitude}',
  });
  await account.saveOptionalProfile(o);
}

Future<String?> _useGps(WidgetRef ref) async {
  ref.read(gpsPosition.notifier).state = null; // GPS 추적이 다시 채운다
  ref.read(originLabelProvider.notifier).state = null;
  final account = AccountService();
  final o = await account.optionalProfile();
  o['originMode'] = '현재 위치';
  await account.saveOptionalProfile(o);
  try {
    final p = await ref.read(locationService).current();
    if (!inServiceArea(p)) return '현재 위치가 구룡포 서비스 지역 밖이라 구룡포 기본 위치를 씁니다.';
    setPosition(ref, p);
    return null;
  } on LocationUnavailable catch (e) {
    return '${e.message} 구룡포 기본 위치를 씁니다.';
  } catch (_) {
    return '위치를 읽지 못해 구룡포 기본 위치를 씁니다.';
  }
}

/// 지금 출발 위치를 보여 주고, 누르면 바꾸는 칩
class OriginChip extends ConsumerWidget {
  const OriginChip({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final here = ref.watch(userLocation);
    final label = ref.watch(originLabelProvider);
    final text = here.manual
        ? (label ?? '지도에서 고른 위치')
        : here.fromGps
            ? '현재 위치 (GPS)'
            : '구룡포 기본 위치';
    return ActionChip(
      avatar: Icon(here.manual ? Icons.push_pin_outlined : Icons.my_location, size: 18),
      label: Text('출발: $text'),
      tooltip: '출발 위치 바꾸기',
      onPressed: () => showOriginPicker(c, ref),
    );
  }
}

Future<void> showOriginPicker(BuildContext c, WidgetRef ref) async {
  final o = await AccountService().optionalProfile();
  final places = await AccountService().places();
  if (!c.mounted) return;
  LatLng? at(String k) {
    final lat = double.tryParse(o['${k}Lat'] ?? ''), lng = double.tryParse(o['${k}Lon'] ?? '');
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  final home = at('home'), work = at('work');
  void done(String? msg) {
    if (msg != null && c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> pick(LatLng p, String label, {String address = ''}) async {
    if (!inServiceArea(p)) {
      done('구룡포 서비스 지역(경로 안내 범위) 밖이라 출발 위치로 쓸 수 없습니다.');
      return;
    }
    await _choose(ref, p, label, address: address);
    done('출발 위치: $label');
  }

  await showModalBottomSheet<void>(
    context: c,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
        const ListTile(title: Text('출발 위치', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            subtitle: Text('고른 위치를 기준으로 위험도·대피 경로·AI 안내를 보여 줍니다.')),
        ListTile(
            leading: const Icon(Icons.my_location),
            title: const Text('현재 위치 (GPS)'),
            onTap: () async {
              Navigator.pop(sheet);
              done(await _useGps(ref) ?? '현재 위치(GPS)를 씁니다.');
            }),
        if (home != null)
          ListTile(
              leading: const Icon(Icons.home_outlined),
              title: Text((o['homeName'] ?? '').isEmpty ? '집' : o['homeName']!),
              subtitle: Text(o['homeAddress'] ?? ''),
              onTap: () {
                Navigator.pop(sheet);
                pick(home, (o['homeName'] ?? '').isEmpty ? '집' : o['homeName']!, address: o['homeAddress'] ?? '');
              }),
        if (work != null)
          ListTile(
              leading: const Icon(Icons.business_outlined),
              title: Text((o['workName'] ?? '').isEmpty ? '직장' : o['workName']!),
              subtitle: Text(o['workAddress'] ?? ''),
              onTap: () {
                Navigator.pop(sheet);
                pick(work, (o['workName'] ?? '').isEmpty ? '직장' : o['workName']!, address: o['workAddress'] ?? '');
              }),
        for (final p in places)
          ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(p.name),
              subtitle: Text(p.address),
              onTap: () {
                Navigator.pop(sheet);
                pick(p.position, p.name, address: p.address);
              }),
        ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('지도에서 고르기'),
            onTap: () async {
              Navigator.pop(sheet);
              final p = await showDialog<LatLng>(context: c, builder: (_) => _MapPickDialog(start: ref.read(userLocation).position));
              if (p != null) await pick(p, '지도에서 고른 위치');
            }),
        ListTile(
            leading: const Icon(Icons.search),
            title: const Text('주소로 찾기'),
            subtitle: const Text('도로명 주소 (예: 구룡포읍 호미로 152)'),
            onTap: () async {
              Navigator.pop(sheet);
              final r = await showDialog<GeocodedAddress>(context: c, builder: (_) => const _AddressDialog());
              if (r != null) await pick(r.position, r.address, address: r.address);
            }),
      ]),
    ),
  );
}

class _MapPickDialog extends StatefulWidget {
  const _MapPickDialog({required this.start});
  final LatLng start;
  @override
  State<_MapPickDialog> createState() => _MapPickDialogState();
}

class _MapPickDialogState extends State<_MapPickDialog> {
  LatLng? picked;
  @override
  Widget build(BuildContext c) => Dialog.fullscreen(
      child: Scaffold(
          appBar: AppBar(title: const Text('지도를 눌러 출발 위치 고르기'), actions: [
            TextButton(onPressed: picked == null ? null : () => Navigator.pop(c, picked), child: const Text('이 위치로')),
          ]),
          body: FlutterMap(
              options: MapOptions(
                  initialCenter: widget.start,
                  initialZoom: 15,
                  minZoom: 11,
                  cameraConstraint: CameraConstraint.containCenter(
                      bounds: LatLngBounds(const LatLng(serviceSouth, serviceWest), const LatLng(serviceNorth, serviceEast))),
                  onTap: (_, p) => setState(() => picked = p)),
              children: [
                TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'kr.guryong.guardian'),
                MarkerLayer(markers: [
                  if (picked != null)
                    Marker(point: picked!, width: 44, height: 44, alignment: Alignment.topCenter,
                        child: const Icon(Icons.location_on, color: Colors.red, size: 44)),
                ]),
              ])));
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();
  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final address = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await GeocodingService().resolve(address.text);
      if (mounted) Navigator.pop(context, r);
    } on GeocodingException catch (e) {
      setState(() => error = e.message);
    } catch (_) {
      setState(() => error = '주소를 찾지 못했습니다. 도로명 주소를 확인해 주세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
        title: const Text('주소로 출발 위치 찾기'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: address,
              autofocus: true,
              onSubmitted: (_) => busy ? null : _find(),
              decoration: const InputDecoration(labelText: '도로명 주소', hintText: '구룡포읍 호미로 152')),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: busy ? null : _find, child: Text(busy ? '찾는 중…' : '찾기')),
        ],
      );
}

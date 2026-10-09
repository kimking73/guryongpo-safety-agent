import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../origin_picker.dart';
import '../services/demo_mode.dart';
import '../ui/tokens.dart';

/// 도움 필요(SOS) 화면 — 대피 확인에서 '도움 필요'를 고르거나 10분 동안 응답이 없을 때.
/// 응답(위치 포함)은 이미 방재단에 보냈고, 위급하면 119로 바로 전화한다
class SosScreen extends ConsumerStatefulWidget {
  const SosScreen({super.key});
  @override
  ConsumerState<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends ConsumerState<SosScreen> {
  bool _ack = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    // 시연에서만 '방재단이 확인했어요'로 바뀐다. 실측은 확인 신호가 없어 그대로 둔다
    if (ref.read(showDemoProvider)) {
      _t = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _ack = true);
      });
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final here = ref.watch(userLocation);
    final place = here.manual
        ? (ref.watch(originLabelProvider) ?? '지도에서 고른 위치')
        : here.fromGps
            ? 'GPS 현재 위치'
            : '구룡포 기본 위치';
    final white = dsText(18, color: Colors.white, height: 1.55);
    return Scaffold(
      backgroundColor: Ds.danger,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 36),
          child: Column(children: [
            Container(
              width: 120,
              height: 120,
              decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Color(0x2EFFFFFF), spreadRadius: 18)]),
              alignment: Alignment.center,
              child: Text('SOS',
                  style: dsText(40, weight: FontWeight.w900, color: Ds.danger)),
            ),
            const SizedBox(height: 40),
            Text(_ack ? '방재단이 확인했어요' : '방재단에 연락하고 있어요',
                textAlign: TextAlign.center,
                style: dsText(30,
                    weight: FontWeight.w800, color: Colors.white, height: 1.3)),
            const SizedBox(height: 10),
            Text(
                _ack
                    ? '곧 연락드릴게요. 안전한 곳에서 기다려 주세요.'
                    : '현재 위치를 함께 보냈어요. 위급하면 119에 바로 전화하세요.',
                textAlign: TextAlign.center,
                style: white),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(20)),
              child: Row(children: [
                const FaIcon(FontAwesomeIcons.locationCrosshairs,
                    size: 20, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('현재 위치',
                            style: dsText(14,
                                color: Colors.white.withValues(alpha: .9))),
                        Text(place,
                            style: dsText(18,
                                weight: FontWeight.w800, color: Colors.white)),
                      ]),
                ),
              ]),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 64,
              child: Material(
                color: Colors.white,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => launchUrl(Uri(scheme: 'tel', path: '119')),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const FaIcon(FontAwesomeIcons.phone,
                            size: 20, color: Ds.danger),
                        const SizedBox(width: 10),
                        Text('119 바로 전화하기',
                            style: dsText(21,
                                weight: FontWeight.w800, color: Ds.danger)),
                      ]),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white, width: 2)),
                onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                child: Text('처음 화면으로',
                    style: dsText(18, weight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

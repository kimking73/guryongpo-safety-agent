import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'services/demo_speech.dart';
import 'services/prototype_safety_store.dart';

const prototypeEvacuationAlertId = 'demo-flood-evacuation';
const evacuationFlashTransitionInterval = Duration(milliseconds: 500);
const evacuationFlashDuration = Duration(seconds: 30);
const evacuationHapticPulseLimit = 8;
const _evacuationFlashTransitionLimit = 60;

const _evacuationVoicePrompt =
    '대피 확인 경보입니다. 현재 상태를 말하거나 화면에서 선택해 주세요. 대피 완료, 대피 중, 도움 필요.';
const _evacuationVoiceResponsePrompt =
    '현재 안전 상태를 말해 주세요. 대피소에 도착했어요, 지금 이동하고 있어요, 혼자 이동하기 어려워요 중 하나를 선택해 시연할 수 있습니다.';

bool shouldAutoPlayAccessibilityPrompt(
  AccessibilitySettings settings, {
  required bool accessibleNavigation,
}) =>
    settings.visionSupport && settings.voicePrompts && !accessibleNavigation;

class PrototypeFeatureLinks extends ConsumerWidget {
  const PrototypeFeatureLinks({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(prototypeSafetyProvider);
    final role = controller.demoRole;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('3주차 안전 기능 시연', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('대피 확인·접근성·방재단 흐름을 확인합니다.'),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: () => context.push('/evacuation'),
                icon: const Icon(Icons.campaign_outlined),
                label: const Text('대피 확인'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/accessibility'),
                icon: const Icon(Icons.accessibility_new),
                label: const Text('접근성 설정'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/household'),
                icon: const Icon(Icons.home_work_outlined),
                label: const Text('내 가구 등록'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/sea-route'),
                icon: const Icon(Icons.sailing_outlined),
                label: const Text('해상 경로'),
              ),
              // 시연 모드의 방재단 대시보드는 시연 가구 12곳으로 바로 열린다 (역할 받기 없이)
              FilledButton.icon(
                onPressed: () => context.push('/responder'),
                icon: const Icon(Icons.groups_outlined),
                label: Text(controller.hasResponderAccess ? '방재단 대시보드 · $role' : '방재단 대시보드 (시연)'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class EvacuationDemoScreen extends ConsumerStatefulWidget {
  const EvacuationDemoScreen({super.key, this.onResponse});

  final Future<void> Function(EvacuationResponseStatus status)? onResponse;

  @override
  ConsumerState<EvacuationDemoScreen> createState() =>
      _EvacuationDemoScreenState();
}

class _EvacuationDemoScreenState extends ConsumerState<EvacuationDemoScreen> {
  Timer? _flashTimer;
  Timer? _hapticTimer;
  bool _flashOn = false;
  int _flashTransitions = 0;
  int _hapticPulses = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = ref.read(prototypeSafetyProvider).accessibility;
      _startAlertEffects(settings);
      if (shouldAutoPlayAccessibilityPrompt(
        settings,
        accessibleNavigation: MediaQuery.accessibleNavigationOf(context),
      )) {
        unawaited(DemoSpeech.instance.speak(_evacuationVoicePrompt));
      }
    });
  }

  void _startAlertEffects(AccessibilitySettings settings) {
    _flashTimer?.cancel();
    _hapticTimer?.cancel();
    _flashOn = false;
    _flashTransitions = 0;
    _hapticPulses = 0;

    if (settings.hearingSupport && settings.screenFlash) {
      _flashTimer = Timer.periodic(evacuationFlashTransitionInterval, (timer) {
        if (!mounted || _flashTransitions >= _evacuationFlashTransitionLimit) {
          timer.cancel();
          if (mounted) setState(() => _flashOn = false);
          return;
        }
        _flashTransitions++;
        setState(() => _flashOn = _flashTransitions.isOdd);
        if (_flashTransitions >= _evacuationFlashTransitionLimit) {
          timer.cancel();
        }
      });
    }

    if (settings.hearingSupport && settings.strongVibration) {
      _hapticTimer = Timer.periodic(evacuationFlashTransitionInterval, (timer) {
        if (!mounted || _hapticPulses >= evacuationHapticPulseLimit) {
          timer.cancel();
          return;
        }
        _hapticPulses++;
        unawaited(HapticFeedback.vibrate().catchError((Object _) {}));
        if (_hapticPulses >= evacuationHapticPulseLimit) timer.cancel();
      });
    }
  }

  Future<void> _replayPrompt() =>
      DemoSpeech.instance.speak(_evacuationVoicePrompt);

  @override
  void dispose() {
    _flashTimer?.cancel();
    _hapticTimer?.cancel();
    unawaited(DemoSpeech.instance.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prototypeSafetyProvider).accessibility;
    final accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    final background = _flashOn ? const Color(0xffffe082) : null;
    return AnimatedContainer(
      key: const ValueKey('evacuation-demo-background'),
      duration: const Duration(milliseconds: 100),
      decoration: BoxDecoration(color: background),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('대피 확인 시연', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text('테스트 경보입니다. 실제 재난 알림이 아닙니다.'),
          const SizedBox(height: 12),
          EvacuationResponseCard(
            alertId: prototypeEvacuationAlertId,
            title: '구룡포 저지대 침수 대피 확인',
            detail: '안전한 실내 또는 지정 대피소로 이동해 주세요.',
            onVoice: () => context.push('/evacuation-voice'),
            onReplayVoice: prefs.visionSupport ? _replayPrompt : null,
            accessibleNavigation: accessibleNavigation,
            onResponse: widget.onResponse ??
                (status) => ref
                    .read(prototypeSafetyProvider)
                    .respond(prototypeEvacuationAlertId, status),
          ),
          if (prefs.hearingSupport) ...[
            const SizedBox(height: 8),
            const ListTile(
              leading: Icon(Icons.vibration),
              title: Text('청각 지원 경보'),
              subtitle: Text(
                  '앱이 열린 동안 기본 진동과 초당 1회 주기의 화면 점멸을 최대 30초간 시연합니다. 진동 세기는 기기에 따라 다릅니다.'),
            ),
          ],
        ],
      ),
    );
  }
}

class EvacuationResponseCard extends ConsumerStatefulWidget {
  const EvacuationResponseCard({
    super.key,
    required this.alertId,
    required this.title,
    required this.detail,
    required this.onResponse,
    this.onVoice,
    this.onReplayVoice,
    this.accessibleNavigation = false,
  });

  final String alertId;
  final String title;
  final String detail;
  final Future<void> Function(EvacuationResponseStatus) onResponse;
  final VoidCallback? onVoice;
  final VoidCallback? onReplayVoice;
  final bool accessibleNavigation;

  @override
  ConsumerState<EvacuationResponseCard> createState() =>
      _EvacuationResponseCardState();
}

class _EvacuationResponseCardState
    extends ConsumerState<EvacuationResponseCard> {
  bool _submitting = false;

  Future<void> _respond(EvacuationResponseStatus status) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onResponse(status);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(prototypeSafetyProvider);
    final settings = controller.accessibility;
    final response = controller.responseFor(widget.alertId);
    final theme = Theme.of(context);
    final scaledTheme = theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontSizeFactor: settings.largeText ? 1.3 : 1.0,
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '대피 확인 경보. ${widget.title}. ${widget.detail}',
      child: Theme(
        data: scaledTheme,
        child: Card(
          color: theme.colorScheme.errorContainer.withValues(alpha: .5),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const ExcludeSemantics(
                      child: Icon(Icons.warning_amber_rounded, size: 30)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('대피 확인 필요',
                          style: scaledTheme.textTheme.titleLarge),
                    ),
                  ),
                ]),
                if (response != null) ...[
                  const SizedBox(height: 6),
                  Semantics(
                    container: true,
                    liveRegion: true,
                    label: '응답 상태: ${response.label}',
                    child: ExcludeSemantics(
                      child: Chip(
                        avatar:
                            const Icon(Icons.check_circle_outline, size: 18),
                        label: Text('응답: ${response.label}'),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(widget.title,
                    style: scaledTheme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    )),
                Text(widget.detail),
                if (settings.visionSupport) ...[
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const ExcludeSemantics(
                        child: Icon(Icons.volume_up_outlined)),
                    title: Text(widget.accessibleNavigation
                        ? '화면낭독기가 경고 내용을 안내합니다'
                        : settings.voicePrompts
                            ? '경보 안내 음성이 자동 재생됩니다'
                            : '음성 안내 자동 재생 꺼짐'),
                  ),
                  if (widget.onReplayVoice != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: widget.onReplayVoice,
                        icon: const Icon(Icons.volume_up_outlined),
                        label: const Text('경보 안내 다시 듣기'),
                      ),
                    ),
                ],
                if (settings.visionSupport && widget.onVoice != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: widget.onVoice,
                    icon: const Icon(Icons.mic_none_outlined),
                    label: const Text('음성 응답 시연'),
                  ),
                  const Text('실제 마이크 입력 없이 문구를 선택하는 시연입니다.'),
                ],
                const SizedBox(height: 12),
                for (final status in EvacuationResponseStatus.values) ...[
                  Semantics(
                    button: true,
                    label:
                        '${status.label} 응답 보내기${response == status ? ', 선택됨' : ''}',
                    child: FilledButton.icon(
                      onPressed: _submitting ? null : () => _respond(status),
                      icon: Icon(switch (status) {
                        EvacuationResponseStatus.evacuated =>
                          Icons.check_circle,
                        EvacuationResponseStatus.evacuating =>
                          Icons.directions_run,
                        EvacuationResponseStatus.needHelp => Icons.sos,
                      }),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(status.label,
                              style: scaledTheme.textTheme.labelLarge),
                          if (response == status) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.check, size: 20),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (status != EvacuationResponseStatus.needHelp)
                    const SizedBox(height: 7),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AccessibilitySettingsScreen extends ConsumerWidget {
  const AccessibilitySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(prototypeSafetyProvider);
    final settings = controller.accessibility;
    Future<void> update(AccessibilitySettings next) =>
        controller.updateAccessibility(next);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('접근성 경보 설정', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        const Text('청각·시각 지원을 선택하면 테스트 경보에 반영됩니다.'),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            SwitchListTile(
              secondary: const Icon(Icons.hearing),
              title: const Text('청각 지원 경보'),
              subtitle: const Text('켜면 반복 진동, 화면 점멸, 큰 글씨가 함께 켜집니다.'),
              value: settings.hearingSupport,
              onChanged: (value) => update(value
                  ? settings.copyWith(
                      hearingSupport: true,
                      strongVibration: true,
                      screenFlash: true,
                      largeText: true,
                    )
                  : settings.copyWith(hearingSupport: false)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.visibility_off_outlined),
              title: const Text('시각 지원 음성 안내'),
              subtitle: const Text('켜면 음성 질문 자동 재생도 함께 켜집니다.'),
              value: settings.visionSupport,
              onChanged: (value) => update(value
                  ? settings.copyWith(visionSupport: true, voicePrompts: true)
                  : settings.copyWith(visionSupport: false)),
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('반복 진동 알림'),
              subtitle:
                  const Text('운영체제 기본 진동을 반복합니다. 진동 세기와 패턴은 기기에 따라 다릅니다.'),
              value: settings.strongVibration,
              onChanged: (value) =>
                  update(settings.copyWith(strongVibration: value)),
            ),
            SwitchListTile(
              title: const Text('화면 점멸'),
              subtitle: const Text('초당 1회 주기, 최대 30초 · 광과민성이 있으면 꺼 두세요'),
              value: settings.screenFlash,
              onChanged: (value) =>
                  update(settings.copyWith(screenFlash: value)),
            ),
            SwitchListTile(
              title: const Text('큰 글씨'),
              value: settings.largeText,
              onChanged: (value) => update(settings.copyWith(largeText: value)),
            ),
            SwitchListTile(
              title: const Text('음성 질문 자동 재생'),
              value: settings.voicePrompts,
              onChanged: (value) =>
                  update(settings.copyWith(voicePrompts: value)),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => context.push('/evacuation'),
          icon: const Icon(Icons.campaign_outlined),
          label: const Text('테스트 경보 열기'),
        ),
        const SizedBox(height: 8),
        const Text(
          '설정은 이 기기에 저장됩니다. 시연 설정은 서버로 전송되지 않습니다.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          '백그라운드 알림의 진동과 소리는 iOS·Android 시스템 알림 설정을 따릅니다.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class EvacuationVoiceDemoScreen extends ConsumerStatefulWidget {
  const EvacuationVoiceDemoScreen({super.key});

  @override
  ConsumerState<EvacuationVoiceDemoScreen> createState() =>
      _EvacuationVoiceDemoScreenState();
}

class _EvacuationVoiceDemoScreenState
    extends ConsumerState<EvacuationVoiceDemoScreen> {
  String? selectedPhrase;

  static const phrases = <(String, EvacuationResponseStatus)>[
    ('대피소에 도착했어요', EvacuationResponseStatus.evacuated),
    ('지금 이동하고 있어요', EvacuationResponseStatus.evacuating),
    ('혼자 이동하기 어려워요', EvacuationResponseStatus.needHelp),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = ref.read(prototypeSafetyProvider).accessibility;
      if (shouldAutoPlayAccessibilityPrompt(
        settings,
        accessibleNavigation: MediaQuery.accessibleNavigationOf(context),
      )) {
        unawaited(DemoSpeech.instance.speak(_evacuationVoiceResponsePrompt));
      }
    });
  }

  @override
  void dispose() {
    DemoSpeech.instance.stop();
    super.dispose();
  }

  Future<void> _select(String phrase, EvacuationResponseStatus status) async {
    setState(() => selectedPhrase = phrase);
    await ref
        .read(prototypeSafetyProvider)
        .respond(prototypeEvacuationAlertId, status);
    if (!mounted) return;
    final settings = ref.read(prototypeSafetyProvider).accessibility;
    if (shouldAutoPlayAccessibilityPrompt(
      settings,
      accessibleNavigation: MediaQuery.accessibleNavigationOf(context),
    )) {
      await DemoSpeech.instance.speak('응답했습니다. ${status.label}.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(prototypeSafetyProvider).accessibility;
    final accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    final promptText = accessibleNavigation
        ? '화면낭독기가 이 화면의 안내를 읽습니다. 자동 음성 재생은 중복을 막기 위해 꺼져 있습니다.'
        : !settings.visionSupport
            ? '접근성 설정에서 시각 지원을 켜면 음성 안내를 사용할 수 있습니다.'
            : settings.voicePrompts
                ? '음성 안내가 자동 재생됩니다. 아래 문구는 음성 응답 시연용 선택지입니다.'
                : '자동 음성 재생이 꺼져 있습니다. 아래 문구는 음성 응답 시연용 선택지입니다.';
    final theme = Theme.of(context);
    final scaledTheme = theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontSizeFactor: settings.largeText ? 1.3 : 1.0,
      ),
    );
    return Theme(
      data: scaledTheme,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Semantics(
            liveRegion: true,
            header: true,
            child: Text('음성 대피 확인', style: scaledTheme.textTheme.headlineSmall),
          ),
          const SizedBox(height: 8),
          const Text('문구를 선택해 음성 응답을 시연합니다. 실제 마이크 입력이나 음성 인식은 사용하지 않습니다.'),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(children: [
                Semantics(
                  label: '음성 응답 시연 화면',
                  child:
                      ExcludeSemantics(child: Icon(Icons.mic_none, size: 48)),
                ),
                const SizedBox(height: 12),
                Text('현재 안전 상태를 말해 주세요.',
                    textAlign: TextAlign.center,
                    style: scaledTheme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(promptText),
                if (settings.visionSupport)
                  TextButton.icon(
                    onPressed: () => unawaited(DemoSpeech.instance
                        .speak(_evacuationVoiceResponsePrompt)),
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('안내 다시 듣기'),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          for (final (phrase, status) in phrases)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                button: true,
                label: '음성 응답 시연: $phrase',
                child: OutlinedButton.icon(
                  onPressed: () => _select(phrase, status),
                  icon: Icon(selectedPhrase == phrase
                      ? Icons.check_circle
                      : Icons.graphic_eq),
                  label: Text(phrase),
                ),
              ),
            ),
          if (selectedPhrase != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: const Text('응답 기록됨'),
                subtitle: Text(
                    '$selectedPhrase · ${ref.watch(prototypeSafetyProvider).responseFor(prototypeEvacuationAlertId)?.label}'),
              ),
            ),
        ],
      ),
    );
  }
}

const householdNeeds = <(String, String)>[
  ('elderly', '고령'),
  ('living_alone', '독거'),
  ('mobility_limited', '보행 불편'),
  ('wheelchair', '휠체어'),
  ('bedridden', '와상'),
  ('hearing', '청각 지원'),
  ('vision', '시각 지원'),
  ('cognitive', '인지 지원'),
  ('medical_device', '의료기기'),
  ('infant', '영유아'),
  ('pet', '반려동물'),
];

class HouseholdRegistrationScreen extends ConsumerStatefulWidget {
  const HouseholdRegistrationScreen({super.key, this.delegated = false});
  final bool delegated;

  @override
  ConsumerState<HouseholdRegistrationScreen> createState() =>
      _HouseholdRegistrationScreenState();
}

class _HouseholdRegistrationScreenState
    extends ConsumerState<HouseholdRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _address = TextEditingController(text: '구룡포읍 시연로 68');
  final _consentBy = TextEditingController(text: '시연 참여자');
  final _note = TextEditingController();
  final Set<String> _needs = {};
  String _consentMethod = 'verbal';
  int _members = 1;
  bool _consent = false;
  bool _saving = false;

  @override
  void dispose() {
    _label.dispose();
    _address.dispose();
    _consentBy.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_consent) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('민감정보 수집·방재단 제공에 별도 동의해 주세요.')));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(prototypeSafetyProvider).registerHousehold(
            label: _label.text,
            address: _address.text,
            members: _members,
            needs: _needs.toList(),
            consent: _consent,
            consentBy: widget.delegated ? _consentBy.text : '본인',
            consentMethod: widget.delegated ? _consentMethod : 'app',
            note: _note.text,
            delegated: widget.delegated,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('합성 데이터로 가구 등록을 시연했습니다.')));
      context.pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('등록하지 못했습니다: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(prototypeSafetyProvider);
    if (widget.delegated && !controller.hasResponderAccess) {
      return const Center(child: Text('방재단 역할이 있어야 대리 등록할 수 있습니다.'));
    }
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.delegated ? '취약 가구 대리 등록' : '내 가구 등록',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text('시연용 합성 데이터입니다. 입력 내용은 서버로 전송되지 않습니다.'),
          const SizedBox(height: 12),
          TextFormField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: '가구 표시명',
              hintText: '예: 시연 가구 E',
              border: OutlineInputBorder(),
            ),
            validator: (value) => (value == null || value.trim().isEmpty)
                ? '가구 표시명을 입력해 주세요.'
                : null,
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _address,
            decoration: const InputDecoration(
              labelText: '시연용 주소',
              border: OutlineInputBorder(),
            ),
            validator: (value) => (value == null || value.trim().isEmpty)
                ? '시연용 주소를 입력해 주세요.'
                : null,
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            initialValue: _members,
            decoration: const InputDecoration(
                labelText: '가구원 수', border: OutlineInputBorder()),
            items: [
              for (var i = 1; i <= 8; i++)
                DropdownMenuItem(value: i, child: Text('$i명')),
            ],
            onChanged: (value) => setState(() => _members = value ?? 1),
          ),
          const SizedBox(height: 14),
          Text('지원 필요 항목', style: Theme.of(context).textTheme.titleMedium),
          Wrap(
            spacing: 6,
            children: [
              for (final (key, label) in householdNeeds)
                FilterChip(
                  label: Text(label),
                  selected: _needs.contains(key),
                  onSelected: (value) => setState(() {
                    if (value) {
                      _needs.add(key);
                    } else {
                      _needs.remove(key);
                    }
                  }),
                ),
            ],
          ),
          if (widget.delegated) ...[
            const SizedBox(height: 10),
            TextFormField(
              controller: _consentBy,
              decoration: const InputDecoration(
                labelText: '동의한 사람(시연 이름)',
                border: OutlineInputBorder(),
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? '동의한 사람을 입력해 주세요.'
                  : null,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _consentMethod,
              decoration: const InputDecoration(
                  labelText: '동의 방식', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'written', child: Text('서면 동의')),
                DropdownMenuItem(value: 'verbal', child: Text('구두 동의')),
              ],
              onChanged: (value) =>
                  setState(() => _consentMethod = value ?? 'verbal'),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            maxLines: 2,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: '추가 메모(선택)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: CheckboxListTile(
              value: _consent,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('민감정보 수집 및 방재단 제공에 동의합니다.'),
              subtitle: const Text('일반 이용 동의와 별도이며 이 기기에만 저장됩니다.'),
              onChanged: (value) => setState(() => _consent = value ?? false),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? '저장 중…' : '시연 정보 등록'),
          ),
        ],
      ),
    );
  }
}

class DemoRoleClaimCard extends ConsumerStatefulWidget {
  const DemoRoleClaimCard({super.key});

  @override
  ConsumerState<DemoRoleClaimCard> createState() => _DemoRoleClaimCardState();
}

class _DemoRoleClaimCardState extends ConsumerState<DemoRoleClaimCard> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    final success =
        await ref.read(prototypeSafetyProvider).claimDemoRole(_code.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success
          ? '시연 역할을 열었습니다. 대시보드 메뉴에서 방재단 화면을 확인할 수 있습니다.'
          : '올바른 시연 초대 코드가 아닙니다.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(prototypeSafetyProvider).demoRole;
    if (role != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: Text('시연 역할: $role'),
          subtitle: const Text('DEMO-RESPONDER / DEMO-CAREGIVER / DEMO-ADMIN'),
          trailing: TextButton(
            onPressed: () => ref.read(prototypeSafetyProvider).dropDemoRole(),
            child: const Text('해제'),
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('방재단 대시보드 시연 역할'),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: '초대 코드',
              hintText: 'DEMO-RESPONDER',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _claim,
            icon: const Icon(Icons.key_outlined),
            label: const Text('시연 코드 확인'),
          ),
        ]),
      ),
    );
  }
}

class ResponderDashboardScreen extends ConsumerWidget {
  const ResponderDashboardScreen({super.key});

  static const _statusOrder = {
    '도움 필요': 0,
    '미응답': 1,
    '재확인 필요': 1,
    '대피 중': 2,
    '대피 완료': 3,
  };

  Future<void> _recordVisit(
      BuildContext context, WidgetRef ref, DemoHousehold household) async {
    const results = <(String, String)>[
      ('evacuated_with_help', '함께 대피'),
      ('already_evacuated', '이미 대피'),
      ('refused', '대피 거부'),
      ('not_home', '부재'),
      ('transported', '차량 이송'),
      ('other', '기타'),
    ];
    final selected = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
                title: Text('방문 결과 입력'),
                subtitle: Text('합성 대상: 가구 정보는 기기에만 저장됩니다.')),
            for (final result in results)
              ListTile(
                leading: const Icon(Icons.assignment_turned_in_outlined),
                title: Text(result.$2),
                onTap: () => Navigator.pop(sheetContext, result),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    if (!context.mounted) return;
    final note = TextEditingController();
    final noteResult = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(selected.$2),
        content: TextField(
          controller: note,
          maxLength: 300,
          maxLines: 2,
          decoration: const InputDecoration(labelText: '시연 메모(선택)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, note.text),
              child: const Text('기록')),
        ],
      ),
    );
    note.dispose();
    if (noteResult == null) return;
    await ref.read(prototypeSafetyProvider).recordVisit(
          householdId: household.id,
          result: selected.$1,
          note: noteResult,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${selected.$2} 결과를 저장했습니다.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(prototypeSafetyProvider);
    if (!controller.hasResponderAccess) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('이 화면은 방재단 시연 역할에만 표시됩니다.'),
      ));
    }
    final households = [...controller.households]..sort((a, b) {
        final status = (_statusOrder[a.status] ?? 8)
            .compareTo(_statusOrder[b.status] ?? 8);
        return status != 0 ? status : b.needs.length.compareTo(a.needs.length);
      });
    final visitsByHousehold = <String, DemoVisit>{};
    for (final visit in controller.visits) {
      visitsByHousehold.putIfAbsent(visit.householdId, () => visit);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(
            child: Text('방재단 대시보드',
                style: Theme.of(context).textTheme.headlineSmall),
          ),
          IconButton(
            tooltip: '가구 대리 등록',
            onPressed: () => context.push('/household/delegate'),
            icon: const Icon(Icons.person_add_alt_1),
          ),
        ]),
        const Text('우선순위는 도움 필요 → 미응답 → 대피 중 → 대피 완료 순입니다.'),
        const SizedBox(height: 10),
        Card(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 290,
            child: FlutterMap(
              options: const MapOptions(
                  initialCenter: LatLng(35.992, 129.553), initialZoom: 14.2),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                  subdomains: const ['a', 'b', 'c'],
                  userAgentPackageName: 'com.example.guryongpo_safety',
                ),
                MarkerLayer(
                  markers: [
                    for (var i = 0; i < households.length; i++)
                      Marker(
                        point: LatLng(
                            households[i].latitude, households[i].longitude),
                        width: 120,
                        height: 58,
                        child: Tooltip(
                          message:
                              '${i + 1}순위 ${households[i].label} · ${households[i].status}',
                          child: Column(children: [
                            Icon(Icons.location_on,
                                color: households[i].status == '도움 필요'
                                    ? Colors.red
                                    : Colors.deepOrange,
                                size: 34),
                            Container(
                              color: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Text('${i + 1}. ${households[i].label}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ]),
                        ),
                      ),
                  ],
                ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors')
                  ],
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              _SummaryChip(label: '전체 대상', value: '${households.length}'),
              _SummaryChip(
                  label: '도움 필요',
                  value:
                      '${households.where((h) => h.status == '도움 필요').length}'),
              _SummaryChip(
                  label: '미응답',
                  value:
                      '${households.where((h) => h.status == '미응답').length}'),
              _SummaryChip(
                  label: '방문 기록', value: '${controller.visits.length}'),
            ]),
          ),
        ),
        Text('우선 방문 명단', style: Theme.of(context).textTheme.titleLarge),
        for (var i = 0; i < households.length; i++)
          Card(
            child: ExpansionTile(
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text(households[i].label),
              subtitle:
                  Text('${households[i].status} · ${households[i].address}'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 6, children: [
                    for (final need in households[i].needs)
                      Chip(label: Text(householdNeedLabel(need))),
                  ]),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      '가구원 ${households[i].members}명 · 동의 ${households[i].consentMethod == 'app' ? '앱' : households[i].consentMethod == 'written' ? '서면' : '구두'}'),
                ),
                if (visitsByHousehold[households[i].id] case final visit?)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.history),
                    title: Text('최근 방문: ${visit.result}'),
                    subtitle: Text(visit.note.isEmpty
                        ? visit.visitedAt.toLocal().toString()
                        : visit.note),
                  ),
                const SizedBox(height: 6),
                FilledButton.icon(
                  onPressed: () => _recordVisit(context, ref, households[i]),
                  icon: const Icon(Icons.assignment_outlined),
                  label: const Text('방문 결과 입력'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Chip(
        avatar: CircleAvatar(child: Text(value)),
        label: Text(label),
      );
}

class SeaRouteDemoScreen extends StatelessWidget {
  const SeaRouteDemoScreen({super.key});

  static const offshore = LatLng(35.9706, 129.5640);
  static const harborMouth = LatLng(35.9796, 129.5550);
  static const berth = LatLng(35.9861, 129.5515);
  static const landPath = <LatLng>[
    berth,
    LatLng(35.9880, 129.5511),
    LatLng(35.9904, 129.5522),
    LatLng(35.9924, 129.5546),
    LatLng(35.9948, 129.5571),
  ];

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('해상 → 항 → 육상 경로',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text('B11 API 미연결 상태의 합성 시연 경로입니다. 실제 항해·대피 안내가 아닙니다.'),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: 430,
              child: FlutterMap(
                options: const MapOptions(
                    initialCenter: LatLng(35.986, 129.555), initialZoom: 13.5),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                    subdomains: const ['a', 'b', 'c'],
                    userAgentPackageName: 'com.example.guryongpo_safety',
                  ),
                  PolylineLayer(polylines: [
                    Polyline(
                        points: const [offshore, harborMouth, berth],
                        color: Colors.blue.shade700,
                        strokeWidth: 7),
                    Polyline(
                        points: landPath,
                        color: Colors.green.shade700,
                        strokeWidth: 7),
                  ]),
                  MarkerLayer(markers: [
                    Marker(
                      point: offshore,
                      width: 84,
                      height: 64,
                      child: const Column(children: [
                        Icon(Icons.sailing, color: Colors.blue, size: 34),
                        Text('출발', style: TextStyle(fontSize: 11)),
                      ]),
                    ),
                    Marker(
                      point: berth,
                      width: 80,
                      height: 64,
                      child: const Column(children: [
                        Icon(Icons.anchor, color: Colors.deepOrange, size: 32),
                        Text('구룡포항', style: TextStyle(fontSize: 11)),
                      ]),
                    ),
                    Marker(
                      point: landPath.last,
                      width: 84,
                      height: 64,
                      child: const Column(children: [
                        Icon(Icons.health_and_safety,
                            color: Colors.green, size: 32),
                        Text('안전 지점', style: TextStyle(fontSize: 11)),
                      ]),
                    ),
                  ]),
                  const RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution('OpenStreetMap contributors')
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(spacing: 14, runSpacing: 8, children: [
                _RouteLegend(color: Colors.blue.shade700, label: '해상 구간'),
                _RouteLegend(color: Colors.deepOrange, label: '최근접 항·접안점'),
                _RouteLegend(color: Colors.green.shade700, label: '육상 경로'),
              ]),
            ),
          ),
        ],
      );
}

class _RouteLegend extends StatelessWidget {
  const _RouteLegend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, color: color, size: 14),
        const SizedBox(width: 6),
        Text(label),
      ]);
}

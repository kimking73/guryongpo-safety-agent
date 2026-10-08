import 'package:flutter/material.dart';

/// 앱 디자인 = web-prototype (Claude Design 시연 앱, 2026-10-08 사용자 결정).
/// 색·경보 단계는 web-prototype/src/tokens.js 와 같다. 화면은 이 색과 [gkTheme]·ui/gk_widgets.dart 만 쓴다.
class GK {
  GK._();
  static const navy = Color(0xFF14245C);
  static const navyHover = Color(0xFF2A3F86);
  static const tint = Color(0xFFE9EDF7);
  static const ink = Color(0xFF0E1838);
  static const muted = Color(0xFF4A5578);
  static const bg = Color(0xFFF3F5FA);
  static const line = Color(0xFFD5DBEA);
  static const grey = Color(0xFF9AA3BE);
  static const red = Color(0xFFD7312B);
  static const redDark = Color(0xFFB3221D);
  static const redDeep = Color(0xFF8A1C17);
  static const redTint = Color(0xFFFBE3E2);
  static const orange = Color(0xFFEF7D1A);
  static const orangeTint = Color(0xFFFFF1E3);
  static const orangeInk = Color(0xFF9A4A06);
  static const yellow = Color(0xFFF2C230);
  static const yellowInk = Color(0xFF2B2200);
  static const green = Color(0xFF1E9E5A);
  static const switchOff = Color(0xFFC9D0E2);
  static const white = Colors.white;

  static const font = 'Pretendard';
  static const radiusCard = 32.0;
  static const radiusInner = 24.0;
  static const shadow = [BoxShadow(color: Color(0x1A14245C), blurRadius: 24, offset: Offset(0, 6))];
}

/// 경보 4단계 (초록 → 빨강) — 프로토타입 LV
class GkLevel {
  const GkLevel(this.name, this.bg, this.fg);
  final String name;
  final Color bg, fg;
}

const gkLevels = [
  GkLevel('좋음', GK.green, Colors.white),
  GkLevel('관심', GK.yellow, GK.yellowInk),
  GkLevel('주의', GK.orange, Colors.white),
  GkLevel('경보', GK.red, Colors.white),
];

/// 서버 위험 단계(normal·watch·advisory·warning·critical, 한글 이름도) → 4단계
GkLevel gkLevelOf(String? level) {
  final l = (level ?? '').trim();
  return switch (l) {
    'critical' || 'warning' || '경보' || '심각' || '위험' => gkLevels[3],
    'advisory' || '주의보' || '주의' => gkLevels[2],
    'watch' || '관심' || '예비특보' => gkLevels[1],
    _ => gkLevels[0],
  };
}

ThemeData gkTheme() {
  const stadium = StadiumBorder();
  final scheme = ColorScheme.fromSeed(seedColor: GK.navy).copyWith(
    primary: GK.navy,
    onPrimary: Colors.white,
    primaryContainer: GK.tint,
    onPrimaryContainer: GK.navy,
    secondary: GK.navy,
    onSecondary: Colors.white,
    secondaryContainer: GK.tint,
    onSecondaryContainer: GK.navy,
    tertiary: GK.orange,
    error: GK.red,
    onError: Colors.white,
    errorContainer: GK.redTint,
    onErrorContainer: GK.redDark,
    surface: Colors.white,
    onSurface: GK.ink,
    onSurfaceVariant: GK.muted,
    outline: GK.line,
    outlineVariant: GK.tint,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Colors.white,
    surfaceContainer: GK.bg,
    surfaceContainerHigh: GK.bg,
    surfaceContainerHighest: GK.tint,
  );
  TextStyle t(double size, FontWeight w, [Color c = GK.ink, double h = 1.4]) =>
      TextStyle(fontFamily: GK.font, fontSize: size, fontWeight: w, color: c, height: h, letterSpacing: -0.2);
  final text = TextTheme(
    displaySmall: t(40, FontWeight.w800, GK.ink, 1.2),
    headlineLarge: t(36, FontWeight.w800, GK.ink, 1.2),
    headlineMedium: t(30, FontWeight.w800, GK.ink, 1.25),
    headlineSmall: t(26, FontWeight.w800, GK.ink, 1.3),
    titleLarge: t(22, FontWeight.w800),
    titleMedium: t(19, FontWeight.w700),
    titleSmall: t(17, FontWeight.w700),
    bodyLarge: t(19, FontWeight.w400, GK.ink, 1.55),
    bodyMedium: t(17, FontWeight.w400, GK.ink, 1.5),
    bodySmall: t(15, FontWeight.w400, GK.muted, 1.45),
    labelLarge: t(17, FontWeight.w700),
    labelMedium: t(15, FontWeight.w700),
    labelSmall: t(13, FontWeight.w600, GK.muted),
  );
  const pad = EdgeInsets.symmetric(horizontal: 22, vertical: 14);
  final btnText = t(17, FontWeight.w700);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: GK.font,
    textTheme: text,
    scaffoldBackgroundColor: GK.bg,
    canvasColor: GK.bg,
    dividerColor: GK.tint,
    dividerTheme: const DividerThemeData(color: GK.tint, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
        backgroundColor: GK.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: GK.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: t(24, FontWeight.w800)),
    cardTheme: const CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(GK.radiusCard))),
        clipBehavior: Clip.antiAlias),
    filledButtonTheme: FilledButtonThemeData(
        // 색은 colorScheme(남색·흰 글자)에서 — 여기서 정하면 FilledButton.tonal(흰 바탕)도 흰 글자가 돼 안 보인다
        style: FilledButton.styleFrom(shape: stadium, padding: pad, textStyle: btnText)),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
            backgroundColor: GK.navy,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: stadium,
            padding: pad,
            textStyle: btnText)),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: GK.navy,
            backgroundColor: Colors.white,
            side: const BorderSide(color: GK.navy, width: 2),
            shape: stadium,
            padding: pad,
            textStyle: btnText)),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: GK.navy, shape: stadium, textStyle: btnText)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: GK.navy)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: GK.navy, foregroundColor: Colors.white, shape: StadiumBorder(), elevation: 2),
    segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
      shape: const WidgetStatePropertyAll(stadium),
      side: const WidgetStatePropertyAll(BorderSide(color: GK.navy, width: 1.5)),
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? GK.navy : Colors.white),
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : GK.navy),
      textStyle: WidgetStatePropertyAll(t(15, FontWeight.w700)),
    )),
    chipTheme: ChipThemeData(
      backgroundColor: GK.tint,
      selectedColor: GK.navy,
      disabledColor: GK.bg,
      side: BorderSide.none,
      shape: stadium,
      // 선택되면 남색 바탕 → 글자 흰색 (그냥 남색이면 글자가 안 보인다)
      labelStyle: t(15, FontWeight.w700).copyWith(
          color: WidgetStateColor.resolveWith((s) =>
              s.contains(WidgetState.selected) ? Colors.white : (s.contains(WidgetState.disabled) ? GK.grey : GK.navy))),
      secondaryLabelStyle: t(15, FontWeight.w700, Colors.white),
      iconTheme: const IconThemeData(color: GK.navy, size: 20),
      checkmarkColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: GK.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      labelStyle: t(16, FontWeight.w600, GK.muted),
      hintStyle: t(16, FontWeight.w400, GK.grey),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GK.radiusInner), borderSide: const BorderSide(color: GK.line, width: 2)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GK.radiusInner), borderSide: const BorderSide(color: GK.line, width: 2)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GK.radiusInner), borderSide: const BorderSide(color: GK.navy, width: 2)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GK.radiusInner), borderSide: const BorderSide(color: GK.red, width: 2)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? GK.navy : GK.switchOff),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? GK.navy : Colors.white),
        side: const BorderSide(color: GK.navy, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? GK.navy : GK.muted)),
    dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GK.radiusCard)),
        titleTextStyle: t(24, FontWeight.w800),
        contentTextStyle: t(17, FontWeight.w400)),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(GK.radiusCard)))),
    snackBarTheme: SnackBarThemeData(
        backgroundColor: GK.navy,
        behavior: SnackBarBehavior.floating,
        contentTextStyle: t(16, FontWeight.w600, Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    listTileTheme: ListTileThemeData(
        iconColor: GK.navy,
        titleTextStyle: t(18, FontWeight.w700),
        subtitleTextStyle: t(15, FontWeight.w400, GK.muted)),
    expansionTileTheme: const ExpansionTileThemeData(
        iconColor: GK.navy, collapsedIconColor: GK.navy, shape: Border(), collapsedShape: Border()),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: GK.navy, linearTrackColor: GK.tint),
    tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: GK.ink, borderRadius: BorderRadius.circular(12)),
        textStyle: t(14, FontWeight.w600, Colors.white)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: GK.navy,
      indicatorColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      height: 76,
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? GK.navy : Colors.white, size: 28)),
      labelTextStyle: WidgetStatePropertyAll(t(14, FontWeight.w700, Colors.white)),
    ),
    popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    dropdownMenuTheme: DropdownMenuThemeData(textStyle: t(17, FontWeight.w600)),
  );
}

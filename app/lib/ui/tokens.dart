import 'package:flutter/material.dart';

/// 「구룡포 안전 비서 모바일」 디자인(design/mobile-handoff)의 색·모서리·글자 크기.
/// 화면 코드는 색을 직접 쓰지 말고 여기 값을 쓴다
class Ds {
  Ds._();

  // 색
  static const navy = Color(0xFF14225B); // 주색 · 하단 탭바
  static const navyDeep = Color(0xFF0B1233);
  static const bg = Color(0xFFF3F4F9); // 화면 바탕 · 카드 안 회색 칸
  static const card = Colors.white;
  static const ink = Color(0xFF111A3A); // 본문 글자
  static const muted = Color(0xFF4A5578); // 보조 글자
  static const sub = Color(0xFF2A3354); // 설명 글자
  static const faint = Color(0xFF8A93AE); // 입력 안내 글자
  static const soft = Color(0xFFE8EBF5); // 연남색 칩·아이콘 바탕
  static const line = Color(0xFFD5DAE8); // 입력창 테두리
  static const divider = Color(0xFFEDEFF5);
  static const off = Color(0xFF9CA5C2); // 누를 수 없는 버튼
  static const track = Color(0xFFC9CFE3); // 꺼진 토글

  static const danger = Color(0xFFD9342B); // 경보 · 도움 필요
  static const dangerDeep = Color(0xFFB42318);
  static const dangerSoft = Color(0xFFFBE3E1);
  static const warn = Color(0xFFEF7F1A); // 주의
  static const warnDeep = Color(0xFFC25A0C); // 대피 중 · 오프라인
  static const warnSoft = Color(0xFFFFF4EA);
  static const offlineRing = Color(0xFFFCE3CC);
  static const good = Color(0xFF1FA05A); // 좋음
  static const goodDeep = Color(0xFF178A4C); // 대피 완료
  static const goodSoft = Color(0xFFE3F3EA);
  static const caution = Color(0xFFF2C230); // 관심 (글자는 어둡게)
  static const cautionInk = Color(0xFF2A1F00);
  static const noResp = Color(0xFF8E2A1E); // 응답 없음

  // 모서리
  static const rCard = 22.0;
  static const rCardLg = 26.0;
  static const rSheet = 30.0;
  static const pill = 999.0;

  static const fontFamily = 'Pretendard';

  /// 위험 단계(좋음·관심·주의·경보 또는 서버 영문 단계) → 색
  static Color level(String? lv) => switch (lv) {
        '경보' || 'warning' || 'danger' || 'severe' || '심각' || '위험' || '매우나쁨' || '매우높음' => danger,
        '주의' || 'advisory' || 'caution' || '나쁨' || '높음' || '경계' => warn,
        '관심' || 'watch' || 'attention' || '보통' => caution,
        '좋음' || 'normal' || 'safe' || 'ok' || '낮음' || '안전' => good,
        _ => muted,
      };

  /// 색 바탕 위 글자색 (관심 노랑만 어두운 글자)
  static Color onLevel(Color c) => c == caution ? cautionInk : Colors.white;
}

TextStyle dsText(double size,
        {FontWeight weight = FontWeight.w400,
        Color color = Ds.ink,
        double? height,
        double? spacing}) =>
    TextStyle(
        fontFamily: Ds.fontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: spacing);

/// 앱 전체 테마 — 손대지 않은 Material 위젯도 디자인 색·글꼴을 따른다
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Ds.navy,
    primary: Ds.navy,
    onPrimary: Colors.white,
    secondary: Ds.navy,
    surface: Colors.white,
    error: Ds.danger,
  ).copyWith(
    primaryContainer: Ds.soft,
    onPrimaryContainer: Ds.navy,
    secondaryContainer: Ds.soft,
    onSecondaryContainer: Ds.navy,
    surfaceContainerLow: Colors.white,
    surfaceContainer: Ds.bg,
    surfaceContainerHighest: Ds.soft,
    errorContainer: Ds.dangerSoft,
  );
  const pillShape = StadiumBorder();
  final base = ThemeData(
      useMaterial3: true, colorScheme: scheme, fontFamily: Ds.fontFamily);
  return base.copyWith(
    scaffoldBackgroundColor: Ds.bg,
    textTheme: base.textTheme.apply(bodyColor: Ds.ink, displayColor: Ds.ink),
    appBarTheme: const AppBarTheme(
        backgroundColor: Ds.bg,
        foregroundColor: Ds.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
            fontFamily: Ds.fontFamily,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Ds.ink)),
    cardTheme: const CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Ds.rCard)))),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            backgroundColor: Ds.navy,
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 48),
            shape: pillShape,
            textStyle: const TextStyle(
                fontFamily: Ds.fontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w800))),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: Ds.navy,
            minimumSize: const Size(48, 48),
            side: const BorderSide(color: Ds.navy, width: 2),
            shape: pillShape,
            textStyle: const TextStyle(
                fontFamily: Ds.fontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w800))),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            foregroundColor: Ds.navy,
            textStyle: const TextStyle(
                fontFamily: Ds.fontFamily, fontWeight: FontWeight.w700))),
    chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: Ds.soft,
        checkmarkColor: Ds.navy,
        side: const BorderSide(color: Ds.line),
        shape: pillShape,
        labelStyle: const TextStyle(
            fontFamily: Ds.fontFamily,
            fontWeight: FontWeight.w700,
            color: Ds.ink)),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Ds.bg,
        hintStyle: const TextStyle(color: Ds.faint),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Ds.pill),
            borderSide: const BorderSide(color: Ds.line, width: 2)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Ds.pill),
            borderSide: const BorderSide(color: Ds.line, width: 2)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Ds.pill),
            borderSide: const BorderSide(color: Ds.navy, width: 2))),
    switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Ds.navy : Ds.track),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent)),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(Ds.rSheet)))),
    dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)))),
    snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Ds.ink,
        contentTextStyle: TextStyle(
            fontFamily: Ds.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)))),
    dividerTheme: const DividerThemeData(color: Ds.divider, thickness: 1),
    segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
            shape: const WidgetStatePropertyAll(pillShape),
            backgroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Ds.navy : Colors.white),
            foregroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Colors.white : Ds.navy))),
  );
}

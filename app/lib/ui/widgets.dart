import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'tokens.dart';

/// 흰 카드 (디자인 기본 카드: 모서리 22, 그림자 없음)
class AppCard extends StatelessWidget {
  const AppCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14),
      this.radius = Ds.rCard,
      this.color = Ds.card,
      this.onTap});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Padding(padding: padding, child: child);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// 카드 제목 줄 (제목 + 오른쪽 덧붙임)
class CardTitle extends StatelessWidget {
  const CardTitle(this.title, {super.key, this.trailing, this.icon, this.size = 19});
  final String title;
  final Widget? trailing;
  final FaIconData? icon;
  final double size;

  @override
  Widget build(BuildContext context) => Row(children: [
        if (icon != null) ...[
          IconCircle(icon!, size: 40, iconSize: 17),
          const SizedBox(width: 10),
        ],
        Expanded(
            child: Text(title,
                style: dsText(size, weight: FontWeight.w800))),
        if (trailing != null) trailing!,
      ]);
}

/// 둥근 바탕 위 아이콘
class IconCircle extends StatelessWidget {
  const IconCircle(this.icon,
      {super.key,
      this.size = 36,
      this.iconSize = 15,
      this.bg = Ds.soft,
      this.fg = Ds.navy});
  final FaIconData icon;
  final double size, iconSize;
  final Color bg, fg;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: FaIcon(icon, size: iconSize, color: fg),
      );
}

/// 꽉 찬 pill 버튼 (남색 기본)
class PillButton extends StatelessWidget {
  const PillButton(this.label,
      {super.key,
      required this.onPressed,
      this.icon,
      this.height = 54,
      this.bg = Ds.navy,
      this.fg = Colors.white,
      this.fontSize = 17,
      this.outlined = false,
      this.expand = true});
  final String label;
  final VoidCallback? onPressed;
  final FaIconData? icon;
  final double height, fontSize;
  final Color bg, fg;
  final bool outlined, expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final child = Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            FaIcon(icon, size: fontSize - 1, color: outlined ? bg : fg),
            const SizedBox(width: 8),
          ],
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: dsText(fontSize,
                      weight: FontWeight.w800, color: outlined ? bg : fg))),
        ]);
    return SizedBox(
      height: height,
      width: expand ? double.infinity : null,
      child: Material(
        color: outlined ? Colors.white : (enabled ? bg : Ds.off),
        shape: StadiumBorder(
            side: outlined
                ? BorderSide(color: bg, width: 2)
                : BorderSide.none),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
            onTap: onPressed,
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: child)),
      ),
    );
  }
}

/// 작은 pill 칩 (아이콘 원 + 글자) — 재난문자 행동 칩, 경보 칩 등
class PillChip extends StatelessWidget {
  const PillChip(this.label,
      {super.key,
      this.icon,
      this.bg = Colors.white,
      this.fg = Ds.navy,
      this.iconBg,
      this.height = 40,
      this.fontSize = 14,
      this.onTap});
  final String label;
  final FaIconData? icon;
  final Color bg, fg;
  final Color? iconBg;
  final double height, fontSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final circled = iconBg != null;
    return Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          padding: EdgeInsets.only(
              left: icon == null ? 14 : (circled ? 4 : 14), right: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              circled
                  ? IconCircle(icon!,
                      size: height - 8, iconSize: 13, bg: iconBg!, fg: fg)
                  : FaIcon(icon, size: fontSize, color: fg),
              const SizedBox(width: 7),
            ],
            Text(label,
                style: dsText(fontSize, weight: FontWeight.w800, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// 둘·셋 중 하나 고르는 회색 바탕 pill 묶음 (집|현위치|내 장소, 도보|자동차)
class SegmentedPill<T> extends StatelessWidget {
  const SegmentedPill(
      {super.key,
      required this.items,
      required this.value,
      required this.onChanged,
      this.height = 38,
      this.expand = true,
      this.bg = Ds.bg});
  final List<(T, String?, FaIconData?)> items; // (값, 글자, 아이콘)
  final T value;
  final ValueChanged<T> onChanged;
  final double height;
  final bool expand;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    Widget seg((T, String?, FaIconData?) it) {
      final on = it.$1 == value;
      final fg = on ? Colors.white : Ds.sub;
      return Material(
        color: on ? Ds.navy : Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onChanged(it.$1),
          child: SizedBox(
            height: height,
            width: it.$2 == null ? height : null,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: it.$2 == null ? 0 : 8),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (it.$3 != null)
                      FaIcon(it.$3, size: it.$2 == null ? 15 : 11, color: on ? Colors.white : Ds.navy),
                    if (it.$3 != null && it.$2 != null) const SizedBox(width: 4),
                    if (it.$2 != null)
                      Flexible(
                          child: Text(it.$2!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: dsText(14, weight: FontWeight.w800, color: fg))),
                  ]),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(Ds.pill)),
      child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (final (i, it) in items.indexed) ...[
              if (i > 0) const SizedBox(width: 2),
              expand ? Expanded(child: seg(it)) : seg(it),
            ]
          ]),
    );
  }
}

/// 46×28 남색 토글 (디자인 스위치)
class NavySwitch extends StatelessWidget {
  const NavySwitch({super.key, required this.value, required this.onChanged, this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
        toggled: value,
        label: label,
        button: true,
        child: GestureDetector(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 46,
            height: 28,
            decoration: BoxDecoration(
                color: onChanged == null
                    ? Ds.track.withValues(alpha: .5)
                    : (value ? Ds.navy : Ds.track),
                borderRadius: BorderRadius.circular(14)),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 150),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.all(3),
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))
                    ]),
              ),
            ),
          ),
        ),
      );
}

/// 설정 줄: 아이콘 · 제목/설명 · 오른쪽 (토글 등)
class SettingRow extends StatelessWidget {
  const SettingRow(
      {super.key,
      required this.icon,
      required this.title,
      this.subtitle,
      this.trailing,
      this.topBorder = false,
      this.onTap,
      this.subtitleColor = Ds.muted,
      this.highlight = false});
  final FaIconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool topBorder, highlight;
  final VoidCallback? onTap;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: EdgeInsets.symmetric(vertical: 6, horizontal: highlight ? 10 : 0),
      decoration: BoxDecoration(
        color: highlight ? Ds.warnSoft : null,
        borderRadius: highlight ? BorderRadius.circular(14) : null,
        border: highlight
            ? Border.all(color: Ds.warn, width: 1.5)
            : (topBorder
                ? const Border(top: BorderSide(color: Ds.divider))
                : null),
      ),
      child: Row(children: [
        SizedBox(
            width: 18,
            child: Center(child: FaIcon(icon, size: 15, color: Ds.navy))),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: dsText(15, weight: FontWeight.w800)),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(subtitle!,
                        style: dsText(12,
                            color: highlight ? const Color(0xFFB4500A) : subtitleColor,
                            weight: highlight ? FontWeight.w700 : FontWeight.w400,
                            height: 1.35)),
                  ),
              ]),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ]),
    );
    return onTap == null
        ? row
        : InkWell(borderRadius: BorderRadius.circular(14), onTap: onTap, child: row);
  }
}

/// 위험 단계 배지 (좋음·관심·주의·경보)
class LevelBadge extends StatelessWidget {
  const LevelBadge(this.label, {super.key, this.color, this.fontSize = 11});
  final String label;
  final Color? color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Ds.level(label);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize * .55, vertical: fontSize * .2),
      decoration:
          BoxDecoration(color: c, borderRadius: BorderRadius.circular(Ds.pill)),
      child: Text(label,
          style: dsText(fontSize, weight: FontWeight.w800, color: Ds.onLevel(c))),
    );
  }
}

/// 둥근 원 아이콘 버튼 (뒤로, 닫기, 종)
class CircleButton extends StatelessWidget {
  const CircleButton(this.icon,
      {super.key,
      required this.onPressed,
      this.size = 48,
      this.bg = Colors.white,
      this.fg = Ds.navy,
      this.tooltip,
      this.shadow = false,
      this.iconSize});
  final FaIconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double? iconSize;
  final Color bg, fg;
  final String? tooltip;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final btn = Container(
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: shadow
              ? const [BoxShadow(color: Color(0x2614225B), blurRadius: 14, offset: Offset(0, 4))]
              : null),
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
              width: size,
              height: size,
              child: Center(
                  child: FaIcon(icon, size: iconSize ?? size * .37, color: fg))),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// 탭 밖 화면 위쪽: 뒤로 버튼 + 큰 제목 (디자인 '알림' 화면)
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.trailing, this.onBack});
  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          CircleButton(FontAwesomeIcons.arrowLeft,
              tooltip: '뒤로',
              onPressed: onBack ??
                  () => Navigator.of(context).canPop()
                      ? Navigator.of(context).pop()
                      : null),
          const SizedBox(width: 10),
          Expanded(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: dsText(26, weight: FontWeight.w800, spacing: -.4))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// 큰 화면 제목 (탭 화면 위쪽)
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 16),
        child: Row(children: [
          Expanded(
              child: Text(title,
                  style: dsText(30, weight: FontWeight.w800, spacing: -.6))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// 가로로 미는 줄 (마우스 끌기도 됨 · 오른쪽 끝 흐림)
class HScroll extends StatelessWidget {
  const HScroll(
      {super.key,
      required this.children,
      this.gap = 6,
      this.padding = EdgeInsets.zero,
      this.fade = true});
  final List<Widget> children;
  final double gap;
  final EdgeInsets padding;
  final bool fade;

  @override
  Widget build(BuildContext context) {
    final list = ScrollConfiguration(
      behavior: const _DragAll(),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding.copyWith(right: padding.right + 12),
        child: Row(children: [
          for (final (i, c) in children.indexed) ...[
            if (i > 0) SizedBox(width: gap),
            c
          ]
        ]),
      ),
    );
    if (!fade) return list;
    return ShaderMask(
      shaderCallback: (r) => const LinearGradient(
          colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
          stops: [0, .04, .92, 1]).createShader(r),
      blendMode: BlendMode.dstIn,
      child: list,
    );
  }
}

class _DragAll extends MaterialScrollBehavior {
  const _DragAll();
  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}

/// 디자인 입력창 (둥근 회색 칸)
class DsField extends StatelessWidget {
  const DsField(
      {super.key,
      this.label,
      this.controller,
      this.hint,
      this.keyboardType,
      this.obscure = false,
      this.onSubmitted,
      this.onChanged,
      this.fill = Ds.bg,
      this.autofillHints,
      this.error = false,
      this.maxLength,
      this.textCapitalization = TextCapitalization.none});
  final String? label;
  final TextEditingController? controller;
  final String? hint;
  final TextInputType? keyboardType;
  final bool obscure, error;
  final ValueChanged<String>? onSubmitted, onChanged;
  final Color fill;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      autofillHints: autofillHints,
      maxLength: maxLength,
      textCapitalization: textCapitalization,
      style: dsText(17, weight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        fillColor: fill,
        enabledBorder: error
            ? OutlineInputBorder(
                borderRadius: BorderRadius.circular(Ds.pill),
                borderSide: const BorderSide(color: Ds.danger, width: 2))
            : null,
      ),
    );
    if (label == null) return field;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label!, style: dsText(15, weight: FontWeight.w800)),
      ),
      field,
    ]);
  }
}

/// 빨간 경고 글 (입력 오류)
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(children: [
          const FaIcon(FontAwesomeIcons.circleExclamation, size: 14, color: Ds.danger),
          const SizedBox(width: 6),
          Expanded(
              child: Text(text,
                  style: dsText(14, weight: FontWeight.w700, color: Ds.danger))),
        ]),
      );
}

/// 지도 자리 (실제 지도가 없을 때 줄무늬)
class StripedPlaceholder extends StatelessWidget {
  const StripedPlaceholder({super.key, required this.label, this.height});
  final String label;
  final double? height;
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
            color: const Color(0xFFF6F7FB),
            borderRadius: BorderRadius.circular(16)),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(Ds.pill)),
          child: Text(label, style: dsText(14, color: Ds.muted)),
        ),
      );
}

/// 화면 아래 토스트 (디자인: 어두운 둥근 상자)
void showDsToast(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(
      content: Text(text, textAlign: TextAlign.center),
      duration: const Duration(milliseconds: 2400)));
}

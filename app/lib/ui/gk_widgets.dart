import 'package:flutter/material.dart';
import 'gk_theme.dart';

/// web-prototype 공통 조각 (src/components/ui.jsx 와 화면들의 card·pill 스타일).
/// 흰 카드(반경 32) · 원 안의 아이콘 · 알약 버튼·칩 · 큰 제목 · 스위치 줄 · 경보 단계 칩·범례.

class GkCard extends StatelessWidget {
  const GkCard({super.key, required this.child, this.padding, this.color, this.onTap, this.shadow = false});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final VoidCallback? onTap;
  final bool shadow;
  @override
  Widget build(BuildContext c) {
    final narrow = MediaQuery.sizeOf(c).width < 600;
    final body = Padding(padding: padding ?? EdgeInsets.all(narrow ? 20 : 28), child: child);
    // 바탕은 Material 로 — 안의 ListTile·InkWell 물결이 보이게 (DecoratedBox 바탕이면 가려지고 디버그 경고)
    final card = Material(
      color: color ?? Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GK.radiusCard)),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
    if (!shadow) return card;
    return DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(GK.radiusCard), boxShadow: GK.shadow), child: card);
  }
}

class GkCircleIcon extends StatelessWidget {
  const GkCircleIcon(this.icon, {super.key, this.size = 48, this.bg = GK.tint, this.fg = GK.navy, this.iconSize});
  final IconData icon;
  final double size;
  final Color bg, fg;
  final double? iconSize;
  @override
  Widget build(BuildContext c) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(icon, color: fg, size: iconSize ?? size * 0.56),
      );
}

/// 화면 큰 제목 (프로토타입 h1 48 → 좁은 화면 32)
class GkPageTitle extends StatelessWidget {
  const GkPageTitle(this.text, {super.key, this.trailing, this.subtitle});
  final String text;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext c) {
    final narrow = MediaQuery.sizeOf(c).width < 600;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text,
              style: TextStyle(
                  fontSize: narrow ? 32 : 44, fontWeight: FontWeight.w800, color: GK.ink, letterSpacing: -0.8, height: 1.2)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle!, style: const TextStyle(fontSize: 17, color: GK.muted, fontWeight: FontWeight.w600)),
            ),
        ])),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// 카드 머리 (원 아이콘 + 제목 + 오른쪽 작은 글)
class GkCardHeader extends StatelessWidget {
  const GkCardHeader(this.title, {super.key, this.icon, this.trailing, this.iconBg = GK.tint, this.iconFg = GK.navy, this.color});
  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Color iconBg, iconFg;
  final Color? color;
  @override
  Widget build(BuildContext c) => Row(children: [
        if (icon != null) ...[GkCircleIcon(icon!, size: 48, bg: iconBg, fg: iconFg), const SizedBox(width: 12)],
        Expanded(
            child: Text(title,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: color ?? GK.ink, height: 1.25))),
        if (trailing != null) trailing!,
      ]);
}

/// 알약 버튼·칩. filled = 남색 바탕, 아니면 연한 남색(tint) 바탕
class GkPill extends StatelessWidget {
  const GkPill(this.label,
      {super.key, this.icon, this.onTap, this.filled = false, this.trailingIcon, this.bg, this.fg, this.big = false});
  final String label;
  final IconData? icon, trailingIcon;
  final VoidCallback? onTap;
  final bool filled, big;
  final Color? bg, fg;
  @override
  Widget build(BuildContext c) {
    final background = bg ?? (filled ? GK.navy : GK.tint);
    final foreground = fg ?? (filled ? Colors.white : GK.navy);
    final fs = big ? 19.0 : 16.0;
    return Material(
      color: background,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
          padding: EdgeInsets.symmetric(horizontal: big ? 22 : 16, vertical: big ? 14 : 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: fs + 5, color: foreground), const SizedBox(width: 8)],
            Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: fs, fontWeight: FontWeight.w700, color: foreground))),
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              Icon(trailingIcon, size: fs + 4, color: foreground.withValues(alpha: 0.8))
            ],
          ]),
        ),
        ),
      ),
    );
  }
}

/// 경보 단계 칩 (좋음·관심·주의·경보)
class GkLevelChip extends StatelessWidget {
  const GkLevelChip(this.level, {super.key, this.label});
  final GkLevel level;
  final String? label;
  @override
  Widget build(BuildContext c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: level.bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label ?? level.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: level.fg)),
      );
}

/// 4단계 범례 (좋음 → 경보)
class GkLevelLegend extends StatelessWidget {
  const GkLevelLegend({super.key});
  @override
  Widget build(BuildContext c) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final l in gkLevels)
          Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 20, height: 20, decoration: BoxDecoration(color: l.bg, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(l.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          ),
      ]);
}

/// 작은 아이콘 + 이름·짧은 설명 + 오른쪽 스위치 (2026-10-09: 원 배경·큰 여백을 빼고 목록처럼).
/// [note] = 주의 문구 (주황, 예: 화면 점멸의 광과민성 안내). 줄 전체를 눌러도 바뀌고, 키보드 초점은 스위치가 받는다
class GkSwitchRow extends StatelessWidget {
  const GkSwitchRow(
      {super.key,
      required this.icon,
      required this.label,
      this.desc,
      this.note,
      required this.value,
      required this.onChanged});
  final IconData icon;
  final String label;
  final String? desc, note;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext c) => MergeSemantics(
        child: InkWell(
          canRequestFocus: false,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Container(
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: GK.tint))),
            child: Row(children: [
              Icon(icon, size: 22, color: GK.navy),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GK.ink)),
                if (desc != null)
                  Text(desc!, style: const TextStyle(fontSize: 14, color: GK.muted, height: 1.35)),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(
                          padding: EdgeInsets.only(top: 1),
                          child: Icon(Icons.warning_amber_rounded, size: 16, color: GK.orangeInk)),
                      const SizedBox(width: 4),
                      Expanded(
                          child: Text(note!,
                              style: const TextStyle(fontSize: 13.5, color: GK.orangeInk, fontWeight: FontWeight.w600))),
                    ]),
                  ),
              ])),
              const SizedBox(width: 8),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      );
}

/// 작은 아이콘 + 항목명 + 값 한 줄 (프로토타입 내 정보 rowLine, 2026-10-09 간결하게).
/// [empty]면 값을 옅게 ('입력 안 함' 등). [valueWidget]을 주면 값 대신 그것 (여러 줄 장소 목록)
class GkInfoRow extends StatelessWidget {
  const GkInfoRow(
      {super.key,
      required this.icon,
      required this.label,
      this.value = '',
      this.valueWidget,
      this.trailing,
      this.empty = false,
      this.divider = true});
  final IconData icon;
  final String label, value;
  final Widget? valueWidget, trailing;
  final bool empty, divider;
  @override
  Widget build(BuildContext c) => MergeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: divider ? const BoxDecoration(border: Border(bottom: BorderSide(color: GK.tint))) : null,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 22, color: GK.navy)),
            const SizedBox(width: 12),
            SizedBox(
                width: 92,
                child: Text(label, style: const TextStyle(fontSize: 15, color: GK.muted, height: 1.45))),
            const SizedBox(width: 8),
            Expanded(
                child: valueWidget ??
                    Text(value,
                        style: TextStyle(
                            fontSize: 16,
                            height: 1.4,
                            fontWeight: empty ? FontWeight.w500 : FontWeight.w700,
                            color: empty ? GK.grey : GK.ink))),
            if (trailing != null) trailing!,
          ]),
        ),
      );
}

/// 프로필 카드 제목 (20px) — 카드 안 여백은 [gkCompactPad]
class GkCardTitle extends StatelessWidget {
  const GkCardTitle(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext c) => Semantics(
        header: true,
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 22, color: GK.navy), const SizedBox(width: 8)],
          Flexible(child: Text(text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: GK.ink))),
        ]),
      );
}

/// 간결한 카드 안 여백 (프로필 화면, 2026-10-09)
const gkCompactPad = EdgeInsets.all(20);

/// 넓은 화면이면 두 칸, 좁으면 한 칸으로 쌓는다 (프로토타입 grid auto-fit)
class GkColumns extends StatelessWidget {
  const GkColumns({super.key, required this.children, this.minWidth = 420, this.gap = 20, this.equalHeight = true});
  final List<Widget> children;
  final double minWidth, gap;
  /// 같은 줄 카드 높이 맞추기 (IntrinsicHeight — 안에 LayoutBuilder·목록이 있으면 false)
  final bool equalHeight;
  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
        final cols = (box.maxWidth / minWidth).floor().clamp(1, children.length);
        if (cols <= 1) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]]
          ]);
        }
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += cols) {
          final part = children.sublist(i, (i + cols).clamp(0, children.length));
          final row = Row(
              crossAxisAlignment: equalHeight ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < cols; j++) ...[
                  if (j > 0) SizedBox(width: gap),
                  Expanded(child: j < part.length ? part[j] : const SizedBox()),
                ]
              ]);
          rows.add(equalHeight ? IntrinsicHeight(child: row) : row);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: gap), rows[i]]
        ]);
      });
}

/// 화면 바깥 여백 (프로토타입 padding 8px 40px 56px, 좁으면 16)
EdgeInsets gkPagePadding(BuildContext c) {
  final w = MediaQuery.sizeOf(c).width;
  final side = w < 600 ? 16.0 : (w < 1100 ? 28.0 : 40.0);
  return EdgeInsets.fromLTRB(side, 8, side, 48);
}

/// 메뉴 항목 (이름, 아이콘, 주소)
typedef GkNavItem = (String, IconData, String);

/// 넓은 화면 왼쪽 남색 세로 메뉴 (프로토타입 SideNav, 폭 116) — 맨 위 방패, 맨 아래 [bottom](119 버튼)
class GkSideNav extends StatelessWidget {
  const GkSideNav({super.key, required this.items, required this.selected, required this.onTap, this.bottom});
  final List<GkNavItem> items;
  final int selected;
  final ValueChanged<int> onTap;
  final Widget? bottom;
  @override
  Widget build(BuildContext c) => Container(
        width: 116,
        color: GK.navy,
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          const GkCircleIcon(Icons.shield_rounded, size: 56, bg: Colors.white, fg: GK.navy),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Column(children: [
                for (var i = 0; i < items.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: i == selected ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => onTap(i),
                        child: SizedBox(
                          width: 92,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 14, 4, 12),
                            child: Column(children: [
                              Icon(items[i].$2, size: 34, color: i == selected ? GK.navy : Colors.white),
                              const SizedBox(height: 6),
                              Text(items[i].$1,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      height: 1.2,
                                      color: i == selected ? GK.navy : Colors.white)),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          if (bottom != null) bottom!,
        ]),
      );
}

/// 빨간 119 긴급전화 버튼 (프로토타입 EmergencyCall). compact = 위쪽 줄용 작은 알약
class GkEmergencyCall extends StatelessWidget {
  const GkEmergencyCall({super.key, required this.onCall, this.compact = false});
  final VoidCallback onCall;
  final bool compact;
  @override
  Widget build(BuildContext c) {
    if (compact) {
      return GkPill('119', icon: Icons.call_rounded, filled: true, bg: GK.red, onTap: onCall);
    }
    return Material(
      color: GK.red,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onCall,
        child: const SizedBox(
          width: 92,
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, 16, 0, 14),
            child: Column(children: [
              GkCircleIcon(Icons.call_rounded, size: 48, bg: Colors.white, fg: GK.red),
              SizedBox(height: 6),
              Text('119', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, height: 1)),
              SizedBox(height: 4),
              Text('긴급전화', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
            ]),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'gk_theme.dart';

/// 대시보드 지도 메뉴 (2026-10-09 사용자 요청): 상위 메뉴(재난 지도·경로 안내) + 하위 버튼.
/// 모양 = 기존 남색·연한 배경·둥근 버튼, 참고 이미지처럼 아이콘 + 짧은 글자를 한 버튼에, 관련 버튼은 연한 둥근 바탕에 묶는다.
/// 선택 여부는 색 + 체크(라디오) 표시 + 테두리로 같이 보이고, 보조 기술에는 펼침(expanded)·선택(checked) 상태로 알린다.
/// 터치 영역 최소 48×48, 키보드 Tab·Enter·Space 조작, 포커스는 주황 테두리.

/// 같은 모양의 SVG 아이콘 (24×24, 선 2px, 둥근 끝, 채움 없음). 색은 그릴 때 입힌다
class MapIcons {
  static const _head =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">';
  static String _svg(String body) => '$_head$body</svg>';

  static final layers = _svg('<path d="M12 3 2.5 8 12 13l9.5-5z"/><path d="m2.5 12.5 9.5 5 9.5-5"/><path d="m2.5 17 9.5 4.5 9.5-4.5"/>');
  static final route = _svg(
      '<circle cx="6" cy="19" r="2.5"/><circle cx="18" cy="5" r="2.5"/><path d="M8.5 19H15a3.5 3.5 0 0 0 0-7H9a3.5 3.5 0 0 1 0-7h6.5"/>');
  static final all = _svg(
      '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>');
  static final typhoon = _svg(
      '<circle cx="12" cy="12" r="3"/><path d="M19 5.5C17 3.6 14 2.8 11 3.4A8.5 8.5 0 0 0 3.5 12"/><path d="M5 18.5c2 1.9 5 2.7 8 2.1A8.5 8.5 0 0 0 20.5 12"/>');
  static final flood = _svg(
      '<path d="M4 11V4h16v7"/><path d="M12 4v7"/><path d="M4 7.5h16"/><path d="M3 15c1.5 1.3 3 1.3 4.5 0s3-1.3 4.5 0 3 1.3 4.5 0 3-1.3 4.5 0"/><path d="M3 19.5c1.5 1.3 3 1.3 4.5 0s3-1.3 4.5 0 3 1.3 4.5 0 3-1.3 4.5 0"/>');
  static final wind = _svg('<path d="M3 8h10a3 3 0 1 0-3-3"/><path d="M3 12h15a3 3 0 1 1-3 3"/><path d="M3 16h7"/>');
  static final landslide =
      _svg('<path d="M2 20 9 8l4 6 2-3 7 9z"/><circle cx="17" cy="5.5" r="1.5"/><circle cx="20.5" cy="9" r="1"/>');
  static final shortest = _svg('<circle cx="5" cy="12" r="2"/><path d="M7 12h13"/><path d="m16 8 4 4-4 4"/>');
  static final safe = _svg(
      '<path d="M12 3 4.5 6v5.5c0 4.6 3.2 8.4 7.5 9.5 4.3-1.1 7.5-4.9 7.5-9.5V6z"/><path d="m8.5 12 2.5 2.5 4.5-5"/>');
  static final flat = _svg('<path d="m4 14 5-8 5 8"/><path d="M2 18.5h17"/><path d="m16 15.5 3 3-3 3"/>');
  static final anchor = _svg(
      '<circle cx="12" cy="5" r="2"/><path d="M12 7v14"/><path d="M8 11h8"/><path d="M4 14a8 8 0 0 0 16 0"/>');
  static final locate = _svg(
      '<circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="2.5"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>');
  static final check = _svg('<path d="m5 12.5 4.5 4.5L19 7.5"/>');
  static final chevronDown = _svg('<path d="m6 9 6 6 6-6"/>');
  static final info = _svg('<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5"/><path d="M12 7.5h.01"/>');
  static final external = _svg(
      '<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5"/>');
}

class MapIcon extends StatelessWidget {
  const MapIcon(this.svg, {super.key, this.size = 22, this.color = GK.navy});
  final String svg;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SvgPicture.string(svg,
            width: size, height: size, colorFilter: ColorFilter.mode(color, BlendMode.srcIn)),
      );
}

/// 버튼 종류: 상위 메뉴(펼침) · 여러 개 선택(체크) · 하나만 선택(라디오) · 그냥 실행
enum MapButtonKind { menu, check, radio, action }

/// 지도 메뉴 버튼 하나. [selected] = 상위 메뉴면 지금 보고 있는 메뉴, 체크·라디오면 켜짐
class MapMenuButton extends StatefulWidget {
  const MapMenuButton({
    super.key,
    required this.label,
    required this.icon,
    required this.kind,
    this.selected = false,
    this.expanded,
    this.onTap,
    this.tooltip,
    this.big = false,
  });
  final String label;
  final String icon;
  final MapButtonKind kind;
  final bool selected, big;
  /// 상위 메뉴만: 하위 항목이 펼쳐져 있는지
  final bool? expanded;
  /// null 이면 사용할 수 없음 (흐리게)
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<MapMenuButton> createState() => _MapMenuButtonState();
}

class _MapMenuButtonState extends State<MapMenuButton> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final enabled = w.onTap != null;
    final on = w.selected;
    final menu = w.kind == MapButtonKind.menu;
    final bg = !enabled
        ? GK.bg
        : on
            ? GK.navy
            : menu
                ? GK.tint
                : Colors.white;
    final fg = !enabled ? GK.grey : (on ? Colors.white : GK.navy);
    final border = !enabled ? GK.line : (on ? GK.navy : (menu ? GK.tint : GK.line));
    final fs = w.big ? 19.0 : 16.0;

    // 선택 표시 (색 말고도 보이게): 체크 = 동그라미 안 체크, 라디오 = 동그라미 안 점, 메뉴 = 접힘·펼침 화살표
    Widget? mark;
    switch (w.kind) {
      case MapButtonKind.check:
      case MapButtonKind.radio:
        mark = Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? Colors.white : Colors.transparent,
            border: Border.all(color: on ? Colors.white : (enabled ? GK.grey : GK.line), width: 2),
          ),
          alignment: Alignment.center,
          child: !on
              ? null
              : w.kind == MapButtonKind.check
                  ? const MapIcon(_check, size: 16, color: GK.navy)
                  : Container(
                      width: 10, height: 10, decoration: const BoxDecoration(color: GK.navy, shape: BoxShape.circle)),
        );
      case MapButtonKind.menu:
        mark = AnimatedRotation(
          turns: w.expanded == true ? .5 : 0,
          duration: const Duration(milliseconds: 150),
          child: MapIcon(MapIcons.chevronDown, size: 20, color: fg),
        );
      case MapButtonKind.action:
        mark = null;
    }
    final markFirst = w.kind == MapButtonKind.check || w.kind == MapButtonKind.radio;

    final content = Row(mainAxisSize: MainAxisSize.min, children: [
      if (markFirst && mark != null) ...[mark, const SizedBox(width: 8)],
      MapIcon(w.icon, size: fs + 4, color: fg),
      const SizedBox(width: 8),
      // 좁은 화면에서는 글자가 줄바꿈된다 (잘리지 않게)
      Flexible(
          child: Text(w.label,
              softWrap: true,
              style: TextStyle(fontSize: fs, fontWeight: FontWeight.w700, color: fg, height: 1.25))),
      if (!markFirst && mark != null) ...[const SizedBox(width: 6), mark],
    ]);

    Widget button = Material(
      color: bg,
      shape: StadiumBorder(side: BorderSide(color: border, width: 2)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: w.onTap,
        onFocusChange: (f) => setState(() => focused = f),
        focusColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: w.big ? 20 : 14, vertical: 8),
            child: Align(widthFactor: 1, heightFactor: 1, child: content),
          ),
        ),
      ),
    );
    // 포커스 테두리: 남색·흰 바탕 어디서나 보이게 주황 3px, 바깥에 둘러 크기는 그대로
    button = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: focused ? GK.orange : Colors.transparent, width: 3)),
      ),
      child: Padding(padding: const EdgeInsets.all(3), child: button),
    );

    // 보조 기술: 메뉴 = 버튼 + 펼침 상태, 체크 = 체크박스, 라디오 = 한 묶음 안의 라디오
    button = Semantics(
      container: true,
      enabled: enabled,
      expanded: menu ? (w.expanded ?? false) : null,
      selected: menu ? on : null,
      checked: menu || w.kind == MapButtonKind.action ? null : on,
      inMutuallyExclusiveGroup: w.kind == MapButtonKind.radio ? true : null,
      child: button,
    );
    if (w.tooltip != null) button = Tooltip(message: w.tooltip!, child: button);
    return button;
  }
}

const _check =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>';

/// 관련 버튼 묶음: 연한 둥근 바탕 + 줄바꿈 (참고 이미지의 '집·현위치·내 장소' 묶음 모양). [label] 은 보조 기술용 묶음 이름
class MapButtonGroup extends StatelessWidget {
  const MapButtonGroup({super.key, required this.label, required this.children});
  final String label;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: label,
        explicitChildNodes: true,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(color: GK.bg, borderRadius: BorderRadius.circular(30)),
          child: Wrap(spacing: 4, runSpacing: 4, children: children),
        ),
      );
}

/// 안내 한 줄 (아이콘 + 글 + 선택 버튼) — 위치 확인 필요·태풍 표시 범위 등
class MapNotice extends StatelessWidget {
  const MapNotice({super.key, required this.text, this.title, this.action, this.warn = false});
  final String text;
  final String? title;
  final Widget? action;
  final bool warn;
  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: warn ? GK.orangeTint : GK.bg,
            borderRadius: BorderRadius.circular(GK.radiusInner),
            border: Border.all(color: warn ? GK.orange : GK.line, width: 1.5),
          ),
          child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              MapIcon(MapIcons.info, size: 22, color: warn ? GK.orangeInk : GK.navy),
              const SizedBox(width: 10),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (title != null)
                    Text(title!,
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800, color: warn ? GK.orangeInk : GK.ink)),
                  Text(text, style: const TextStyle(fontSize: 15, height: 1.45, color: GK.muted)),
                ]),
              ),
            ]),
            if (action != null) action!,
          ]),
        ),
      );
}

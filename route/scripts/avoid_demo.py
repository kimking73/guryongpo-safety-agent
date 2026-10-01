"""위험 구역 회피 검증 (시연용): 가상 침수 구역을 무작위로 켜고 끄며 경로가 바뀌는지 확인하고 그림으로 남긴다.

운영 코드 그대로 검증한다 — RouteService(hazards=…)에 메모리 위험 구역 소스를 넣어 route()를 부르고,
GraphHopper는 실행 중인 컨테이너(localhost:8989)를 실제로 호출한다. 서비스의 임시 위험 파일은 건드리지 않는다.

실행 (graphhopper가 떠 있어야 한다):
    cd 코드/route
    uv pip install -p .venv -e ".[demo]"
    .venv/bin/python scripts/avoid_demo.py --seed 20261001
산출물: route/out/avoid_demo/ — trial_XX.png, contact_sheet.png, avoid.gif, results.csv, results.md

회차별 판정
  ① 회피 경로가 켜진 구역과 겹치지 않는다 (겹치면 still_inside에 있어야 하고, 경계 사례가 아니면 still_inside는 비어야 함)
  ② 응답의 avoided = 켜진 구역 중 기본 경로와 겹치는 것 − still_inside
  ③ 켜진 구역이 모두 기본 경로 밖이면 회피 경로 = 기본 경로 (불필요한 우회 없음)
"""

from __future__ import annotations

import argparse
import csv
import math
import random
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import osmium  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402
from PIL import Image  # noqa: E402
from shapely.geometry import LineString, Point  # noqa: E402

from guardian_route.gh import GraphHopperClient  # noqa: E402
from guardian_route.hazards import Hazard, circle  # noqa: E402
from guardian_route.service import RouteRequest, RouteService, _line  # noqa: E402

OSM_FILE = ROOT.parent / "graphhopper" / "data" / "guryongpo.osm.pbf"
OUT = ROOT / "out" / "avoid_demo"
plt.rcParams["font.family"] = "Apple SD Gothic Neo"   # 한글 (macOS 기본 글꼴, 굵게 지원)
plt.rcParams["axes.unicode_minus"] = False

# 출발·도착 3쌍 (lat, lon)
PAIRS = [
    ("구룡포항 → 실내체육관 부근", (35.9905, 129.5560), (35.9868, 129.5480)),   # B6 실측 경로
    ("남쪽 → 서쪽 언덕", (35.9800, 129.5600), (35.9950, 129.5450)),            # B7 실측 경로
    ("시가지 남북 횡단", (35.9945, 129.5525), (35.9830, 129.5505)),
]
ON_ROUTE, DECOYS = 4, 2          # 쌍마다 경로 위 구역 4개 + 대조군 2개
RADIUS_M = (40, 80)
END_MARGIN_M = 100               # 출발·도착 이 거리 안에는 구역을 두지 않는다 (돌아갈 길이 있도록)
DECOY_CLEAR_M = 200              # 대조군 구역 가장자리가 경로에서 떨어진 거리
TRIALS_PER_PAIR = 5


class MemoryHazards:
    """HazardSource 프로토콜(guardian_route/hazards.py)을 따르는 메모리 소스. 회차마다 켜진 구역만 담는다."""

    def __init__(self) -> None:
        self.zones: list[Hazard] = []

    def hazards(self) -> list[Hazard]:
        return list(self.zones)


# --- 좌표 ↔ m (구룡포 수 km 범위에서 충분히 정확) ------------------------------------

LAT0 = 35.99
M_PER_DEG_LAT = 111_320
M_PER_DEG_LON = 111_320 * math.cos(math.radians(LAT0))


def to_m(lon: float, lat: float) -> tuple[float, float]:
    return lon * M_PER_DEG_LON, lat * M_PER_DEG_LAT


def to_m_line(line: LineString) -> LineString:
    return LineString([to_m(x, y) for x, y in line.coords])


def from_m(x: float, y: float) -> tuple[float, float]:
    return x / M_PER_DEG_LON, y / M_PER_DEG_LAT


# --- 구역 만들기 ---------------------------------------------------------------

@dataclass
class Zone:
    name: str                 # Z1 … (그림·표에 쓰는 이름)
    hazard: Hazard
    on_route: bool            # 경로 위 구역(True) / 대조군(False)
    center: tuple[float, float]
    radius: float


def make_zones(rng: random.Random, pair_idx: int, base: LineString) -> list[Zone]:
    line_m = to_m_line(base)
    zones: list[Zone] = []
    usable = line_m.length - 2 * END_MARGIN_M
    picks: list[float] = []
    while len(picks) < ON_ROUTE:                       # 서로 150m 이상 떨어진 지점
        d = END_MARGIN_M + rng.random() * usable
        if all(abs(d - p) >= 150 for p in picks):
            picks.append(d)
    for d in sorted(picks):
        p = line_m.interpolate(d)
        lon, lat = from_m(p.x, p.y)
        r = rng.uniform(*RADIUS_M)
        zones.append(Zone(f"Z{len(zones) + 1}", Hazard(f"demo-{pair_idx}-{len(zones) + 1}", "flood",
                                                       circle(lat, lon, r, sides=24), source="demo"),
                          True, (lat, lon), r))
    minx, miny, maxx, maxy = line_m.bounds
    while len(zones) < ON_ROUTE + DECOYS:
        x, y = rng.uniform(minx - 300, maxx + 300), rng.uniform(miny - 300, maxy + 300)
        r = rng.uniform(*RADIUS_M)
        if line_m.distance(Point(x, y)) - r < DECOY_CLEAR_M:
            continue
        lon, lat = from_m(x, y)
        zones.append(Zone(f"Z{len(zones) + 1}", Hazard(f"demo-{pair_idx}-{len(zones) + 1}", "flood",
                                                       circle(lat, lon, r, sides=24), source="demo"),
                          False, (lat, lon), r))
    return zones


# --- 회차 실행·판정 --------------------------------------------------------------

@dataclass
class Trial:
    no: int
    pair: str
    origin: tuple[float, float]
    dest: tuple[float, float]
    zones: list[Zone]
    on: list[str]
    base_geom: str
    base_dist: int
    boundary: bool = False
    safe_geom: str = ""
    dist: int = 0
    dur: int = 0
    avoided: list[str] = field(default_factory=list)
    still_inside: list[str] = field(default_factory=list)
    gh_ms: int = 0
    passed: bool = False
    notes: list[str] = field(default_factory=list)


def run_trial(svc: RouteService, mem: MemoryHazards, t: Trial) -> None:
    by_name = {z.name: z for z in t.zones}
    by_id = {z.hazard.id: z.name for z in t.zones}
    mem.zones = [by_name[n].hazard for n in t.on]
    req = RouteRequest(origin={"lat": t.origin[0], "lon": t.origin[1]},
                       destination={"lat": t.dest[0], "lon": t.dest[1]}, avoid_manholes=False)
    t0 = time.perf_counter()
    res = svc.route(req)
    t.gh_ms = round((time.perf_counter() - t0) * 1000)
    t.safe_geom, t.dist, t.dur = res.geometry, res.distance_m, res.duration_s
    t.avoided = sorted(by_id[i] for i in res.avoided)
    t.still_inside = sorted(by_id[i] for i in res.still_inside)

    safe, base = _line(res.geometry), _line(t.base_geom)
    on_zones = [by_name[n] for n in t.on]
    crossing = sorted(z.name for z in on_zones if safe.intersects(z.hazard.geometry))
    ok1 = set(crossing) <= set(t.still_inside) and (t.boundary or not t.still_inside)
    if not ok1:
        t.notes.append(f"① 켜진 구역 통과 {crossing}, still_inside {t.still_inside}")
    expect_avoided = sorted({z.name for z in on_zones if base.intersects(z.hazard.geometry)} - set(t.still_inside))
    ok2 = expect_avoided == t.avoided
    if not ok2:
        t.notes.append(f"② avoided 기대 {expect_avoided} ≠ 응답 {t.avoided}")
    ok3 = True
    if not any(base.intersects(z.hazard.geometry) for z in on_zones):
        ok3 = res.geometry == t.base_geom
        if not ok3:
            t.notes.append(f"③ 경로 밖 구역만 켜졌는데 경로가 바뀜 ({t.base_dist}m → {t.dist}m)")
        else:
            t.notes.append("③ 경로 밖 구역만 켜짐 → 기본 경로 유지")
    if t.boundary:
        t.notes.append("경계 사례: 출발지가 구역 안 → 막히지 않고 still_inside로 알림")
    t.passed = ok1 and ok2 and ok3


# --- 배경 도로 (로컬 OSM) ------------------------------------------------------------

class Roads(osmium.SimpleHandler):
    def __init__(self, bbox: tuple[float, float, float, float]) -> None:
        super().__init__()
        self.bbox, self.lines = bbox, []

    def way(self, w) -> None:
        if "highway" not in w.tags:
            return
        try:
            pts = [(n.lon, n.lat) for n in w.nodes]
        except osmium.InvalidLocationError:
            return
        x0, y0, x1, y1 = self.bbox
        if any(x0 <= x <= x1 and y0 <= y <= y1 for x, y in pts):
            self.lines.append((pts, w.tags.get("highway")))


def load_roads(bbox: tuple[float, float, float, float]) -> list:
    h = Roads(bbox)
    h.apply_file(str(OSM_FILE), locations=True)
    return h.lines


# --- 그림 ---------------------------------------------------------------------

MAJOR = {"primary", "secondary", "tertiary", "trunk", "primary_link", "secondary_link"}


def draw(t: Trial, roads: list, total: int, path: Path) -> None:
    base = _line(t.base_geom)
    safe = _line(t.safe_geom)
    xs = [x for g in (base, safe) for x, _ in g.coords] + [z.center[1] for z in t.zones] + [t.origin[1], t.dest[1]]
    ys = [y for g in (base, safe) for _, y in g.coords] + [z.center[0] for z in t.zones] + [t.origin[0], t.dest[0]]
    pad = 0.0018
    x0, x1, y0, y1 = min(xs) - pad, max(xs) + pad, min(ys) - pad, max(ys) + pad

    fig, ax = plt.subplots(figsize=(8, 8.8), dpi=110)
    for pts, kind in roads:
        if any(x0 <= x <= x1 and y0 <= y <= y1 for x, y in pts):
            lx, ly = zip(*pts)
            ax.plot(lx, ly, color="#b9b9b9" if kind in MAJOR else "#dcdcdc",
                    lw=1.6 if kind in MAJOR else 0.9, zorder=1)
    for z in t.zones:
        on = z.name in t.on
        gx, gy = z.hazard.geometry.exterior.xy
        if on:
            ax.fill(gx, gy, color="#e5484d", alpha=0.35, zorder=2)
            ax.plot(gx, gy, color="#e5484d", lw=1.6, zorder=2)
        else:
            ax.plot(gx, gy, color="#8a8a8a", lw=1.2, ls=(0, (3, 3)), zorder=2)
        ax.text(z.center[1], z.center[0], z.name, ha="center", va="center", fontsize=9,
                color="#a01c20" if on else "#6b6b6b", fontweight="bold", zorder=5)
    bx, by = base.xy
    ax.plot(bx, by, color="#222", lw=1.8, ls=(0, (4, 3)), zorder=3)
    sx, sy = safe.xy
    ax.plot(sx, sy, color="#1f6feb", lw=3.6, alpha=0.9, zorder=4, solid_capstyle="round")
    # GraphHopper는 출발·도착을 가장 가까운 길로 붙인다 → 표시 지점과 경로 끝을 점선으로 잇는다
    (sx0, sy0), (sx1, sy1) = safe.coords[0], safe.coords[-1]
    ax.plot([t.origin[1], sx0], [t.origin[0], sy0], color="#1f9d55", lw=1, ls=":", zorder=5)
    ax.plot([t.dest[1], sx1], [t.dest[0], sy1], color="#d97a00", lw=1, ls=":", zorder=5)
    ax.plot(t.origin[1], t.origin[0], "o", ms=11, color="#1f9d55", mec="white", mew=1.5, zorder=6)
    ax.plot(t.dest[1], t.dest[0], "*", ms=17, color="#d97a00", mec="white", mew=1.2, zorder=6)

    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_aspect(1 / math.cos(math.radians(LAT0)))
    ax.set_xticks([])
    ax.set_yticks([])
    for s in ax.spines.values():
        s.set_color("#dddddd")
    on_txt = ", ".join(t.on) or "없음"
    diff = t.dist - t.base_dist
    title = (f"회차 {t.no}/{total} · {t.pair}" + (" · 경계 사례" if t.boundary else "") + "\n"
             f"켜진 구역 {on_txt} · {t.dist:,}m ({diff:+,}m) · 피함 {', '.join(t.avoided) or '없음'}"
             + (f" · 못 피함 {', '.join(t.still_inside)}" if t.still_inside else "")
             + f" · 판정 {'통과' if t.passed else '실패'}")
    ax.set_title(title, fontsize=11, loc="left", color="#1d1d1f")
    ax.legend(handles=[
        Line2D([], [], color="#1f6feb", lw=3.6, label="회피 경로"),
        Line2D([], [], color="#222", lw=1.8, ls=(0, (4, 3)), label="기본 경로 (구역 없음)"),
        Patch(facecolor="#e5484d", alpha=0.35, edgecolor="#e5484d", label="켜진 위험 구역"),
        Line2D([], [], color="#8a8a8a", lw=1.2, ls=(0, (3, 3)), label="꺼진 위험 구역"),
        Line2D([], [], marker="o", color="w", markerfacecolor="#1f9d55", ms=10, label="출발"),
        Line2D([], [], marker="*", color="w", markerfacecolor="#d97a00", ms=14, label="도착"),
        Line2D([], [], color="#888", lw=1, ls=":", label="가장 가까운 길까지"),
    ], loc="upper center", bbox_to_anchor=(0.5, -0.01), ncol=4, fontsize=8.5, frameon=False)
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)


def contact_sheet(paths: list[Path], out: Path, cols: int = 4, thumb: int = 440) -> None:
    rows = math.ceil(len(paths) / cols)
    sheet = Image.new("RGB", (cols * thumb, rows * thumb), "white")
    for i, p in enumerate(paths):
        im = Image.open(p).convert("RGB")
        im.thumbnail((thumb, thumb))
        sheet.paste(im, ((i % cols) * thumb, (i // cols) * thumb))
    sheet.save(out)


def gif(paths: list[Path], out: Path, ms: int = 1500) -> None:
    frames = []
    for p in paths:
        im = Image.open(p).convert("RGB")
        frames.append(im.resize((660, round(660 * im.height / im.width))))   # 비율 유지
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=ms, loop=0, optimize=True)


# --- 실행 --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=20261001)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    OUT.mkdir(parents=True, exist_ok=True)

    mem = MemoryHazards()
    svc = RouteService(client=GraphHopperClient(), hazards=mem)
    if not svc.gh.ping():
        print("GraphHopper(localhost:8989)에 닿지 않음 — docker compose up -d graphhopper")
        return 2

    trials: list[Trial] = []
    for pi, (name, o, d) in enumerate(PAIRS, start=1):
        mem.zones = []
        base = svc.route(RouteRequest(origin={"lat": o[0], "lon": o[1]}, destination={"lat": d[0], "lon": d[1]},
                                      avoid_manholes=False))
        zones = make_zones(rng, pi, _line(base.geometry))
        prev: tuple[str, ...] = ()
        for _ in range(TRIALS_PER_PAIR):
            while True:
                on = tuple(z.name for z in zones if rng.random() < 0.5)
                if on and on != prev:
                    break
            prev = on
            trials.append(Trial(len(trials) + 1, name, o, d, zones, list(on), base.geometry, base.distance_m))
    # 경로 밖 구역만 켜진 회차가 하나도 없으면 마지막 회차를 그렇게 바꾼다 (③을 반드시 한 번은 확인)
    if not any(all(not z.on_route for z in t.zones if z.name in t.on) for t in trials):
        trials[-1].on = [z.name for z in trials[-1].zones if not z.on_route]

    # 경계 사례: 출발지를 덮는 구역 + 경로 위 구역 하나
    name, o, d = PAIRS[0]
    first = trials[0]
    cover = Zone("Z0", Hazard("demo-1-0", "flood", circle(o[0], o[1], 60, sides=24), source="demo"), True, o, 60)
    trials.append(Trial(len(trials) + 1, name, o, d, [cover, *first.zones], ["Z0", first.zones[1].name],
                        first.base_geom, first.base_dist, boundary=True))

    for t in trials:
        run_trial(svc, mem, t)
        print(f"회차 {t.no:2d} [{'통과' if t.passed else '실패'}] {t.pair} 켜짐 {t.on} → {t.dist}m "
              f"({t.dist - t.base_dist:+}m) 피함 {t.avoided} 못 피함 {t.still_inside} {t.gh_ms}ms "
              + (" / ".join(t.notes)))

    lons = [x for t in trials for g in (t.base_geom, t.safe_geom) for x, _ in _line(g).coords]
    lats = [y for t in trials for g in (t.base_geom, t.safe_geom) for _, y in _line(g).coords]
    roads = load_roads((min(lons) - 0.01, min(lats) - 0.01, max(lons) + 0.01, max(lats) + 0.01))
    paths = []
    for t in trials:
        p = OUT / f"trial_{t.no:02d}.png"
        draw(t, roads, len(trials), p)
        paths.append(p)
    contact_sheet(paths, OUT / "contact_sheet.png")
    gif(paths, OUT / "avoid.gif")

    with open(OUT / "results.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["회차", "출발→도착", "켜진 구역", "기본 거리(m)", "회피 거리(m)", "증가(m)", "소요(초)",
                    "피한 구역", "못 피한 구역", "응답(ms)", "판정", "비고"])
        for t in trials:
            w.writerow([t.no, t.pair, " ".join(t.on), t.base_dist, t.dist, t.dist - t.base_dist, t.dur,
                        " ".join(t.avoided), " ".join(t.still_inside), t.gh_ms,
                        "통과" if t.passed else "실패", " / ".join(t.notes)])
    passed = sum(t.passed for t in trials)
    detours = [t.dist - t.base_dist for t in trials if t.avoided]
    lines = [f"# 위험 구역 회피 검증 결과 (seed {a.seed})", "",
             f"- 판정: **{passed}/{len(trials)} 통과**",
             f"- 회피가 일어난 회차 {len(detours)}건, 평균 우회 {sum(detours) / max(1, len(detours)):.0f}m",
             f"- 경로 계산 응답 평균 {sum(t.gh_ms for t in trials) / len(trials):.0f}ms (GraphHopper 2회 호출 포함)", "",
             "| 회차 | 출발→도착 | 켜진 구역 | 기본 → 회피 (m) | 피함 | 못 피함 | 판정 |", "|---|---|---|---|---|---|---|"]
    lines += [f"| {t.no} | {t.pair} | {', '.join(t.on)} | {t.base_dist:,} → {t.dist:,} ({t.dist - t.base_dist:+,}) | "
              f"{', '.join(t.avoided) or '-'} | {', '.join(t.still_inside) or '-'} | {'통과' if t.passed else '실패'} |"
              for t in trials]
    (OUT / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n판정 {passed}/{len(trials)} 통과 · 산출물 {OUT}")
    return 0 if passed == len(trials) else 1


if __name__ == "__main__":
    raise SystemExit(main())

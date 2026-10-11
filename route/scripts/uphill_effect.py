"""오르막 회피(strategy flat)가 효과가 있는가 — 효과 크기 측정.

무작위 출발·도착 N쌍에서 기본 경로(성인, 안전한 경로)와 오르막 회피 경로를 받아, 급한 오르막을 얼마나 덜 지나는지와
그 대가(더 걷는 거리·시간)를 잰다. 통과/실패가 아니라 숫자를 낸다.

고도 자료 두 가지로 잰다.
  - 90m: 경로 서버(GraphHopper)가 경사 계산에 쓰는 자료 그대로 — 구간 평균 경사(average_slope)와 좌표의 고도
  - 30m: 경로 계산에 쓰지 않은 Copernicus GLO-30 (out/dem_check/glo30.npy). 경로를 10m 간격으로 찍어 고도를 읽고
         50m 이동 평균으로 고른 뒤 경사를 다시 계산한다. 90m에서만 줄고 여기서 안 줄면 '지도 위에서만의 효과'다.
경로는 운영 코드의 규칙(profiles.rules_for → service.build_model)을 GraphHopper에 그대로 보낸다 (위험 구역 없음 = 평시).

준비: out/dem_check/glo30.npy·glo30.json (Copernicus 타일을 gdal 컨테이너로 잘라 만든다 — timeline 2026-10-11 기록)
실행 (route/ 폴더에서):
    .venv/bin/python scripts/uphill_effect.py --pairs 20      # 시험
    .venv/bin/python scripts/uphill_effect.py                  # 300쌍
산출물: route/out/uphill_effect_<seed>/ — summary.md, pairs.csv, results.json, scatter.png, tradeoff.png, case_XX_a/b.png, uphill.gif
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import avoid_demo as D  # noqa: E402 — 도로 읽기·GIF·좌표 변환을 그대로 쓴다

from guardian_route.profiles import SLOPE_ACCESSIBLE_MAX, SLOPE_SIDEWALK_MAX, rules_for  # noqa: E402
from guardian_route.service import build_model  # noqa: E402

plt = D.plt
GH_URL = "http://localhost:8989"
PUBLIC = "https://34-64-177-195.nip.io"
BBOX = (129.515, 35.955, 129.585, 36.015)      # 구룡포읍 시가지와 둘레 언덕 (lon0, lat0, lon1, lat1)
WALKABLE = {"residential", "service", "unclassified", "tertiary", "secondary", "primary", "living_street", "pedestrian",
            "footway", "path", "track", "steps", "tertiary_link", "secondary_link", "primary_link"}
MIN_M, MAX_M = 300, 3000                        # 출발·도착 직선 거리
STEP_M, SMOOTH_N, SMOOTH_WIDE = 10, 5, 11        # 30m 자료: 10m 간격 표본, 50m 이동 평균 (+ 110m 평균으로도 재서 잡음 영향을 본다)
TOL_M = 10                                      # 이만큼 넘게 달라져야 '줄었다/늘었다'로 센다
DEM_DIR = D.ROOT / "out" / "dem_check"


class Dem30:
    """Copernicus GLO-30 잘라낸 조각. 화소 중심 기준 쌍선형 보간."""

    def __init__(self) -> None:
        self.a = np.load(DEM_DIR / "glo30.npy")
        self.x0, self.dx, _, self.y0, _, self.dy = json.loads((DEM_DIR / "glo30.json").read_text())["gt"]

    def at(self, lon: np.ndarray, lat: np.ndarray) -> np.ndarray:
        c = (lon - self.x0) / self.dx - 0.5
        r = (lat - self.y0) / self.dy - 0.5
        c0, r0 = np.floor(c).astype(int), np.floor(r).astype(int)
        fc, fr = c - c0, r - r0
        a = self.a
        return (a[r0, c0] * (1 - fc) * (1 - fr) + a[r0, c0 + 1] * fc * (1 - fr)
                + a[r0 + 1, c0] * (1 - fc) * fr + a[r0 + 1, c0 + 1] * fc * fr)


@dataclass
class Measure:
    """한 경로를 한 고도 자료로 잰 값"""
    ascend: float = 0.0        # 총 오름 (m)
    steep1: float = 0.0        # 오르막 5.56% 초과 ~ 8.33% 이하 길이 (m)
    steep2: float = 0.0        # 오르막 8.33% 초과 길이 (m)
    max_up: float = 0.0        # 최대 오르막 (%)

    @property
    def steep(self) -> float:
        return self.steep1 + self.steep2

    @property
    def burden(self) -> float:   # 규칙의 추가 비용 그대로: 5배(= +4), 2배(= +1)
        return self.steep2 * 4 + self.steep1


@dataclass
class Path_:
    coords: list                # [lon, lat, ele]
    dist: float
    time_s: float
    slopes: list                # GraphHopper details.average_slope [[from, to, %], …]
    m90: Measure = field(default_factory=Measure)
    m30: Measure = field(default_factory=Measure)
    m30w: Measure = field(default_factory=Measure)   # 110m 평균
    gh_ascend: float = 0.0
    prof: tuple = ()            # (거리 m, 30m 자료 고도) — 단면 그림용


def gh_route(http: httpx.Client, o, d, model) -> Path_:
    body = {"profile": "foot", "points": [[o[1], o[0]], [d[1], d[0]]], "points_encoded": False, "elevation": True,
            "instructions": False, "details": ["average_slope"]}
    if model:
        body["custom_model"] = model
    res = http.post("/route", json=body)
    res.raise_for_status()
    p = res.json()["paths"][0]
    return Path_(p["points"]["coordinates"], p["distance"], p["time"] / 1000, p["details"]["average_slope"],
                 gh_ascend=float(p.get("ascend") or 0))


def seg_len(coords: list) -> np.ndarray:
    xy = np.array([D.to_m(c[0], c[1]) for c in coords])
    return np.hypot(*np.diff(xy, axis=0).T) if len(xy) > 1 else np.zeros(0)


def measure90(p: Path_) -> Measure:
    """경로 서버가 보는 값: 구간 평균 경사(정수 %)별 길이, 좌표 고도로 총 오름"""
    L = seg_len(p.coords)
    m = Measure()
    for a, b, v in p.slopes:
        if v is None:
            continue
        n = float(L[a:b].sum())
        if v > SLOPE_ACCESSIBLE_MAX:
            m.steep2 += n
        elif v > SLOPE_SIDEWALK_MAX:
            m.steep1 += n
        m.max_up = max(m.max_up, v)
    m.ascend = p.gh_ascend          # GraphHopper가 계산한 총 오름 (앱에 나가는 ascend_m과 같은 값)
    return m


def measure30(p: Path_, dem: Dem30, n_smooth: int = SMOOTH_N) -> Measure:
    """독립 자료: 10m 간격으로 고도를 읽어 이동 평균(기본 50m) → 10m 걸음마다 경사"""
    L = seg_len(p.coords)
    cum = np.concatenate([[0], np.cumsum(L)])
    if cum[-1] < STEP_M * 2:
        return Measure()
    s = np.arange(0, cum[-1], STEP_M)
    lon = np.interp(s, cum, [c[0] for c in p.coords])
    lat = np.interp(s, cum, [c[1] for c in p.coords])
    z = dem.at(lon, lat)
    pad = n_smooth // 2
    zs = np.convolve(np.pad(z, pad, mode="edge"), np.ones(n_smooth) / n_smooth, mode="valid")
    g = np.diff(zs) / STEP_M * 100
    if n_smooth == SMOOTH_N:
        p.prof = (s, zs)
    return Measure(ascend=float(np.clip(np.diff(zs), 0, None).sum()),
                   steep1=float(((g > SLOPE_SIDEWALK_MAX) & (g <= SLOPE_ACCESSIBLE_MAX)).sum() * STEP_M),
                   steep2=float((g > SLOPE_ACCESSIBLE_MAX).sum() * STEP_M),
                   max_up=float(max(g.max(), 0)) if len(g) else 0.0)


def sample_pairs(rng: random.Random, n: int) -> list:
    roads = D.load_roads(BBOX)
    nodes = sorted({(round(y, 6), round(x, 6)) for pts, kind in roads if kind in WALKABLE for x, y in pts
                    if BBOX[0] <= x <= BBOX[2] and BBOX[1] <= y <= BBOX[3]})
    pairs = []
    while len(pairs) < n:
        o, d = rng.choice(nodes), rng.choice(nodes)
        if MIN_M <= math.hypot((o[0] - d[0]) * D.M_PER_DEG_LAT, (o[1] - d[1]) * D.M_PER_DEG_LON) <= MAX_M:
            pairs.append((o, d))
    return pairs


def q(v, p) -> float:
    return float(np.percentile(v, p)) if len(v) else 0.0


def med_iqr(v) -> str:
    return f"{q(v, 50):+,.0f} ({q(v, 25):+,.0f} ~ {q(v, 75):+,.0f})"


# --- 그림 ---------------------------------------------------------------------

def steep_runs(p: Path_):
    """90m 기준 급한 오르막 구간의 좌표 묶음 [(xs, ys, 단계)]"""
    for a, b, v in p.slopes:
        if v is not None and v > SLOPE_SIDEWALK_MAX:
            seg = p.coords[a:b + 1]
            yield [c[0] for c in seg], [c[1] for c in seg], 2 if v > SLOPE_ACCESSIBLE_MAX else 1


def draw_case(no: int, total: int, label: str, o, d, base: Path_, flat: Path_, roads: list, path: Path, with_flat: bool) -> None:
    xs = [c[0] for p in (base, flat) for c in p.coords]
    ys = [c[1] for p in (base, flat) for c in p.coords]
    pad = 0.0015
    x0, x1, y0, y1 = min(xs) - pad, max(xs) + pad, min(ys) - pad, max(ys) + pad
    fig, (ax, pr) = plt.subplots(2, 1, figsize=(8, 10.4), dpi=110, gridspec_kw={"height_ratios": [3.1, 1]})
    for pts, kind in roads:
        if any(x0 <= x <= x1 and y0 <= y <= y1 for x, y in pts):
            lx, ly = zip(*pts)
            ax.plot(lx, ly, color="#b9b9b9" if kind in D.MAJOR else "#dcdcdc", lw=1.6 if kind in D.MAJOR else 0.9, zorder=1)
    shown = [base, flat] if with_flat else [base]
    if with_flat:
        ax.plot([c[0] for c in flat.coords], [c[1] for c in flat.coords], color="#1f6feb", lw=4.2, alpha=0.9, zorder=3,
                solid_capstyle="round")
    ax.plot([c[0] for c in base.coords], [c[1] for c in base.coords], color="#111111", lw=2.2, ls=(0, (4, 2.5)), zorder=5)
    for p in shown:
        for sx, sy, lv in steep_runs(p):
            ax.plot(sx, sy, color="#d1242f" if lv == 2 else "#f08c00", lw=7, alpha=0.55, zorder=4, solid_capstyle="round")
    ax.plot(o[1], o[0], "o", ms=11, color="#1f9d55", mec="white", mew=1.5, zorder=8)
    ax.plot(d[1], d[0], "*", ms=17, color="#d97a00", mec="white", mew=1.2, zorder=8)
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_aspect(1 / math.cos(math.radians(D.LAT0)))
    ax.set_xticks([])
    ax.set_yticks([])
    for s in ax.spines.values():
        s.set_color("#dddddd")
    head = f"사례 {no}/{total} · {label}\n"
    if with_flat:
        same = flat.coords == base.coords
        line = (f"② 오르막 회피 {flat.dist:,.0f}m ({flat.dist - base.dist:+,.0f}m) · 급한 오르막 {flat.m30.steep:,.0f}m "
                f"({flat.m30.steep - base.m30.steep:+,.0f}m) · 오름 {flat.m30.ascend:.0f}m ({flat.m30.ascend - base.m30.ascend:+.0f}m)"
                + (" · 기본 경로와 같음" if same else ""))
    else:
        line = f"① 기본 경로 {base.dist:,.0f}m · 급한 오르막 {base.m30.steep:,.0f}m · 오름 {base.m30.ascend:.0f}m (30m 자료 기준)"
    ax.set_title(head + line, fontsize=11, loc="left", color="#1d1d1f")
    ax.legend(handles=[
        D.Line2D([], [], color="#111111", lw=2.2, ls=(0, (4, 2.5)), label="기본 경로"),
        D.Line2D([], [], color="#1f6feb", lw=4.2, label="오르막 회피 경로"),
        D.Line2D([], [], color="#f08c00", lw=7, alpha=0.55, label="오르막 1/18 초과 (경로 서버 기준)"),
        D.Line2D([], [], color="#d1242f", lw=7, alpha=0.55, label="오르막 1/12 초과 (경로 서버 기준)"),
        D.Line2D([], [], marker="o", color="w", markerfacecolor="#1f9d55", ms=10, label="출발"),
        D.Line2D([], [], marker="*", color="w", markerfacecolor="#d97a00", ms=14, label="도착"),
    ], loc="upper center", bbox_to_anchor=(0.5, -0.01), ncol=3, fontsize=8.5, frameon=False)

    # 고도 단면 (30m 독립 자료). 두 장의 축 범위는 같다
    zmin = min(float(p.prof[1].min()) for p in (base, flat))
    zmax = max(float(p.prof[1].max()) for p in (base, flat))
    pr.plot(base.prof[0], base.prof[1], color="#111111", lw=1.8, ls=(0, (4, 2.5)))
    if with_flat:
        pr.plot(flat.prof[0], flat.prof[1], color="#1f6feb", lw=2.6)
    pr.set_xlim(0, max(base.dist, flat.dist) * 1.02)
    pr.set_ylim(min(0, zmin - 2), zmax + max(4, (zmax - zmin) * 0.12))
    pr.set_xlabel("출발지에서 걸은 거리 (m)", fontsize=9)
    pr.set_ylabel("고도 (m)", fontsize=9)
    pr.tick_params(labelsize=8)
    pr.grid(color="#e6e6e6", lw=0.8)
    for s in ("top", "right"):
        pr.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)


def draw_scatter(rows: list, out: Path) -> None:
    fig, axes = plt.subplots(1, 2, figsize=(11, 5.4), dpi=120)
    for ax, key, name in ((axes[0], "90", "경로 서버가 쓰는 90m 자료"), (axes[1], "30", "독립 자료 (Copernicus 30m)")):
        b = np.array([r[f"base_steep{key}"] for r in rows])
        f = np.array([r[f"flat_steep{key}"] for r in rows])
        ch = np.array([r["changed"] for r in rows])
        top = max(b.max(), f.max(), 50) * 1.05
        ax.plot([0, top], [0, top], color="#999999", lw=1, ls=(0, (3, 3)))
        ax.scatter(b[~ch], f[~ch], s=14, color="#b5b5b5", label=f"경로 그대로 ({int((~ch).sum())}쌍)")
        ax.scatter(b[ch], f[ch], s=22, color="#1f6feb", alpha=0.8, label=f"경로 바뀜 ({int(ch.sum())}쌍)")
        ax.set_xlim(0, top)
        ax.set_ylim(0, top)
        ax.set_aspect("equal")
        ax.set_xlabel("기본 경로의 급한 오르막 길이 (m)")
        ax.set_ylabel("오르막 회피 경로의 급한 오르막 길이 (m)")
        ax.set_title(name, fontsize=11, loc="left")
        ax.text(top * 0.97, top * 0.04, "점선 아래 = 줄었음", ha="right", fontsize=9, color="#555555")
        ax.grid(color="#eeeeee", lw=0.8)
        ax.legend(fontsize=8.5, frameon=False, loc="upper left")
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(out)
    plt.close(fig)


def draw_tradeoff(rows: list, out: Path) -> None:
    ch = [r for r in rows if r["changed"]]
    fig, ax = plt.subplots(figsize=(7.4, 5.4), dpi=120)
    x = [r["flat_dist"] - r["base_dist"] for r in ch]
    y = [r["flat_steep30"] - r["base_steep30"] for r in ch]
    ax.axhline(0, color="#999999", lw=1)
    ax.axvline(0, color="#999999", lw=1)
    ax.scatter(x, y, s=24, color=["#1f6feb" if v < -TOL_M else "#d1242f" if v > TOL_M else "#9a9a9a" for v in y], alpha=0.85)
    ax.set_xlabel("더 걷는 거리 (m)")
    ax.set_ylabel("급한 오르막 길이 변화 (m, 30m 자료) — 아래일수록 좋음")
    ax.set_title("경로가 바뀐 쌍: 더 걷는 만큼 오르막이 줄었는가", fontsize=11, loc="left")
    ax.grid(color="#eeeeee", lw=0.8)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(out)
    plt.close(fig)


# --- 본문 ---------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=20261011)
    ap.add_argument("--pairs", type=int, default=300)
    ap.add_argument("--strategy", default="flat", help="flat(기본) 또는 uphill — 오르막 규칙은 같다")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()
    out = a.out or D.ROOT / "out" / f"uphill_effect_{a.seed}"
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(a.seed)
    dem = Dem30()
    http = httpx.Client(base_url=GH_URL, timeout=20.0)
    if http.get("/health").status_code != 200:
        print("GraphHopper(localhost:8989)에 닿지 않음 — docker compose up -d graphhopper")
        return 2
    base_model = build_model(rules_for("adult", None), [])
    flat_model = build_model(rules_for("adult", a.strategy), [])

    rows, kept = [], []
    skipped = 0
    for o, d in sample_pairs(rng, a.pairs):
        try:
            base, flat = gh_route(http, o, d, base_model), gh_route(http, o, d, flat_model)
        except httpx.HTTPStatusError:
            skipped += 1                      # 도로망에서 이어지지 않는 점
            continue
        for p in (base, flat):
            p.m90, p.m30, p.m30w = measure90(p), measure30(p, dem), measure30(p, dem, SMOOTH_WIDE)
        if not base.prof or not flat.prof:
            skipped += 1
            continue
        r = {"no": len(rows) + 1, "o": o, "d": d, "changed": base.coords != flat.coords,
             "base_dist": round(base.dist), "flat_dist": round(flat.dist),
             "base_min": round(base.time_s / 60, 1), "flat_min": round(flat.time_s / 60, 1)}
        for key, bm, fm in (("90", base.m90, flat.m90), ("30", base.m30, flat.m30), ("30w", base.m30w, flat.m30w)):
            r |= {f"base_steep{key}": round(bm.steep), f"flat_steep{key}": round(fm.steep),
                  f"base_steep2_{key}": round(bm.steep2), f"flat_steep2_{key}": round(fm.steep2),
                  f"base_burden{key}": round(bm.burden), f"flat_burden{key}": round(fm.burden),
                  f"base_asc{key}": round(bm.ascend, 1), f"flat_asc{key}": round(fm.ascend, 1),
                  f"base_max{key}": round(bm.max_up, 1), f"flat_max{key}": round(fm.max_up, 1)}
        rows.append(r)
        kept.append((base, flat))

    n = len(rows)
    ch = [r for r in rows if r["changed"]]
    had90 = [r for r in rows if r["base_steep90"] > 0]          # 경로 서버가 보기에 급한 오르막이 있던 쌍

    def tally(key: str, metric: str = "steep") -> tuple[int, int, int]:
        dv = [r[f"flat_{metric}{key}"] - r[f"base_{metric}{key}"] for r in ch]
        tol = TOL_M if metric == "steep" else 2          # 총 오름은 ±2m
        return sum(v < -tol for v in dv), sum(abs(v) <= tol for v in dv), sum(v > tol for v in dv)

    def delta(key: str) -> list:
        return [r[f"flat_{key}"] - r[f"base_{key}"] for r in ch]

    def total(key: str, rs: list) -> float:
        return sum(r[key] for r in rs)

    lines = [f"# 오르막 회피 효과 측정 (seed {a.seed}, strategy {a.strategy})", "",
             f"- 표본: 무작위 출발·도착 **{n}쌍** (직선 {MIN_M}m~{MAX_M / 1000:.0f}km, 경로 없음 {skipped}쌍 제외)",
             f"- 경로 서버 기준으로 기본 경로에 급한 오르막(1/18 초과)이 있던 쌍: **{len(had90)}쌍** ({len(had90) / n:.0%})",
             f"- 오르막 회피를 켜서 **경로가 바뀐 쌍: {len(ch)}쌍** ({len(ch) / n:.0%})", ""]
    if ch:
        lines += ["## 경로가 바뀐 쌍에서의 변화 — 중앙값 (25% ~ 75%)", "",
                  "| 항목 | 90m (경로 서버 자료) | 30m 독립 자료 (50m 평균) | 30m 독립 자료 (110m 평균) |", "|---|---|---|---|",
                  f"| 급한 오르막 길이 (m) | {med_iqr(delta('steep90'))} | {med_iqr(delta('steep30'))} | {med_iqr(delta('steep30w'))} |",
                  f"| 그중 1/12 초과 (m) | {med_iqr(delta('steep2_90'))} | {med_iqr(delta('steep2_30'))} | {med_iqr(delta('steep2_30w'))} |",
                  f"| 총 오름 (m) | {med_iqr(delta('asc90'))} | {med_iqr(delta('asc30'))} | {med_iqr(delta('asc30w'))} |",
                  f"| 최대 오르막 (%p) | {med_iqr(delta('max90'))} | {med_iqr(delta('max30'))} | {med_iqr(delta('max30w'))} |",
                  f"| 더 걷는 거리 (m) | {med_iqr(delta('dist'))} | 같음 | 같음 |",
                  f"| 더 걸리는 시간 (분) | {q(delta('min'), 50):+.1f} ({q(delta('min'), 25):+.1f} ~ {q(delta('min'), 75):+.1f}) | 같음 | 같음 |", "",
                  f"## 바뀐 {len(ch)}쌍을 줄었음 / 비슷(±{TOL_M}m) / 늘었음으로 세면", "",
                  "| 급한 오르막 길이 | 줄었음 | 비슷 | 늘었음 |", "|---|---|---|---|",
                  "| 90m (경로 서버 자료) | {} | {} | {} |".format(*tally("90")),
                  "| 30m 독립 자료 (50m 평균) | {} | {} | {} |".format(*tally("30")),
                  "| 30m 독립 자료 (110m 평균) | {} | {} | {} |".format(*tally("30w")), "",
                  "| 총 오름 | 줄었음 | 비슷 | 늘었음 |", "|---|---|---|---|",
                  "| 90m (경로 서버 자료) | {} | {} | {} |".format(*tally("90", "asc")),
                  "| 30m 독립 자료 (50m 평균) | {} | {} | {} |".format(*tally("30", "asc")),
                  "| 30m 독립 자료 (110m 평균) | {} | {} | {} |".format(*tally("30w", "asc")), "",
                  "## 바뀐 쌍 전체 합계", "",
                  "| 항목 | 기본 경로 | 오르막 회피 | 변화 |", "|---|---|---|---|"]
        for label, key in (("급한 오르막 길이, 90m 자료 (m)", "steep90"), ("급한 오르막 길이, 30m 자료 50m 평균 (m)", "steep30"),
                           ("급한 오르막 길이, 30m 자료 110m 평균 (m)", "steep30w"),
                           ("1/12 초과 오르막 길이, 90m 자료 (m)", "steep2_90"), ("1/12 초과 오르막 길이, 30m 자료 50m 평균 (m)", "steep2_30"),
                           ("총 오름, 90m 자료 (m)", "asc90"), ("총 오름, 30m 자료 50m 평균 (m)", "asc30"),
                           ("총 오름, 30m 자료 110m 평균 (m)", "asc30w"), ("걷는 거리 (m)", "dist")):
            b, f = total(f"base_{key}", ch), total(f"flat_{key}", ch)
            lines.append(f"| {label} | {b:,.0f} | {f:,.0f} | {f - b:+,.0f} ({(f - b) / b:+.0%}) |" if b else f"| {label} | 0 | {f:,.0f} | – |")
        cut30 = total("base_steep30", ch) - total("flat_steep30", ch)
        extra = total("flat_dist", ch) - total("base_dist", ch)
        if cut30 > 0:
            lines += ["", f"- 30m 자료 기준, 급한 오르막 1m를 줄이는 데 평균 **{extra / cut30:.1f}m** 더 걷는다."]
        worse = sorted((r for r in ch if r["flat_steep30"] - r["base_steep30"] > TOL_M),
                       key=lambda r: r["base_steep30"] - r["flat_steep30"])
        if worse:
            lines += ["", "## 30m 자료 기준으로 급한 오르막이 오히려 늘어난 쌍", "",
                      "| 쌍 | 급한 오르막 30m (m) | 급한 오르막 90m (m) | 거리 (m) |", "|---|---|---|---|"]
            lines += [f"| {r['no']} | {r['base_steep30']} → {r['flat_steep30']} | {r['base_steep90']} → {r['flat_steep90']} | "
                      f"{r['base_dist']:,} → {r['flat_dist']:,} |" for r in worse]
    still = [r for r in had90 if not r["changed"]]
    lines += ["", f"- 급한 오르막이 있는데도 경로가 그대로인 쌍: {len(still)}쌍 (돌아갈 만한 길이 없거나, 돌아가는 비용이 더 큼)"]
    (out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "results.json").write_text(json.dumps({"seed": a.seed, "strategy": a.strategy, "skipped": skipped, "rows": rows},
                                                 ensure_ascii=False), encoding="utf-8")
    with open(out / "pairs.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    draw_scatter(rows, out / "scatter.png")
    if ch:
        draw_tradeoff(rows, out / "tradeoff.png")

    # 사례: 효과 큰 것 6 · 효과 없거나 나빠진 것 3 · 급한 오르막이 있는데 그대로인 것 3 (30m 자료 기준)
    gain = lambda r: r["base_steep30"] - r["flat_steep30"]      # noqa: E731
    by_gain = sorted(ch, key=gain, reverse=True)
    picks = [(r, "효과 큼") for r in by_gain[:6]]
    picks += [(r, "효과 없음·나빠짐") for r in by_gain[::-1][:3] if r not in [p[0] for p in picks]]
    picks += [(r, "급한 오르막이 있지만 경로 그대로") for r in sorted(still, key=lambda r: -r["base_steep90"])[:3]]
    roads = D.load_roads((BBOX[0] - 0.02, BBOX[1] - 0.02, BBOX[2] + 0.02, BBOX[3] + 0.02))
    frames, finals = [], []
    for i, (r, label) in enumerate(picks, start=1):
        base, flat = kept[r["no"] - 1]
        pa, pb = out / f"case_{i:02d}_a.png", out / f"case_{i:02d}_b.png"
        draw_case(i, len(picks), f"{label} (쌍 {r['no']})", r["o"], r["d"], base, flat, roads, pa, False)
        draw_case(i, len(picks), f"{label} (쌍 {r['no']})", r["o"], r["d"], base, flat, roads, pb, True)
        frames += [pa, pb, pb]
        finals.append(pb)
    if frames:
        D.gif(frames, out / "uphill.gif", ms=1200)
        D.contact_sheet(finals, out / "contact_sheet.png", cols=4)
    (out / "cases.json").write_text(json.dumps([{"case": i, "label": lb, **r} for i, (r, lb) in enumerate(picks, 1)],
                                               ensure_ascii=False, indent=1), encoding="utf-8")

    # 배포 서버와 같은 경로인가 (읽기 전용 호출 5쌍 — 고도 자료가 다르면 여기서 드러난다)
    vm = []
    try:
        pub = httpx.Client(timeout=20.0)
        for r in (ch or rows)[:5]:
            body = {"origin": {"lat": r["o"][0], "lon": r["o"][1]}, "destination": {"lat": r["d"][0], "lon": r["d"][1]}}
            b = pub.post(PUBLIC + "/api/route", json=body).json()
            f = pub.post(PUBLIC + "/api/route", json={**body, "strategy": "flat"}).json()
            vm.append((r["no"], r["base_dist"], b.get("distance_m"), r["flat_dist"], f.get("distance_m"), b.get("avoided"), f.get("avoided")))
    except httpx.HTTPError as e:
        vm.append(("실패", type(e).__name__))
    with open(out / "summary.md", "a", encoding="utf-8") as f:
        f.write("\n## 배포 서버와 비교 (읽기 전용 5쌍: 쌍, 로컬 기본, VM 기본, 로컬 회피, VM 회피, VM avoided)\n\n")
        f.writelines(f"- {v}\n" for v in vm)
    print((out / "summary.md").read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

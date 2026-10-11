"""위험 구역 회피 검증 2 (실제 서비스 흐름): 수위계 모의값 → 판정 엔진 → 위험 영역 → 경로 API.

avoid_demo.py(검증 1)는 경로 서버 코드에 가상 원을 직접 넣었다. 이 스크립트는 서비스가 실제로 도는 길을 그대로 탄다.
  ① 수위계 6곳에 모의 관측값을 넣는다 (서비스의 시연 기능과 같은 방식 — server/risk/simulate.py INSERT_SQL, quality='simulated')
  ② 판정 엔진(risk.flood)이 침수 영역을 만든다 → GET /api/v1/risk/areas
  ③ 경로 서버가 그 영역을 읽을 때까지 기다린다 (60초 캐시 — 실제 동작 그대로) → GET /api/route/hazards
  ④ 앱이 부르는 것과 같은 POST /api/route 로 경로를 받아 판정한다
  ⑤ 같은 순간에 '가까운 경로'(strategy shortest — 위험 구역을 피하지 않는 최단)도 받아 나란히 비교한다 (검증 3, 2026-10-11)
켜기 = 주의(포항 DT 3등급, 반경 150m) · 관심 = 2등급(100m, 경로는 피하지 않아야 함) · 끄기 = 정상.
경보 이상은 쓰지 않는다 (대피 상황·대피 확인 창이 열린다).

실행 (route/ 폴더에서):
    .venv/bin/python scripts/avoid_live.py --target local --limit 2      # 로컬 서버로 스크립트 확인
    .venv/bin/python scripts/avoid_live.py --target vm                   # 배포 서버 (공개 주소 + ssh 주입)
    .venv/bin/python scripts/avoid_live.py --target vm --cleanup-only    # 모의값만 지우기
끝나면(실패·중단 때도) 서비스의 해제 기능 risk.simulate.apply("clear") 로 모의값을 지운다.
회차 = 출발·도착 3쌍 × 6회(5회는 최단 경로 위 구역을 하나 이상 켬, 1회는 경로 밖 구역만) + 경계 사례 2회 = 20회.
산출물: route/out/avoid_live_<seed>/ — trial_XX_a.png(최단 경로만)·trial_XX_b.png(안전 경로 겹침), contact_sheet.png, avoid.gif,
results.csv, results.md, results.json
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import math
import random
import subprocess
import sys
import time
from pathlib import Path

import httpx
from shapely.geometry import Point, shape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import avoid_demo as D  # noqa: E402 — 그림·GIF·좌표 변환을 그대로 쓴다

from guardian_route.hazards import Hazard, circle  # noqa: E402
from guardian_route.service import _line  # noqa: E402

REPO = D.ROOT.parent
VM = "jongyeonkim@34.64.177.195"
TARGETS = {
    "local": {"api": "http://localhost:8000", "route": "http://localhost:8002",
              "exec": ["docker", "compose", "exec", "-T", "api", "python", "-"], "cwd": str(REPO)},
    "vm": {"api": "https://34-64-177-195.nip.io", "route": "https://34-64-177-195.nip.io",
           "exec": ["ssh", "-o", "BatchMode=yes", VM,
                    "cd ~/guryongpo-safety-agent && docker compose -f docker-compose.yml exec -T api python -"], "cwd": None},
}

# 구역 = 포항 DT 수위계 (external_id, 이름, lat, lon, metric). 좌표는 서버 stations 표와 같다
STATIONS = [
    ("Z1", "1", "구룡포교 하천", 35.98724, 129.55047, "river_level"),
    ("Z2", "7", "하나과메기", 35.98612, 129.54925, "flood_depth"),
    ("Z3", "8", "구룡포파출소", 35.98870, 129.55306, "flood_depth"),
    ("Z4", "9", "해양경찰서", 35.98947, 129.55465, "flood_depth"),
    ("Z5", "10", "구룡포환승센터", 35.99069, 129.55606, "flood_depth"),
    ("Z6", "11", "구룡포수협", 35.99111, 129.55735, "flood_depth"),
]
# 상태 → (값, 포항 DT 등급). 지표면 침수심 170mm = 기준 9번(>=150mm)·22번(3등급) 모두 주의
VALUES = {"flood_depth": {"on": (170, 3), "watch": (60, 2), "off": (0, 1)},
          "river_level": {"on": (1850, 3), "watch": (1500, 2), "off": (900, 1)}}
ON_RADIUS_M, WATCH_RADIUS_M = 150, 100
END_CLEAR_M = 180              # 출발·도착은 모든 수위계에서 이만큼 떨어진 곳 (주의 영역 150m 밖)

PAIRS = [
    ("시가지 남북 횡단", (35.9945, 129.5525), (35.9830, 129.5505)),
    ("남쪽 → 서쪽 언덕", (35.9800, 129.5600), (35.9950, 129.5450)),
    ("항구 동쪽 → 읍사무소 서쪽", (35.9925, 129.5600), (35.9850, 129.5440)),
]
BOUNDARIES = [
    ("구룡포항 → 실내체육관 부근", (35.9905, 129.5560), (35.9868, 129.5480), ["Z5", "Z3"]),   # 출발지가 Z5 안
    ("시가지 북쪽 → 구룡포교", (35.9945, 129.5525), (35.9873, 129.5506), ["Z1", "Z4"]),        # 도착지가 Z1 안
]
TRIALS_PER_PAIR = 6            # 마지막 1회는 경로 밖 구역만 켜는 대조 회차
MAX_ON = 4                     # 한 회차에 켜는 구역 수 (많이 켜면 구역이 이어져 15km대 우회만 남는다)
LONG_DETOUR_M = 5000           # 이보다 길게 돌면 표에 따로 표시 (실패는 아님)

# api 컨테이너 안에서 도는 코드: 모의값을 넣고 침수 판정만 다시 돌린다 (선제 경고 작업은 서버 일정대로 — 여기서 부르지 않는다)
INJECT = r'''
import base64, json, sys
from datetime import datetime, timedelta
from app import db
from risk import simulate as sim
from collector import jobs
from app.config import settings
db.init_pool(settings.database_url, max_size=2)
arg = json.loads(base64.b64decode(sys.argv[1]))
if arg.get("clear"):
    out = sim.apply("clear"); db.close_pool(); print(json.dumps(out, default=str)); raise SystemExit
now = datetime.now(sim.KST).replace(microsecond=0)
t = (now if now.second else now + timedelta(seconds=1)).isoformat()
rows = [{**r, "unit": sim.UNITS[r["metric"]], "observed_at": t} for r in arg["rows"]]
n = db.execute_many(sim.INSERT_SQL, rows)
res = jobs.execute(jobs.BY_KEY["risk.flood"])
db.close_pool()
print(json.dumps({"observations": n, "risk_run": res.get("status"), "assessments": res.get("rows")}, default=str))
'''


def dist_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot((a[0] - b[0]) * D.M_PER_DEG_LAT, (a[1] - b[1]) * D.M_PER_DEG_LON)


class Live:
    def __init__(self, target: str) -> None:
        self.t = TARGETS[target]
        self.http = httpx.Client(timeout=20.0, transport=httpx.HTTPTransport(retries=3))

    def exec(self, arg: dict) -> dict:
        cmd = [*self.t["exec"][:-1], self.t["exec"][-1] + " " + base64.b64encode(json.dumps(arg).encode()).decode()] \
            if self.t["exec"][0] == "ssh" else [*self.t["exec"], base64.b64encode(json.dumps(arg).encode()).decode()]
        # 네트워크가 잠깐 끊겨도(ssh 'Network is unreachable') 모의값이 서버에 남지 않게 여러 번 다시 시도한다
        err = ""
        for attempt in range(8):
            try:
                out = subprocess.run(cmd, input=INJECT, capture_output=True, text=True, cwd=self.t["cwd"], timeout=120)
                if out.returncode == 0:
                    return json.loads(out.stdout.strip().splitlines()[-1])
                err = out.stderr.strip()[-400:]
            except subprocess.TimeoutExpired:
                err = "시간 초과"
            time.sleep(5 + 5 * attempt)
        raise RuntimeError(f"주입 실패: {err}")

    def set_states(self, states: dict[str, str]) -> dict:
        rows = []
        for name, ext, _, _, _, metric in STATIONS:
            value, grade = VALUES[metric][states.get(name, "off")]
            rows.append({"external_id": ext, "metric": metric, "value": value, "source_level": grade})
        return self.exec({"rows": rows})

    def clear(self) -> dict:
        return self.exec({"clear": True})

    def _call(self, method: str, url: str, **kw) -> httpx.Response:
        """네트워크가 잠깐 끊기면 다시 시도 (맥 네트워크가 흔들린 적이 있다 — 'Can't assign requested address')"""
        for attempt in range(6):
            try:
                res = self.http.request(method, url, **kw)
                res.raise_for_status()
                return res
            except httpx.TransportError:
                if attempt == 5:
                    raise
                time.sleep(3 + 3 * attempt)
        raise AssertionError

    def engine_areas(self) -> list[dict]:
        return self._call("GET", self.t["api"] + "/api/v1/risk/areas").json()["features"]

    def route_hazards(self) -> list[dict]:
        return self._call("GET", self.t["route"] + "/api/route/hazards").json()["features"]

    def route(self, o: tuple[float, float], d: tuple[float, float], strategy: str | None = None) -> tuple[dict, int]:
        body = {"origin": {"lat": o[0], "lon": o[1]}, "destination": {"lat": d[0], "lon": d[1]}}
        if strategy:
            body["strategy"] = strategy
        self._call("POST", self.t["route"] + "/api/route", json=body)          # 연결을 먼저 열어 둔다 (응답 시간에 TLS 연결 시간이 섞이지 않게)
        t0 = time.perf_counter()
        res = self._call("POST", self.t["route"] + "/api/route", json=body)
        return res.json(), round((time.perf_counter() - t0) * 1000)


def station_of(geom) -> str | None:
    """영역 도형 → 구역 이름 (영역 중심에서 30m 안의 수위계)"""
    c = geom.centroid
    for name, _, _, lat, lon, _ in STATIONS:
        if dist_m((c.y, c.x), (lat, lon)) < 30:
            return name
    return None


def wait_route_hazards(live: Live, want: set[str], timeout: float = 100.0) -> tuple[list[dict], float]:
    """경로 서버가 피하는 구역이 이번 조합이 될 때까지 (60초 캐시)"""
    t0 = time.monotonic()
    while True:
        feats = live.route_hazards()
        got = {station_of(shape(f["geometry"])) for f in feats if f["properties"].get("kind", "flood") == "flood"}
        if got == want:
            return feats, time.monotonic() - t0
        if time.monotonic() - t0 > timeout:
            raise RuntimeError(f"경로 서버 위험 구역이 기대와 다름: 기대 {sorted(want)} 실제 {sorted(map(str, got))}")
        time.sleep(4)


def run_trial(live: Live, t: D.Trial, watch: str | None) -> dict:
    states = {n: "on" for n in t.on}
    if watch:
        states[watch] = "watch"
    inj = live.set_states(states)
    feats, waited = wait_route_hazards(live, set(t.on))
    engine = live.engine_areas()
    res, ms = live.route(t.origin, t.dest)
    short, _ = live.route(t.origin, t.dest, "shortest")     # 같은 위험 영역에서 '가까운 경로' (회피 안 함)
    t.gh_ms = ms
    t.safe_geom, t.dist, t.dur = res["geometry"], res["distance_m"], res["duration_s"]

    # 구역 도형 = 서비스가 돌려준 실제 영역 (경로 서버 목록 기준). 끈 곳·관심 단계는 그림용 점선 원
    geom_of = {station_of(shape(f["geometry"])): shape(f["geometry"]) for f in feats}
    id_to_name = {str(f.get("id") or f["properties"].get("id")): station_of(shape(f["geometry"])) for f in feats}
    zones = []
    for name, _, label, lat, lon, _ in STATIONS:
        if name in t.on:
            g, zname, r = geom_of[name], name, ON_RADIUS_M
            if g.geom_type != "Polygon":          # 서버는 MultiPolygon으로 준다 — 그림에는 가장 큰 조각(판정은 원래 도형으로)
                g = max(g.geoms, key=lambda x: x.area)
        elif name == watch:
            g, zname, r = circle(lat, lon, WATCH_RADIUS_M, sides=24), f"{name}\n관심", WATCH_RADIUS_M
        else:
            g, zname, r = circle(lat, lon, ON_RADIUS_M, sides=24), name, ON_RADIUS_M
        zones.append(D.Zone(zname, Hazard(f"live-{name}", "flood", g, source="risk_engine"), True, (lat, lon), r))
    t.zones = zones
    t.avoided = sorted(filter(None, (id_to_name.get(i) for i in res.get("avoided", []))))
    t.still_inside = sorted(filter(None, (id_to_name.get(i) for i in res.get("still_inside", []))))
    unknown = [i for i in [*res.get("avoided", []), *res.get("still_inside", [])] if i not in id_to_name]

    safe, base = _line(res["geometry"]), _line(t.base_geom)
    crossing = sorted(n for n in t.on if safe.intersects(geom_of[n]))
    ok1 = set(crossing) <= set(t.still_inside) and (t.boundary or not t.still_inside)
    if not ok1:
        t.notes.append(f"① 켜진 구역 통과 {crossing}, still_inside {t.still_inside}")
    expect = sorted({n for n in t.on if base.intersects(geom_of[n])} - set(t.still_inside))
    ok2 = expect == t.avoided and not unknown
    if not ok2:
        t.notes.append(f"② avoided 기대 {expect} ≠ 응답 {t.avoided}" + (f" (모르는 id {unknown})" if unknown else ""))
    ok3 = True
    if not any(base.intersects(geom_of[n]) for n in t.on):
        ok3 = res["geometry"] == t.base_geom
        t.notes.append("③ 켜진 구역이 모두 경로 밖 → 기본 경로 유지" if ok3
                       else f"③ 켜진 구역이 경로 밖인데 경로가 바뀜 ({t.base_dist}m → {t.dist}m)")
    # ④ 판정 엔진 영역과 경로 서버 목록이 이어져 있는가
    eng = {station_of(shape(f["geometry"])): f["properties"].get("level") for f in engine if f["properties"].get("hazard") == "flood"}
    eng_on = {n for n, lv in eng.items() if lv in ("advisory", "warning", "critical")}
    ok4 = eng_on == set(t.on) and (watch is None or eng.get(watch) == "watch") and res.get("hazards_ok", True)
    if not ok4:
        t.notes.append(f"④ 판정 엔진 영역 {eng} ≠ 기대 (켜짐 {t.on}, 관심 {watch})")
    watch_on_base = bool(watch) and base.intersects(next(z.hazard.geometry for z in zones if z.name.startswith(watch)))
    if watch_on_base:
        t.notes.append(f"관심 단계 {watch}가 기본 경로 위 — 피하지 않음")
    if t.boundary:
        t.notes.append("경계 사례: 출발지·도착지가 구역 안 → 막히지 않고 still_inside로 알림")
    # ⑤ 가까운 경로: 피한 구역 없음, 지나는 켜진 구역을 still_inside로 그대로 알림, 구역이 생겨도 경로는 평시와 같음
    sline = _line(short["geometry"])
    t.short_geom, t.short_dist = short["geometry"], short["distance_m"]
    t.short_cross = sorted(n for n in t.on if sline.intersects(geom_of[n]))
    short_inside = sorted(filter(None, (id_to_name.get(i) for i in short.get("still_inside", []))))
    ok5 = not short.get("avoided") and short_inside == t.short_cross and short["geometry"] == t.short_peace
    if not ok5:
        t.notes.append(f"⑤ 가까운 경로: 지나는 구역 {t.short_cross}, still_inside {short_inside}, avoided {short.get('avoided')}, "
                       f"평시와 같은 경로 {short['geometry'] == t.short_peace}")
    # ⑥ 가까운 경로가 켜진 구역을 지나면 안전 경로는 그 구역을 지나지 않는 다른 경로여야 한다 (경계 사례 = 피할 수 없는 구역은 빼고)
    must_differ = [n for n in t.short_cross if n not in t.still_inside]
    ok6 = not must_differ or (res["geometry"] != short["geometry"] and not set(must_differ) & set(crossing))
    if not ok6:
        t.notes.append(f"⑥ 가까운 경로가 {must_differ}를 지나는데 안전 경로가 같거나 그 구역을 지남")
    if t.short_cross and t.dist - t.short_dist > LONG_DETOUR_M:
        t.notes.append(f"긴 우회 (+{t.dist - t.short_dist:,}m)")
    t.passed = ok1 and ok2 and ok3 and ok4 and ok5 and ok6
    return {"watch": watch, "waited_s": round(waited, 1), "inject": inj, "engine": eng, "watch_on_base": watch_on_base,
            "checks": [ok1, ok2, ok3, ok4, ok5, ok6]}


def draw_compare(t: D.Trial, roads: list, total: int, path: Path, with_safe: bool) -> None:
    """한 회차 그림. with_safe=False = (가) 가까운 경로만, True = (나) 안전 경로를 겹침. 두 장의 지도 범위는 같다."""
    short, safe = _line(t.short_geom), _line(t.safe_geom)
    xs = [x for g in (short, safe) for x, _ in g.coords] + [z.center[1] for z in t.zones] + [t.origin[1], t.dest[1]]
    ys = [y for g in (short, safe) for _, y in g.coords] + [z.center[0] for z in t.zones] + [t.origin[0], t.dest[0]]
    pad = 0.0018
    x0, x1, y0, y1 = min(xs) - pad, max(xs) + pad, min(ys) - pad, max(ys) + pad

    fig, ax = D.plt.subplots(figsize=(8, 8.8), dpi=110)
    for pts, kind in roads:
        if any(x0 <= x <= x1 and y0 <= y <= y1 for x, y in pts):
            lx, ly = zip(*pts)
            ax.plot(lx, ly, color="#b9b9b9" if kind in D.MAJOR else "#dcdcdc", lw=1.6 if kind in D.MAJOR else 0.9, zorder=1)
    for z in t.zones:
        gx, gy = z.hazard.geometry.exterior.xy
        if z.name in t.on:
            hit = z.name in t.short_cross          # 가까운 경로가 지나는 구역은 진하게
            ax.fill(gx, gy, color="#e5484d", alpha=0.5 if hit else 0.22, zorder=2)
            ax.plot(gx, gy, color="#e5484d", lw=2.2 if hit else 1.4, zorder=2)
        else:
            ax.plot(gx, gy, color="#8a8a8a", lw=1.2, ls=(0, (3, 3)), zorder=2)
        ax.text(z.center[1], z.center[0], z.name, ha="center", va="center", fontsize=9,
                color="#a01c20" if z.name in t.on else "#6b6b6b", fontweight="bold", zorder=7)
    kx, ky = short.xy
    ax.plot(kx, ky, color="#111111", lw=2.6 if not with_safe else 2.0, ls=(0, (4, 2.5)), zorder=5)
    if with_safe:
        sx, sy = safe.xy
        ax.plot(sx, sy, color="#1f6feb", lw=4.0, alpha=0.9, zorder=4, solid_capstyle="round")
    ax.plot(t.origin[1], t.origin[0], "o", ms=11, color="#1f9d55", mec="white", mew=1.5, zorder=8)
    ax.plot(t.dest[1], t.dest[0], "*", ms=17, color="#d97a00", mec="white", mew=1.2, zorder=8)

    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_aspect(1 / math.cos(math.radians(D.LAT0)))
    ax.set_xticks([])
    ax.set_yticks([])
    for s in ax.spines.values():
        s.set_color("#dddddd")
    head = f"회차 {t.no}/{total} · {t.pair}" + (" · 경계 사례" if t.boundary else "") + f" · 수위계 주의 {', '.join(t.on)}\n"
    if with_safe:
        diff = t.dist - t.short_dist
        same = t.safe_geom == t.short_geom
        line = (f"② 안전한 경로 {t.dist:,}m ({diff:+,}m)" + (" · 가까운 경로와 같음" if same else "")
                + f" · 피한 구역 {', '.join(t.avoided) or '없음'}"
                + (f" · 못 피함 {', '.join(t.still_inside)}" if t.still_inside else "")
                + f" · 판정 {'통과' if t.passed else '실패'}")
    else:
        line = f"① 가까운 경로(회피 안 함) {t.short_dist:,}m · 지나는 위험 구역 {', '.join(t.short_cross) or '없음'}"
    ax.set_title(head + line, fontsize=11, loc="left", color="#1d1d1f")
    ax.legend(handles=[
        D.Line2D([], [], color="#111111", lw=2.2, ls=(0, (4, 2.5)), label="가까운 경로 (회피 안 함)"),
        D.Line2D([], [], color="#1f6feb", lw=4.0, label="안전한 경로 (위험 구역 회피)"),
        D.Patch(facecolor="#e5484d", alpha=0.5, edgecolor="#e5484d", label="위험 구역 — 가까운 경로가 지남"),
        D.Patch(facecolor="#e5484d", alpha=0.22, edgecolor="#e5484d", label="위험 구역 (주의)"),
        D.Line2D([], [], color="#8a8a8a", lw=1.2, ls=(0, (3, 3)), label="평시·관심 단계 (피하지 않음)"),
        D.Line2D([], [], marker="o", color="w", markerfacecolor="#1f9d55", ms=10, label="출발"),
        D.Line2D([], [], marker="*", color="w", markerfacecolor="#d97a00", ms=14, label="도착"),
    ], loc="upper center", bbox_to_anchor=(0.5, -0.01), ncol=3, fontsize=8.5, frameon=False)
    fig.tight_layout()
    fig.savefig(path)
    D.plt.close(fig)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=list(TARGETS), required=True)
    ap.add_argument("--seed", type=int, default=20261012)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--limit", type=int, default=0, help="앞에서 N회차만 (스크립트 확인용)")
    ap.add_argument("--cleanup-only", action="store_true")
    ap.add_argument("--keep", default="", help="끝난 뒤 지우지 않고 이 구역들을 켜 둔다 (앱 화면 확인용, 예: Z3,Z4)")
    a = ap.parse_args()
    live = Live(a.target)
    if a.cleanup_only:
        print("해제:", live.clear())
        return 0
    out = a.out or D.ROOT / "out" / f"avoid_live_{a.seed}"
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(a.seed)

    for name, o, d in PAIRS:                       # 출발·도착이 주의 영역(150m) 밖인지
        for z, _, label, lat, lon, _ in STATIONS:
            for end, p in (("출발", o), ("도착", d)):
                if dist_m(p, (lat, lon)) < END_CLEAR_M:
                    raise SystemExit(f"{name} {end}이 {z} {label}에서 {dist_m(p, (lat, lon)):.0f}m — {END_CLEAR_M}m 넘게 떨어져야 함")
    if any(f["properties"].get("simulated") for f in live.engine_areas()):
        raise SystemExit("시작 전에 모의값이 이미 있음 — 먼저 --cleanup-only")
    wait_route_hazards(live, set())                # 경로 서버 캐시(60초)가 비워질 때까지
    if live.route_hazards():
        raise SystemExit("시작 전에 경로 서버가 피하는 구역이 이미 있음 (실제 위험 상황일 수 있음) — 중단")

    trials: list[D.Trial] = []
    watches: list[str | None] = []
    names = [s[0] for s in STATIONS]
    rings = {s[0]: circle(s[3], s[4], ON_RADIUS_M, sides=48) for s in STATIONS}
    station_pts = {s[0]: Point(s[4], s[3]) for s in STATIONS}

    def add(pname, o, d, on, base, short0, watch, boundary=False) -> None:
        t = D.Trial(len(trials) + 1, pname, o, d, [], list(on), base["geometry"], base["distance_m"], boundary=boundary)
        t.short_peace = short0["geometry"]            # 평시의 가까운 경로 (⑤: 구역이 생겨도 같아야 한다)
        trials.append(t)
        watches.append(watch)

    for pname, o, d in PAIRS:
        base, _ = live.route(o, d)
        short0, _ = live.route(o, d, "shortest")
        short_line = _line(short0["geometry"])
        lines_m = [D.to_m_line(_line(base["geometry"])), D.to_m_line(short_line)]
        on_short = [n for n in names if short_line.intersects(rings[n])]      # 가까운 경로가 지나는 구역
        on_base = [n for n in names if _line(base["geometry"]).intersects(rings[n])]   # 평시 안전 경로가 지나는 구역

        def off_route(n: str) -> bool:
            x, y = D.to_m(station_pts[n].x, station_pts[n].y)
            return all(ln.distance(Point(x, y)) > ON_RADIUS_M + 20 for ln in lines_m)
        far = [n for n in names if off_route(n)]
        seen: set[tuple[str, ...]] = set()
        for i in range(TRIALS_PER_PAIR):
            control = i == TRIALS_PER_PAIR - 1 and bool(far)
            for _ in range(200):
                if control:                       # 대조: 경로 밖 구역만 → 경로가 그대로여야 한다 (③)
                    on = tuple(sorted(rng.sample(far, min(len(far), rng.randint(1, 2)))))
                else:
                    # 가까운 경로 위 구역 하나(→ 가까운 경로는 위험 구역을 지난다) + 평시 안전 경로 위 구역 하나(→ 실제로 회피가 일어난다).
                    # 두 경로는 평시에도 다를 수 있어서, 한쪽만 켜면 '원래 다른 길'일 뿐 회피를 보여 주지 못한다
                    must = [rng.choice(on_short)] if on_short else []
                    if on_base and not set(must) & set(on_base):
                        must.append(rng.choice(on_base))
                    rest = [n for n in names if n not in must]
                    on = tuple(sorted(must + rng.sample(rest, rng.randint(max(1, len(must)), MAX_ON) - len(must))))
                if on and on not in seen:
                    break
            seen.add(on)
            off = [n for n in names if n not in on]
            add(pname, o, d, on, base, short0, rng.choice(off) if off else None)
    for bname, bo, bd, bon in BOUNDARIES:
        bbase, _ = live.route(bo, bd)
        bshort, _ = live.route(bo, bd, "shortest")
        add(bname, bo, bd, bon, bbase, bshort, None, boundary=True)
    if a.limit:
        trials, watches = trials[:a.limit], watches[:a.limit]

    extra: list[dict] = []
    try:
        for t, w in zip(trials, watches):
            info = run_trial(live, t, w)
            extra.append(info)
            print(f"회차 {t.no:2d} [{'통과' if t.passed else '실패'}] {t.pair} 켜짐 {t.on} 관심 {w} → {t.dist}m "
                  f"({t.dist - t.base_dist:+}m) 피함 {t.avoided} 못 피함 {t.still_inside} {t.gh_ms}ms 대기 {info['waited_s']}s "
                  + " / ".join(t.notes), flush=True)
    finally:
        keep = [k for k in a.keep.split(",") if k]
        if keep and len(extra) == len(trials):
            print("앱 화면용으로 켜 둠:", keep, live.set_states({k: "on" for k in keep}))
        else:
            print("해제:", live.clear())

    done = trials[:len(extra)]
    lons = [x for t in done for g in (t.short_geom, t.safe_geom) for x, _ in _line(g).coords]
    lats = [y for t in done for g in (t.short_geom, t.safe_geom) for _, y in _line(g).coords]
    roads = D.load_roads((min(lons) - 0.01, min(lats) - 0.01, max(lons) + 0.01, max(lats) + 0.01))
    frames, finals = [], []
    for t in done:
        pa, pb = out / f"trial_{t.no:02d}_a.png", out / f"trial_{t.no:02d}_b.png"
        draw_compare(t, roads, len(trials), pa, with_safe=False)
        draw_compare(t, roads, len(trials), pb, with_safe=True)
        frames += [pa, pb, pb]                     # 안전 경로가 겹친 장을 두 배 길게 보여 준다
        finals.append(pb)
    D.contact_sheet(finals, out / "contact_sheet.png", cols=5)
    D.gif(frames, out / "avoid.gif", ms=1100)

    rows = [{"no": t.no, "pair": t.pair, "on": t.on, "watch": e["watch"], "base": t.base_dist, "short": t.short_dist,
             "short_cross": t.short_cross, "dist": t.dist, "dur": t.dur,
             "avoided": t.avoided, "still_inside": t.still_inside, "ms": t.gh_ms, "waited_s": e["waited_s"],
             "passed": t.passed, "boundary": t.boundary, "notes": t.notes, "watch_on_base": e["watch_on_base"],
             "checks": e["checks"]} for t, e in zip(done, extra)]
    (out / "results.json").write_text(json.dumps({"seed": a.seed, "target": a.target, "trials": rows}, ensure_ascii=False, indent=1),
                                      encoding="utf-8")
    with open(out / "results.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["회차", "출발→도착", "켜진 구역", "관심 구역", "가까운 경로(m)", "가까운 경로가 지난 구역", "안전 경로(m)", "증가(m)",
                    "피한 구역", "못 피한 구역", "응답(ms)", "판정", "비고"])
        for r in rows:
            w.writerow([r["no"], r["pair"], " ".join(r["on"]), r["watch"] or "", r["short"], " ".join(r["short_cross"]),
                        r["dist"], r["dist"] - r["short"],
                        " ".join(r["avoided"]), " ".join(r["still_inside"]), r["ms"], "통과" if r["passed"] else "실패",
                        " / ".join(r["notes"])])
    passed = sum(r["passed"] for r in rows)
    detours = sorted(r["dist"] - r["short"] for r in rows if r["short_cross"] and not r["boundary"])
    lines = [f"# 위험 구역 회피 검증 3 — 가까운 경로(회피 안 함)와 비교 ({a.target}, seed {a.seed})", "",
             f"- 판정: **{passed}/{len(rows)} 통과**",
             f"- 가까운 경로가 위험 구역을 지난 회차 {len(detours)}건 — 안전 경로의 추가 거리 중앙값 "
             f"{detours[len(detours) // 2] if detours else 0:,}m (최소 {detours[0] if detours else 0:,} · 최대 {detours[-1] if detours else 0:,})",
             f"- 경로 API 응답 평균 {sum(r['ms'] for r in rows) / max(1, len(rows)):.0f}ms", "",
             "| 회차 | 출발→도착 | 켜진 구역 | 관심 | 가까운 경로가 지난 구역 | 가까운 → 안전 (m) | 피함 | 못 피함 | 판정 |",
             "|---|---|---|---|---|---|---|---|---|"]
    lines += [f"| {r['no']} | {r['pair']} | {', '.join(r['on'])} | {r['watch'] or '-'} | {', '.join(r['short_cross']) or '-'} | "
              f"{r['short']:,} → {r['dist']:,} "
              f"({r['dist'] - r['short']:+,}) | {', '.join(r['avoided']) or '-'} | {', '.join(r['still_inside']) or '-'} | "
              f"{'통과' if r['passed'] else '실패'} |" for r in rows]
    (out / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n판정 {passed}/{len(rows)} 통과 · 산출물 {out}")
    return 0 if passed == len(rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())

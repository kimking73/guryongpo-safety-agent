"""침수 · 강우(포항 DT) 판정 — A3

입력 : 포항 DT 수위계·강우량계 최신 관측값 (수집 시각 40분 이내, 모의값은 6시간 이내 우선)
기준 : risk_rules (코드에 숫자를 두지 않고 DB 기준을 읽어 적용 → Agent 가 같은 기준을 근거로 인용)
  9번     flood advisory  지표면 수위계(road_flood) 침수심 flood_depth >= 150mm, 반경 150m
  21~24번 flood watch~critical  맨홀·지표면·하천 수위계 포항 DT 등급 2~5, 반경 100/150/300/500m
  25~28번 heavy_rain watch~critical  강우량계 포항 DT 등급 2~5 → 구룡포읍 전체
출력 : risk_assessments — 관측소×재난마다 현재 유효한 행 1개 (valid_to IS NULL)
  같은 판정(단계·기준)이 이어지면 같은 행을 갱신 → area_id 가 바뀌지 않아 경고 중복 발송을 막기 쉬움 (A5)
  단계가 바뀌면 이전 행을 닫고(valid_to) 새 행, 정상으로 돌아오면 닫기만 함
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from app import db
from .levels import DT_LEVEL_KO, GURYONGPO_CENTER, GURYONGPO_RADIUS_M, HAZARD_KO, LEVEL_NUM

log = logging.getLogger("risk")
KST = timezone(timedelta(hours=9))
ENGINE = "flood_v1"
HAZARDS = ["flood", "heavy_rain"]
KINDS = ["manhole", "road_flood", "river_level", "rain_gauge"]
PRIMARY_METRIC = {"manhole": "manhole_level", "road_flood": "flood_depth", "river_level": "river_level", "rain_gauge": "rain_1h"}
MAX_AGE_MIN = 40          # 10분 주기 수집 → 3회 연속 실패하면 판정에서 빠짐 (/health 도 degraded) — risk/freshness.VALID_MIN 과 같은 값
SIM_MAX_AGE_MIN = 360     # 시연용 모의값은 6시간 동안 실측보다 우선


# ------------------------------------------------------------------ 입력
LATEST_SQL = """
SELECT DISTINCT ON (o.station_id, o.metric)
       s.id AS station_id, s.external_id, s.name, s.kind, ST_X(s.geom) AS lng, ST_Y(s.geom) AS lat,
       o.metric, o.value, o.unit, o.source_level, o.observed_at, (o.quality IS NOT DISTINCT FROM 'simulated') AS simulated
FROM observations o
JOIN stations s ON s.id = o.station_id
WHERE s.is_active AND s.source_code = 'pohang_dt' AND s.kind = ANY(%(kinds)s)
  AND ((o.quality IS DISTINCT FROM 'simulated' AND o.observed_at >= now() - make_interval(mins => %(max_age)s))
    OR (o.quality = 'simulated' AND o.observed_at >= now() - make_interval(mins => %(sim_age)s)))
ORDER BY o.station_id, o.metric, (o.quality IS NOT DISTINCT FROM 'simulated') DESC, o.observed_at DESC
"""

RULES_SQL = """
SELECT id, hazard::text AS hazard, level::text AS level, label, metric, operator, threshold, threshold_max, condition
FROM risk_rules WHERE is_active AND hazard::text = ANY(%(hazards)s) ORDER BY id
"""


@dataclass
class Result:
    key: str                      # 'station:<id>:<hazard>' — 같은 대상의 판정을 이어 붙이는 기준
    hazard: str
    level: str
    rule_id: int
    label: str
    reason: str
    lng: float                    # 영향 범위 중심
    lat: float
    buffer_m: float               # 영향 범위 반경
    observed_at: Optional[datetime]
    basis: dict = field(default_factory=dict)
    zone_id: Optional[int] = None  # 있으면 영향 범위 = hazard_zones(id) 폴리곤 그대로 (원 대신, 예: 산사태위험지도 100m 범위)


def _kinds(cond: dict) -> list[str]:
    k = cond.get("station_kind")
    return [k] if isinstance(k, str) else list(k or [])


def _cmp(v: float, op: str, t: float, t2: Optional[float]) -> bool:
    if op == "between":
        return t <= v <= (t2 if t2 is not None else float("inf"))
    return {">=": v >= t, ">": v > t, "<=": v <= t, "<": v < t}.get(op, False)


def _cond(rule: dict) -> dict:
    c = rule.get("condition") or {}
    return json.loads(c) if isinstance(c, str) else c


def _hhmm(t: Optional[datetime]) -> str:
    return t.astimezone(KST).strftime("%H:%M") if t else "-"


def _reason(obs: dict, rule: dict, threshold_hit: bool) -> str:
    name, kind, v, lv = obs["name"].replace("_", " "), obs["kind"], obs["value"], obs["source_level"]
    parts = []
    if kind == "road_flood":
        parts.append(f"{name} 침수심 {v:.0f}mm" + (f" (기준 {rule['threshold']:.0f}mm)" if threshold_hit else ""))
    elif kind == "river_level":
        parts.append(f"{name} 수위 {v:.0f}mm")
    elif kind == "rain_gauge":
        parts.append(f"{name} 시간당 {v:.1f}mm")
    else:
        parts.append(name)
    if lv:
        parts.append(f"포항 DT {int(lv)}단계({DT_LEVEL_KO.get(int(lv), '?')})")
    s = " · ".join(parts) + f" [{_hhmm(obs['observed_at'])} 수집]"
    return s + (" (모의)" if obs.get("simulated") else "")


def evaluate(latest: list[dict], rules: list[dict]) -> list[Result]:
    """순수 함수 — DB 없이 테스트 가능. 관측소마다 가장 높은 단계의 기준 1개를 고름"""
    by_station: dict[int, dict] = {}
    for o in latest:
        if o["metric"] == PRIMARY_METRIC.get(o["kind"]):
            by_station[o["station_id"]] = o
    out: list[Result] = []
    for sid, o in by_station.items():
        best: Optional[tuple[int, int, dict, bool]] = None      # (level_num, 우선순위, rule, threshold 기준 여부)
        for r in rules:
            c = _cond(r)
            if o["kind"] not in _kinds(c):
                continue
            hit, by_threshold = False, False
            sl = (c.get("source_level") or {}).get("=")
            if sl is not None:
                hit = o["source_level"] is not None and int(o["source_level"]) == int(sl)
            elif r.get("metric") == o["metric"] and r.get("operator") and r.get("threshold") is not None \
                    and o["value"] is not None and o["kind"] != "manhole":     # 맨홀 value 는 판단에 쓰지 않음
                hit = by_threshold = _cmp(float(o["value"]), r["operator"], float(r["threshold"]), r.get("threshold_max"))
            if not hit or r["level"] == "normal":
                continue
            # 같은 단계면 명시 기준(15cm 침수심)을 우선 — 근거 문장이 더 구체적
            cand = (LEVEL_NUM[r["level"]], 1 if by_threshold else 0, r, by_threshold)
            if best is None or cand[:2] > best[:2]:
                best = cand
        if best is None:
            continue
        _, _, r, by_threshold = best
        c = _cond(r)
        threshold_hit = by_threshold or (o["kind"] == "road_flood" and o["value"] is not None and any(
            rr.get("metric") == "flood_depth" and rr.get("threshold") is not None and float(o["value"]) >= float(rr["threshold"])
            for rr in rules))
        depth_rule = next((rr for rr in rules if rr.get("metric") == "flood_depth" and rr.get("threshold") is not None), r)
        if "buffer_m" in c:
            lng, lat, buf = o["lng"], o["lat"], float(c["buffer_m"])
        else:                                   # 강우량계: 구룡포읍 전체
            (lng, lat), buf = GURYONGPO_CENTER, float(GURYONGPO_RADIUS_M)
        out.append(Result(
            key=f"station:{sid}:{r['hazard']}", hazard=r["hazard"], level=r["level"], rule_id=r["id"],
            label=r["label"].split(" (")[0], reason=_reason(o, depth_rule if threshold_hit else r, threshold_hit),
            lng=lng, lat=lat, buffer_m=buf, observed_at=o["observed_at"],
            basis={"engine": ENGINE, "key": f"station:{sid}:{r['hazard']}", "station_id": sid,
                   "external_id": o["external_id"], "station_name": o["name"], "station_kind": o["kind"],
                   "station_lng": o["lng"], "station_lat": o["lat"], "metric": o["metric"], "value": o["value"],
                   "unit": o["unit"], "source_level": o["source_level"],
                   "observed_at": o["observed_at"].isoformat() if o["observed_at"] else None,
                   "simulated": bool(o.get("simulated")), "buffer_m": buf},
        ))
    return out


# ------------------------------------------------------------------ 저장 (risk_assessments 동기화)
AREA_SQL = "ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography, %(buffer_m)s)::geometry)"
INSERT_SQL = f"""
INSERT INTO risk_assessments (hazard, level, label, area, rule_id, basis, valid_from, computed_at)
VALUES (%(hazard)s, %(level)s, %(label)s, {AREA_SQL}, %(rule_id)s, %(basis)s::jsonb, now(), now())
RETURNING id
"""
INSERT_ZONE_SQL = """
INSERT INTO risk_assessments (hazard, level, label, area, rule_id, basis, valid_from, computed_at)
SELECT %(hazard)s, %(level)s, %(label)s, ST_Multi(z.geom), %(rule_id)s, %(basis)s::jsonb, now(), now()
FROM hazard_zones z WHERE z.id = %(zone_id)s
RETURNING id
"""
UPDATE_SQL = """
UPDATE risk_assessments SET label = %(label)s, basis = %(basis)s::jsonb, computed_at = now() WHERE id = %(id)s
"""
CLOSE_SQL = "UPDATE risk_assessments SET valid_to = now() WHERE id = ANY(%(ids)s)"
ACTIVE_SQL = """
SELECT id, hazard::text AS hazard, level::text AS level, rule_id, basis->>'key' AS key,
       (basis->>'station_id')::int AS station_id, computed_at < now() - make_interval(mins => %(keep_min)s) AS expired
FROM risk_assessments WHERE valid_to IS NULL AND basis->>'engine' = %(engine)s
ORDER BY id
"""
KEEP_UNSEEN_MIN = 180     # 수집이 끊긴 관측소의 위험 영역은 바로 지우지 않고 3시간 유지 (끊겼다고 '안전'으로 보이지 않게)


def sync(results: list[Result], seen_station_ids: set[int], engine: str = ENGINE) -> dict[str, int]:
    """판정 결과를 risk_assessments 에 반영. 반환: kept / opened / closed / held 개수
    seen_station_ids: 이번에 최신값이 있었던 관측소 — 여기 없는 관측소의 기존 영역은 KEEP_UNSEEN_MIN 동안 유지
    engine: 비교할 기존 판정의 basis.engine (hazards 는 hazards_v1 — 빠지면 기존 영역을 못 찾아 매번 새로 열고 닫지 못함)"""
    stats = {"kept": 0, "opened": 0, "closed": 0, "held": 0}
    with db.connection() as conn:
        active: dict = {}
        to_close: list[int] = []
        for r in conn.execute(ACTIVE_SQL, {"engine": engine, "keep_min": KEEP_UNSEEN_MIN}).fetchall():
            if r["key"] in active:                               # 같은 대상이 여러 행이면 최신 1개만 남김 (예전 중복 정리)
                to_close.append(active[r["key"]]["id"])
            active[r["key"]] = r
        for res in results:
            row = {"hazard": res.hazard, "level": res.level, "label": res.label, "rule_id": res.rule_id,
                   "lng": res.lng, "lat": res.lat, "buffer_m": res.buffer_m, "zone_id": res.zone_id,
                   "basis": json.dumps({**res.basis, "reason": res.reason}, ensure_ascii=False)}
            cur = active.pop(res.key, None)
            if cur and cur["level"] == res.level and cur["rule_id"] == res.rule_id:
                conn.execute(UPDATE_SQL, {**row, "id": cur["id"]})
                stats["kept"] += 1
                continue
            if cur:
                to_close.append(cur["id"])
            conn.execute(INSERT_ZONE_SQL if res.zone_id is not None else INSERT_SQL, row)
            stats["opened"] += 1
        for r in active.values():                                # 이번 판정에 없는 기존 영역
            if r["station_id"] in seen_station_ids or r["expired"]:
                to_close.append(r["id"])                         # 값이 정상으로 돌아왔거나 너무 오래됨
            else:
                stats["held"] += 1                               # 수집이 끊긴 관측소 → 유지
        if to_close:
            conn.execute(CLOSE_SQL, {"ids": to_close})
        stats["closed"] = len(to_close)
    return stats


def run(run_id: Optional[int] = None) -> int:
    """수집기 job 진입점 — 판정 1회. 반환: 현재 유효한 위험 영역 수"""
    latest = db.fetch_all(LATEST_SQL, {"kinds": KINDS, "max_age": MAX_AGE_MIN, "sim_age": SIM_MAX_AGE_MIN})
    rules = db.fetch_all(RULES_SQL, {"hazards": HAZARDS})
    results = evaluate(latest, rules)
    stats = sync(results, {o["station_id"] for o in latest})
    log.info("flood risk: stations=%d active=%d %s", len({o['station_id'] for o in latest}), len(results), stats)
    if not latest:
        # 40분 넘게 새 수위값이 없음 → 판정 불가. 기존 영역은 유지하고 실패로 기록 (/health 에 드러남)
        from collector.fetch import FetchError
        raise FetchError("판정할 최신 수위값 없음 (수집 중단 여부 확인)")
    return len(results)

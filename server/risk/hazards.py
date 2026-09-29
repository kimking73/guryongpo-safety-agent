"""호우·강풍·산사태 판정 — A4

입력
  호우 : 구룡포 AWS(816) rain_1h 스냅샷을 RAIN_SUM_SQL 로 3·12시간 누적 (judge_source 로 유효성 확인)
  강풍 : 구룡포 AWS(816) wind_speed·wind_gust 최신값
  산사태 : 이번 판정에서 나온 heavy_rain 단계 + hazard_zones(landslide) 488곳 중 구룡포 포함 전체

기준 : risk_rules 1~4(호우·강풍), 10~11(산사태) — 전부 기상청 발표기준을 그대로 우리 관측값에 적용한 것.
  강풍은 stations.is_mountain 으로 육상/산지 기준을 나눈다 (구룡포 AWS 는 해안 저지대 → 육상 기준)

산사태 표기 원칙 (2026-09-29 팀 결정)
  이건 토양수분을 실측/예측한 결과가 아니라 "호우 단계 + 이미 지정된 취약지역"이라는 대리 지표다.
  그래서 근거 문장에 "산사태가 발생함"처럼 확정된 사실인 것처럼 쓰지 않고, 대비가 필요한 가능성으로만 표기한다.

출력 : risk_assessments (engine='hazards_v1'). risk/engine.sync() 를 그대로 재사용 —
  basis.station_id 에 음수 sentinel(-1 호우, -2 강풍, -100-zone.id 산사태 지점)을 넣어 두면,
  이번 판정에 자료가 있었던 대상만 sync() 의 seen_station_ids 에 포함되어 "정상으로 복귀"가 즉시 반영되고,
  자료가 없어 판단을 못한 경우는 station_id 가 seen 에 없어 기존 판정이 3시간(KEEP_UNSEEN_MIN) 동안 유지된다
  (침수·강우와 같은 원칙: 판단 불가를 안전으로 보이게 하지 않음).
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from app import db
from risk import freshness
from risk.engine import Result, sync
from risk.levels import GURYONGPO_CENTER, GURYONGPO_RADIUS_M, LEVEL_NUM

log = logging.getLogger("risk.hazards")
KST = timezone(timedelta(hours=9))
ENGINE = "hazards_v1"
HAZARDS = ["heavy_rain", "strong_wind", "landslide"]
AWS_SOURCE, AWS_EXTERNAL_ID = "kma", "816"
STA_HEAVY_RAIN, STA_STRONG_WIND = -1, -2   # basis.station_id sentinel (실제 관측소 id 와 겹치지 않게 음수)


def _zone_sentinel(zone_id: int) -> int:
    return -100 - zone_id


def _op_hit(v: float, op: str, t: float) -> bool:
    return {">=": v >= t, ">": v > t, "<=": v <= t, "<": v < t}.get(op, False)


def _any_hit(cond_any: list[dict], values: dict[str, Optional[float]]) -> Optional[dict]:
    """condition["any"] 목록 중 하나라도 만족하면 그 조건을 반환 (근거 인용용)"""
    for c in cond_any:
        v = values.get(c["metric"])
        if v is not None and _op_hit(float(v), c["op"], float(c["value"])):
            return c
    return None


def _rules_by_hazard(rules: list[dict], hazard: str) -> list[dict]:
    return sorted((r for r in rules if r["hazard"] == hazard), key=lambda r: LEVEL_NUM[r["level"]], reverse=True)


def _cond(rule: dict) -> dict:
    c = rule.get("condition") or {}
    return json.loads(c) if isinstance(c, str) else c


def _hhmm(t: Optional[datetime]) -> str:
    return t.astimezone(KST).strftime("%H:%M") if t else "-"


def heavy_rain_level_ko(level: str) -> str:
    return {"watch": "관심", "advisory": "주의보", "warning": "경보", "critical": "심각"}.get(level, level)


# ------------------------------------------------------------------ 호우 (rules 1·2)
def evaluate_heavy_rain(rain_3h: Optional[float], rain_12h: Optional[float], observed_at: Optional[datetime],
                         rules: list[dict], simulated: bool = False) -> Optional[Result]:
    """구룡포 AWS 강우 합산값 → 호우 판정. 자료가 아예 없으면(rain_3h·rain_12h 모두 None) None (판단 불가)"""
    if rain_3h is None and rain_12h is None:
        return None
    values = {"rain_3h": rain_3h, "rain_12h": rain_12h}
    for r in _rules_by_hazard(rules, "heavy_rain"):           # 경보 → 주의보 순 (가장 높은 단계 먼저)
        hit = _any_hit(_cond(r).get("any", []), values)
        if hit:
            parts = []
            if rain_3h is not None:
                parts.append(f"최근 3시간 누적 강수 {rain_3h:.0f}mm")
            if rain_12h is not None:
                parts.append(f"12시간 누적 {rain_12h:.0f}mm")
            reason = "구룡포 AWS " + " · ".join(parts) + f" (기준 {hit['metric']} {hit['op']}{hit['value']:.0f}mm)" \
                     + f" [{_hhmm(observed_at)} 기준]" + (" (모의)" if simulated else "")
            return Result(
                key="heavy_rain:guryongpo", hazard="heavy_rain", level=r["level"], rule_id=r["id"],
                label=r["label"], reason=reason, lng=GURYONGPO_CENTER[0], lat=GURYONGPO_CENTER[1],
                buffer_m=GURYONGPO_RADIUS_M, observed_at=observed_at,
                basis={"engine": ENGINE, "key": "heavy_rain:guryongpo", "station_id": STA_HEAVY_RAIN,
                       "source": f"{AWS_SOURCE}:{AWS_EXTERNAL_ID}", "rain_3h": rain_3h, "rain_12h": rain_12h,
                       "observed_at": observed_at.isoformat() if observed_at else None, "simulated": simulated},
            )
    return None   # 자료는 있지만 기준 미만 → 정상 (호출 측이 seen 에 포함시켜 기존 판정을 닫음)


# ------------------------------------------------------------------ 강풍 (rules 3·4)
def evaluate_strong_wind(wind_speed: Optional[float], wind_gust: Optional[float], is_mountain: bool,
                          observed_at: Optional[datetime], rules: list[dict],
                          simulated: bool = False) -> Optional[Result]:
    if wind_speed is None and wind_gust is None:
        return None
    values = {"wind_speed": wind_speed, "wind_gust": wind_gust}
    branch = "mountain" if is_mountain else "land"
    for r in _rules_by_hazard(rules, "strong_wind"):
        hit = _any_hit(_cond(r).get(branch, {}).get("any", []), values)
        if hit:
            parts = []
            if wind_speed is not None:
                parts.append(f"평균풍속 {wind_speed:.1f}m/s")
            if wind_gust is not None:
                parts.append(f"순간풍속 {wind_gust:.1f}m/s")
            reason = "구룡포 AWS " + " · ".join(parts) + f" (기준 {hit['metric']} {hit['op']}{hit['value']:.0f}m/s, {branch})" \
                     + f" [{_hhmm(observed_at)} 기준]" + (" (모의)" if simulated else "")
            return Result(
                key="strong_wind:guryongpo", hazard="strong_wind", level=r["level"], rule_id=r["id"],
                label=r["label"], reason=reason, lng=GURYONGPO_CENTER[0], lat=GURYONGPO_CENTER[1],
                buffer_m=GURYONGPO_RADIUS_M, observed_at=observed_at,
                basis={"engine": ENGINE, "key": "strong_wind:guryongpo", "station_id": STA_STRONG_WIND,
                       "source": f"{AWS_SOURCE}:{AWS_EXTERNAL_ID}", "wind_speed": wind_speed, "wind_gust": wind_gust,
                       "is_mountain": is_mountain, "observed_at": observed_at.isoformat() if observed_at else None,
                       "simulated": simulated},
            )
    return None


# ------------------------------------------------------------------ 산사태 (rules 10·11)
def evaluate_landslide(heavy_rain_level: Optional[str], zones: list[dict], rules: list[dict]) -> list[Result]:
    """heavy_rain_level=None 이면 호우 판정 자체가 불가한 상태 → 산사태도 판단 불가로 보고 빈 목록 반환"""
    if heavy_rain_level is None:
        return []
    r10 = next((r for r in rules if r["id"] == 10), None)   # advisory, buffer 100m
    r11 = next((r for r in rules if r["id"] == 11), None)   # warning, buffer 0m (지역 안)
    lvl = LEVEL_NUM.get(heavy_rain_level, 0)
    out: list[Result] = []
    for z in zones:
        rule = None
        if r11 and lvl >= LEVEL_NUM["warning"]:
            rule = r11
        elif r10 and lvl >= LEVEL_NUM["advisory"]:
            rule = r10
        if rule is None:
            continue
        cond = _cond(rule)
        within = next((c for c in cond.get("all", []) if "within" in c), {})
        buffer_m = float(within.get("buffer_m", 0))
        emd = (z.get("meta") or {}).get("emd", "")
        reason = (f"{z['name']}{'(' + emd + ')' if emd else ''} 산사태 취약지역 지정 · 현재 호우 {heavy_rain_level_ko(heavy_rain_level)} 수준 강우"
                  " · 산사태 발생 가능성에 대비가 필요합니다 (실제 발생을 뜻하지 않음)")
        out.append(Result(
            key=f"landslide:zone:{z['id']}", hazard="landslide", level=rule["level"], rule_id=rule["id"],
            label=rule["label"], reason=reason, lng=z["lng"], lat=z["lat"], buffer_m=buffer_m,
            observed_at=None,
            basis={"engine": ENGINE, "key": f"landslide:zone:{z['id']}", "station_id": _zone_sentinel(z["id"]),
                   "zone_id": z["id"], "zone_name": z["name"], "emd": emd, "heavy_rain_level": heavy_rain_level,
                   "buffer_m": buffer_m, "note": "호우 단계 + 지정 취약지역 조합 — 토양수분 실측/예측 아님"},
        ))
    return out


# ------------------------------------------------------------------ DB 연동
RAIN_SUM_SQL = """
SELECT COALESCE(SUM(v.value), 0) AS rain_sum_mm, COUNT(v.value) AS hours_found
FROM generate_series(0, %(hours)s - 1) AS h(k)
CROSS JOIN LATERAL (
  SELECT o.value FROM observations o
  WHERE o.station_id = %(station_id)s AND o.metric = 'rain_1h'
    AND o.observed_at <= %(now)s - make_interval(hours => h.k)
    AND o.observed_at >  %(now)s - make_interval(hours => h.k + 1)
  ORDER BY o.observed_at DESC LIMIT 1
) v
"""
LATEST_METRIC_SQL = """
SELECT DISTINCT ON (metric) metric, value, observed_at, (quality IS NOT DISTINCT FROM 'simulated') AS simulated
FROM observations WHERE station_id = %(station_id)s AND metric = ANY(%(metrics)s)
ORDER BY metric, (quality IS NOT DISTINCT FROM 'simulated') DESC, observed_at DESC
"""
STATION_ID_SQL = "SELECT id, is_mountain FROM stations WHERE source_code = %(source_code)s AND external_id = %(external_id)s"
ZONES_SQL = """
SELECT id, name, meta, ST_X(ST_Centroid(geom)) AS lng, ST_Y(ST_Centroid(geom)) AS lat
FROM hazard_zones WHERE hazard = 'landslide'
"""
RULES_SQL = ("SELECT id, hazard::text AS hazard, level::text AS level, label, condition FROM risk_rules "
             "WHERE is_active AND hazard::text = ANY(%(hazards)s) ORDER BY id")
STALE_HEAVY_RAIN_MIN = 40


def run(run_id: Optional[int] = None) -> int:
    """수집기 job 진입점. 반환: 이번에 생성/갱신된 위험 영역 수"""
    now = datetime.now(KST)
    rules = db.fetch_all(RULES_SQL, {"hazards": HAZARDS})
    sta = db.fetch_one(STATION_ID_SQL, {"source_code": AWS_SOURCE, "external_id": AWS_EXTERNAL_ID})
    results: list[Result] = []
    seen: set[int] = set()
    heavy_rain_level: Optional[str] = None

    if sta is None:
        log.warning("구룡포 AWS(816) 관측소가 아직 없음 — 호우·강풍 판정 건너뜀")
    else:
        station_id, is_mountain = sta["id"], sta["is_mountain"]
        latest = {row["metric"]: row for row in db.fetch_all(
            LATEST_METRIC_SQL, {"station_id": station_id, "metrics": ["rain_1h", "wind_speed", "wind_gust"]})}

        rain_row = latest.get("rain_1h")
        rain_age = freshness.age_minutes(rain_row["observed_at"], now) if rain_row else None
        rain_fresh = rain_age is not None and rain_age <= STALE_HEAVY_RAIN_MIN
        if rain_fresh:
            sums = {h: db.fetch_one(RAIN_SUM_SQL, {"station_id": station_id, "hours": h, "now": now})["rain_sum_mm"]
                    for h in (3, 12)}
            res = evaluate_heavy_rain(float(sums[3]), float(sums[12]), rain_row["observed_at"], rules,
                                       simulated=rain_row["simulated"])
            heavy_rain_level = res.level if res else "normal"
            if res:
                results.append(res)
            seen.add(STA_HEAVY_RAIN)
        else:
            log.info("구룡포 AWS rain_1h 자료 없음/오래됨 — 호우·산사태 판정 이번 회차 보류(기존 유지)")

        ws, wg = latest.get("wind_speed"), latest.get("wind_gust")
        ages = [freshness.age_minutes(row["observed_at"], now) for row in (ws, wg) if row]
        wind_fresh = any(a is not None and a <= 40 for a in ages)
        if wind_fresh:
            obs_at = max((row["observed_at"] for row in (ws, wg) if row), default=None)
            simulated = any(row.get("simulated") for row in (ws, wg) if row)
            res = evaluate_strong_wind(float(ws["value"]) if ws else None, float(wg["value"]) if wg else None,
                                        bool(is_mountain), obs_at, rules, simulated=simulated)
            if res:
                results.append(res)
            seen.add(STA_STRONG_WIND)

    zones = db.fetch_all(ZONES_SQL)
    landslide_results = evaluate_landslide(heavy_rain_level, zones, rules)
    results.extend(landslide_results)
    if heavy_rain_level is not None:
        seen.update(_zone_sentinel(z["id"]) for z in zones)

    stats = sync(results, seen)
    log.info("hazards: heavy_rain=%s wind_seen=%s landslide_zones=%d active=%d %s",
             heavy_rain_level, STA_STRONG_WIND in seen, len(landslide_results), len(results), stats)
    return len(results)

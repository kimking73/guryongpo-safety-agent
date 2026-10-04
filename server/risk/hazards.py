"""호우·강풍·산사태 판정 — A4

입력
  호우 : 구룡포 AWS(816) rain_1h 스냅샷을 RAIN_SUM_SQL 로 3·12시간 누적 (judge_source 로 유효성 확인)
  강풍 : 구룡포 AWS(816) wind_speed·wind_gust 최신값
  산사태 : 이번 판정에서 나온 heavy_rain 단계
           + 산림청 산사태위험지도 100m 범위(hazard_zones external_id riskmap_g1_buf100 / riskmap_g12_buf100, 09_seed)
           + 지정 산사태 취약지역(hazard_zones, 포항 488곳) 100m

기준 : risk_rules 1~4(호우·강풍), 10~11(산사태) — 전부 기상청 발표기준을 그대로 우리 관측값에 적용한 것.
  강풍은 stations.is_mountain 으로 육상/산지 기준을 나눈다 (구룡포 AWS 는 해안 저지대 → 육상 기준)

산사태 기준 (2026-10-02 개편)
  주의(10) = 호우주의보 이상 AND (위험지도 1등급 비탈 100m 이내 OR 지정 취약지역 100m 이내)
  경고(11) = 호우경보 이상   AND (위험지도 1·2등급 비탈 100m 이내 OR 지정 취약지역 100m 이내)
  - 등급: 산림청 산사태위험판정기준표(산림보호법 시행규칙 별표1) 1등급 '집중강우 시', 2등급 '폭우 시' → 주의보↔1등급, 경보↔1·2등급 (자체 설계)
  - 100m: KIGAM 김경수 외(2006) 포항(제3기퇴적암류) 산사태 진행거리 평균 36m, 91%가 60m 이내
  - 위험지도 범위는 미리 계산한 폴리곤(Result.zone_id)을 그대로 영향 범위로 씀. 취약지역은 지정사유를 근거 문장에 넣음
  - 산림청 산사태예측정보 API 는 2012~2026 이력에 포항 0건 → 사용하지 않음

산사태 표기 원칙 (2026-09-29 팀 결정)
  이건 토양수분을 실측/예측한 결과가 아니라 "호우 단계 + 위험 비탈·취약지역"이라는 대리 지표다.
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
from collector.converters import kma_typhoon
from risk import freshness
from risk.engine import Result, sync
from risk.levels import GURYONGPO_CENTER, GURYONGPO_RADIUS_M, LEVEL_NUM

log = logging.getLogger("risk.hazards")
KST = timezone(timedelta(hours=9))
ENGINE = "hazards_v1"
HAZARDS = ["heavy_rain", "strong_wind", "landslide", "typhoon"]
AWS_SOURCE, AWS_EXTERNAL_ID = "kma", "aws_816"   # 수집기 kma_warn_aws.aws_station 과 같은 이름 (2026-10-05 수정: "816" 이라 관측소를 못 찾아 호우·강풍 판정이 늘 건너뛰어짐)
STA_HEAVY_RAIN, STA_STRONG_WIND, STA_TYPHOON = -1, -2, -3   # basis.station_id sentinel (실제 관측소 id 와 겹치지 않게 음수)


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


# ------------------------------------------------------------------ 태풍 (rules 7·8)
# any: 기상청 태풍 특보(주의보/경보, 우리 지역) 발효 중 이거나, 태풍 강풍(15m/s)·폭풍(25m/s) 반경 안에 구룡포가 들어옴
def evaluate_typhoon(active_warnings: list[dict], impacts: dict[str, dict], rules: list[dict]) -> Optional[Result]:
    """active_warnings: weather_warnings 에서 hazard='typhoon', released_at IS NULL 인 행들 (region_name·level·headline)
    impacts: kma_typhoon.impact() 결과 {typhoon_code: {...}} — in_15ms_now/in_25ms_now 로 반경 진입 여부 판단
    자료가 아예 없으면(특보도 없고 진행 중 태풍도 없음) None — 이건 '판단 불가'가 아니라 '해당 없음'과 같으므로
    호출 측이 항상 seen 에 포함시켜 즉시 정상 처리한다"""
    warn_level = {w["level"] for w in active_warnings}
    for r in _rules_by_hazard(rules, "typhoon"):
        need_warn = "warning" if r["level"] == "warning" else {"advisory", "watch"}
        need_warn = {need_warn} if isinstance(need_warn, str) else need_warn
        warn_hit = bool(warn_level & need_warn)
        radius_key = "in_25ms_now" if r["level"] == "warning" else "in_15ms_now"
        radius_hits = [(code, im) for code, im in impacts.items() if im.get(radius_key)]
        if not (warn_hit or radius_hits):
            continue
        parts = []
        if warn_hit:
            w = next(w for w in active_warnings if w["level"] in need_warn)
            parts.append(f"기상청 {w['headline'] or w['region_name'] + ' 태풍특보'} 발효 중")
        for code, im in radius_hits:
            radius_ko = "폭풍반경(25m/s)" if r["level"] == "warning" else "강풍반경(15m/s)"
            parts.append(f"제{code}호 태풍 {radius_ko} 안 · 구룡포 중심 거리 {im['now_distance_km']}km")
        return Result(
            key="typhoon:guryongpo", hazard="typhoon", level=r["level"], rule_id=r["id"], label=r["label"],
            reason=" · ".join(parts), lng=GURYONGPO_CENTER[0], lat=GURYONGPO_CENTER[1],
            buffer_m=GURYONGPO_RADIUS_M, observed_at=None,
            basis={"engine": ENGINE, "key": "typhoon:guryongpo", "station_id": STA_TYPHOON,
                   "warning_hit": warn_hit, "radius_hit_codes": [c for c, _ in radius_hits],
                   "impacts": impacts},
        )
    return None


# ------------------------------------------------------------------ 산사태 (rules 10·11)
RISKMAP_AREA = {"advisory": "riskmap_g1_buf100", "warning": "riskmap_g12_buf100"}   # 규칙 condition 에 없을 때 기본값
RISKMAP_GRADE_KO = {"riskmap_g1_buf100": "1등급(매우 높음)", "riskmap_g12_buf100": "1·2등급(매우 높음·높음)"}


def evaluate_landslide(heavy_rain_level: Optional[str], zones: list[dict], rules: list[dict]) -> list[Result]:
    """heavy_rain_level=None 이면 호우 판정 자체가 불가한 상태 → 산사태도 판단 불가로 보고 빈 목록 반환
    zones: hazard_zones(landslide) — external_id 가 riskmap_* 이면 위험지도 100m 범위, 아니면 지정 취약지역"""
    if heavy_rain_level is None:
        return []
    r10 = next((r for r in rules if r["id"] == 10), None)   # advisory: 1등급 100m + 취약지역 100m
    r11 = next((r for r in rules if r["id"] == 11), None)   # warning : 1·2등급 100m + 취약지역 100m
    lvl = LEVEL_NUM.get(heavy_rain_level, 0)
    if r11 and lvl >= LEVEL_NUM["warning"]:
        rule = r11
    elif r10 and lvl >= LEVEL_NUM["advisory"]:
        rule = r10
    else:
        return []
    within = next((c for c in _cond(rule).get("all", []) if "within" in c), {})
    buffer_m = float(within.get("buffer_m", 0))
    area_ext = within.get("riskmap_area") or RISKMAP_AREA.get(rule["level"])
    rain_ko = heavy_rain_level_ko(heavy_rain_level)
    tail = f" · 현재 호우 {rain_ko} 수준 강우 · 산사태 발생 가능성에 대비가 필요합니다 (실제 발생을 뜻하지 않음)"
    out: list[Result] = []
    for z in zones:
        ext = z.get("external_id") or ""
        if ext.startswith("riskmap_"):
            if ext != area_ext:
                continue
            out.append(Result(
                key="landslide:riskmap", hazard="landslide", level=rule["level"], rule_id=rule["id"],
                label=rule["label"], lng=z["lng"], lat=z["lat"], buffer_m=0, observed_at=None, zone_id=z["id"],
                reason=f"산림청 산사태위험지도 {RISKMAP_GRADE_KO.get(ext, '')} 비탈에서 {buffer_m:.0f}m 이내 지역" + tail,
                basis={"engine": ENGINE, "key": "landslide:riskmap", "station_id": _zone_sentinel(z["id"]),
                       "kind": "riskmap", "zone_id": z["id"], "area": ext, "buffer_m": buffer_m,
                       "heavy_rain_level": heavy_rain_level,
                       "note": "호우 단계 + 산림청 산사태위험지도 등급 — 토양수분 실측/예측 아님"},
            ))
            continue
        meta = z.get("meta") or {}
        emd, why = meta.get("emd", ""), (meta.get("reason") or "").strip()
        why_txt = f" (지정사유: {why[:60]}{'…' if len(why) > 60 else ''})" if why else ""
        out.append(Result(
            key=f"landslide:zone:{z['id']}", hazard="landslide", level=rule["level"], rule_id=rule["id"],
            label=rule["label"], lng=z["lng"], lat=z["lat"], buffer_m=buffer_m, observed_at=None,
            reason=f"{z['name']}{'(' + emd + ')' if emd else ''} 산사태 취약지역 지정{why_txt}" + tail,
            basis={"engine": ENGINE, "key": f"landslide:zone:{z['id']}", "station_id": _zone_sentinel(z["id"]),
                   "kind": "designated", "priority": "designated", "zone_id": z["id"], "zone_name": z["name"],
                   "emd": emd, "heavy_rain_level": heavy_rain_level, "buffer_m": buffer_m,
                   "note": "호우 단계 + 지정 취약지역 조합 — 토양수분 실측/예측 아님"},
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
SELECT id, external_id, name, meta, ST_X(ST_PointOnSurface(geom)) AS lng, ST_Y(ST_PointOnSurface(geom)) AS lat
FROM hazard_zones
WHERE hazard = 'landslide' AND COALESCE(meta->>'role', '') <> 'display'   -- 위험지도 등급 원본(표시용)은 판정에서 제외
"""
RULES_SQL = ("SELECT id, hazard::text AS hazard, level::text AS level, label, condition FROM risk_rules "
             "WHERE is_active AND hazard::text = ANY(%(hazards)s) ORDER BY id")
STALE_HEAVY_RAIN_MIN = 40

ACTIVE_TYPHOON_WARNINGS_SQL = """
SELECT level::text AS level, region_name, headline, issued_at
FROM weather_warnings WHERE hazard = 'typhoon' AND released_at IS NULL
"""
TYPHOON_TRACKS_SQL = """
SELECT typhoon_code, name_ko, observed_at, issued_at, is_forecast,
       ST_Y(geom) AS lat, ST_X(geom) AS lng, radius_15ms_km, radius_25ms_km, location_text
FROM typhoon_tracks
WHERE observed_at >= now() - interval '2 days'
ORDER BY typhoon_code, observed_at
"""


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

    # 태풍: 특보·경로 테이블은 항상 조회 가능(관측소 연결 유무와 무관) → 매 회차 seen 에 포함
    active_warnings = db.fetch_all(ACTIVE_TYPHOON_WARNINGS_SQL)
    track_rows = db.fetch_all(TYPHOON_TRACKS_SQL)
    # kma_typhoon.impact()는 태풍별로 "현재"(is_forecast=False) 관측 1건이 있다고 가정한다.
    # 아직 예보(forecast)만 들어오고 현재 관측이 없는 태풍은 대상에서 제외한다 — 특보(active_warnings)
    # 경로로는 여전히 잡히므로 판단 자체가 누락되지는 않는다.
    codes_with_now = {r["typhoon_code"] for r in track_rows if not r["is_forecast"]}
    usable_track_rows = [r for r in track_rows if r["typhoon_code"] in codes_with_now]
    impacts = kma_typhoon.impact(usable_track_rows) if usable_track_rows else {}
    typhoon_res = evaluate_typhoon(active_warnings, impacts, rules)
    if typhoon_res:
        results.append(typhoon_res)
    seen.add(STA_TYPHOON)

    stats = sync(results, seen)
    log.info("hazards: heavy_rain=%s wind_seen=%s landslide_zones=%d typhoon=%s active=%d %s",
             heavy_rain_level, STA_STRONG_WIND in seen, len(landslide_results),
             typhoon_res.level if typhoon_res else None, len(results), stats)
    return len(results)

"""포항 디지털 트윈 '수위계 장비 실시간 수집 정보' → stations / observations 행 변환
(A2 수집기에서 그대로 사용)

응답 형식 (2026-09 확인)
  {"id":"1","status":"success","data":[
     {"id":10,"eui":"50F8A5FFFE0EF54B","name":"구룡포환승센터_지표면 수위계",
      "latitude":35.99069,"longitude":129.556057,"address":"경북 포항시 남구 구룡포읍 구룡포리 954-31",
      "sensorType":"ROAD","value":"0","level":"1"}, ...]}

확인된 규칙
- sensorType: HOLE(스마트맨홀) / ROAD(지표면 수위계) / RIVER(하천 수위계) / RAIN(강우량계)
- value: 문자열. 단위 mm (RAIN 은 시간당 강우량 mm). HOLE value 는 저장만 하고 판단에는 level 만 사용
- level: 문자열. 1 정상 / 2 보통 / 3 주의 / 4 경보 / 5 위험
- 측정 시각 필드 없음, 측정 시점도 알 수 없음(약 1시간 주기 갱신)
  → observed_at = 수집 시각(분 단위). 10분마다 수집한 스냅샷을 모두 저장
- 응답 앞의 "{" 가 빠진 채 오는 경우가 있음 → parse_text() 가 보정
"""
from __future__ import annotations

import json
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))

# sensorType → (stations.kind, observations.metric, unit)
SENSOR_TYPES = {
    "HOLE":  ("manhole",     "manhole_level", "mm"),
    "ROAD":  ("road_flood",  "flood_depth",   "mm"),
    "RIVER": ("river_level", "river_level",   "mm"),
    "RAIN":  ("rain_gauge",  "rain_1h",       "mm"),   # 시간당 강우량
}

# 포항 DT level → 우리 risk_level
LEVEL_MAP = {1: "normal", 2: "watch", 3: "advisory", 4: "warning", 5: "critical"}
LEVEL_LABEL = {1: "정상", 2: "보통", 3: "주의", 4: "경보", 5: "위험"}


class PohangDTError(Exception):
    pass


def parse_text(raw: str):
    """응답 원문 문자열 → dict. 앞의 '{' 누락 보정."""
    s = raw.strip().lstrip("﻿")
    if not s.startswith(("{", "[")):
        s = "{" + s
    try:
        return json.loads(s)
    except json.JSONDecodeError as e:
        raise PohangDTError(f"JSON 파싱 실패: {e}; 앞부분={raw[:80]!r}") from e


def _sensor_list(resp):
    if isinstance(resp, list):
        return resp
    if resp.get("status") not in (None, "success"):
        raise PohangDTError(f"status={resp.get('status')!r}")
    data = resp.get("data")
    if isinstance(data, list):
        return data
    raise PohangDTError("data 배열이 없음")


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def minute_floor(t: datetime) -> datetime:
    return t.astimezone(KST).replace(second=0, microsecond=0)


def normalize(resp, fetched_at: datetime | None = None):
    """반환: (stations, observations, skipped)
    stations     : stations upsert 용 dict (geom 은 lng/lat)
    observations : observations upsert 용 dict (station 은 external_id 로 참조)
    skipped      : 변환하지 못한 원본 항목과 사유
    """
    if isinstance(resp, str):
        resp = parse_text(resp)
    observed_at = minute_floor(fetched_at or datetime.now(KST))   # 수집 시각
    stations, observations, skipped = [], [], []
    for item in _sensor_list(resp):
        st = SENSOR_TYPES.get(item.get("sensorType"))
        lat, lng = _num(item.get("latitude")), _num(item.get("longitude"))
        if st is None or item.get("id") is None or lat is None or lng is None:
            skipped.append({"item": item, "reason": "알 수 없는 sensorType 또는 id/좌표 누락"})
            continue
        kind, metric, unit = st
        ext_id = str(item["id"])
        stations.append({
            "source_code": "pohang_dt", "external_id": ext_id, "name": item.get("name") or ext_id,
            "kind": kind, "address": item.get("address"), "lng": lng, "lat": lat,
            "meta": {"eui": item.get("eui"), "sensor_type": item.get("sensorType")},
        })
        value, level = _num(item.get("value")), _num(item.get("level"))
        if value is None:
            skipped.append({"item": item, "reason": "value 숫자 변환 실패"})
            continue
        observations.append({
            "source_code": "pohang_dt", "external_id": ext_id, "metric": metric,
            "observed_at": observed_at.isoformat(), "value": value, "unit": unit,
            "source_level": int(level) if level is not None else None,
        })
    return stations, observations, skipped


UPSERT_STATION_SQL = """
INSERT INTO stations (source_code, external_id, name, kind, address, geom, meta)
VALUES (%(source_code)s, %(external_id)s, %(name)s, %(kind)s, %(address)s,
        ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), %(meta)s::jsonb)
ON CONFLICT (source_code, external_id) DO UPDATE
SET name = EXCLUDED.name, kind = EXCLUDED.kind, address = EXCLUDED.address,
    geom = EXCLUDED.geom, meta = EXCLUDED.meta, is_active = true
"""

# 10분마다 수집해 스냅샷을 모두 저장 (같은 분에 재수집하면 덮어씀)
INSERT_OBSERVATION_SQL = """
INSERT INTO observations (station_id, metric, observed_at, value, unit, source_level, ingest_run_id)
SELECT s.id, %(metric)s, %(observed_at)s, %(value)s, %(unit)s, %(source_level)s, %(ingest_run_id)s
FROM stations s WHERE s.source_code = %(source_code)s AND s.external_id = %(external_id)s
ON CONFLICT (station_id, metric, observed_at) DO UPDATE
SET value = EXCLUDED.value, source_level = EXCLUDED.source_level, ingest_run_id = EXCLUDED.ingest_run_id
"""


if __name__ == "__main__":
    import pathlib
    raw = (pathlib.Path(__file__).parent.parent / "mock/external/pohang_dt_water_level.sample.json").read_text(encoding="utf-8")
    s, o, sk = normalize(raw, datetime(2026, 9, 26, 19, 42, 37, tzinfo=KST))
    print(json.dumps({"stations": s, "observations": o, "skipped": sk}, ensure_ascii=False, indent=2))


# ------------------------------------------------------------------ risk engine 참고
# 시간당 강우량(rain_1h)으로 3시간·12시간 누적 계산 (측정 시각을 모르므로 수집 스냅샷 기준 근사)
#   now, now-1h, now-2h 각 시점에서 '그 시점 이전 가장 최근 스냅샷' 값을 더한다.
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


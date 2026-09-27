"""포항 디지털 트윈 '대기환경 측정 장비' · '자외선' → stations / observations 행 변환 (A2 수집기용)

응답 형식 (2026-09-26 실제 호출로 확인, 원문: mock/external/*.json)
  GET /dpg/atmosphere/devices            장비 목록 24대
    {"id":1,"name":"유해물질 측정기 외1","latitude":"35.980946","longitude":"129.540324",
     "address":"...","firm":"1.0.0","nickname":"구룡포행정복지센터 남서측"}
  GET /dpg/atmosphere/devices/realtime   장비별 최신값 (23대, 23번 없음)
    {"logDateTime":"2026-09-26 20:54:35","devId":1,"pm10":21.1,"pm25":11.8,"so2":0.04,...,
     "temp":18.5,"humi":82.5,"winsp":0.04,"windir":295.5,"batt":12.4}
  GET /dpg/sensor/latest/uvIndex         구룡포 전체 값 1개 (장비 id·좌표 없음)
    {"dateTime":"2026-09-26 20:48:34","uvIndex":0.4}
  GET /dpg/uv/devices?id=N               유효한 id 확인 불가 → 사용 안 함
  공통: 쿼리 serviceKey 필수. 키 오류 시 {"rspns_rslt":{"rslt_cd":"40102",...},"rspns_bdy":null}

수위계와 다른 점
- 측정 시각(logDateTime / dateTime)이 있음 → observed_at = 원천 측정 시각 (KST)
- 갱신이 멈춘 장비가 섞여 옴 (확인 당시 5번 6월, 6번 8월, 10·15·18번 반나절~하루 전,
  7번 시각 공란·전부 0) → 수집은 하되, 위험 판단은 MAX_AGE_MIN(60분) 이내 값만 사용
- 시각이 비어 있거나 모든 값이 0인 행은 건너뜀 (skipped)
- 같은 값을 다시 받아도 (station, metric, observed_at) PK 로 중복 저장되지 않음
"""
from __future__ import annotations

import json
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))
MAX_AGE_MIN = 60            # 위험 판단에 쓰는 값의 최대 나이 (분)

# 응답 필드 → (observations.metric, 단위, 위험판단 사용 여부)
AIR_METRICS = {
    "pm10":   ("pm10",       "㎍/㎥", True),    # 미세먼지 규칙
    "pm25":   ("pm25",       "㎍/㎥", True),    # 초미세먼지 규칙
    "winsp":  ("wind_speed", "m/s",   False),   # 참고용 (지상 저고도 센서, 강풍 판단은 기상청 값)
    "windir": ("wind_dir",   "deg",   False),
    "temp":   ("temp",       "°C",    False),
    "humi":   ("humidity",   "%",     False),
    "o3":     ("o3",         "ppm",   False),   # 이하 저장만
    "no2":    ("no2",        "ppm",   False),
    "so2":    ("so2",        "ppm",   False),
    "co":     ("co",         "ppm",   False),
    "voc":    ("voc",        "ppm",   False),
    "h2s":    ("h2s",        "ppm",   False),
    "nh3":    ("nh3",        "ppm",   False),
    "hcho":   ("hcho",       "ppm",   False),
    "co2":    ("co2",        "%",     False),   # 부피비 % (0.04% = 400ppm, 평소 대기 농도와 일치)
    "ou":     ("odor",       "OU",    False),
    "batt":   ("battery",    "V",     False),
}

# 자외선: 좌표 없는 구룡포 전역 값 → 가상 관측소 1개 (구룡포행정복지센터 좌표)
UV_STATION = {
    "source_code": "pohang_dt", "external_id": "uv_latest", "name": "구룡포 자외선지수 (전역)",
    "kind": "uv", "address": "경북 포항시 남구 구룡포읍", "lng": 129.548065, "lat": 35.985863,
    "meta": {"area_wide": True, "note": "원천 좌표 없음 - 구룡포 전역 값, 버퍼 대신 구룡포읍 전체에 적용"},
}


class PohangDTError(Exception):
    pass


def _body(resp):
    if isinstance(resp, str):
        s = resp.strip().lstrip("﻿")
        resp = json.loads(s if s.startswith(("{", "[")) else "{" + s)
    if isinstance(resp, dict) and "rspns_rslt" in resp:
        r = resp["rspns_rslt"] or {}
        raise PohangDTError(f"{r.get('rslt_cd')} {r.get('rslt_msg')}")
    if isinstance(resp, dict):
        if resp.get("status") not in (None, "success"):
            raise PohangDTError(f"status={resp.get('status')!r}")
        return resp.get("data")
    return resp


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _kst(s):
    if not s:
        return None
    try:
        return datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S").replace(tzinfo=KST)
    except ValueError:
        return None


def normalize_devices(resp):
    """장비 목록 → stations"""
    stations, skipped = [], []
    for d in _body(resp) or []:
        lat, lng = _num(d.get("latitude")), _num(d.get("longitude"))
        if d.get("id") is None or lat is None or lng is None:
            skipped.append({"item": d, "reason": "id/좌표 누락"}); continue
        stations.append({
            "source_code": "pohang_dt", "external_id": f"air_{d['id']}",
            "name": d.get("nickname") or d.get("name"), "kind": "air",
            "address": d.get("address"), "lng": lng, "lat": lat,
            "meta": {"device_name": d.get("name"), "firm": d.get("firm"), "dev_id": d["id"]},
        })
    return stations, skipped


def normalize_realtime(resp):
    """실시간 → observations (observed_at = logDateTime)"""
    obs, skipped = [], []
    for r in _body(resp) or []:
        t = _kst(r.get("logDateTime"))
        vals = {k: _num(r.get(k)) for k in AIR_METRICS}
        if r.get("devId") is None or t is None:
            skipped.append({"item": r, "reason": "devId 또는 logDateTime 없음"}); continue
        if all(not v for k, v in vals.items() if k != "batt"):
            skipped.append({"item": r, "reason": "측정값 전부 0/없음 (장비 이상)"}); continue
        for k, v in vals.items():
            if v is None:
                continue
            metric, unit, _ = AIR_METRICS[k]
            obs.append({"source_code": "pohang_dt", "external_id": f"air_{r['devId']}", "metric": metric,
                        "observed_at": t.isoformat(), "value": v, "unit": unit, "source_level": None})
    return obs, skipped


def normalize_uv(resp):
    """자외선 최신값 → (station, observations)"""
    d = _body(resp) or {}
    t, v = _kst(d.get("dateTime")), _num(d.get("uvIndex"))
    if t is None or v is None:
        return UV_STATION, [], [{"item": d, "reason": "dateTime/uvIndex 없음"}]
    return UV_STATION, [{"source_code": "pohang_dt", "external_id": "uv_latest", "metric": "uv_index",
                         "observed_at": t.isoformat(), "value": v, "unit": "index", "source_level": None}], []


def is_fresh(observed_at: str, now: datetime | None = None, max_age_min: int = MAX_AGE_MIN):
    now = now or datetime.now(KST)
    return now - datetime.fromisoformat(observed_at) <= timedelta(minutes=max_age_min)


# SQL 은 pohang_dt_water.UPSERT_STATION_SQL / INSERT_OBSERVATION_SQL 을 그대로 사용.
# 위험 판단용 최신값 (60분 이내만):
FRESH_LATEST_SQL = """
SELECT * FROM v_latest_observations
WHERE metric = ANY(%(metrics)s) AND observed_at >= now() - make_interval(mins => %(max_age_min)s)
"""
# 미세먼지 '시간평균 2시간 지속' 근사: 최근 2시간을 1시간 구간 2개로 나눠 각 평균이 모두 기준 이상
DUST_SUSTAINED_SQL = """
SELECT station_id, bool_and(avg_v >= %(threshold)s) AND count(*) = 2 AS sustained
FROM (
  SELECT station_id, floor(extract(epoch FROM now() - observed_at) / 3600) AS h, avg(value) AS avg_v
  FROM observations
  WHERE metric = %(metric)s AND observed_at > now() - interval '2 hours'
  GROUP BY station_id, h
) x GROUP BY station_id
"""


if __name__ == "__main__":
    import pathlib
    ext = pathlib.Path(__file__).parent.parent / "mock/external"
    now = datetime(2026, 9, 26, 20, 55, tzinfo=KST)
    st, sk1 = normalize_devices((ext / "atmosphere_devices.json").read_text(encoding="utf-8"))
    ob, sk2 = normalize_realtime((ext / "atmosphere_realtime.json").read_text(encoding="utf-8"))
    uvs, uvo, sk3 = normalize_uv((ext / "uv_latest.json").read_text(encoding="utf-8"))
    fresh = {o["external_id"] for o in ob if is_fresh(o["observed_at"], now)}
    stale = sorted({o["external_id"] for o in ob} - fresh, key=lambda x: int(x.split("_")[1]))
    print(f"stations {len(st)}+1(uv) / observations {len(ob)}+{len(uvo)} / skipped {len(sk1)+len(sk2)+len(sk3)}")
    print("skipped:", [(s['item'].get('devId'), s['reason']) for s in sk2])
    print(f"판단 사용 장비 {len(fresh)}대, 60분 초과 제외: {stale}")
    print("uv:", uvo)

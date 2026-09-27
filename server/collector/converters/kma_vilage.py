# 원본: 1주차_DB_API명세/tools/kma_vilage.py (수집기용 사본 — 이후 수정은 이 파일에서)
"""기상청 API허브 동네예보 (VilageFcstInfoService_2.0) → observations / forecasts 행 변환 (A2 수집기용)

API (authKey 필수, dataType=JSON)
  getUltraSrtNcst  초단기실황  매시 정각 발표, +40분 조회 가능  → observations (격자 가상 관측소)
  getUltraSrtFcst  초단기예보  매시 30분 발표, +45분, 6시간     → forecasts kind='ultra_short'
  getVilageFcst    단기예보    02·05·08·11·14·17·20·23시, +10분, 약 4일 → forecasts kind='short'
  base_date/base_time 은 tools/fetch_dt.py kma_times() 로 계산. 단기예보는 1회 약 1,016건 → numOfRows 1500
  정상: response.header.resultCode == '00'

구룡포 격자 (위경도 → 기상청 LCC 5km 격자, 포항시청 = (102,94) 로 검증)
  (105,94) 구룡포읍 중심·병포리  (106,94) 구룡포항  (105,93) 구평리  (106,95) 다무포
"""
from __future__ import annotations

import json, re
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))

GRIDS = {  # (nx, ny): (이름, 대표 lat, lng) — 격자 가상 관측소 좌표
    (105, 94): ("구룡포읍 중심", 35.985863, 129.548065),
    (106, 94): ("구룡포항", 35.9903, 129.5558),
}

# 초단기실황 category → (metric, unit)   UUU/VVV(동서·남북 성분)는 WSD/VEC 와 중복이라 저장 안 함
NCST_METRICS = {
    "T1H": ("temp", "°C"), "RN1": ("rain_1h", "mm"), "REH": ("humidity", "%"),
    "WSD": ("wind_speed", "m/s"), "VEC": ("wind_dir", "deg"), "PTY": ("precip_type", "code"),
}

# 코드값 (앱·Agent 표시용)
PTY = {0: "없음", 1: "비", 2: "비/눈", 3: "눈", 4: "소나기", 5: "빗방울", 6: "빗방울눈날림", 7: "눈날림"}
SKY = {1: "맑음", 3: "구름많음", 4: "흐림"}
# 예보 category 설명 (forecasts.category 원문 그대로 저장)
FCST_CATEGORIES = {
    "POP": "강수확률 %", "PTY": "강수형태 코드", "PCP": "1시간 강수량 (범주 문자열)", "RN1": "1시간 강수량 (초단기, 범주 문자열)",
    "SNO": "1시간 신적설", "SKY": "하늘상태 코드", "TMP": "1시간 기온 °C", "T1H": "기온 °C (초단기)",
    "TMN": "일 최저기온", "TMX": "일 최고기온", "REH": "습도 %", "WSD": "풍속 m/s", "VEC": "풍향 deg",
    "UUU": "동서바람성분", "VVV": "남북바람성분", "WAV": "파고 m", "LGT": "낙뢰 (초단기)",
}


def parse_amount(v: str):
    """'강수없음'/'적설없음' → 0, '1mm 미만' → 0.5, '1.0mm'/'1.0cm' → 1.0,
    '30.0~50.0mm' → 30.0 (하한), '50.0mm 이상' → 50.0, 숫자 문자열 → float"""
    s = str(v).strip()
    if s in ("강수없음", "적설없음"):
        return 0.0
    if "미만" in s:
        return 0.5 if "mm" in s else 0.25     # '1mm 미만' / '0.5cm 미만'
    m = re.search(r"-?\d+(?:\.\d+)?", s)
    return float(m.group()) if m else None


def _items(resp):
    if isinstance(resp, str):
        resp = json.loads(resp)
    r = resp.get("response") or {}
    h = r.get("header") or {}
    if h.get("resultCode") != "00":
        raise RuntimeError(f"KMA {h.get('resultCode')} {h.get('resultMsg')}")
    return ((r.get("body") or {}).get("items") or {}).get("item") or []


def _t(d, t):
    return datetime.strptime(d + t, "%Y%m%d%H%M").replace(tzinfo=KST)


def grid_station(nx, ny):
    name, lat, lng = GRIDS.get((nx, ny), (f"격자 {nx},{ny}", None, None))
    return {"source_code": "kma", "external_id": f"grid_{nx}_{ny}", "name": f"기상청 초단기실황 {name}",
            "kind": "weather", "address": None, "lng": lng, "lat": lat,
            "meta": {"nx": nx, "ny": ny, "note": "5km 격자 값 (지점 관측 아님)"}}


def normalize_ncst(resp):
    """초단기실황 → (station, observations)"""
    items = _items(resp)
    if not items:
        return None, []
    nx, ny = int(items[0]["nx"]), int(items[0]["ny"])
    obs = []
    for it in items:
        m = NCST_METRICS.get(it["category"])
        v = parse_amount(it["obsrValue"])
        if m is None or v is None:
            continue
        obs.append({"source_code": "kma", "external_id": f"grid_{nx}_{ny}", "metric": m[0],
                    "observed_at": _t(it["baseDate"], it["baseTime"]).isoformat(),
                    "value": v, "unit": m[1], "source_level": None})
    return grid_station(nx, ny), obs


def normalize_fcst(resp, kind: str):
    """초단기예보(kind='ultra_short') / 단기예보(kind='short') → forecasts 행"""
    rows = []
    for it in _items(resp):
        rows.append({
            "kind": kind, "grid_nx": int(it["nx"]), "grid_ny": int(it["ny"]), "region_code": None,
            "base_time": _t(it["baseDate"], it["baseTime"]).isoformat(),
            "fcst_time": _t(it["fcstDate"], it["fcstTime"]).isoformat(),
            "category": it["category"], "value": str(it["fcstValue"]),
            "value_num": parse_amount(it["fcstValue"]),
        })
    return rows


def normalize_mid(resp, tm_fc: str):
    """중기육상예보(getMidLandFcst) / 중기기온(getMidTa) → forecasts 행 (kind='mid', region_code=regId)
    tm_fc: 발표시각 'YYYYMMDDHHMM'. N일 후 = 발표일 + N일
    fcst_time 규칙: Am 09시, Pm 15시, 오전/오후 구분 없는 8~10일 12시, taMin 06시, taMax 15시"""
    base = datetime.strptime(tm_fc, "%Y%m%d%H%M").replace(tzinfo=KST)
    rows = []
    for it in _items(resp):
        reg = it.get("regId")
        for k, v in it.items():
            m = re.fullmatch(r"(wf|rnSt|taMin|taMax)(\d+)(Am|Pm|Low|High)?", k)
            if not m:
                continue
            kind, day, suf = m.group(1), int(m.group(2)), m.group(3)
            hour = {"Am": 9, "Pm": 15}.get(suf) if kind in ("wf", "rnSt") else (6 if kind == "taMin" else 15)
            d = (base + timedelta(days=day)).replace(hour=hour or 12, minute=0)
            rows.append({"kind": "mid", "grid_nx": None, "grid_ny": None, "region_code": reg,
                         "base_time": base.isoformat(), "fcst_time": d.isoformat(), "category": k,
                         "value": str(v), "value_num": v if isinstance(v, (int, float)) else None})
    return rows


UPSERT_FORECAST_SQL = """
INSERT INTO forecasts (kind, grid_nx, grid_ny, region_code, base_time, fcst_time, category, value, value_num)
VALUES (%(kind)s, %(grid_nx)s, %(grid_ny)s, %(region_code)s, %(base_time)s, %(fcst_time)s, %(category)s, %(value)s, %(value_num)s)
ON CONFLICT (kind, grid_nx, grid_ny, region_code, base_time, fcst_time, category) DO UPDATE
SET value = EXCLUDED.value, value_num = EXCLUDED.value_num
"""
# forecasts 의 UNIQUE 는 NULLS NOT DISTINCT (PostgreSQL 15+) — 동네예보 region_code NULL 도 중복 방지됨
# observations 는 pohang_dt_water.UPSERT_STATION_SQL / INSERT_OBSERVATION_SQL 재사용

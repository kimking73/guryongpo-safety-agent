# 원본: 1주차_DB_API명세/tools/kma_warn_aws.py (수집기용 사본 — 이후 수정은 이 파일에서)
"""기상청 API허브 기상특보 현황 · AWS 시간통계(바람) → weather_warnings / observations 변환 (A2 수집기용)

특보현황  typ01/url/wrn_now_data.php?fe=f&tm=&disp=1   (tm 공란 = 현재, tm=YYYYMMDDHHMM = 과거 시점 재현 가능)
  응답: JSON 배열. 발효 중 특보가 없으면 []   예) mock/external/kma_wrn_hinnamno.json (2022-09-05 18시, 276건)
  {"REG_UP":"L1070000","REG_UP_KO":"경상북도","REG_ID":"L1072400","REG_KO":"포항시",
   "TM_FC":"202209050500","TM_EF":"202209052358","WRN":"태풍","LVL":"예비","CMD":"발표","ED_TM":""}
  - 문자열 끝 공백 있음 → strip
  - LVL: 예비(예비특보) / 주의(주의보) / 경보
  - CMD: 발표 / 변경 (해제된 특보는 목록에서 사라짐 → 수집 시 사라진 행에 released_at 기록)
  - ED_TM: 해제 예고 문구 (예: '07일 오전(09시~12시),') — 시각 아님, headline/raw 로만
구룡포 관련 특보구역 (wrn_reg.php 로 확인)
  L1072400 포항시 (육상) · S1131200 경북남부앞바다 · S1132210 동해남부북쪽안쪽먼바다 (어업인 먼바다)

AWS 시간통계 바람 (보조 · 전 지점만 가능, stn 지정 시 빈 응답 → 기본 수집은 AWS 매분 사용)  typ01/url/awsh.php?var=WD&tm=YYYYMMDDHH00   (전 지점, 느림 → timeout 120초)
  고정폭 텍스트. '#' 주석 뒤 공백 구분 19열
  YYMMDDHHMI STN WD WS WS_HMI WD_MAX WS_MAX WS_MAX_MI WS_QCM WS1_AVG WD1_MAX WS1_MAX WS1_MAX_MI WS1_QCM
             WD_INS_MAX WS_INS_MAX WS_INS_MAX_MI WS_INS_QCM
  → WS(정시 10분 평균풍속) = wind_speed, WD = wind_dir, WS_INS_MAX(60분 최대순간풍속) = wind_gust
  결측은 음수(-99 등) → 건너뜀
"""
from __future__ import annotations

import json
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))

OUR_REGIONS = {"L1072400": "포항시", "S1131200": "경북남부앞바다", "S1132210": "동해남부북쪽안쪽먼바다"}

WRN_HAZARD = {"호우": "heavy_rain", "강풍": "strong_wind", "태풍": "typhoon", "풍랑": "high_seas",
              "폭풍해일": "flood"}   # 폭풍해일 = 해안 침수로 취급 (raw 에 원문 유지). 그 외(대설·한파·폭염·건조·황사·안개)는 저장 안 함
WRN_LEVEL = {"예비": "watch", "주의": "advisory", "경보": "warning"}

# 관심 지점 (방재기상관측 지점 일람표 getAwsStnLstTbl 로 확인)
#   816 구룡포 (35.9831, 129.5475, 해발 42.4m, 구룡포읍 중심에서 0.3km) · 808 호미곶 (10km) · 138 포항 ASOS
AWS_STATIONS = {"816": ("구룡포 AWS", 35.9831, 129.5475),
                "808": ("호미곶 AWS", 36.07597, 129.56673),
                "138": ("포항 ASOS", 36.0326, 129.3796)}


def _kst(s):
    s = (s or "").strip()
    return datetime.strptime(s, "%Y%m%d%H%M").replace(tzinfo=KST) if s else None


def normalize_warnings(resp, regions=OUR_REGIONS):
    """특보현황 → weather_warnings 행 (우리 구역·우리 재난만)"""
    if isinstance(resp, str):
        resp = json.loads(resp)
    rows, skipped = [], []
    for w in resp:
        w = {k: (v.strip() if isinstance(v, str) else v) for k, v in w.items()}
        if w["REG_ID"] not in regions:
            continue
        hz, lv = WRN_HAZARD.get(w["WRN"]), WRN_LEVEL.get(w["LVL"])
        if hz is None or lv is None:
            skipped.append({"item": w, "reason": "매핑 없는 특보 종류/단계"}); continue
        rows.append({
            "source_code": "kma", "external_id": f'{w["TM_EF"]}_{w["WRN"]}_{w["LVL"]}',
            "hazard": hz, "level": lv, "region_code": w["REG_ID"], "region_name": w["REG_KO"],
            "issued_at": _kst(w["TM_FC"]).isoformat(), "effective_at": _kst(w["TM_EF"]).isoformat(),
            "released_at": None,
            "headline": f'{w["REG_KO"]} {w["WRN"]}{"예비특보" if w["LVL"] == "예비" else w["LVL"] + ("보" if w["LVL"] == "주의" else "")}'
                        + (f' (해제 예고: {w["ED_TM"].rstrip(",")})' if w.get("ED_TM") else ""),
            "raw": w,
        })
    return rows, skipped


UPSERT_WARNING_SQL = """
INSERT INTO weather_warnings (source_code, external_id, hazard, level, region_code, region_name,
                              issued_at, effective_at, released_at, headline, raw)
VALUES (%(source_code)s, %(external_id)s, %(hazard)s, %(level)s, %(region_code)s, %(region_name)s,
        %(issued_at)s, %(effective_at)s, NULL, %(headline)s, %(raw)s::jsonb)
ON CONFLICT (source_code, external_id, hazard, region_code) DO UPDATE
SET level = EXCLUDED.level, headline = EXCLUDED.headline, raw = EXCLUDED.raw, released_at = NULL
"""
# 이번 수집에 없는 (= 해제된) 특보 닫기. %(seen)s = 이번에 받은 (external_id||'|'||region_code) 목록
RELEASE_MISSING_SQL = """
UPDATE weather_warnings SET released_at = %(now)s
WHERE source_code = 'kma' AND released_at IS NULL AND region_code = ANY(%(regions)s)
  AND NOT (external_id || '|' || region_code = ANY(%(seen)s))
"""


def normalize_awsh_wind(text, stations=AWS_STATIONS):
    """AWS 시간통계(바람) 텍스트 → observations 행 (관심 지점만)"""
    obs = []
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split()
        if len(c) < 18 or c[1] not in stations:
            continue
        t = _kst(c[0]).isoformat()
        for metric, idx, unit in (("wind_dir", 2, "deg"), ("wind_speed", 3, "m/s"), ("wind_gust", 15, "m/s")):
            v = float(c[idx])
            if v >= 0:
                obs.append({"source_code": "kma", "external_id": f"aws_{c[1]}", "metric": metric,
                            "observed_at": t, "value": v, "unit": unit, "source_level": None})
    return obs


# AWS 매분 자료  typ01/cgi-bin/url/nph-aws2_min?tm1=&tm2=<KST YYYYMMDDHHMI>&stn=816&disp=1
#   ※ stn=0(전 지점)은 빈 응답 → 반드시 지점 지정. 쉼표 구분, 결측은 -50 이하
#   YYMMDDHHMI,STN,WD1,WS1,WDS,WSS,WD10,WS10,TA,RE,RN-15m,RN-60m,RN-12H,RN-DAY,HM,PA,PS,TD
AWS_MIN_METRICS = {   # 열 번호 → (metric, unit)
    6: ("wind_dir", "deg"),        # WD10 10분 평균 풍향
    7: ("wind_speed", "m/s"),      # WS10 10분 평균 풍속  → 강풍 기준 평균풍속
    5: ("wind_gust", "m/s"),       # WSS  최대 순간 풍속   → 강풍 기준 순간풍속
    8: ("temp", "°C"),
    10: ("rain_15m", "mm"),
    11: ("rain_1h", "mm"),         # RN-60m → RAIN_SUM_SQL 로 3시간 누적
    12: ("rain_12h", "mm"),        # 12시간 누적 (호우 기준 직접 사용)
    13: ("rain_day", "mm"),
    14: ("humidity", "%"),
    16: ("pressure_sea", "hPa"),
}


def normalize_aws_min(text, stations=AWS_STATIONS):
    obs = []
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        c = [x.strip() for x in line.rstrip(",=").split(",")]
        if len(c) < 17 or c[1] not in stations:
            continue
        t = _kst(c[0]).isoformat()
        for idx, (metric, unit) in AWS_MIN_METRICS.items():
            try:
                v = float(c[idx])
            except ValueError:
                continue
            if v > -50:
                obs.append({"source_code": "kma", "external_id": f"aws_{c[1]}", "metric": metric,
                            "observed_at": t, "value": v, "unit": unit, "source_level": None})
    return obs


def aws_station(stn):
    name, lat, lng = AWS_STATIONS[stn]
    return {"source_code": "kma", "external_id": f"aws_{stn}", "name": name, "kind": "weather",
            "address": None, "lng": lng, "lat": lat, "meta": {"stn": int(stn)}}

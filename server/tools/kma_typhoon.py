"""기상청 API허브 태풍정보 → typhoon_tracks 변환 + 구룡포 영향권 판단 (A2 수집기 · risk engine)

태풍 목록   typ01/url/typ_lst.php?YY=&disp=1       YY,SEQ,NOW(1진행/2종료),EFF(1상륙 2직접 3간접 4없음),TM_ST,TM_ED(UTC),TYP_NAME,TYP_EN,REM
위치+예측   typ01/url/typ_now.php?tm=<UTC>&mode=1&disp=1   ※ tm 과 응답 시각은 모두 UTC
  FT(0분석/1예측),YY,TYP,SEQ,TMD(예측-분석 h),TYP_TM,FT_TM,LAT,LON,DIR,SP(km/h),PS(hPa),WS(m/s),
  RAD15(강풍반경 km),RAD25(폭풍반경 km),RAD(70% 확률반경 km),ED15,ER15,LOC,ED25,ER25   결측 -999
  예) mock/external/kma_typ_hinnamno.txt (tm=2022-09-05 18UTC = 09-06 03KST, 통영 남남서 80km, +6h 예측 '포항 북동쪽 60km')
      mock/external/kma_typ_now.txt       (2026 제26호 수리개, 오키나와 남쪽 → 북동진, 한반도 영향 없음)
"""
from __future__ import annotations

import math
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))
GURYONGPO = (35.9858, 129.5481)


def _rows(text):
    for line in text.splitlines():
        if line and not line.startswith("#"):
            yield [c.strip() for c in line.rstrip(",=").split(",")]


def _utc(s):
    return datetime.strptime(s, "%Y%m%d%H%M").replace(tzinfo=timezone.utc).astimezone(KST)


def _n(s):
    try:
        v = float(s)
    except ValueError:
        return None
    return None if v <= -999 else v


def parse_list(text):
    """→ {typhoon_code: {name_ko, name_en, active, korea_effect}}"""
    out = {}
    for c in _rows(text):
        code = f"{c[0][2:]}{int(c[1]):02d}"            # '2611'
        out[code] = {"name_ko": c[6], "name_en": c[7], "active": c[2] == "1",
                     "korea_effect": {"1": "상륙", "2": "직접영향", "3": "간접영향", "4": "없음"}.get(c[3])}
    return out


def normalize_tracks(text, names=None):
    """→ typhoon_tracks 행 (분석 이력 + 최신 예측)"""
    names = names or {}
    rows = []
    for c in _rows(text):
        if len(c) < 19:
            continue
        code = f"{c[1][2:]}{int(c[2]):02d}"
        is_fc = c[0] == "1"
        rows.append({
            "typhoon_code": code, "name_ko": (names.get(code) or {}).get("name_ko"),
            "observed_at": _utc(c[6] if is_fc else c[5]).isoformat(),
            "issued_at": _utc(c[5]).isoformat(), "is_forecast": is_fc,
            "lat": float(c[7]), "lng": float(c[8]), "direction": c[9], "speed_kmh": _n(c[10]),
            "central_pressure_hpa": _n(c[11]), "max_wind_ms": _n(c[12]),
            "radius_15ms_km": _n(c[13]), "radius_25ms_km": _n(c[14]), "prob_radius_km": _n(c[15]),
            "location_text": c[18],
        })
    return rows


def dist_km(lat1, lng1, lat2, lng2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lng2 - lng1) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(a))


def impact(rows, point=GURYONGPO):
    """태풍별 구룡포 영향: 현재 거리·강풍반경 안인지 + 예측 경로 중 최근접 거리·시각·반경 진입 여부
    risk_rules 7번(advisory: radius_15ms_km 안) / 8번(warning: radius_25ms_km 안) 판단에 사용"""
    out = {}
    for code in {r["typhoon_code"] for r in rows}:
        rs = sorted([r for r in rows if r["typhoon_code"] == code], key=lambda r: r["observed_at"])
        now = [r for r in rs if not r["is_forecast"]][-1]
        d = lambda r: dist_km(r["lat"], r["lng"], *point)
        inside = lambda r, k: r[k] is not None and d(r) <= r[k]
        fc = [r for r in rs if r["is_forecast"] and r["issued_at"] == now["observed_at"]]
        closest = min([now] + fc, key=d)
        out[code] = {
            "now_at": now["observed_at"], "now_distance_km": round(d(now)), "now_location": now["location_text"],
            "in_15ms_now": inside(now, "radius_15ms_km"), "in_25ms_now": inside(now, "radius_25ms_km"),
            "closest_at": closest["observed_at"], "closest_distance_km": round(d(closest)),
            "will_enter_15ms": any(inside(r, "radius_15ms_km") for r in fc),
            "will_enter_25ms": any(inside(r, "radius_25ms_km") for r in fc),
        }
    return out


UPSERT_TRACK_SQL = """
INSERT INTO typhoon_tracks (typhoon_code, name_ko, observed_at, issued_at, is_forecast, geom, direction, speed_kmh,
                            central_pressure_hpa, max_wind_ms, radius_15ms_km, radius_25ms_km, prob_radius_km, location_text)
VALUES (%(typhoon_code)s, %(name_ko)s, %(observed_at)s, %(issued_at)s, %(is_forecast)s,
        ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), %(direction)s, %(speed_kmh)s,
        %(central_pressure_hpa)s, %(max_wind_ms)s, %(radius_15ms_km)s, %(radius_25ms_km)s, %(prob_radius_km)s, %(location_text)s)
ON CONFLICT (typhoon_code, observed_at, is_forecast) DO UPDATE
SET issued_at = EXCLUDED.issued_at, geom = EXCLUDED.geom, central_pressure_hpa = EXCLUDED.central_pressure_hpa,
    max_wind_ms = EXCLUDED.max_wind_ms, radius_15ms_km = EXCLUDED.radius_15ms_km,
    radius_25ms_km = EXCLUDED.radius_25ms_km, prob_radius_km = EXCLUDED.prob_radius_km, location_text = EXCLUDED.location_text
"""
# 예측은 같은 예측시각이라도 발표마다 갱신 → 최신 발표로 덮어씀 (issued_at 로 구분)


if __name__ == "__main__":
    import pathlib, json
    ext = pathlib.Path(__file__).parent.parent / "mock/external"
    for lst, trk in (("kma_typ_list_2022.txt", "kma_typ_hinnamno.txt"), ("kma_typ_list.txt", "kma_typ_now.txt")):
        names = parse_list((ext / lst).read_text(encoding="utf-8"))
        rows = normalize_tracks((ext / trk).read_text(encoding="utf-8"), names)
        print(trk, len(rows), "rows", rows[0]["name_ko"])
        print(json.dumps(impact(rows), ensure_ascii=False, indent=1))

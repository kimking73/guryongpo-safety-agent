"""수집 작업 정의 — (source, job) 하나 = 호출 → 변환 → 적재 → ingest_runs 기록

작업 목록·주기는 JOBS 한 곳에서 관리한다. 주기는 APScheduler cron 인자 (Asia/Seoul).
주기 선택 근거
  - 포항 DT 수위계: 측정 시각이 없고 약 1시간 주기 갱신 → 10분마다 스냅샷 (README 5-1)
  - 포항 DT 대기·자외선: 원천 측정 시각 있음, 같은 값은 PK 로 중복 저장 안 됨 → 10분
  - 기상청 특보·AWS: 10분 (선제 경고 1차 입력)
  - 초단기실황 :45 (정시 발표 +40분) · 초단기예보 :20 (30분 발표 +45분) · 단기예보 발표 +20분
  - 긴급재난문자 2분 (일일 한도 1,000회 → 720회/일. 발송→API 등록 약 20초, 휴대폰 CBS 가 1차이므로 대시보드·Agent 설명용)
  - 중기예보 06:30·18:30 · 태풍 3시간마다(진행 중인 태풍이 있을 때만 경로 호출) · 대기 장비 목록 하루 1회
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable

from app.config import settings
from . import fetch, store
from .converters import kma_typhoon, kma_vilage, kma_warn_aws, nmc_er, pohang_dt_air, pohang_dt_water, safety_msg

log = logging.getLogger("collector")
KST = timezone(timedelta(hours=9))

KMA_GRIDS = [(105, 94), (106, 94)]
AWS_STN = "816"                       # 구룡포 AWS
SLOW_TIMEOUT = 60.0                   # 기상청 typ01 (AWS·태풍) 은 응답이 느린 때가 있음
MID_LAND_REG, MID_TA_REG = "11H10000", "11H10201"


class SkipJob(Exception):
    """호출할 필요가 없어 건너뜀 (예: 진행 중인 태풍 없음) — 실패가 아님"""


@dataclass
class Job:
    source: str                       # data_sources.code
    job: str                          # ingest_runs.job
    run: Callable[[int], int]         # (ingest_run_id) → 적재 행 수
    cron: dict = field(default_factory=dict)
    run_at_start: bool = True         # 스케줄러 시작 직후 1회 실행
    stale_after_min: int = 30         # /health: 마지막 성공이 이보다 오래되면 degraded

    @property
    def key(self) -> str:
        return f"{self.source}.{self.job}"


def _need(key: str | None, name: str) -> str:
    if settings.fetch_mode != "replay" and not key:
        raise fetch.FetchError(f"{name} 가 설정되지 않음 (.env 또는 dt_config.txt)")
    return key or ""


# ------------------------------------------------------------------ 포항 디지털 트윈
def _dt(name: str, path: str) -> str:
    return fetch.get(name, f"{settings.dt_base_url}{path}",
                     {"serviceKey": _need(settings.dt_key, "DT_KEY")}).text


def run_water_level(run_id: int) -> int:
    st, obs, skipped = pohang_dt_water.normalize(_dt("pohang_dt_water_level", "/sensor/latest/sensorLevel"))
    if not obs:                                           # 센서 목록이 비면 정상 응답이 아님 → /health 에 드러나게 실패 처리
        raise fetch.FetchError(f"수위계 관측값 없음 (skipped {len(skipped)})")
    if skipped:
        log.warning("water_level skipped %d: %s", len(skipped), [s["reason"] for s in skipped][:3])
    store.upsert_stations(st)
    return store.insert_observations(obs, run_id)


def run_air_devices(run_id: int) -> int:
    st, _ = pohang_dt_air.normalize_devices(_dt("atmosphere_devices", "/atmosphere/devices"))
    return store.upsert_stations(st)


def run_air_realtime(run_id: int) -> int:
    if store.count_stations("pohang_dt", "air") == 0:     # 장비 목록이 없으면 관측값이 버려짐 → 먼저 적재
        run_air_devices(run_id)
    obs, skipped = pohang_dt_air.normalize_realtime(_dt("atmosphere_realtime", "/atmosphere/devices/realtime"))
    if not obs:
        raise fetch.FetchError(f"대기환경 관측값 없음 (skipped {len(skipped)})")
    if skipped:
        log.info("air_realtime skipped %d (장비 이상/시각 없음)", len(skipped))
    return store.insert_observations(obs, run_id)


def run_uv(run_id: int) -> int:
    st, obs, skipped = pohang_dt_air.normalize_uv(_dt("uv_latest", "/sensor/latest/uvIndex"))
    if not obs:
        raise fetch.FetchError(f"자외선 값 없음: {skipped}")
    store.upsert_stations([st])
    return store.insert_observations(obs, run_id)


# ------------------------------------------------------------------ 기상청 API허브
def _kma(name: str, path: str, params: dict[str, str], timeout: float | None = None) -> str:
    return fetch.get(name, f"{fetch.KMA}/{path}",
                     {**params, "authKey": _need(settings.kma_key, "KMA_KEY")}, timeout).text


def _vfc(date: str, tm: str, nx: int, ny: int, rows: int) -> dict[str, str]:
    return {"pageNo": "1", "numOfRows": str(rows), "dataType": "JSON",
            "base_date": date, "base_time": tm, "nx": str(nx), "ny": str(ny)}


def run_ncst(run_id: int) -> int:
    t, n = fetch.kma_times(), 0
    for nx, ny in KMA_GRIDS:
        text = _kma(f"kma_ncst_{nx}_{ny}", "typ02/openApi/VilageFcstInfoService_2.0/getUltraSrtNcst",
                    _vfc(t["NCST_DATE"], t["NCST_TIME"], nx, ny, 100))
        st, obs = kma_vilage.normalize_ncst(text)
        if st:
            store.upsert_stations([st])
            n += store.insert_observations(obs, run_id)
    return n


def run_ultra_fcst(run_id: int) -> int:
    t, n = fetch.kma_times(), 0
    for nx, ny in KMA_GRIDS:
        text = _kma(f"kma_fcst_{nx}_{ny}", "typ02/openApi/VilageFcstInfoService_2.0/getUltraSrtFcst",
                    _vfc(t["FCST_DATE"], t["FCST_TIME"], nx, ny, 100))
        n += store.upsert_forecasts(kma_vilage.normalize_fcst(text, "ultra_short"))
    return n


def run_vilage_fcst(run_id: int) -> int:
    t, n = fetch.kma_times(), 0
    for nx, ny in KMA_GRIDS:
        text = _kma(f"kma_vil_{nx}_{ny}", "typ02/openApi/VilageFcstInfoService_2.0/getVilageFcst",
                    _vfc(t["VIL_DATE"], t["VIL_TIME"], nx, ny, 1500))   # 1회 약 1,016건
        n += store.upsert_forecasts(kma_vilage.normalize_fcst(text, "short"))
    return n


def run_mid_fcst(run_id: int) -> int:
    tm = fetch.kma_times()["MID_TMFC"]
    n = 0
    for name, op, reg in (("kma_mid_land_11H10000", "getMidLandFcst", MID_LAND_REG),
                          ("kma_mid_ta_11H10201", "getMidTa", MID_TA_REG)):
        text = _kma(name, f"typ02/openApi/MidFcstInfoService/{op}",
                    {"pageNo": "1", "numOfRows": "10", "dataType": "JSON", "regId": reg, "tmFc": tm})
        n += store.upsert_forecasts(kma_vilage.normalize_mid(text, tm))
    return n


def run_warnings(run_id: int) -> int:
    text = _kma("kma_wrn_now", "typ01/url/wrn_now_data.php", {"fe": "f", "tm": "", "disp": "1", "help": "1"}).strip()
    # 빈 응답·오류 문구를 '특보 없음([])'으로 오해하면 발효 중인 특보가 전부 해제 처리됨 → 실패로 처리
    if not text.startswith("["):
        raise fetch.FetchError(f"특보 응답이 JSON 배열이 아님: {text[:80]!r}")
    rows, skipped = kma_warn_aws.normalize_warnings(text)
    if skipped:
        log.info("warnings skipped %d", len(skipped))
    return store.upsert_warnings(rows, list(kma_warn_aws.OUR_REGIONS))


def run_aws(run_id: int) -> int:
    t = fetch.kma_times()
    # 1분치만 요청 (9/26 확인된 호출 방식). 10분 구간 요청은 기상청 쪽에서 504·빈 응답이 잦았음
    # 그 분이 아직 안 들어왔으면 2분 전 값으로 한 번 더
    obs, text = [], ""
    for tm in (t["AWS_TM"], t["AWS_TM_PREV"]):
        text = _kma(f"kma_aws_min_{AWS_STN}", "typ01/cgi-bin/url/nph-aws2_min",
                    {"tm1": tm, "tm2": tm, "stn": AWS_STN, "disp": "1", "help": "1"}, SLOW_TIMEOUT)
        obs = kma_warn_aws.normalize_aws_min(text)
        if obs:
            break
    if not obs:
        raise fetch.FetchError(f"AWS {AWS_STN} 자료 없음 ({t['AWS_TM_PREV']}·{t['AWS_TM']}): {text.strip()[:80]!r}")
    store.upsert_stations([kma_warn_aws.aws_station(AWS_STN)])
    return store.insert_observations(obs, run_id)


def run_typhoon(run_id: int) -> int:
    t = fetch.kma_times()
    names = kma_typhoon.parse_list(_kma("kma_typ_list", "typ01/url/typ_lst.php",
                                        {"YY": t["YEAR"], "disp": "1", "help": "1"}, SLOW_TIMEOUT))
    active = [c for c, v in names.items() if v["active"]]
    if not active and settings.fetch_mode != "replay":
        raise SkipJob("진행 중인 태풍 없음")
    text = _kma("kma_typ_now", "typ01/url/typ_now.php", {"tm": t["NOW_TM_UTC"], "mode": "1", "disp": "1", "help": "1"},
                SLOW_TIMEOUT)
    rows = kma_typhoon.normalize_tracks(text, names)
    if rows:
        for code, im in kma_typhoon.impact(rows).items():
            log.info("태풍 %s(%s) 구룡포 %skm, 최근접 %skm @%s, 강풍반경 진입예정=%s", code,
                     names.get(code, {}).get("name_ko"), im["now_distance_km"], im["closest_distance_km"],
                     im["closest_at"], im["will_enter_15ms"])
    return store.upsert_typhoon_tracks(rows)


# ------------------------------------------------------------------ 긴급재난문자 (행정안전부)
SAFETY_MSG_URL = "https://www.safetydata.go.kr/V2/api/DSSP-IF-00247"


def run_disaster_messages(run_id: int) -> int:
    """어제 날짜부터(자정 경계 누락 방지) 포항 수신 문자 → SN 기준 upsert. 0건은 정상 (문자 없는 날)"""
    since = (datetime.now(KST) - timedelta(days=1)).strftime("%Y%m%d")
    text = fetch.get("safety_msg_pohang", SAFETY_MSG_URL,
                     {"serviceKey": _need(settings.safetydata_key, "SAFETYDATA_KEY"), "returnType": "json",
                      "pageNo": "1", "numOfRows": "1000", "crtDt": since, "rgnNm": "포항"}).text
    rows, skipped = safety_msg.normalize(text)
    if skipped:
        log.info("disaster_messages skipped %d", len(skipped))
    return store.upsert_disaster_messages(rows)


# ------------------------------------------------------------------ 응급실 실시간 가용병상 (국립중앙의료원)
NMC_BEDS_URL = "https://apis.data.go.kr/B552657/ErmctInfoInqireService/getEmrrmRltmUsefulSckbdInfoInqire"


def run_er_beds(run_id: int) -> int:
    """포항 응급의료기관 5곳 가용병상. 병원이 입력한 시각(hvidate) 기준이라 같은 값은 PK 로 중복 저장 안 됨"""
    text = fetch.get("nmc_er_beds_pohang", NMC_BEDS_URL,
                     {"serviceKey": _need(settings.data_go_kr_key, "DATA_GO_KR_KEY"), "STAGE1": "경상북도",
                      "STAGE2": "포항시", "pageNo": "1", "numOfRows": "50"}).text
    rows = nmc_er.availability(text)
    if not rows:
        raise fetch.FetchError("응급실 가용병상 0건")
    return store.insert_er_availability(rows)


# ------------------------------------------------------------------ 판정 (A3)
def run_flood_risk(run_id: int) -> int:
    from risk import engine
    return engine.run(run_id)


def run_hazards_risk(run_id: int) -> int:
    from risk import hazards
    return hazards.run(run_id)


def run_alerts(run_id: int) -> int:
    from alerts import dispatch
    return dispatch.run(run_id)


def run_evac_followup(run_id: int) -> int:
    from alerts import evacuation
    return evacuation.run_followups(run_id)


# ------------------------------------------------------------------ 목록
EVERY_10 = {"minute": "*/10"}
JOBS: list[Job] = [
    Job("pohang_dt", "water_level", run_water_level, EVERY_10),
    Job("pohang_dt", "air_realtime", run_air_realtime, EVERY_10),
    Job("pohang_dt", "uv", run_uv, EVERY_10, stale_after_min=90),       # 자외선은 90분 이내 값만 판단에 사용
    Job("pohang_dt", "air_devices", run_air_devices, {"hour": "4", "minute": "5"}, stale_after_min=26 * 60),
    Job("kma", "warnings", run_warnings, EVERY_10),
    Job("kma", "aws", run_aws, EVERY_10),
    Job("kma", "ncst", run_ncst, {"minute": "45"}, stale_after_min=130),
    Job("kma", "ultra_fcst", run_ultra_fcst, {"minute": "20"}, stale_after_min=130),
    Job("kma", "vilage_fcst", run_vilage_fcst, {"hour": "2,5,8,11,14,17,20,23", "minute": "20"}, stale_after_min=7 * 60),
    Job("kma", "mid_fcst", run_mid_fcst, {"hour": "6,18", "minute": "30"}, stale_after_min=26 * 60),
    # 재난문자: 일일 호출 한도 1,000회 → 2분 = 720회/일 (재시작·수동 테스트·개발 PC 여유 280회). 86초 미만은 한도 초과
    Job("nmc", "er_beds", run_er_beds, EVERY_10, stale_after_min=40),    # 응급실 가용병상 (일 144회)
    Job("safety24", "disaster_messages", run_disaster_messages, {"minute": "*/2"}, stale_after_min=10),
    Job("kma", "typhoon", run_typhoon, {"hour": "*/3", "minute": "10"}, stale_after_min=7 * 60),
    # 판정은 수위 수집(매 10분 정각) 1분 뒤 — 수집 직후 값으로 판정
    Job("risk", "flood", run_flood_risk, {"minute": "1-59/10"}),
    # A4: 호우·강풍(AWS 10분 수집)·산사태(호우 단계 + 취약지역) — AWS 수집(매 10분 정각) 2분 뒤
    Job("risk", "hazards", run_hazards_risk, {"minute": "2-59/10"}),
    # A5 선제 경고: 판정 2개가 끝난 뒤(매 10분 3분) 판정 결과·재난문자 → 대상 사용자 경고 + FCM
    Job("risk", "alerts", run_alerts, {"minute": "3-59/10"}),
    # A12 대피 확인 후속: 미응답 2분 재알림·10분 이관, 대피 중 10분 재확인 — 2분 간격을 지키려고 1분마다
    Job("risk", "evac_followup", run_evac_followup, {"minute": "*"}, stale_after_min=10),
]
BY_KEY = {j.key: j for j in JOBS}


def find(source: str, job: str) -> Job | None:
    return BY_KEY.get(f"{source}.{job}")


def execute(j: Job, run_id: int | None = None) -> dict:
    """작업 1회 실행. 예외를 밖으로 내지 않고 결과 dict 반환 (스케줄러가 멈추지 않게)."""
    t0 = time.monotonic()
    run_id = run_id or store.start_run(j.source, j.job)
    try:
        n = j.run(run_id)
        store.finish_run(run_id, n)
        res = {"job": j.key, "status": "success", "rows": n}
    except SkipJob as e:
        store.finish_run(run_id, 0)
        res = {"job": j.key, "status": "skipped", "rows": 0, "reason": str(e)}
    except Exception as e:  # noqa: BLE001 — 원천 API 오류는 다양함
        store.fail_run(run_id, f"{type(e).__name__}: {e}")
        log.exception("수집 실패 %s", j.key)
        res = {"job": j.key, "status": "failed", "error": f"{type(e).__name__}: {e}"}
    res.update(ingest_run_id=run_id, sec=round(time.monotonic() - t0, 2))
    log.info("%s", res)
    return res

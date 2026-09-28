"""행정안전부 긴급재난문자 (재난안전데이터공유플랫폼 DSSP-IF-00247) → disaster_messages

API  https://www.safetydata.go.kr/V2/api/DSSP-IF-00247?serviceKey=&returnType=json&pageNo=&numOfRows=&crtDt=YYYYMMDD&rgnNm=포항
  - crtDt: 이 날짜 **이후** 생성분 (조회 시작일). 조건 없이 부르면 2023년부터 오래된 순 → 반드시 crtDt 지정
  - rgnNm: 수신지역명 부분일치 ('포항' → 포항시 남구·북구)
  - **등록된 IP 에서만 호출 가능** (미등록 시 header.resultCode '32' UNREGISTERED IP ERROR) → 배포 VM 고정 IP 등록 필요
  - 응답: {"header":{"resultCode":"00",...},"numOfRows","pageNo","totalCount","body":[ {...}, ... ]}  (body 가 배열)
  - 항목: SN(일련번호) · CRT_DT '2026/09/27 13:31:31'(발송) · REG_YMD(플랫폼 등록, 발송 +약 20초) · MSG_CN(본문)
          RCPTN_RGN_NM '경상북도 포항시 남구 ,경상북도 포항시 북구 ' · EMRG_STEP_NM(안전안내/긴급재난/위급재난) · DST_SE_NM(재해구분)
  - 지연: 2026-09-27 확인분 발송(CRT_DT) → API 등록(REG_YMD) 약 20초. 우리 수집 주기(5분)가 지연의 대부분
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))

# DST_SE_NM(재해구분) → hazard_type. 매핑 없으면 hazard NULL (category 원문은 그대로 저장)
DST_HAZARD = {"호우": "heavy_rain", "태풍": "typhoon", "강풍": "strong_wind", "풍랑": "high_seas",
              "홍수": "flood", "침수": "flood", "산사태": "landslide", "미세먼지": "fine_dust",
              "초미세먼지": "ultrafine_dust"}


class SafetyMsgError(Exception):
    pass


def _items(resp):
    d = json.loads(resp) if isinstance(resp, str) else resp
    h = d.get("header") or {}
    if h.get("resultCode") != "00":
        raise SafetyMsgError(f"재난문자 {h.get('resultCode')} {h.get('resultMsg')} {h.get('errorMsg') or ''}".strip())
    body = d.get("body")
    return body if isinstance(body, list) else []


def _kst(s: str):
    s = (s or "").strip().split(".")[0].replace("-", "/")
    for fmt in ("%Y/%m/%d %H:%M:%S", "%Y/%m/%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=KST)
        except ValueError:
            pass
    return None


def normalize(resp, region_keyword: str = "포항"):
    """→ (rows, skipped). region_keyword 가 수신지역에 없는 문자는 제외 (API rgnNm 필터의 이중 확인)"""
    rows, skipped = [], []
    for m in _items(resp):
        region = ", ".join(x.strip() for x in (m.get("RCPTN_RGN_NM") or "").split(",") if x.strip())
        sent = _kst(m.get("CRT_DT"))
        if m.get("SN") is None or sent is None or not m.get("MSG_CN"):
            skipped.append({"item": m, "reason": "SN/CRT_DT/MSG_CN 없음"}); continue
        if region_keyword and region_keyword not in region:
            skipped.append({"item": m, "reason": f"수신지역에 '{region_keyword}' 없음"}); continue
        sender = re.search(r"\[([^\]]+)\]", m["MSG_CN"])
        cat = (m.get("DST_SE_NM") or "").strip() or None
        rows.append({
            "external_id": str(m["SN"]), "sent_at": sent.isoformat(),
            "sender": sender.group(1).strip() if sender else None, "region_name": region,
            "category": cat, "hazard": DST_HAZARD.get(cat or ""),
            "alert_class": (m.get("EMRG_STEP_NM") or "").strip() or None,
            "message": m["MSG_CN"].strip(), "raw": m,
        })
    return rows, skipped


UPSERT_MESSAGE_SQL = """
INSERT INTO disaster_messages (external_id, sent_at, sender, region_name, category, hazard, alert_class, message, raw)
VALUES (%(external_id)s, %(sent_at)s, %(sender)s, %(region_name)s, %(category)s, %(hazard)s, %(alert_class)s,
        %(message)s, %(raw)s::jsonb)
ON CONFLICT (external_id) DO UPDATE
SET sent_at = EXCLUDED.sent_at, sender = EXCLUDED.sender, region_name = EXCLUDED.region_name,
    category = EXCLUDED.category, hazard = EXCLUDED.hazard, alert_class = EXCLUDED.alert_class,
    message = EXCLUDED.message, raw = EXCLUDED.raw
"""

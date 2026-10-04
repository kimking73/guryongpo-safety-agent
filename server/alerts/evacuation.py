"""대피 확인 (A12) — 응답 기록 · 재알림 · 방재단 이관

시간 규칙 (2026-10-03 팀 결정, 2026-10-04 '대피 중' 반복 결정 — 근거 정리 중: 프로젝트 문서 8-판단기준-근거현황 4절)
  미응답(no_response) : 경고 후 2분마다 재알림, 10분 지나면 방재단에 넘김(이관) — 넘긴 뒤에는 재알림 안 함
  도움 필요(need_help): 응답 즉시 이관 (이미 넘겼어도 다시 알림 — 더 급함)
  대피 중(evacuating)  : 10분마다 "도착하셨나요?" 재확인 (이관 없음)
  대피 완료(evacuated) : 끝
재알림·이관은 앱 사용자 대상(경고를 받은 사람)만. 앱 없는 등록 가구는 처음부터 방재단 목록에 있으므로 알림 없음.
수집기 job risk.evac_followup (1분마다) 가 run_followups() 를 실행한다.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from app import db
from risk.levels import HAZARD_KO, LEVEL_NUM
from . import fcm

log = logging.getLogger("alerts.evacuation")

REMINDER_INTERVAL_MIN = 2       # 응답 없으면 2분마다 다시 알림 (방재단에 넘길 때까지)
ESCALATE_AFTER_MIN = 10         # 응답 없으면 10분 뒤 방재단에 넘김
EVACUATING_RECHECK_MIN = 10     # '대피 중'이면 10분마다 다시 확인
RULES = {"reminder_interval_min": REMINDER_INTERVAL_MIN, "escalate_after_min": ESCALATE_AFTER_MIN,
         "evacuating_recheck_min": EVACUATING_RECHECK_MIN}

Action = Literal["reminder", "escalate"]


def next_action(t: dict, now: datetime) -> Optional[Action]:
    """대상 1개에 지금 할 일. t: status, created_at, status_at, last_reminder_at, escalated_at, user_id, alert_id"""
    if not t.get("user_id") or not t.get("alert_id"):
        return None                                        # 앱 없는 등록 가구 → 방재단 목록만
    status = t["status"]
    if status == "no_response":
        if t.get("escalated_at"):
            return None
        if now - t["created_at"] >= timedelta(minutes=ESCALATE_AFTER_MIN):
            return "escalate"
        last = t.get("last_reminder_at") or t["created_at"]
        return "reminder" if now - last >= timedelta(minutes=REMINDER_INTERVAL_MIN) else None
    if status == "evacuating":
        base = t.get("status_at") or t["created_at"]
        last = max(base, t["last_reminder_at"]) if t.get("last_reminder_at") else base
        return "reminder" if now - last >= timedelta(minutes=EVACUATING_RECHECK_MIN) else None
    return None


# ------------------------------------------------------------------ 응답 기록
RECORD_SQL = """
UPDATE care.incident_targets SET status = %(status)s::evac_status, status_via = %(via)s::response_via, status_at = now(),
       last_location = COALESCE(ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), last_location),
       note = COALESCE(%(note)s, note), updated_at = now()
WHERE id = ANY(%(ids)s::uuid[])
RETURNING id
"""
# 앱 사용자가 본인 등록 가구이기도 하면 같은 상황의 가구 대상도 같은 상태로 (방재단이 두 번 보지 않게)
LINKED_SQL = """
SELECT t.id FROM care.incident_targets t JOIN care.households h ON h.id = t.household_id
WHERE t.incident_id = %(iid)s AND h.linked_user_id = %(uid)s
"""
HISTORY_SQL = """
INSERT INTO care.evacuation_responses (target_id, status, via, by_user_id, location, note)
VALUES (%(tid)s, %(status)s::evac_status, %(via)s::response_via, %(by)s,
        ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), %(note)s)
"""


def record(target: dict, status: str, via: str, by_user_id: Optional[str] = None,
           location: Optional[dict] = None, note: Optional[str] = None) -> list[str]:
    """대상 상태 변경 + 이력. target: {id, incident_id, user_id}. 반환: 바뀐 대상 id 들"""
    ids = [str(target["id"])]
    if target.get("user_id"):
        ids += [str(r["id"]) for r in db.fetch_all(LINKED_SQL, {"iid": target["incident_id"], "uid": target["user_id"]})
                if str(r["id"]) not in ids]
    loc = location or {}
    p = {"status": status, "via": via, "lat": loc.get("lat"), "lng": loc.get("lng"), "note": note, "by": by_user_id}
    db.execute(RECORD_SQL, {**p, "ids": ids})
    db.execute_many(HISTORY_SQL, [{**p, "tid": i} for i in ids])
    if status == "need_help":
        escalate(str(target["id"]), "need_help")
    return ids


# ------------------------------------------------------------------ 이관 (방재단·담당 생활지원사에게)
ESCALATE_SQL = """
UPDATE care.incident_targets t SET escalated_at = COALESCE(t.escalated_at, now()), updated_at = now()
FROM care.incidents i
WHERE t.id = %(tid)s AND i.id = t.incident_id
RETURNING t.id, t.incident_id, t.note, i.title, i.hazard::text AS hazard, i.level::text AS level,
          (SELECT h.label FROM care.households h WHERE h.id = t.household_id) AS label
"""
# 받는 사람: 방재단·관리자 전원 + 이 대상 가구(또는 앱 사용자 본인 가구)의 담당 생활지원사
RECIPIENTS_SQL = """
SELECT DISTINCT d.fcm_token FROM user_devices d JOIN users u ON u.id = d.user_id
WHERE d.fcm_token IS NOT NULL AND (
  u.role IN ('responder', 'admin')
  OR u.id IN (SELECT h.caregiver_user_id FROM care.incident_targets t
              JOIN care.households h ON h.id = t.household_id OR h.linked_user_id = t.user_id
              WHERE t.id = %(tid)s))
"""
REASON_KO = {"need_help": "도움 요청", "no_response": f"{ESCALATE_AFTER_MIN}분 미응답"}


def escalate(target_id: str, reason: Literal["need_help", "no_response"]) -> dict:
    t = db.fetch_one(ESCALATE_SQL, {"tid": target_id})
    if not t:
        return {}
    who = t.get("label") or "앱 사용자"
    body = f"{t['title']} · {who}" + (f" — {t['note']}" if reason == "need_help" and t.get("note") else "")
    pushes = [fcm.Push(token=r["fcm_token"], title=f"[{REASON_KO[reason]}] {who}", body=body,
                       data=fcm.payload("escalation", incident_id=t["incident_id"], target_id=t["id"], hazard=t["hazard"],
                                        level=t["level"], level_num=LEVEL_NUM[t["level"]], action="open_incident"))
              for r in db.fetch_all(RECIPIENTS_SQL, {"tid": target_id})]
    log.info("이관 %s (%s) → %d명", target_id, reason, len(pushes))
    return fcm.send(pushes)


# ------------------------------------------------------------------ 재알림
FOLLOWUP_SQL = """
SELECT t.id, t.incident_id, t.user_id, t.alert_id, t.status::text AS status, t.created_at, t.status_at,
       t.last_reminder_at, t.escalated_at, i.hazard::text AS hazard, i.level::text AS level, a.tts_text
FROM care.incident_targets t
JOIN care.incidents i ON i.id = t.incident_id AND i.closed_at IS NULL
LEFT JOIN user_alerts a ON a.id = t.alert_id
WHERE t.status IN ('no_response', 'evacuating') AND t.user_id IS NOT NULL AND t.alert_id IS NOT NULL
"""
REMINDED_SQL = """
UPDATE care.incident_targets SET reminder_count = reminder_count + 1, last_reminder_at = now(), updated_at = now()
WHERE id = %(tid)s
"""
DEVICES_SQL = "SELECT fcm_token FROM user_devices WHERE user_id = %(uid)s AND fcm_token IS NOT NULL"
REMINDER_TEXT = {
    "no_response": ("[대피 확인] 아직 응답이 없어요", "지금 안전하신가요? '대피 완료', '대피 중', '도움 필요' 중 하나를 눌러 주세요."),
    "evacuating": ("[대피 확인] 대피소에 도착하셨나요?", "도착하셨으면 '대피 완료', 이동이 어려우면 '도움 필요'를 눌러 주세요."),
}


def remind(t: dict) -> None:
    db.execute(REMINDED_SQL, {"tid": t["id"]})
    title, body = REMINDER_TEXT[t["status"]]
    hz = HAZARD_KO.get(t["hazard"], t["hazard"])
    fcm.send([fcm.Push(token=r["fcm_token"], title=title, body=f"{hz} 대피 상황입니다. {body}",
                       data=fcm.payload("reminder", alert_id=t["alert_id"], incident_id=t["incident_id"],
                                        hazard=t["hazard"], level=t["level"], level_num=LEVEL_NUM[t["level"]],
                                        action="respond", tts_text=t.get("tts_text")))
              for r in db.fetch_all(DEVICES_SQL, {"uid": t["user_id"]})])


def run_followups(run_id: Optional[int] = None, now: Optional[datetime] = None) -> int:
    """진행 중 대피 상황의 재알림·이관 1회. 반환: 처리한 대상 수"""
    now = now or datetime.now(timezone.utc)
    n = 0
    for t in db.fetch_all(FOLLOWUP_SQL):
        act = next_action(t, now)
        if act == "reminder":
            remind(t)
        elif act == "escalate":
            escalate(str(t["id"]), "no_response")
        if act:
            n += 1
    if n:
        log.info("대피 확인 후속: %d건", n)
    return n

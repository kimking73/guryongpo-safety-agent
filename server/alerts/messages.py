"""경고 문구 — 템플릿 (B4 '선제 경고 메시지 생성 함수'가 나오기 전까지)

B4 함수로 바꿀 때는 compose() 의 입출력만 지키면 된다.
  입력 event: {kind, hazard, level, reason(판정 근거 문장), message(재난문자 원문, 문자일 때만),
               also(묶어서 함께 알리는 재난 [{hazard, level}]), notice(방재단 수동 시작 안내문)}
  입력 user : {trigger, place_label, birth_year, walking_ability, mobility, occupation, owns_vessel,
               vision_impaired, hearing_impaired, user_type, contact{name, relation, phone}}
  출력      : {title, body, tts_text, actions[], reason{trigger, place_label, profile_tags[]}}
행동 문장은 action_guides(포항시·국민재난안전포털·기상청 행동요령) 내용을 짧게 줄인 것.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from risk.levels import HAZARD_KO

LEVEL_KO = {"normal": "정상", "watch": "관심", "advisory": "주의", "warning": "경보", "critical": "위험"}

ACTION = {
    "flood": "맨홀·배수구·지하 공간을 피해 높은 곳으로 이동하세요.",
    "heavy_rain": "하천·해안가·비탈면 가까이 가지 말고 안전한 실내에 머무르세요.",
    "landslide": "비탈면·옹벽에서 멀리 떨어져 산 반대쪽 높은 곳이나 대피소로 이동하세요.",
    "strong_wind": "간판·공사장·해안가를 피하고 창문에서 떨어진 실내에 머무르세요.",
    "typhoon": "외출을 삼가고, 해안가·저지대에 계시면 대피소로 이동하세요.",
    "high_seas": "바다 출입과 조업을 멈추고 방파제·해안가에서 떨어지세요.",
    "fine_dust": "외출을 줄이고, 나가야 하면 보건용 마스크(KF80 이상)를 쓰세요.",
    "ultrafine_dust": "외출을 줄이고, 나가야 하면 보건용 마스크(KF80 이상)를 쓰세요.",
    "uv": "한낮(10~15시) 외출을 줄이고 모자·긴소매·자외선 차단제를 쓰세요.",
}
SEA_HAZARDS = {"flood", "heavy_rain", "typhoon", "high_seas", "strong_wind"}
BUTTONS = ["evacuated", "evacuating", "need_help"]
ELDERLY_AGE = 65


def profile_tags(u: dict, now: Optional[datetime] = None) -> list[str]:
    year = (now or datetime.now()).year
    tags = []
    if u.get("birth_year") and year - int(u["birth_year"]) >= ELDERLY_AGE:
        tags.append("elderly")
    if u.get("walking_ability") in ("limited", "unable") or u.get("mobility") == "wheelchair":
        tags.append("walking_limited")
    if (u.get("occupation") or "") == "fisher":
        tags.append("fisher")
    if u.get("owns_vessel"):
        tags.append("vessel_owner")
    if u.get("vision_impaired"):
        tags.append("vision_impaired")
    if u.get("hearing_impaired"):
        tags.append("hearing_impaired")
    if u.get("user_type") == "tourist":
        tags.append("tourist")
    return tags


def _where(u: dict) -> tuple[str, str]:
    """(제목용, 문장용)"""
    t = u.get("trigger")
    if t == "place" and u.get("place_label"):
        return f"'{u['place_label']}' 주변", f"등록하신 '{u['place_label']}'이(가)"
    if t == "broadcast":
        return "구룡포읍", "구룡포읍 일대가"
    return "현재 위치", "지금 계신 곳이"


def _extra(kind: str, hazard: str, tags: list[str]) -> list[str]:
    out = []
    if kind == "evacuation" and "walking_limited" in tags:
        out.append("보행이 불편하시면 무리해서 혼자 움직이지 마세요.")
    elif "walking_limited" in tags or "elderly" in tags:
        out.append("가족이나 이웃에게 상황을 알리고, 필요하면 도움을 요청하세요.")
    if hazard in SEA_HAZARDS and ("fisher" in tags or "vessel_owner" in tags):
        out.append("선박 점검·결박은 위험이 지나간 뒤에 하세요.")
    if "tourist" in tags and kind == "evacuation":
        out.append("가까운 대피소는 '대피 경로'에서 확인할 수 있어요.")
    return out


def compose(event: dict, u: dict) -> dict:
    kind, hazard, level = event["kind"], event["hazard"], event["level"]
    hz, lv = HAZARD_KO.get(hazard, hazard), LEVEL_KO.get(level, level)
    tags = profile_tags(u)
    where_t, where_s = _where(u)
    action = ACTION.get(hazard, "안전한 곳으로 이동하세요.")
    extra = _extra(kind, hazard, tags)
    also = [f"{HAZARD_KO.get(x['hazard'], x['hazard'])} {LEVEL_KO.get(x['level'], x['level'])}" for x in event.get("also") or []]
    also_s = [f"{'·'.join(also)}도 함께 발효 중입니다."] if also else []
    msg = event.get("message")

    if kind == "evacuation":
        title = f"[대피 확인] {hz} {lv} · {where_t}"
        if event.get("notice"):                          # 방재단이 직접 시작한 대피 상황의 안내문
            lead = f"방재단 안내: {event['notice'][:160]}"
        elif msg:
            lead = f"긴급재난문자: {msg[:120]}"
        else:
            lead = f"{event['reason']}." if event.get("reason") else f"{hz} {lv}입니다."
        body = " ".join([lead, *also_s, f"{where_s} 위험 영역 안입니다.", action, *extra,
                         "대피를 시작하셨으면 '대피 중', 대피소에 도착하셨으면 '대피 완료', 혼자 움직이기 어려우면 '도움 필요'를 눌러 주세요."])
        tts = (f"{hz} {lv}입니다. {' '.join(also_s) + ' ' if also_s else ''}{where_s} 위험 영역 안입니다. "
               "대피 완료, 대피 중, 도움 필요 중 하나를 말하거나 눌러 주세요.")
        actions = [{"type": "respond", "label": "대피 확인", "params": {"buttons": BUTTONS}},
                   {"type": "open_route", "label": "대피 경로", "params": {}},
                   {"type": "call", "label": "119", "params": {"phone": "119"}}]
    else:
        title = f"[{hz} {lv}] {where_t}"
        lead = f"{event['reason']}." if event.get("reason") else f"{where_s} {hz} {lv} 영역 안입니다."
        body = " ".join([lead, action, *extra])
        tts = f"{hz} {lv}입니다. {action}"
        actions = [{"type": "open_route", "label": "안전 경로", "params": {}}] if hazard in SEA_HAZARDS | {"landslide"} else []
        actions.append({"type": "open_checklist", "label": f"{hz} 체크리스트", "params": {"hazard": hazard}})
    c = u.get("contact")
    if c and c.get("phone") and ("elderly" in tags or "walking_limited" in tags or kind == "evacuation"):
        actions.append({"type": "call", "label": f"{c.get('relation') or c.get('name')}에게 전화",
                        "params": {"phone": c["phone"]}})
    return {"title": title, "body": body, "tts_text": tts, "actions": actions,
            "reason": {"trigger": u.get("trigger") or "current_location", "place_label": u.get("place_label"),
                       "profile_tags": tags}}

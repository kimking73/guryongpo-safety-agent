"""FCM 발송 (명세 FcmPayload) — firebase-admin messaging

- data 값은 전부 문자열 (FCM 규약). 앱은 알림을 누르면 GET /alerts 로 전체 내용을 다시 받는다
- evacuation: iOS 는 알림 카테고리 EVACUATION (앱이 같은 이름으로 버튼 3개 등록), Android 는 data.kind 로 앱이 버튼을 붙임 (C5·C6)
- Firebase 서비스 계정이 없으면 보내지 않고 skipped 로 집계 → 경고는 폴링(GET /alerts)으로 전달됨
- 만료·삭제된 토큰은 user_devices.fcm_token 을 비움
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field

from app import db

log = logging.getLogger("alerts.fcm")
EVAC_CATEGORY = "EVACUATION"
BATCH = 500                       # send_each 한 번에 최대 500건


@dataclass
class Push:
    token: str
    title: str
    body: str
    data: dict = field(default_factory=dict)
    ref: str | None = None            # 호출한 쪽 식별자 (경고 id) — 1건이라도 성공하면 stats["ok_refs"] 에 들어감


def payload(kind: str, **kw) -> dict:
    """FcmPayload data — None 은 빼고 모두 문자열로"""
    d = {"kind": kind, **kw}
    return {k: str(v) for k, v in d.items() if v is not None}


def _message(p: Push):
    from firebase_admin import messaging
    evac = p.data.get("kind") == "evacuation"
    return messaging.Message(
        token=p.token, data=p.data,
        notification=messaging.Notification(title=p.title, body=p.body),
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(channel_id="alerts")),       # 앱에 채널이 없으면 기본 채널
        apns=messaging.APNSConfig(payload=messaging.APNSPayload(
            aps=messaging.Aps(sound="default", category=EVAC_CATEGORY if evac else None))),
    )


def _app():
    from app import auth
    return auth._firebase_app if (auth._firebase_app is not None or auth.init_firebase()) else None


def send(pushes: list[Push]) -> dict:
    """반환: {sent, failed, invalid_tokens, skipped, ok_refs}. 예외를 밖으로 내지 않음 (경고 기록은 이미 끝난 뒤)"""
    stats = {"sent": 0, "failed": 0, "invalid_tokens": 0, "skipped": 0, "ok_refs": set()}
    if not pushes:
        return stats
    app = _app()
    if app is None:
        stats["skipped"] = len(pushes)
        log.info("FCM 건너뜀 (Firebase 미설정) %d건 — 폴링으로 전달", len(pushes))
        return stats
    from firebase_admin import messaging
    invalid = []
    for i in range(0, len(pushes), BATCH):
        chunk = pushes[i:i + BATCH]
        try:
            res = messaging.send_each([_message(p) for p in chunk], app=app)
        except Exception as e:  # noqa: BLE001
            log.warning("FCM 발송 실패 %d건: %s", len(chunk), e)
            stats["failed"] += len(chunk)
            continue
        for p, r in zip(chunk, res.responses):
            if r.success:
                stats["sent"] += 1
                if p.ref:
                    stats["ok_refs"].add(p.ref)
            else:
                stats["failed"] += 1
                if isinstance(r.exception, (messaging.UnregisteredError, messaging.SenderIdMismatchError)):
                    invalid.append(p.token)
    if invalid:
        stats["invalid_tokens"] = db.execute("UPDATE user_devices SET fcm_token = NULL WHERE fcm_token = ANY(%(t)s)",
                                             {"t": invalid})
    log.info("FCM sent=%d failed=%d invalid_tokens=%d", stats["sent"], stats["failed"], stats["invalid_tokens"])
    return stats

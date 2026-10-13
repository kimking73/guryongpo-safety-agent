"""방재단 전용 코드(초대 코드) 발급·목록·회수 (2026-10-12). 표준 라이브러리만 사용.

  python3 server/tools/invites.py issue --count 15 --label "구룡포읍 자율방재단 2026"   # 방재단 코드 15개
  python3 server/tools/invites.py issue --count 3 --role admin --label "구룡포읍 행정팀"  # 관리자 코드
  python3 server/tools/invites.py list                                                  # 발급한 코드 (원문 없음)
  python3 server/tools/invites.py revoke 7                                              # 7번 코드 회수

코드 원문은 발급할 때 한 번만 보인다 (서버에는 sha256 만 저장). 받은 코드는 나눠 줄 사람 이름과 함께 따로 보관하고,
저장소에는 올리지 않는다. 잃어버린 코드는 되살릴 수 없으니 회수하고 새로 발급한다.
코드 하나 = 계정 하나 (2026-10-13): 처음 넣은 계정에 묶이고, 그 계정만 다시 넣을 수 있다(휴대폰·웹 같은 계정은 OK).
다른 계정이 넣으면 거절된다. 로그아웃해도 코드는 그 계정에 묶인 채 — 다른 사람에게 주려면 회수하고 새로 발급한다.
회수해도 이미 그 코드로 받은 역할은 남는다 — 그 사람이 앱의 '방재단 로그인' 카드에서 로그아웃하거나 DB 에서 내려야 한다.

서버 주소: --base (기본 http://localhost:8000). /internal 은 X-Internal-Token — 환경 변수 API_INTERNAL_TOKEN 을 읽는다.
배포 VM 에서는 /api/v1/internal 이 밖에서 막혀 있으므로 api 컨테이너 안에서 실행한다 (토큰 환경 변수가 이미 있음):
  docker compose -f docker-compose.yml exec -T api python - issue --count 15 --label "구룡포읍 자율방재단 2026" < server/tools/invites.py
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

ROLE_KO = {"responder": "방재단", "caregiver": "생활지원사", "admin": "관리자"}


def call(base: str, method: str, path: str, body=None):
    headers = {"Content-Type": "application/json"}
    token = os.environ.get("API_INTERNAL_TOKEN")
    if token:
        headers["X-Internal-Token"] = token
    req = urllib.request.Request(base.rstrip("/") + "/api/v1/internal" + path, method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} 실패 {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")


def issue(a) -> None:
    body = {"role": a.role, "label": a.label, "max_uses": a.max_uses, "expires_in_days": a.days}
    rows = [call(a.base, "POST", "/invites", body) for _ in range(a.count)]
    print(f"# {ROLE_KO[a.role]} 코드 {len(rows)}개 · {a.label or '이름 없음'} · 만료 {rows[0]['expires_at'][:10]}"
          f" · 사용 횟수 {a.max_uses or '제한 없음'}")
    print("# 원문은 지금 한 번만 보입니다 — 받는 사람과 함께 따로 보관하세요")
    for i, r in enumerate(rows, 1):
        print(f"{i:>2}. {r['code']}")


def list_(a) -> None:
    rows = call(a.base, "GET", "/invites")
    if not rows:
        print("발급한 코드가 없습니다")
        return
    print(f"{'번호':>4}  {'역할':<6} {'사용':>6}  {'만료':<10}  {'상태':<4}  이름")
    for r in rows:
        used = f"{r['used_count']}/{r['max_uses'] or '∞'}"
        state = "회수" if r["revoked_at"] else "사용"
        print(f"{r['id']:>4}  {ROLE_KO.get(r['role'], r['role']):<6} {used:>6}  {(r['expires_at'] or '-')[:10]:<10}  {state:<4}  "
              f"{r['label'] or ''}")


def revoke(a) -> None:
    for i in a.ids:
        call(a.base, "DELETE", f"/invites/{i}")
        print(f"{i}번 코드를 회수했습니다")


def main() -> None:
    p = argparse.ArgumentParser(description="방재단 전용 코드 발급·목록·회수")
    p.add_argument("--base", default=os.environ.get("API_BASE", "http://localhost:8000"))
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("issue", help="코드 발급 (원문은 이때 한 번만)")
    s.add_argument("--count", type=int, default=1)
    s.add_argument("--role", choices=list(ROLE_KO), default="responder")
    s.add_argument("--label", default="구룡포읍 자율방재단")
    s.add_argument("--days", type=int, default=365, help="며칠 뒤 만료 (1–365, 기본 365)")
    s.add_argument("--max-uses", type=int, default=None, help="코드 하나로 로그인할 수 있는 횟수 (기본 제한 없음)")
    s.set_defaults(fn=issue)
    sub.add_parser("list", help="발급한 코드 목록 (원문 없음)").set_defaults(fn=list_)
    r = sub.add_parser("revoke", help="코드 회수 (번호는 list 로 확인)")
    r.add_argument("ids", type=int, nargs="+")
    r.set_defaults(fn=revoke)
    a = p.parse_args()
    if a.cmd == "issue" and not 1 <= a.count <= 100:
        sys.exit("--count 는 1–100")
    a.fn(a)


if __name__ == "__main__":
    main()

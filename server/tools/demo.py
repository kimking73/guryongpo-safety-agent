"""시연 스크립트 (A11) — 대피 확인 흐름을 명령 몇 개로 재현하고 정리한다. 표준 라이브러리만 사용.

  python3 server/tools/demo.py status                # 서버 상태
  python3 server/tools/demo.py prepare               # 시연용 가상 취약 가구 5곳 등록
  python3 server/tools/demo.py flood                 # 모의 호우·침수 → 판정 → 대피 확인 경고까지
  python3 server/tools/demo.py walkthrough [--step]  # 주민 응답 → 방재단 화면 → 방문 기록 (dev 모드 서버만)
  python3 server/tools/demo.py reset                 # 모의값·시연 가구·시연 사용자 정리

서버 주소: --base (기본 http://localhost:8000). /internal 은 X-Internal-Token — 환경 변수 API_INTERNAL_TOKEN 을 읽는다
(dev 모드에서 비어 있으면 헤더 없이 통과). 토큰은 화면에 출력하지 않는다.

배포 VM 에서는 /api/v1/internal 이 밖에서 막혀 있으므로 api 컨테이너 안에서 실행한다 (토큰 환경 변수가 이미 있음):
  docker compose -f docker-compose.yml exec -T api python - prepare < server/tools/demo.py
walkthrough 는 'Bearer dev:<uid>' 로 주민·방재단을 흉내 내므로 API_AUTH_MODE=dev 서버(로컬)에서만 된다.
배포 서버(firebase 모드)에서는 실제 앱으로 같은 순서를 진행하고, 이 스크립트는 prepare·flood·reset 만 쓴다.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

CITIZEN = "demo-citizen"          # 시연 주민 (dev uid)
RESPONDER = "responder-demo"      # 시연 방재단원 (dev uid — 'responder' 로 시작하면 방재단 역할)
HOME = {"lat": 35.99069, "lng": 129.556057}     # 구룡포환승센터 — heavy_rain_flood 의 침수 경보 영역 안


class Api:
    def __init__(self, base: str, token: str | None):
        self.base = base.rstrip("/") + "/api/v1"
        self.token = token

    def call(self, method: str, path: str, body=None, who: str | None = None, internal: bool = False):
        headers = {"Content-Type": "application/json"}
        if who:
            headers["Authorization"] = f"Bearer dev:{who}"
        if internal and self.token:
            headers["X-Internal-Token"] = self.token
        req = urllib.request.Request(self.base + path, method=method, headers=headers,
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                text = r.read().decode()
                return r.status, json.loads(text) if text else None
        except urllib.error.HTTPError as e:
            text = e.read().decode()
            try:
                return e.code, json.loads(text) if text else None
            except ValueError:
                return e.code, text

    def simulate(self, scenario: str) -> dict:
        st, d = self.call("POST", "/internal/simulate", {"scenario": scenario}, internal=True)
        if st != 202:
            sys.exit(f"시나리오 {scenario} 실패 ({st}): {d}")
        return d


def say(title: str, *lines: str) -> None:
    print(f"\n■ {title}")
    for x in lines:
        print(f"  {x}")


def pause(step: bool) -> None:
    if step:
        input("  (Enter 를 누르면 다음 단계)")


# ------------------------------------------------------------------ 명령
def status(api: Api, _a) -> None:
    st, h = api.call("GET", "/health")
    comps = ", ".join(f"{k}={v.get('status')}" for k, v in (h or {}).get("components", {}).items()) if isinstance(h, dict) else h
    say("서버 상태", f"HTTP {st} · {(h or {}).get('status') if isinstance(h, dict) else ''}", comps)


def prepare(api: Api, _a) -> None:
    d = api.simulate("demo_households")
    say("시연용 가상 취약 가구 등록", f"{d.get('households')}곳 (이전 시연 가구 {d.get('replaced', 0)}곳 교체) — 표시명 '[시연] …', 실제 개인정보 없음")


def flood(api: Api, _a) -> None:
    d = api.simulate("heavy_rain_flood")
    say("모의 호우·침수", f"위험 영역 {d.get('assessments')}개 · 판정 {d.get('risk_run')} · 새 경고 {d.get('new_alerts')}건 ({d.get('alerts_run')})",
        "→ 환승센터·수협 일대 침수 경보, 영역 안 사용자에게 대피 확인 경고 (방재단 화면에 시연 가구가 대상으로)")


def walkthrough(api: Api, a) -> None:
    st, _ = api.call("POST", "/user", {"birth_year": 1950, "walking_ability": "limited"}, who=CITIZEN)
    if st == 401:
        sys.exit("dev 토큰이 거절됨 — walkthrough 는 API_AUTH_MODE=dev 서버(로컬)에서만 됩니다")
    api.call("POST", "/user/places", {"place_type": "home", "label": "우리집", "address": "구룡포환승센터 앞 (시연)",
                                      "location": HOME}, who=CITIZEN)
    say("1. 주민: 집을 환승센터 앞에 등록 (보행 불편 어르신)")
    pause(a.step)

    alerts = api.call("GET", "/alerts", who=CITIZEN)[1]
    evac = next((x for x in alerts["alerts"] if x["response_required"]), None)
    if not evac:
        sys.exit("대피 확인 경고가 없음 — 먼저 `flood` 를 실행하세요")
    say("2. 주민 앱: 대피 확인 경고 도착", evac["title"], evac["body"], f"버튼: 대피 완료 / 대피 중 / 도움 필요")
    pause(a.step)

    st, r = api.call("POST", f"/alerts/{evac['id']}/response", {"status": "need_help", "via": "button",
                                                                "location": HOME, "note": "다리가 불편해 혼자 못 가요"},
                     who=CITIZEN)
    say("3. 주민: '도움 필요' 누름", f"응답 {st} — {r.get('message') if isinstance(r, dict) else r}",
        "→ 방재단·담당 생활지원사에게 즉시 이관 (푸시)")
    pause(a.step)

    iid = evac["incident_id"]
    d = api.call("GET", f"/admin/incidents/{iid}", who=RESPONDER)[1]
    s = d["summary"]
    say("4. 방재단 화면: 대피 현황", d["title"],
        f"대상 {s['total']} · 도움 필요 {s['need_help']} · 미응답 {s['no_response']} · 대피 중 {s['evacuating']} · 대피 완료 {s['evacuated']}"
        f" · 아직 방문 안 한 도움 요청 {s.get('unvisited_need_help')}",
        *[f"{t['priority_rank']}. {t['label']} — {t['status']}{' (이관됨)' if t['escalated'] else ''}"
          f"{' · ' + t['note'] if t.get('note') else ''}" for t in d["targets"][:6]])
    pause(a.step)

    first = d["targets"][0]
    st, v = api.call("POST", f"/admin/incidents/{iid}/targets/{first['id']}/visits",
                     {"result": "evacuated_with_help", "note": "부축해서 대피소 도착"}, who=RESPONDER)
    after = api.call("GET", f"/admin/incidents/{iid}", who=RESPONDER)[1]["summary"]
    mine = api.call("GET", "/alerts", who=CITIZEN)[1]["evacuation"]
    say("5. 방재단: 1순위 방문 → '함께 대피' 기록", f"방문 기록 {st} → 상태 {v.get('status_after') if isinstance(v, dict) else v}",
        f"집계: 방문 {after.get('visited')} · 아직 방문 안 한 도움 요청 {after.get('unvisited_need_help')} · 대피 완료 {after['evacuated']}",
        f"주민 앱 카드: {mine['status'] if mine else '없음'}")


def reset(api: Api, _a) -> None:
    api.simulate("clear")
    d = api.simulate("demo_households_clear")
    gone = [who for who in (CITIZEN, RESPONDER) if api.call("DELETE", "/user", who=who)[0] == 204]
    say("정리", "모의 관측값 삭제 → 판정 해제 → 대피 상황 종료",
        f"시연 가구 {d.get('removed_households')}곳 삭제", f"시연 사용자 삭제: {', '.join(gone) or '없음 (firebase 모드)'}")


COMMANDS = {"status": status, "prepare": prepare, "flood": flood, "walkthrough": walkthrough, "reset": reset}


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(description="구룡가디언 시연 (A11)")
    p.add_argument("command", choices=list(COMMANDS))
    p.add_argument("--base", default=os.environ.get("DEMO_BASE_URL", "http://localhost:8000"))
    p.add_argument("--step", action="store_true", help="walkthrough 단계마다 Enter 로 넘김 (발표용)")
    a = p.parse_args(argv)
    COMMANDS[a.command](Api(a.base, os.environ.get("API_INTERNAL_TOKEN") or os.environ.get("INTERNAL_TOKEN")), a)


if __name__ == "__main__":
    main()

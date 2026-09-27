"""포항/구룡포 디지털 트윈 API 일괄 호출기
사용법:  cd tools && python3 fetch_dt.py            # 전부 호출
         python3 fetch_dt.py 수위계                # 이름에 '수위계'가 들어간 것만
- API 목록: tools/dt_apis.json   (url/params/headers 안에 ${변수} 를 쓰면 dt_config.txt 값으로 치환)
- 키·주소: server/dt_config.txt (.gitignore 등록 — 절대 커밋 금지. 형식은 KEY=값 줄)
- 결과:    mock/external/<name>.json (원문 그대로) + 콘솔 요약
표준 라이브러리만 사용 — 설치 필요 없음.
"""
import json, os, re, sys, ssl, subprocess, urllib.request, urllib.parse
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "mock" / "external"

def load_env():
    env = dict(os.environ)
    f = ROOT / "dt_config.txt"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def kma_times(now=None):
    """기상청 동네예보 base_date/base_time 자동 계산 (KST, 발표 후 반영 지연 고려)
    초단기실황: 매시 정각 발표, 약 40분 후 조회 가능
    초단기예보: 매시 30분 발표, 약 45분 후 조회 가능
    단기예보  : 02·05·08·11·14·17·20·23시 발표, 약 10분 후 조회 가능 (여유 15분)"""
    from datetime import timedelta, timezone
    kst = timezone(timedelta(hours=9))
    now = (now or datetime.now(kst)).astimezone(kst)
    t = now - timedelta(minutes=40); ncst = t.replace(minute=0)
    t = now - timedelta(minutes=45); fcst = t.replace(minute=30) if t.minute >= 30 else t.replace(minute=30) - timedelta(hours=1)
    t = now - timedelta(minutes=15)
    h = max([x for x in (2, 5, 8, 11, 14, 17, 20, 23) if x <= t.hour], default=None)
    vil = t.replace(hour=h, minute=0) if h is not None else (t - timedelta(days=1)).replace(hour=23, minute=0)
    f = lambda d: (d.strftime("%Y%m%d"), d.strftime("%H%M"))
    out = {}
    # 중기예보: 06·18시 발표 (여유 20분), 최근 24시간치만 조회 가능
    t = now - timedelta(minutes=20)
    mid = t.replace(hour=18, minute=0) if t.hour >= 18 else t.replace(hour=6, minute=0) if t.hour >= 6 else (t - timedelta(days=1)).replace(hour=18, minute=0)
    out["MID_TMFC"] = mid.strftime("%Y%m%d%H%M")
    # AWS 매분: 3분 전 (전송 지연), AWS 시간통계: 직전 정시
    out["AWS_TM"] = (now - timedelta(minutes=3)).strftime("%Y%m%d%H%M")
    out["AWSH_TM"] = now.replace(minute=0).strftime("%Y%m%d%H%M")
    out["YEAR"] = now.strftime("%Y")
    out["NOW_TM"] = (now - timedelta(minutes=5)).strftime("%Y%m%d%H%M")
    out["NOW_TM_UTC"] = (now - timedelta(minutes=5)).astimezone(timezone.utc).strftime("%Y%m%d%H%M")  # 태풍 API 는 UTC
    for k, d in (("NCST", ncst), ("FCST", fcst), ("VIL", vil)):
        out[k + "_DATE"], out[k + "_TIME"] = f(d)
    return out


def sub(obj, env):
    if isinstance(obj, str):
        def rep(m):
            if m.group(1) not in env:
                raise KeyError(f"dt_config.txt 에 {m.group(1)} 가 없음")
            return env[m.group(1)]
        return re.sub(r"\$\{(\w+)\}", rep, obj)
    if isinstance(obj, dict):
        return {k: sub(v, env) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sub(v, env) for v in obj]
    return obj

def decode(b: bytes) -> str:
    """UTF-8 우선, 실패하면 EUC-KR(CP949) — 기상청 typ01 텍스트 응답 대비"""
    for enc in ("utf-8", "cp949"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            pass
    return b.decode("utf-8", errors="replace")


def call(api, env):
    a = sub(api, env)
    url = a["url"]
    if a.get("params"):
        # 이미 인코딩된 키(%2B 등)가 이중 인코딩되지 않도록 먼저 디코딩 후 한 번만 인코딩
        params = {k: urllib.parse.unquote(str(v)) for k, v in a["params"].items()}
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    body = None
    headers = {"User-Agent": "guryong-fetch/1.0", **a.get("headers", {})}
    if a.get("json") is not None:
        body = json.dumps(a["json"]).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=headers, method=a.get("method", "GET"))
    ctx = ssl.create_default_context()
    if a.get("insecure"):          # 인증서 문제가 있는 기관 서버용 (필요할 때만)
        ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=a.get("timeout", 20), context=ctx) as r:
            return r.status, decode(r.read())
    except urllib.error.URLError as e:
        if "CERTIFICATE_VERIFY_FAILED" not in str(e):
            raise
        # 파이썬 인증서 저장소 문제 → macOS 시스템 인증서를 쓰는 curl 로 재시도
        cmd = ["curl", "-sS", "--max-time", str(a.get("timeout", 20)), "-X", a.get("method", "GET"),
               "-w", "\n%{http_code}", url]
        for k, v in headers.items():
            cmd += ["-H", f"{k}: {v}"]
        if body:
            cmd += ["--data-binary", body.decode()]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(f"curl 도 실패: {r.stderr.decode(errors='replace').strip()}") from None
        body_b, _, code = r.stdout.rpartition(b"\n")
        return int(code), decode(body_b)

def main():
    env = load_env()
    env.update(kma_times())
    apis = json.loads((Path(__file__).parent / "dt_apis.json").read_text(encoding="utf-8"))
    flt = sys.argv[1] if len(sys.argv) > 1 else None
    OUT.mkdir(parents=True, exist_ok=True)
    ok = fail = 0
    for api in apis:
        if api.get("skip") or (flt and flt not in api["name"]):
            continue
        name = api["name"]
        try:
            status, text = call(api, env)
            s = text.strip()
            try:                                   # 앞 '{' 누락 보정 포함
                data = json.loads(s if s.startswith(("{", "[")) else "{" + s)
                (OUT / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
                n = len(data.get("data", [])) if isinstance(data, dict) and isinstance(data.get("data"), list) else "-"
                rs = data.get("rspns_rslt", {}) if isinstance(data, dict) else {}
                hd = (data.get("response") or {}).get("header") if isinstance(data, dict) else None
                if hd:   # 기상청: resultCode '00' = 정상
                    rs = {"rslt_cd": "0" if hd.get("resultCode") == "00" else "E" + str(hd.get("resultCode")),
                          "rslt_msg": hd.get("resultMsg", "")}
                    items = (((data["response"].get("body") or {}).get("items") or {}).get("item")) or []
                    n = len(items)
                tag = "OK  " if not rs or str(rs.get("rslt_cd", "")).startswith(("0", "2")) else "ERR "
                print(f"{tag} {name:30s} HTTP {status}  items={n}  {rs.get('rslt_cd','')} {rs.get('rslt_msg','')}")
            except json.JSONDecodeError:
                (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
                print(f"OK   {name:30s} HTTP {status}  (JSON 아님 → .txt 저장, 앞부분: {s[:60]!r})")
            ok += 1
        except Exception as e:
            print(f"FAIL {name:30s} {type(e).__name__}: {e}")
            fail += 1
    print(f"\n{datetime.now():%H:%M:%S}  성공 {ok} / 실패 {fail}  → {OUT}")

if __name__ == "__main__":
    main()

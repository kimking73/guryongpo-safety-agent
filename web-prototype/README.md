# 구룡포 안전 비서

Claude Design에서 만든 웹 디자인(`구룡포 안전.dc.html`, 데스크톱 화면)을 React + Vite로 옮긴 시연용 앱.
팀 앱(`app/`, Flutter)과는 별개이며, 서버에 연결하지 않고 예시 데이터로만 동작한다.

```bash
npm install
npm run dev      # 개발 서버
npm run build    # dist/ 에 정적 파일 생성 (아무 웹 호스팅에 올리면 됨)
```

## 시연 설정 (디자인의 Tweaks)

URL 쿼리로 처음 값을 정한다. `?tweaks`를 붙이면 오른쪽 아래에 설정 패널이 뜬다.

| 쿼리 | 뜻 | 기본 |
| --- | --- | --- |
| `start=dash\|chat\|user` | 시작 화면 | `dash` |
| `onboarding=0` | 초기 화면 건너뛰기 | 표시 |
| `evac=1` | 대피 필요 상태로 시작 | 꺼짐 |
| `fast=1` | 빠른 시연 (1초 = 1분) | 꺼짐 |
| `offline=1` | 오프라인 표시 시연 | 꺼짐 |

예: `/?onboarding=0&evac=1&fast=1&tweaks`

## 구조

- `src/App.jsx` — 전체 상태, 1초 타이머(대피 재확인 · 무응답 · 방재단 진행), 화면 전환
- `src/logic.js` — 상태 계산 (우선순위 정렬, 체크리스트, 예시 답변, 맞춤 안내)
- `src/data.js` — 재난문자 · 경보 · 날씨 · 대피소 · 가구 예시 데이터
- `src/screens/` — 초기 화면, 대시보드, AI 대화창, 사용자, 방재단 현황
- `src/modals/` — 경보 상세, 날씨 상세, 이메일 로그인, 대피 알림

모든 수치 · 문구 · 가구 정보는 예시이며, 지도는 아직 실제 지도가 아니다.

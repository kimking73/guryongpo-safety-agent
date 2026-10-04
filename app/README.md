# 구룡포 안전 목업

구룡포의 호우, 침수, 산사태, 강풍 및 태풍 대응 흐름을 검증하기 위한 Flutter 동작형 시제품입니다. 화면의 위험도, 시설, 경로, 알림과 AI 답변은 모두 **예시 데이터**이며 실제 재난 경보나 대피 지시가 아닙니다.

## 포함된 기능

- Firebase 익명 인증 초기화: Firebase 설정이 없으면 자동으로 안전한 목업 모드로 진입
- 초기 위치 설정, 관광객/주민 대시보드 전환, 온라인/저장 정보 상태
- OpenStreetMap 기반 구룡포 중심 지도와 예시 대피소·의료시설 마커
- 시설 선택 → 상세 → 예시 보행 경로, 알림 목록·상세, 목업 AI 대화, 프로필
- 넓은 화면에서 지도·시설 목록과 대시보드 정보가 함께 보이는 반응형 레이아웃
- Firebase ID 토큰을 `Authorization: Bearer <token>`으로 붙이는 Dio 인터셉터

## 실행

Flutter SDK 3.3 이상이 필요합니다. 최초에 플랫폼 폴더가 없다면 아래 명령을 한 번 실행합니다. 기존 앱 식별자가 있다면 생성 전에 조정하세요.

```powershell
flutter create --platforms=android,ios,web .
flutter pub get
flutter run -d chrome
flutter run -d android
```

iOS 빌드는 macOS와 Xcode가 있는 환경에서만 가능합니다.

```bash
flutter run -d ios
```

## 실제 서버에 연결해서 보기 (APP_MODE=remote)

코드 루트에서 `docker compose up -d` 로 서버를 켠 뒤:

```bash
flutter run -d chrome --dart-define=APP_MODE=remote
```

| 화면 | 서버 | 상태 |
|---|---|---|
| 대시보드 위험도·판정 근거, 알림 | api `GET /api/v1/risk` (반경 300m) | 실데이터. 알림은 `/api/v1/alerts`(A5) 전까지 위험 판정 항목으로 만든다 |
| 지도 위험 영역 | api `GET /api/v1/risk/areas` | 실데이터 |
| 대피소·의료시설 | api `GET /api/v1/dashboard/layers/{shelters,medical}` | 실데이터. 거리·도보시간은 직선거리 기반 대략값 |
| AI 대화 | ai `POST /api/chat` | 실데이터 (기기별 사용자 ID, 대화 이어 쓰기) |
| 대피 경로 | route `POST /api/route` | GraphHopper. 65세 이상·휠체어면 노약자 경로, "가까운 경로"는 맨홀 회피 끔 |

- 서버 주소 기본값은 `localhost:8000/8001/8002`. 바꾸려면 `--dart-define=API_BASE_URL=... AI_BASE_URL=... ROUTE_BASE_URL=...`
  (Android 에뮬레이터는 `10.0.2.2`). 배포는 세 값을 같은 도메인으로 준다.
- 침수 장면 시연: 서버에 `heavy_rain_flood` 시나리오를 넣으면 대시보드가 경계 단계·알림·위험 영역으로 바뀐다
  (`POST /api/v1/internal/simulate`, `server/README.md`). 끝나면 `clear`.
- AI 답에 경로가 있으면 "지도에서 경로 보기" 버튼이 붙고, 누르면 대시보드 지도에 AI가 계산한 경로를 그대로 그린다.
- 장소 등록(프로필): 이름·유형(집·직장·기타)을 적고 작은 지도에서 눌러 위치를 고른다. 이 기기에만 저장(서버 `/user/places`는 A5 이후)되고, AI 요청에 실려 "집까지", "직장까지" 질문에 쓰인다.
- 선택 정보 '보행 능력'에 무엇이든 적으면 보행 불편으로 보고 '안전 경로'를 노약자 경로로 요청한다.
- 현재 위치: 앱이 GPS를 따라가고, **구룡포 일대(경로 서버 도로망 범위) 안이면** 위험도·시설 거리·경로·AI 질문을 그 위치로 계산한다.
  30m 넘게 움직일 때마다 다시 계산(경로 안내 중이면 경로도 새로). 권한 거부·구룡포 밖·읽기 실패면 사용자 유형별 예시 위치를 쓰고 상단 줄에 이유를 표시.
  지도의 GPS 버튼으로 다시 읽고, 못 읽으면 지도를 눌러 위치를 고를 수 있다. 크롬에서 구룡포에 있는 것처럼 보려면 개발자 도구 → 센서 → 위치에 35.9907, 129.5526.
  웹은 `localhost`나 HTTPS에서만 위치를 준다(배포는 B10 Caddy HTTPS 필요).
- 아직 목업인 것: 등록 장소 위험 요약, 음성, 푸시 알림, 이동 중 경로 재계산 API(`/route/check`, C5), 계정 연결.
- 연결 코드: `lib/repositories/remote_repository.dart` (서버 응답 → 화면 모델 변환은 `test/remote_mapping_test.dart`에서 검사).
- 한글 경로에서 `flutter analyze`가 죽는 Flutter 버그가 있다. 영문 경로에 복사해서 돌린다.

## Firebase와 원격 API 설정

### 로그인 (Google · 이메일/비밀번호, 2026-10-04)

- 시작하면 Firebase **익명 로그인** → 서버에 사용자 등록(`POST /api/v1/user`, 멱등). 로그인은 선택이고 익명으로도 전부 쓸 수 있다.
- 프로필 → **계정** 카드: "Google로 계속하기"(웹 팝업, 모바일 브라우저 화면) / "이메일로 로그인·가입"(`/login`, 비밀번호 찾기 포함).
  가입·Google은 지금 익명 계정에 **연결**(link)해서 uid가 그대로 — 익명일 때 저장한 장소·AI 기억이 이어진다.
  이미 가입된 계정이면 그 계정으로 로그인한다. 로그아웃하면 다시 익명.
- AI 대화 `user_id`는 Firebase uid(없으면 기기 ID) → 로그인하면 AI 기억이 계정을 따라간다.
- 코드: `lib/services/auth_service.dart`(로그인·오류 문구·서버 등록), `lib/login_screen.dart`(계정 카드·이메일 화면).
- Naver는 Firebase 기본 지원이 아니라 넣지 않았다(서버에서 Naver OAuth → Firebase Custom Token 발급이 필요).

### Firebase 설정값

- `lib/firebase_options.dart`(커밋됨): 웹·안드로이드·iOS별 Firebase **클라이언트** 설정. 비밀이 아니다(앱에 그대로 배포되는 공개 식별자,
  승인된 도메인·앱 ID로 보호). 그래서 `--dart-define` 없이 `APP_MODE=remote`만 주면 로그인이 켜진다. `--dart-define=FIREBASE_*`를 주면 그 값이 우선.
- 앱 ID: 안드로이드·iOS 모두 **`kr.guryong.guardian`** (Firebase 프로젝트 `guryong-guardian-0924`에 등록).
- iOS: `ios/Runner/Info.plist`의 `CFBundleURLTypes` = Google 로그인 후 돌아오는 주소(인코딩된 iOS 앱 ID).
- 안드로이드: Google 로그인을 시험할 PC마다 디버그 서명 SHA-1을 Firebase 콘솔(프로젝트 설정 → Android 앱 → 지문 추가)에 등록한다.
  확인: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android | grep SHA1`
- 웹: 배포 주소가 Firebase Authentication → 설정 → **승인된 도메인**에 있어야 한다(`34-64-177-195.nip.io`, `localhost` 등록됨).
- 서비스 계정 키(`secrets/firebase-admin.json`)는 서버용 비밀이라 앱에 절대 넣지 않는다.

```bash
flutter run -d chrome --dart-define=APP_MODE=remote                     # 로컬 서버 + 로그인
flutter run -d "iPhone 17 Pro" --dart-define=APP_MODE=remote \
  --dart-define=API_BASE_URL=https://34-64-177-195.nip.io --dart-define=AI_BASE_URL=https://34-64-177-195.nip.io \
  --dart-define=ROUTE_BASE_URL=https://34-64-177-195.nip.io           # 아이폰 시뮬레이터 + 배포 서버
```

`lib/services/api_client.dart`가 모든 요청에 Firebase ID 토큰을 붙인다.

현재 저장소의 `MockSafetyRepository`는 고정 fixture를 반환합니다. 실제 서버 연결은 이 인터페이스의 remote 구현체를 추가해 교체합니다. 포항 디지털 트윈·기상청·재난안전24·생활안전지도 데이터 통합, GraphHopper 실제 길찾기, 위험 레이어 및 푸시 알림도 동일한 repository/service 경계에 연결합니다.

## 지도와 오프라인 범위

`flutter_map`은 OpenStreetMap 타일을 표시합니다. 공용 `tile.openstreetmap.org`는 개발·저용량 테스트 용도로만 사용해야 하며, 운영에서는 정책에 맞는 타일 제공자 또는 자체 타일 서버 URL을 설정 구조로 교체해야 합니다. 실제 위험 레이어, 오프라인 타일 저장, 실제 전화 위치 전송은 구현하지 않았습니다. 오프라인 토글은 마지막 예시 데이터 표시 흐름을 검증하는 UI입니다.

## 향후 검토: 침수 위험 예측

현재 목업은 **현재 시점의 예시 위험 상태만** 표시하며, 미래 위험 수치·그래프·경고 또는 예측 모델을 포함하지 않습니다. 향후 실제 데이터와 모델이 확보되면 `현재 위험 상태 + 단기 예측 위험 상태` 제공을 검토하고, 선제 경고 목적상 현재 시점 이후 1시간 범위를 우선 검토합니다.

## 팀 공용 설정 (구룡가디언)

- 담당: C 레인. 저장소 경로는 `app/`이다.
- Firebase 프로젝트: `guryong-guardian-0924` — 앱 등록은 `flutterfire configure --project=guryong-guardian-0924`
- 익명 인증과 FCM은 이미 켜져 있다 (B8).
- 로컬 서버 주소: api `http://localhost:8000`, ai `:8001`, route `:8002` (Android 에뮬레이터에서는 `10.0.2.2`)

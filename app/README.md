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
- 아직 목업인 것: 등록 장소 위험 요약, 음성, 푸시 알림, 이동 중 경로 재계산(C5), 계정 연결.
- 연결 코드: `lib/repositories/remote_repository.dart` (서버 응답 → 화면 모델 변환은 `test/remote_mapping_test.dart`에서 검사).
- 한글 경로에서 `flutter analyze`가 죽는 Flutter 버그가 있다. 영문 경로에 복사해서 돌린다.

## Firebase와 원격 API 설정

### 초기 설정과 계정 연결

첫 실행에서는 주민 또는 관광객, 구룡포 내 예시 주거·출발 위치, 연령, 이동수단을 입력한 뒤 대시보드로 이동합니다. 주민/관광객 선택은 로컬 저장소에 보존됩니다. 프로필의 Google·Naver·이메일 항목은 설정값이 없을 때 명확히 목업 연결로 동작합니다.

Google과 이메일은 Firebase Authentication provider 연결 지점이며, 익명 계정은 이후 `linkWithCredential` 방식으로 연결하도록 인증과 프로필 데이터가 분리되어 있습니다. Naver 로그인은 클라이언트에 Client Secret을 두지 않고, Naver OAuth 완료 후 신뢰 가능한 서버 또는 Cloud Functions가 Firebase Custom Token을 발급하는 구조로 연결해야 합니다. Firebase 서비스 계정 키와 Naver Client Secret은 어떤 클라이언트 파일에도 넣지 마세요.

기본값은 `mock`입니다. 비밀 값이나 `google-services.json`, `GoogleService-Info.plist`는 저장소에 넣지 마세요. `.env.example`을 참고하여 CI 또는 로컬 런 설정에 `--dart-define`으로 전달합니다.

```powershell
flutter run -d chrome --dart-define=APP_MODE=remote --dart-define=API_BASE_URL=https://api.example.com --dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_APP_ID=... --dart-define=FIREBASE_PROJECT_ID=... --dart-define=FIREBASE_MESSAGING_SENDER_ID=...
```

`lib/services/auth_service.dart`가 익명 로그인 및 ID 토큰을 담당하고, `lib/services/api_client.dart`가 인증 헤더를 삽입합니다. 익명 계정을 이메일 계정으로 연결할 때에도 프로필·저장 데이터는 인증 사용자와 분리된 사용자 데이터 키로 유지하도록 서버에서 설계합니다.

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

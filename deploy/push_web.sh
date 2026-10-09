#!/usr/bin/env bash
# Flutter 웹을 배포 주소용으로 빌드해 VM에 올린다 (B10). 맥에서 실행.
#   ./deploy/push_web.sh                     # 기본 VM jongyeonkim@34.64.177.195, 주소 34-64-177-195.nip.io
#   VM=user@host DOMAIN=example.com ./deploy/push_web.sh
# Firebase 설정은 app/lib/firebase_options.dart 를 쓴다. 다른 Firebase 프로젝트로 바꿔 빌드할 때만
# deploy/web-defines.json (gitignore, FIREBASE_API_KEY·APP_ID·PROJECT_ID·MESSAGING_SENDER_ID)을 둔다.
# 한글 경로에서 flutter 도구가 깨지므로 영문 임시 폴더에 복사해서 빌드한다.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
VM="${VM:-jongyeonkim@34.64.177.195}"
DOMAIN="${DOMAIN:-34-64-177-195.nip.io}"
base="https://$DOMAIN"

work="${TMPDIR:-/tmp}/guardian-web-build"
mkdir -p "$work"
rsync -a --delete --exclude build --exclude .dart_tool "$root/app/" "$work/app/"

defines=(--dart-define=APP_MODE=remote
         --dart-define=API_BASE_URL="$base"
         --dart-define=AI_BASE_URL="$base"
         --dart-define=ROUTE_BASE_URL="$base"
         --dart-define=APP_BUILD="$(git -C "$root" rev-parse --short HEAD) · $(date '+%m-%d %H:%M')")
if [ -f "$root/deploy/web-defines.json" ]; then
  defines+=(--dart-define-from-file="$root/deploy/web-defines.json")
fi

# --no-tree-shake-icons: Font Awesome(font_awesome_flutter 11, 첫 화면·앱 화면) 아이콘은 트리 셰이킹하면 네모로 보인다
(cd "$work/app" && flutter pub get >/dev/null && flutter build web --release --no-tree-shake-icons "${defines[@]}")

# 서비스 워커 끄기 (2026-10-08, app/web/flutter_bootstrap.js 가 등록하지 않는다). 이미 예전 서비스 워커가 깔린 브라우저는
# 다음 접속 때 이 파일로 업데이트되어 캐시를 비우고 스스로 해제한 뒤 한 번 새로고침한다 → 그 뒤로는 항상 새 버전
cat > "$work/app/build/web/flutter_service_worker.js" <<'SW'
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) await caches.delete(key);
    await self.registration.unregister();
    for (const client of await self.clients.matchAll({ type: 'window' })) client.navigate(client.url);
  })());
});
SW

ssh "$VM" 'mkdir -p ~/guryongpo-safety-agent/deploy/web'
rsync -az --delete "$work/app/build/web/" "$VM:guryongpo-safety-agent/deploy/web/"
echo "올림: $base/"

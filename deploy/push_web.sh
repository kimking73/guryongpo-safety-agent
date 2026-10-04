#!/usr/bin/env bash
# Flutter 웹을 배포 주소용으로 빌드해 VM에 올린다 (B10). 맥에서 실행.
#   ./deploy/push_web.sh                     # 기본 VM jongyeonkim@34.64.177.195, 주소 34-64-177-195.nip.io
#   VM=user@host DOMAIN=example.com ./deploy/push_web.sh
# Firebase 웹 설정값(FIREBASE_API_KEY·FIREBASE_APP_ID·FIREBASE_PROJECT_ID·FIREBASE_MESSAGING_SENDER_ID)은
# deploy/web-defines.json (gitignore)에 둔다. 없으면 로그인 없이 빌드된다 (공개 API만 동작).
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
         --dart-define=ROUTE_BASE_URL="$base")
if [ -f "$root/deploy/web-defines.json" ]; then
  defines+=(--dart-define-from-file="$root/deploy/web-defines.json")
else
  echo "주의: deploy/web-defines.json 없음 → Firebase 로그인 없이 빌드" >&2
fi

(cd "$work/app" && flutter pub get >/dev/null && flutter build web --release "${defines[@]}")

ssh "$VM" 'mkdir -p ~/guryongpo-safety-agent/deploy/web'
rsync -az --delete "$work/app/build/web/" "$VM:guryongpo-safety-agent/deploy/web/"
echo "올림: $base/"

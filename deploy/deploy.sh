#!/usr/bin/env bash
# 서버(VM) 업데이트 (B10): DB 백업 → 최신 코드 → 시드·스키마 반영 → 재빌드 → 상태 확인
#   VM에서:  cd ~/guryongpo-safety-agent && ./deploy/deploy.sh
# .env 는 건드리지 않는다. .env 를 바꿨으면 이 스크립트가 컨테이너를 다시 만들 때 함께 반영된다.
set -euo pipefail
cd "$(dirname "$0")/.."

compose() { docker compose -f docker-compose.yml "$@"; }
domain=$(grep -E '^DEPLOY_DOMAIN=' .env | cut -d= -f2- || true)

echo "== DB 백업"
mkdir -p ~/backups
backup=~/backups/db-$(date +%Y%m%d-%H%M).dump
compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$backup"
ls -lh "$backup"
# 최근 10개만 남긴다
ls -1t ~/backups/db-*.dump | tail -n +11 | xargs -r rm --

echo "== 코드 받기"
git pull --ff-only
git log --oneline -1

echo "== 스키마 추가분·정적 데이터 반영 (loader)"
compose run --rm --build loader | tail -3

echo "== 재빌드·재시작"
mkdir -p deploy/web
compose up -d --build --remove-orphans

echo "== 상태 확인 (최대 3분)"
for _ in $(seq 36); do
  bad=$(compose ps --format '{{.Service}} {{.Status}}' | grep -v '(healthy)' || true)
  [ -z "$bad" ] && break
  sleep 5
done
compose ps --format '{{.Service}}\t{{.Status}}'
if [ -n "$domain" ]; then
  curl -fsS -m 10 "https://$domain/api/health" && echo
else
  curl -fsS -m 10 http://localhost:8000/api/health && echo
fi

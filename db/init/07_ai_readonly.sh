#!/bin/sh
# AI(B 레인, ai 컨테이너) 전용 읽기 전용 DB 계정 — 2026-10-01 "AI는 DB를 직접 읽기 전용으로 조회" 결정 (B3)
#
# 빈 볼륨이면 00~06 다음에 자동 실행된다. 이미 만들어진 DB에는 한 번 직접 실행:
#   docker compose up -d db   (.env의 AI_DB_* 를 db 컨테이너가 읽도록 다시 만든 뒤)
#   docker compose exec db sh /docker-entrypoint-initdb.d/07_ai_readonly.sh
# 다시 실행해도 안전하다 (계정이 있으면 비밀번호·권한만 다시 맞춘다).
#
# 권한: public 스키마의 모든 표·뷰 SELECT만. 이후 새로 만드는 표에도 자동으로 SELECT.
#       계정 기본값으로 모든 트랜잭션을 읽기 전용(default_transaction_read_only)으로 연다.
# 주의: docker-entrypoint는 실행 권한이 없는 .sh를 source 하므로 exit를 쓰지 않는다.

AI_USER="${AI_DB_USER:-guardian_ai}"

if [ -z "$AI_DB_PASSWORD" ]; then
  echo "07_ai_readonly: AI_DB_PASSWORD 없음 — AI 읽기 전용 계정을 만들지 않음"
else
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
       -v ai_user="$AI_USER" -v ai_pw="$AI_DB_PASSWORD" -v db_name="$POSTGRES_DB" -v owner="$POSTGRES_USER" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'ai_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ai_user') \gexec
ALTER ROLE :"ai_user" WITH LOGIN PASSWORD :'ai_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
ALTER ROLE :"ai_user" SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE :"db_name" TO :"ai_user";
GRANT USAGE ON SCHEMA public TO :"ai_user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ai_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT ON TABLES TO :"ai_user";
SQL
  echo "07_ai_readonly: $AI_USER 읽기 전용 계정 준비 완료"
fi

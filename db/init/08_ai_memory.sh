#!/bin/sh
# AI(B 레인) 사용자 기억(장기) 저장 공간 — 2026-10-02 (LangGraph PostgresStore). 대화 기억(단기)은 AI 서버 메모리라 여기 없음
#
# 스키마 ai_memory 와 전용 계정(AI_MEM_DB_USER)을 만든다. 이 계정은 ai_memory 의 주인이라 그 안에서만 표를 만들고 쓴다.
# public 스키마(재난 데이터)에는 권한을 주지 않는다 — 재난 데이터는 07의 읽기 전용 계정(guardian_ai)으로만 읽는다.
# 표(store)는 AI 서버가 처음 뜰 때 LangGraph의 setup()이 만든다.
#
# 빈 볼륨이면 07 다음에 자동 실행된다. 이미 만들어진 DB에는 한 번 직접 실행:
#   docker compose up -d db   (.env의 AI_MEM_DB_* 를 db 컨테이너가 읽도록 다시 만든 뒤)
#   docker compose exec db sh /docker-entrypoint-initdb.d/08_ai_memory.sh
# 다시 실행해도 안전하다. docker-entrypoint는 실행 권한이 없는 .sh를 source 하므로 exit를 쓰지 않는다.

MEM_USER="${AI_MEM_DB_USER:-guardian_ai_mem}"

if [ -z "$AI_MEM_DB_PASSWORD" ]; then
  echo "08_ai_memory: AI_MEM_DB_PASSWORD 없음 — AI 기억 저장 계정을 만들지 않음"
else
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
       -v mem_user="$MEM_USER" -v mem_pw="$AI_MEM_DB_PASSWORD" -v db_name="$POSTGRES_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'mem_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'mem_user') \gexec
ALTER ROLE :"mem_user" WITH LOGIN PASSWORD :'mem_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT CONNECT ON DATABASE :"db_name" TO :"mem_user";
CREATE SCHEMA IF NOT EXISTS ai_memory AUTHORIZATION :"mem_user";
ALTER ROLE :"mem_user" SET search_path = ai_memory;
REVOKE CREATE ON SCHEMA public FROM :"mem_user";
SQL
  echo "08_ai_memory: $MEM_USER 계정·ai_memory 스키마 준비 완료"
fi

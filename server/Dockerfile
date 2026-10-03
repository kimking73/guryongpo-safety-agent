FROM python:3.12-slim

WORKDIR /srv

# 의존성 먼저 설치해 코드만 바뀔 때는 이 층을 재사용한다. 목록은 pyproject.toml 한 곳에서만 관리.
COPY pyproject.toml .
RUN python -c "import tomllib, subprocess, sys; deps = tomllib.load(open('pyproject.toml', 'rb'))['project']['dependencies']; subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-cache-dir', *deps])"

# app: API · collector: 수집기(같은 이미지를 collector 서비스가 다른 명령으로 실행) · risk: 판정 엔진 · loader: 정적 데이터 적재
# mock: 실구현 전 목업 응답 + 네트워크 없이 적재하는 저장 원문(mock/external)
COPY app ./app
COPY collector ./collector
COPY risk ./risk
COPY alerts ./alerts
# loader: 정적 데이터 적재 (A7). 시드 SQL 은 이미지에 넣지 않고 실행 시 ./db/init 을 /srv/db/init 으로 연결
COPY loader ./loader
COPY mock ./mock

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]

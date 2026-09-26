FROM python:3.12-slim

WORKDIR /srv

# 의존성 먼저 설치해 코드만 바뀔 때는 이 층을 재사용한다. 목록은 pyproject.toml 한 곳에서만 관리.
COPY pyproject.toml .
RUN python -c "import tomllib, subprocess, sys; deps = tomllib.load(open('pyproject.toml', 'rb'))['project']['dependencies']; subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-cache-dir', *deps])"

COPY guardian_route ./guardian_route
# 임시 위험지역 GeoJSON (A7 DB 적재 전까지)
COPY data ./data

EXPOSE 8002
CMD ["uvicorn", "guardian_route.api:app", "--host", "0.0.0.0", "--port", "8002"]

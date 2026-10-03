FROM python:3.12-slim

WORKDIR /srv

# 음성 녹음(webm·m4a 등)을 Google STT가 받는 16kHz mono PCM으로 바꾼다 (voice.py)
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*

# 의존성 먼저 설치해 코드만 바뀔 때는 이 층을 재사용한다. 목록은 pyproject.toml 한 곳에서만 관리.
COPY pyproject.toml .
RUN python -c "import tomllib, subprocess, sys; deps = tomllib.load(open('pyproject.toml', 'rb'))['project']['dependencies']; subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-cache-dir', *deps])"

COPY guardian_ai ./guardian_ai

EXPOSE 8001
CMD ["uvicorn", "guardian_ai.api:app", "--host", "0.0.0.0", "--port", "8001"]

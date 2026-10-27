# AppleLook Server: docker compose up -d (see README.md)
FROM python:3.12-slim

# tzdata so TZ=America/New_York etc. shows times in your zone
RUN apt-get update && apt-get install -y --no-install-recommends tzdata && rm -rf /var/lib/apt/lists/*

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 APPLELOOK_DATA=/data
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY applelook_server ./applelook_server

RUN useradd --uid 1000 --create-home applelook && mkdir -p /data && chown applelook /data
USER applelook
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"
CMD ["python", "-m", "applelook_server"]

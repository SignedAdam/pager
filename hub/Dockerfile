# Ambient reference hub. Build from the repository root:
#   docker build -t ambient-hub hub/
#   docker run -d --name ambient-hub -p 8790:8790 -v ambient-hub:/data \
#     -e AMBIENT_HUB_PUBLIC_URL=https://hub.example.com -e AMBIENT_HUB_NAME="My hub" ambient-hub
# Admin commands run inside the container:
#   docker exec ambient-hub python3 /app/ambient-hub.py source list
FROM python:3.12-slim

RUN useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin hub \
 && mkdir -p /data /app \
 && chown hub:hub /data

COPY ambient-hub.py conformance.py /app/

ENV AMBIENT_HUB_DB=/data/hub.db \
    AMBIENT_HUB_LISTEN=0.0.0.0:8790 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

VOLUME /data
EXPOSE 8790
USER hub
WORKDIR /data

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8790/healthz', timeout=2)"

ENTRYPOINT ["python3", "/app/ambient-hub.py"]
CMD ["serve"]

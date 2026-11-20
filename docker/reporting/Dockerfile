ARG RUN_BASE=docker-mirror.liara.ir/python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
FROM ${RUN_BASE}
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY reporting/requirements.txt .
RUN python -m pip install --no-cache-dir --only-binary=:all: -r requirements.txt
COPY --chown=10001:10001 reporting/source/ ./source/
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]
ENTRYPOINT ["python", "source/server.py"]

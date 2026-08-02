# flux-coderunner: sandboxed execution service for the code node.
# Python via uv-cached venvs; JavaScript via permissionless Deno.
FROM python:3.12-slim-bookworm

COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /usr/local/bin/uv
COPY --from=denoland/deno:bin-2.3.6 /deno /usr/local/bin/deno

RUN useradd --create-home runner && \
    mkdir -p /cache/venvs /cache/uv && chown -R runner /cache

COPY server.py /srv/server.py

USER runner
ENV RUNNER_PORT=8194 \
    RUNNER_VENV_ROOT=/cache/venvs \
    UV_CACHE_DIR=/cache/uv \
    UV_PYTHON_DOWNLOADS=never

EXPOSE 8194
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8194/health')"]

CMD ["python", "/srv/server.py"]

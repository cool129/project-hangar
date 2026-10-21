# syntax=docker/dockerfile:1.7
#
# Multi-stage build:
#   builder  - compiles the venv (pip, build tooling never reach the runtime image)
#   runtime  - slim base, OS patches applied, no pip, non-root UID, no shell login
#
# Compatible with a read-only root filesystem (Kubernetes readOnlyRootFilesystem).
# Dependency versions are pinned by constraints.txt for reproducible builds.

ARG PYTHON_VERSION=3.13

FROM python:${PYTHON_VERSION}-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# Dependencies first so source edits don't invalidate this layer.
COPY constraints.txt pyproject.toml ./
COPY src ./src
RUN pip install -c constraints.txt . \
    && pip uninstall -y pip


FROM python:${PYTHON_VERSION}-slim AS runtime

ARG GIT_SHA=unknown

LABEL org.opencontainers.image.title="sortie-tracker" \
      org.opencontainers.image.description="Aircraft readiness and sortie lifecycle API (Project HANGAR)" \
      org.opencontainers.image.revision="${GIT_SHA}"

# Pull in Debian security fixes released after the base image was published, and
# remove pip + ensurepip: the runtime never installs packages, and their vendored
# libraries (urllib3, certifi, ...) are the image's main CVE surface.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip \
    && rm -rf /usr/local/lib/python3*/ensurepip \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    GIT_SHA=${GIT_SHA}

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY alembic.ini ./
COPY migrations ./migrations

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]

# One process per container; Kubernetes (HPA) handles horizontal scale.
# --proxy-headers: trust X-Forwarded-* from the ingress controller.
CMD ["uvicorn", "sortie_tracker.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*", "--no-access-log"]

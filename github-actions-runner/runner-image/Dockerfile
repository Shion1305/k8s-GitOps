# syntax=docker/dockerfile:1.7
FROM ghcr.io/actions/actions-runner:2.335.1

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      file \
      git-lfs \
      gzip \
      jq \
      nodejs \
      npm \
      openssh-client \
      pkg-config \
      python3 \
      python3-pip \
      python3-venv \
      rsync \
      tar \
      unzip \
      wget \
      xz-utils \
      zip \
      zstd \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=runner:docker entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh \
    && mkdir -p /runner \
    && chown runner:docker /runner

USER runner
ENV RUNNER_ASSETS_DIR=/home/runner \
    RUNNER_HOME=/runner
ENTRYPOINT ["/entrypoint.sh"]

# syntax=docker/dockerfile:1.7
FROM ghcr.io/actions/actions-runner:2.335.1

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
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

# buildctl client for daemonless image builds against the in-cluster rootless
# BuildKit (see ../../buildkit). No Docker daemon is bundled in these runners.
ARG BUILDKIT_VERSION=v0.30.0
ARG TARGETARCH
RUN curl -fsSL "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local bin/buildctl \
    && buildctl --version

# Rust toolchain — parity with GitHub-hosted ubuntu-latest, which preinstalls it
# (the actions-runner base image does not). Installed system-wide so every job
# sees cargo/rustc on PATH; CARGO_HOME is world-writable for the runner user.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable \
    && chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME" \
    && rustc --version && cargo --version

COPY --chown=runner:docker entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh \
    && mkdir -p /runner \
    && chown runner:docker /runner

USER runner
ENV RUNNER_ASSETS_DIR=/home/runner \
    RUNNER_HOME=/runner
ENTRYPOINT ["/entrypoint.sh"]

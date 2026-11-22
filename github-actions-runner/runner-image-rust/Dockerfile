# syntax=docker/dockerfile:1.26

# Keep both sources pinned to multi-platform OCI indexes. BuildKit selects the
# toolchain matching each output platform without running rustup under QEMU.
ARG RUST_IMAGE=rust:1.100.0-slim-bookworm@sha256:7c7d4eb4d05b7781187a327809466cfddf29753f6defdc3d19a0e291951b7a37
ARG GARM_IMAGE=harbor.shion1305.com/shion1305/garm-runner@sha256:bb53496e68ce90d3cb481a199d26ccc83006d8f29e025fe771e5a885d9cdb8cd

FROM ${RUST_IMAGE} AS rust-toolchain
# The official slim image has the minimal profile. ISUCON CI also runs fmt and
# clippy, so install these once in the image instead of on every ephemeral Pod.
RUN rustup component add rustfmt clippy \
    && rm -rf "$RUSTUP_HOME/downloads" "$RUSTUP_HOME/tmp"

FROM ${GARM_IMAGE}

# /home/runner is copied into the ephemeral /runner volume by entrypoint.sh.
# Keep Rust outside that tree so each new Pod shares the read-only image layer.
COPY --from=rust-toolchain --chown=runner:docker /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain --chown=runner:docker /usr/local/rustup /usr/local/rustup

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:$PATH

# Check the copied toolchain in the final Ubuntu image without reinstalling it.
RUN rustup toolchain list \
    && rustc --version \
    && cargo --version \
    && cargo fmt --version \
    && cargo clippy --version

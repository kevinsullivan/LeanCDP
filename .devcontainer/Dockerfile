# Base image pinned by digest for reproducible rebuilds. debian:trixie-slim,
# multi-arch index digest resolved 2026-10-21. Re-pin with:
#   docker buildx imagetools inspect debian:trixie-slim
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
LABEL org.opencontainers.image.description="LeanCDP: a pure-Lean 4 Chrome DevTools Protocol client"

ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    SHELL=/bin/bash

SHELL ["/bin/bash", "-c"]
USER root

# ----- Base tools -----
# chromium: not for browsing -- it's the live integration target this project's
# own `lake exe leancdp-chromium-demo` / `leancdp-screenshot` launch headless
# (`--headless --no-sandbox --remote-debugging-port=...`). --no-install-recommends
# still pulls its hard Depends (GTK, Mesa, fonts, etc.), which headless rendering
# needs anyway.
RUN apt-get update && \
    apt-get install --no-install-recommends --assume-yes \
      build-essential \
      chromium \
      curl \
      git \
      openssh-client \
      less \
      libffi-dev \
      libssl-dev \
      locales \
      pkg-config \
      unzip \
      vim \
      wget \
      zip \
      sudo && \
    sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ----- Non-root user and workspace -----
RUN useradd -m -s /bin/bash dev && \
    usermod -aG sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev && \
    chmod 0440 /etc/sudoers.d/dev && \
    mkdir -p /home/dev/app && chown -R dev:dev /home/dev/app && \
    git config --system --add safe.directory /home/dev/app

# Pinned tool versions — copied after apt so a version bump does not rebuild
# the base layer; owned by dev so the elan step below (which runs as dev) can
# source and then remove it.
COPY --chown=dev:dev versions.env /tmp/versions.env

# ----- Switch to dev for user-scoped installs -----
USER dev
WORKDIR /home/dev

# Put user-local tools (elan/lean, claude) on PATH.
ENV PATH="/home/dev/.elan/bin:/home/dev/.local/bin:${PATH}"

# ----- elan (Lean toolchain manager, user-local) -----
# Installed WITHOUT a default toolchain: the correct Lean version is fetched
# lazily from lean-toolchain on the first `lake`/`lake build`, so the image
# stays small and version-agnostic while making `lake` usable headlessly (no
# VS Code extension required).
RUN set -a && . /tmp/versions.env && set +a && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) ELAN_ARCH=x86_64-unknown-linux-gnu ;; \
      arm64) ELAN_ARCH=aarch64-unknown-linux-gnu ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/elan.tar.gz "https://github.com/leanprover/elan/releases/download/v${ELAN_VERSION}/elan-${ELAN_ARCH}.tar.gz" && \
    tar -xzf /tmp/elan.tar.gz -C /tmp && \
    /tmp/elan-init -y --default-toolchain none --no-modify-path && \
    rm -f /tmp/elan.tar.gz /tmp/elan-init /tmp/versions.env

# ----- Claude Code CLI (user-local) -----
# Installed AFTER the USER switch so the binary lands in /home/dev/.local/bin
# (readable by dev) rather than /root/.local/bin.
RUN curl -fsSL https://claude.ai/install.sh | bash

# Workspace
WORKDIR /home/dev/app

# Keep the devcontainer running so VS Code can attach.
CMD ["sleep", "infinity"]

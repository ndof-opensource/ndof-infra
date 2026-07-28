# syntax=docker/dockerfile:1
#
# ndof development environment image.
#
# This file is the single source of truth for the team's toolchain. Every
# version is pinned; changing anything here is a reviewed pull request that
# produces a new published image digest, which project repositories then
# adopt explicitly by updating the pin in their .devcontainer/devcontainer.json
# and CI workflow.

# Digest-pinned so the build's only external input is explicit; Dependabot
# (docker ecosystem) opens PRs when Canonical publishes a newer 24.04 image.
FROM ubuntu:24.10@sha256:cdf755952ed117f6126ff4e65810bf93767d4c38f5c7185b50ec1f1078b464cc

# ---- pinned toolchain versions ----------------------------------------------
ARG GCC_MAJOR=14
ARG LLVM_MAJOR=19
ARG CMAKE_VERSION=3.30.5
ARG NINJA_VERSION=1.11.1.1
ARG CONAN_VERSION=2.9.2

ENV DEBIAN_FRONTEND=noninteractive

# Base tools and GCC
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        git openssh-client \
        make pkg-config \
        gcc-${GCC_MAJOR} g++-${GCC_MAJOR} \
        gdb ccache \
        cppcheck \
        python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# LLVM/Clang from apt.llvm.org, pinned to one major version
RUN curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-${LLVM_MAJOR} main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clang-${LLVM_MAJOR} clang-tools-${LLVM_MAJOR} clangd-${LLVM_MAJOR} \
        clang-format-${LLVM_MAJOR} clang-tidy-${LLVM_MAJOR} \
        lld-${LLVM_MAJOR} llvm-${LLVM_MAJOR} libclang-rt-${LLVM_MAJOR}-dev \
    && rm -rf /var/lib/apt/lists/*

# Unversioned command names resolve to the pinned versions
RUN for t in gcc g++ gcov; do \
        update-alternatives --install /usr/bin/$t $t /usr/bin/$t-${GCC_MAJOR} 100; \
    done \
    && for t in clang clang++ clangd clang-format clang-tidy run-clang-tidy lld; do \
        update-alternatives --install /usr/bin/$t $t /usr/bin/$t-${LLVM_MAJOR} 100; \
    done

# CMake / Ninja / Conan, pinned, isolated in their own venv
RUN python3 -m venv /opt/toolchain \
    && /opt/toolchain/bin/pip install --no-cache-dir \
        cmake==${CMAKE_VERSION} \
        ninja==${NINJA_VERSION} \
        conan==${CONAN_VERSION}
ENV PATH=/opt/toolchain/bin:${PATH}

# Team Conan profiles: versioned in this repo, baked into the image so every
# container and CI job resolves dependencies identically.
COPY conan/profiles/ /opt/conan/profiles/

# Non-root development user (replaces Ubuntu 24.04's default uid-1000 user so
# bind-mounted workspaces keep sane ownership on Linux hosts).
RUN userdel -r ubuntu && useradd -m -s /bin/bash -u 1000 dev
USER dev
ENV CONAN_HOME=/home/dev/.conan2
# Pre-create the cache dir so a named volume mounted here (e.g. to persist the
# cache across one-shot `docker run` invocations) inherits dev ownership.
RUN mkdir -p ${CONAN_HOME}

LABEL org.opencontainers.image.description="ndof pinned C++ development environment (GCC ${GCC_MAJOR}, Clang ${LLVM_MAJOR}, CMake ${CMAKE_VERSION}, Conan ${CONAN_VERSION})"

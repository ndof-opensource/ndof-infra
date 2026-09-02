# syntax=docker/dockerfile:1
#
# ndof development environment image.
#
# This file is the single source of truth for the team's toolchain. Every
# version is pinned; changing anything here is a reviewed pull request that
# produces a new published image digest, which project repositories then
# adopt explicitly by updating the pin in their .devcontainer/devcontainer.json
# (the only place the digest lives; CI reads it from there).

# Digest-pinned so the build's only external input is explicit; Dependabot
# (docker ecosystem) opens PRs when Canonical publishes a newer 24.04 image.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

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

# LLVM/Clang from apt.llvm.org, pinned to one major version. The apt
# signing key is a committed file, not fetched at build time: a trust
# root downloaded from the same server the packages come from verifies
# nothing, and apt.llvm.org outages were failing builds. The expected
# fingerprint below was cross-checked against keyserver.ubuntu.com at
# pin time; an upstream key rotation shows up as a reviewed diff of the
# committed key plus this constant, rather than as a silent build-time swap.
# The index guard after apt-get update exists because Ubuntu's own
# archive also carries clang-19: if apt.llvm.org is unreachable, apt
# reports success anyway and the install would silently take Ubuntu's
# older build, so an outage must fail the image build instead.
COPY image/llvm-snapshot.gpg.key /tmp/llvm-snapshot.gpg.key

# Check the committed key's fingerprint, install it as the repository
# trust root, and register the LLVM apt source against it.
RUN fpr=$(gpg --show-keys --with-colons /tmp/llvm-snapshot.gpg.key \
            | awk -F: '/^fpr:/ { print $10; exit }') \
    && if [ "$fpr" != "6084F3CF814B57C1CF12EFD515CF4D18AF4F7421" ]; then \
           echo "committed LLVM key fingerprint mismatch: got $fpr" >&2; \
           exit 1; \
       fi \
    && gpg --dearmor -o /usr/share/keyrings/llvm.gpg /tmp/llvm-snapshot.gpg.key \
    && rm /tmp/llvm-snapshot.gpg.key \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-${LLVM_MAJOR} main" \
        > /etc/apt/sources.list.d/llvm.list

# Fetch the package indexes, confirm apt.llvm.org's actually loaded,
# install the pinned-major LLVM toolchain, and drop the index cache.
RUN apt-get update -o Acquire::Retries=5 \
    && if ! apt-cache policy | grep -q "apt\.llvm\.org"; then \
           echo "apt.llvm.org index not loaded; failing instead of silently installing Ubuntu's clang" >&2; \
           exit 1; \
       fi \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=5 \
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

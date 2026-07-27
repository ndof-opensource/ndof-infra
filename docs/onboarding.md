# Developer onboarding

How to go from a fresh machine to building, testing, and contributing — and
enough theory about each moving part that nothing feels like magic. If you
want the *reasons* behind the setup, read [decisions.md](decisions.md).

## The mental model in one paragraph

This repo (`ndof-infra`) holds the **definition** of the team environment: a
Dockerfile, Conan profiles, CI logic, and a project template. Definitions are
turned into **pinned artifacts**: the Dockerfile becomes a published container
image identified by an immutable digest, and each project repo pins that
digest (in `.devcontainer/devcontainer.json` and its CI stub). So every commit
of every project records exactly which environment built it, any machine can
reproduce it, and changing the environment is a reviewed pull request here
followed by explicit pin updates there.

## Day one

1. Install Docker (Docker Desktop or OrbStack) and clone a library repo,
   e.g. `ndof-core-utils`.
2. Open the folder in a devcontainer-capable editor — VS Code (Dev Containers
   extension), Zed (built-in since Jan 2026), or the `devcontainer` CLI. Accept
   the "open in container" prompt. Your terminal is now inside the pinned
   environment: GCC 14, Clang 19, CMake, Ninja, Conan 2, team profiles.
3. Build and test:

   ```sh
   scripts/build.sh debug
   ```

   The script prints every command it runs. The raw sequence it wraps:

   ```sh
   conan install . --build=missing -pr:a /opt/conan/profiles/linux-gcc14 -s build_type=Debug
   cmake --preset debug          # configure
   cmake --build --preset debug  # compile
   ctest --preset debug          # run unit tests
   ```

That is the entire onboarding. Nothing is installed on your host.

## Conan in five minutes

C++ has no built-in package ecosystem, and compiled C++ libraries are only
linkable against binaries built with a *compatible configuration* — same
architecture, compatible compiler, same standard library, same build type
(this compatibility contract is the **ABI**, Application Binary Interface).
So a C++ package manager must track versions × configurations, not versions
alone.

Conan's model:

- Each repo's `conanfile.py` declares what it needs (today: gtest for tests)
  and how this library itself is packaged.
- A **profile** (see `conan/profiles/`, baked into the image at
  `/opt/conan/profiles/`) is the written answer to "compatible with what?" —
  one line per ABI axis: `os`, `arch`, `compiler`, `compiler.version`,
  `compiler.libcxx` (which C++ standard library — both our profiles use
  libstdc++ so GCC and Clang builds share one), `compiler.cppstd=23`.
- `conan install` hashes recipe + settings into a **package ID** per
  dependency, then finds a matching binary: local cache → remotes → build
  from source (`--build=missing`). Debug and Release gtest are different
  package IDs; both live in the cache side by side.
- It then generates `build/<Type>/generators/conan_toolchain.cmake`, which
  carries the compiler choice and standard into our own build. **The profile
  is the single source of truth for the toolchain** — switching compilers is
  switching profiles, nothing else.
- A **remote** is a package server. ConanCenter (public, anonymous) is the
  default and currently sufficient. A private remote gets stood up at the
  first internal release, so `requires = "ndof-core-utils/x.y.z"` resolves
  across repos. Until then, cross-repo local development uses
  `conan editable add ../ndof-core-utils` — point your build at a sibling
  checkout, no publishing involved.
- Cross-compilation, when it arrives, is a profile *pair*:
  `-pr:h <target> -pr:b <build machine>` — host profile describes where
  artifacts run, build profile the machine building them. Same file format,
  more files in `conan/profiles/`.

## CMake presets

`CMakePresets.json` names the sanctioned configurations so humans and CI type
identical commands: `debug`, `release`, and sanitizer variants `asan`, `tsan`
(these deliberately reuse the *Debug* Conan install — their toolchain file
points into `build/Debug/generators/`). Each has matching build and test
presets; `ctest` is CMake's test runner, which discovers the gtest suites.

## Where does a new header go?

Three questions, asked in order (decision 14 has the full reasoning):

1. **Will users call what is in it?** Then
   `include/ndof/<lib>/`. This is the public API: documented,
   semver-governed, reviewed as a promise.
2. **Do public headers need to include it, even though users will never
   call it directly?** Then `include/ndof/<lib>/details/`, in namespace
   `ndof::<lib>::details`. Template machinery, traits, storage types: it
   ships, because consumers' compilers must be able to read it, but
   nothing under `details/` is supported API and all of it may change
   without notice.
3. **Neither?** Then `src/`, next to the sources that use it. It is
   never installed; consumers cannot include what does not exist on
   their machines.

The install rule is the enforcement: `install(DIRECTORY include/)`
ships tiers 1 and 2 and nothing else. Promoting a header from `src/`
into `details/` (because a public header now needs it) grows the shipped
surface; review it like an API change.

## The CI gates, and how to reproduce each locally

CI logic lives once, in `.github/workflows/ci.yml` here, called by a ~10-line
stub in each repo. Every push and pull request runs:

| Job | Proves | Reproduce locally (in the container) |
|---|---|---|
| `format` | Code matches `.clang-format` | `git ls-files '*.cpp' '*.hpp' \| xargs clang-format --dry-run -Werror` |
| `linux` (GCC & Clang × Debug & Release) | Builds and tests pass in the canonical environment | `scripts/build.sh debug` / `--profile linux-clang19` / `release` |
| `sanitize` | No memory errors or undefined behavior at runtime (ASan + UBSan) | `scripts/build.sh asan` |
| `tidy` | Static-analysis clean per `.clang-tidy`, warnings as errors | `run-clang-tidy -p build/Debug -warnings-as-errors='*'` |
| `macos` / `windows` | Portability to AppleClang and MSVC | native runners only — CI is the arbiter |

The objective of CI (**Continuous Integration**): every change is built and
tested automatically before it lands, so integration breakage surfaces in
minutes and quality is the default path, not a discipline. The **CD**
(Continuous Delivery) side today is `build-image.yml`, which publishes the
environment image on merge; automated Conan package publishing on release
tags is planned alongside the private remote.

## Changing the environment itself

1. PR to this repo (usually a one-line `ARG` bump in `image/Dockerfile` —
   every toolchain version is declared once at the top).
2. Merge → `build-image.yml` builds multi-arch, pushes to GHCR, and prints
   the new **digest** (`sha256:…` content fingerprint).
3. Each project adopts explicitly by updating its digest pin (devcontainer +
   CI stub). Projects can adopt at different times; pins make drift explicit.
   The two pins move together: CI's `digest-sync` job fails any commit where
   `devcontainer.json` and the CI stub disagree, so half-done bumps cannot
   land silently.
4. Rollback = revert the pin.

Tags like `:latest` are conveniences that move; digests are immutable facts.
Pin digests.

## Footguns (each learned the hard way, once)

- **Switching compiler profiles requires a clean build tree.** CMake caches
  the compiler and silently ignores a changed toolchain in an existing
  `build/`. `scripts/build.sh` detects the switch and cleans automatically;
  doing it by hand, `rm -rf build` first.
- **A build tree remembers the absolute path it was created at.** Using one
  checkout from different mount points — plain `docker run` at `/work`, a
  devcontainer at `/workspaces/<name>` — fails with "CMakeCache.txt directory
  … is different". `scripts/build.sh` detects the move and cleans
  automatically; by hand, `rm -rf build`.
- **Zed's dev containers are local-only (v1).** Zed cannot chain SSH remoting
  with dev containers — an SSH-remote project shows no "reopen in container"
  prompt. On remote machines, use the devcontainer CLI
  (`npx @devcontainers/cli up --workspace-folder .`) or VS Code, or open the
  repo on the machine where Docker runs.
- **One-shot `docker run` loses the Conan cache** (it lives in the container
  home, not the mounted repo) while `build/` persists on the mount — a
  mismatch that yields confusing "missing gtest" errors. Persist it with
  `-v ndof-conan-cache:/home/dev/.conan2`, or just use a real devcontainer.
- **Format only with the pinned clang-format** (i.e., inside the container).
  Different clang-format majors disagree; CI enforces the pinned one.
- **`ctest` passing while the build failed** usually means a stale test
  binary from a previous configuration — clean and rebuild.

## Glossary

| Term | Meaning |
|---|---|
| ABI | Application Binary Interface — the binary-compatibility contract between compiled artifacts |
| ASan / UBSan / TSan | Address / UndefinedBehavior / Thread Sanitizers — runtime error detectors compiled into test builds |
| CD | Continuous Delivery — green commits automatically produce the deliverable artifact |
| CI | Continuous Integration — every change automatically built and tested before it lands |
| clangd | LLVM's language server (code intelligence in Zed/VS Code); reads `compile_commands.json` from `build/Debug` |
| CTest | CMake's test runner |
| Dev Container | A development environment defined by `devcontainer.json` + a container image; supported by VS Code, Zed, JetBrains, Codespaces |
| digest | Immutable `sha256:` content fingerprint of a container image — the reproducibility anchor |
| GHA | GitHub Actions — the CI/CD service executing `.github/workflows/*.yml` |
| GHCR | GitHub Container Registry (`ghcr.io`) — hosts the `ndof-dev` image |
| GCC / Clang / MSVC | The three compiler families in the CI matrix (GNU, LLVM, Microsoft) |
| Ninja | Fast build executor invoked by CMake |
| OCI | Open Container Initiative — standards for container images (incl. the `org.opencontainers.image.*` labels baked into ours) |
| package ID | Conan's hash of recipe + settings identifying one binary variant of a dependency |
| profile | Conan's description of a build configuration (the ABI axes + tool configuration) |
| remote | A Conan package server (ConanCenter public; private remote planned) |
| SPDX | Standardized machine-readable license identifiers (`SPDX-License-Identifier: Apache-2.0` headers) |

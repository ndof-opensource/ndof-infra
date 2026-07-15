# ndof-infra

Version-controlled development environment and shared project infrastructure
for the ndof framework family (`ndof-core-utils`, `ndof-callable`, `ndof-error`,
and eventually the ndof framework itself).

This repository holds the **definition** of the environment. Each project repo
pins the **published artifacts** (image digest, workflow ref) in its own
history — so any commit of any project records exactly which environment built
it, and any developer on any machine can reproduce it.

## Contents

| Path | Purpose |
|---|---|
| `image/Dockerfile` | The dev image: Ubuntu 24.04, GCC 14 + Clang 19, CMake/Ninja/Conan 2 pinned, non-root `dev` user. Multi-arch (amd64 + arm64). |
| `conan/profiles/` | Team Conan profiles (C++23, both compilers). Baked into the image at `/opt/conan/profiles/`. |
| `.github/workflows/build-image.yml` | Builds and publishes the image to GHCR on changes; prints the digest to pin. |
| `.github/workflows/ci.yml` | Reusable CI for all library repos: Linux (GCC + Clang, Debug + Release) in the image, macOS and Windows native, ASan/UBSan, clang-tidy, clang-format. |
| `template/` | Project template: CMake package with proper install/export, Conan recipe, presets, lint configs, devcontainer, CI stub, unit-test skeleton. |
| `scripts/new-project.sh` | Instantiates the template into a new repository. |
| `docs/decisions.md` | Design-decision record: what was chosen and why. |
| `docs/onboarding.md` | New-developer guide: day-one setup, Conan/CMake/CI concepts, footguns, glossary. |

## How environment versioning works

1. Changing the environment = a PR to this repo (e.g. bump `LLVM_MAJOR` in the
   Dockerfile). Review happens here, once, for the whole team.
2. On merge, `build-image.yml` publishes a new multi-arch image to
   `ghcr.io/<owner>/ndof-dev` and prints its immutable digest.
3. Each project repo adopts the change explicitly by updating the digest pin in
   its `.devcontainer/devcontainer.json` and CI workflow (automatable with
   Dependabot/Renovate). Projects can adopt at different times; the pin makes
   drift explicit instead of accidental.
4. Rollback = revert the pin.

The same pattern applies to CI logic: project workflows are ~10-line stubs
calling the reusable `ci.yml` here by ref. Fix CI once, every repo gets it on
its next ref bump.

## Design decisions (agreed 2026-07)

- **Dev Container** as the canonical environment; CI's macOS/Windows/multi-arch
  matrix — not the container — is what enforces cross-platform compatibility.
- **Conan 2** for dependency management (chosen over vcpkg for cross-compilation
  profiles, private package remotes, and lockfile-based graph capture as the
  project grows toward embedded targets).
- **C++23** baseline (`std::expected` et al.); compiler floor GCC 13 / Clang 17 /
  MSVC 19.36.
- **One repo per library**, all instantiated from `template/`, so each is
  independently consumable open source; this repo prevents infrastructure drift.
- Libraries are **plain CMake packages** (proper `install()`/`export()`); Conan
  is how *we* consume and publish, never a requirement imposed on consumers.

## Bootstrap (one-time)

1. Create the GitHub org/owner and push this repo as `ndof-infra`.
2. Run the `build-image` workflow (or push to main); make the
   `ndof-dev` GHCR package public so CI containers and devcontainers can pull
   it without credentials.
3. Take the digest it prints and pin it in each project repo (devcontainer +
   CI stub), and pin the `ci.yml` ref to a tag or SHA.
4. Enable branch protection (Settings → Rules) on `main` of **every** repo,
   this one included: require the CI status checks to pass, require branches
   to be up to date before merging, and forbid direct pushes. This is what
   makes a red PR unmergeable — without it, CI is advisory.
5. Add the Apache-2.0 `LICENSE` file when creating each repo (decision
   recorded in docs/decisions.md; per-file SPDX headers and AUTHORS files are
   already in place).
6. Stand up a private Conan remote (Artifactory CE or GitLab package registry)
   for publishing `ndof-*` packages; add lockfiles to the library repos.

## Local image build (optional)

```sh
docker build -f image/Dockerfile -t ndof-dev:local .
```

## Creating a new library

```sh
scripts/new-project.sh <name> "<description>" <dest-dir> [github-owner]
# e.g.
scripts/new-project.sh callable "Callable traits and utilities for ndof" ../ndof-callable my-org
```

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

## Forking this environment (bootstrap for your own organization)

Projects stamped from `template/` ride the
published ndof-opensource environment by default (decision 12 in
docs/decisions.md) and need none of the steps below — clone, stamp, build.
Fork this repository only if you want **environmental independence**: your
own image, your own CI pipeline, published under your own org.

1. Fork (or copy) this repository into your organization.
2. In the org settings (Settings → Packages), allow members to create
   **public packages** — new orgs disallow this by default, which silently
   blocks step 4.
3. Run the `build-image` workflow (Actions → "Build and publish dev image" →
   Run workflow; it also fires on pushes to main touching `image/` or the
   profiles). It publishes `ghcr.io/<your-org>/ndof-dev` and prints the
   image digest in its final step.
4. Make the `ndof-dev` GHCR package public (package page → settings → Danger
   Zone) so devcontainers and CI containers can pull it anonymously.
5. Repoint the template at *your* environment: in
   `template/.devcontainer/devcontainer.json` and
   `template/.github/workflows/ci.yml`, replace `ndof-opensource` with your
   org, the image digest with the one from step 3, and the workflow-ref SHA
   with your fork's main commit. Projects stamped from then on are born
   pinned to your environment, and Dependabot maintains the pins.
6. Make the template yours: `template/AUTHORS`, the copyright line in the
   SPDX file headers, and — if you are not shipping Apache-2.0 — `LICENSE`
   and the `license` field in `conanfile.py`. Note that the `ndof-` naming
   (package names, the `ndof::` namespace) is baked into the template;
   renaming is a find-and-replace decision to make before your first stamp.
7. Enable a branch ruleset on `main`: require the `self-test` status check,
   require branches up to date, PRs only. Your first PR
   will exercise `self-test`, which builds the image and runs the full
   pipeline against a scratch stamp — the fork validates itself.
8. When your libraries start consuming each other as packages, stand up a
   Conan remote (Artifactory CE or a GitLab package registry) and add
   lockfiles.

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

The `github-owner` argument affects only the stamped project's *identity*
URLs (homepage, package metadata). Environment references — image digest,
CI workflow — are absolute and always point at the environment this repo
publishes (decision 12); a stamp under any owner builds and tests
immediately.

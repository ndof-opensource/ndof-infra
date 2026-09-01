# Developer onboarding

How to go from a fresh machine to building, testing, and contributing — and
enough theory about each moving part that nothing feels like magic. If you
want the *reasons* behind the setup, read [decisions.md](decisions.md).

## The mental model in one paragraph

This repo (`ndof-infra`) holds the **definition** of the team environment: a
Dockerfile, Conan profiles, CI logic, and a project template. Definitions are
turned into **pinned artifacts**: the Dockerfile becomes a published container
image identified by an immutable digest, and each project repo pins that
digest (in `.devcontainer/devcontainer.json`, and CI reads it from there). So every commit
of every project records exactly which environment built it, any machine can
reproduce it, and changing the environment is a reviewed pull request here
followed by explicit pin updates there.

## Day one

1. Install Docker (Docker Desktop or OrbStack) and clone a library repo,
   e.g. `ndof-core`.
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

For working on two ndof libraries at once (a library and its ndof
dependency), see "Live cross-repo development" in
[releasing.md](releasing.md); it uses a dedicated workspace directory
instantiated by `scripts/init-workspace.sh`.

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
- A **remote** is a package server. ConanCenter (public, anonymous)
  supplies third-party packages such as gtest. The public `ndof-public`
  remote supplies the ndof libraries themselves, so
  `requires = "ndof-core/x.y.z"` resolves across repos (see
  [releasing.md](releasing.md)). For live cross-repo editing,
  `conan editable add ../ndof-core` can be used to point your
  build at a sibling checkout instead, no publishing involved.
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

## How editor tooling fits together

The chain behind code intelligence, in order:

1. `conan install` (the first step of `scripts/build.sh`) generates the
   toolchain file; `cmake --preset debug` then writes
   `build/Debug/compile_commands.json`, the compile database recording
   the exact command for every translation unit.
2. **clangd**, the team language server, reads that database. It embeds
   the Clang compiler frontend, so its diagnostics are the compiler's
   opinion, fed by the real build's flags. The repo's `.clangd` file
   points it at `build/Debug` (its default search never looks there) and
   forces `-std=c++23` for brand-new headers that no compiled file
   includes yet. Every clangd-capable editor honors `.clangd`; nothing
   editor-specific is required for code intelligence.
3. clangd also surfaces the checks in `.clang-tidy` inline, and
   `.clang-format` drives formatting. Together those three files are the
   editor-agnostic tooling config; `customizations.vscode` in
   `devcontainer.json` carries VS Code niceties only (the cpptools
   extension for its gdb debugger, with its own IntelliSense engine
   disabled so clangd stays the single language-services engine).
4. There are **two build lanes** in an IDE. The task lane
   (Ctrl/Cmd+Shift+B, or "Tasks: Run Build Task") runs
   `scripts/build.sh` and is the canonical path; it can never build
   against a stale or unbootstrapped tree. The CMake-integration lane
   ("CMake: Build", the status-bar button) calls CMake directly and only
   works after the first `build.sh` run has generated the toolchain
   file; on an unbootstrapped tree it fails with a one-line message
   saying to run `build.sh`, and auto-configure on folder open is
   disabled for the same reason.

Fresh-clone rule of thumb: run `scripts/build.sh debug` once, then
restart the language server if the editor still shows stale errors.

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
| `cppcheck` | A second, independent static analyzer also finds nothing | `cppcheck --project=build/Debug/compile_commands.json --library=googletest --enable=warning,style,performance,portability --error-exitcode=1` |
| `package` | The Conan recipe itself works: export, build, test, and install as a package | `conan create . --build=missing -pr:a /opt/conan/profiles/linux-gcc14 -s build_type=Release` |
| `macos` / `windows` | Portability to AppleClang and MSVC | native runners only — CI is the arbiter |

The objective of CI (**Continuous Integration**): every change is built and
tested automatically before it lands, so integration breakage surfaces in
minutes and quality is the default path, not a discipline. The **CD**
(Continuous Delivery) side is `build-image.yml`, which publishes the
environment image on merge, and `publish.yml`, which publishes a library's
Conan package when a version tag is pushed (see
[releasing.md](releasing.md)).

## Changing the environment: the pins and how changes propagate

The environment reaches a library repo through two kinds of pinned
reference:

- **The image digest**, meaning *which environment*: compilers, tools,
  Conan profiles. It lives in exactly one file, `.devcontainer/devcontainer.json`.
  Your editor reads it to start the devcontainer, and the reusable CI's
  `digest-sync` job reads the same line to choose the container for every
  Linux job, so local and CI environments cannot disagree. Stubs carry no
  digest.
- **The workflow SHA**, meaning *which CI logic*: the jobs, their
  commands, the gates. Pinned in the `uses:` line of the CI stub
  (`.github/workflows/ci.yml`) and of the publish stub
  (`.github/workflows/publish.yml`). GitHub requires these to be literals.

`template/` in this repo carries the master copies of the same three
references (one digest, two SHAs); refreshing them is what future stamps
inherit.

What each kind of infra change requires:

| Change in ndof-infra | Produces | Re-pins required | Automated? |
|---|---|---|---|
| `image/Dockerfile`, `conan/profiles/` | new image digest (published by `build-image.yml` on merge) | digest, one line in every library's `.devcontainer/devcontainer.json` and in `template/`'s | **never** — always manual |
| reusable `ci.yml` | new commit SHA on `main` | workflow SHAs in each stub (ci.yml and publish.yml) | no — manual today (Dependabot cannot track a tagless repo); automation planned |
| both at once (new tool + a CI job using it) | both | digest **and** SHAs together, one PR per repo | no — see the ordering rule |
| docs, `scripts/`, `template/` files | new SHA, but no library-facing behavior | none (existing repos may hand-sync template file changes if wanted) | — |

What Dependabot covers:

- **In this repo:** the ubuntu base line in the Dockerfile (docker
  ecosystem) and action SHA pins in our own workflows (github-actions
  ecosystem).
- **In each library:** nothing today. The only `uses:` lines point at
  ndof-infra, which publishes no releases, so Dependabot has no update
  candidates; workflow SHA bumps are manual.

What Dependabot never touches — always manual:

- **The image digest, in either file.** Nothing scans `devcontainer.json`,
  and the stub's `image:` input is an opaque string to it. This is the one
  pin that silently rots if forgotten — which is why `digest-sync` exists.
- The `env:` tool versions in the reusable `ci.yml` (Conan/CMake/Ninja for
  the native macOS/Windows jobs) — kept matching the Dockerfile by hand,
  in the same PR that changes the Dockerfile.
- Files already stamped from `template/` into existing repos.

The image-change checklist:

1. PR to this repo changing `image/Dockerfile` (and `ci.yml` in the same
   PR, if the change adds a gate). `test-infra.yml` builds and exercises
   the candidate image before merge.
2. Merge → `build-image.yml` publishes multi-arch and prints the new
   digest; it is also available any time via
   `docker buildx imagetools inspect ghcr.io/ndof-opensource/ndof-dev:latest`.
3. One PR per library: the digest line in `.devcontainer/devcontainer.json`,
   plus the workflow SHAs if the reusable workflows changed. That PR's CI
   running green against the new pins *is* the adoption test.
4. One PR back here refreshing `template/`'s pins the same way.
5. Rollback = revert a pin PR. Nothing else to undo.

**Ordering rule.** When a `ci.yml` change depends on an image change (a
new job invoking a tool only the new image contains), never adopt the SHA
without the digest. Do the paired bumps promptly after publish; if
Dependabot's weekly SHA-only bump arrives first, it fails loudly in that
library ("command not found") — push the digest bump onto that PR's
branch, or close it and open the paired PR.

Tags like `:latest` are conveniences that move; digests are immutable facts.
Pin digests.

## Common pitfalls (each learned the hard way, once)

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
- **Linux hosts: the checkout must be writable by the container user.**
  Bind mounts preserve numeric uids, and the image's `dev` user is uid 1000.
  Devcontainer tools bridge the gap by remapping `dev`'s uid to yours at
  create time (`updateRemoteUserUID` — spec default, stated explicitly in
  our devcontainer.json); VS Code and the devcontainer CLI do this
  reliably, Zed currently has open bugs. Symptom: `PermissionError` on the
  first write, usually deep inside Conan; `scripts/build.sh` fails fast
  with the explanation. Diagnose with `id` (container user) vs `ls -ldn .`
  (checkout owner). Never `chmod -R 777` around it — git then sees every
  tracked file as modified (exec-bit mode changes that must not be
  committed), and container-created files still end up owned by the wrong
  uid. Fix the remapping, then re-clone if the tree was already chmodded.
- **One checkout used from host and container makes git's status lie.**
  Git decides "possibly modified" from cached stat data (inode, device,
  uid, ctime) that differs between the host filesystem and the same
  files seen through the container mount, so running git on both sides
  of one checkout makes every tracked file show as modified with empty
  diffs, flickering as each side refreshes the index in turn. Fix, once
  per clone (the setting lives in `.git/config`, which both sides
  share): `git config core.checkStat minimal` and
  `git config core.trustctime false`, then one `git status` to settle;
  from then on both sides judge freshness by size and mtime only, which
  the mount reports identically.
- **Editor code intelligence is configured by `.clangd`, and needs one
  build first.** clangd finds the compile database via the repo's `.clangd`
  file (`build/Debug` — clangd's default search never looks there). That
  file is honored by every editor; anything under `customizations.vscode`
  in devcontainer.json reaches VS Code *only* — Zed ignores it entirely.
  On a fresh clone there is no compile database until `scripts/build.sh
  debug` completes, so the editor shows include errors until the first
  build finishes and the language server restarts.
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
| remote | A Conan package server (ConanCenter for third-party packages; `ndof-public` for the ndof libraries; a private remote is planned for the private layer) |
| SPDX | Standardized machine-readable license identifiers (`SPDX-License-Identifier: Apache-2.0` headers) |

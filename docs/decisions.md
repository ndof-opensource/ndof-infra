# Design decisions

A record of the load-bearing decisions behind this infrastructure, with the
reasoning that produced them. Read this before proposing to change one — not
because they are immutable, but so the discussion starts from the original
trade-offs rather than rediscovering them. Decisions date from July 2026
unless noted.

## 1. Dev Container is the canonical environment

**Decision.** The team's development environment is a Docker image defined in
`image/Dockerfile`, published multi-arch (amd64 + arm64) to GHCR, and pinned
**by digest** in each project repository.

**Rationale.** Making the environment a versioned,
published artifact means: changes are reviewed PRs; any commit of any project
records exactly which environment built it (the digest pin lives in that
repo's history); rollback is reverting a pin. Alternatives considered: Nix
(stronger guarantees, steeper team cost, weak Windows story) and
docs-plus-version-managers (weakest consistency).

**Consequence.** The Dockerfile is *policy* (GCC 14, Clang 19, pinned tools);
the published digest is *fact* (bit-identical forever). Reproducibility claims
attach to the digest, not the Dockerfile. Of the build's three external inputs,
the base image is digest-pinned and the Python-installed tools are
exact-version-pinned;
apt packages installed on top still resolve against Ubuntu's live archive, so their
patch levels (e.g. GCC 14.x) float at image-build time. That residual float is
recorded in each published image's SBOM and its elimination (snapshot archives) is
out of scope for this public layer by design — see decision 11.

## 2. The container provides consistency; the CI matrix provides portability

**Decision.** Linux CI jobs run inside the dev image; macOS (AppleClang,
arm64) and Windows (MSVC) jobs run on native runners with pinned tools.

**Rationale.** Cross-platform claims are enforced by building every commit on three OSes and four compiler families (GCC, Clang, AppleClang, MSVC). Building with two
compilers on Linux (GCC + Clang, same standard library) is cheap cross-vendor
insurance.

## 3. Conan 2 for dependency management (over vcpkg)

**Decision.** Dependencies are declared in each repo's `conanfile.py` and
resolved against team profiles in `conan/profiles/` (baked into the image).

**Rationale.** Both tools solve C++'s ABI-aware dependency problem well; the
edges decided it. Conan's advantages match this project's trajectory:
(a) cross-compilation via build/host profile pairs — the path to embedded and
RTOS targets; (b) first-class production of *our own* packages (`conan
create` / `conan upload`), since the ndof libraries consume each other;
(c) lockfiles that capture the full resolved graph - including our own
internal packages - and first-class support for self-hosted remotes. At the
public layer this buys reproducible dependency resolution and a place to publish
`ndof-*` packages between repos. At the future private layer (decisions 7, 11),
the same machinery scales to controlled binary storage and the audit trail
certification evidence demands. Choosing Conan now means that requirement will
be met by configuration, not by a tooling migration.

**Consequences.** A self-hosted Conan remote (Artifactory CE or GitLab registry)
becomes necessary at the first internal release; until then ConanCenter
(gtest) suffices and `conan editable` covers cross-repo local development.
The libraries themselves must remain consumable *without* Conan (see 6).

## 4. C++23 baseline

**Decision.** All libraries target C++23 (`compiler.cppstd=23`,
`cxx_std_23`).

**Rationale.** `std::expected` and friends are directly relevant to the error
framework. Compiler floor (GCC 13+/Clang 17+/MSVC 19.36+) is easily satisfied
in a container-defined environment. The cost — a narrower consumer-toolchain
window than C++20 — is accepted and documented in each README.

## 5. One repository per library, stamped from a shared template

**Decision.** Each open-source library (`ndof-core-utils`, `ndof-callable`,
`ndof-error`, …) is its own repository, instantiated from `template/` via
`scripts/new-project.sh`. This repo prevents infrastructure drift: the image
and the reusable CI workflow are *referenced by pin*, not copied; only
rarely-churning files are copied at creation.

**Rationale.** The libraries are meant to be independently consumable,
versioned, and contributable open source. A monorepo
was rejected because it couldn't hold a public/private boundary (the ndof
framework itself may not be public) and blurs per-library releases. Per-repo
versioning also maps onto certification's configuration-item model.
Cross-repo coordination costs are mitigated by Conan (releases via remote,
`editable` for local development) rather than by co-location.

## 6. Libraries are plain CMake packages; Conan is never imposed on consumers

**Decision.** Every library installs proper CMake package files
(`find_package(ndof-<name>)` → `ndof::<name>`), with warnings kept `PRIVATE`
and `-Werror` opt-in (`NDOF_WERROR`, ON in team presets/CI, OFF by default).

**Rationale.** Conan is how *we* consume and publish; open-source consumers
must be free to use vcpkg, FetchContent, or system packages. Exported
`-Werror` is a classic way to break downstream builds on newer compilers.

## 7. ndof-infra is public

**Decision.** This repository, and the `ndof-dev` GHCR package, are public
under `ndof-opensource`.

**Rationale.** Hard constraint: public repos cannot call reusable workflows
in private repos, and CI containers/devcontainers must pull the image
anonymously. Beyond the constraint: the repo contains zero proprietary
information, and a public environment lets contributors reproduce the exact
lint/build gates their PRs face. Company-internal needs (licensed RTOS
toolchains, target-hardware profiles, internal remotes) belong in a future
*private* `ndof-infra-internal` image layered `FROM` this one — never bolted
onto this repo.

## 8. Apache-2.0, "The ndof Authors", AUTHORS file

**Decision.** All public repos are Apache-2.0. Per-file notices are two-line
SPDX headers (`Copyright 2026 The ndof Authors` +
`SPDX-License-Identifier: Apache-2.0`); the collective name is mapped to
legal entities in each repo's `AUTHORS` file.

**Rationale.** SPDX identifiers are machine-readable (SBOM/license scanners)
and survive files being vendored out of the repo. The collective-notice
pattern means headers never churn when the entity story evolves (a planned
501(c)(3) would be an AUTHORS edit plus assignment paperwork) or when
external contributors — who retain their own copyright under Apache-2.0 §5 —
start landing patches. No NOTICE file: it imposes a preservation burden on
every consumer for no current benefit.

## 9. New code is written fresh; prior prototypes are specifications

**Decision.** These libraries are clean implementations, not ports. Where
earlier internal prototypes of an idea exist, they are treated as
specifications and test-case sources: behavior worth keeping is reimplemented
against current standards, and any known failure mode of a prototype becomes
a named regression test in the new code.

**Rationale.** Rewriting against the full gate set (C++23,
warnings-as-errors, sanitizers, clang-tidy, review) is cheaper and safer than
retrofitting quality onto code that predates the gates. Encoding a
prototype's failure modes as tests preserves its lessons without inheriting
its implementation.

## 10. Convenience tooling never becomes load-bearing

**Decision.** `scripts/build.sh` wraps the canonical commands and prints each
one as it runs; CI executes the raw commands directly and never calls the
script.

**Rationale.** Wrappers that hide commands produce developers who cannot
debug the machinery, and a wrapper CI depends on is a second encoding of the
build that can drift. CI steps double as the always-true documentation of the
sequence; the script encodes operational footguns (profile switches require a
clean build tree) but can vanish without breaking anything.

## 11. Supply-chain posture of the public layer

**Decision.** The public infrastructure applies four controls: (a) all
artifacts in use are digest-pinned (dev image in project repos; ubuntu base
in the Dockerfile); (b) published images carry SBOM and SLSA provenance
attestations, so every digest answers "what is inside, and what built it";
(c) third-party GitHub Actions are pinned to commit SHAs, not mutable tags
(tag-retargeting is a real, exploited attack vector, and our actions handle
the token that publishes the image everyone executes); (d) Dependabot
(github-actions + docker ecosystems) opens bump PRs so pins never rot
silently — each bump is validated by test-infra.yml before merge.

**Rationale.** Out of scope here, required elsewhere. Snapshot-pinned apt archives
(snapshot.ubuntu.com), internally mirrored packages, and hash-pinned pip installs
are not applied in this repository — apt package patch-levels float at image-build
time, and upstream trust (Canonical/LLVM/PyPI signing keys) is accepted. This is
not deferred technical debt of the public layer: it is a control that belongs to a
different artifact with a different threat model. The public dev image serves OSS
contributors and CI, where "consistent, auditable, explicitly adopted" (digest pins, SBOM,
reviewed bumps) is the chosen proportionate standard. Bit-reproducible
builds from controlled inputs will be the standard of the future private build
environment (ndof-infra-internal, decision 7), which will layer FROM this image
and add those stricter input controls on top. If the private layer is never built,
this repository is not missing a control; if it is built, the requirement lands
there, not here.

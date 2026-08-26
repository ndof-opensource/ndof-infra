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

**Consequences.** Cross-library packages resolve from the public remote
(decision 15). A self-hosted remote (Artifactory CE or a GitLab registry)
remains the plan for the private layer, where controlled binary storage
and audit evidence matter. `conan editable` covers cross-repo local
development. The libraries themselves must remain consumable *without*
Conan (see 6).

## 4. C++23 baseline

**Decision.** All libraries target C++23 (`compiler.cppstd=23`,
`cxx_std_23`).

**Rationale.** `std::expected` and friends are directly relevant to the error
framework. Compiler floor (GCC 13+/Clang 17+/MSVC 19.36+) is easily satisfied
in a container-defined environment. The cost — a narrower consumer-toolchain
window than C++20 — is accepted and documented in each README.

## 5. One repository per library, stamped from a shared template

**Decision.** Each open-source library (`ndof-core`, `ndof-callable`,
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
contributors and CI, where "consistent, auditable, explicitly adopted" (digest
pins, SBOM, reviewed bumps) is the chosen proportionate standard. Bit-reproducible
builds from controlled inputs will be the standard of the future private build
environment (ndof-infra-internal, decision 7), which will layer FROM this image
and add those stricter input controls on top. If the private layer is never built,
this repository is not missing a control; if it is built, the requirement lands
there, not here.

The same boundary applies to image signing and runtime signature
verification (Sigstore/Cosign). A digest pin already *is* content
verification — the runtime hashes what it pulls and rejects a mismatch, so
no registry can substitute bits for a pinned digest. Verifying a signature
at CI runtime would defend only against an attacker who can rewrite the
pinned digest in a repo — and that attacker can edit the workflow files
that perform the verification; branch protection and review are the
controls that actually cover that path. Provenance is instead inspected by
a human at pin-bump time, and signing/verification machinery is a private-
layer control if it is ever needed.

## 12. Template environment references are absolute and pinned

**Decision.** In `template/`, references to the development environment —
the dev-image digest in `devcontainer.json`, the reusable-workflow ref and
image input in the CI stub, and the README's links to ndof-infra — are
hard-coded to `ndof-opensource` and pinned (digest / commit SHA). Only
identity references (the stamped project's own URLs in `CMakeLists.txt`
and `conanfile.py`) use the `__GITHUB_OWNER__` token.

**Rationale.** A digest and a workflow SHA are inherently specific to the
publishing org; pairing them with a tokenized owner produces references
that cannot resolve for any other owner. Absolute environment refs mean a
third-party stamp works immediately, riding the public ndof environment
(anonymous image pulls; reusable workflows execute on the caller's
runners, at no cost to this org). Environmental independence remains
available as an explicit fork-and-repin, per the README bootstrap.

## 13. CI container jobs run as root; devcontainers run as `dev`

**Decision.** The reusable CI runs its container jobs with `--user root`.
The devcontainer — the environment humans actually work in — runs as the
non-root `dev` user (uid 1000).

**Rationale.** GitHub Actions mounts the runner's work directories into
job containers at job start, owned by the runner's host user. Those paths
do not exist when the image is built, so no image-side permission scheme
can make them writable to `dev`; without root, checkout fails (EACCES).
Running as root in an ephemeral, discarded-after-job container is the
ecosystem-standard resolution, and the asymmetry with local development is
accepted: the toolchain and commands are identical, and permission-related
behavior that would affect a person surfaces in the devcontainer, which is
non-root. Alternatives rejected: world-writable directories baked into the
image (`chmod 777`) fix a directory that was never the problem and turn
the Conan cache into something any compromised build step can poison; a
user matching the runner's uid cannot be baked in, because that uid is a
host detail images should not encode.

## 14. Header layout: three visibility tiers

**Decision.** Each library's headers are organized in three tiers:

- `include/ndof/<lib>/` is the public API: headers users are expected to
  include and call, documented and governed by semantic versioning.
- `include/ndof/<lib>/details/` holds implementation headers that public
  headers must include transitively (template machinery, traits, storage
  types). They ship with the package because consumers' compilers need
  them, but they are not part of the supported API and may change
  without notice. Namespaces mirror folders: `ndof::<lib>::details`.
- `src/` holds everything only the library's own translation units use:
  sources and private headers. Nothing in `src/` is installed.

The subdirectory is named `details`, matching spdlog and the
convention as documented in WG21 P1204R0. Sibling conventions exist in
first-tier projects (`detail` in Boost and nlohmann/json, `internal`
in googletest and Abseil); the tiers themselves are common to all of
them, and we standardize on one name.

**Rationale.** The install boundary is the enforcement mechanism for
visibility: `install(DIRECTORY include/)` ships every header under
`include/` and nothing else. Placing internal-only headers in `src/`
therefore makes privacy physical rather than advisory: those files do
not exist on a consumer's machine, so no convention has to ask users
not to depend on them. `details/` exists because C++ forces some
implementation into shipped headers: template and inline definitions
must be visible to consumers' compilers, and the subdirectory (with its
matching namespace) marks exactly that code as outside the supported
API while still delivering it. Keeping `ndof/` directly under
`include/` preserves a further property: the line
`#include <ndof/<lib>/...>` resolves identically in the source tree and
against an installed package, so tests, examples, and documentation
always use the exact syntax consumers use. The classification test for
any new header: users call it, public; a public header includes it but
users do not call it, `details/`; neither, `src/`. Promoting a header
from `src/` to `details/` is therefore always a visible, reviewable
growth of the shipped surface, never a silent reclassification.

**Consequence.** No build changes: the existing install rules already
ship `details/` whenever a library creates one and already exclude
`src/`. `details/` directories are created on first need rather than
pre-seeded into the template. Header-heavy libraries (callable, error)
will carry most of their implementation in `details/` since template
definitions must be visible to consumers' compilers.

## 15. Public Conan remote on Cloudsmith; publishing is tag-driven and CI-only

**Decision.** Libraries publish Conan packages to one public remote,
`https://conan.cloudsmith.io/ndof-opensource/packages/` (client alias
`ndof-public`), hosted under Cloudsmith's open-source program. Publishing
is triggered only by a `v*` tag and performed only by the reusable
`.github/workflows/publish.yml`: it verifies the tag matches the conanfile
version, exports the recipe and sources from the tagged commit, and
uploads them; no prebuilt binaries and no build. Recipe correctness is
gated earlier, on every change, by a `package` job in the reusable CI
that runs `conan create` (export, build, test, install) in the pinned dev
image. Every consumer, including our CI, builds dependencies locally with
`--build=missing`. Nothing is ever published from a workstation.

**Rationale.** The first cross-library dependency (`ndof-error` on the
core library) made a remote necessary. The alternatives were a pinned
build-from-source script
(no infrastructure, but a second workflow to learn and unlearn later) or
standing up a self-hosted remote (with all of the associated overhead
to maintain the server for limited packages and consumers).
A hosted remote with anonymous read satisfies the
hard constraint that public CI and fork PRs must resolve packages with no
secrets, and Cloudsmith's open-source tier does so at no cost with
quotas well above our recipe-only usage. Cloudsmith's terms require
only attribution (in the README) and that we serve our own artifacts,
which the `ndof-*` upload filter enforces mechanically. Tag-driven
publishing makes every published version immutable: the "Verify tag
matches conanfile version" step in publish.yml refuses a new tag
whose conanfile version was not bumped, which would otherwise re-publish
an existing version as a new revision, and per-library tag rulesets
(`v*` cannot be moved or deleted; no other
tag shape can be created) block the other route, moving an existing tag,
at the git layer. CI-only
publishing keeps provenance uniform (a tagged `main` commit whose
`package` job passed, plus the publish run) and keeps the publishing
credentials confined to GitHub's org secrets. Recipe-only publishing
avoids a per-platform binary matrix while consumers already build from
source for every other dependency.

**Consequence.** The `version` field in `conanfile.py` names the next
version to publish and is bumped immediately after each release. The
image digest lives in exactly one file per repo,
`.devcontainer/devcontainer.json`; the reusable CI reads it from there, so
stubs carry no digest and a library has one image pin plus two workflow
SHAs (its CI stub and its publish stub, bumped by hand until propagation
is automated). Decision 3's self-hosted remote remains the plan for the
private layer (decisions 7 and 11). Conan resolves against multiple
remotes in order, so that remote will sit alongside this one rather than
replace it.

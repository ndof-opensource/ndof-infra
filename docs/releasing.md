# Releasing and consuming ndof Conan packages

How a library version gets published and how other libraries consume it.
For the reasoning behind the setup, see `docs/decisions.md`.

## Where packages live

- Host: Cloudsmith (free open-source hosting; see attribution in the
  README). Workspace `ndof-opensource`, repository `packages`.
- Conan remote URL: `https://conan.cloudsmith.io/ndof-opensource/packages/`
- Client alias used everywhere in this project: `ndof-public` (a local
  nickname, like git's `origin`; Cloudsmith never sees it).
- Reads are anonymous. Writes need the `ndof-ci` service account, whose
  credentials exist as the org-level GitHub secrets `CLOUDSMITH_USER` and
  `CLOUDSMITH_API_KEY`. Publishing runs only on tag pushes in our own
  repos; fork PRs never see secrets.

We publish recipes and sources only, no prebuilt binaries. Every consumer
(including our CI) builds locally via `--build=missing`, exactly as they
already do for gtest.

Packages are published only by `.github/workflows/publish.yml`, on a
version tag. It builds nothing: it exports the recipe and sources from the
tagged commit and uploads them. The build-and-test proof lives in CI's
`package` job, which runs `conan create` on every change before it can
reach `main`.

## Cutting a release

The `version` field in `conanfile.py` always names the version that will
be published *next*. A never-published library carries the stamped
`0.1.0`, and its first release is simply `v0.1.0`; no bump is needed.

1. Confirm `main` builds green and `version` in `conanfile.py` is the
   number you intend to publish. Everything that ships is already on
   `main` via merged PRs; nothing is committed directly to `main` (the
   branch ruleset forbids it), so there is no local commit step.
2. Tag the merge commit on `main` and push the tag. Locally, `pull`
   fetches that commit before you tag it:

   ```sh
   git switch main && git pull
   git tag v0.1.0
   git push origin v0.1.0
   ```

   Or with no local git at all: GitHub → Releases → "Draft a new
   release" → choose tag `v0.1.0` targeting `main` → publish. A tag
   created there fires the same workflow.

3. The `Publish` workflow runs automatically: it verifies the tag matches
   the conanfile version, exports the recipe and sources from the tagged
   commit (`conan export`), and uploads them to `ndof-public`.
4. Verify from any dev container:

   ```sh
   conan search "ndof-*" -r ndof-public
   ```

5. Immediately open a small PR bumping `version` to the next number
   (`0.1.1`), so `main` again describes what is coming rather than what
   already shipped. Under semver's 0.y.z rules any bump is allowed before
   1.0.0; bump the middle number when the public API changes shape.

Versions are immutable once published: never move or delete a tag; ship a
fix as the next version. The tag/version guard fails the workflow if the
two disagree, and each library's tag ruleset (`v*`: force-pushes and
deletions blocked) makes a published tag unmovable server-side.

## Consuming a released library

In the consuming repo's `conanfile.py`:

```python
def requirements(self):
    self.requires("ndof-core/0.1.1")
```

Nothing else: CI adds the `ndof-public` remote in every job, and
`scripts/build.sh` adds it locally on first run. Version bumps in
consumers are ordinary PRs whose CI proves the chain.

## Live cross-repo development (editable mode)

For editing a library and one of its ndof dependencies together (say,
core and error), skip the remote and point Conan at your sibling
checkout. Decision 16 has the reasoning; CI never uses editable mode.

One-time setup: create a dedicated directory, conventionally
`ndof-base`, containing only ndof repositories cloned side by side,
then instantiate the workspace into it (the script explains itself and
asks for confirmation):

```sh
ndof-infra/scripts/init-workspace.sh /path/to/ndof-base
```

Open `ndof-base/ndof.code-workspace` in your editor and reopen in the
container; every repo is at `/workspaces/<parent-name>/<repo>`.

The procedure, assuming `ndof-base`:

1. **Versions must match.** The consumer's `requires` must name the
   version the sibling's `conanfile.py` currently carries; check with
   `grep version /workspaces/ndof-base/ndof-core/conanfile.py`.
2. **Build the dependency in place** (editable mode redirects lookups;
   it builds nothing itself):
   `cd /workspaces/ndof-base/ndof-core && scripts/build.sh debug`
3. **Register it as editable**:
   `conan editable add /workspaces/ndof-base/ndof-core`
4. **Build the consumer**:
   `cd /workspaces/ndof-base/ndof-error && scripts/build.sh debug`.
   Its `conan install` now resolves ndof-core to the sibling checkout;
   the output shows that instead of a download from `ndof-public`.
5. **Iterate**: edit core, rebuild core (step 2), rebuild error
   (step 4). Header-only changes in core still require rebuilding
   error.
6. **When done, always**: `conan editable remove /workspaces/ndof-base/ndof-core`
   (the same path used in step 3; `conan editable remove --refs "ndof-core/*"`
   removes by reference pattern instead and also works).
   A forgotten entry silently shadows the published package in every
   future build in that container; `conan editable list` shows what is
   active. The registration and the Conan cache live in the container,
   so a container rebuild also resets them (redo steps 2 and 3).

Shipping is unchanged: the dependency's changes go through its own PR
and release, and the consumer's PR bumps its `requires`; a consumer PR
is only green once the version it names is actually published.

## Cloudsmith setup notes (in case a new repository needs to be created)

- A repository's Open-Source type is chosen at creation: select
  "Broadcast" visibility first, which unlocks the Open-Source option.
  The type is what grants the free OSS tier; plain Public is not it.
- Repository slugs (URL-compatible names) are permanent in practice: they appear in every
  pinned URL. 
- The service account needs write access to the one repository only.
- Cloudsmith's OSS hosting policy requires attribution with a link back
  to cloudsmith.com; ours lives in this repo's README. It also requires
  that the served artifacts are the project's own, which the `ndof-*`
  upload filter enforces mechanically.

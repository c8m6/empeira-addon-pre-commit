# Empeira Addon Pre-Commit

Small standalone Ruby addon for Empeira API 1. It installs Git pre-commit hooks
for a control repository and its Hiera repositories and runs their own
`.pre-commit-config.yaml` inside locally built Docker or Podman images.
Licensed AGPL-3.0-only. No default scanners and no extra addon configuration.

**Prerequisite:** each target repository must already contain its own
`.pre-commit-config.yaml`. `install`, `prepare`, `build`, and `run` fail before
touching the engine when it is missing. `status` reports missing configuration;
`uninstall` still lets you remove an owned hook after deleting that file.

## Installation

Requires Ruby 3.1, 3.2, 3.3, 3.4 or 4.0 and Git on Linux, macOS or WSL2, plus a working Docker or
Podman engine. Nothing is installed on the host by the addon. No Bundler, gem
build or addon install hook is needed; `./bin/pre-commit --help` works after
checkout. Native Windows is unsupported.

In the control repository's existing `.empeira.yaml`:

```yaml
addons:
  pre-commit:
    git: https://github.com/c8m6/empeira-addon-pre-commit.git
    ref: main
```

```sh
empeira addons sync
empeira addon pre-commit --help
empeira addon pre-commit install
```

For a pinned installation, use a commit or a tag from the
[latest releases](https://github.com/c8m6/empeira-addon-pre-commit/releases).
Releases never rewrite this README automatically.

## Repository selection and commands

The addon reads `EMPEIRA_CONTROL_REPO` and the effective API 1 exports
`EMPEIRA_CONFIG_HIERA_MOUNTS_COUNT` and
`EMPEIRA_CONFIG_HIERA_MOUNTS_<index>_SOURCE`, with `NAME` or `TARGET` as labels.
Hiera source paths are relative to the control root. Git roots are canonicalized
and deduplicated; missing sources and non-Git directories are reported and skipped.
It does not read a second configuration or start Empeira infrastructure.

```console
$ empeira addon pre-commit install
Install pre-commit hooks/images?
Control repository [Y/n]:
Hiera repository: common [Y/n]:
Hiera repository: network [Y/n]: n
Selected: 2 repositories
```

Enter means yes; `y/Y` confirms and `n/N` skips. The same selection is used for
`uninstall`, `prepare`, and `build`; `status` lists all available repositories.
Without a terminal, specify `--all` or `--repo PATH`. Unselected repositories
remain unchanged. Hiera repositories need no `.empeira.yaml`.

| Command | Behavior |
| --- | --- |
| `install` | Prepare missing images, then install owned hooks |
| `uninstall` | Remove only owned hooks; keep images |
| `prepare` | Build missing images ahead of a commit |
| `build` | Rebuild explicitly, without cached build steps |
| `status` | Report hook ownership and current image availability |
| `run` | Check staged files in one repository, never prompt |
| `run --all-files` | Check all tracked files in that repository |

```sh
empeira addon pre-commit install --all
empeira addon pre-commit prepare --repo /data/puppet/hiera-common
empeira addon pre-commit run --all-files
empeira addon pre-commit run -- check-yaml
empeira --container-engine podman addon pre-commit install --all
```

`--repo PATH` works for every command and selects exactly that Git root.
`--all` is for management only; `--all-files` is for `run` only. Both
`--help` and `COMMAND --help` document the options. Arguments after `run --`
are forwarded to `pre-commit run`. Completion uses the API 1 manifest.
Core global options go before `addon`. Outside Empeira, the executable chooses
Docker when present, otherwise Podman. A selected but inaccessible engine fails
explicitly instead of silently switching.

## Git hook types

The addon supports `pre-commit`, `commit-msg` and `prepare-commit-msg` using the
same prepared scanner image. The existing `.pre-commit-config.yaml` determines
which hooks are installed. If `default_install_hook_types` is set, it selects
exactly those types; otherwise the addon installs `pre-commit` and recognizes
explicit `commit-msg` / `prepare-commit-msg` stages in the configuration.

For example:

```yaml
default_install_hook_types: [pre-commit, commit-msg, prepare-commit-msg]
repos:
  - repo: local
    hooks:
      - id: validate-message
        name: Validate commit message
        entry: python scripts/check_commit_message.py
        language: system
        stages: [commit-msg]
```

An actual `git commit` forwards the commit-message file path to the container.
`prepare-commit-msg` additionally forwards Git's message source and commit object
as `PRE_COMMIT_COMMIT_MSG_SOURCE` and `PRE_COMMIT_COMMIT_OBJECT_NAME`. The
message file is mounted read/write so prepare hooks can edit it. Both stages
preserve their scanners' exit codes. A configuration change requires another
`install` to update the installed Git hook types; `uninstall` removes all owned
types even if the configuration changed. Foreign hooks are never overwritten.

Only these three hook types are managed; other entries in
`default_install_hook_types` produce an explicit error. For other stages, use
pre-commit directly.

## Configuration and images

An existing `.pre-commit-config.yaml` is used unchanged. A missing configuration
fails with a clear message and leaves that repository unchanged; other selected
repositories are still processed. No scanner template is copied automatically.
The previous mypuppet repository was unavailable during initial development, so
no mypuppet scanners or versions have been guessed or added.

Each image is named `localhost/empeira-pre-commit:<path-id>-<fingerprint>`.
SHA-256 includes the canonical repository path identity, pinned Python base image
digest, pre-commit 4.3.0, container preparation code, full pre-commit configuration,
and optional scanner build inputs. Ordinary application edits do not rebuild it.
Changing any configuration byte (including `args` or `exclude`) can rebuild it;
this deliberately avoids a second configuration interpreter. Old images remain
available until you remove them with the selected engine.

The build downloads the base and scanner dependencies, runs
`pre-commit install-hooks`, checks environment health, and retains
`PRE_COMMIT_HOME=/opt/pre-commit` in the image. Temporary build files are removed.
Regular hook runs use `--pull=never` and `--network=none`, without a host cache
volume. A small adapter for the **pinned** pre-commit version forbids cache
initialization and environment installation at runtime. The prepared scanner
cache is validated at build time and on each invocation, so missing environments
fail closed. Missing images, including manually deleted images, are rebuilt
before running; build errors abort the commit. A warm run skips the separate
container-engine readiness probe and reuses the already computed image
fingerprint, but still checks that the image exists.

## Local hooks and system dependencies

Remote hooks and `repo: local` hooks with ordinary package dependencies use
pre-commit's own installation logic. `language: system` tools must already exist
in the image, or be repository scripts mounted at runtime. The default image
provides Python, Git, Ruby/RubyGems, Ruby development headers, `libffi-dev`
and a C/C++ build toolchain, not a scanner catalogue.

For extra tools, optionally supply the standard build definition
`Containerfile.pre-commit` in the target repository. It replaces the base recipe;
the addon appends Python pre-commit installation and cache preparation. Use a
Linux image with Python (available as `python`), pip, Git and a root user. Pin
custom `FROM` images and dependency versions. `BASE_IMAGE` is the addon's pinned
Python image. Put additional build files in `pre-commit/`; only that directory,
the configuration and the recipe enter the build context. Its contents and
executable bits enter the fingerprint. Symlinks in scanner build inputs are
rejected. Never place secrets there.

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
COPY pre-commit/my-check /usr/local/bin/my-check
RUN chmod +x /usr/local/bin/my-check
```

Reference that tool in the repository's existing configuration as a local
`language: system` hook. For a locally packaged scanner, copy and install it in
this recipe and use a system hook. Relative file requirements in
`additional_dependencies` are resolved by pre-commit inside its own cache,
not against your checkout; use the recipe instead. Application scripts executed
directly from the checkout need no rebuild when edited. A custom recipe must
not override the appended cache, entrypoint or runtime contract. Nested
`language: docker` / `docker_image` hooks and scanners needing live network
access are unsupported; no Docker socket is mounted.

## Git hooks and runtime

Foreign hooks are never overwritten or edited. Installation is idempotent and
uninstallation recognizes only this addon's wrapper. Local `core.hooksPath` and
linked worktrees are supported. External/shared `core.hooksPath` fails explicitly:
removing it for one repository could affect others. Worktrees share Git's common
hook directory, so uninstalling there also removes the hook for related worktrees.

The Ruby wrapper calls the addon directly and detects the current Git root.
It stores Empeira's source/ref pointer, which follows `empeira addons update`
to the new immutable snapshot. No control-project lookup is needed during a
Hiera commit. Changing the source URL or configured ref requires reinstalling
hooks. For a plain checkout, keep the checkout at its installed path or reinstall.
The selected engine is retained in the wrapper; reinstall to change it.

The worktree and external Git metadata are mounted read/write at their original
absolute paths, preserving linked worktree links and pre-commit's index/stash
handling. Containers run as the caller's UID/GID (Podman uses `keep-id`), without
privileges or capabilities, with signal forwarding and automatic removal.
Relevant pre-commit/Git variables, including `SKIP` and `GIT_INDEX_FILE`, are
passed explicitly. External indexes and external alternate object stores are
unsupported. On macOS/WSL2 the engine must share these paths; on SELinux hosts
you must allow the bind mounts through the normal host policy. The addon does
not change labels or request root access. Scanner exit status is returned directly.

## Output and performance

When the host's stderr is a terminal, the addon forwards
`PRE_COMMIT_COLOR=always` so pre-commit retains its ANSI color output even
though the isolated container has no pseudo-terminal. An explicitly set
`PRE_COMMIT_COLOR` takes precedence. Hook-specific color behavior depends on
the scanner; the addon also forwards existing `FORCE_COLOR` and
`CLICOLOR_FORCE` values. Nonterminal output remains uncolored by default.

Only the first invocation that needs a scanner image builds and prepares it.
Further commits reuse the image, but each configured Git stage starts a separate
container. Pre-commit itself may buffer scanner output until each hook finishes.
In rootless Podman, engine startup and mount setup can take longer than Docker,
particularly under WSL2. The addon never starts a persistent background service
or bypasses the immutable/offline image policy for speed.

Older Podman/Buildah combinations can emit `can't raise ambient capability`
warnings during rootless builds; these originate in the container runtime, not
the scanner. Podman 5.3 (Buildah 1.38) addressed the underlying warning source.
Do not use `sudo` or suppress all engine warnings just to hide the messages.
They can be ignored when the build succeeds.

## Troubleshooting and development

- Missing configuration: add your chosen hooks yourself; the addon provides none.
- Missing executable: install the host Ruby/Git/engine yourself, or bake a scanner
  tool into `Containerfile.pre-commit`.
- Ruby-language scanner fails with `gem not found` or `missing libffi`: the
  default image includes Ruby, RubyGems, development headers and `libffi-dev`;
  run `empeira addons update` and rebuild the image. Custom
  `Containerfile.pre-commit` definitions must supply their own dependencies.
- Rootless Podman may warn that `/` is not a shared mount. This warning
  alone does not mean a build failed; investigate if bind mounts actually fail.
- Engine unavailable: start the engine and check permissions and path sharing.
- Unmanaged hook: review it yourself; move/remove it deliberately before installing.
- Incomplete image: run `build --repo PATH`; include required languages/libraries
  in the recipe. Builds require access to the configured scanner sources.
- TLS inspection proxy: add its trusted CA in your container recipe and run
  `update-ca-certificates`; keep certificate verification enabled. The integration
  test accepts `TEST_CA_CERT=/path/to/trusted-proxy-ca.crt` for its temporary image.
- Deleted image: `prepare` restores it, or the next hook builds it automatically.
- Failed scanner: fix the reported files; pre-commit's output is preserved.

Run `ruby test/pre_commit_test.rb` and, with a working engine,
`ruby test/integration_test.rb`. CI runs both suites and syntax checks on Ruby
3.1, 3.2, 3.3, 3.4 and 4.0 (max two matrix jobs in parallel). Integration tests use synthetic local hooks,
exercise dependency preparation, staged/unstaged files, fixes, worktrees, image
reuse/deletion, and exit codes. They install nothing in your working repositories.
See [CONTRIBUTING.md](CONTRIBUTING.md). Support:
[Empeira Discussions](https://github.com/c8m6/empeira/discussions).

Ruby 3.1 is the minimum supported version. All five supported versions (3.1, 3.2,
3.3, 3.4 and 4.0) run standalone behavior and actual addon/Core acceptance tests
on Linux and macOS in regular CI. See [CONTRIBUTING.md](CONTRIBUTING.md) for
local commands, optional dependencies and runtime/WSL2 validation limits.

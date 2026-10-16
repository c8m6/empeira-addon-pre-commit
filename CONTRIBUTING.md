# Contributing

Keep changes focused and follow [AGENTS.md](AGENTS.md). Use Conventional Commits.
Contributions are AGPL-3.0-or-later; retain third-party attribution and check license
compatibility. Documentation and comments are English. No CLA is required.

```sh
ruby -c bin/pre-commit
ruby -c lib/pre_commit.rb
ruby test/pre_commit_test.rb
ruby test/integration_test.rb
git diff --check
```

The last test needs Docker or Podman and network access for the initial build.
Set `EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE=podman` to test Podman explicitly.
Behind a TLS inspection proxy, set `TEST_CA_CERT=/path/to/trusted-proxy-ca.crt`
to add that CA to the temporary integration recipe. TLS verification stays enabled.
Tests use temporary synthetic repositories and remove their images and hooks.
No additional Ruby gems are needed. The runtime adapter uses pre-commit 4.3.0
internals; validate the adapter and prepared image when updating that version.

Use [Empeira Discussions](https://github.com/c8m6/empeira/discussions) for questions.
For undisclosed vulnerabilities follow [SECURITY.md](SECURITY.md).

## Ruby compatibility

Ruby 3.1 is the minimum; support Ruby 3.1, 3.2, 3.3, 3.4 and 4.0 without
changing the Empeira API 1 interface. Regular CI runs the complete standalone
behavioral suite on Ubuntu 24.04 and native macOS 15 for every version, including
a required Ruby 4.0 job. Require optional libraries explicitly; never install
dependencies automatically. Use the same Ruby on PATH for Core and the addon.

Core integration is tested by the shared acceptance gate in the reviewed Empeira
checkout. With this checkout under `/path/to/checkouts/empeira-addon-pre-commit`, run
from the Core checkout:

```sh
EMPEIRA_OFFICIAL_ADDON_ROOT=/path/to/checkouts EMPEIRA_OFFICIAL_ADDONS=pre-commit \
  bundle exec rspec spec/acceptance/official_addons.rb
```

This gate installs the real addon through Core's Git/cache/manifest path and
exercises configuration, revision updates, terminal I/O, arguments and errors in
synthetic repositories. Missing sources fail explicitly. CI pins the Core revision;
update it deliberately when the contract changes. Core owns its RSpec, RuboCop and
dual lockfile audit dependencies; this standalone addon still needs no Bundler.
Native Windows is unsupported. WSL2 and real engine capabilities need separate
real-host validation; Linux/macOS unit results do not establish those results.

The existing real Docker/Podman integration remains required on each Linux Ruby
job. Hosted macOS has no configured engine, so its matrix runs unit and Core
acceptance tests; run the documented real integration locally on a capable Mac.

Synthetic repository paths are canonicalized before comparing them with Git roots,
including macOS temporary-directory symlinks. No lifecycle assertion is relaxed.

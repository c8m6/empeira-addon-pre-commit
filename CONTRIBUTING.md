# Contributing

Keep changes focused and follow [AGENTS.md](AGENTS.md). Use Conventional Commits.
Contributions are AGPL-3.0-only; retain third-party attribution and check license
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

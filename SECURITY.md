# Security policy

Use [GitHub private vulnerability reporting](https://github.com/c8m6/empeira-addon-pre-commit/security/advisories/new)
if enabled. Otherwise request a private contact through
[Empeira Discussions](https://github.com/c8m6/empeira/discussions) without posting
vulnerability details. No email or response-time guarantee is provided.
Include the affected commit, Ruby/runtime versions and a synthetic reproduction.
Never attach production configuration, credentials or private keys. No guaranteed
backport policy is provided; check current `main` before reporting.

Addon code, pre-commit sources and repository Containerfiles are trusted executable
code. Review and pin them before installation. Build tools have network access;
regular scanner containers do not. Scanners can edit all mounted repository and
Git metadata, with the caller's permissions. This is not an isolation boundary
for untrusted repositories or malicious hooks. No socket, credential environment
dump, privileged container or automatic host installation is part of the workflow.

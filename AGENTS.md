# Project conventions

Standalone Empeira API 1 addon, Ruby 3.1–4.0 and standard libraries only.
Keep the implementation small; no Bundler, CLI framework, addon configuration
manager or scanner catalogue. The executable must work directly after checkout.
Do not modify Empeira Core. Use the actual API exports and manifest contract.

Code and documentation are AGPL-3.0-or-later; documentation and comments are English.
Do not overwrite unmanaged hooks or alter target pre-commit configurations.
Keep scanner installation in the image build, never in a normal hook run.
Preserve the pinned pre-commit adapter contract when updating the dependency.
Never request root or install host Docker/Podman from the addon.

Use small synthetic fixtures, no production data. Run
`ruby test/pre_commit_test.rb`, `ruby test/integration_test.rb` with an available
engine, Ruby syntax checks, and `git diff --check`. Report unavailable engines
honestly. Update help, manifest completion, and README when the CLI changes.
Use focused Conventional Commits and respect the user's publication instructions.

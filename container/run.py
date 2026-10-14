#!/usr/bin/env python3
"""Use pinned pre-commit normally, but forbid incomplete runtime preparation."""
# SPDX-License-Identifier: AGPL-3.0-only
import os
import shlex
import shutil
import sys

from pre_commit.clientlib import load_config
from pre_commit.main import main
from pre_commit.repository import _hook_installed, all_hooks
from pre_commit.store import Store
import pre_commit.repository


def prepared_repo(self, repo, ref, deps, make_strategy):
    with self.connect() as db:
        result = db.execute(
            'SELECT path FROM repos WHERE repo = ? AND ref = ?',
            (self.db_repo_name(repo, deps), ref),
        ).fetchone()
    if not result or not os.path.isdir(result[0]):
        raise RuntimeError('Scanner cache missing. Run pre-commit addon build.')
    return result[0]


def forbid_install(hook):
    raise RuntimeError('Scanner environment incomplete. Run pre-commit addon build.')


def check():
    hooks = all_hooks(load_config('.pre-commit-config.yaml'), Store())
    for hook in hooks:
        if hook.language in ('docker', 'docker_image'):
            raise RuntimeError('Nested Docker hooks are unsupported; use a system hook in the scanner image.')
        if not _hook_installed(hook):
            raise RuntimeError(f'Unprepared scanner: {hook.id}. Run pre-commit addon build.')
        if hook.language == 'system':
            executable = shlex.split(hook.entry)[0]
            # Repository scripts exist only at runtime; system tools must be baked in.
            if '/' not in executable and shutil.which(executable) is None:
                raise RuntimeError(f'Missing system hook executable: {executable}. Use Containerfile.pre-commit.')


Store._new_repo = prepared_repo
pre_commit.repository._hook_install = forbid_install
try:
    os.makedirs(os.environ['HOME'], exist_ok=True)
    if sys.argv[1:] == ['--check']:
        check()
        sys.exit(0)
    # The immutable image was already verified during build. On regular runs,
    # the patched store/install entrypoints still reject incomplete caches.
    sys.exit(main(sys.argv[1:]))
except (RuntimeError, OSError) as error:
    print(f'Error: {error}', file=sys.stderr)
    sys.exit(1)

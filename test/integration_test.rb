# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
require 'yaml'
require 'stringio'
require_relative '../lib/pre_commit'

def assert(condition, message = 'Assertion failed')
  raise message unless condition
end

def command(*args, env: {}, directory: Dir.pwd, expected: 0)
  out, err, result = Open3.capture3(env, *args, chdir: directory)
  assert(result.exitstatus == expected, "#{args.inspect}: #{result.exitstatus}\n#{out}\n#{err}")
  [out, err]
end

BIN = File.join(EmpeiraPreCommit::ROOT, 'bin', 'pre-commit')
app = EmpeiraPreCommit.new(output: StringIO.new)
engine = app.engine # Fail explicitly if the requested integration capability is missing.
env = { 'EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE' => engine,
        'EMPEIRA_CONTROL_REPO' => nil, 'EMPEIRA_ADDON_PATH' => nil,
        'EMPEIRA_CONFIG_HIERA_MOUNTS_COUNT' => nil, 'EMPEIRA_ADDON_VERSION' => nil }
tags = []

Dir.mktmpdir('empeira-integration-') do |tmp|
  begin
    repo = File.join(tmp, 'hiera standalone')
    Dir.mkdir(repo)
    command('git', 'init', '-q', repo)
    command('git', 'config', 'user.name', 'Synthetic Test', directory: repo)
    command('git', 'config', 'user.email', 'test@example.invalid', directory: repo)
    config = { 'default_install_hook_types' => EmpeiraPreCommit::HOOK_TYPES,
               'repos' => [{ 'repo' => 'local', 'hooks' => [{ 'id' => 'synthetic', 'name' => 'Synthetic dependency check',
               'entry' => 'python check.py', 'language' => 'python', 'additional_dependencies' => ['six==1.17.0'],
               'files' => '\\.txt$' }, { 'id' => 'synthetic-system', 'name' => 'Synthetic baked system tool',
               'entry' => '/opt/scanner/check', 'language' => 'system', 'files' => '\\.txt$' },
               { 'id' => 'synthetic-ruby', 'name' => 'Synthetic RubyGems hook',
                 'entry' => "ruby -e 'exit 0'", 'language' => 'ruby',
                 'additional_dependencies' => ['puppet'], 'files' => '\\.txt$' },
               { 'id' => 'synthetic-prepare-msg', 'name' => 'Prepare commit message',
                 'entry' => 'python message_check.py prepare', 'language' => 'system',
                 'stages' => ['prepare-commit-msg'] },
               { 'id' => 'synthetic-commit-msg', 'name' => 'Validate commit message',
                 'entry' => 'python message_check.py verify', 'language' => 'system',
                 'stages' => ['commit-msg'] }] }] }
    File.write(File.join(repo, '.pre-commit-config.yaml'), YAML.dump(config))
    FileUtils.mkdir_p(File.join(repo, 'pre-commit', 'tools'))
    tool = File.join(repo, 'pre-commit', 'tools', 'check')
    File.write(tool, "#!/bin/sh\nfor file do test -r \"$file\" || exit 1; done\n")
    File.chmod(0o755, tool)
    recipe = File.binread(File.join(EmpeiraPreCommit::ROOT, 'container', 'Containerfile'))
    recipe += "\nCOPY pre-commit/tools /opt/scanner\n"
    # Cloud/corporate proxy trust is an explicit test input, never a TLS bypass.
    if ENV['TEST_CA_CERT']
      FileUtils.cp(ENV.fetch('TEST_CA_CERT'), File.join(repo, 'pre-commit', 'test-ca.crt'))
      recipe += "\nCOPY pre-commit/test-ca.crt /usr/local/share/ca-certificates/test-ca.crt\nRUN update-ca-certificates\n"
    end
    File.write(File.join(repo, 'Containerfile.pre-commit'), recipe)
    File.write(File.join(repo, 'check.py'), <<~PYTHON)
      import pathlib, sys, six
      assert six.__version__ == '1.17.0'
      failed = False
      for name in sys.argv[1:]:
          path = pathlib.Path(name)
          text = path.read_text()
          if 'FAIL' in text:
              print('synthetic failure:', name)
              failed = True
          if 'FIX' in text:
              path.write_text(text.replace('FIX', 'fixed'))
      sys.exit(1 if failed else 0)
    PYTHON
    File.write(File.join(repo, 'message_check.py'), <<~PYTHON)
      import pathlib, sys
      mode, filename = sys.argv[1:]
      path = pathlib.Path(filename)
      text = path.read_text()
      if mode == 'prepare':
          path.write_text('Prepared: ' + text)
      elif not text.startswith('Prepared: '):
          print('commit message not prepared:', filename)
          sys.exit(1)
    PYTHON
    file = File.join(repo, 'data.txt')
    File.write(file, "initial\n")
    command('git', 'add', '.', directory: repo)
    command('git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Synthetic fixture', directory: repo)
    tags << app.image(repo)
    out, = command(BIN, 'install', '--repo', repo, env: env)
    assert(out.include?('Build completed.'))
    EmpeiraPreCommit::HOOK_TYPES.each { |type| assert(app.managed?(app.hook_path(repo, type))) }
    out, err = command(BIN, 'run', '--repo', repo, '--all-files', env: env)
    assert(out.include?('Passed') && !(out + err).include?('Installing environment'))
    assert(!out.include?('Building repository'))
    puts 'PASS real image build, prepared Python and Ruby hooks, baked local system tool and offline reuse'

    File.write(file, "staged\n")
    command('git', 'add', 'data.txt', directory: repo)
    File.write(file, "staged\nunstaged\n")
    command('git', 'commit', '-qm', 'Staged check from standalone Hiera', env: env, directory: repo)
    assert(File.read(file) == "staged\nunstaged\n")
    staged, = command('git', 'show', 'HEAD:data.txt', directory: repo)
    assert(staged == "staged\n")
    subject, = command('git', 'log', '-1', '--format=%s', directory: repo)
    assert(subject.strip == 'Prepared: Staged check from standalone Hiera',
           "prepare-commit-msg did not modify the commit message: #{subject}")
    bad_message = File.join(repo, 'unprepared-msg.txt')
    File.write(bad_message, "unprepared message\n")
    message_out, message_err = command(BIN, 'run', '--repo', repo, '--', '--hook-stage', 'commit-msg',
                                       '--commit-msg-filename', bad_message, env: env, expected: 1)
    assert((message_out + message_err).include?('commit message not prepared'))
    File.unlink(bad_message)
    puts 'PASS real pre-commit, prepare-commit-msg and commit-msg hooks with message forwarding'

    File.write(file, "FAIL\n")
    command('git', 'add', 'data.txt', directory: repo)
    _, err = command('git', 'commit', '-qm', 'Must fail', env: env, directory: repo, expected: 1)
    assert(err.include?('synthetic failure:'))
    File.write(file, "FIX\n")
    command('git', 'add', 'data.txt', directory: repo)
    command(BIN, 'run', '--repo', repo, env: env, expected: 1)
    assert(File.read(file) == "fixed\n" && File.stat(file).uid == Process.uid)
    command('git', 'add', 'data.txt', directory: repo)
    command('git', 'commit', '-qm', 'Fix applied', env: env, directory: repo)
    puts 'PASS failing scanner blocks commit; autofix preserves file ownership'

    worktree = File.join(tmp, 'linked worktree')
    command('git', 'worktree', 'add', '-qb', 'linked', worktree, directory: repo)
    tags << app.image(worktree)
    command(BIN, 'run', '--repo', worktree, '--all-files', env: env)
    File.write(File.join(worktree, 'data.txt'), "worktree staged\n")
    command('git', 'add', 'data.txt', directory: worktree)
    command('git', 'commit', '-qm', 'Linked worktree hook', env: env, directory: worktree)
    puts 'PASS linked worktree mounts and shared Git hook'

    command(engine, 'image', 'rm', tags.first)
    out, = command(BIN, 'run', '--repo', repo, '--all-files', env: env)
    assert(out.include?('Building repository-specific image') && out.include?('Passed'))
    puts 'PASS automatic recovery of deleted repository image'

    # Damage only a disposable container's cache: the guard must refuse repair.
    script = 'rm -rf /opt/pre-commit/repo*; cd /check; python /opt/empeira/run.py run --all-files'
    out, err = command(engine, 'run', '--rm', '--network=none', '--pull=never',
                       '--mount', "type=bind,src=#{repo},dst=/check", '--entrypoint', 'sh',
                       tags.first, '-c', script, expected: 1)
    assert(err.include?('Scanner cache missing') && !(out + err).include?('Installing environment'))
    puts 'PASS incomplete runtime cache fails instead of installing scanners'

    command(BIN, 'uninstall', '--repo', repo, env: env)
    assert(!File.exist?(app.hook_path(repo)))
    puts 'PASS integration hook removal'
  ensure
    tags.each { |tag| system(engine, 'image', 'rm', tag, out: File::NULL, err: File::NULL) }
  end
end

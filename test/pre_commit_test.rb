# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only
require 'json'
require 'stringio'
require 'yaml'
require_relative '../lib/pre_commit'

def assert(condition, message = 'Assertion failed')
  raise message unless condition
end

def check(name)
  yield
  puts "PASS #{name}"
end

BIN = File.join(EmpeiraPreCommit::ROOT, 'bin', 'pre-commit')

def cli(env, *args, directory: Dir.pwd)
  Open3.capture3(env, BIN, *args, chdir: directory)
end

def git(repo, *args)
  out, err, status = Open3.capture3('git', '-C', repo, *args)
  assert(status.success?, err)
  out.strip
end

def repository(path)
  FileUtils.mkdir_p(path)
  git(path, 'init', '-q')
  File.write(File.join(path, '.pre-commit-config.yaml'), "repos: []\n")
  path
end

Dir.mktmpdir('empeira-unit-') do |tmp|
  tmp = File.realpath(tmp)
  tools = File.join(tmp, 'bin')
  FileUtils.mkdir_p(tools)
  File.write(File.join(tools, 'docker'), <<~RUBY)
    #!/usr/bin/env ruby
    require 'json'
    require 'digest'
    require 'fileutils'
    File.open(ENV.fetch('FAKE_LOG'), 'a') { |f| f.puts JSON.generate(ARGV) }
    def image(tag)
      File.join(ENV.fetch('FAKE_IMAGES'), Digest::SHA256.hexdigest(tag))
    end
    case ARGV[0]
    when 'info' then exit 0
    when 'image' then exit(File.file?(image(ARGV.last)) ? 0 : 1)
    when 'build'
      exit 9 if ENV['FAKE_BUILD_FAIL'] == '1'
      FileUtils.touch(image(ARGV[ARGV.index('-t') + 1]))
      exit 0
    when 'run' then exit Integer(ENV.fetch('FAKE_EXIT', '0'))
    else exit 99
    end
  RUBY
  File.chmod(0o755, File.join(tools, 'docker'))
  images = File.join(tmp, 'images')
  FileUtils.mkdir_p(images)
  control = repository(File.join(tmp, 'control repo'))
  hiera = repository(File.join(tmp, 'hiera'))
  log = File.join(tmp, 'log')
  env = { 'PATH' => "#{tools}:#{ENV.fetch('PATH')}", 'FAKE_LOG' => log, 'FAKE_IMAGES' => images,
          'EMPEIRA_CONTROL_REPO' => control, 'EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE' => 'docker',
          'EMPEIRA_CONFIG_HIERA_MOUNTS_COUNT' => '3',
          'EMPEIRA_CONFIG_HIERA_MOUNTS_0_SOURCE' => '../hiera', 'EMPEIRA_CONFIG_HIERA_MOUNTS_0_NAME' => 'common',
          'EMPEIRA_CONFIG_HIERA_MOUNTS_1_SOURCE' => '../hiera',
          'EMPEIRA_CONFIG_HIERA_MOUNTS_2_SOURCE' => '../missing',
          'EMPEIRA_ADDON_PATH' => nil, 'EMPEIRA_ADDON_VERSION' => nil, 'EMPEIRA_ADDON_API_VERSION' => '1' }
  app = EmpeiraPreCommit.new(environment: ENV.to_h.merge(env).compact, output: StringIO.new, errors: StringIO.new)

  check('API 1 manifest and executable CLI') do
    manifest = YAML.safe_load_file(File.join(EmpeiraPreCommit::ROOT, 'empeira-addon.yaml'))
    assert(manifest['schema'] == 1 && manifest['executable'] == 'bin/pre-commit')
    assert(manifest['commands'].keys == EmpeiraPreCommit::COMMANDS)
    EmpeiraPreCommit::COMMANDS.each do |command|
      out, err, result = cli(env, command, '--help')
      assert(result.success? && out.include?('--repo PATH'), err)
    end
    _, err, result = cli(env, 'run', '--all')
    assert(!result.success? && err.include?('only for management'))
  end

  check('interactive selection: Enter, n, canonical deduplication, missing sources') do
    input = StringIO.new("\nn\n")
    def input.tty? = true
    output, errors = StringIO.new, StringIO.new
    interactive = EmpeiraPreCommit.new(environment: ENV.to_h.merge(env).compact, input: input, output: output, errors: errors)
    selected = interactive.repositories('install', {})
    assert(selected == [['Control repository', control]])
    assert(output.string.scan('[Y/n]').size == 2 && output.string.include?('Selected: 1'))
    assert(errors.string.include?('unavailable'))
    assert(!File.exist?(File.join(hiera, '.git', 'hooks', 'pre-commit')))
  end

  check('--all installs all existing repositories, idempotently; uninstall owns only its hooks') do
    2.times do
      _, err, result = cli(env, 'install', '--all')
      assert(result.success?, err)
    end
    [control, hiera].each { |repo| assert(app.managed?(app.hook_path(repo))) }
    foreign = File.join(hiera, '.git', 'hooks', 'post-commit')
    File.write(foreign, '# foreign')
    _, err, result = cli(env, 'uninstall', '--all')
    assert(result.success?, err)
    [control, hiera].each { |repo| assert(!File.exist?(app.hook_path(repo))) }
    assert(File.read(foreign) == '# foreign')
  end

  check('unmanaged hooks and symlinks are protected before image preparation') do
    hook = app.hook_path(hiera)
    File.write(hook, "#!/bin/sh\nexit 0\n")
    original = File.binread(hook)
    _, err, result = cli(env, 'install', '--repo', hiera)
    assert(!result.success? && err.include?('unmanaged'))
    assert(File.binread(hook) == original)
    File.unlink(hook)
    File.symlink(File.join(hiera, '.pre-commit-config.yaml'), hook)
    _, _, result = cli(env, 'install', '--repo', hiera)
    assert(!result.success? && File.symlink?(hook))
    File.unlink(hook)
  end

  check('commit-msg and prepare-commit-msg install, forward message files and uninstall cleanly') do
    config = File.join(hiera, '.pre-commit-config.yaml')
    File.write(config, YAML.dump('repos' => [], 'default_install_hook_types' => %w[pre-commit commit-msg prepare-commit-msg]))
    _, err, result = cli(env, 'install', '--repo', hiera)
    assert(result.success?, err)
    EmpeiraPreCommit::HOOK_TYPES.each { |type| assert(app.managed?(app.hook_path(hiera, type))) }
    message = File.join(hiera, '.git', 'COMMIT_EDITMSG')
    File.write(message, "feat: synthetic message\n")
    File.write(log, '')
    _, err, result = Open3.capture3(env, app.hook_path(hiera, 'commit-msg'), message, chdir: hiera)
    assert(result.success?, err)
    _, err, result = Open3.capture3(env, app.hook_path(hiera, 'prepare-commit-msg'),
                                   message, 'message', 'deadbeef', chdir: hiera)
    assert(result.success?, err)
    runs = File.readlines(log).map { |line| JSON.parse(line) }.select { |args| args.first == 'run' }
    assert(runs.size == 2)
    assert(runs.first.each_cons(2).include?(%w[--hook-stage commit-msg]))
    assert(runs.last.each_cons(2).include?(%w[--hook-stage prepare-commit-msg]))
    assert(runs.all? { |args| args.each_cons(2).include?(['--commit-msg-filename', message]) })
    assert(runs.last.include?('--env') && runs.last.include?('PRE_COMMIT_COMMIT_MSG_SOURCE=message'))
    assert(runs.last.include?('PRE_COMMIT_COMMIT_OBJECT_NAME=deadbeef'))
    _, err, result = cli(env, 'uninstall', '--repo', hiera)
    assert(result.success?, err)
    EmpeiraPreCommit::HOOK_TYPES.each { |type| assert(!File.exist?(app.hook_path(hiera, type))) }
    File.write(config, "repos: []\n")
  end

  check('message stages are discovered without defaults and unmanaged hooks are preserved') do
    config = File.join(hiera, '.pre-commit-config.yaml')
    File.write(config, YAML.dump('repos' => [
      { 'repo' => 'local', 'hooks' => [{ 'id' => 'check-message', 'stages' => ['commit-msg'] }] }
    ]))
    assert(app.hook_types(hiera) == %w[pre-commit commit-msg])
    foreign = app.hook_path(hiera, 'commit-msg')
    File.write(foreign, "#!/bin/sh\nexit 0\n")
    _, err, result = cli(env, 'install', '--repo', hiera)
    assert(!result.success? && err.include?('unmanaged'))
    assert(File.read(foreign).include?('exit 0'))
    assert(!File.exist?(app.hook_path(hiera, 'pre-commit')))
    File.unlink(foreign)
    _, err, result = cli(env, 'install', '--repo', hiera)
    assert(result.success?, err)
    assert(app.managed?(app.hook_path(hiera, 'commit-msg')))
    File.write(config, "repos: []\n")
    _, err, result = cli(env, 'install', '--repo', hiera)
    assert(result.success?, err)
    assert(!File.exist?(app.hook_path(hiera, 'commit-msg')), 'Reinstall must remove obsolete owned hooks')
    app.uninstall(hiera)
  end

  check('warm hook execution needs no engine-info preflight and preserves terminal colors') do
    File.write(log, '')
    terminal = StringIO.new
    def terminal.tty? = true
    colored = EmpeiraPreCommit.new(environment: ENV.to_h.merge(env).compact, errors: terminal)
    args = colored.run_arguments(control)
    assert(args.each_cons(2).include?(['--env', 'PRE_COMMIT_COLOR=always']))
    assert(File.read(log).empty?, 'Building run argv must not invoke the container engine')
    overridden = EmpeiraPreCommit.new(environment: ENV.to_h.merge(env, 'PRE_COMMIT_COLOR' => 'never').compact,
                                      errors: terminal)
    args = overridden.run_arguments(control)
    assert(args.each_cons(2).include?(['--env', 'PRE_COMMIT_COLOR=never']))
    assert(!args.include?('PRE_COMMIT_COLOR=always'))
  end

  check('fingerprints isolate repositories and ignore application edits') do
    original = app.image(control)
    assert(original != app.image(hiera))
    File.write(File.join(control, 'application.yaml'), 'changed')
    assert(app.image(control) == original)
    config = File.join(control, '.pre-commit-config.yaml')
    File.write(config, "repos: []\n# changed\n")
    assert(app.image(control) != original)
    File.write(config, "repos: []\n")
    inputs = File.join(control, 'pre-commit')
    Dir.mkdir(inputs)
    scanner = File.join(inputs, 'scanner')
    File.write(scanner, 'one')
    scanner_tag = app.image(control)
    File.chmod(0o755, scanner)
    assert(app.image(control) != scanner_tag)
    FileUtils.remove_entry(inputs)
  end

  check('missing image rebuilds once and scanner exit status is preserved') do
    FileUtils.rm_f(Dir.glob(File.join(images, '*')))
    File.write(log, '')
    _, err, result = cli(env.merge('FAKE_EXIT' => '7'), 'run', '--repo', hiera, '--all-files')
    assert(result.exitstatus == 7, err)
    _, err, result = cli(env, 'run', '--repo', hiera)
    assert(result.success?, err)
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    assert(calls.count { |args| args.first == 'build' } == 1)
    run = calls.find { |args| args.first == 'run' }
    assert(run.include?('--network=none') && run.include?('--pull=never') && run.include?('--all-files'))
    assert(run.include?('--user') && !run.join.include?('docker.sock'))
    FileUtils.rm_f(Dir.glob(File.join(images, '*')))
    _, err, result = cli(env.merge('FAKE_BUILD_FAIL' => '1'), 'run', '--repo', hiera)
    assert(!result.success? && err.include?('build failed'))
  end

  check('hook executes in standalone Hiera context and follows updated snapshots') do
    storage = File.join(tmp, 'addon-cache')
    refs = File.join(storage, 'refs')
    FileUtils.mkdir_p(refs)
    reference = File.join(refs, Digest::SHA256.hexdigest('main'))
    commits = %w[a b].map { |letter| letter * 40 }
    commits.each_with_index do |commit, index|
      snapshot = File.join(storage, 'revisions', commit)
      FileUtils.mkdir_p(File.join(snapshot, 'bin'))
      File.write(File.join(snapshot, 'bin', 'pre-commit'), "#!/usr/bin/env ruby\nexit #{index + 6}\n")
      File.chmod(0o755, File.join(snapshot, 'bin', 'pre-commit'))
    end
    File.write(reference, commits.first)
    _, err, result = cli(env.merge('EMPEIRA_ADDON_PATH' => File.join(storage, 'revisions', commits.first),
                                 'EMPEIRA_ADDON_VERSION' => 'main'), 'install', '--repo', hiera)
    assert(result.success?, err)
    clean = env.merge('EMPEIRA_CONTROL_REPO' => nil, 'EMPEIRA_CONFIG_HIERA_MOUNTS_COUNT' => nil)
    _, err, result = Open3.capture3(clean, app.hook_path(hiera), chdir: hiera)
    assert(result.exitstatus == 6, err)
    File.write(reference, commits.last)
    _, err, result = Open3.capture3(clean, app.hook_path(hiera), chdir: hiera)
    assert(result.exitstatus == 7, err)
    File.unlink(reference)
    _, err, result = Open3.capture3(clean, app.hook_path(hiera), chdir: hiera)
    assert(!result.success? && err.include?('Cannot start'))
    app.uninstall(hiera)
  end

  check('local hooksPath is respected; shared external hooksPath is rejected') do
    git(control, 'config', 'core.hooksPath', '.hooks')
    _, err, result = cli(env, 'install', '--repo', control)
    assert(result.success? && app.managed?(File.join(control, '.hooks', 'pre-commit')), err)
    _, err, result = cli(env, 'uninstall', '--repo', control)
    assert(result.success?, err)
    git(control, 'config', 'core.hooksPath', File.join(tmp, 'shared-hooks'))
    _, err, result = cli(env, 'install', '--repo', control)
    assert(!result.success? && err.include?('External/shared'))
    git(control, 'config', '--unset', 'core.hooksPath')
  end

  check('explicit rebuild and exported Podman selection') do
    FileUtils.cp(File.join(tools, 'docker'), File.join(tools, 'podman'))
    File.chmod(0o755, File.join(tools, 'podman'))
    podman = env.merge('EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE' => 'podman')
    File.write(log, '')
    _, err, result = cli(podman, 'build', '--repo', control)
    assert(result.success?, err)
    _, err, result = cli(podman, 'run', '--repo', control)
    assert(result.success?, err)
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    assert(calls.find { |args| args.first == 'build' }.include?('--no-cache'))
    assert(calls.find { |args| args.first == 'run' }.include?('--userns=keep-id'))
  end

  check('absent configuration leaves repositories untouched') do
    File.unlink(File.join(hiera, '.pre-commit-config.yaml'))
    before = git(hiera, 'status', '--porcelain')
    _, err, result = cli(env, 'install', '--repo', hiera)
    assert(!result.success? && err.include?('No .pre-commit-config.yaml'))
    assert(git(hiera, 'status', '--porcelain') == before && !File.exist?(app.hook_path(hiera)))
    %w[prepare build run].each do |command|
      File.write(log, '')
      _, err, result = cli(env, command, '--repo', hiera)
      assert(!result.success? && err.include?('No .pre-commit-config.yaml'))
      assert(File.read(log).empty?, 'Missing configuration must fail before touching the engine')
    end
  end
end

# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require 'digest'
require 'etc'
require 'fileutils'
require 'open3'
require 'optparse'
require 'pathname'
require 'tmpdir'
require 'yaml'

class EmpeiraPreCommit
  ROOT = File.expand_path('..', __dir__)
  CONFIG = '.pre-commit-config.yaml'
  VERSION = '4.3.0'
  BASE = 'python:3.13-slim-bookworm@sha256:a1165e272e578941b84abc79e4ab38a0305cd12803a5c4247979ac7655f4d641'
  COMMANDS = %w[install uninstall prepare build status run].freeze
  HOOK_TYPES = %w[pre-commit commit-msg prepare-commit-msg].freeze
  MARKER = "#!/usr/bin/env ruby\n# Managed by empeira-addon-pre-commit (API 1)\n"
  class Error < StandardError; end

  def initialize(environment: ENV, input: $stdin, output: $stdout, errors: $stderr)
    @env, @input, @output, @errors = environment, input, output, errors
  end

  def call(arguments)
    arguments = arguments.dup
    command = arguments.shift
    options = {}
    parser = OptionParser.new do |o|
      o.banner = 'Usage: empeira addon pre-commit COMMAND [options]'
      o.separator "Commands: #{COMMANDS.join(', ')}"
      o.on('--repo PATH', 'Use exactly this Git repository, without questions') { |v| options[:repo] = v }
      o.on('--all', 'Management: select all discovered repositories') { options[:all] = true }
      o.on('--all-files', 'Run: check all tracked files instead of staged files') { options[:all_files] = true }
      o.on('-h', '--help', 'Show this help') { options[:help] = true }
      o.separator 'Run also forwards arguments after -- to pre-commit run (for example a hook ID).'
      o.separator 'Install manages pre-commit, commit-msg and prepare-commit-msg from repository configuration.'
      o.separator 'Core runtime option goes before addon: empeira --container-engine podman addon pre-commit ...'
    end
    if command.nil? || %w[-h --help].include?(command)
      @output.puts parser
      return 0
    end
    raise Error, "Unknown command: #{command}" unless COMMANDS.include?(command)

    parser.parse!(arguments)
    if options[:help]
      @output.puts parser
      return 0
    end
    raise Error, '--repo and --all are mutually exclusive' if options[:repo] && options[:all]
    raise Error, '--all is only for management commands' if command == 'run' && options[:all]
    raise Error, '--all-files is only for run' if command != 'run' && options[:all_files]
    raise Error, 'Unexpected arguments; use run -- ARGS to pass pre-commit options' if command != 'run' && !arguments.empty?
    api = @env['EMPEIRA_ADDON_API_VERSION']
    raise Error, "Unsupported Empeira addon API: #{api}" if api && api != '1'

    if command == 'run'
      repo = git_root(options[:repo] || Dir.pwd)
      tag = prepare(repo)
      exec(*run_arguments(repo, arguments, all_files: options[:all_files], tag: tag), chdir: repo)
    end
    selected = repositories(command, options)
    failed = false
    selected.each do |label, repo|
      @output.puts "#{label}: #{repo}"
      begin
        case command
        when 'install' then install(repo)
        when 'uninstall' then uninstall(repo)
        when 'prepare', 'build' then prepare(repo, force: command == 'build')
        when 'status' then status(repo)
        end
      rescue Error, SystemCallError => e
        @errors.puts "Error: #{repo}: #{e.message}"
        failed = true
      end
    end
    failed ? 1 : 0
  rescue Error, OptionParser::ParseError, SystemCallError => e
    @errors.puts "Error: #{e.message}"
    1
  rescue Interrupt
    130
  end

  def git(repo, *arguments)
    stdout, stderr, result = Open3.capture3('git', '-C', repo, *arguments)
    raise Error, "Git failed: #{stderr.strip}" unless result.success?

    stdout.strip
  end

  def git_root(path)
    root = git(File.expand_path(path), 'rev-parse', '--show-toplevel')
    File.realpath(root)
  end

  def repositories(command, options)
    return [['Repository', git_root(options[:repo])]] if options[:repo]

    control = @env['EMPEIRA_CONTROL_REPO'] || git_root(Dir.pwd)
    candidates = [['Control repository', control]]
    count = Integer(@env.fetch('EMPEIRA_CONFIG_HIERA_MOUNTS_COUNT', '0'), 10)
    count.times do |i|
      prefix = "EMPEIRA_CONFIG_HIERA_MOUNTS_#{i}"
      source = @env["#{prefix}_SOURCE"]
      next unless source

      name = @env["#{prefix}_NAME"] || @env["#{prefix}_TARGET"] || source
      candidates << ["Hiera repository: #{name}", File.expand_path(source, control)]
    end
    seen = {}
    available = candidates.filter_map do |label, path|
      begin
        repo = git_root(path)
        next if seen[repo]

        seen[repo] = true
        [label, repo]
      rescue Error, SystemCallError => e
        @errors.puts "#{label}: unavailable (#{path}): #{e.message}"
        nil
      end
    end
    raise Error, 'No available Git repositories found' if available.empty?
    return available if options[:all] || command == 'status'

    raise Error, 'Selection requires a terminal; use --all or --repo PATH' unless @input.tty?

    @output.puts "#{command.capitalize} pre-commit hooks/images?"
    selected = available.select do |label, _repo|
      loop do
        @output.print "#{label} [Y/n]: "
        @output.flush
        answer = @input.gets
        raise Error, 'Selection cancelled (end of input)' unless answer

        break true if ['', 'y'].include?(answer.strip.downcase)
        break false if answer.strip.downcase == 'n'

        @output.puts 'Please answer y or n.'
      end
    end
    @output.puts "Selected: #{selected.size} repositories"
    selected
  rescue ArgumentError
    raise Error, 'Invalid Empeira Hiera mount count'
  end

  def engine
    return @engine if @engine

    requested = @env['EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE']
    choices = requested ? [requested] : %w[docker podman]
    raise Error, "Unsupported container engine: #{requested}" unless (choices - %w[docker podman]).empty?

    @engine = choices.find do |name|
      @env.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |p| File.executable?(File.join(p, name)) }
    end
    raise Error, requested ? "#{requested} is not on PATH" : 'Neither Docker nor Podman is available' unless @engine
    @engine
  end

  def configuration!(repo)
    raise Error, "No #{CONFIG} found in repository; repository left unchanged" unless File.file?(File.join(repo, CONFIG))
  end

  # Only scanner build inputs enter the context; application files stay on the host.
  def build_inputs(repo)
    files = { CONFIG => File.binread(File.join(repo, CONFIG)),
              'Containerfile' => File.binread(File.join(ROOT, 'container', 'Containerfile')),
              'run.py' => File.binread(File.join(ROOT, 'container', 'run.py')) }
    custom = File.join(repo, 'Containerfile.pre-commit')
    files['Containerfile'] = File.binread(custom) if File.file?(custom)
    directory = File.join(repo, 'pre-commit')
    raise Error, 'Scanner build directory must not be a symlink' if File.symlink?(directory)
    if File.directory?(directory)
      Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).sort.each do |path|
        next if %w[. ..].include?(File.basename(path))
        raise Error, "Scanner build inputs must not be symlinks: #{path}" if File.symlink?(path)
        next if File.directory?(path)
        raise Error, "Scanner input is not a regular file: #{path}" unless File.file?(path)

        files[Pathname(path).relative_path_from(Pathname(repo)).to_s] = File.binread(path)
      end
    end
    files
  end

  def image(repo)
    configuration!(repo)
    digest = Digest::SHA256.new
    [BASE, VERSION, File.binread(File.join(ROOT, 'container', 'prepare.Containerfile'))].each do |value|
      digest.update("#{value.bytesize}:#{value}")
    end
    build_inputs(repo).sort.each do |name, content|
      digest.update("#{name.bytesize}:#{name}#{content.bytesize}:#{content}")
      digest.update(File.executable?(File.join(repo, name)) ? 'x' : '-') if name.start_with?('pre-commit/')
    end
    "localhost/empeira-pre-commit:#{Digest::SHA256.hexdigest(repo)[0, 16]}-#{digest.hexdigest}"
  end

  def image_present?(tag)
    system(engine, 'image', 'inspect', tag, out: File::NULL, err: File::NULL)
  end

  def prepare(repo, force: false)
    tag = image(repo)
    return tag if !force && image_present?(tag)

    raise Error, "#{engine} is unavailable; check the engine and your permissions" unless
      system(engine, 'info', out: File::NULL, err: File::NULL)

    @output.puts 'Pre-commit image missing or rebuild requested. Building repository-specific image...'
    @output.flush
    Dir.mktmpdir('empeira-pre-commit-') do |directory|
      build_inputs(repo).each do |name, content|
        path = File.join(directory, name)
        FileUtils.mkdir_p(File.dirname(path))
        Pathname(File.dirname(path)).ascend do |parent|
          break if parent.to_s == directory

          File.chmod(0o755, parent)
        end
        File.binwrite(path, content)
        File.chmod(0o644, path)
        # Preserve executable scanner inputs, without inheriting unsafe mode bits.
        File.chmod(0o755, path) if name.start_with?('pre-commit/') && File.executable?(File.join(repo, name))
      end
      File.open(File.join(directory, 'Containerfile'), 'a') do |file|
        file.write("\n")
        file.write(File.binread(File.join(ROOT, 'container', 'prepare.Containerfile')))
      end
      arguments = [engine, 'build', '-f', File.join(directory, 'Containerfile'), '-t', tag,
                   '--build-arg', "BASE_IMAGE=#{BASE}", '--build-arg', "PRE_COMMIT_VERSION=#{VERSION}"]
      arguments << '--no-cache' if force
      raise Error, 'Pre-commit image build failed' unless system(*arguments, directory)
    end
    raise Error, 'Built image could not be found' unless image_present?(tag)

    @output.puts 'Build completed.'
    tag
  end

  def hook_types(repo)
    config = YAML.safe_load_file(File.join(repo, CONFIG), aliases: true)
    raise Error, "Invalid #{CONFIG}: expected a mapping" unless config.is_a?(Hash)

    explicit = config['default_install_hook_types']
    if explicit
      raise Error, 'default_install_hook_types must be a list' unless explicit.is_a?(Array)

      unsupported = explicit - HOOK_TYPES
      raise Error, "Unsupported hook types: #{unsupported.join(', ')}" unless unsupported.empty?

      return explicit.uniq
    end

    stages = Array(config['default_stages'])
    Array(config['repos']).each do |source|
      Array(source['hooks']).each { |hook| stages.concat(Array(hook['stages'])) }
    end
    ['pre-commit', *%w[commit-msg prepare-commit-msg].select { |type| stages.include?(type) }]
  rescue Psych::Exception => e
    raise Error, "Invalid #{CONFIG}: #{e.message}"
  end

  def hook_path(repo, type = 'pre-commit')
    path = git(repo, 'rev-parse', '--path-format=absolute', '--git-path', "hooks/#{type}")
    common = git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    # A shared external hooksPath cannot be uninstalled for just one repository.
    parent = Pathname(path).parent
    ancestor = parent
    ancestor = ancestor.parent until ancestor.exist?
    resolved = ancestor.realpath.join(parent.relative_path_from(ancestor)).to_s
    unless [repo, File.realpath(common)].any? { |root| resolved.start_with?("#{root}/") }
      raise Error, 'External/shared core.hooksPath is ambiguous; use a hooks directory inside this repository'
    end
    path
  end

  def managed?(path)
    File.file?(path) && !File.symlink?(path) && File.binread(path).start_with?(MARKER)
  end

  def wrapper(hook_type = 'pre-commit')
    addon = File.realpath(@env['EMPEIRA_ADDON_PATH'] || ROOT)
    # API 1's refs/<sha256(ref)> follows addon updates, unlike revisions/<commit>.
    snapshot = File.basename(File.dirname(addon)) == 'revisions' && File.basename(addon).match?(/\A[0-9a-f]{40,64}\z/)
    reference = if snapshot
                  ref = @env['EMPEIRA_ADDON_VERSION']
                  raise Error, 'Empeira addon ref is missing; cannot create an update-safe hook' unless ref

                  File.join(File.dirname(File.dirname(addon)), 'refs', Digest::SHA256.hexdigest(ref))
                end
    runtime = engine
    MARKER + <<~RUBY
      # SPDX-License-Identifier: AGPL-3.0-only
      require 'open3'
      begin
        reference = #{reference.inspect}
        if reference
          commit = File.read(reference).strip
          abort 'Error: Invalid Empeira addon reference; run empeira addons sync.' unless commit.match?(/\\A(?:[0-9a-f]{40}|[0-9a-f]{64})\\z/)
          entry = File.join(File.dirname(File.dirname(reference)), 'revisions', commit, 'bin', 'pre-commit')
        else
          entry = #{File.join(addon, 'bin', 'pre-commit').inspect}
        end
        abort 'Error: Addon entrypoint missing; sync the addon and reinstall hooks.' unless File.executable?(entry)
        repo, error, result = Open3.capture3('git', 'rev-parse', '--show-toplevel')
        abort "Error: Cannot identify Git repository: \#{error}" unless result.success?
        arguments = ['run', '--repo', repo.strip]
        environment = { 'EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE' => #{runtime.inspect} }
        if #{hook_type.inspect} != 'pre-commit'
          abort 'Error: Commit message filename missing.' unless ARGV.first

          arguments.concat(['--', '--hook-stage', #{hook_type.inspect}, '--commit-msg-filename',
                            File.expand_path(ARGV.first, repo.strip)])
        end
        if #{hook_type.inspect} == 'prepare-commit-msg'
          environment['PRE_COMMIT_COMMIT_MSG_SOURCE'] = ARGV[1]
          environment['PRE_COMMIT_COMMIT_OBJECT_NAME'] = ARGV[2]
        end
        exec(environment, entry, *arguments)
      rescue SystemCallError => e
        abort "Error: Cannot start pre-commit addon: \#{e.message}"
      end
    RUBY
  end

  def install(repo)
    configuration!(repo)
    paths = hook_types(repo).to_h { |type| [type, hook_path(repo, type)] }
    paths.each_value do |path|
      if (File.exist?(path) || File.symlink?(path)) && !managed?(path)
        raise Error, "Cannot overwrite an existing unmanaged Git hook: #{path}"
      end
    end

    prepare(repo)
    paths.each do |type, path|
      FileUtils.mkdir_p(File.dirname(path))
      if File.exist?(path) || File.symlink?(path)
        raise Error, "Cannot overwrite an existing unmanaged Git hook: #{path}" unless managed?(path)

        File.binwrite(path, wrapper(type))
      else
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o755) { |file| file.write(wrapper(type)) }
      end
      File.chmod(0o755, path)
      @output.puts "Installed #{path}"
    end
    (HOOK_TYPES - paths.keys).each do |type|
      path = hook_path(repo, type)
      File.unlink(path) if managed?(path)
    end
  end

  def uninstall(repo)
    removed = false
    HOOK_TYPES.each do |type|
      path = hook_path(repo, type)
      next unless managed?(path)

      File.unlink(path)
      @output.puts "Removed #{path}"
      removed = true
    end
    @output.puts 'No managed hooks; existing hooks left unchanged.' unless removed
  end

  def status(repo)
    hooks = HOOK_TYPES.map do |type|
      path = hook_path(repo, type)
      state = managed?(path) ? 'installed' : File.exist?(path) || File.symlink?(path) ? 'unmanaged' : 'absent'
      "#{type}: #{state}"
    end
    unless File.file?(File.join(repo, CONFIG))
      @output.puts "Hooks: #{hooks.join(', ')}; no #{CONFIG}"
      return
    end
    tag = image(repo)
    @output.puts "Hooks: #{hooks.join(', ')}; image: #{image_present?(tag) ? 'prepared' : 'missing'} (#{tag})"
  end

  def run_arguments(repo, arguments = [], all_files: false, tag: nil)
    tag ||= image(repo)
    mounts = [repo, git(repo, 'rev-parse', '--absolute-git-dir'),
              git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir')].map { |p| File.realpath(p) }.uniq
    mounts.reject! { |p| mounts.any? { |other| other != p && p.start_with?("#{other}/") } }
    raise Error, 'Mount paths must not contain commas or control characters' if mounts.any? { |p| p.match?(/[,\x00-\x1f]/) }

    argv = [engine, 'run', '--rm', '--init', '--pull=never', '--network=none', '--cap-drop=ALL',
            '--security-opt=no-new-privileges', '--user', "#{Process.uid}:#{Process.gid}"]
    argv << '--userns=keep-id' if engine == 'podman'
    mounts.each { |path| argv.concat(['--mount', "type=bind,src=#{path},dst=#{path}"]) }
    # Git hook context, including temporary indexes; never forward the full host environment.
    %w[GIT_INDEX_FILE GIT_PREFIX GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
       GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE SKIP PRE_COMMIT_ALLOW_NO_CONFIG
       PRE_COMMIT_COLOR FORCE_COLOR CLICOLOR_FORCE PRE_COMMIT_COMMIT_MSG_SOURCE
       PRE_COMMIT_COMMIT_OBJECT_NAME TERM].each do |key|
      argv.concat(['--env', "#{key}=#{@env[key]}"]) if @env.key?(key)
    end
    # The container has no PTY: retain pre-commit colors when the host has a terminal.
    if !@env.key?('PRE_COMMIT_COLOR') && @errors.respond_to?(:tty?) && @errors.tty?
      argv.concat(['--env', 'PRE_COMMIT_COLOR=always'])
    end
    index = @env['GIT_INDEX_FILE']
    if index && !mounts.any? { |p| File.expand_path(index, repo).start_with?("#{p}/") }
      raise Error, 'External GIT_INDEX_FILE is unsupported; keep the index inside the Git repository metadata'
    end
    argv.concat(['--workdir', repo, tag, 'run'])
    argv << '--all-files' if all_files
    argv.concat(arguments)
  end
end

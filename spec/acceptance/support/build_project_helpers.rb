module Simp::BeakerHelpers::SimpRakeHelpers::BuildProjectHelpers
  # Scaffolds _just_ enough of a super-release project to run `bundle exec rake
  #   -T` using this repository's source code as the simp-rake-helper source
  #
  # @param [Host, Array<Host>, String, Symbol] hosts Beaker host/hosts/role
  # @param [Hash{Symbol=>String}] opts Beaker options Hash for `#on` ({})
  #
  def scaffold_build_project(hosts, test_dir, opts = {})
    copy_host_files_into_build_user_homedir(hosts, opts)
    skeleton_dir = "#{build_user_host_files}/spec/acceptance/files/build/project_skeleton/"

    on(hosts, %(mkdir "#{test_dir}"; chown build_user:build_user "#{test_dir}"), opts)
    on(hosts, %(#{run_cmd} "cp -aT '#{skeleton_dir}' '#{test_dir}'"), opts)
    gemfile = <<-GEMFILE.gsub(%r{^ {6}}, '')
      gem_sources = ENV.fetch('GEM_SERVERS','https://rubygems.org').split(/[, ]+/)
      gem_sources.each { |gem_source| source gem_source }
      gem 'simp-rake-helpers', :path => '#{build_user_host_files}'
      gem 'simp-build-helpers', ENV.fetch('SIMP_BUILD_HELPERS_VERSION', '>= 0.1.0')
    GEMFILE
    create_remote_file(hosts, "#{test_dir}/Gemfile", gemfile, opts)
    on(hosts, "chown build_user:build_user #{test_dir}/Gemfile", opts)
    on(hosts, %(#{run_cmd} "cd '#{test_dir}'; rvm use default; bundle --local || bundle"), opts)
  end

  # Returns the distribution directory appropriate to an SUT
  #
  # @example The distribution directory format looks like:
  #
  #     `/home/build_user/simp-core/build/distributions/CentOS/6/x86_64
  #
  # @param [Host, String, Symbol] host Beaker host
  # @param [Hash{Symbol=>String}] opts Beaker options Hash for `#on` ({})
  # @return [String] Absolute path for the SUT's distribution directory
  #
  def distribution_dir(host, opts = {})
    @distribution_dirs ||= {}
    return @distribution_dirs[host.to_s] if @distribution_dirs.key?(host.to_s)
    result = on(host, %(#{run_cmd} "rvm use default; facter --json"), opts.merge(silent: true))
    facts = JSON.parse(result.stdout.lines[1..-1].join)
    os = facts['os']
    dir = "#{@test_dir}/build/distributions/#{os['name']}/" \
          "#{os['release']['major']}/#{facts['architecture']}"
    @distribution_dirs[host.to_s] = dir
  end

  # Scans a directory for the 'SIMP Development' GPG key and returns its Key ID
  #
  # @param [Host, String, Symbol] host Beaker host
  # @param [Hash{Symbol=>String}] opts Beaker options Hash for `#on` ({})
  # @return [String] GPG dev signing key ID
  #
  def dev_signing_key_id(host, opts = {})
    key_dir = distribution_dir(host, opts) + '/build_keys/dev'
    res = on(host, %(#{run_cmd} "gpg --list-keys --fingerprint --homedir='#{key_dir}' 'SIMP Development'"))
    lines = res.stdout.lines.select { |x| x =~ %r{Key fingerprint =} }
    raise "No 'SIMP Development' GPG keys found under ''" if lines.empty?
    lines.first.strip.split(%r{\s+})[-4..-1].join.downcase
  end
end

require 'puppet'
require 'puppet/util/inifile'

module Simp; end
module Simp::Build; end
module Simp::Build::Iso
  class TreeInfoReader
    def initialize(treeinfo_file, target_arch: 'x86_64')
      @target_arch = target_arch
      File.exist?( treeinfo_file ) or fail("File does not exist: '#{treeinfo_file}'")
      @file = treeinfo_file
      @ini = Puppet::Util::IniConfig::PhysicalFile.new(@file)
      @ini.read
      @treeinfo_version = nil
      parse
    end

    def treeinfo_maj_version
      fail('ERROR: @treeinfo_version is not set') unless @treeinfo_version
      @treeinfo_version.split('.').first.to_i
    end

    # release version, for example: "21", "7.0", "2.1"
    def release_version
      treeinfo_maj_version > 0 ? section('release')['version'] : section('general')['version']
    end

    def release_short_name
      treeinfo_maj_version > 0 ? section('release')['short'] : section('general')['family']
    end

    def tree_arch
      treeinfo_maj_version > 0 ? section('tree')['arch'] : section('general')['arch']
    end

    def parse
      # - [x] TODO header + version check
      # - [ ] TODO only use general section for EL7 (not needed... yet?)
      # - [ ] TODO set baseosver and arch for EL8

      if h = section('header') # productmd .treeinfo format (EL8+)
        @treeinfo_version = h['version']
        unless treeinfo_maj_version == 1
          fail "ERROR: Unsupported productmd .treeinfo version: '#{@treeinfo_version}': '#{@file}'"
        end
        warn "Detected productmd .treeinfo, version '#{@treeinfo_version}'" if @verbose
      else # pre-productmd .treeinfo format (EL7)
        unless @ini.get_section('general')
          fail "ERROR: Cannot parse: Not a pre-prouct .treeinfo format: '#{@file}' !"
        end
        @treeinfo_version = '0.pre-productmd'
        warn 'Detected pre-productmd .treeinfo format (<= EL7)' if @verbose
      end
      ###require 'yaml'
      ###warn general.to_yaml
      ###warn variants.to_yaml if treeinfo_maj_version > 0
    end

    def sections
      @ini.sections.map{|s| [s.name, section(s.name)] }.to_h
    end

    # @param [String] name of ini section to read
    # @return [Hash] k/v pairs from ini [section] if it exists
    # @return [nil] if ini [section] doesn't exist
    def section(name)
      s = @ini.get_section(name) || return
      s.entries.grep(Array).to_h
    end

    # The [general] section is in pre-productmd .treeinfo files
    #
    # NOTE: According to RHEL7 discs, the [general] section is deprecated
    #
    # NOTE: According to CentOS8 discs, the [general] section is only provided
    #       for 'compatibility with pre-productmd treeinfos'
    #
    def general
      unless section('general')
        fail("ERROR: No [general] section found in file '#{@ini.filetype.path}'")
      end
      h = section('general')
      arch = h['arch'].to_s.strip
      orig_baseosver = (h['version'] || baseosver).to_s.strip
      baseosver = orig_baseosver
      baseosver += '.0' if (baseosver.count('.') < 1)
      h
    end

    def variants
      variant_uids = section('tree')['variants'].to_s.split(',')
      variant_uids.map { |uid| section("variant-#{uid}") }
    end

  end
end


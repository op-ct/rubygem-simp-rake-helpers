#!/usr/bin/rake -T

require 'simp/rake'
require 'json'
require 'colorize'
include Simp::Rake

class SIMPBuildException < Exception
end

require 'simp/build/release_mapper'
module Simp; end
module Simp::Rake; end
module Simp::Rake::Build
  class Auto < ::Rake::TaskLib
    def initialize( run_dir )
      @base_dir = run_dir
      define
    end

    def puts_header( msg )
      puts msg.colorize( :green )
    end
    def puts_hint( msg )
      puts msg.colorize( :blue )
    end

    # define rake tasks
    def define
      namespace :build do
        desc <<-EOM
        Automatically detect and build a SIMP ISO for a target SIMP release.

        This task runs all other build tasks

        Arguments:
          * :release     => SIMP release to build (e.g., '5.1.X')
          - :iso_paths   => path to source ISO(s) (colon-delimited list of files/directories) [Default: '.']
          - :tarball     => SIMP build tarball file; if given, skips tar build.  [Default: 'false']
          - :output_dir  => path to write SIMP ISO.   [Default: './SIMP_ISO']
          - :do_checksum => Use sha256sum checksum to compare each ISO.  [Default: 'false']
          - :key_name    => Key name to sign packages [Default: 'dev']
          - :packer_vars => Write a packer vars.json to go with this ISO [Default: 'true']
          - :verbose     => Enable verbose reporting. [Default: 'false']

        ENV vars:
          - SIMP_BUILD_staging_dir    => Path to stage big build assets [Default: './SIMP_ISO_STAGING']
          - SIMP_BUILD_rm_staging_dir => 'yes' forcibly removes the staging dir before starting
          - SIMP_BUILD_force_dirty    => 'yes' tries to checks out subrepos even if dirty
          - SIMP_BUILD_docs           => 'yes' builds & includes documentation
          - SIMP_BUILD_checkout       => 'no' will skip the git repo checkouts
          - SIMP_BUILD_bundle         => 'no' skips running bundle in each subrepo
          - SIMP_BUILD_unpack         => 'no' skips the unpack section
          - SIMP_BUILD_unpack_merge   => 'no' prevents auto-merging the unpacked DVD
          - SIMP_BUILD_prune          => 'no' passes :prune=>false to iso:build
          - SIMP_BUILD_iso_name       => Renames the output ISO filename [Default: false]
          - SIMP_BUILD_iso_tag        => Appended to the output ISO's filename [Default: false]

        Notes:
          - To skip `tar:build` (including `pkg:build`), use the `tarball` argument
        EOM

        task :auto,  [:release,
                      :iso_paths,
                      :tarball,
                      :output_dir,
                      :do_checksum,
                      :key_name,
                      :packer_vars,
                      :verbose] do |t, args|
          # set up data
          # --------------------------------------------------------------------------

          args.with_defaults(
            :iso_paths   => Dir.pwd,
            :tarball     => 'false',
            :output_dir  => '',
            :do_checksum => 'false',
            :key_name    => 'dev',
            :packer_vars => 'true',
            :verbose     => 'false',
          )

          # locals
          target_release   = args[:release]
          iso_paths        = File.expand_path(args[:iso_paths])
          tarball          = (args.tarball =~ /^(false|)$/ ? false : args.tarball)
          output_dir       = args[:output_dir].sub(/^$/, File.expand_path( 'SIMP_ISO', Dir.pwd ))
          do_checksum      = (args.do_checksum =~ /^$/ ? 'false' : args.do_checksum)
          key_name         = args[:key_name]
          staging_dir      = ENV.fetch('SIMP_BUILD_staging_dir',
                                        File.expand_path( 'SIMP_ISO_STAGING', Dir.pwd ))
          do_packer_vars   = (args.packer_vars == 'false' ? false : true)
          verbose          = (args.verbose == 'false' ? false : true)

          yaml_file        = File.expand_path('build/release_mappings.yaml', @base_dir)
          pwd              = Dir.pwd
          repo_root_dir    = File.expand_path( @base_dir )
          method           = ENV.fetch('SIMP_BUILD_puppetfile','tracking')
          do_rm_staging    = ENV['SIMP_BUILD_rm_staging_dir'] == 'yes'
          do_docs          = ENV['SIMP_BUILD_docs'] == 'yes' ? 'true' : 'false'
          do_merge         = ENV['SIMP_BUILD_unpack_merge'] != 'no'
          do_prune         = ENV['SIMP_BUILD_prune'] != 'no' ? 'true' : 'false'
          do_checkout      = ENV['SIMP_BUILD_checkout'] != 'no'
          do_bundle        = ENV['SIMP_BUILD_bundle'] != 'no'
          do_unpack        = ENV['SIMP_BUILD_unpack'] != 'no'
          full_iso_name    = ENV.fetch('SIMP_BUILD_iso_name', false)
          iso_name_tag     = ENV.fetch('SIMP_BUILD_iso_tag', false)
          @dirty_repos     = nil
          @simp_output_iso = nil


          # Build environment sanity checks
          # --------------------
          if do_rm_staging && !do_unpack
            fail SIMPBuildException, "ERROR: Mixing `SIMP_BUILD_rm_staging_dir=yes` and `SIMP_BUILD_unpack=no` is silly."
          end

          if File.exists?(output_dir) && !File.directory?(output_dir)
            fail SIMPBuildException, "ERROR: ISO output dir exists but is not a directory:\n\n" +
                                     "    '#{output_dir}'\n\n"
          end


          # Look up ISOs against known build assets
          # --------------------
          target_data = get_target_data(target_release, iso_paths, yaml_file, do_checksum, verbose )

          # IDEA: check for prequisite build tools

          # check out subrepos
          # --------------------
          if do_checkout && !tarball
            puts_header
            puts_header '='*80
            puts_header "## Checking out subrepositories"
            puts_header
            puts_header "     (skip with `SIMP_BUILD_checkout=no`)"
            puts_header '='*80
            Dir.chdir repo_root_dir
            Rake::Task['deps:status'].invoke
            if @dirty_repos && !ENV['SIMP_BUILD_force_dirty'] == 'yes'
              raise SIMPBuildException, "ERROR: Dirty repos detected!  I refuse to destroy uncommitted work."
            else
              puts_header
              puts_header '-'*80
              puts_header "#### Checking out subrepositories using method '#{method}'"
              puts_header '-'*80
              Rake::Task['deps:checkout'].invoke(method)
            end

            if do_bundle
              puts_header
              puts_header '-'*80
              puts_header "#### Running bundler in all repos"
              puts_header '     (Disable with `SIMP_BUILD_bundle=no`)'
              puts_header '-'*80
              Rake::Task['build:bundle'].invoke
            else
              puts_header
              puts_header '-'*80
              puts_header "#### SKIPPED: bundler in all repos"
              puts_header '     (Force with `SIMP_BUILD_bundle=yes`)'
              puts_header '-'*80
            end
          else
            puts_header
            puts_header '='*80
            puts_header "#### skipping sub repository checkout (because `SIMP_BUILD_checkout=no`)"
            puts_header
          end

          # build tarball
          # --------------------
          if tarball
            puts_header
            puts_header '-'*80
            puts_header "#### Using pre-existing tarball:"
            puts_header "           '#{tarball}'"
            puts_header
            puts_header '-'*80

          else
            puts_header
            puts_header '='*80
            puts_header "#### Running tar:build in all repos"
            puts_header '='*80
            $simp_tarballs = {}
            Rake::Task['tar:build'].invoke(target_data['mock'],key_name,do_docs)
            tarball = $simp_tarballs.fetch(target_data['flavor'])
          end

          # yum sync
          # --------------------
          puts_header
          puts_header '-'*80
          puts_header "#### rake build:yum:sync[#{target_data['flavor']},#{target_data['os_version']}]"
          puts_header '-'*80
          Rake::Task['build:yum:sync'].invoke(target_data['flavor'],target_data['os_version'])

          # If you have previously downloaded packages from yum, you may need to run
          # $ rake build:yum:clean_cache

          # Optionally, you may drop in custom packages you wish to have available during an install into build/yum_data/SIMP<simp_version>_<CentOS or RHEL><os_version>_<architecture>/packages
          # TODO: ENV var for optional packages

          prepare_staging_dir( staging_dir, do_rm_staging, repo_root_dir, verbose )
          Dir.chdir staging_dir

          #
          # --------------------
          if do_unpack
            puts_header
            puts_header '='*80
            puts_header "#### unpack ISOs into staging directory"
            puts_header "     staging area: '#{staging_dir}'"
            puts_header
            puts_header "     (skip with `SIMP_BUILD_unpack=no`)"
            puts_header '='*80
            puts_header

            Dir.glob( File.join(staging_dir, "#{target_data['flavor']}*/") ).each do |f|
              FileUtils.rm_f( f , :verbose => verbose )
            end

            target_data['isos'].each do |iso|
              puts_header "---- rake unpack[#{iso},#{do_merge},#{Dir.pwd},isoinfo,#{target_data['os_version']}]"
              Rake::Task['unpack'].reenable
              Rake::Task['unpack'].invoke(iso,do_merge,Dir.pwd,'isoinfo',target_data['os_version'])
            end
          else
            puts_header
            puts_header '='*80
            puts_header "#### skipping ISOs unpack (because `SIMP_BUILD_unpack=no`)"
            puts_header
          end

          Dir.chdir repo_root_dir

          puts_header
          puts_header '='*80
          puts_header "#### iso:build[#{tarball}]"
          puts_header '='*80
          puts_header

          Rake::Task['iso:build'].invoke(tarball,staging_dir,do_prune)


          _isos = Dir[ File.join(Dir.pwd,'SIMP-*.iso') ]
          if _isos.size == 0
            fail "ERROR: No SIMP ISOs found in '#{Dir.pwd}'"
          elsif _isos.size > 1
            warn "WARNING: More than one SIMP ISO found in '#{Dir.pwd}'"
            _isos.each{ |i| warn i }
          end

          # NOTE: It is possible at this point (given the right
          # `SIMP_BUILD_xxx=no` flags) that iso:build will not have set
          # `@simp_output_iso`.  In that case, look at the ISOs in the staging
          # dir (there should only be one) and take our best guess.
          if @simp_output_iso.nil?
             @simp_output_iso = File.basename(_isos.first)
          end

          output_file = full_iso_name ? full_iso_name : @simp_output_iso
          if iso_name_tag
            output_file = output_file.sub(/\.iso$/i, "__#{iso_name_tag}.iso")
          end

          puts_header
          puts_header '='*80
          puts_header "#### Moving '#{@simp_output_iso}' into:"
          puts_header "       '#{output_dir}/#{output_file}'"
          puts_header '='*80
          puts_header

          iso = File.join(output_dir,output_file)
          FileUtils.mkdir_p File.dirname(iso), :verbose => verbose
          FileUtils.mv(@simp_output_iso, iso, :verbose => verbose)

          # write vars.json for packer build
          # --------------------------------------
          vars_file = iso.sub(/.iso$/, '.json')
          puts_header
          puts_header '='*80
          puts_header "#### Checksumming #{iso}..."
          puts_header '='*80
          puts_header

          sum = `sha256sum "#{iso}"`.split(/ +/).first

          puts_header
          puts_header '='*80
          puts_header "#### Writing packer data to:"
          puts_header "       '#{vars_file.colorize(:yellow)}'"
          puts_header '='*80
          puts_header
          box_distro_release = "SIMP-#{target_release}-#{File.basename(target_data['isos'].first).sub(/\.iso$/,'').sub(/-x86_64/,'')}"
          packer_vars = {
            'box_simp_release'   => target_release,
            'box_distro_release' => box_distro_release,
            'iso_url'            => iso,
            'iso_checksum'       => sum,
            'iso_checksum_type'  => 'sha256',
            'new_password'       => 'suP3rP@ssw0r!suP3rP@ssw0r!suP3rP@ssw0r!',
            'output_directory'   => './OUTPUT',
          }
          File.open(vars_file, 'w'){|f| f.puts_header packer_vars.to_json }

          puts_header
          puts_header '='*80
          puts_header "#### FINIS!"
          puts_header '='*80
          puts_header
        end

      end

      def get_target_data(target_release, iso_paths, yaml_file, do_checksum, verbose )
        puts_header '='*80
        puts_header "## validating ISOs for target:"
        puts_header "      '#{target_release}' in '#{iso_paths}'"
        puts_header '='*80
        puts_header

        mapper          = Simp::Build::ReleaseMapper.new(target_release, yaml_file, do_checksum == 'true')
        mapper.verbose  = true || verbose
        target_data     = mapper.autoscan_unpack_list( iso_paths )

        puts_header '-'*80
        puts_hint "## target data:"
        puts_hint ''
        puts_hint "     target release: '#{target_release}'"
        puts_hint "     target flavor:  '#{target_data['flavor']}'"
        puts_hint "     source isos:"
        target_data['isos'].each do |iso|
          puts_header "        - #{iso}"
        end
        puts_header '-'*80
        puts_header
        sleep 3

        target_data
      end


      def prepare_staging_dir( staging_dir, do_rm_staging, repo_root_dir, verbose )
        if ['','/',Dir.home,repo_root_dir].include? staging_dir
          fail SIMPBuildException,
               "ERROR: staging directoy path is too stupid to be believed:\n"+
               "         '#{staging_dir}'\n\n" +
               "       Use SIMP_BUILD_staging_dir='path/to/staging/dir'\n\n"
        end
        if do_rm_staging
          puts_header
          puts_header '-'*80
          puts_header '#### Ensuring previous staging directory is removed:'
          puts_header "       '#{staging_dir}'"
          puts_header
          puts_hint   '     (disable this with `SIMP_BUILD_rm_staging_dir=no`)'
          puts_header '-'*80

          FileUtils.rm_rf staging_dir, :verbose => verbose
        elsif File.exists? staging_dir
          warn ''
          warn '!'*80
          warn '#### WARNING: staging dir already exists at:'
          warn "              '#{staging_dir}'"
          warn ''
          warn '              - Previously staged assets in this directory may cause problems.'
          warn '              - Use `SIMP_BUILD_rm_staging_dir=yes` to remove it automatically.'
          warn ''
          warn '!'*80
          warn ''
          sleep 10
        end
        FileUtils.mkdir_p staging_dir, :verbose => verbose
      end
    end
  end
end


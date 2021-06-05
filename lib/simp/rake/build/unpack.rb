require 'ruby-progressbar'
require 'simp/rake/build/constants'

module Simp; end
module Simp::Rake; end
module Simp::Rake::Build

  class Unpack < ::Rake::TaskLib
    include Simp::Rake::Build::Constants

    def initialize( base_dir )
      init_member_vars( base_dir )

      define_tasks
    end

    def verbose
      (
        ENV.fetch('SIMP_UNPACK_verbose','no') == 'yes' ||
        ENV.fetch('SIMP_STAGE_verbose','no') == 'yes'
      )
    end


    def define_tasks
      def valid_iso?(iso_path)
        %x{file --keep-going '#{iso_path}'}.split(":")[1..-1].to_s =~ /ISO/ ? true : false
      end

      # Determine name for unpack directory from ISO filename
      #
      #   e.g., 'CentOS-8.3.2011-x86_64-dvd1.iso' -> 'CentOS8.3.2011-x86_64'
      #
      def dirname_from_iso_name(iso_path, version:)
        pieces = File.basename(iso_path,'.iso').split('-')

        # Mappings of ISO name to target directory name.
        # This is a hash of hashes to provide room for growth.
        dvd_map = {
          # RHEL structure as provided from RHN:
          #   rhel-server-<version>-<arch>-<whatever>
          'rhel' => {
            'baseos'  => 'RedHat',
            'version' => version || pieces[2],
            'arch'    => pieces[3]
          },
          # CentOS structure as provided from the CentOS website:
          #   CentOS-<version>-<arch>-<whatever>
          'CentOS' => {
            'baseos'  => 'CentOS',
            'version' => version || pieces[1],
            'arch'    => pieces[2]
          }
        }
        # Determine the target directory
        map = dvd_map[pieces[0]]
        map.nil? and fail "Error: Could not find a mapping for '#{iso_path}'."
        "#{map['baseos']}#{map['version']}-#{map['arch']}"
      end

      # Determine target directory/name
      def unpack_target_path(iso_path, version, targetdir)
        unpack_dir_name = dirname_from_iso_name(iso_path, version: version)
        File.expand_path(unpack_dir_name, targetdir)
      end

      # Removes repos and packages from Array of ISO files, based on .treeinfo
      #
      # - [x] Supports productmd
      # - [ ] Supports legacy? (legacy doesn't need to define variants)
      #
      def delete_repos_from_iso_toc(iso_toc, iso_path, iso_info)
        require 'tempfile'
        require 'simp/build/iso/tree_info_reader'
        unless iso_toc.grep('/.treeinfo').empty?
          treeinfo_content = %x{#{iso_info} -R -x /.treeinfo -i #{iso_path}}
          treeinfo = Tempfile.create('simp_rake_build_unpack_ini_file') do |ini_file|
            ini_file.write(treeinfo_content)
            ini_file.flush
            Simp::Build::Iso::TreeInfoReader.new(ini_file.path)
          end
          treeinfo.variants.each do |v|
            warn "Filtering out packages from variant #{v['packages']}"
            iso_toc.reject!{|i| i =~ %r[^/(#{v['packages']}|#{v['repository']})] }
            iso_toc.reject!{|i| i =~ %r[^/#{v['repository']}] }
          end
        end
        iso_toc
      end

      def validate_unpacked_baseos_dvd_dir(unpacked_dvd_dir)
        unless File.directory?(unpacked_dvd_dir)
          fail("Error: No directory found at #{unpacked_dvd_dir}'")
        end

        treeinfo_path = File.join(unpacked_dvd_dir,'.treeinfo')
        unless File.file? treeinfo_path
          fail("Error: No .treeinfo found under '#{unpacked_dvd_dir}'.  (Does it really contain an unpacked ISO?)")
        end
        Simp::Build::Iso::TreeInfoReader.new(treeinfo_path) # raises error if invalid format
        true
      end


      namespace :iso do

        def repo_directory?(dir)
          repomd_file = File.join(dir, 'repodata', 'repomd.xml')
          File.exist?(repomd_file)
        end

        namespace :stage do
          # --------------------------------------------------------------------------------
          desc <<~DESC
            Unpack a tarball into an an unpacked DVD staging directory, create RPM repos

              * :tarball - Path to tarball to unpack
              * :unpacked_dvd_dir - Path to directory of unpacked base OS DVD

            RPM repos will be created in any extracted top-level directory that:

              1. Contains any `*.rpm` files at any level
              2. Does not already have an RPM repository (under the top-lvel directory)


          DESC
          # --------------------------------------------------------------------------------
          task :tarball, [:tarball,:unpacked_dvd_dir] do |t,args|
            tarball = File.expand_path(args.tarball)
            unpacked_dvd_dir = File.expand_path(args.unpacked_dvd_dir)
            validate_unpacked_baseos_dvd_dir(unpacked_dvd_dir)

            # Identify top-level directories the tarball provides
            cmd = "tar --exclude='./*/*' -tf #{tarball} | grep /$"
            toplevel_tar_dirnames = %x{#{cmd}}.split("\n").map{|x| x.gsub(%r[(\A./|/\Z)],'')}
            staged_toplevel_tar_dirs = toplevel_tar_dirnames.map{|x| File.join(unpacked_dvd_dir,x) }

            # Remove each of those dirs from the staged ISO dir before unpacking
            staged_toplevel_tar_dirs.each do |clean_dir|
              if File.directory?(clean_dir)
                puts "-- Removing staged top-level dir '#{clean_dir}' before unpacking..."
                FileUtils.rm_rf(clean_dir, :verbose => verbose)
              elsif File.file?(clean_dir)
                fail("Error: #{clean_dir} is a file, expecting directory!")
              end
            end

            # Unpack the tarball!
            v = verbose ? 'v' : ''
            puts '','== Unpacking tarball...'
            sh "tar --no-same-permissions -C '#{unpacked_dvd_dir}' -z#{v}xf '#{tarball}'"
            puts '== Finished unpacking tarball'


            # Identify top-level directory trees containing RPMs
            require 'find'
            rpm_dirs = staged_toplevel_tar_dirs.select do |dir|
              Find.find(dir) do |path|
                break(true) if path =~ /.*\.rpm$/
                false
              end
            end

            # Create RPM repository for those directory trees, if necessary
            rpm_dirs.each do |dir|
              puts "\n== Creating repository in RPM directory: '#{File.basename(dir)}'"
              if repo_directory?(dir)
                puts '', "-- SKIPPING createrepo! Repo directory exists in '#{dir}'; not messing with it", ''
                next
              end
              Dir.chdir(dir) do
                puts "  (Full path: '#{dir}')"
                # Future improvements:
                #
                #  - TODO use `createrepo_c` when available and target >EL7
                #  - TODO use group or moulemd metadata if present
                #
                sh 'createrepo -p .'
              end
            end
          end

          # --------------------------------------------------------------------------------
          desc <<~DESC
            Copy local Yum/DNF repositories into the ISO staging directory

              * :repos_bash_dir - Path to directory containing local repositories
              * :unpacked_dvd_dir - Path to directory of unpacked/staged base OS ISO
              * :method - Whether to 'copy', 'move', or 'hardlink' the local repos into the
                          unpacked ISO staging directory (Default: 'copy')

          DESC
          # --------------------------------------------------------------------------------
          task :local_repos, [:repos_base_dir,:unpacked_dvd_dir,:method] do |t,args|
            args.with_defaults({
              :method   => 'copy',
            })
            arg_methods = %w[copy move hardlink]
            unless arg_methods.include? args[:method]
              fail ArgumentError, ":method must be one of: #{methods.join(', ')} (got '#{args.method}')"
            end
            copy_method = args[:method]
            repos_base_dir = File.expand_path(args.repos_base_dir)
            unpacked_dvd_dir = File.expand_path(args.unpacked_dvd_dir)
            validate_unpacked_baseos_dvd_dir(unpacked_dvd_dir)


            puts "\n== Staging local repos from #{unpacked_dvd_dir}..."

            # Only copy actual repositories
            dirs = Dir[File.join(repos_base_dir,'*')].select{|f| File.directory?(f) }
            rejected_dirs = []
            repo_dirs = dirs.select do |dir|
                repo = repo_directory?(dir) ? dir : nil
              unless repo
                warn "   -- REJECTING dir '#{File.basename(dir)}' - not a repository : '#{dir}'"
                rejected_dirs << dir
              end
              repo
            end

            repo_dirs.each do |dir|
              case copy_method
              when 'copy'
                puts "-- Copying repo dir '#{File.basename(dir)}' into '#{unpacked_dvd_dir}'"
                FileUtils.cp_r(dir, unpacked_dvd_dir, verbose: verbose )
              when 'move'
                puts "-- Moving repo dir '#{File.basename(dir)}' into '#{unpacked_dvd_dir}'"
                FileUtils.mv(dir, unpacked_dvd_dir, verbose: verbose )
              when 'hardlink'
                puts "-- Hardlinking repo dir '#{File.basename(dir)}' into '#{unpacked_dvd_dir}'"
                FileUtils.ln(dir, unpacked_dvd_dir, verbose: verbose )
              else
                fail('no copy :method defined')
              end
            end
            puts "-- Done staging local repos\n"
          end
        end
      end


      desc <<~DESC
        Unpack an ISO. Unpacks either a RHEL or CentOS ISO into
        <targetdir>/<RHEL|CentOS><version>-<arch>.

           * :iso_path - Full path to the ISO image to unpack.
           * :merge - If true, then automatically merge any existing
             directories. Defaults to prompting.
           * :targetdir - The parent directory for the to-be-created directory
             containing the unpacked ISO. Defaults to the current directory.
           * :isoinfo - The isoinfo executable to use to extract stuff from the ISO.
             Defaults to 'isoinfo'.
           * :version - optional override for the <version> number (e.g., '7.0' instead of '7')

      DESC
      task :unpack,[:iso_path, :merge, :targetdir, :isoinfo, :version, :unpack_repos] do |t,args|
        args.with_defaults(
          :iso_path   => '',
          :isoinfo    => 'isoinfo',
          :targetdir  => Dir.pwd,
          :merge      => false,
          :version => false,
          :unpack_repos => false,
        )

        iso_path     = args.iso_path
        iso_info     = which(args.isoinfo)
        targetdir    = args.targetdir
        merge        = args.merge
        version      = args.version
        unpack_repos = args.unpack_repos

        # Validate arguments
        File.exist?(iso_path) or
          fail "Error: You must provide the full path and filename of the ISO image."

        valid_iso?(iso_path) or fail "Error: The file provided is not a valid ISO."
        out_dir = unpack_target_path(iso_path, version, targetdir)

        # Attempt a merge
        # NOTE: merging modulary repos would destroy the modular metadata
        if File.exist?(out_dir) and merge.to_s.strip == 'false'
          puts "Directory '#{out_dir}' already exists! Would you like to merge? [Yn]?"
          unless $stdin.gets.strip.match(/^(y.*|$)/i)
            puts "Skipping #{iso_path}"
            next
          end
        end

        puts "Target dir: #{out_dir}"
        mkdir_p(out_dir)

        # Build list of files to unpack
        iso_toc = %x{#{iso_info} -Rf -i #{iso_path}}.split("\n")
        iso_toc.each { |iso_entry| iso_toc.delete(File.dirname(iso_entry)) }
        delete_repos_from_iso_toc(iso_toc, iso_path, iso_info) unless unpack_repos

        # Unpack the ISO
        progress = ProgressBar.create(:title => 'Unpacking', :total => iso_toc.size)

        iso_toc.each do |iso_entry|
          target = "#{out_dir}#{iso_entry}"
          unless File.exist?(target)
            FileUtils.mkdir_p(File.dirname(target))
            system("#{iso_info} -R -x #{iso_entry} -i #{iso_path} > #{target}")
          end
          if progress
            progress.increment
          else
            print "#"
          end
        end
      end

    end
  end
end

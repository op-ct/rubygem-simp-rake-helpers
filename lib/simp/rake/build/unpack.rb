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


    def define_tasks

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

      desc "Unpack an ISO. Unpacks either a RHEL or CentOS ISO into
      <targetdir>/<RHEL|CentOS><version>-<arch>.
       * :iso_path - Full path to the ISO image to unpack.
       * :merge - If true, then automatically merge any existing
         directories. Defaults to prompting.
       * :targetdir - The parent directory for the to-be-created directory
         containing the unpacked ISO. Defaults to the current directory.
       * :isoinfo - The isoinfo executable to use to extract stuff from the ISO.
         Defaults to 'isoinfo'.
       * :version - optional override for the <version> number (e.g., '7.0' instead of '7')

      "
      task :unpack,[:iso_path, :merge, :targetdir, :isoinfo, :version, :unpack_repos] do |t,args|
        args.with_defaults(
          :iso_path   => '',
          :isoinfo    => 'isoinfo',
          :targetdir  => Dir.pwd,
          :merge      => false,
          :version => false,
          :unpack_repos => false,
        )

        iso_path   = args.iso_path
        iso_info   = which(args.isoinfo)
        targetdir  = args.targetdir
        merge      = args.merge
        version = args.version

        # Checking for valid arguments
        File.exist?(args.iso_path) or
          fail "Error: You must provide the full path and filename of the ISO image."

        %x{file --keep-going '#{iso_path}'}.split(":")[1..-1].to_s =~ /ISO/ or
          fail "Error: The file provided is not a valid ISO."

        # Determine target directory/name
        unpack_dir_name = dirname_from_iso_name(iso_path,version: version)
        out_dir = "#{File.expand_path(unpack_dir_name,  targetdir)}"

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

        # Unpack the ISO
        iso_toc = %x{#{iso_info} -Rf -i #{iso_path}}.split("\n")
        unless args.unpack_repos
          unless iso_toc.grep('/.treeinfo').empty?
            treeinfo_content = %x{#{iso_info} -R -x /.treeinfo -i #{iso_path}}
            require 'tempfile'
            treeinfo = Tempfile.create('simp_rake_build_unpack_ini_file') do |ini_file|
              require 'simp/build/iso/tree_info_reader'
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
        end

          require 'pry'; binding.pry
        iso_toc.each do |iso_entry|
          iso_toc.delete(File.dirname(iso_entry))
        end

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

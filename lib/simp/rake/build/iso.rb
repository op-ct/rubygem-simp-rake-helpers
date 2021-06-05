require 'simp/rake'
require 'simp/rake/build/constants'
require 'simp/build/iso/tree_info_reader'

module Simp; end
module Simp::Rake; end

module Simp::Rake::Build

  class Iso < ::Rake::TaskLib
    include Simp::Rake
    include Simp::Rake::Build::Constants

    def initialize( base_dir )
      init_member_vars( base_dir )

      define_tasks
    end

    def verbose
      ENV.fetch('SIMP_ISO_verbose','no') == 'yes'
    end

    def define_tasks

      File.umask(0007)

      namespace :iso do
        task :prep do
          if $simp6
            @build_dir = $simp6_build_dir || @distro_build_dir
          end
        end

        desc <<~EOM
          Build the SIMP ISO(s).
           * :tarball - Path of the source SIMP tarball
           * :unpacked_dvd_dir - Path to the unpacked base OS ISO

          ENV vars:
            - Set `SIMP_ISO_verbose=yes` to report file operations as they happen.
        EOM
        task :build2,[:tarball, :unpacked_dvd_dir] => [:prep] do |t,args|
          # TODO move unpacking the tarball into a separate task, like build:unpack:tar
          if args.nil?
            fail("Error: You must specify a source  or tarball directory!")
          end

          tarball = File.expand_path(args.tarball)
          unpacked_dvd_dir = File.expand_path(args.unpacked_dvd_dir)

          unless File.exist?(tarball)
            fail("Error: Could not find tarball file at '#{tarball}'!")
          end

          unless File.directory? unpacked_dvd_dir
            fail("Error: No directory found at #{unpacked_dvd_dir}'")
          end

          treeinfo_path = File.join(unpacked_dvd_dir,'.treeinfo')
          unless File.file? treeinfo_path
            fail("Error: No .treeinfo found under '#{unpacked_dvd_dir}'.  (Does it really contain an unpacked ISO?)")
          end

          vermap = YAML::load_file( File.join( __dir__, 'vermap.yaml'))
          namepieces = File.basename(tarball,".tar.gz").split('-')

          # SIMP 6
          if namepieces[1] !~ /^\d/
            simpver = namepieces[3..-1].join('-')
            baseos  = namepieces[2]
          else
            # Older, maybe unused?
            simpver = namepieces[1..2].join('-')
            baseos  = namepieces[3]
          end

          treeinfo = Simp::Build::Iso::TreeInfoReader.new(treeinfo_path)
          rel_name = treeinfo.release_short_name || '???'
          arch = treeinfo.tree_arch || '???'
          baseosver = treeinfo.release_version || '???'
          baseosver += '.0' if (baseosver.count('.') < 1)

          # Skip if SIMP version doesn't match target base OS version
          # TODO  Without a multi tarball/ISO matrix, do we even need the
          #       version mapping check any more?
          #       (embedding the vermap.yaml in simp-rake-helpers is heinous)
          unless Array(vermap[simpver.split('.').first]).include?(baseosver.split('.').first)
            fail("Could not find SIMP version mapping for #{simpver} for Base OS #{baseosver}")
          end

          # NOTE no pruning any more; just mirror in repos that have already been pruned
          # NOTE tarball extraction moved to iso:unpack:tarball
          # NOTE no symlinking noarch into x86_64 anymore (weird separation compared to EL)


          # - identify all staged RPM repos
          # - FIXME Update productmd .treeinfo with correct tree + variants for all RPM repos

          # Make sure we have all of the necessary RPMs!
          # FIXME include all repos in the repoclosure
          #Rake::Task['pkg:repoclosure'].invoke(File.expand_path(unpacked_dvd_dir))

          require 'find'
          repo_dirs = []
          Find.find(unpacked_dvd_dir) do |path|
            next(false) unless File.basename(path) == 'repodata'
            if File.file?(File.join(path,'repomd.xml'))
              repo_dirs << File.dirname(path)
            end
          end
      require 'pry'; binding.pry



          # Do some sane chmod'ing and build ISO
          system("chmod -fR u+rwX,g+rX,o=g #{unpacked_dvd_dir}")
          simp_output_name = "SIMP-#{simpver}-#{baseos}-#{baseosver}-#{arch}"
          @simp_output_iso = "#{simp_output_name}.iso"

          mkisofs_cmd = [
            'mkisofs',
            "-A SIMP-#{simpver}",
            "-V SIMP-#{simpver}",
            "-volset SIMP-#{simpver}",
            '-uid 0',
            '-gid 0',
            '-J',
            '-joliet-long',
            '-r',
            '-v',
            '-T',
            '-b isolinux/isolinux.bin',
            '-c boot.cat',
            '-boot-load-size 4',
            '-boot-info-table',
            '-no-emul-boot',
            '-eltorito-alt-boot',
            '-e images/efiboot.img',
            # This is apparently needed twice to get the lines above it to
            # take. Not sure why.
            '-no-emul-boot',
            '-m TRANS.TBL',
            '-x ./lost+found',
            "-o #{@simp_output_iso}",
            unpacked_dvd_dir
          ]

          system(mkisofs_cmd.join(' '))

          # If we got here and didn't generate any ISOs, something went horribly wrong
          fail('Error: No ISO was built!') unless @simp_output_iso
        end

=begin
        desc <<-EOM
        Build the source ISO.
          Note: The process clobbers the temporary and built files, rebuilds the
          (s) and packages the source ISO. Therefore it will take a
          while.
            * :key - The GPG key to sign the RPMs with. Defaults to 'prod'.
        EOM
=end
        task :src,[:prep, :key] do |t,args|
          args.with_defaults(:key => 'prod')

          if Dir.glob("#{@dvd_dir}/*.gz").empty?
            fail("Error: Could not find compiled source tarballs")
          end

          Rake::Task['tar:build']

          Dir.chdir(@base_dir) do
            File.basename(Dir.glob("#{@dvd_dir}/*.tar.gz").first,'.tar.gz') =~ /SIMP-DVD-[^-]+-(.+)/
            name = "SIMP-#{$1}"
            sh %{mkisofs -uid 0 -gid 0 -D -A #{name} -J -joliet-long -m ".git*" -m "./build/tmp" -m "./build/SRPMS" -m "./build/RPMS" -m "./build/build_keys" -o #{name}.src.iso .}
          end
        end
      end
    end
  end
end

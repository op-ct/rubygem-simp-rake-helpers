# This file provided many common build-related tasks and helper methods from
# the SIMP Rakefile ecosystem.

require 'rake'
require 'rake/clean'
require 'rake/tasklib'
require 'fileutils'
require 'find'
require 'simp/utils/rpm'
require 'simp/rake/helpers/rpm_spec'
require 'simp/build/mock'

module Simp; end
module Simp::Rake
  class Pkg < ::Rake::TaskLib

    # path to the project's directory.  Usually `File.dirname(__FILE__)`
    attr_accessor :base_dir

    # the name of the package.  Usually `File.basename(@base_dir)`
    attr_accessor :pkg_name

    # path to the project's RPM specfile
    attr_accessor :spec_file

    # path to the directory to place generated assets (e.g., rpm, srpm, tar.gz)
    attr_accessor :pkg_dir

    # array of items to exclude from the tarball
    attr_accessor :exclude_list

    # array of items to additionally clean
    attr_accessor :clean_list

    # directory that contains all the mock chroots
    attr_accessor :mock_root_dir

    # array of items to ignore when checking if the tarball needs to be rebuilt
    attr_accessor :ignore_changes_list

    attr_accessor :spec_info

    attr_accessor :variants

    def initialize( base_dir, unique_name=nil )
      @base_dir            = base_dir
      @pkg_name            = File.basename(@base_dir)
      @pkg_dir             = File.join(@base_dir, 'dist')
      @pkg_tmp_dir         = File.join(@pkg_dir, 'tmp')
      @exclude_list        = [ File.basename(@pkg_dir) ]
      @clean_list          = []
      @ignore_changes_list = []
      @chroot_name         = unique_name
      @mock_root_dir       = ENV.fetch('SIMP_BUILD_MOCK_root','/var/lib/mock')

      local_spec = Dir.glob(File.join(@base_dir, 'build', '*.spec'))
      unless local_spec.empty?
        @spec_file = local_spec.first
      else
        FileUtils.mkdir_p(@pkg_tmp_dir) unless File.directory?(@pkg_tmp_dir)

        @spec_tempfile = File.open(File.join(@pkg_tmp_dir, "#{@pkg_name}.spec"), 'w')
        @spec_tempfile.write(Simp::Rake::Helpers::RPM_Spec.template)

        @spec_file = @spec_tempfile.path

        @spec_tempfile.flush
        @spec_tempfile.close

        FileUtils.chmod(0640, @spec_file)
      end

      # The following are required to build successful RPMs using the new
      # LUA-based RPM template

      @puppet_module_info_files = [
        @spec_file,
        %(#{@base_dir}/build),
        %(#{@base_dir}/CHANGELOG),
        %(#{@base_dir}/metadata.json)
      ]

      ::CLEAN.include( @pkg_dir )

      yield self if block_given?

      ::CLEAN.include( @clean_list )

      define
    end

    def define
      # For the most part, we don't want to hear Rake's noise, unless it's an error
      # TODO: Make this configurable
      verbose(false)

      define_clean
      define_clobber
      define_pkg_tar
      define_pkg_srpm
      define_pkg_rpm
      define_pkg_scrub
      task :default => 'pkg:tar'
      self
    end

    # Initialize the mock space if passed and retrieve the spec info from that
    # space directly.
    #
    # Ensures that the correct file names are used across the board.
    def initialize_spec_info(chroot, unique)
      unless @spec_info
        # This gets the resting spec file and allows us to pull out the name
        @spec_info   = Simp::Utils::RPM.get_info(@spec_file)
        @spec_info_dir = @base_dir


        if chroot
          @chroot_name = @chroot_name || "#{@spec_info[:name]}__#{ENV.fetch( 'USER', 'USER' )}"
          # Need to do this in case there is already a directory in /tmp
          rand_dirname = (0...10).map { ('a'..'z').to_a[rand(26)] }.join
          rand_tmpdir = %(/tmp/#{rand_dirname}_tmp)

          FileUtils.mkdir_p @pkg_dir
          mock = Simp::Build::Mock.new( chroot, @pkg_dir, "#{@chroot_name}__#{unique}" )
          mock.run( "mkdir -p '#{rand_tmpdir}'" )

          @puppet_module_info_files.each do |copy_in|
            if File.exist?(copy_in)
               mock.copyin( copy_in, "#{rand_tmpdir}" )
            end
          end

          mock.run "chmod -R ugo+rwX #{rand_tmpdir}/"

          mock.extra_args = [ '-D', "'pup_module_info_dir #{rand_tmpdir}'" ]
          info_hash = {
            :command    => mock.mock_cmd.join(' ') + " --chroot --cwd='#{rand_tmpdir}'",
            :rpm_extras => %(--specfile #{rand_tmpdir}/#{File.basename(@spec_file)} )
          }

          @spec_info = Simp::Utils::RPM.get_info(@spec_file, info_hash)
        end

        @dir_name       = "#{@spec_info[:name]}-#{@spec_info[:version]}"
        @mfull_pkg_name = "#{@dir_name}-#{@spec_info[:release]}"
        @full_pkg_name  = @mfull_pkg_name.gsub("%{?snapshot_release}","")
        @tar_dest       = "#{@pkg_dir}/#{@full_pkg_name}.tar.gz"

        if @tar_dest =~ /UNKNOWN/
          fail("Error: Could not determine package information from 'metadata.json'. Got '#{File.basename(@tar_dest)}'")
        end

        @variants       = (ENV['SIMP_BUILD_VARIANTS'].to_s.split(',') + ['default'])
      end
    end

    def srpm( chroot, unique, snapshot_release )
      mock = Simp::Build::Mock.new( chroot, @pkg_dir, "#{@chroot_name}__#{unique}" )

      l_date = ''
      if snapshot_release == 'true'
        l_date = ".#{TIMESTAMP}"
        mock.extra_args = ['-D', "'snapshot_release #{l_date}"]
        @tar_dest = "#{@pkg_dir}/#{@full_pkg_name}#{l_date}.tar.gz"
      end

      @variants.each do |variant|
        if variant != 'default'
          suffix = "-#{variant}"
        end

        srpms = Dir.glob(%(#{@pkg_dir}/#{@spec_info[:name]}#{suffix}-#{@spec_info[:version]}-#{@spec_info[:release]}#{l_date}.*.src.rpm))

        if require_rebuild?(@tar_dest,srpms) || require_rebuild?("#{@base_dir}/metadata.json")
          @puppet_module_info_files.each do |file|
            next unless File.exist?(file)
            Find.find(file) do |path|
              next if File.directory?(path)
              tgt_file = File.join(@pkg_dir, File.basename(path))
              FileUtils.rm_rf(tgt_file)    if File.exist?(tgt_file)
              FileUtils.cp(path, @pkg_dir) if File.exist?(path)
            end
          end

          mock.extra_args += ['-D' "_variant #{variant}"] if suffix
          mock.buildsrpm( @spec_file, @pkg_dir )
        end
      end
    end

    def rpm( chroot, unique, snapshot_release )
      mock = Simp::Build::Mock.new( chroot, @pkg_dir, "#{@chroot_name}__#{unique}" )
      l_mocksnap = []

      l_date = ''
      if snapshot_release == 'true'
        l_date = ".#{TIMESTAMP}"
        l_mocksnap = ['-D', "'snapshot_release #{l_date}"]
        @tar_dest = "#{@pkg_dir}/#{@full_pkg_name}#{l_date}.tar.gz"
      end

      @variants.each do |variant|
        suffix = "-#{variant}" unless variant == 'default'

        rpms = Dir.glob(%(#{@pkg_dir}/#{@spec_info[:name]}#{suffix}-#{@spec_info[:version]}-#{@spec_info[:release]}#{l_date}.*.rpm))
        srpms = rpms.select{|x| x =~ /src\.rpm$/}
        rpms = (rpms - srpms)

        srpms.each do |srpm|
          if require_rebuild?(srpm,rpms)
            mock.extra_args += l_mocksnap + ['-D' "_variant #{variant}"] if suffix
            mock.buildrpm( srpm )
          end
        end
      end

      # remote chroot unless told not to (saves LOTS of space during ISO builds)
      mock.clean unless ENV['SIMP_RAKE_MOCK_cleanup'] == 'no'
    end


    # Build a source tarball
    # @param
    def tar(snapshot_release, chroot, unique)
      l_date = ''
      if snapshot_release == 'true'
        l_date = '.' + "#{TIMESTAMP}"
        @tar_dest = "#{@pkg_dir}/#{@full_pkg_name}#{l_date}.tar.gz"
      end

      target_dir = File.basename(@base_dir)

      Dir.chdir(%(#{@base_dir}/..)) do
        Find.find(target_dir) do |path|
          Find.pappropriateyrune if path =~ /^\.git/
          Find.prune if path == "#{@pkg_name}/#{File.basename(@pkg_dir)}"
          Find.prune if @ignore_changes_list.include?(path)
          next if File.directory?(path)
          unless uptodate?(@tar_dest,[path])
            sh %Q(tar --owner 0 --group 0 --exclude-vcs --exclude=#{@exclude_list.join(' --exclude=')} --transform='s/^#{@pkg_name}/#{@dir_name}/' -cpzf "#{@tar_dest}" #{@pkg_name})
            break
          end
        end
      end
    end

    def define_clean
      desc <<-EOM
      Clean build artifacts for #{@pkg_name} (except for mock)
      EOM
      task :clean do |t,args|
        # this is provided by 'rake/clean' and the ::CLEAN constant
      end
    end

    def define_clobber
      desc <<-EOM
      Clobber build artifacts for #{@pkg_name} (except for mock)
      EOM
      task :clobber do |t,args|
      end
    end


    def define_pkg_tar
      namespace :pkg do
        directory @pkg_dir

        task :initialize_spec_info,[:chroot,:unique] => [@pkg_dir] do |t,args|
          args.with_defaults(:chroot => nil)
          args.with_defaults(:unique => false)
          initialize_spec_info(args.chroot, args.unique)
        end

        # :pkg:tar
        # -----------------------------
        desc <<-EOM
        Build the #{@pkg_name} tar package.
            * :snapshot_release - Add snapshot_release (date and time) to rpm
                                  version, rpm spec file must have macro for
                                  this to work.
        EOM
        task :tar,[:chroot,:unique,:snapshot_release] => [:initialize_spec_info] do |t,args|
          args.with_defaults(:snapshot_release => false)
          args.with_defaults(:chroot => nil)
          args.with_defaults(:unique => false)
          tar(args.snapshot_release, args.chroot, args.unique)
        end

      end
    end

    def define_pkg_srpm
      namespace :pkg do
        desc <<-EOM
        Build the #{@pkg_name} SRPM.
          Building RPMs requires a working Mock setup (http://fedoraproject.org/wiki/Projects/Mock)
            * :chroot - The Mock chroot configuration to use. See the '--root' option in mock(1)."
            * :unique - Whether or not to build the SRPM in a unique Mock environment.
                        This can be very useful for parallel builds of all modules.
            * :snapshot_release - Add snapshot_release (date and time) to rpm version.
                        Rpm spec file must have macro for this to work.

        Environment Variables
          SIMP_BUILD_VARIANTS - A comma delimted list of the target versions of Puppet/PE to build toward.

                     Currently supported are 'pe', 'p4', 'pe-2015'.

                     These will build for Puppet Enterprise, Puppet 4, and
                     Puppet Enterprise 2015+ respectively.

                     Anything after a dash '-' will be considered a VERSION.

                     NOTE: Different RPM spec files may have different
                     behaviors based on the value passed.
        EOM
        task :srpm,[:chroot,:unique,:snapshot_release] => [:tar] do |t,args|
          args.with_defaults(:unique => false)
          args.with_defaults(:snapshot_release => false)
          srpm( args.chroot, args.unique, args.snapshot_release )
        end
      end
    end

    def define_pkg_rpm
      namespace :pkg do
        desc <<-EOM
        Build the #{@pkg_name} RPM.
          Building RPMs requires a working Mock setup (http://fedoraproject.org/wiki/Projects/Mock)
            * :chroot - The Mock chroot configuration to use. See the '--root' option in mock(1)."
            * :unique - Whether or not to build the RPM in a unique Mock environment.
                        This can be very useful for parallel builds of all modules.
            * :snapshot_release - Add snapshot_release (date and time) to rpm version.
                        Rpm spec file must have macro for this to work.

        Environment Variables
          SIMP_BUILD_VARIANTS - A comma delimted list of the target versions of Puppet/PE to build toward.

                     Currently supported are 'pe', 'p4', 'pe-2015'.

                     These will build for Puppet Enterprise, Puppet 4, and
                     Puppet Enterprise 2015+ respectively.

                     Anything after a dash '-' will be considered a VERSION.

                     NOTE: Different RPM spec files may have different
                     behaviors based on the value passed.
        EOM
        task :rpm,[:chroot,:unique,:snapshot_release] do |t,args|
          args.with_defaults(:unique => false)
          args.with_defaults(:snapshot_release => false)


          Rake::Task['pkg:srpm'].invoke(args.chroot,args.unique,args.snapshot_release)
          rpm(args.chroot,args.unique,args.snapshot_release)
        end
      end
    end

    def define_pkg_scrub
      namespace :pkg do
        # :pkg:scrub
        # -----------------------------
        desc <<-EOM
        Scrub the #{@pkg_name} mock build directory.
        EOM
        task :scrub,[:chroot,:unique] do |t,args|
          args.with_defaults(:unique => false)
          mock = Simp::Build::Mock.new( chroot, @pkg_dir, "#{@chroot_name}__#{unique}" )
          mock.scrub
        end
      end
    end

    # ------------------------------------------------------------------------------
    # helper methods
    # ------------------------------------------------------------------------------
    # Return True if any of the 'output_files' are older than the 'src_file'
    def require_rebuild?(src_file,output_files)
      require_rebuild = false
      require_rebuild = true if output_files.empty?
      unless require_rebuild
        output_files.each do |outfile|
          unless uptodate?(outfile,Array(src_file))
            require_rebuild = true
            break
          end
        end
      end

      require_rebuild
    end
  end
end

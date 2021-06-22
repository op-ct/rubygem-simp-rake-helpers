module Simp; end
module Simp::Build; end
module Simp::Build::Iso
  #
  class LocalRepoclosure

    # FIXME support:
    #   - [x] EL8 `dnf repoclosure`
    #   - [ ] EL8 `dnf repoclosure` with pre-enabled modules
    #   - [ ] EL7 `dnf repoclosure` (untested)
    #
    # Maybe support:
    #   - [ ] EL7 plan-jane `repoclosure`? (PITA, see old code)
    #
    #  On EL7, ensure:
    #     yum install -y dnf dnf-plugins-core
    #
    #  IIRC, EL7 dnf uses `--repo` instead of `--repoid`, too
    def self.repoclosure(staging_dir, enable_module_streams: [], repoclose_pe: false)
      repo_dirs = locate_repo_dirs(staging_dir)

      require 'tmpdir'
      Dir.mktmpdir(['simp','repoclosure']) do |dir|
        yum_conf = File.join(dir,'yum.conf')
        reposdir = File.join(dir,'yum.repos.d')

        File.open(yum_conf, 'w') do |f|
          f.write(ERB.new(yum_conf_erb(repoclose_pe),nil,'-').result(binding))
        end
        FileUtils.mkdir_p(reposdir)

        dnf_base_cmd = "dnf -v -c '#{yum_conf}' --installroot '#{dir}' "

        # Need to set reposdir (even if its empty), or dnf will also use the
        # host system's repos - resulting in repoid collisions
        dnf_base_cmd += "--setopt reposdir='#{reposdir}' "

        repoclosure_cmd = dnf_base_cmd + 'repoclosure  ' + repo_dirs.map do |path|
          repoid = File.basename(path)
           " \\\n  --repofrompath '#{repoid},file://#{path}' \\\n  --repoid '#{repoid}'"
        end.join(' ')

        if block_given?
          yield repoclosure_cmd, dnf_base_cmd
        else
          fail( 'Unimplemented: run command with feedback (popen3?)' )
        end
      end
    end

    # Locate all (non-hidden) RPM repositories under the directory tree
    def self.locate_repo_dirs(staging_dir)
      require 'find'
      repo_dirs = []
      Find.find(staging_dir) do |path|
        next unless File.directory?(path)
        Find.prune if File.basename(path).start_with?('.') # skip hidden
        next unless File.basename(path) == 'repodata'
        if File.file?(File.join(path,'repomd.xml'))
          repo_dirs << File.dirname(path)
          Find.prune
        end
      end
      repo_dirs
    end

    # Template a dnf.conf / yum.conf to run inside a tempdir
    def self.yum_conf_erb(repoclose_pe=false)
      <<~YUM_CONF
        [main]
        keepcache=0
        exactarch=1
        obsoletes=1
        gpgcheck=0
        plugins=1    # needed to use 'dnf repoclosure'
        installonly_limit=5
        <% unless #{repoclose_pe} -%>
        exclude=*-pe-*
        <% end -%>
      YUM_CONF
    end

  end
end


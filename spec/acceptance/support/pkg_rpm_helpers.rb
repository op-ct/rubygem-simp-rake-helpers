module Simp::BeakerHelpers::SimpRakeHelpers::PkgRpmHelpers

  # rake command string to run on hosts
  # passes on useful troubleshooting env vars
  def rake_cmd
    cmd = 'rake'
    %w(
      SIMP_RPM_LUA_debug
      SIMP_RAKE_PKG_verbose
      SIMP_RPM_verbose
    ).each do |env_var|
      if value = ENV[env_var]
         cmd = "#{env_var}=#{value} #{cmd}"
      end
    end
    cmd
  end


  def copy_host_files_into_build_user_homedir(
    hosts,
    root_dir=File.expand_path('../../../',__FILE__)
  )
    # make sure all generated files from previous rake tasks have
    # permissions that allow the copy in the 'prep' below
    dist_dirs = Dir.glob(File.join(root_dir, '**', 'dist'))
    dist_dirs.each { |dir| FileUtils.chmod_R(0755, dir) }
    FileUtils.chmod_R(0755, 'junit')
    FileUtils.chmod_R(0755, 'log')
    #
    # FIXME: ^^^ Ive faithfully refactored the code above into the helpers, but
    #        it doesn't make sense to me: the file permissions are modified on
    #        the host *after* they've been uploaded to the SUTs.
    #
    #        I've added a `cp -a` + `chown/chmod -R` below, which seems to
    #        accomplish what the section above it documented as doing.
    #
    #        So: Is this section really doing something we need?
    #
    #          * If `no`:  let's remove it
    #          * If `yes`: let's demonstrate + document it
    #          * If you'd rather try something else, turn to page 386
    #

    # I've added the `ch* -R` on the SUT-side, which seems to work on a fresh checkout
    on hosts, 'cp -a /host_files /home/build_user/; ' +
             'chmod -R go=u-w /home/build_user/host_files/{dist,**/dist,junit,log}; ' +
             'chown -R build_user:build_user /home/build_user/host_files; '
  end


  # key   = what `rpm -q --scripts` calls each scriptlet
  # value = the label passed to `simp_rpm_helper`
  def scriptlet_label_map
    {
      'pretrans'      => nil,
      'preinstall'    => 'pre',
      'postinstall'   => 'post',
      'preuninstall'  => 'preun',
      'postuninstall' => 'postun',
      'posttrans'     => nil,
    }
  end


  # returns a Hash of information about an RPM file's scriptlets
  def rpm_scriptlets_for( host, rpm_file )
    _labels  = scriptlet_label_map.keys.join('|')
    rx_scriptlet_blocks = /^(?<block>(?<scriptlet>#{_labels}) scriptlet.*?(\r|\n)(?<content>.*?))(?=\n#{_labels}|\Z)/m


    comment "\n\n\n===== RPM LOGS\n"

    require 'tmpdir'
    Dir.mktmpdir do |dir|
      %w(
           logs/build.srpm.out
           logs/build.srpm.err
           logs/build.rpm.out
           logs/build.rpm.err
      ).each do |log_file |
          _from = File.expand_path(log_file, File.dirname(rpm_file))
          _to   = File.join( dir )
          result = scp_from(host, _from, _to)
          comment "\n\n== LOGFILE: #{log_file}\n"
          comment File.read( File.join(_to, File.basename(_to)) )
      end
    end

    comment "Verify RPM version\n\t(FIXME: this is to aid troubleshooting within Travis CI―remove when done!)"
    on host, 'rpm --version; cat /etc/redhat-release; true'

    result = on host, %Q(rpm -qp --scripts #{rpm_file})

    comment "\n\n== result.stdout:\n\n#{result.stdout.to_s}\n"

    comment "\n\n== regex:\n\n#{rx_scriptlet_blocks.source}\n"


    scriptlets = {}
    result.stdout.to_s.scan(rx_scriptlet_blocks) do
      scriptlet = scriptlets[$~[:scriptlet]] ||= { :count => 0 }
      scriptlet[:count]       += 1
      scriptlet[:content]      = $~[:content].strip
      scriptlet[:full_block]   = $~[:block]
      scriptlet[:bare_content] = scriptlet[:content].gsub(/^((--|#).*?[\r\n]+)/,'')
    end

    require 'pp'
    comment "\n\n== scriptlets data structure:"
    comment "\n||" + scriptlets.pretty_print_inspect + "||\n"
    scriptlets
  end


  # returns a Hash of information about an RPM file's triggers
  def rpm_triggers_for( host, rpm_file )
    _trigger          = 'trigger\\w+ scriptlet \\(using [\\/a-z0-9]+\\) --(!?\\p{Graph}|\\s)*?'
    rx_trigger_blocks = /^(?<block>(?<trigger>#{_trigger})[\r\n](?<content>.*?)(?=\n#{_trigger}|\Z))/m

    result = on host, %Q(rpm -qp --triggers #{rpm_file})

    triggers = {}
    result.stdout.scan(rx_trigger_blocks) do
      trigger=  triggers[$~[:trigger]] ||= { :count => 0 }
      trigger[:count]       += 1
      trigger[:content]      = $~[:content].strip
      trigger[:full_block]   = $~[:block]
      trigger[:bare_content] = trigger[:content].gsub(/^((--|#).*?[\r\n]+)/,'')
    end
    triggers
  end
end

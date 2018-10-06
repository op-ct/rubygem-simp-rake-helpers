require 'securerandom'
require 'rake'

module Simp
  # Manage a development GPG key + GPG agent
  #
  #   A typical env-file reads like:
  #
  #   ```sh
  #   GPG_AGENT_INFO=/tmp/gpg-4yhfOB/S.gpg-agent:15495:1; export GPG_AGENT_INFO;\n"
  #   ```
  class GPGAgent
    include FileUtils

    def initialize(dir, verbose = false)
      @dir                = File.expand_path(dir)
      @verbose            = verbose
      @dev_email          = 'gatekeeper@simp.development.key'
      @dev_key_file       = 'RPM-GPG-KEY-SIMP-Dev'

      # SIMP::RPM.sign_keys looks for a "gengpgkey" file
      @genkey_params_file = 'gengpgkey'
      @gpg_agent_env_file = 'gpg-agent-info.env'
      @gpg_agent_script   = 'run_gpg_agent'
    end

    # Returns a running gpg-agent's env string, if it can be detected
    #
    #   This is the shell string returned to STDOUT by a new gpg-agent --deamon,
    #   and written via  `--write-env-file`
    #
    def gpg_agent_info
      if File.exist?(@gpg_agent_env_file)
        puts "Reading gpg_agent_info from `#{@gpg_agent_env_file}`..." if @verbose
        info = parse_gpg_agent_info_env(File.read(@gpg_agent_env_file))
      elsif File.exist?((ENV['GPG_AGENT_INFO']).to_s.split(':').first || '')
        puts "Reading gpg_agent_info from `ENV['GPG_AGENT_INFO']`..." if @verbose
        info = parse_gpg_agent_info_env('GPG_AGENT_INFO=' + ENV['GPG_AGENT_INFO'])
      else
        puts "Couldn't find a valid source to read gpg_agent_info..." if @verbose
        info = nil
      end
      info
    end

    # Return the number of days left before the agent's SIMP dev key expires
    def dev_key_days_left
      current_key = %x(gpg --homedir=#{@dir} --list-keys #{@dev_email} 2>/dev/null)
      days_left = 0
      unless current_key.empty?
        lasts_until = current_key.lines.first.strip.split("\s").last.delete(']')
        days_left = (Date.parse(lasts_until) - Date.today).to_i
      end
      days_left
    end

    def clean_gpg_agent_directory
      puts "  Removing all files under '#{@dir}'" if @verbose
      Dir.glob(File.join(@dir, '*')).each do |todel|
        rm_rf(todel, :verbose => @verbose)
      end
    end

    # Ensure that the gpg-agent is running with a a dev key
    def ensure
      days_left = dev_key_days_left
      if days_left > 0
        puts "GPG key (#{@dev_email}) will expire in #{days_left} days."
        return
      end

      Dir.chdir @dir do |_dir|
        puts 'Ensuring dev GPG agent is available...'
        clean_gpg_agent_directory
        write_genkey_parameter_file
        write_gpg_agent_script

        begin
          gpg_agent_output = %x(./#{@gpg_agent_script}).strip
          agent_info = gpg_agent_info

            if gpg_agent_output.empty?
              raise 'WTF'
            end
            # get back info on the command line.
            unless File.exist?(File.join(Dir.pwd, File.basename(agent_info[:socket])))
              ### This was the original target, but it doesn't make sense to me:
              ### local_target = %(#{Dir.pwd}/#{File.basename(agent_info[:pid])})
              local_target = File.join(Dir.pwd, 'S.gpg-agent')
              ln_s(agent_info[:socket], local_target, :verbose => @verbose)
            end

          generate_key(agent_info[:info])
        ensure
          kill_agent(agent_info[:pid])
        end
        agent_info
      end
    end

    def kill_agent(pid)
      rm('S.gpg-agent') if File.symlink?('S.gpg-agent')
      if pid
        Process.kill(0, pid)
        Process.kill(15, pid)
      end
    rescue Errno::ESRCH
      # Not Running, Nothing to do!
    end

    # Generate a RPM GPG signing key for local development
    def generate_key(gpg_agent_info_str)
      puts "Generating new GPG key#{@verbose ? " under '#{@dir}'" : ''}..."
      gpg_cmd   = %(GPG_AGENT_INFO=#{gpg_agent_info_str} gpg --homedir="#{@dir}")
      output_to = @verbose ? '| tee' : '>'
      sh %(#{gpg_cmd} --batch --gen-key #{@genkey_params_file})
      sh %(#{gpg_cmd} --armor --export #{@dev_email} #{output_to} "#{@dev_key_file}")
    end

    # Return a data structure from a gpg-agent env-file formatted string.
    #
    def parse_gpg_agent_info_env(str)
      info    = %r{^(GPG_AGENT_INFO=)?(?<info>[^;]+)}.match(str)[:info]
      matches = %r{^(?<socket>[^:]+):(?<pid>[^:]+)}.match(info)
      { info: info.strip, socket: matches[:socket], pid: matches[:pid].to_i }
    end

    # Write the `gpg --genkey --batch` control parameters file
    #
    # @see "Unattended key generation" in /usr/share/doc/gnupg2-*/DETAILS for
    #   documentation on the command parameters format
    def write_genkey_parameter_file
      now               = Time.now.to_i.to_s
      expire_date       = Date.today + 14
      passphrase        = SecureRandom.base64(500)
      genkey_parameters = <<-GENKEY_PARAMETERS.gsub(%r{^ {8}}, '')
        %echo Generating Development GPG Key
        %echo
        %echo This key will expire on #{expire_date}
        %echo
        Key-Type: RSA
        Key-Length: 4096
        Key-Usage: sign
        Name-Real: SIMP Development
        Name-Comment: Development key #{now}
        Name-Email: #{@dev_email}
        Expire-Date: 2w
        Passphrase: #{passphrase}
        %pubring pubring.gpg
        %secring secring.gpg
        # The following creates the key, so we can print "Done!" afterwards
        %commit
        %echo New GPG Development Key Created
      GENKEY_PARAMETERS
      File.open(@genkey_params_file, 'w') { |fh| fh.puts(genkey_parameters) }
    end

    # Write a local gpg-agent daemon script file
    def write_gpg_agent_script
      gpg_agent_script = <<-AGENT_SCRIPT.gsub(%r{^ {20}}, '')
        #!/bin/sh

        gpg-agent --homedir=#{Dir.pwd} --no-use-standard-socket --sh --batch --write-env-file "#{@gpg_agent_env_file}" --daemon --pinentry-program /usr/bin/pinentry-curses < /dev/null &
      AGENT_SCRIPT

      File.open(@gpg_agent_script, 'w') { |fh| fh.puts(gpg_agent_script) }
      chmod(0o755, @gpg_agent_script)
    end
  end
end

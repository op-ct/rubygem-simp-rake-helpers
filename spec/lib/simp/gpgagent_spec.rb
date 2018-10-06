require 'simp/gpgagent'
require 'spec_helper'
require 'fileutils'

describe Simp::GPGAgent do
  include FileUtils

  before :all do
    dir = File.expand_path('files/gpg_agent', File.dirname(__FILE__))
    TMP_DIR = File.join(dir, 'tmp')
    TMP_DEV_DIR = File.join(TMP_DIR, 'dev')
    rm_rf   TMP_DIR
    mkdir_p TMP_DEV_DIR
    chmod   0o700, TMP_DEV_DIR

    ###STDERR.puts "   ==== ORIGINAL_GPG_AGENT_INFO = ENV['GPG_AGENT_INFO'] (#{ENV['GPG_AGENT_INFO']})"
    ORIGINAL_GPG_AGENT_INFO = ENV['GPG_AGENT_INFO']
  end

  after :all do
    ENV['GPG_AGENT_INFO'] = ORIGINAL_GPG_AGENT_INFO
    STDERR.puts "  ======= TMP_DEV_DIR: '#{TMP_DEV_DIR}'"
    #    rm_rf TMP_DIR
  end

  # TODO: Test this with:
  # 1. [x] Fresh checkout: no GPG_AGENT_INFO and no gpg_agent_env_file
  #        should be nil
  # 2. [ ] Fresh checkout w/env: GPG_AGENT_INFO, but no gpg_agent_env_file
  #        should be GPG_AGENT_INFO
  # 3. [x] Rerun w/file: no GPG_AGENT_INFO, gpg_agent_env_file exists
  #        should be gpg_agent_env_file
  # 4. [ ] Rerun+env: GPG_AGENT_INFO, but no gpg_agent_env_file
  #        should be gpg_agent_env_file
  context 'with #ensure' do
    shared_examples_for 'a new local gpg-agent' do
      it 'creates a local gpg-agent' do
        expect(agent_info.reject{|x| x.nil?}.keys).to include(:info, :socket, :pid)
      end

      it 'creates a local GPG signing key' do
        Dir.chdir(TMP_DEV_DIR) { expect(Dir['*']).to include('RPM-GPG-KEY-SIMP-Dev') }
      end

      it 'populates a gpg-agent directory' do
        Dir.chdir(TMP_DEV_DIR) do |_dir|
          expect(Dir['*'].sort).to include(
            'gengpgkey',
            'gpg-agent-info.env',
            'run_gpg_agent',
            'pubring.gpg',
            'secring.gpg',
            'random_seed'
          )
        end
      end

      it 'had a gpg-agent socket' do
        socket = agent_info[:socket]
        expect(File.absolute_path(socket.to_s)).to eq socket.to_s
      end

      it 'has killed the local gpg-agent' do
        expect(File.exist?(agent_info[:socket])).to be false
      end
    end

    shared_examples_for 'a re-used local gpg-agent' do
      it 'reuses an unexpired local gpg-agent' do
        expect{described_class.new(TMP_DEV_DIR).ensure}.to output(
          /^GPG key \(gatekeeper@simp\.development\.key\) will expire in 14 days\./
        ).to_stdout
      end
    end

    context 'with a rerun: no GPG_AGENT_INFO, but a recent gpg_agent_env_file' do
      before :all do
        rm_rf   TMP_DEV_DIR
        mkdir_p TMP_DEV_DIR
        chmod   0o700, TMP_DEV_DIR
        ENV['GPG_AGENT_INFO'] = nil
        FIRST_RUN_AGENT_INFO  = described_class.new(TMP_DEV_DIR).ensure
        SECOND_RUN_AGENT_INFO = described_class.new(TMP_DEV_DIR).ensure
      end

      let(:agent_info) { FIRST_RUN_AGENT_INFO }
      let(:reused_agent_info) { SECOND_RUN_AGENT_INFO }

      it_behaves_like 'a new local gpg-agent'
      it_behaves_like 'a re-used local gpg-agent'
    end
  end
end

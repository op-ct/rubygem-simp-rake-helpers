require 'spec_helper_acceptance'
require_relative 'support/build_user_helpers'
require_relative 'support/build_project_helpers'

RSpec.configure do |c|
  c.include Simp::BeakerHelpers::SimpRakeHelpers::BuildUserHelpers
  c.extend  Simp::BeakerHelpers::SimpRakeHelpers::BuildUserHelpers
  c.include Simp::BeakerHelpers::SimpRakeHelpers::BuildProjectHelpers
  c.extend  Simp::BeakerHelpers::SimpRakeHelpers::BuildProjectHelpers
end



describe 'rake pkg:signrpms' do
  def opts
    { run_in_parallel: true, environment: { 'SIMP_PKG_verbose' => 'yes' } }
  end

  def prep_rpms_dir(_rpms_dir, src_rpms, opts = {})
    copy_cmds = src_rpms.map do |_rpm|
      "cp -a '#{@src_rpm}' '#{@rpms_dir}'"
    end.join('; ')
    # Clean out RPMs dir and copy in a fresh dummy RPM
    on(hosts, %(#{run_cmd} "rm -f '#{@rpms_dir}/*'; #{copy_cmds} "), opts)
  end

  before :all do
    @test_dir = "#{build_user_homedir}/test--pkg-signrpms"

    scaffold_build_project(hosts, @test_dir, opts)

    # Provide an RPM directory to process and a dummy RPM to sign
    @rpms_dir = "#{@test_dir}/test.rpms"
    @src_rpm  = "#{build_user_host_files}/spec/lib/simp/files/testpackage-1-0.noarch.rpm"
    @test_rpm = File.join(@rpms_dir, File.basename(@src_rpm))
    on(hosts, %(#{run_cmd} "mkdir '#{@rpms_dir}'"))

    # Ensure a DVD directory exists that is appropriate to each SUT
    hosts.each do |host|
      dvd_dir = distribution_dir(host, opts) + '/DVD'
      on(host, %(#{run_cmd} "mkdir -p #{dvd_dir}"), opts)
    end
  end

  let(:rpm_unsigned_regex) do
    %r{^Signature\s+:\s+\(none\)$}
  end

  let(:rpm_signed_regex) do
    %r{^Signature\s+:\s+.*,\s*Key ID (?<key_id>[0-9a-f]+)$}
  end

  context 'when starting without a dev key' do
    before :all do
      prep_rpms_dir(@rpms_dir, [@src_rpm], opts)
      @rpms_before_signing = on(hosts, %(#{run_cmd} "rpm -qip '#{@test_rpm}' | grep ^Signature"), opts)
      on(hosts, %(#{run_cmd} "cd '#{@test_dir}'; bundle exec rake pkg:signrpms[dev,'#{@rpms_dir}']"), opts)
      @rpms_after_signing = on(hosts, %(#{run_cmd} "rpm -qip '#{@test_rpm}' | grep ^Signature"), opts)
    end

    it 'creates a GPG dev signing key' do
      hosts.each do |host|
        expect { dev_signing_key_id(host, opts) }.not_to(raise_error)
      end
    end

    it 'begins with unsigned RPMs' do
      @rpms_before_signing.each do |result|
        expect(result.stdout).to match rpm_unsigned_regex
      end
    end

    it 'signs RPM packages in the directory using the GPG dev signing key' do
      @rpms_after_signing.each do |result|
        host = hosts_with_name(hosts, result.host).first
        expect(result.stdout).to match rpm_signed_regex

        signed_rpm_data = rpm_signed_regex.match(result.stdout)
        expect(signed_rpm_data[:key_id]).to eql dev_signing_key_id(host, opts)
      end
    end
  end

  context 'when an unexpired dev key exists' do
  end

  ###  it 'can run the os-dependent Simp::LocalGpgSigningKey spec tests' do
  ###    hf_cmd(hosts, 'bundle exec rspec spec/lib/simp/local_gpg_signing_key_spec.rb.beaker-only')
  ###  end
end

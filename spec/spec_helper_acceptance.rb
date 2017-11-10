require 'beaker-rspec'
require 'tmpdir'
require 'simp/beaker_helpers'
include Simp::BeakerHelpers

RSpec.configure do |c|
  # Readable test descriptions
  c.formatter = :documentation

  # Configure all nodes in nodeset
  c.before :suite do
    # build_user's "cp -a /host_files ~" will fail if the source files were
    # checked out with a conservative umask, so open up the permissions:
    hosts.each { |host| on host, 'chmod -R go=u-w  /host_files; ls -lartZ /host_files' }
  end
end

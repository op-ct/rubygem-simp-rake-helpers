require 'spec_helper_acceptance'

describe 'rake pkg:rpm with customized content' do

  before :all do
    echo "START " * 80
  end
  it 'can prep the package directories' do
    on hosts, 'ls -l /root'
  end
end


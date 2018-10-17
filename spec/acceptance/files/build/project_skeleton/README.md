# Dummy super-release (`simp-core`) project

The contents of this directory tree provide _just enough_ directories and dummy
files for a `rake -T` to avoid failing during ` Simp::Rake::Build::Helpers.new`

## What this provides

* A (paper-thin) directory structure to model a "super-release" project like
  [`simp-core`][simp-core])
* A means to acceptance-test `simp/rake/build/helpers`

## How to use this project in your acceptance tests

To use this project in your acceptance tests:

1. Copy this directory tree into a test-specific directory root
2. Copy in any specific assets you need for your tests
3. Run `bundle exec rake <task>` to test the scenario you have modeled

You can do this simply by including:

```ruby
RSpec.configure do |c|
  c.include Simp::BeakerHelpers::SimpRakeHelpers::BuildProjectHelpers
  c.extend  Simp::BeakerHelpers::SimpRakeHelpers::BuildProjectHelpers
end
```


Gem::Specification.new do |s|
  s.name          = 'logstash-output-cv'
  s.version       = '0.1.0'
  s.licenses      = ['Apache License (2.0)']
  s.summary       = 'This plugin writes the events into commvault datacube endpoint'
  s.description   = 'Commvault datacube endpoint '
  s.homepage      = ''
  s.authors       = ['Mahesh']
  s.email         = 'mkota@commvault.com'
  s.require_paths = ['lib']

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "output" }

  # Gem dependencies
  s.add_runtime_dependency "logstash-core-plugin-api", ">= 2.0"
  s.add_runtime_dependency "logstash-codec-plain"
  s.add_development_dependency "logstash-devutils"
  s.add_runtime_dependency "logstash-mixin-http_client", ">= 2.2.1", "< 6.0.0"
  s.add_runtime_dependency "stud", ['>= 0.0.17', '~> 0.0']
end
# encoding: utf-8

require 'rubygems'
require 'bundler'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end
require 'rake'

require 'jeweler'
Jeweler::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://docs.rubygems.org/read/chapter/20 for more options
  gem.name = "s3-object-processor"
  gem.homepage = "http://github.com/jpastuszek/s3-object-processor"
  gem.license = "MIT"
  gem.summary = "S3 key-by-kye processor builder"
  gem.description = "DSL tools for building programs that can process S3 object key-by-key using threaded worker pool"
  gem.email = "jpastuszek@gmail.com"
  gem.authors = ["Jakub Pastuszek"]
  # dependencies defined in Gemfile

	gem.files.select{|f| f =~ /^.idea/}.each do |file|
		gem.files.exclude file
	end
end
Jeweler::RubygemsDotOrgTasks.new

require 'rspec/core'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = FileList['spec/**/*_spec.rb']
end

RSpec::Core::RakeTask.new(:rcov) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rcov = true
end

task :default => :spec

require 'rdoc/task'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "s3-object-processor #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

require "bundler/gem_tasks"
require "rspec/core/rake_task"

ENV['REDIS_URL'] ||= 'redis://redis:6379/0'


RSpec::Core::RakeTask.new(:spec)

task :default => :spec

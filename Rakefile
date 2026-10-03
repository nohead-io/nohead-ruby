# frozen_string_literal: true

require "bundler/gem_tasks" # rake release, used by .github/workflows/release.yml
require "minitest/test_task"

Minitest::TestTask.create(:test) do |task|
  task.test_globs = ["test/**/*_test.rb"]
end

desc "Regenerate lib/nohead/operations.rb from openapi.json"
task :generate do
  ruby "scripts/generate.rb"
end

desc "Write samples.json, the API reference's code samples, from test/calls.rb"
task :samples do
  ruby "scripts/samples.rb"
end

task default: :test

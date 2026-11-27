# Run from the generated Local.xcodeproj directory. Both roles must emit
# matching evidence in this run, even if Xcode reports success with skips.
require 'json'
require 'open3'
require 'securerandom'

abort 'Usage: ruby verify_replay.rb <simulator-UDID>' unless ARGV.size == 1
run = SecureRandom.uuid
bundle = "Replay-#{run}.xcresult"
test = 'LocalPurchaseTests/testReplayAfterProcessTermination'
ok = system({ 'TEST_RUNNER_PAYKIT_RESTART_NONCE' => run },
            'xcodebuild', 'test', '-project', 'Local.xcodeproj', '-scheme', 'Replay',
            '-destination', "id=#{ARGV.first}", '-parallel-testing-enabled', 'NO',
            "-only-testing:LocalTests/#{test}", '-derivedDataPath', 'DerivedData', '-resultBundlePath', bundle)
abort "Replay test failed. See #{bundle}" unless ok

json, status = Open3.capture2('xcrun', 'xcresulttool', 'get', 'test-results', 'activities',
                              '--path', bundle, '--test-id', "#{test}()")
abort 'Missing replay result' unless status.success?
runs = JSON.parse(json).fetch('testRuns')
abort 'Expected exactly two replay test runs' unless runs.size == 2
def transaction(runs, configuration, prefix)
  result = runs.find { |r| r.dig('testPlanConfiguration', 'configurationName') == configuration }
  abort "Missing #{configuration} configuration" unless result
  titles = result.fetch('activities').map { |activity| activity.fetch('title') }
  evidence = titles.select { |title| title.start_with?(prefix) }.map { |title| title.delete_prefix(prefix) }
  abort "Missing or ambiguous #{configuration} evidence" unless evidence.size == 1 && !evidence.first.empty?
  evidence.first
end

seeded = transaction(runs, '1-seed', "Seeded #{run} transaction ")
recovered = transaction(runs, '2-recover', "Recovered #{run} transaction ")
abort 'Recovery finished a different transaction' unless recovered == seeded
puts "Verified cross-process recovery and finish of transaction #{seeded}. See #{bundle}"

# Generates a simulator-only XCTest host in a temporary directory.
# Requires the xcodeproj Ruby gem (also bundled with CocoaPods).
# ruby make_project.rb /tmp/paykit-tests <Flutter SDK root>
# cd /tmp/paykit-tests
# xcodebuild test -scheme Local -destination id=<simulator-UDID> -parallel-testing-enabled NO
# In the generated directory, run the separate two-process release check:
# ruby <pay_kit>/ios/Tests/verify_replay.rb <simulator-UDID>
# All purchases use the local StoreKit test catalog, with a test-only app ID.
require 'fileutils'
require 'json'
require 'securerandom'
require 'xcodeproj'
dest, sdk = ARGV
abort 'Usage: make_project.rb <empty directory> <Flutter SDK root>' unless dest && sdk
Dir.mkdir(dest) unless Dir.exist?(dest)
abort 'Expected empty output directory' unless Dir.empty?(dest)
source = File.expand_path('..', __dir__)
framework = File.join(File.expand_path(sdk), 'bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework')
abort 'Run flutter precache --ios to install Flutter.framework' unless File.directory?(framework)
Dir.chdir(dest)
FileUtils.cp(File.join(source, 'Tests/Products.storekit'), 'Products.storekit')
Xcodeproj::Plist.write_to_path({ 'get-task-allow' => true }, 'Local.entitlements')
Xcodeproj::Plist.write_to_path({ 'PayKitConsumableProductIdentifiers' => ['test.coins', 'test.monthly'] }, 'Local.plist')
project = Xcodeproj::Project.new('Local.xcodeproj')
app = project.new_target(:application, 'Local', :ios, '17.0')
tests = project.new_target(:unit_test_bundle, 'LocalTests', :ios, '17.0')
tests.add_dependency(app)
File.write('main.m', <<~OBJC)
  #import <UIKit/UIKit.h>
  @interface LocalTestDelegate : UIResponder<UIApplicationDelegate>
  @end
  @implementation LocalTestDelegate
  @end
  int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"LocalTestDelegate"); }
  }
OBJC
app.source_build_phase.add_file_reference(project.main_group.new_file('main.m'))
flutter = project.main_group.new_file(framework)
app.frameworks_build_phase.add_file_reference(flutter)
embed = app.new_copy_files_build_phase('Embed Flutter')
embed.dst_subfolder_spec = '10'
embed.add_file_reference(flutter).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
tests.frameworks_build_phase.add_file_reference(flutter)
['Classes/PayKitTransactionPlugin.m', 'Tests/LocalPurchaseTests.swift', 'Tests/ObjectIdentityTests.m'].each do |file|
  tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(source, file)))
end
catalog = project.main_group.new_file('Products.storekit')
app.resources_build_phase.add_file_reference(catalog)
tests.resources_build_phase.add_file_reference(catalog)
File.write('Bridge.h', "#import \"PayKitTransactionPlugin.h\"\n@interface PayKitTransactionPlugin (Bridge)\n- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result;\n- (void)stopObserving;\n@end\n")
[app, tests].each do |target|
  target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = "test.paykit.#{target.name}"
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['MARKETING_VERSION'] = '1.0'
    s['CURRENT_PROJECT_VERSION'] = '1'
    s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    s['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', File.dirname(framework), '$(SDKROOT)/Developer/Library/Frameworks']
    s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
    s['HEADER_SEARCH_PATHS'] = [File.join(source, 'Classes')]
    s['SWIFT_VERSION'] = '5.0'
    if target == app
      s['INFOPLIST_FILE'] = 'Local.plist'
      s['CODE_SIGN_ENTITLEMENTS'] = 'Local.entitlements'
      next
    end
    s['BUNDLE_LOADER'] = '$(TEST_HOST)'
    s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Local.app/Local'
    s['SWIFT_OBJC_BRIDGING_HEADER'] = 'Bridge.h'
  end
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.launch_action.xml_element.add_element('StoreKitConfigurationFileReference', 'identifier' => '../Products.storekit')
replay = 'LocalPurchaseTests/testReplayAfterProcessTermination()'
testable = scheme.test_action.testables.first.xml_element
testable.add_element('SkippedTests').add_element('Test', 'Identifier' => replay)
scheme.save_as(project.path, 'Local')

# Each configuration starts its own test host. The shared app container only
# carries purchase evidence. The plan assigns the roles independently of it.
phases = %w[seed recover].each_with_index.map do |phase, index|
  { id: SecureRandom.uuid, name: "#{index + 1}-#{phase}",
    options: { environmentVariableEntries: [{ key: 'PAYKIT_RESTART_PHASE', value: phase }] } }
end
plan = { version: 1, configurations: phases, defaultOptions: {},
         testTargets: [{ target: { containerPath: 'container:Local.xcodeproj', identifier: tests.uuid,
                                   name: tests.name }, selectedTests: [replay] }] }
File.write('Replay.xctestplan', JSON.pretty_generate(plan))
action = scheme.test_action.xml_element
action.delete_element('Testables')
action.add_element('TestPlans').add_element('TestPlanReference', 'reference' => 'container:Replay.xctestplan',
                                            'default' => 'YES')
scheme.save_as(project.path, 'Replay')
project.save

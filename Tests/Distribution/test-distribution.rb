#!/usr/bin/env ruby
# Does not sign, notarize, install, access credentials, or modify the input repository.
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'rexml/document'

source_root = File.expand_path(ARGV.fetch(0, File.join(__dir__, '../..')))
%w[build-app.sh build-pkg.sh notarize-pkg.sh components.plist Distribution.xml.in].each do |name|
  unless File.file?(File.join(source_root, 'Distribution', name))
    abort "Missing Distribution/#{name}. Pass the repository/snapshot containing Issue #15's scripts."
  end
end

class DistributionChecks
  def initialize(root, fixtures)
    @root = root
    @trace = File.join(root, 'trace.txt')
    @bin = File.join(root, 'mock-bin')
    FileUtils.mkdir_p(@bin)
    mock = File.join(@bin, 'mock-tool.sh')
    FileUtils.cp(File.join(fixtures, 'mock-tool.sh'), mock)
    FileUtils.chmod(0755, mock)
    %w[security codesign lipo ditto pkgbuild productbuild pkgutil xcrun spctl shasum swift sips iconutil tiffutil].each do |name|
      FileUtils.ln_s(mock, File.join(@bin, name))
    end
    @app = File.join(root, 'fixture', 'Sumibi.app')
    FileUtils.mkdir_p(File.join(@app, 'Contents', 'MacOS'))
    FileUtils.cp(File.join(fixtures, 'FixtureInfo.plist'), File.join(@app, 'Contents', 'Info.plist'))
    File.write(File.join(@app, 'Contents', 'MacOS', 'Sumibi'), 'not an executable; test fixture only')
    @pkg = File.join(root, 'fixture', 'Sumibi.pkg')
    File.write(@pkg, 'test fixture, not a distributable package')
    @count = 0
  end

  def assert(condition, message)
    raise message unless condition
  end

  def run(script, args = [], overrides = {})
    File.write(@trace, '')
    env = {
      'PATH' => "#{@bin}:/usr/bin:/bin:/usr/sbin:/sbin",
      'SUMIBI_TEST_TRACE' => @trace,
      'SUMIBI_DEVELOPER_ID_APPLICATION' => '',
      'SUMIBI_DEVELOPER_ID_INSTALLER' => 'Developer ID Installer: Test (TEST)',
      'TEST_APP_AUTHORITY' => 'Developer ID Application: Test (TEST)',
      'TEST_APP_TEAM' => 'TEST', 'TEST_RUNTIME' => 'yes', 'TEST_TIMESTAMP' => 'yes',
      'TEST_PKG_AUTHORITY' => 'Developer ID Installer: Test (TEST)',
      'TEST_STATUS' => 'Accepted', 'TEST_SUBMIT_EXIT' => '0',
      'TEST_STAPLE_EXIT' => '0', 'TEST_SPCTL_EXIT' => '0'
    }.merge(overrides)
    stdout, stderr, status = Open3.capture3(env, '/bin/sh', File.join(@root, 'Distribution', script), *args, chdir: @root)
    [status.success?, File.readlines(@trace, chomp: true), stdout + stderr]
  end

  def check(name)
    yield
    @count += 1
    puts "PASS: #{name}"
  end

  def reject(script, args = [], env = {}, forbidden = /^(swift|pkgbuild|productbuild|xcrun|spctl|shasum)\|/)
    success, calls, output = run(script, args, env)
    assert(!success, "Unexpected success: #{script}\n#{output}")
    assert(calls.none? { |call| call.match?(forbidden) }, "Unexpected later command: #{calls.inspect}")
  end

  def execute
    check('build-app requires identity') { reject('build-app.sh') }
    check('build-app rejects App Store identity') do
      reject('build-app.sh', [], 'SUMIBI_DEVELOPER_ID_APPLICATION' => 'Apple Distribution: Test (TEST)')
    end
    check('missing Developer ID stops before compiling') do
      reject('build-app.sh', [], 'SUMIBI_DEVELOPER_ID_APPLICATION' => 'Developer ID Application: Test (TEST)')
    end
    check('build-pkg requires an app argument') { reject('build-pkg.sh') }
    check('build-pkg rejects wrong Installer identity') do
      reject('build-pkg.sh', [@app], 'SUMIBI_DEVELOPER_ID_INSTALLER' => 'Apple Distribution: Test (TEST)')
    end
    check('build-pkg rejects a non-Developer-ID app') do
      reject('build-pkg.sh', [@app], 'TEST_APP_AUTHORITY' => 'Apple Development: Test (TEST)')
    end
    check('build-pkg rejects different signing teams') { reject('build-pkg.sh', [@app], 'TEST_APP_TEAM' => 'OTHER') }
    check('build-pkg requires hardened runtime') { reject('build-pkg.sh', [@app], 'TEST_RUNTIME' => 'no') }
    check('build-pkg requires timestamp') { reject('build-pkg.sh', [@app], 'TEST_TIMESTAMP' => 'no') }
    check('build-pkg permits only the home domain and disables relocation') do
      success, calls, output = run('build-pkg.sh', [@app])
      assert(success, output)
      xml_path = Dir.glob(File.join(@root, '.build/distribution/package.*/Distribution.xml')).fetch(0)
      xml = REXML::Document.new(File.read(xml_path))
      domains = xml.elements['installer-gui-script/domains']
      assert(domains.attributes['enable_currentUserHome'] == 'true', 'Home domain must be enabled')
      %w[enable_anywhere enable_localSystem].each { |key| assert(domains.attributes[key] == 'false', "#{key} must be disabled") }
      assert(xml.elements['installer-gui-script/options'].attributes['hostArchitectures'] == 'arm64', 'Wrong architecture')
      assert(xml.elements['installer-gui-script/allowed-os-versions/os-version'].attributes['min'] == '26.0', 'Wrong minimum OS')
      plist = File.join(@root, 'Distribution/components.plist')
      value, _, status = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :0:BundleIsRelocatable', plist)
      assert(status.success? && value.strip == 'false', 'Relocation must be disabled')
      assert(calls.any? { |call| call.start_with?('pkgbuild|') && call.include?('|--install-location|/Library/Input Methods|') }, 'Wrong component location')
      assert(calls.none? { |call| call.include?('|--scripts|') }, 'No installation scripts expected')
      assert(calls.any? { |call| call.start_with?('productbuild|') && call.include?('|--sign|Developer ID Installer: Test (TEST)|--timestamp|') }, 'Product signing required')
    end
    check('notarize rejects relative path') { reject('notarize-pkg.sh', ['Sumibi.pkg', 'test-profile']) }
    check('notarize requires nonempty profile') { reject('notarize-pkg.sh', [@pkg, '']) }
    check('notarize requires Installer signature') do
      reject('notarize-pkg.sh', [@pkg, 'test-profile'], 'TEST_PKG_AUTHORITY' => 'Unsigned')
    end
    check('Accepted follows submission, log, staple, validation, assessment, checksum') do
      success, calls, output = run('notarize-pkg.sh', [@pkg, 'test-profile'])
      assert(success, output)
      sequence = calls.map { |call| call.split('|').take(call.start_with?('xcrun|') ? 3 : 1).join(' ') }
      assert(sequence == ['pkgutil', 'xcrun notarytool submit', 'xcrun notarytool log', 'xcrun stapler staple', 'xcrun stapler validate', 'spctl', 'shasum'], "Wrong sequence: #{sequence.inspect}")
      submit = calls.find { |call| call.start_with?('xcrun|notarytool|submit|') }
      assert(submit.include?('|--keychain-profile|test-profile|'), 'Must use profile reference, not passwords')
    end
    check('Invalid never staples, assesses or hashes') do
      reject('notarize-pkg.sh', [@pkg, 'test-profile'], { 'TEST_STATUS' => 'Invalid' }, /^(xcrun\|stapler|spctl\||shasum\|)/)
    end
    check('submission failure never proceeds or retries') do
      success, calls, output = run('notarize-pkg.sh', [@pkg, 'test-profile'], 'TEST_SUBMIT_EXIT' => '7')
      assert(!success, output)
      assert(calls.count { |call| call.start_with?('xcrun|notarytool|submit|') } == 1, 'Must not retry silently')
      assert(calls.none? { |call| call.start_with?('xcrun|stapler|', 'spctl|', 'shasum|') }, 'Failed submission advanced')
    end
    check('staple failure stops before Gatekeeper assessment') do
      reject('notarize-pkg.sh', [@pkg, 'test-profile'], { 'TEST_STAPLE_EXIT' => '8' }, /^(spctl|shasum)\|/)
    end
    check('Gatekeeper rejection stops before checksum/success') do
      reject('notarize-pkg.sh', [@pkg, 'test-profile'], { 'TEST_SPCTL_EXIT' => '9' }, /^shasum\|/)
    end
    puts "#{@count} distribution checks passed (mock tools only; no signing/notarization/installation)."
  end
end

Dir.mktmpdir('sumibi-distribution-tests-') do |root|
  FileUtils.cp_r(File.join(source_root, 'Distribution'), root)
  DistributionChecks.new(root, __dir__).execute
end

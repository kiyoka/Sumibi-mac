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
    %w[security codesign nm lipo ditto pkgbuild productbuild pkgutil xcrun spctl shasum swift sips iconutil tiffutil].each do |name|
      FileUtils.ln_s(mock, File.join(@bin, name))
    end
    @app = File.join(root, 'fixture', 'Sumibi.app')
    FileUtils.mkdir_p(File.join(@app, 'Contents', 'MacOS'))
    FileUtils.cp(File.join(fixtures, 'FixtureInfo.plist'), File.join(@app, 'Contents', 'Info.plist'))
    File.write(File.join(@app, 'Contents', 'MacOS', 'Sumibi'), 'not an executable; test fixture only')
    %w[AppIcon.icns InputMenuIcon.tiff MenuBarIcon.png MenuBarIcon@2x.png SudachiCandidates.tsv ja.lproj/InfoPlist.strings en.lproj/InfoPlist.strings SudachiDict/LICENSE-2.0.txt SudachiDict/LEGAL].each do |name|
      path = File.join(@app, 'Contents', 'Resources', name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, 'fixture only')
    end
    FileUtils.mkdir_p(File.join(root, 'App'))
    FileUtils.cp(File.join(fixtures, 'mock-build-app.sh'), File.join(root, 'App/build.sh'))
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
      'SUMIBI_SIGN_IDENTITY' => 'Apple Development: inherited (OTHER)',
      'SUMIBI_PROTOTYPE_SIGN_IDENTITY' => 'Apple Development: legacy (OTHER)',
      'TEST_APP_IDENTITY_AVAILABLE' => 'no', 'TEST_INSTALLER_IDENTITY_AVAILABLE' => 'yes',
      'TEST_ARCHITECTURES' => 'arm64',
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
    later_calls = calls.reject { |call| call == 'xcrun|--sdk|macosx|--show-sdk-path' }
    assert(later_calls.none? { |call| call.match?(forbidden) }, "Unexpected later command: #{calls.inspect}\n#{output}")
  end

  def with_plist(key, value)
    path = File.join(@app, 'Contents', 'Info.plist')
    original = File.binread(path)
    _, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Set :#{key} #{value}", path)
    assert(status.success?, "Cannot set fixture #{key}")
    yield
  ensure
    File.binwrite(path, original) if original
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
    check('build-app rejects development arguments') do
      reject('build-app.sh', ['--development'], {}, /^(app-build|codesign|swift)\|/)
    end
    check('build-app uses the normal entry and overrides inherited signing identities') do
      success, calls, output = run('build-app.sh', [], 'TEST_APP_IDENTITY_AVAILABLE' => 'yes',
        'SUMIBI_DEVELOPER_ID_APPLICATION' => 'Developer ID Application: Test (TEST)')
      assert(success, output)
      assert(calls.include?('app-build|sign=-|args='), 'Must use normal App/build.sh with explicit ad-hoc intermediate')
      assert(calls.any? { |call| call.start_with?('codesign|--force|--options|runtime|--timestamp|--sign|Developer ID Application: Test (TEST)|') }, 'Distribution copy must get timestamped Developer ID signature')
    end
    check('build-pkg rejects missing Installer private key') do
      reject('build-pkg.sh', [@app], 'TEST_INSTALLER_IDENTITY_AVAILABLE' => 'no')
    end
    check('build-pkg rejects development builds') do
      with_plist('SumibiDevelopmentBuild', 'true') { reject('build-pkg.sh', [@app]) }
    end
    check('build-pkg rejects malformed versions') do
      with_plist('CFBundleShortVersionString', '0..9') { reject('build-pkg.sh', [@app]) }
    end
    check('build-pkg rejects unsupported architectures') do
      reject('build-pkg.sh', [@app], 'TEST_ARCHITECTURES' => 'i386')
    end
    check('build-pkg rejects development code markers even with production metadata') do
      binary = File.join(@app, 'Contents/MacOS/Sumibi')
      original = File.binread(binary)
      begin
        File.write(binary, 'PrototypeResponseMode')
        reject('build-pkg.sh', [@app])
      ensure
        File.binwrite(binary, original)
      end
    end
    check('build-pkg rejects missing resources') do
      resource = File.join(@app, 'Contents/Resources/SudachiCandidates.tsv')
      original = File.binread(resource)
      begin
        File.unlink(resource)
        reject('build-pkg.sh', [@app])
      ensure
        File.binwrite(resource, original)
      end
    end
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
      product = calls.find { |call| call.start_with?('productbuild|') }.split('|')
      xml_path = product.fetch(product.index('--distribution') + 1)
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
    check('build-pkg derives minimum OS from the input artifact') do
      with_plist('LSMinimumSystemVersion', '26.1') do
        success, calls, output = run('build-pkg.sh', [@app])
        assert(success, output)
        product = calls.find { |call| call.start_with?('productbuild|') }.split('|')
        xml = REXML::Document.new(File.read(product.fetch(product.index('--distribution') + 1)))
        assert(xml.elements['installer-gui-script/allowed-os-versions/os-version'].attributes['min'] == '26.1', 'Minimum OS must follow artifact metadata')
      end
    end
    check('build-pkg checks the resulting Installer identity') do
      success, calls, output = run('build-pkg.sh', [@app], 'TEST_PKG_AUTHORITY' => 'Developer ID Installer: Other (OTHER)')
      assert(!success, output)
      assert(calls.any? { |call| call.start_with?('pkgutil|--check-signature|') }, 'Generated product signature must be inspected')
      assert(!output.include?('Signed user-only package (not yet notarized):'), 'Wrong signature must not be announced as successful')
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
  FileUtils.mkdir_p(File.join(root, 'Development'))
  FileUtils.cp(File.join(source_root, 'Development/verify-build.rb'), File.join(root, 'Development/verify-build.rb'))
  DistributionChecks.new(root, __dir__).execute
end

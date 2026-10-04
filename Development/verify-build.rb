#!/usr/bin/env ruby
# Read-only artifact check. Does not launch the IME or access user settings/Keychain.
require 'open3'

mode, app = ARGV
abort 'Usage: ruby Development/verify-build.rb production|development /path/to/Sumibi.app' unless
  %w[production development].include?(mode) && app && ARGV.size == 2
plist = File.join(app, 'Contents', 'Info.plist')
read = lambda do |key|
  output, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", plist)
  abort "Cannot read #{key}: #{output}" unless status.success?
  output.strip
end
expected = {
  'CFBundleIdentifier' => 'org.sumibi.inputmethod.Sumibi',
  'CFBundleExecutable' => 'Sumibi',
  'InputMethodConnectionName' => 'org.sumibi.inputmethod.Sumibi_Connection',
  'InputMethodServerControllerClass' => 'SumibiPrototypeInputController',
  'ComponentInputModeDict:tsInputModeListKey:com.apple.inputmethod.Japanese:TISInputSourceID' => 'org.sumibi.inputmethod.Sumibi.Japanese',
  'SumibiDevelopmentBuild' => (mode == 'development').to_s
}
expected.each { |key, value| abort "Unexpected #{key}" unless read.call(key) == value }
binary = File.join(app, 'Contents', 'MacOS', 'Sumibi')
contents = File.binread(binary)
# These strings exist only in gated implementations, not ordinary diagnostic logging.
markers = %w[PrototypeResponseMode PrototypeDiagnoseText PrototypePokeStyle] +
  ['text: expected=[', 'text: after commit caret=', 'text: before caret ']
markers.each do |marker|
  present = contents.include?(marker.b)
  abort "Unexpected development marker #{marker} (#{mode})" unless present == (mode == 'development')
end
symbols, status = Open3.capture2e('nm', binary)
abort 'Cannot inspect executable symbols' unless status.success?
has_mock = symbols.include?('MockConversionService')
abort "Unexpected mock service (#{mode})" unless has_mock == (mode == 'development')
%w[AppIcon.icns InputMenuIcon.tiff MenuBarIcon.png MenuBarIcon@2x.png SudachiCandidates.tsv ja.lproj/InfoPlist.strings en.lproj/InfoPlist.strings SudachiDict/LICENSE-2.0.txt SudachiDict/LEGAL].each do |resource|
  abort "Missing resource #{resource}" unless File.file?(File.join(app, 'Contents', 'Resources', resource))
end
output, status = Open3.capture2e('codesign', '--verify', '--strict', app)
abort "Invalid signature: #{output}" unless status.success?
puts "PASS: #{mode} artifact, development code boundary, registration identifiers, resources and signature"

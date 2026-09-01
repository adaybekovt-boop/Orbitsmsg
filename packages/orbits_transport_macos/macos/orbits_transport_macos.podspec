#
# Local Bare slot for macOS. NEVER downloads a runtime or remote JS.
# kBareBinaryShipped stays false until every OS slot is in the app bundle.
#
Pod::Spec.new do |s|
  s.name             = 'orbits_transport_macos'
  s.version          = '0.1.0'
  s.summary          = 'Orbits Bare transport host for macOS.'
  s.description      = <<-DESC
Vendors a locally built Bare binary into the app bundle when present.
Production must not fetch remote executable JS or binaries.
                       DESC
  s.homepage         = 'https://github.com/adaybekovt-boop/Orbitsmsg'
  s.license          = { :type => 'UNLICENSED', :text => 'Proprietary. See the repository LICENSE.' }
  s.author           = { 'Orbits' => 'security@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # Copy a local slot if present. No curl, wget, or remote URL.
  s.prepare_command = <<-CMD
    set -e
    SLOT_ARM="../../../tool/bare/darwin-arm64/bare"
    SLOT_X64="../../../tool/bare/darwin-x64/bare"
    STDLIB="../../../tool/connectivity_harness/bare_stdlib.zip"
    if [ -f "$SLOT_ARM" ]; then
      cp -f "$SLOT_ARM" ./bare
      chmod +x ./bare
      echo "orbits_transport_macos: using local darwin-arm64 Bare slot"
    elif [ -f "$SLOT_X64" ]; then
      cp -f "$SLOT_X64" ./bare
      chmod +x ./bare
      echo "orbits_transport_macos: using local darwin-x64 Bare slot"
    elif [ -f ./bare ]; then
      echo "orbits_transport_macos: using previously embedded Bare slot"
    else
      echo "orbits_transport_macos: Bare slot empty (kBareBinaryShipped stays false)"
    fi
    if [ -f "$STDLIB" ]; then
      cp -f "$STDLIB" ./bare_stdlib.zip
      echo "orbits_transport_macos: using local bare stdlib zip"
    elif [ -f ./bare_stdlib.zip ]; then
      echo "orbits_transport_macos: using previously embedded bare stdlib zip"
    fi
  CMD

  resources = []
  resources << 'bare' if File.exist?(File.join(__dir__, 'bare'))
  resources << 'bare_stdlib.zip' if File.exist?(File.join(__dir__, 'bare_stdlib.zip'))
  unless resources.empty?
    s.resource_bundles = { 'OrbitsTransportBare' => resources }
    s.resources = resources
  end
end

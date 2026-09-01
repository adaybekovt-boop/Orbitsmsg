#
# Local Bare slot for iOS. NEVER downloads a runtime or remote JS.
# kBareBinaryShipped stays false until every OS slot is in the app bundle.
#
Pod::Spec.new do |s|
  s.name             = 'orbits_transport_ios'
  s.version          = '0.1.0'
  s.summary          = 'Orbits Bare transport host for iOS.'
  s.description      = <<-DESC
Vendors a locally built Bare binary into the app bundle when present.
Production must not fetch remote executable JS or binaries.
                       DESC
  s.homepage         = 'https://github.com/adaybekovt-boop/Orbitsmsg'
  s.license          = { :file => '../../../LICENSE' }
  s.author           = { 'Orbits' => 'security@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'

  # Copy a local slot if present. No curl, wget, or remote URL.
  s.prepare_command = <<-CMD
    set -e
    SLOT="../../../tool/bare/ios-arm64/bare"
    if [ -f "$SLOT" ]; then
      cp -f "$SLOT" ./bare
      chmod +x ./bare
      echo "orbits_transport_ios: using local Bare slot"
    elif [ -f ./bare ]; then
      echo "orbits_transport_ios: using previously embedded Bare slot"
    else
      echo "orbits_transport_ios: Bare slot empty (kBareBinaryShipped stays false)"
    fi
  CMD

  if File.exist?(File.join(__dir__, 'bare'))
    s.resources = 'bare'
  end
end

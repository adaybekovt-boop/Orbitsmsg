Pod::Spec.new do |s|
  s.name             = 'orbits_transport_macos'
  s.version          = '0.1.0'
  s.summary          = 'Orbits federated transport macOS host. Fail-closed without Bare.'
  s.homepage         = 'https://github.com/adaybekovt-boop/Orbitsmsg'
  s.license          = { :type => 'proprietary' }
  s.author           = { 'Orbits' => 'orbits@local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'
  s.static_framework = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.resource_bundles = {
    'orbits_transport_macos_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  kit_root = ENV['ORBITS_BARE_KIT']
  local = File.join(__dir__, 'BareKit.xcframework')
  if File.directory?(local)
    s.vendored_frameworks = 'BareKit.xcframework'
  elsif kit_root && !kit_root.empty?
    _ = File.join(kit_root, 'macos', 'BareKit.xcframework')
  end
end

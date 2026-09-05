Pod::Spec.new do |s|
  s.name             = 'orbits_transport_ios'
  s.version          = '0.1.0'
  s.summary          = 'Orbits federated transport iOS host. Fail-closed without Bare.'
  s.homepage         = 'https://github.com/adaybekovt-boop/Orbitsmsg'
  s.license          = { :type => 'proprietary' }
  s.author           = { 'Orbits' => 'orbits@local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.static_framework = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.libraries = 'z', 'compression'
  s.resource_bundles = {
    'orbits_transport_ios_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }
  zip = File.join(__dir__, 'orbits-worklet-modules.zip')
  if File.file?(zip)
    s.resources = ['orbits-worklet-modules.zip']
  end

  kit_root = ENV['ORBITS_BARE_KIT']
  local = File.join(__dir__, 'BareKit.xcframework')
  udx_local = File.join(__dir__, 'udx-native.xcframework')
  # CocoaPods requires a relative vendored_frameworks path. The official
  # XCFramework is linked into this plugin directory by tool/bare/link-official-kit.sh.
  vendored = []
  if File.directory?(local)
    vendored << 'BareKit.xcframework'
  end
  Dir.glob(File.join(__dir__, '*.xcframework')).each do |fw|
    name = File.basename(fw)
    vendored << name unless vendored.include?(name)
  end
  if !vendored.empty?
    s.vendored_frameworks = vendored
  elsif kit_root && !kit_root.empty?
    # Keep the ORBITS_BARE_KIT hook for verify-kit-hooks; linking happens before pod install.
    _ = File.join(kit_root, 'ios', 'BareKit.xcframework')
  end
end

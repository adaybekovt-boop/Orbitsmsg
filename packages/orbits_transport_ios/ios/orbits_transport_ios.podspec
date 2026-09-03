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
  s.resource_bundles = {
    'orbits_transport_ios_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  kit_root = ENV['ORBITS_BARE_KIT']
  xc = nil
  if kit_root && !kit_root.empty?
    nested = File.join(kit_root, 'ios', 'BareKit.xcframework')
    direct = File.join(kit_root, 'BareKit.xcframework')
    xc = nested if File.directory?(nested)
    xc ||= direct if File.directory?(direct)
  end
  unless xc
    cache = ENV['ORBITS_BARE_CACHE']
    repo_root = File.expand_path('../../..', __dir__)
    cached = if cache && !cache.empty?
               File.join(cache, 'bare-kit', 'ios', 'BareKit.xcframework')
             else
               File.join(repo_root, 'build', 'orbits-bare', 'bare-kit', 'ios', 'BareKit.xcframework')
             end
    xc = cached if File.directory?(cached)
  end
  s.vendored_frameworks = xc if xc
end

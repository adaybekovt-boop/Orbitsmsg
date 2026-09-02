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
end

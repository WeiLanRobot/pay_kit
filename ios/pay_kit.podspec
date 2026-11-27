Pod::Spec.new do |s|
  s.name             = 'pay_kit'
  s.version          = '1.3.1'
  s.summary          = 'StoreKit transaction support for pay_kit.'
  s.description      = s.summary
  s.homepage         = 'https://github.com/WeiLanRobot/pay_kit'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'WeiLanRobot'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.framework        = 'StoreKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end

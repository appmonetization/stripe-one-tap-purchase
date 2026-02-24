Pod::Spec.new do |s|
  s.name             = 'StripeOneTapPurchase'
  s.version          = '1.0.3'
  s.summary          = 'Stripe one-tap purchase integration for Helium.'
  s.description      = 'A library that provides Stripe one-tap purchase functionality with Helium integration, including Apple Pay support and entitlements management.'
  s.homepage         = 'https://github.com/appmonetization/stripe-one-tap-purchase'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'appmonetization' => 'appmonetization' }
  s.source           = { :git => 'https://github.com/appmonetization/stripe-one-tap-purchase.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '6.0'

  s.source_files = 'Sources/StripeOneTapPurchase/**/*.swift'

  s.dependency 'Helium', '~> 4.1'
  s.dependency 'StripeApplePay', '~> 25.6'
end

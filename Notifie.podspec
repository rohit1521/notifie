Pod::Spec.new do |spec|
  spec.name             = 'Notifie'
  spec.version          = '0.1.0-beta.2'
  spec.summary          = 'Notifie Device SDK for iOS and macOS.'
  spec.description      = <<~DESC
    Local notifications, push token registration, lifecycle events and durable
    event delivery. Local notifications require no Notifie account.
  DESC
  spec.homepage         = 'https://notifie.dev'
  spec.license          = { :type => 'Apache-2.0', :file => 'sdks/swift/LICENSE' }
  spec.author           = { 'Notifie' => 'support@notifie.dev' }
  spec.source           = {
    :git => 'https://github.com/rohit1521/notifie.git',
    :tag => "swift-#{spec.version}",
  }

  # Lives at the repository root rather than beside the Swift sources.
  # CocoaPods resolves file patterns from the clone root when installing from
  # git, so a podspec nested in the monorepo would find no files once
  # published — which is exactly how `pod spec lint` catches it.
  #
  # Published alongside Swift Package Manager rather than instead of it.
  # CocoaPods is what lets the Flutter plugin depend on this SDK: a Flutter iOS
  # plugin is a pod, and a pod cannot depend on an SPM package. Without this the
  # cross-platform bridges would have to reimplement scheduling.
  spec.source_files     = 'sdks/swift/Sources/Notifie/**/*.swift'

  # The example is an executable target and is deliberately excluded.

  spec.ios.deployment_target = '15.0'
  spec.osx.deployment_target = '12.0'
  spec.swift_version    = '5.9'
  spec.frameworks       = 'Foundation', 'UserNotifications'
end

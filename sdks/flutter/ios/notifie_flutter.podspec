Pod::Spec.new do |spec|
  spec.name             = 'notifie_flutter'
  # Must track pubspec.yaml: CocoaPods resolves against this, so a stale value
  # makes `pod 'notifie_flutter', '0.1.0-beta.6'` unsatisfiable for a consumer
  # who read the published Dart version.
  spec.version          = '0.1.0-beta.7'
  spec.summary          = 'Flutter bridge for the Notifie Device SDK.'
  spec.homepage         = 'https://notifie.dev'
  spec.license          = { :type => 'Apache-2.0' }
  spec.author           = { 'Notifie' => 'opensource@notifie.dev' }
  spec.source           = { :path => '.' }
  spec.source_files     = 'Classes/**/*'
  spec.dependency 'Flutter'

  # Local notification scheduling is delegated to the native SDK rather than
  # reimplemented here, so persistence and platform trigger behaviour keep a
  # single implementation across all Notifie SDKs.
  # CocoaPods does not select a prerelease to satisfy an open-ended dependency.
  # Pin until a stable Notifie pod exists; otherwise a clean pub.dev consumer
  # fails with "only pre-release versions available".
  #
  # Because the pin is exact, it must be raised in the same change that
  # republishes the native SDK, and the native pod must reach trunk first. A
  # stale pin here silently ships the previous native SDK: the plugin would
  # look fixed while every consumer still had the old push and identify
  # behaviour underneath it.
  spec.dependency 'Notifie', '0.1.0-beta.3'

  # Raised from 12.0 to match the Notifie SDK, which uses async/await APIs
  # unavailable on older deployment targets.
  spec.platform         = :ios, '15.0'
  spec.swift_version    = '5.9'
end

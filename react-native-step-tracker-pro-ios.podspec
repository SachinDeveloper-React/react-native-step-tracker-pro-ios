require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-step-tracker-pro-ios"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]
  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => package["repository"]["url"], :tag => "v#{s.version}" }

  s.source_files = "ios/*.{h,mm}", "ios/Core/**/*.swift", "ios/Platform/**/*.swift"
  s.resource_bundles = { "StepTrackerProIOSPrivacy" => ["ios/PrivacyInfo.xcprivacy"] }
  s.frameworks   = "HealthKit", "CoreMotion", "DeviceCheck", "CryptoKit", "Security", "UIKit"
  s.swift_version = "5.9"
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_COMPILATION_MODE" => "wholemodule",
  }

  install_modules_dependencies(s)
end

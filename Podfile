# Uncomment the next line to define a global platform for your project
# platform :ios, '9.0'

target 'SayEnglish' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!
  pod 'Google-Mobile-Ads-SDK'  # Firebase Messaging (푸시 알림)
  pod 'AdFitSDK'

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
      config.build_settings['STRIP_DEBUG_SYMBOLS'] = 'NO'
      config.build_settings['COPY_PHASE_STRIP'] = 'NO'
    end
  end
end


find_package(unofficial-sodium CONFIG REQUIRED)
find_package(Opus CONFIG REQUIRED)

set(YAPPER_IOS_BUNDLE_ID "com.example.yapper" CACHE STRING "Bundle id of the iPhone app, must be one you own for TestFlight")
set(YAPPER_IOS_TEAM "" CACHE STRING "Apple developer team id that signs the iPhone app, not needed for the Simulator")

# The iPhone app. Same protocol as the desktop client, so it talks to the same server.
add_executable(yapper_ios MACOSX_BUNDLE
        src/AppModel.swift
        src/Audio.swift
        src/Connection.swift
        src/Crypto.swift
        src/ScreenViewer.swift
        src/Wire.swift
        src/YapperApp.swift

        Assets.xcassets
)

target_link_libraries(yapper_ios PRIVATE unofficial-sodium::sodium Opus::opus)

set_target_properties(yapper_ios PROPERTIES
        OUTPUT_NAME Yapper
        RESOURCE Assets.xcassets
        Swift_LANGUAGE_VERSION 5.0
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist
        XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER ${CMAKE_CURRENT_SOURCE_DIR}/src/Bridging.h
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER ${YAPPER_IOS_BUNDLE_ID}
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${YAPPER_IOS_TEAM}"
        XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY 1
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
        # Raise CURRENT_PROJECT_VERSION for every TestFlight upload
        XCODE_ATTRIBUTE_MARKETING_VERSION 0.1.0
        XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION 1
)

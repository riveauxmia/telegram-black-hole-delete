# Telegram-iOS: submodules/TelegramUI/Components/Chat/BlackHoleDelete/BUILD
#   Sources/BlackHoleTimeline.swift, Sources/BlackHoleDeleteAnimator.swift
#   Resources/BlackHole.metal, Resources/BlackHoleDisk.png
# apple_resource_bundle compiles the .metal file into default.metallib inside the bundle.
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

filegroup(
    name = "BlackHoleDeleteResources",
    srcs = glob(["Resources/**/*"]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "BlackHoleDeleteResourcesBundleInfoPlist",
    extension = "plist",
    template = """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.BlackHoleDeleteResources</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>BlackHoleDelete</string>
    """,
)

apple_resource_bundle(
    name = "BlackHoleDeleteResourcesBundle",
    infoplists = [":BlackHoleDeleteResourcesBundleInfoPlist"],
    resources = [":BlackHoleDeleteResources"],
)

swift_library(
    name = "BlackHoleDelete",
    module_name = "BlackHoleDelete",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    data = [":BlackHoleDeleteResourcesBundle"],
    deps = [],
    visibility = ["//visibility:public"],
)

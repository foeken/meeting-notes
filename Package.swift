// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MeetingNotes",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MeetingNotes", targets: ["MeetingNotes"])
  ],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.1"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
  ],
  targets: [
    .executableTarget(
      name: "MeetingNotes",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      swiftSettings: [
        .unsafeFlags(["-parse-as-library"])
      ],
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreMediaIO"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "MeetingNotesTests",
      dependencies: ["MeetingNotes"]
    ),
  ]
)

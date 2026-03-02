// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwiftPDF",
  platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
  products: [
    .library(name: "SwiftPDF", targets: ["SwiftPDF"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
  ],
  targets: [
    .systemLibrary(
      name: "CZlib",
      pkgConfig: "zlib",
      providers: [
        .apt(["zlib1g-dev"]),
        .brew(["zlib"]),
      ],
    ),
    .target(
      name: "SwiftPDF",
      dependencies: [
        "CZlib",
        .product(name: "DequeModule", package: "swift-collections"),
      ],
    ),
    .executableTarget(
      name: "SwiftPDFTests",
      dependencies: ["SwiftPDF"],
      path: "Tests/SwiftPDFTests",
    ),
  ],
)

// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MOM",
  products: [
    .library(
      name: "MOM",
      targets: ["MOM"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "MOM",
      dependencies: [
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "MOMTests",
      dependencies: ["MOM"]
    ),
  ]
)

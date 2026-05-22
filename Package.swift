// swift-tools-version: 5.9
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
  targets: [
    .target(
      name: "MOM",
      dependencies: []
    ),
    .testTarget(
      name: "MOMTests",
      dependencies: ["MOM"]
    ),
  ]
)

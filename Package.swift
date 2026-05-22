// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MOM",
  products: [
    .library(
      name: "Surrogate",
      targets: ["Surrogate"]
    ),
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
    // Legacy compatibility shim: re-exports MOM and provides the C-style
    // free-function surface (`MOMControllerCreate(...)` etc.) for callers
    // that still write `import Surrogate`.
    .target(
      name: "Surrogate",
      dependencies: ["MOM"]
    ),
    .testTarget(
      name: "MOMTests",
      dependencies: ["MOM", "Surrogate"]
    ),
  ]
)

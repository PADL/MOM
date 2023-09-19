// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

func tryGuessSwiftLibRoot() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "which swift"]
    task.standardOutput = Pipe()
    do {
        try task.run()
        let outputData = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        let path = URL(fileURLWithPath: String(decoding: outputData, as: UTF8.self))
        return path.deletingLastPathComponent().path + "/../lib/swift"
    } catch {
        return "/usr/lib/swift"
    }
}

let UnsafeCFlags: [String]
#if os(Linux)
UnsafeCFlags = ["-I", tryGuessSwiftLibRoot()]
#else
UnsafeCFlags = [String]()
#endif

let package = Package(
    name: "MOM",
    products: [
        // Products define the executables and libraries a package produces, and make them visible
        // to other packages.
        .library(
            name: "Surrogate",
            targets: [
                "Surrogate"
            ]
        ),
        .library(
            name: "MOM",
            targets: [
                "MOM"
            ]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a
        // test suite.
        // Targets can depend on other targets in this package, and on products in packages this
        // package depends on.
        .target(
            name: "Surrogate",
            dependencies: [],
            cSettings: [
                .unsafeFlags(UnsafeCFlags),
            ]
        ),
        .target(
            name: "MOM",
            dependencies: [
                "Surrogate",
            ],
            cSettings: [
                .unsafeFlags(UnsafeCFlags),
            ]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ContourDJ", platforms: [.macOS(.v14)], products: [.executable(name: "Contour", targets: ["Contour"])], targets: [
 .target(name: "CDJCore", publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-std=c++17"])]),
 .executableTarget(name: "Contour", dependencies: ["CDJCore"], linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreMIDI"), .linkedFramework("AppKit")])
], cxxLanguageStandard: .cxx17)

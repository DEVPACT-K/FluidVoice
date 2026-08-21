import XCTest

final class MontereyBuildGuardTests: XCTestCase {
    func testSwiftToolsVersionIsMontereyCompatible() throws {
        let pkg = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Package.swift")
        let content = try String(contentsOf: pkg)
        XCTAssertFalse(content.contains("swift-tools-version: 5.9"), "Monterey needs 5.7, not 5.9")
        XCTAssertTrue(content.contains("swift-tools-version: 5.7"))
    }

    func testBuildShGuardsToolsVersion() throws {
        let build = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build.sh")
        let content = try String(contentsOf: build)
        XCTAssertTrue(content.contains("swift-tools-version: 5.9") && content.contains("5.7"), "build.sh should guard swift-tools-version")
    }

    func testFluidAudioBranchIsMontereyCompatible() throws {
        let pkg = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Package.swift")
        let content = try String(contentsOf: pkg)
        XCTAssertFalse(content.contains("B/cohere-coreml-asr"), "Monterey needs FluidAudio main, not B/cohere-coreml-asr (15-only)")
        XCTAssertTrue(content.contains("FluidAudio.git") && content.contains("branch: \"main\""))
    }

    func testMarketingVersionIsMontereyParity() throws {
        let pbx = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fluid.xcodeproj/project.pbxproj")
        let content = try String(contentsOf: pbx)
        XCTAssertFalse(content.contains("MARKETING_VERSION = 1.5.1"), "Monterey needs 1.6.10, not 1.5.1")
        XCTAssertTrue(content.contains("MARKETING_VERSION = 1.6.10"))
    }
}

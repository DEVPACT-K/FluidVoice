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
}

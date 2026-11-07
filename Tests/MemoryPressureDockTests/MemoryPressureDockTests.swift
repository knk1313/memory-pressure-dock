import XCTest
@testable import MemoryPressureDock

final class ProcessGroupingTests: XCTestCase {
    func testChromeHelperBelongsToOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(ProcessSampler.outermostAppBundle(in: path), "/Applications/Google Chrome.app")
    }

    func testAppMainExecutable() {
        XCTAssertEqual(ProcessSampler.outermostAppBundle(in: "/Applications/Safari.app/Contents/MacOS/Safari"),
                       "/Applications/Safari.app")
    }

    func testCommandLineToolIsNotGrouped() {
        XCTAssertNil(ProcessSampler.outermostAppBundle(in: "/opt/homebrew/bin/node"))
        XCTAssertNil(ProcessSampler.outermostAppBundle(in: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"))
    }

    func testSampleReturnsAtMostFiveSortedEntries() {
        let sample = ProcessSampler().sample(limit: 5)
        XCTAssertLessThanOrEqual(sample.top.count, 5)
        XCTAssertGreaterThan(sample.readableCount, 0)
        XCTAssertEqual(sample.top.map(\.bytes), sample.top.map(\.bytes).sorted(by: >))
    }
}

final class SystemReadingTests: XCTestCase {
    func testPressureLevelIsReadable() {
        XCTAssertNotEqual(MemoryPressureMonitor.readCurrent(), .unknown)
    }

    func testMemorySnapshot() {
        let snap = MemoryStats.read()
        XCTAssertNotNil(snap.total)
        XCTAssertNotNil(snap.used)
        XCTAssertNotNil(snap.swapUsed)
        if let used = snap.used, let total = snap.total { XCTAssertLessThanOrEqual(used, total) }
    }

    func testInterfaceCountersIncludeLoopback() {
        let counters = InterfaceCounters.read()
        XCTAssertNotNil(counters?["lo0"])
    }

    func testThroughputNeedsTwoSamples() {
        let sampler = ThroughputSampler()
        guard case .measuring = sampler.sample(interface: "lo0") else { return XCTFail("first sample should be measuring") }
        Thread.sleep(forTimeInterval: 0.3)
        guard case .rate(let r) = sampler.sample(interface: "lo0") else { return XCTFail("second sample should be a rate") }
        XCTAssertGreaterThanOrEqual(r.down, 0)
    }
}

final class ConnectivityCheckTests: XCTestCase {
    private func run(_ url: String, timeout: TimeInterval) -> ConnectivityCheck.Outcome? {
        let done = expectation(description: "check")
        var result: ConnectivityCheck.Outcome?
        ConnectivityCheck.run(url: URL(string: url)!, timeout: timeout) { result = $0; done.fulfill() }
        wait(for: [done], timeout: timeout + 5)
        return result
    }

    func testUnresolvableHostIsFailure() {
        guard case .failure(let reason)? = run("https://nonexistent.invalid/", timeout: 5) else { return XCTFail() }
        XCTAssertFalse(reason.isEmpty)
    }

    func testUnroutableAddressIsTimeout() {
        // 10.255.255.1 は通常応答しないアドレスで、接続の確立を待ち続ける
        guard case .timeout? = run("https://10.255.255.1/", timeout: 1) else { return XCTFail() }
    }
}

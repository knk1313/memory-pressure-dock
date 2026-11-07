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

final class SpeedTestParsingTests: XCTestCase {
    func testParsesThroughput() {
        let json = #"{"base_rtt":13.4,"dl_throughput":87642376,"ul_throughput":114280944,"test_endpoint":"jptyo5-edge.aaplimg.com"}"#
        let outcome = SpeedTest.parse(Data(json.utf8), exitCode: 0)
        XCTAssertEqual(outcome, .success(.init(downBitsPerSecond: 87642376, upBitsPerSecond: 114280944,
                                               baseRTTMilliseconds: 13.4, endpoint: "jptyo5-edge.aaplimg.com")))
    }

    func testOfflineErrorIsFailure() {
        let json = #"{"error_code":-1009,"error_domain":"NSURLErrorDomain"}"#
        XCTAssertEqual(SpeedTest.parse(Data(json.utf8), exitCode: 1), .failure("インターネットに接続されていません"))
    }

    func testBrokenOutputIsFailure() {
        guard case .failure = SpeedTest.parse(Data("oops".utf8), exitCode: 1) else { return XCTFail() }
    }

    func testFormatsMbps() {
        XCTAssertEqual(Format.bitsPerSecond(87_642_376), "87.6 Mbps")
        XCTAssertEqual(Format.bitsPerSecond(114_280_944), "114 Mbps")
    }
}

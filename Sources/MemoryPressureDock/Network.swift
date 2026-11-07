import CoreWLAN
import Darwin
import Foundation
import Network

struct NetworkStatus {
    enum State { case connected, disconnected, waiting }
    var state: State
    var kind: String          // 「Wi‑Fi」「有線LAN」など
    var interfaceName: String?
    var wifiName: String?     // 取得できない場合は nil（位置情報の許可が必要）
    var isExpensive: Bool

    var stateLabel: String {
        switch state {
        case .connected: return "接続中"
        case .disconnected: return "未接続"
        case .waiting: return "接続待ち"
        }
    }
}

/// パネルを開いている間だけ動かす。NWPathMonitor は再開できないため開くたびに作り直す。
final class NetworkStatusMonitor {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "network.path")

    func start(onUpdate: @escaping (NetworkStatus) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let status = Self.makeStatus(from: path)
            DispatchQueue.main.async { onUpdate(status) }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private static func makeStatus(from path: NWPath) -> NetworkStatus {
        let state: NetworkStatus.State
        switch path.status {
        case .satisfied: state = .connected
        case .requiresConnection: state = .waiting
        default: state = .disconnected
        }
        let primary = path.availableInterfaces.first
        let kind: String
        var wifiName: String?
        if state != .connected {
            kind = "—"
        } else if path.usesInterfaceType(.wifi) {
            kind = "Wi‑Fi"
            // macOS 14 以降は位置情報サービスの許可がないと nil になる。
            wifiName = CWWiFiClient.shared().interface()?.ssid()
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = "有線LAN"
        } else if path.usesInterfaceType(.cellular) {
            kind = "モバイル通信"
        } else {
            kind = "その他（VPN など）"
        }
        return NetworkStatus(state: state, kind: kind, interfaceName: primary?.name,
                             wifiName: wifiName, isExpensive: path.isExpensive)
    }
}

/// インターフェースの累計送受信バイト数（64bit カウンタ）。
enum InterfaceCounters {
    struct Counter { var received: UInt64; var sent: UInt64 }

    /// sysctl NET_RT_IFLIST2 から if_data64 を読む。失敗時は nil。
    static func read() -> [String: Counter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }

        var result: [String: Counter] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        result[name] = Counter(received: h2.ifm_data.ifi_ibytes, sent: h2.ifm_data.ifi_obytes)
                    }
                }
                offset += msgLen
            }
        }
        return result
    }
}

/// 前回の値との差分から、現在の下り・上り通信量（バイト/秒）を出す。
final class ThroughputSampler {
    struct Rate { var down: Double; var up: Double; var interface: String }
    private var last: (time: TimeInterval, counters: [String: InterfaceCounters.Counter])?

    func reset() { last = nil }

    enum Result { case measuring, unavailable, rate(Rate) }

    /// `interface` が nil の場合は loopback 以外の全インターフェースの合計を使う。
    func sample(interface: String?) -> Result {
        guard let now = InterfaceCounters.read() else { last = nil; return .unavailable }
        let t = ProcessInfo.processInfo.systemUptime
        defer { last = (t, now) }
        guard let prev = last, t - prev.time > 0.2 else { return .measuring }

        func total(_ c: [String: InterfaceCounters.Counter]) -> InterfaceCounters.Counter? {
            if let interface { return c[interface] }
            return c.filter { !$0.key.hasPrefix("lo") }.values
                .reduce(InterfaceCounters.Counter(received: 0, sent: 0)) {
                    .init(received: $0.received &+ $1.received, sent: $0.sent &+ $1.sent)
                }
        }
        guard let a = total(prev.counters), let b = total(now) else { return .unavailable }
        // カウンタのリセット（インターフェースの付け外し等）時は1回計測し直す。
        guard b.received >= a.received, b.sent >= a.sent else { return .measuring }
        let dt = t - prev.time
        return .rate(Rate(down: Double(b.received - a.received) / dt,
                          up: Double(b.sent - a.sent) / dt,
                          interface: interface ?? "全インターフェース"))
    }
}

/// 「接続を確認」ボタン用。押したときだけ、macOS 標準の `networkQuality` で下り・上りの回線速度を測る。
/// 測定先は Apple のサーバー（networkQuality の既定）。1回で数百MBの通信が発生する。
enum SpeedTest {
    static let tool = "/usr/bin/networkQuality"
    static let maxRuntime = 10          // networkQuality に渡す最大の測定時間（秒）
    static let timeout: TimeInterval = 30  // これを超えたら打ち切る（設定の取得や接続で詰まったとき）

    struct Result: Equatable {
        var downBitsPerSecond: Double
        var upBitsPerSecond: Double
        var baseRTTMilliseconds: Double?
        var endpoint: String?
    }

    enum Outcome: Equatable {
        case success(Result)
        case failure(String)
        case timeout
    }

    private static var running: Process?

    static func cancel() { running?.terminate() }

    static func run(completion: @escaping (Outcome) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            completion(.failure("networkQuality が見つかりません")); return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-c", "-M", String(maxRuntime)]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            var timedOut = false
            let watchdog = DispatchWorkItem { timedOut = true; process.terminate() }
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(.failure("測定を開始できません")) }
                return
            }
            DispatchQueue.main.async { running = process }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            let outcome: Outcome = timedOut ? .timeout : parse(data, exitCode: process.terminationStatus)
            DispatchQueue.main.async { running = nil; completion(outcome) }
        }
    }

    /// networkQuality -c の JSON を読む。速度の単位は bit/s。
    static func parse(_ data: Data, exitCode: Int32) -> Outcome {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(exitCode == 0 ? "測定結果を読めません" : "測定に失敗しました（終了コード \(exitCode)）")
        }
        if json["error_code"] != nil || json["error_domain"] != nil {
            return .failure(describeError(json))
        }
        guard let down = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (json["ul_throughput"] as? NSNumber)?.doubleValue else {
            return .failure("測定結果に速度がありません")
        }
        return .success(Result(downBitsPerSecond: down, upBitsPerSecond: up,
                               baseRTTMilliseconds: (json["base_rtt"] as? NSNumber)?.doubleValue,
                               endpoint: json["test_endpoint"] as? String))
    }

    private static func describeError(_ json: [String: Any]) -> String {
        let code = (json["error_code"] as? NSNumber)?.intValue
        let domain = json["error_domain"] as? String ?? ""
        if domain.contains("URL") || domain.contains("NSURLErrorDomain") {
            switch code {
            case -1009: return "インターネットに接続されていません"
            case -1001: return "測定先が応答しません"
            case -1003, -1006: return "名前解決に失敗しました"
            case -1004: return "測定先に接続できません"
            default: break
            }
        }
        if let code { return "測定に失敗しました（\(domain) \(code)）" }
        return "測定に失敗しました"
    }
}

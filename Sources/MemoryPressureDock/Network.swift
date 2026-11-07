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

/// 「接続を確認」ボタン用。押したときだけ1回リクエストする。
enum ConnectivityCheck {
    static let target = URL(string: "https://www.apple.com/library/test/success.html")!
    static let timeout: TimeInterval = 5

    enum Outcome {
        case success(milliseconds: Int, httpStatus: Int)
        case failure(String)
        case timeout
    }

    static func run(url: URL = target, timeout: TimeInterval = timeout, completion: @escaping (Outcome) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let start = DispatchTime.now()
        let task = session.dataTask(with: request) { _, response, error in
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let outcome: Outcome
            if let error = error as? URLError {
                switch error.code {
                case .timedOut: outcome = .timeout
                case .notConnectedToInternet: outcome = .failure("インターネットに接続されていません")
                case .cannotFindHost, .dnsLookupFailed: outcome = .failure("名前解決に失敗しました")
                case .cannotConnectToHost: outcome = .failure("測定先に接続できません")
                case .networkConnectionLost: outcome = .failure("通信が途中で切れました")
                case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                    outcome = .failure("安全な接続を確立できません")
                default: outcome = .failure(error.localizedDescription)
                }
            } else if let error {
                outcome = .failure(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                outcome = (200..<400).contains(http.statusCode)
                    ? .success(milliseconds: ms, httpStatus: http.statusCode)
                    : .failure("HTTP \(http.statusCode) が返りました")
            } else {
                outcome = .failure("応答を解釈できません")
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { completion(outcome) }
        }
        task.resume()
    }
}

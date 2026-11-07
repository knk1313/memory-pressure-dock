import AppKit
import Darwin

struct ProcessEntry: Identifiable {
    let id: String          // 集約キー（.app のパス）または "pid:<pid>"
    let name: String
    let bytes: UInt64       // phys_footprint（アクティビティモニタの「メモリ」と同じ指標）
    let processCount: Int
    let isAggregatedApp: Bool
}

struct ProcessSample {
    let top: [ProcessEntry]
    let readableCount: Int
    let unreadableCount: Int   // 権限がなく使用量を読めなかったプロセス数
}

/// プロセスごとのメモリ使用量を集計する。重い処理なのでバックグラウンドで呼ぶ。
///
/// 集約ルール: 実行ファイルのパスが `xxx.app/` の内側にあるプロセスは、
/// パス上で最も外側の `.app` に属すると判定する（例: Chrome のヘルパーは
/// `/Applications/Google Chrome.app/Contents/Frameworks/.../Helpers/...` にある）。
/// それ以外（CLI、システムの XPC サービスなど）は所属を確実に判定できないので個別に扱う。
final class ProcessSampler {
    private var nameCache: [String: String] = [:]

    func sample(limit: Int = 5) -> ProcessSample {
        let pids = Self.allPIDs()
        var groups: [String: (name: String, bytes: UInt64, count: Int, isApp: Bool)] = [:]
        var readable = 0
        var unreadable = 0

        for pid in pids where pid > 0 {
            guard let footprint = Self.footprint(of: pid) else { unreadable += 1; continue }
            readable += 1
            let path = Self.executablePath(of: pid)
            if let path, let bundle = Self.outermostAppBundle(in: path) {
                let name = appName(for: bundle)
                var g = groups[bundle] ?? (name, 0, 0, true)
                g.bytes += footprint
                g.count += 1
                groups[bundle] = g
            } else {
                let name = path.map { ($0 as NSString).lastPathComponent } ?? Self.shortName(of: pid) ?? "PID \(pid)"
                groups["pid:\(pid)"] = (name, footprint, 1, false)
            }
        }

        let top = groups
            .map { ProcessEntry(id: $0.key, name: $0.value.name, bytes: $0.value.bytes, processCount: $0.value.count, isAggregatedApp: $0.value.isApp) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
        return ProcessSample(top: Array(top), readableCount: readable, unreadableCount: unreadable)
    }

    private func appName(for bundlePath: String) -> String {
        if let cached = nameCache[bundlePath] { return cached }
        let name = FileManager.default.displayName(atPath: bundlePath)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        nameCache[bundlePath] = name
        return name
    }

    static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<path.index(range.lowerBound, offsetBy: 4)])
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
        }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private static func shortName(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}

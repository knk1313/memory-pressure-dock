import Darwin

/// nil は「取得できません」を意味し、計測値の 0 と区別する。
struct MemorySnapshot {
    var total: UInt64?
    var used: UInt64?
    var compressed: UInt64?
    var swapUsed: UInt64?
    var swapTotal: UInt64?
}

enum MemoryStats {
    private static let host = mach_host_self()

    static func read() -> MemorySnapshot {
        var snap = MemorySnapshot()

        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 { snap.total = memsize }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // アクティビティモニタの「使用済みメモリ」に合わせる: App メモリ + 確保されているメモリ + 圧縮
            let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            let wired = UInt64(stats.wire_count)
            let compressed = UInt64(stats.compressor_page_count)
            snap.used = (app + wired + compressed) * page
            snap.compressed = compressed * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            snap.swapUsed = swap.xsu_used
            snap.swapTotal = swap.xsu_total
        }
        return snap
    }
}

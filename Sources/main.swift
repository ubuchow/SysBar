import AppKit
import CoreText
import Darwin
import IOKit.ps
import SystemConfiguration

// SysBar — 极轻量菜单栏系统状态（目标：空闲物理占用贴近 AppKit 下限）

private enum C {
    static let name = "SysBar"
    static let panelW: CGFloat = 400
    static let panelH: CGFloat = 688
    static let panelCornerRadius: CGFloat = 20
}

// MARK: - Font
// 衬线：优先 Claude 的 Anthropic Serif，本机没有则用宋体-简。数字等宽。

private enum Theme {
    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let names: [String]
        switch weight {
        case .bold, .semibold, .medium:
            names = ["Anthropic Serif Medium", "AnthropicSerif-Medium", "SongtiSC-Bold", "STSongti-SC-Bold"]
        default:
            names = ["Anthropic Serif", "AnthropicSerif-Regular", "SongtiSC-Regular", "STSongti-SC-Regular"]
        }
        var base = NSFont(name: "Songti SC", size: size) ?? .systemFont(ofSize: size, weight: weight)
        for name in names {
            if let font = NSFont(name: name, size: size) {
                base = font
                break
            }
        }
        let song = NSFontDescriptor(fontAttributes: [.name: "STSongti-SC-Regular"])
        let features: [[NSFontDescriptor.FeatureKey: Any]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let desc = base.fontDescriptor.addingAttributes([
            .cascadeList: [song],
            .featureSettings: features,
        ])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    /// 面板稿面：拉丁用 Times，中文落到宋体。数字按稿面用比例字体。
    static func display(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let bold = weight >= .medium
        let name = bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT"
        let base = NSFont(name: name, size: size)
            ?? NSFont(name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size)
            ?? .systemFont(ofSize: size, weight: weight)
        let song = NSFontDescriptor(fontAttributes: [.name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"])
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: [song]])
        return NSFont(descriptor: desc, size: size) ?? base
    }
}

private struct Palette {
    let bg: NSColor
    let card: NSColor
    let line: NSColor
    let text: NSColor
    let secondary: NSColor
    let tertiary: NSColor
    let down: NSColor
    let up: NSColor
    let button: NSColor
    let buttonText: NSColor
    let rust: NSColor
    let track: NSColor
    let ink: NSColor

    static func current(dark: Bool) -> Palette {
        if dark {
            return Palette(
                bg: NSColor(srgbRed: 0.133, green: 0.129, blue: 0.118, alpha: 1),
                card: NSColor(srgbRed: 0.176, green: 0.173, blue: 0.157, alpha: 1),
                line: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
                text: NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1),
                secondary: NSColor(srgbRed: 0.733, green: 0.718, blue: 0.663, alpha: 1),
                tertiary: NSColor(srgbRed: 0.58, green: 0.565, blue: 0.51, alpha: 1),
                down: NSColor(srgbRed: 0.545, green: 0.710, blue: 0.580, alpha: 1),
                up: NSColor(srgbRed: 0.863, green: 0.545, blue: 0.400, alpha: 1),
                button: NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1),
                buttonText: NSColor(srgbRed: 0.133, green: 0.129, blue: 0.118, alpha: 1),
                rust: NSColor(srgbRed: 0.863, green: 0.545, blue: 0.400, alpha: 1),
                track: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
                ink: NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1)
            )
        }
        return Palette(
            bg: NSColor(srgbRed: 0.980, green: 0.973, blue: 0.953, alpha: 1),
            card: NSColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 1),
            line: NSColor(srgbRed: 0.10, green: 0.09, blue: 0.07, alpha: 0.12),
            text: NSColor(srgbRed: 0.090, green: 0.082, blue: 0.070, alpha: 1),
            secondary: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.36, alpha: 1),
            tertiary: NSColor(srgbRed: 0.58, green: 0.55, blue: 0.50, alpha: 1),
            down: NSColor(srgbRed: 0.22, green: 0.45, blue: 0.33, alpha: 1),
            up: NSColor(srgbRed: 0.72, green: 0.34, blue: 0.26, alpha: 1),
            button: NSColor(srgbRed: 0.090, green: 0.082, blue: 0.070, alpha: 1),
            buttonText: NSColor(srgbRed: 0.980, green: 0.973, blue: 0.953, alpha: 1),
            rust: NSColor(srgbRed: 0.72, green: 0.34, blue: 0.26, alpha: 1),
            track: NSColor(srgbRed: 0.89, green: 0.87, blue: 0.83, alpha: 1),
            ink: NSColor(srgbRed: 0.10, green: 0.09, blue: 0.08, alpha: 1)
        )
    }
}

// MARK: - Metrics / Sampler（复用缓冲，少分配）

private struct Metrics {
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSys: Double = 0
    /// 读不到传感器时为 -1
    var cpuTempC: Double = -1
    var memPct: Double = 0
    var memPressure: String = "正常"
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
    var memSwapGB: Double = 0
    var memReclaimGB: Double = 0
    var down: Double = 0
    var up: Double = 0
    /// 当前默认路由的线路名，如 VPN / en0
    var route: String = "—"
    var diskFreeGB: Double = 0
    var diskTotalGB: Double = 0
    var uptime: String = "—"
    var batteryPct: Int = -1
    var batteryState: String = "—"
    var procCount: Int = 0
    var threadCount: Int = 0
    var model: String = "Mac"
}

private final class Sampler {
    private let host = mach_host_self()
    private var prevCPU = host_cpu_load_info()
    private var haveCPU = false
    /// 默认线路上次的 64 位累计字节（避免 getifaddrs 的 32 位回绕）
    private var prevRoute = ""
    private var prevBytes: (in: UInt64, out: UInt64)?
    private var prevT: CFAbsoluteTime = 0
    private var lastDown: Double = 0
    private var lastUp: Double = 0
    private var pidBuf = [pid_t]()
    private var tick: UInt64 = 0

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample(fullProcs: Bool) -> Metrics {
        var m = Metrics()
        m.model = Self.modelName
        cpu(&m)
        m.cpuTempC = TempSensor.celsius() ?? -1
        mem(&m)
        net(&m)
        disk(&m)
        m.uptime = uptimeString()
        battery(&m)
        // 轻量采样隔次统计进程，打开面板完成时补齐线程数。
        tick &+= 1
        if fullProcs || tick % 2 == 0 {
            processCount(&m, withThreads: fullProcs || tick % 4 == 0)
        }
        return m
    }

    private static let modelName: String = {
        if let raw = productName() {
            let families = ["MacBook Pro", "MacBook Air", "MacBook", "Mac mini", "Mac Studio", "Mac Pro", "iMac"]
            for name in families where raw.contains(name) { return name }
            let trimmed = raw.split(separator: "(").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            if !trimmed.isEmpty { return trimmed }
        }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 1 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(cString: buf)
        let pairs = [
            ("MacBookPro", "MacBook Pro"),
            ("MacBookAir", "MacBook Air"),
            ("Macmini", "Mac mini"),
            ("iMac", "iMac"),
            ("MacPro", "Mac Pro"),
            ("MacStudio", "Mac Studio"),
        ]
        for (prefix, name) in pairs where model.contains(prefix) { return name }
        return "Mac"
    }()

    /// 设备树 product-name，例如 “MacBook Air (13-inch, M3, 2024)”。
    private static func productName() -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("product"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let text = raw as? String { return text }
        if let data = raw as? Data,
           let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        }
        return nil
    }

    private func cpu(_ m: inout Metrics) {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        defer { prevCPU = info; haveCPU = true }
        guard haveCPU else { return }
        let u = Double(info.cpu_ticks.0 &- prevCPU.cpu_ticks.0)
        let s = Double(info.cpu_ticks.1 &- prevCPU.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prevCPU.cpu_ticks.2)
        let n = Double(info.cpu_ticks.3 &- prevCPU.cpu_ticks.3)
        let total = u + s + idle + n
        guard total > 0 else { return }
        m.cpu = min(100, max(0, (u + s + n) / total * 100))
        m.cpuUser = min(100, max(0, (u + n) / total * 100))
        m.cpuSys = min(100, max(0, s / total * 100))
    }

    private func mem(_ m: inout Metrics) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64()
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        var total: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &len, nil, 0)
        let page = UInt64(vm_kernel_page_size)
        guard kr == KERN_SUCCESS, total > 0 else { return }
        let used = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        let gb = 1_073_741_824.0
        m.memUsedGB = Double(used) / gb
        m.memTotalGB = Double(total) / gb
        m.memPct = Double(used) / Double(total) * 100
        let reclaim = (UInt64(vm.purgeable_count) + UInt64(vm.external_page_count)) * page
        m.memReclaimGB = Double(reclaim) / gb
        var swap = xsw_usage()
        var slen = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &slen, nil, 0) == 0 {
            m.memSwapGB = Double(swap.xsu_used) / gb
        }
        // 空闲页在 macOS 上经常接近 0，不能拿它当压力。用内核的 memorystatus 档位。
        var level: Int32 = 0
        var llen = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &llen, nil, 0) == 0 {
            if level >= 4 { m.memPressure = "紧张" }
            else if level >= 2 { m.memPressure = "偏高" }
            else { m.memPressure = "正常" }
        } else if m.memPct > 90 {
            m.memPressure = "紧张"
        } else if m.memPct > 75 {
            m.memPressure = "偏高"
        } else {
            m.memPressure = "正常"
        }
    }

    /// 通过 NET_RT_IFLIST2 读取 if_data64（64 位累计字节），按网卡名返回
    private func linkCounters() -> [String: (in: UInt64, out: UInt64)]? {
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        let hdrSize = MemoryLayout<if_msghdr2>.size
        var result: [String: (in: UInt64, out: UInt64)] = [:]
        var off = 0
        while off + 4 <= len {
            let msglen = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt16.self) })
            guard msglen > 0, off + msglen <= len else { break }
            let type = buf[off + 3]
            if type == UInt8(RTM_IFINFO2), msglen >= hdrSize {
                let msg = buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: if_msghdr2.self) }
                let flags = msg.ifm_flags
                let sdlOff = off + hdrSize
                if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                   sdlOff + 8 <= off + msglen,
                   buf[sdlOff + 1] == UInt8(AF_LINK) {
                    let nlen = Int(buf[sdlOff + 5])
                    let nameStart = sdlOff + 8
                    if nlen > 0, nameStart + nlen <= off + msglen {
                        let name = String(decoding: buf[nameStart..<(nameStart + nlen)], as: UTF8.self)
                        result[name] = (msg.ifm_data.ifi_ibytes, msg.ifm_data.ifi_obytes)
                    }
                }
            }
            off += msglen
        }
        return result
    }

    /// 系统当前默认路由的接口。VPN 开启时是 utun，而不是底下的 en0。
    private func primaryInterface(among counters: [String: (in: UInt64, out: UInt64)]) -> String {
        if let store = SCDynamicStoreCreate(nil, "SysBar" as CFString, nil, nil),
           let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let name = dict["PrimaryInterface"] as? String,
           counters[name] != nil {
            return name
        }
        return counters.max { $0.value.in &+ $0.value.out < $1.value.in &+ $1.value.out }?.key ?? ""
    }

    private func routeTitle(_ name: String) -> String {
        if name.isEmpty { return "—" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN" }
        if name.hasPrefix("bridge") { return "网桥" }
        if name.hasPrefix("awdl") { return "隔空" }
        return name
    }

    private func net(_ m: inout Metrics) {
        guard let counters = linkCounters() else { return }
        let name = primaryInterface(among: counters)
        m.route = routeTitle(name)
        let now = CFAbsoluteTimeGetCurrent()
        guard let cur = counters[name] else {
            m.down = 0
            m.up = 0
            return
        }
        // 换线路时只建基线，避免把两张网卡的计数差算成速度
        guard name == prevRoute, let prev = prevBytes, prevT > 0 else {
            prevRoute = name
            prevBytes = cur
            prevT = now
            lastDown = 0
            lastUp = 0
            m.down = 0
            m.up = 0
            return
        }
        let dt = now - prevT
        guard dt >= 0.25 else {
            m.down = lastDown
            m.up = lastUp
            return
        }
        let dIn = cur.in >= prev.in ? cur.in - prev.in : 0
        let dOut = cur.out >= prev.out ? cur.out - prev.out : 0
        prevBytes = cur
        prevT = now
        m.down = Double(dIn) / dt
        m.up = Double(dOut) / dt
        lastDown = m.down
        lastUp = m.up
    }

    private func disk(_ m: inout Metrics) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return }
        let gb = 1_073_741_824.0
        if let free = attrs[.systemFreeSize] as? NSNumber {
            m.diskFreeGB = free.doubleValue / gb
        }
        if let total = attrs[.systemSize] as? NSNumber {
            m.diskTotalGB = total.doubleValue / gb
        }
    }

    /// 只数存活进程，不做 Top 内存排序（省 CPU / 内存）
    private func processCount(_ m: inout Metrics, withThreads: Bool) {
        let type = UInt32(PROC_ALL_PIDS)
        let need = proc_listpids(type, 0, nil, 0)
        guard need > 0 else { return }
        let nMax = Int(need) / MemoryLayout<pid_t>.size
        if pidBuf.count < nMax { pidBuf = [pid_t](repeating: 0, count: nMax) }
        let filled = proc_listpids(type, 0, &pidBuf, Int32(pidBuf.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return }
        let n = Int(filled) / MemoryLayout<pid_t>.size
        var alive = 0
        var threads = 0
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        for i in 0..<n where pidBuf[i] > 0 {
            alive += 1
            if withThreads {
                var info = proc_taskinfo()
                let sz = proc_pidinfo(pidBuf[i], PROC_PIDTASKINFO, 0, &info, taskSize)
                if sz == taskSize { threads += Int(info.pti_threadnum) }
            }
        }
        m.procCount = alive
        if withThreads { m.threadCount = threads }
    }

    private func uptimeString() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "—" }
        let up = max(0, Int(Date().timeIntervalSince1970 - Double(boot.tv_sec)))
        let d = up / 86400, h = (up % 86400) / 3600, mi = (up % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(mi) 分钟" }
        return "\(mi) 分钟"
    }

    private func battery(_ m: inout Metrics) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return }
        let cur = desc[kIOPSCurrentCapacityKey] as? Int
        let maxv = desc[kIOPSMaxCapacityKey] as? Int
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powered = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        guard let cur, let maxv, maxv > 0 else { return }
        m.batteryPct = Int(round(Double(cur) / Double(maxv) * 100))
        if charging { m.batteryState = "充电中" }
        else if powered { m.batteryState = "已接电源" }
        else { m.batteryState = "使用电池" }
    }
}

// MARK: - CPU 温度（IOHID，读不到就留空）

private enum TempSensor {
    private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create: CreateFn? = load("IOHIDEventSystemClientCreate")
    private static let copyServices: CopyServicesFn? = load("IOHIDEventSystemClientCopyServices")
    private static let copyEvent: CopyEventFn? = load("IOHIDServiceClientCopyEvent")
    private static let getFloat: GetFloatFn? = load("IOHIDEventGetFloatValue")
    private static var client: UnsafeMutableRawPointer?

    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private static func load<T>(_ name: String) -> T? {
        guard let lib, let sym = dlsym(lib, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static func celsius() -> Double? {
        guard let create, let copyServices, let copyEvent, let getFloat else { return nil }
        if client == nil { client = create(kCFAllocatorDefault) }
        guard let client, let services = copyServices(client)?.takeRetainedValue() else { return nil }
        var best: Double?
        let field = Int32(15 << 16)
        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let event = copyEvent(UnsafeMutableRawPointer(mutating: service), 15, 0, 0) else { continue }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
            let c = normalize(getFloat(event, field))
            if let c, best == nil || c > best! { best = c }
        }
        return best
    }

    static func releaseClient() {
        guard let client else { return }
        Unmanaged<AnyObject>.fromOpaque(client).release()
        self.client = nil
    }

    private static func normalize(_ v: Double) -> Double? {
        if v >= 20, v <= 120 { return v }
        if v >= 250, v <= 400 { return v - 273.15 }
        if v >= 2000, v <= 12000 { return v / 100 }
        return nil
    }
}

// MARK: - Format

/// 网速：按采样间隔的真实字节/秒，1024 进位，不再抹成 0 或取整到整数。
private func fmtBps(_ b: Double) -> String {
    let x = max(0, b)
    if x < 1 { return "0 B/s" }
    if x < 1024 { return String(format: "%.0f B/s", x) }
    if x < 1024 * 1024 {
        let kb = x / 1024
        return kb < 100 ? String(format: "%.1f KB/s", kb) : String(format: "%.0f KB/s", kb)
    }
    if x < 1024 * 1024 * 1024 {
        let mb = x / (1024 * 1024)
        if mb < 10 { return String(format: "%.2f MB/s", mb) }
        if mb < 100 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f MB/s", mb)
    }
    return String(format: "%.2f GB/s", x / (1024 * 1024 * 1024))
}

private func fmtGB(_ g: Double) -> String {
    g >= 10 ? String(format: "%.1f GB", g) : String(format: "%.2f GB", g)
}

private func fmtBytes(_ b: Int64) -> String {
    let x = Double(max(0, b))
    if x < 1024 * 1024 { return String(format: "%.0f KB", x / 1024) }
    if x < 1_073_741_824 { return String(format: "%.0f MB", x / (1024 * 1024)) }
    let gb = x / 1_073_741_824
    return gb < 10 ? String(format: "%.1f GB", gb) : String(format: "%.0f GB", gb)
}

private func fmtParts(_ b: Double) -> (num: String, unit: String) {
    let x = max(0, b)
    if x < 1024 { return (x < 1 ? "0" : String(format: "%.0f", x), "B/s") }
    if x < 1024 * 1024 {
        let kb = x / 1024
        let num = kb < 10 ? String(format: "%.1f", kb) : String(format: "%.0f", kb)
        return (num, "KB/s")
    }
    if x < 1024 * 1024 * 1024 {
        let mb = x / (1024 * 1024)
        let num = mb < 10 ? String(format: "%.2f", mb) : (mb < 100 ? String(format: "%.1f", mb) : String(format: "%.0f", mb))
        return (num, "MB/s")
    }
    return (String(format: "%.2f", x / 1_073_741_824), "GB/s")
}

private var groupFmt: NumberFormatter?

private func grouped(_ n: Int) -> String {
    if groupFmt == nil {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        groupFmt = formatter
    }
    return groupFmt!.string(from: NSNumber(value: n)) ?? "\(n)"
}

// MARK: - Icon（与 AI Credits 同族：单环 + Times 字母，单色描边）

private enum MenuIcon {
    /// 与轻量日历 / FlashFind / AI Credits 同径（17pt），线宽 1.45
    private static let badge: CGFloat = 17.0
    private static let ringWidth: CGFloat = 1.45
    private static let ringColor = NSColor.white
    private static let letterColor = NSColor(srgbRed: 0.98, green: 0.82, blue: 0.22, alpha: 1)

    static func image() -> NSImage {
        let width = badge
        let height = badge
        let image = NSImage(size: NSSize(width: width, height: height))
        for scale in [1, 2, 3] as [CGFloat] {
            let pxW = Int((width * scale).rounded())
            let pxH = Int((height * scale).rounded())
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pxW,
                pixelsHigh: pxH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = NSSize(width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                ctx.imageInterpolation = .high
                ctx.shouldAntialias = true
                NSColor.clear.setFill()
                NSRect(x: 0, y: 0, width: width, height: height).fill()
                draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        return image
    }

    private static func timesBold(_ size: CGFloat) -> NSFont {
        for name in ["TimesNewRomanPS-BoldMT", "Times New Roman Bold", "Times-Bold", "TimesNewRomanPSMT"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: .bold)
    }

    private static func draw(in rect: NSRect) {
        let badgeY = ((rect.height - badge) * 0.5).rounded()
        let badgeRect = NSRect(x: (rect.width - badge) * 0.5, y: badgeY, width: badge, height: badge)
        drawRing(color: ringColor, badgeRect: badgeRect)
        drawCentered(
            "S",
            font: timesBold(9),
            color: letterColor,
            center: NSPoint(x: badgeRect.midX, y: badgeRect.midY)
        )
    }

    private static func drawRing(color: NSColor, badgeRect: NSRect) {
        let inset = ringWidth * 0.5 + 0.15
        let ring = NSBezierPath(ovalIn: badgeRect.insetBy(dx: inset, dy: inset))
        ring.lineWidth = ringWidth
        ring.lineCapStyle = .round
        ring.lineJoinStyle = .round
        color.setStroke()
        ring.stroke()
    }


    private static func drawCentered(
        _ s: String,
        font: NSFont,
        color: NSColor,
        center: NSPoint
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Trash / Memory clean

private enum TrashCleaner {
    /// 清空废纸篓。
    /// 新系统 TCC 禁止进程直读 ~/.Trash，须经 Finder（首次会请求「自动化」权限）。
    static func empty(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 尝试 FileManager（少数环境可直删）
            let (deleted, failed) = emptyViaFileManager()
            if deleted > 0 {
                DispatchQueue.main.async {
                    completion(true, failed == 0 ? "已清空 \(deleted) 项" : "已删 \(deleted)，失败 \(failed)")
                }
                return
            }

            // 2) 经 Finder（可靠路径）
            let r = emptyViaFinder()
            DispatchQueue.main.async {
                switch r {
                case .ok:
                    completion(true, "废纸篓已清空")
                case .alreadyEmpty:
                    completion(true, "废纸篓已是空的")
                case .cancelled:
                    completion(false, "已取消")
                case .needAutomation:
                    completion(false, "请允许 SysBar 控制「访达」：系统设置 → 隐私与安全性 → 自动化")
                case .failed(let msg):
                    completion(false, msg.isEmpty ? "清空失败" : msg)
                }
            }
        }
    }

    private static func emptyViaFileManager() -> (deleted: Int, failed: Int) {
        let fm = FileManager.default
        var dirs = fm.urls(for: .trashDirectory, in: .userDomainMask)
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true))
        let uid = getuid()
        if let vols = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for v in vols {
                let t = v.appendingPathComponent(".Trashes/\(uid)", isDirectory: true)
                if fm.fileExists(atPath: t.path) { dirs.append(t) }
            }
        }
        var seen = Set<String>()
        var deleted = 0, failed = 0
        for dir in dirs where seen.insert(dir.standardizedFileURL.path).inserted {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                do {
                    try fm.removeItem(at: item)
                    deleted += 1
                } catch {
                    failed += 1
                }
            }
        }
        return (deleted, failed)
    }

    /// 顶层项数 + 文件占用。读不到废纸篓（TCC）时返回 nil，不弹授权框。
    static func snapshot() -> (count: Int, bytes: Int64)? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .trashDirectory, in: .userDomainMask).first,
              let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return nil }
        var bytes: Int64 = 0
        var seen = 0
        if let en = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in en {
                seen += 1
                if seen > 30000 { break }
                let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey])
                if vals?.isRegularFile == true {
                    bytes += Int64(vals?.fileAllocatedSize ?? 0)
                }
            }
        }
        return (items.count, bytes)
    }

    private enum FinderResult {
        case ok, alreadyEmpty, cancelled, needAutomation, failed(String)
    }

    private static func emptyViaFinder() -> FinderResult {
        // 注意：新版 macOS 无 warns before emptying trash 属性；空篓时 empty 会 -128
        let script = """
        tell application "Finder"
            try
                set n to (count of items of trash)
                if n is 0 then return "EMPTY"
                empty trash
                return "OK"
            on error errMsg number errNum
                return "ERR:" & errNum & ":" & errMsg
            end try
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
            let text = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errText = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = text.isEmpty ? errText : text

            if combined == "EMPTY" { return .alreadyEmpty }
            if combined == "OK" || (proc.terminationStatus == 0 && combined.isEmpty) { return .ok }
            if combined.hasPrefix("ERR:") {
                let body = String(combined.dropFirst(4))
                return classifyFinderError(body)
            }
            if proc.terminationStatus != 0 {
                return classifyFinderError(combined)
            }
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func classifyFinderError(_ body: String) -> FinderResult {
        let lower = body.lowercased()
        if body.contains("-1743") || lower.contains("not authorized") || lower.contains("not allowed")
            || body.contains("不允许") || body.contains("未授权") || body.contains("-1744") {
            return .needAutomation
        }
        if body.contains("-1728") {
            return .alreadyEmpty
        }
        if body.contains("-128") || lower.contains("user canceled") || body.contains("取消") {
            // 空篓时部分系统 empty 也会 -128；再查一次数量
            if finderTrashCount() == 0 { return .alreadyEmpty }
            return .cancelled
        }
        return .failed(body)
    }

    private static func finderTrashCount() -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Finder\" to count items of trash"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let t = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int(t) ?? -1
        } catch {
            return -1
        }
    }
}

private enum MemoryCleaner {
    private static let sudoersPath = "/etc/sudoers.d/sysbar-purge"
    private static let purgePath = "/usr/sbin/purge"

    static var isPasswordless: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", purgePath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    static func free(completion: @escaping (Bool, String) -> Void) {
        malloc_zone_pressure_relief(nil, 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if runPurge(n: true) {
                DispatchQueue.main.async { completion(true, "已清理缓存（免密）") }
                return
            }
            let user = NSUserName()
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard user.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                DispatchQueue.main.async { completion(false, "无法识别用户名") }
                return
            }
            let line = "\(user) ALL=(root) NOPASSWD: \(purgePath)"
            let script = "do shell script \"echo '\(line)' > \(sudoersPath) && chmod 0440 \(sudoersPath) && \(purgePath)\" with administrator privileges"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            do {
                try proc.run(); proc.waitUntilExit()
                DispatchQueue.main.async {
                    if proc.terminationStatus == 0 {
                        completion(true, "已清理，并完成首次授权")
                    } else {
                        completion(false, "已取消或授权失败")
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    private static func runPurge(n: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = n ? ["-n", purgePath] : [purgePath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }
}

// MARK: - 缓动

private func easeOutCubic(_ t: CGFloat) -> CGFloat {
    let u = 1 - t
    return 1 - u * u * u
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

// MARK: - 单画布面板。玻璃模式下不铺实色底，让 NSGlassEffectView 透出桌面。

private final class Canvas: NSView {
    /// 为真时不画不透明底，轨道和次按钮改成半透明。
    var usesGlass = false
    /// 目标指标
    private var target = Metrics()
    /// 显示用平滑值
    private var dCPU: Double = 0
    private var dUser: Double = 0
    private var dSys: Double = 0
    private var dMem: Double = 0
    private var dDisk: Double = 0
    private var dProcs: Double = 0
    private var dThreads: Double = 0
    private var pressure = "正常"
    private var uptime = "—"

    var hint = ""
    var trashCount = -1
    var trashBytes: Int64 = -1
    var onFree: (() -> Void)?
    var onTrash: (() -> Void)?
    var onActivity: (() -> Void)?
    var onPrefs: (() -> Void)?

    private var freeRect = NSRect.zero
    private var trashRect = NSRect.zero
    private var activityRect = NSRect.zero
    private var prefsRect = NSRect.zero
    private var hoverFree = false
    private var hoverTrash = false
    private var hoverActivity = false
    private var hoverPrefs = false
    private var pressFree = false
    private var pressTrash = false
    private var pressActivity = false
    private var pressPrefs = false

    /// 入场 0→1
    private var appear: CGFloat = 0
    private var appearStart: CFAbsoluteTime = 0
    private var animating = false
    private var animTimer: Timer?

    // 网速原始字节/秒，画的时候再归一
    private var sparkDown = [CGFloat](repeating: 0, count: 36)
    private var sparkUp = [CGFloat](repeating: 0, count: 36)
    private var sparkI = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !usesGlass }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { animTimer?.invalidate() }

    func startLife() {
        appear = 0
        appearStart = CFAbsoluteTimeGetCurrent()
        dCPU = 0; dUser = 0; dSys = 0; dMem = 0; dDisk = 0; dProcs = 0; dThreads = 0
        startAnim()
    }

    func stopLife() {
        animTimer?.invalidate()
        animTimer = nil
        animating = false
    }

    private func startAnim() {
        animTimer?.invalidate()
        animating = true
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickAnim()
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func tickAnim() {
        let now = CFAbsoluteTimeGetCurrent()
        let raw = CGFloat(min(1, (now - appearStart) / 0.28))
        appear = easeOutCubic(raw)

        let k = 0.18
        dCPU = lerp(dCPU, target.cpu, k)
        dUser = lerp(dUser, target.cpuUser, k)
        dSys = lerp(dSys, target.cpuSys, k)
        dMem = lerp(dMem, target.memPct, k)
        dDisk = lerp(dDisk, target.diskFreeGB, k)
        dProcs = lerp(dProcs, Double(target.procCount), k)
        dThreads = lerp(dThreads, Double(target.threadCount), k)

        let moving =
            abs(dCPU - target.cpu) > 0.2
            || abs(dMem - target.memPct) > 0.2
            || appear < 0.999
        if moving || appear < 1 {
            needsDisplay = true
        }
        if !moving, appear >= 1 {
            // 降到约 2fps 只刷时钟，网速不再空转
            if animTimer?.timeInterval ?? 1 < 0.4 {
                animTimer?.invalidate()
                let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.tickAnim()
                }
                t.tolerance = 0.1
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
            // 慢帧也更新时钟
            needsDisplay = true
        }
    }

    func apply(_ m: Metrics) {
        var next = m
        // 稀疏采样时保留上次进程数，避免闪 0
        if next.procCount == 0, target.procCount > 0 {
            next.procCount = target.procCount
        }
        if next.threadCount == 0, target.threadCount > 0 {
            next.threadCount = target.threadCount
        }

        target = next
        pressure = target.memPressure
        uptime = target.uptime
        sparkDown[sparkI] = CGFloat(max(0, target.down))
        sparkUp[sparkI] = CGFloat(max(0, target.up))
        sparkI = (sparkI + 1) % sparkDown.count

        if !animating {
            startAnim()
        } else if let t = animTimer, t.timeInterval > 0.2 {
            startAnim()
        }
        needsDisplay = true
    }

    private func palette() -> Palette {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Palette.current(dark: dark)
    }

    // MARK: Draw

    override func draw(_ dirty: NSRect) {
        let p = palette()
        if !usesGlass {
            p.bg.setFill()
            bounds.fill()
        }

        let pad: CGFloat = 22
        let right = bounds.width - pad
        let innerW = right - pad

        drawTracked("SYSTEM", at: NSPoint(x: pad, y: 18), size: 11, kern: 1.4, color: p.rust)
        let sysW = ("SYSTEM" as NSString).size(withAttributes: [
            .font: Theme.display(11, weight: .medium), .kern: 1.4,
        ]).width
        drawText(" · 状态", at: NSPoint(x: pad + sysW, y: 18), font: Theme.display(12), color: p.rust)

        drawText("系统状态", at: NSPoint(x: pad, y: 42), font: Theme.display(30, weight: .medium), color: p.text)
        drawClock(right: right, y: 38, p: p)

        let sub = Theme.display(12.5)
        drawText("\(target.model)  ·  已运行 \(uptime)", at: NSPoint(x: pad, y: 90), font: sub, color: p.secondary)
        drawRight("打开时刷新", right: right, y: 90, font: sub, color: p.tertiary)

        rule(114, pad: pad, color: p.line)

        let colW = (innerW - 28) / 2
        let rightX = pad + colW + 28
        spread("CPU", zh: "处理器", x: pad, right: pad + colW, y: 130, color: p.tertiary)
        spread("MEMORY", zh: "内存", x: rightX, right: right, y: 130, color: p.tertiary)

        let numEnd = drawStat(String(format: "%.0f", dCPU), unit: "%", x: pad, y: 152,
                              valueSize: 48, unitSize: 18, color: p.text, unitColor: p.tertiary)
        _ = numEnd
        let memWidth = drawStat(String(format: "%.0f", dMem), unit: "%", x: rightX, y: 152,
                                valueSize: 48, unitSize: 18, color: p.text, unitColor: p.tertiary)
        if pressure != "正常" {
            drawPill(pressure, x: rightX + memWidth + 8, y: 162, color: p.rust)
        }

        drawBlocks(ratio: dCPU / 100, in: NSRect(x: pad, y: 214, width: colW, height: 11),
                   filled: p.ink, empty: trackColor(p))
        drawBlocks(ratio: dMem / 100, in: NSRect(x: rightX, y: 214, width: colW, height: 11),
                   filled: p.ink, empty: trackColor(p))

        let meta = Theme.display(12.5)
        drawText("用户 \(Int(dUser.rounded()))  ·  系统 \(Int(dSys.rounded()))",
                 at: NSPoint(x: pad, y: 234), font: meta, color: p.secondary)
        if target.cpuTempC > 0 {
            drawRight(String(format: "%.0f°C", target.cpuTempC), right: pad + colW, y: 234,
                      font: meta, color: p.secondary)
        }
        let used = String(format: "%.1f", target.memUsedGB)
        let total = target.memTotalGB >= 10
            ? String(format: "%.0f", target.memTotalGB)
            : String(format: "%.1f", target.memTotalGB)
        drawText("\(used) / \(total) GB", at: NSPoint(x: rightX, y: 234), font: meta, color: p.secondary)
        drawRight(String(format: "交换 %.1f GB", target.memSwapGB), right: right, y: 234,
                  font: meta, color: p.tertiary)

        rule(264, pad: pad, color: p.line)

        let route = target.route == "—" ? "NETWORK" : "NETWORK  ·  \(target.route)"
        spread(route, zh: "网络", x: pad, right: right, y: 280, color: p.tertiary)

        let down = fmtParts(target.down)
        let up = fmtParts(target.up)
        drawRate(arrow: "↓", num: down.num, unit: down.unit, x: pad, y: 306, color: p.down, p: p)
        let upX = pad + innerW * 0.46
        drawRate(arrow: "↑", num: up.num, unit: up.unit, x: upX, y: 306, color: p.up, p: p)

        drawChart(in: NSRect(x: pad, y: 352, width: innerW, height: 92), p: p)

        rule(458, pad: pad, color: p.line)

        let trioY: CGFloat = 474
        let trioW = innerW / 3
        drawTrioLabel("进程", x: pad, y: trioY, color: p.tertiary)
        drawText(grouped(Int(dProcs.rounded())), at: NSPoint(x: pad, y: trioY + 22),
                 font: Theme.display(28), color: p.text)
        drawText("线程 \(grouped(Int(dThreads.rounded())))", at: NSPoint(x: pad, y: trioY + 58),
                 font: meta, color: p.secondary)

        let diskX = pad + trioW
        drawTrioLabel("磁盘可用", x: diskX, y: trioY, color: p.tertiary)
        let freeNum = String(format: "%.1f", dDisk)
        let freeW = drawStat(freeNum, unit: "GB", x: diskX, y: trioY + 20,
                             valueSize: 28, unitSize: 14, color: p.text, unitColor: p.tertiary)
        _ = freeW
        let barW = trioW - 28
        let usedRatio: Double = {
            guard target.diskTotalGB > 1 else { return 0 }
            return min(1, max(0, 1 - target.diskFreeGB / target.diskTotalGB))
        }()
        drawThinBar(ratio: usedRatio, in: NSRect(x: diskX, y: trioY + 62, width: barW, height: 5), p: p)

        let batX = pad + trioW * 2
        drawTrioLabel("电池", x: batX, y: trioY, color: p.tertiary)
        if target.batteryPct >= 0 {
            let bw = drawStat("\(target.batteryPct)", unit: "%", x: batX, y: trioY + 20,
                              valueSize: 28, unitSize: 14, color: p.text, unitColor: p.tertiary)
            drawBattery(pct: target.batteryPct, in: NSRect(x: batX + bw + 8, y: trioY + 28, width: 26, height: 14), color: p.text)
            drawText(target.batteryState, at: NSPoint(x: batX, y: trioY + 58), font: meta, color: p.secondary)
        } else {
            drawText("—", at: NSPoint(x: batX, y: trioY + 22), font: Theme.display(28), color: p.text)
        }

        p.line.setFill()
        NSRect(x: diskX - 14, y: trioY, width: 1, height: 72).fill()
        NSRect(x: batX - 14, y: trioY, width: 1, height: 72).fill()

        rule(562, pad: pad, color: p.line)

        let gap: CGFloat = 10
        let btnW = (innerW - gap) / 2
        let btnH: CGFloat = 64
        freeRect = NSRect(x: pad, y: 578, width: btnW, height: btnH)
        trashRect = NSRect(x: pad + btnW + gap, y: 578, width: btnW, height: btnH)
        let reclaim = target.memReclaimGB >= 0.05
            ? String(format: "约可释放 %.1f GB", target.memReclaimGB)
            : "释放不活跃缓存"
        let trashSub: String = {
            guard trashCount >= 0 else { return "清空访达废纸篓" }
            return "\(grouped(trashCount)) 项  ·  \(fmtBytes(trashBytes))"
        }()
        drawAction(title: "释放缓存", subtitle: hint.isEmpty ? reclaim : hint,
                   rect: freeRect, hover: hoverFree, pressed: pressFree, primary: true, p: p)
        drawAction(title: "清空回收站", subtitle: trashSub,
                   rect: trashRect, hover: hoverTrash, pressed: pressTrash, primary: false, p: p)

        let foot = Theme.display(12.5)
        let act = "活动监视器  ↗"
        let actW = (act as NSString).size(withAttributes: [.font: foot]).width
        activityRect = NSRect(x: pad, y: 656, width: actW, height: 18)
        let actColor = hoverActivity ? p.text : p.secondary
        drawText(act, at: NSPoint(x: pad, y: 656), font: foot, color: actColor)

        let pref = "偏好设置"
        let key = "⌘,"
        let prefFont = foot
        let keyFont = Theme.display(11)
        let prefW = (pref as NSString).size(withAttributes: [.font: prefFont]).width
        let keyW = (key as NSString).size(withAttributes: [.font: keyFont]).width
        let prefX = right - prefW - keyW - 16
        prefsRect = NSRect(x: prefX, y: 654, width: prefW + keyW + 16, height: 20)
        drawText(pref, at: NSPoint(x: prefX, y: 656), font: prefFont, color: hoverPrefs ? p.text : p.secondary)
        let keyRect = NSRect(x: right - keyW - 10, y: 654, width: keyW + 10, height: 18)
        let keyPath = NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4)
        trackColor(p).setFill()
        keyPath.fill()
        drawText(key, at: NSPoint(x: keyRect.minX + 5, y: keyRect.minY + 1), font: keyFont, color: p.secondary)
    }

    private func rule(_ y: CGFloat, pad: CGFloat, color: NSColor) {
        color.setFill()
        NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 1).fill()
    }

    private func drawText(_ s: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (s as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawRight(_ s: String, right: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        drawText(s, at: NSPoint(x: right - w, y: y), font: font, color: color)
    }

    private func drawTracked(_ s: String, at point: NSPoint, size: CGFloat, kern: CGFloat, color: NSColor) {
        let font = Theme.display(size, weight: .medium)
        (s as NSString).draw(at: point, withAttributes: [
            .font: font, .foregroundColor: color, .kern: kern,
        ])
    }

    private func spread(_ en: String, zh: String, x: CGFloat, right: CGFloat, y: CGFloat, color: NSColor) {
        drawTracked(en, at: NSPoint(x: x, y: y), size: 11, kern: 1.3, color: color)
        drawRight(zh, right: right, y: y, font: Theme.display(12), color: color)
    }

    private func drawTrioLabel(_ s: String, x: CGFloat, y: CGFloat, color: NSColor) {
        drawText(s, at: NSPoint(x: x, y: y), font: Theme.display(12), color: color)
    }

    @discardableResult
    private func drawStat(_ value: String, unit: String, x: CGFloat, y: CGFloat,
                          valueSize: CGFloat, unitSize: CGFloat,
                          color: NSColor, unitColor: NSColor) -> CGFloat {
        let vf = Theme.display(valueSize)
        let uf = Theme.display(unitSize)
        drawText(value, at: NSPoint(x: x, y: y), font: vf, color: color)
        let vw = (value as NSString).size(withAttributes: [.font: vf]).width
        let dy = max(0, vf.ascender - uf.ascender)
        drawText(unit, at: NSPoint(x: x + vw + 3, y: y + dy * 0.15), font: uf, color: unitColor)
        return vw + 3 + (unit as NSString).size(withAttributes: [.font: uf]).width
    }

    private func drawPill(_ title: String, x: CGFloat, y: CGFloat, color: NSColor) {
        let font = Theme.display(11, weight: .medium)
        let sz = (title as NSString).size(withAttributes: [.font: font])
        let rect = NSRect(x: x, y: y, width: sz.width + 16, height: 20)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
        drawText(title, at: NSPoint(x: rect.minX + 8, y: rect.minY + 2), font: font, color: color)
    }

    private func drawBlocks(ratio: Double, in rect: NSRect, filled: NSColor, empty: NSColor) {
        let count = 28
        let gap: CGFloat = 3
        let bw = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let n = Int((min(1, max(0, ratio)) * Double(count)).rounded())
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * (bw + gap)
            let r = NSRect(x: x, y: rect.minY, width: max(1, bw), height: rect.height)
            let path = NSBezierPath(roundedRect: r, xRadius: 1.6, yRadius: 1.6)
            (i < n ? filled : empty).setFill()
            path.fill()
        }
    }

    /// 玻璃上的空槽用淡色，避免奶油色块挡住透出的桌面。
    private func trackColor(_ p: Palette) -> NSColor {
        guard usesGlass else { return p.track }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.18 : 0.10)
    }

    private func drawThinBar(ratio: Double, in rect: NSRect, p: Palette) {
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        trackColor(p).setFill()
        track.fill()
        var fill = rect
        fill.size.width = rect.width * CGFloat(min(1, max(0, ratio)))
        if fill.width > 2 {
            p.ink.setFill()
            NSBezierPath(roundedRect: fill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
    }

    private func drawRate(arrow: String, num: String, unit: String, x: CGFloat, y: CGFloat, color: NSColor, p: Palette) {
        let af = Theme.display(16, weight: .medium)
        let nf = Theme.display(28)
        let uf = Theme.display(13)
        drawText(arrow, at: NSPoint(x: x, y: y + 8), font: af, color: color)
        let aw = (arrow as NSString).size(withAttributes: [.font: af]).width
        drawText(num, at: NSPoint(x: x + aw + 4, y: y), font: nf, color: color)
        let nw = (num as NSString).size(withAttributes: [.font: nf]).width
        drawText(unit, at: NSPoint(x: x + aw + 8 + nw, y: y + 10), font: uf, color: p.tertiary)
    }

    private func drawChart(in rect: NSRect, p: Palette) {
        let grid = NSBezierPath()
        grid.lineWidth = 1
        grid.setLineDash([1.5, 3], count: 2, phase: 0)
        p.line.setStroke()
        for i in 0..<3 {
            let y = rect.minY + rect.height * CGFloat(i + 1) / 4
            grid.move(to: NSPoint(x: rect.minX, y: y))
            grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        grid.stroke()

        let n = sparkDown.count
        guard n > 1 else { return }
        var peak: CGFloat = 1
        for i in 0..<n {
            peak = max(peak, sparkDown[i], sparkUp[i])
        }
        func point(_ series: [CGFloat], _ i: Int) -> NSPoint {
            let v = series[(sparkI + i) % n] / peak
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n - 1)
            let y = rect.maxY - 6 - v * (rect.height - 12)
            return NSPoint(x: x, y: y)
        }
        let area = NSBezierPath()
        let down = NSBezierPath()
        let up = NSBezierPath()
        for i in 0..<n {
            let d = point(sparkDown, i)
            let u = point(sparkUp, i)
            if i == 0 {
                area.move(to: NSPoint(x: d.x, y: rect.maxY))
                area.line(to: d)
                down.move(to: d)
                up.move(to: u)
            } else {
                area.line(to: d)
                down.line(to: d)
                up.line(to: u)
            }
        }
        area.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        area.close()
        p.down.withAlphaComponent(0.14).setFill()
        area.fill()
        down.lineWidth = 1.6
        down.lineJoinStyle = .round
        down.lineCapStyle = .round
        p.down.setStroke()
        down.stroke()
        up.lineWidth = 1.6
        up.lineJoinStyle = .round
        up.lineCapStyle = .round
        p.up.setStroke()
        up.stroke()
        for (series, color) in [(sparkDown, p.down), (sparkUp, p.up)] {
            let pt = point(series, n - 1)
            let dot = NSBezierPath(ovalIn: NSRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7))
            let hole = usesGlass
                ? NSColor(calibratedWhite: 1, alpha: 0.55)
                : p.bg
            hole.setFill()
            dot.fill()
            color.setStroke()
            dot.lineWidth = 1.6
            dot.stroke()
        }
    }

    private func drawBattery(pct: Int, in rect: NSRect, color: NSColor) {
        let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width - 3, height: rect.height)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.2
        color.setStroke()
        outline.stroke()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX, y: body.midY - 2.5, width: 2, height: 5),
                     xRadius: 0.6, yRadius: 0.6).fill()
        let inner = body.insetBy(dx: 2, dy: 2)
        var level = inner
        level.size.width = inner.width * CGFloat(min(100, max(0, pct))) / 100
        if level.width > 0.5 {
            NSBezierPath(rect: level).fill()
        }
    }

    private func drawAction(title: String, subtitle: String, rect: NSRect,
                            hover: Bool, pressed: Bool, primary: Bool, p: Palette) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        let titleFont = Theme.display(16, weight: .medium)
        let subFont = Theme.display(12)
        let titleColor: NSColor
        let subColor: NSColor
        if primary {
            var fill = p.button
            if pressed { fill = p.button.withAlphaComponent(0.82) }
            else if hover { fill = p.button.withAlphaComponent(0.92) }
            fill.setFill()
            path.fill()
            titleColor = p.buttonText
            subColor = p.buttonText.withAlphaComponent(0.62)
        } else if usesGlass {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alpha: CGFloat = pressed ? 0.10 : (hover ? 0.30 : 0.18)
            NSColor(calibratedWhite: dark ? 1 : 1, alpha: alpha).setFill()
            path.fill()
            NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.28 : 0.14).setStroke()
            path.lineWidth = 1
            path.stroke()
            titleColor = pressed ? p.secondary : p.text
            subColor = p.tertiary
        } else {
            p.bg.setFill()
            path.fill()
            let border = hover || pressed ? p.secondary.withAlphaComponent(0.55) : p.line
            border.setStroke()
            path.lineWidth = 1.25
            path.stroke()
            titleColor = pressed ? p.secondary : p.text
            subColor = p.tertiary
        }
        let tw = (title as NSString).size(withAttributes: [.font: titleFont])
        let sw = (subtitle as NSString).size(withAttributes: [.font: subFont])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: 12, dy: 8)).addClip()
        drawText(title, at: NSPoint(x: rect.midX - tw.width / 2, y: rect.midY - 18),
                 font: titleFont, color: titleColor)
        drawText(subtitle, at: NSPoint(x: rect.midX - sw.width / 2, y: rect.midY + 4),
                 font: subFont, color: subColor)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawClock(right: CGFloat, y: CGFloat, p: Palette) {
        let c = Calendar.current
        let now = Date()
        let hm = String(format: "%02d:%02d", c.component(.hour, from: now), c.component(.minute, from: now))
        let ss = String(format: ":%02d", c.component(.second, from: now))
        let big = Theme.display(42)
        let small = Theme.display(20)
        let hmSize = (hm as NSString).size(withAttributes: [.font: big])
        let ssSize = (ss as NSString).size(withAttributes: [.font: small])
        let x = right - hmSize.width - ssSize.width
        drawText(hm, at: NSPoint(x: x, y: y), font: big, color: p.text)
        drawText(ss, at: NSPoint(x: x + hmSize.width, y: y + hmSize.height - ssSize.height - 2),
                 font: small, color: p.secondary)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressFree = freeRect.contains(p)
        pressTrash = trashRect.contains(p)
        pressActivity = activityRect.contains(p)
        pressPrefs = prefsRect.contains(p)
        if pressFree || pressTrash || pressActivity || pressPrefs { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pressFree, freeRect.contains(p) { onFree?() }
        if pressTrash, trashRect.contains(p) { onTrash?() }
        if pressActivity, activityRect.contains(p) { onActivity?() }
        if pressPrefs, prefsRect.contains(p) { onPrefs?() }
        pressFree = false
        pressTrash = false
        pressActivity = false
        pressPrefs = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hf = freeRect.contains(p)
        let ht = trashRect.contains(p)
        let ha = activityRect.contains(p)
        let hp = prefsRect.contains(p)
        if hf != hoverFree || ht != hoverTrash || ha != hoverActivity || hp != hoverPrefs {
            hoverFree = hf
            hoverTrash = ht
            hoverActivity = ha
            hoverPrefs = hp
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverFree = false
        hoverTrash = false
        hoverActivity = false
        hoverPrefs = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    var currentMemUsedGB: Double { target.memUsedGB }

    func prefsAnchor() -> NSPoint {
        NSPoint(x: prefsRect.minX, y: prefsRect.maxY)
    }
}

// MARK: - 玻璃面板

@available(macOS 26.0, *)
private final class GlassShell: NSView {
    let glass = NSGlassEffectView()

    init(canvas: Canvas) {
        super.init(frame: NSRect(x: 0, y: 0, width: C.panelW, height: C.panelH))
        wantsLayer = true
        layer?.cornerRadius = C.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = C.panelCornerRadius
        glass.style = .regular
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        glass.contentView = canvas
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.contentView?.frame = glass.bounds
    }
}

private final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 面板弹出。只改 origin 和透明度，初速不为 0，避免第一帧停住再猛地到位。
private final class PanelMotion {
    private var timer: Timer?
    private var window: NSWindow?
    private var x: CGFloat = 0
    private var restY: CGFloat = 0
    private var fromY: CGFloat = 0
    private var outY: CGFloat = 0
    private var y0: Double = 0
    private var v0: Double = 0
    private let omega: Double = 15.5
    private let zeta: Double = 0.70
    private var animT: Double = 0
    private var lastFrame: CFAbsoluteTime = 0
    private(set) var dismissing = false
    private var onDone: (() -> Void)?

    func cancel() {
        timer?.invalidate()
        timer = nil
        onDone = nil
        window = nil
        dismissing = false
    }

    func springIn(window: NSWindow, rest: NSRect, done: @escaping () -> Void) {
        cancel()
        self.window = window
        x = rest.origin.x
        restY = rest.origin.y
        y0 = Double(window.frame.origin.y - rest.origin.y)
        v0 = 240
        dismissing = false
        onDone = done
        begin()
    }

    func easeOut(window: NSWindow, distance: CGFloat, done: @escaping () -> Void) {
        cancel()
        self.window = window
        x = window.frame.origin.x
        fromY = window.frame.origin.y
        outY = fromY - distance
        dismissing = true
        onDone = done
        begin()
    }

    private func begin() {
        animT = 0
        lastFrame = CFAbsoluteTimeGetCurrent()
        arm()
    }

    private func arm() {
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let window else { return }
        let now = CFAbsoluteTimeGetCurrent()
        var dt = now - lastFrame
        lastFrame = now
        if dt < 0 { dt = 0 }
        // 主线程偶发卡住时不要把整段弹簧一次跳完。
        if dt > 0.05 { dt = 0.05 }
        animT += dt
        let t = animT
        if dismissing {
            let p = min(1, t / 0.16)
            let e = p * p * (3 - 2 * p)
            let y = fromY + (outY - fromY) * e
            window.setFrameOrigin(NSPoint(x: x, y: y))
            window.alphaValue = CGFloat(1 - e)
            if p >= 1 { finish() }
            return
        }
        let y = offset(t)
        window.setFrameOrigin(NSPoint(x: x, y: restY + CGFloat(y)))
        let fade = min(1, t / 0.10)
        let s = fade * fade * (3 - 2 * fade)
        window.alphaValue = CGFloat(0.72 + 0.28 * s)
        if t >= 0.48 || (t >= 0.34 && abs(y) < 0.35) {
            finish()
        }
    }

    /// 欠阻尼，带向上的初速。y 是相对落点的位移。
    private func offset(_ t: Double) -> Double {
        let wd = omega * sqrt(max(0, 1 - zeta * zeta))
        guard wd > 0 else { return 0 }
        let decay = exp(-zeta * omega * t)
        return decay * (y0 * cos(wd * t) + ((v0 + zeta * omega * y0) / wd) * sin(wd * t))
    }

    private func finish() {
        let window = self.window
        let done = onDone
        let closing = dismissing
        let endY = closing ? outY : restY
        cancel()
        if !closing {
            window?.setFrameOrigin(NSPoint(x: x, y: endY))
            window?.alphaValue = 1
            window?.invalidateShadow()
        }
        done?()
    }
}

// MARK: - App

private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var panel: NSPanel?
    private let sampler = Sampler()
    private var canvas: Canvas?
    private var outside: Any?
    private var keys: Any?
    private var lastMem: Double = 0
    /// 刚打开时忽略落在状态图标上的点击，避免同一次点击把面板立刻关掉。
    private var ignoreOutsideUntil: CFAbsoluteTime = 0
    private let motion = PanelMotion()

    private var isOpen: Bool {
        if let panel, panel.isVisible { return true }
        return popover.isShown
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = MenuIcon.image()
            btn.imagePosition = .imageOnly
            // 不缩小绘制，与系统菜单栏符号体量一致
            btn.imageScaling = .scaleNone
            btn.toolTip = C.name
            btn.target = self
            btn.action = #selector(toggle(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        // 系统弹出动画 + 内部自绘入场，观感更顺
        popover.animates = true
        popover.delegate = self
    }

    private func ensurePanel() {
        if canvas != nil { return }
        let c = Canvas(frame: NSRect(x: 0, y: 0, width: C.panelW, height: C.panelH))
        c.onFree = { [weak self] in self?.runFree() }
        c.onTrash = { [weak self] in self?.runTrash() }
        c.onActivity = {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
        c.onPrefs = { [weak self] in self?.showQuitMenu() }
        canvas = c
        if #available(macOS 26.0, *) {
            c.usesGlass = true
            let shell = GlassShell(canvas: c)
            panel = makeGlassPanel(shell)
        } else {
            let vc = NSViewController()
            vc.view = c
            vc.preferredContentSize = NSSize(width: C.panelW, height: C.panelH)
            popover.contentViewController = vc
            popover.contentSize = NSSize(width: C.panelW, height: C.panelH)
        }
    }

    private func makeGlassPanel(_ content: NSView) -> NSPanel {
        let panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: C.panelW, height: C.panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .readOnly
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = content
        return panel
    }

    private func releasePanel() {
        canvas?.stopLife()
        panel?.orderOut(nil)
        panel = nil
        popover.contentViewController = nil
        canvas = nil
        TempSensor.releaseClient()
        groupFmt = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    @objc private func toggle(_ sender: Any?) {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "显示面板", action: #selector(showPanel), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "退出 \(C.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = m
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if isOpen {
            closePanel()
        } else {
            showPanel()
        }
    }

    @objc private func showPanel() {
        guard let btn = item.button else { return }
        ensurePanel()
        canvas?.startLife()
        let opening = sampler.sample(fullProcs: false)
        lastMem = opening.memUsedGB
        canvas?.apply(opening)
        if let panel {
            place(panel, under: btn)
            let end = panel.frame
            var start = end
            start.origin.y -= 38
            panel.setFrame(start, display: false)
            panel.alphaValue = 0.72
            panel.orderFrontRegardless()
            panel.makeKey()
            // 线程数统计很重，等落稳后再做，避免弹出时跳帧。
            motion.springIn(window: panel, rest: end) { [weak self] in
                self?.tick(full: true)
            }
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
        refreshTrash()
        ignoreOutsideUntil = CFAbsoluteTimeGetCurrent() + 0.3
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if CFAbsoluteTimeGetCurrent() < self.ignoreOutsideUntil { return }
            if self.clickHitsStatusItem() { return }
            self.closePanel()
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "," else { return event }
            self?.showQuitMenu()
            return nil
        }
    }

    private func refreshTrash() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = TrashCleaner.snapshot()
            DispatchQueue.main.async {
                guard let canvas = self?.canvas else { return }
                if let snap {
                    canvas.trashCount = snap.count
                    canvas.trashBytes = snap.bytes
                } else {
                    canvas.trashCount = -1
                    canvas.trashBytes = -1
                }
                canvas.needsDisplay = true
            }
        }
    }

    private func showQuitMenu() {
        guard let canvas else { return }
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出 \(C.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: quit, at: canvas.prefsAnchor(), in: canvas)
    }


    private func tick(full: Bool) {
        let m = sampler.sample(fullProcs: full)
        lastMem = m.memUsedGB
        canvas?.apply(m)
    }

    private func runFree() {
        canvas?.hint = MemoryCleaner.isPasswordless ? "正在释放…" : "首次需密码，之后免密"
        canvas?.needsDisplay = true
        let before = lastMem
        MemoryCleaner.free { [weak self] ok, msg in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let after = self.sampler.sample(fullProcs: false)
                self.lastMem = after.memUsedGB
                self.canvas?.apply(after)
                if ok, before > after.memUsedGB {
                    self.canvas?.hint = "\(msg) · 约 \(fmtGB(before - after.memUsedGB))"
                } else {
                    self.canvas?.hint = msg
                }
                self.canvas?.needsDisplay = true
            }
        }
    }

    private func runTrash() {
        canvas?.hint = "正在清空…"
        canvas?.needsDisplay = true
        TrashCleaner.empty { [weak self] ok, msg in
            self?.canvas?.hint = msg
            self?.canvas?.needsDisplay = true
            if ok {
                self?.tick(full: false)
                self?.refreshTrash()
            }
        }
    }

    private func place(_ panel: NSPanel, under btn: NSStatusBarButton) {
        guard let window = btn.window else { return }
        let anchor = window.convertToScreen(btn.convert(btn.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 8)
        let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if vis.width > 1 {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            if origin.y < vis.minY + 8 {
                origin.y = anchor.maxY + 8
            }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func clickHitsStatusItem() -> Bool {
        guard let btn = item.button, let window = btn.window else { return false }
        let rect = window.convertToScreen(btn.convert(btn.bounds, to: nil)).insetBy(dx: -6, dy: -6)
        return rect.contains(NSEvent.mouseLocation)
    }

    private func closePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let panel, panel.isVisible, !motion.dismissing else { return }
        motion.easeOut(window: panel, distance: 14) { [weak self] in
            self?.finishClose()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        tick(full: true)
    }

    func popoverDidClose(_ notification: Notification) {
        finishClose()
    }

    private func finishClose() {
        motion.cancel()
        if let mon = outside {
            NSEvent.removeMonitor(mon)
            outside = nil
        }
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
        releasePanel()
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

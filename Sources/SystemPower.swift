import Foundation
import IOKit

/// Live power draw of the whole Mac (screen, chip, memory, SSD, Wi-Fi…), in watts.
/// Primary source: the SMC key "PSTR" (system total power, updated every second — what tools like Stats show).
/// Fallback: the battery controller's telemetry, which only updates every 20–60 s.
enum SystemPower {
    static func watts() -> Double? { SMC.shared.float("PSTR").flatMap { $0 > 0 ? $0 : nil } ?? batteryWatts() }

    static func batteryWatts() -> Double? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let t = IORegistryEntryCreateCFProperty(svc, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        func mw(_ k: String) -> Double { (t[k] as? NSNumber)?.doubleValue ?? 0 }
        let load = mw("SystemLoad") > 0 ? mw("SystemLoad") : mw("BatteryPower")
        return load > 0 ? load / 1000 : nil
    }
}

/// Minimal read-only access to the System Management Controller.
final class SMC: @unchecked Sendable {
    static let shared = SMC()

    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private struct Param {   // matches the kernel's SMCKeyData_t (80 bytes)
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var pLimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]
    private let lock = NSLock()

    private init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        if IOServiceOpen(svc, mach_task_self_, 0, &conn) != KERN_SUCCESS { conn = 0 }
        IOObjectRelease(svc)
    }

    private func call(_ p: inout Param) -> Bool {
        var out = Param(), size = MemoryLayout<Param>.stride
        guard IOConnectCallStructMethod(conn, 2, &p, MemoryLayout<Param>.stride, &out, &size) == KERN_SUCCESS,
              out.result == 0 else { return false }
        p = out
        return true
    }

    /// Reads a key of type "flt " (32-bit float).
    func float(_ name: String) -> Double? {
        if TestSwitch.noSMC { return nil }
        lock.lock(); defer { lock.unlock() }
        guard conn != 0 else { return nil }
        let key = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var info = infoCache[key]
        if info == nil {
            var p = Param(); p.key = key; p.data8 = 9          // get key info
            guard call(&p) else { return nil }
            info = p.keyInfo; infoCache[key] = info
        }
        guard let info, info.dataType == 0x666C7420 /* "flt " */ else { return nil }
        var p = Param(); p.key = key; p.keyInfo = info; p.data8 = 5   // read bytes
        guard call(&p) else { return nil }
        let v = withUnsafeBytes(of: p.bytes) { $0.load(as: Float.self) }
        return v.isFinite ? Double(v) : nil
    }
}

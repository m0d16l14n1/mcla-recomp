// This Mac and its screens: what the launcher shows and suggests from.

import AppKit
import IOKit

struct MacInfo {
    let chip: String          // "Apple M5"
    let gpuCores: Int?
    let memoryGB: Int
    let model: String         // "Mac16,12"

    static let current: MacInfo = {
        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
            return String(cString: buf)
        }
        var cores: Int?
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                if cores == nil,
                   let v = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber {
                    cores = v.intValue
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        let memory = Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30)
        return MacInfo(chip: sysctlString("machdep.cpu.brand_string"), gpuCores: cores, memoryGB: memory,
                       model: sysctlString("hw.model"))
    }()

    /// A rough GPU class from the core count: the base chips have 7 to 10 cores, Pro 14 to 20, Max 30 to 40,
    /// Ultra 48 and up.
    enum Tier: Int, Comparable {
        case base = 0, pro, max, ultra
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
        var name: String {
            switch self {
            case .base: return "base chip"
            case .pro: return "Pro"
            case .max: return "Max"
            case .ultra: return "Ultra"
            }
        }
    }

    var tier: Tier {
        if let g = gpuCores {
            if g >= 48 { return .ultra }
            if g >= 28 { return .max }
            if g >= 14 { return .pro }
            return .base
        }
        if chip.contains("Ultra") { return .ultra }
        if chip.contains("Max") { return .max }
        if chip.contains("Pro") { return .pro }
        return .base
    }

    /// The chip's generation (M1 = 1), 0 when it can't be told.
    var generation: Int {
        guard let r = chip.range(of: #"M(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(chip[r].dropFirst()) ?? 0
    }
}

struct ScreenInfo: Identifiable {
    let index: Int            // 1-based, the game's monitor option (the order macOS lists screens)
    let name: String
    let points: CGSize
    let pixels: CGSize
    let refresh: Int
    let edr: CGFloat          // the most it can show above SDR white (1 = no EDR)
    let builtIn: Bool
    var id: Int { index }

    var summary: String {
        var s = "\(Int(pixels.width))×\(Int(pixels.height))"
        if refresh > 0 { s += ", \(refresh) Hz" }
        if edr > 1.01 { s += ", HDR (EDR \(String(format: "%.0f", edr))x)" }
        return s
    }

    static func all() -> [ScreenInfo] {
        NSScreen.screens.enumerated().map { i, screen in
            let scale = screen.backingScaleFactor
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            var pixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            }
            return ScreenInfo(index: i + 1, name: screen.localizedName, points: screen.frame.size, pixels: pixels,
                              refresh: screen.maximumFramesPerSecond,
                              edr: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                              builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }
}

/// What the launcher suggests for this Mac and a screen. Measured on an M5 (10-core GPU): about 90 FPS in the
/// city with MetalFX Performance, about 60 with MSAA at the game's own 1280×720. The rest is scaled from the
/// GPU's size and is an estimate, said as one.
struct Suggestion {
    let antiAliasing: String  // mcla_anti_aliasing
    let upscaling: String     // mcla_upscaling
    let fps: Int
    let why: String

    static func make(mac: MacInfo, screen: ScreenInfo?) -> Suggestion {
        let refresh = screen?.refresh ?? 60
        // Base chips before the M3 have the least GPU: MetalFX Performance and 30 to 60.
        if mac.tier == .base && mac.generation > 0 && mac.generation < 3 {
            return Suggestion(antiAliasing: "fsr", upscaling: "performance", fps: refresh >= 60 ? 60 : 30,
                              why: "An \(mac.chip) has a small GPU: MetalFX Performance keeps the frame rate up. "
                                 + "If it can't hold 60, set the cap to 30, as on the console.")
        }
        if mac.tier == .base {
            return Suggestion(antiAliasing: "fsr", upscaling: "performance", fps: 60,
                              why: "Measured on an M5 MacBook Air with MetalFX Performance: about 90 FPS in the city when "
                                 + "cool, 45 to 57 in a race once it is warm (a fanless Mac slows down as it heats). For "
                                 + "the smoothest motion there, turn on frame generation: 30 drawn, 60 shown.")
        }
        // The game's command thread takes about 8 ms of CPU a frame on an M5, so even a big GPU tops out near
        // 110 FPS: 60 is the steady choice, and a 120 Hz screen shows 60 evenly.
        let note = refresh >= 120 ? " A 120 Hz screen can take a higher cap, but the CPU side stops near 110 FPS." : ""
        if mac.tier == .pro {
            return Suggestion(antiAliasing: "fsr", upscaling: "quality", fps: 60,
                              why: "A Pro chip has about twice an M5's GPU (an estimate, not measured): MetalFX at a "
                                 + "higher quality fits." + note)
        }
        return Suggestion(antiAliasing: "fsr", upscaling: "ultra_quality", fps: 60,
                          why: "A \(mac.tier.name) chip has GPU to spare (an estimate, not measured): MetalFX at its "
                             + "best quality." + note)
    }
}

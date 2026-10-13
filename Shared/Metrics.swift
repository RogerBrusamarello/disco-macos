import Foundation
import Darwin

/// Leituras usadas tanto pelo widget quanto pela barra de menus.
enum Metrics {
    static func disk() -> (total: Int64, free: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// "Memória usada" igual ao Monitor de Atividade: memória de apps + residente + comprimida.
    /// pressure = kern.memorystatus_vm_pressure_level: 1 normal, 2 alerta, 4 crítica.
    static func memory() -> (total: Int64, used: Int64, pressure: Int32) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used: Int64 = 0
        if result == KERN_SUCCESS {
            let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            used = (appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * Int64(vm_kernel_page_size)
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return (total, used, level)
    }
}

private let ptBR = Locale(identifier: "pt_BR")

/// Disco em base 10, como o Finder (245 GB).
func gb(_ bytes: Int64) -> String {
    let v = Double(bytes) / 1_000_000_000
    return v.formatted(.number.precision(.fractionLength(v >= 100 ? 0 : 1)).locale(ptBR))
}

/// RAM é medida em potência de 2 (16 GB = 16 × 1024³).
func ramGB(_ bytes: Int64) -> String {
    (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)).locale(ptBR))
}

func ramLabel(_ bytes: Int64) -> String {
    bytes >= 1_073_741_824 ? "\(ramGB(bytes)) GB" : "\(bytes / 1_048_576) MB"
}

func pressureLabel(_ level: Int32) -> String {
    switch level {
    case 4: "pressão crítica"
    case 2: "pressão alta"
    default: "pressão normal"
    }
}

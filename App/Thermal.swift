import Foundation
import IOKit
import SwiftUI

/// Temperatura do Mac lida dos sensores do chip (Apple Silicon), sem sudo.
/// Usa o IOHIDEventSystem, o mesmo caminho de apps como o Stats; as funções são privadas do IOKit,
/// então são carregadas em tempo de execução: se sumirem num macOS futuro, a temperatura só não aparece.
enum Thermal {
    struct Reading {
        /// Maior temperatura dos núcleos (sensores "tdie"/"tdev" do PMU), em °C.
        let cpu: Double?
        /// Bateria, quando o Mac tem uma.
        let battery: Double?
        let state: ProcessInfo.ThermalState
    }

    static func read() -> Reading {
        var cpu: [Double] = []
        var battery: Double?
        for (name, value) in sensors() where value > 0 && value < 130 {
            let lower = name.lowercased()
            if lower.hasPrefix("pmu tdie") || lower.hasPrefix("pmu tdev") || lower.hasPrefix("pmu2 tdie") {
                cpu.append(value)
            } else if lower.contains("battery") {
                battery = max(battery ?? 0, value)
            }
        }
        return Reading(cpu: cpu.max(), battery: battery, state: ProcessInfo.processInfo.thermalState)
    }

    // MARK: IOHIDEventSystem (privado)

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let kIOHIDEventTypeTemperature: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private struct API {
        let create: ClientCreate, setMatching: SetMatching, copyServices: CopyServices
        let copyProperty: CopyProperty, copyEvent: CopyEvent, getFloat: GetFloat
    }

    private static let api: API? = {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let create = sym("IOHIDEventSystemClientCreate", ClientCreate.self),
            let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self),
            let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
            let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self),
            let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self),
            let getFloat = sym("IOHIDEventGetFloatValue", GetFloat.self)
        else { return nil }
        return API(create: create, setMatching: setMatching, copyServices: copyServices,
                   copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat)
    }()

    /// Cliente criado uma vez e reaproveitado: criar a cada leitura é caro.
    private static let client: AnyObject? = {
        guard let api, let client = api.create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // PrimaryUsagePage 0xff00 / PrimaryUsage 5 = sensores de temperatura da Apple.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = api.setMatching(client, matching)
        return client
    }()

    private static func sensors() -> [(String, Double)] {
        guard let api, let client,
              let services = api.copyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return [] }
        return services.compactMap { service in
            guard let name = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = api.copyEvent(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue()
            else { return nil }
            return (name, api.getFloat(event, temperatureField))
        }
    }
}

func celsius(_ value: Double) -> String { "\(Int(value.rounded())) °C" }

func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .fair: "aquecendo"
    case .serious: "quente, desempenho reduzido"
    case .critical: "muito quente"
    default: "temperatura normal"
    }
}

extension Color {
    static func thermalTint(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .serious, .critical: .red
        case .fair: .orange
        default: .brandPurple
        }
    }
}

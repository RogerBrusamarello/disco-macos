import Foundation
import WidgetKit

/// Um grupo de arquivos temporários que pode ser apagado. Tudo aqui é recriado sozinho pelos apps.
struct CleanItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let dirs: [URL]
    /// Se definido, só apaga arquivos sem modificação há mais tempo que isso.
    var olderThan: TimeInterval?
    /// Comando extra rodado na limpeza (ex.: remover simuladores indisponíveis).
    var command: [String]?
}

enum Cleaner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let items: [CleanItem] = [
        CleanItem(
            id: "caches", title: "Cache de aplicativos", subtitle: "~/Library/Caches",
            dirs: [home.appending(path: "Library/Caches")]
        ),
        // Mesmo critério do macOS para /tmp: só o que está parado há mais de 3 dias,
        // para não apagar arquivos que apps abertos ainda estão usando.
        CleanItem(
            id: "temp", title: "Temporários do sistema", subtitle: "Pasta temporária do macOS, com mais de 3 dias",
            dirs: [FileManager.default.temporaryDirectory],
            olderThan: 3 * 24 * 3600
        ),
        CleanItem(
            id: "derived", title: "Xcode DerivedData", subtitle: "Builds temporários do Xcode",
            dirs: [home.appending(path: "Library/Developer/Xcode/DerivedData")]
        ),
        CleanItem(
            id: "simulators", title: "Caches de simuladores", subtitle: "Dados temporários e simuladores indisponíveis",
            dirs: [home.appending(path: "Library/Developer/CoreSimulator/Caches")],
            command: hasDeveloperTools ? ["/usr/bin/xcrun", "simctl", "delete", "unavailable"] : nil
        ),
        CleanItem(
            id: "packages", title: "npm / Yarn / pnpm", subtitle: "Caches de pacotes",
            dirs: [
                home.appending(path: ".npm/_cacache"),
                home.appending(path: ".yarn/berry/cache"),
                home.appending(path: "Library/pnpm/store"),
            ]
        ),
        CleanItem(
            id: "logs", title: "Logs antigos", subtitle: "~/Library/Logs, com mais de 7 dias",
            dirs: [home.appending(path: "Library/Logs")],
            olderThan: 7 * 24 * 3600
        ),
    ]

    /// Sem Xcode/Command Line Tools, `xcrun` abriria o instalador da Apple; nesse caso não roda.
    private static var hasDeveloperTools: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Xcode.app") || fm.fileExists(atPath: "/Library/Developer/CommandLineTools")
    }

    static func size(of item: CleanItem) -> Int64 {
        var total: Int64 = 0
        let cutoff = item.olderThan.map { Date.now.addingTimeInterval(-$0) }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey]
        for dir in item.dirs {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if let cutoff, let modified = values.contentModificationDate, modified > cutoff { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Apaga o conteúdo das pastas (não as pastas em si); ignora o que estiver em uso ou protegido.
    static func clean(_ items: [CleanItem]) {
        let fm = FileManager.default
        for item in items {
            for dir in item.dirs {
                if let age = item.olderThan {
                    let cutoff = Date.now.addingTimeInterval(-age)
                    let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                    while let url = e?.nextObject() as? URL {
                        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                        if values?.isRegularFile == true, let modified = values?.contentModificationDate, modified < cutoff {
                            try? fm.removeItem(at: url)
                        }
                    }
                } else {
                    for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                        try? fm.removeItem(at: child)
                    }
                }
            }
            if let command = item.command {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: command[0])
                p.arguments = Array(command.dropFirst())
                try? p.run()
                p.waitUntilExit()
            }
        }
    }
}

/// Estado da aba Limpeza: tamanhos calculados, seleção e resultado.
@MainActor
final class CleanModel: ObservableObject {
    @Published var sizes: [String: Int64] = [:]
    @Published var selected: Set<String> = Set(Cleaner.items.map(\.id))
    @Published var scanning = false
    @Published var cleaning = false
    @Published var freed: Int64?
    @Published var swapUsed: Int64 = 0

    var total: Int64 { selected.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        sizes = [:]
        swapUsed = Metrics.swap().used
        DispatchQueue.global(qos: .userInitiated).async {
            for item in Cleaner.items {
                let size = Cleaner.size(of: item)
                DispatchQueue.main.async { self.sizes[item.id] = size }
            }
            DispatchQueue.main.async { self.scanning = false }
        }
    }

    func clean() {
        let items = Cleaner.items.filter { selected.contains($0.id) }
        guard !items.isEmpty, !cleaning else { return }
        cleaning = true
        freed = nil
        let before = Metrics.disk().free
        DispatchQueue.global(qos: .userInitiated).async {
            Cleaner.clean(items)
            let after = Metrics.disk().free
            DispatchQueue.main.async {
                self.freed = max(after - before, 0)
                self.cleaning = false
                WidgetCenter.shared.reloadAllTimelines()
                self.scan()
            }
        }
    }
}

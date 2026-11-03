import AppKit
import WidgetKit

/// Um grupo de arquivos temporários que pode ser apagado. Tudo aqui é recriado sozinho pelos apps.
struct CleanItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let dirs: [URL]
    /// Se definido, só apaga arquivos sem modificação há mais tempo que isso.
    var olderThan: TimeInterval?
    /// Pastas de dentro de `dirs` que ficam de fora, porque têm item próprio.
    var skipping: Set<String> = []
    /// Só mede estas pastas; quem apaga é o comando (ex.: `simctl erase all`).
    var measured: (() -> [URL])?
    /// Comandos rodados na limpeza, na ordem (ex.: remover simuladores indisponíveis).
    var commands: [[String]] = []
    /// Começa desmarcado: o efeito colateral pede uma escolha.
    var optIn = false
    /// Por que não dá para apagar agora (ex.: o Gradle rodando). Conferido ao medir e de novo ao apagar.
    var blocker: (() -> String?)?
}

enum Cleaner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices")

    static let items: [CleanItem] = [
        CleanItem(
            id: "caches", title: "Cache de aplicativos", subtitle: "~/Library/Caches",
            dirs: [home.appending(path: "Library/Caches")],
            skipping: ["go-build"]
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
            commands: hasDeveloperTools ? [["/usr/bin/xcrun", "simctl", "delete", "unavailable"]] : []
        ),
        CleanItem(
            id: "gradle", title: "Cache do Gradle", subtitle: "~/.gradle/caches: o próximo build baixa as dependências de novo",
            dirs: [home.appending(path: ".gradle/caches")],
            blocker: { gradleRunning() ? "O Gradle está rodando: feche o Android Studio ou rode gradle --stop" : nil }
        ),
        CleanItem(
            id: "go", title: "Cache de build do Go", subtitle: "~/Library/Caches/go-build",
            dirs: [home.appending(path: "Library/Caches/go-build")]
        ),
        CleanItem(
            id: "vsix", title: "Instaladores de extensões", subtitle: "VS Code e Cursor guardam uma cópia de cada extensão instalada",
            dirs: [
                home.appending(path: "Library/Application Support/Code/CachedExtensionVSIXs"),
                home.appending(path: "Library/Application Support/Cursor/CachedExtensionVSIXs"),
            ]
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
    ] + (hasDeveloperTools ? [
        CleanItem(
            id: "simulator-data", title: "Dados dos simuladores", subtitle: "Zera todos os simuladores: apaga os apps instalados neles",
            dirs: [],
            measured: {
                ((try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? [])
                    .map { $0.appending(path: "data") }
            },
            commands: [["/usr/bin/xcrun", "simctl", "shutdown", "all"], ["/usr/bin/xcrun", "simctl", "erase", "all"]],
            optIn: true
        ),
    ] : [])

    /// Sem Xcode/Command Line Tools, `xcrun` abriria o instalador da Apple; nesse caso não roda.
    static var hasDeveloperTools: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Xcode.app") || fm.fileExists(atPath: "/Library/Developer/CommandLineTools")
    }

    /// Um daemon do Gradle aberto está usando o cache: apagar no meio quebraria o build.
    static func gradleRunning() -> Bool {
        SpaceScanner.execute("/usr/bin/pgrep", ["-f", "GradleDaemon"], timeout: 5).ok
    }

    static func size(of item: CleanItem) -> Int64 {
        if let measured = item.measured {
            return measured().reduce(0) { $0 + SpaceScanner.size(of: $1) }
        }
        var total: Int64 = 0
        let cutoff = item.olderThan.map { Date.now.addingTimeInterval(-$0) }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey]
        for dir in item.dirs {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                if e?.level == 1, item.skipping.contains(url.lastPathComponent) {
                    e?.skipDescendants()
                    continue
                }
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
        for item in items where item.blocker?() == nil {
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
                    for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                    where !item.skipping.contains(child.lastPathComponent) {
                        try? fm.removeItem(at: child)
                    }
                }
            }
            for command in item.commands {
                _ = SpaceScanner.execute(command[0], Array(command.dropFirst()), timeout: 300)
            }
        }
    }
}

/// O cache dyld dos simuladores é do root: só sai com a senha de administrador, fora da seleção.
enum AdminCache {
    static let dyld = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches/dyld")

    static func size() -> Int64 { SpaceScanner.size(of: dyld) }

    /// Fecha os simuladores e apaga o conteúdo pedindo a senha (janela do macOS). nil se deu certo ou se a pessoa cancelou.
    static func clean() -> String? {
        _ = SpaceScanner.execute("/usr/bin/xcrun", ["simctl", "shutdown", "all"], timeout: 120)
        let script = "do shell script \"/bin/rm -rf \(dyld.path)/*\" with prompt \"O disco quer apagar o cache dyld dos simuladores.\" with administrator privileges"
        let result = SpaceScanner.execute("/usr/bin/osascript", ["-e", script], timeout: 600)
        // -128: a pessoa cancelou a senha.
        return result.ok || result.error.contains("-128") ? nil : result.error
    }
}

/// O espaço do que vai para a Lixeira só volta quando ela é esvaziada. Sem Acesso Total ao Disco, o macOS não deixa
/// listar a Lixeira, mas deixa medir e apagar os caminhos conhecidos: o disco guarda os do que ele mesmo mandou para lá.
enum Trash {
    private static let key = "trashedPaths"
    private static let fm = FileManager.default

    /// Guarda os caminhos novos (dentro da Lixeira) do que o disco mandou para lá.
    static func record(_ urls: [URL]) {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.set(saved + urls.map(\.path), forKey: key)
    }

    /// O que o disco mandou para a Lixeira e ainda está lá; esquece o que já saiu.
    static func discoItems() -> [URL] {
        let paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { fm.fileExists(atPath: $0) }
        UserDefaults.standard.set(paths, forKey: key)
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Quanto está na Lixeira. `whole`: deu para listar a Lixeira inteira; senão, só o que o disco mandou.
    static func size() -> (bytes: Int64, whole: Bool) {
        if let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           let all = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            return (all.reduce(0) { $0 + SpaceScanner.size(of: $1) }, true)
        }
        return (discoItems().reduce(0) { $0 + SpaceScanner.size(of: $1) }, false)
    }

    /// Pede ao Finder para esvaziar a Lixeira. Sem permissão para controlar o Finder, apaga só o que o disco mandou
    /// para lá e devolve o aviso.
    static func empty() -> String? {
        let result = SpaceScanner.execute("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 600)
        if result.ok {
            _ = discoItems()
            return nil
        }
        for url in discoItems() { try? fm.removeItem(at: url) }
        _ = discoItems()
        return """
        O Finder não deixou o disco esvaziar a Lixeira, então saiu só o que o disco tinha mandado para lá. \
        Para esvaziar o resto, use o Finder, ou permita em Ajustes do Sistema → Privacidade e Segurança → Automação → Disco → Finder.
        """
    }
}

/// Estado da aba Limpeza: tamanhos calculados, seleção e resultado.
@MainActor
final class CleanModel: ObservableObject {
    @Published var sizes: [String: Int64] = [:]
    @Published var selected: Set<String> = Set(Cleaner.items.filter { !$0.optIn }.map(\.id))
    /// Item → por que não dá para apagar agora.
    @Published var blocked: [String: String] = [:]
    @Published var scanning = false
    @Published var cleaning = false
    @Published var freed: Int64?
    @Published var swapUsed: Int64 = 0

    /// Pastas de build e dependências dos projetos. nil enquanto procura.
    @Published var projects: [ProjectJunk]?
    /// Pastas de projetos que o macOS não deixou ler.
    @Published var deniedRoots: [URL] = []
    @Published var roots: [URL] = ProjectScanner.roots
    /// Projetos que ficaram de fora na última limpeza porque um processo estava neles.
    @Published var skipped: [ProjectJunk] = []
    /// Builds já vistos: um build novo entra marcado, mas o que a pessoa desmarcou continua desmarcado.
    private var seenBuilds: Set<String> = []
    /// Só vale o resultado da procura mais recente (as pastas podem mudar no meio).
    private var projectScan = 0

    @Published var trash: (bytes: Int64, whole: Bool)?
    @Published var dyldBytes: Int64 = 0
    /// Esvaziando a Lixeira ou apagando o cache dyld.
    @Published var busy = false

    var total: Int64 {
        let items = selected.filter { blocked[$0] == nil }.reduce(0) { $0 + (sizes[$1] ?? 0) }
        return items + (projects ?? []).filter { selected.contains($0.id) && !$0.inUse }.reduce(0) { $0 + $1.bytes }
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func projects(_ kind: ProjectJunk.Kind) -> [ProjectJunk] {
        (projects ?? []).filter { $0.kind == kind }
    }

    /// Marca todos os projetos do grupo, ou desmarca se já estavam todos marcados.
    func toggleAll(_ kind: ProjectJunk.Kind) {
        let ids = projects(kind).filter { !$0.inUse }.map(\.id)
        if ids.allSatisfy(selected.contains) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func setRoots(_ roots: [URL]) {
        ProjectScanner.roots = roots
        self.roots = ProjectScanner.roots
        scanProjects()
    }

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        sizes = [:]
        swapUsed = Metrics.swap().used
        scanProjects()
        DispatchQueue.global(qos: .userInitiated).async {
            let trash = Trash.size()
            let dyld = AdminCache.size()
            DispatchQueue.main.async {
                self.trash = trash
                self.dyldBytes = dyld
            }
            for item in Cleaner.items {
                let size = Cleaner.size(of: item)
                let reason = item.blocker?()
                DispatchQueue.main.async {
                    self.sizes[item.id] = size
                    self.blocked[item.id] = reason
                }
            }
            DispatchQueue.main.async { self.scanning = false }
        }
    }

    private func scanProjects() {
        projects = nil
        projectScan += 1
        let generation = projectScan
        let roots = roots
        DispatchQueue.global(qos: .userInitiated).async {
            let (junk, denied) = ProjectScanner.scan(roots: roots)
            DispatchQueue.main.async {
                guard generation == self.projectScan else { return }
                for item in junk where item.kind == .build && !self.seenBuilds.contains(item.id) {
                    self.seenBuilds.insert(item.id)
                    if !item.inUse { self.selected.insert(item.id) }
                }
                self.projects = junk
                self.deniedRoots = denied
            }
        }
    }

    func clean() {
        let items = Cleaner.items.filter { selected.contains($0.id) && blocked[$0.id] == nil }
        let junk = (projects ?? []).filter { selected.contains($0.id) && !$0.inUse }
        guard !items.isEmpty || !junk.isEmpty, !cleaning else { return }
        cleaning = true
        freed = nil
        skipped = []
        let before = Metrics.disk().free
        DispatchQueue.global(qos: .userInitiated).async {
            let skipped = ProjectScanner.clean(junk)
            Cleaner.clean(items)
            let after = Metrics.disk().free
            DispatchQueue.main.async {
                self.freed = max(after - before, 0)
                self.skipped = skipped
                self.cleaning = false
                WidgetCenter.shared.reloadAllTimelines()
                self.scan()
            }
        }
    }

    func emptyTrash() {
        guard !busy, let trash else { return }
        NSApp.activate(ignoringOtherApps: true)
        let size = trash.bytes > 0 ? (trash.whole ? Cleaner.format(trash.bytes) : "pelo menos \(Cleaner.format(trash.bytes))") : nil
        guard confirm(
            title: "Esvaziar a Lixeira?",
            text: "Apaga de vez tudo o que está na Lixeira, inclusive o que não veio do disco\(size.map { ", e libera \($0)" } ?? ""). Não dá para desfazer.",
            button: "Esvaziar"
        ) else { return }
        run { Trash.empty() }
    }

    func cleanDyld() {
        guard !busy else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard confirm(
            title: "Apagar o cache dyld dos simuladores?",
            text: """
            Libera \(Cleaner.format(dyldBytes)). A pasta é do sistema, então o macOS pede a senha de administrador. \
            Os simuladores abertos são fechados, e o próximo que abrir recria o cache (demora um pouco mais nessa vez).
            """,
            button: "Apagar"
        ) else { return }
        run { AdminCache.clean() }
    }

    /// Roda em segundo plano, mostra o erro se houver e mede de novo.
    private func run(_ work: @escaping () -> String?) {
        busy = true
        freed = nil
        let before = Metrics.disk().free
        DispatchQueue.global(qos: .userInitiated).async {
            let error = work()
            let after = Metrics.disk().free
            DispatchQueue.main.async {
                self.busy = false
                if let error {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Não deu para terminar"
                    alert.informativeText = error
                    alert.runModal()
                }
                self.freed = max(after - before, 0)
                WidgetCenter.shared.reloadAllTimelines()
                self.scan()
            }
        }
    }

    private func confirm(title: String, text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

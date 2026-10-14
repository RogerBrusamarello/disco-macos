import AppKit
import ServiceManagement
import WidgetKit

/// Agente em segundo plano (sem Dock, com ícone na barra de menus): a cada minuto grava os apps que mais usam memória
/// para o widget, e atende os links do widget: discowidget://clean, ://activity e ://kill?app=<caminho>.
@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var status: StatusController?
    private var mainWindow: MainWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? SMAppService.mainApp.register()
        registerBrandFonts()
        mainWindow = MainWindowController(
            onClean: { [weak self] in self?.confirmAndClean() },
            onKill: { [weak self] path in self?.confirmAndKill(path) }
        )
        status = StatusController(
            onClean: { [weak self] in self?.confirmAndClean() },
            onKill: { [weak self] path in self?.confirmAndKill(path) },
            onOpen: { [weak self] in self?.mainWindow?.show() }
        )
        // Aberto pela pessoa (Finder/Spotlight) mostra a janela; no login fica só na barra de menus.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let openedByUser = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue != OSType(keyAELaunchedAsLogInItem)
        if openedByUser { mainWindow?.show() }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sample() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "clean": confirmAndClean()
            case "activity":
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            case "kill":
                let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "app" }?.value
                if let path { confirmAndKill(path) }
            default:
                // clique no widget
                sample()
                WidgetCenter.shared.reloadAllTimelines()
                mainWindow?.show()
            }
        }
    }

    /// Abrir o Disco de novo (Spotlight, Finder, Dock) mostra a janela.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    /// Depois de um alerta, esconde o app só se a janela principal não estiver aberta.
    private func hideIfIdle() {
        if !(mainWindow?.isVisible ?? false) { NSApp.hide(nil) }
    }

    private func sample() {
        TopAppsSnapshot(date: .now, apps: Sampler.topApps()).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "MemoryWidget")
    }

    private func confirmAndKill(_ path: String) {
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forçar encerramento de \(name)?"
        alert.informativeText = "Alterações não salvas serão perdidas."
        alert.icon = NSWorkspace.shared.icon(forFile: path)
        alert.addButton(withTitle: "Forçar Encerrar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            Sampler.forceQuit(bundlePath: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.sample() }
        }
        hideIfIdle()
    }

    private func confirmAndClean() {
        NSApp.activate(ignoringOtherApps: true)
        let targets = Cleaner.targets.map { ($0, Cleaner.size(of: $0)) }
        let total = targets.reduce(0) { $0 + $1.1 }

        let alert = NSAlert()
        alert.messageText = "Limpar \(Cleaner.format(total)) de cache?"
        alert.informativeText = targets
            .map { "• \($0.0.name): \(Cleaner.format($0.1))" }
            .joined(separator: "\n") + "\n• Simuladores iOS indisponíveis"
        alert.addButton(withTitle: "Limpar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return hideIfIdle() }

        let before = Cleaner.freeSpace()
        DispatchQueue.global(qos: .userInitiated).async {
            Cleaner.clean(targets.map(\.0))
            let freed = max(Cleaner.freeSpace() - before, 0)
            DispatchQueue.main.async {
                let done = NSAlert()
                done.messageText = "Pronto! \(Cleaner.format(freed)) liberados."
                done.runModal()
                WidgetCenter.shared.reloadAllTimelines()
                self.hideIfIdle()
            }
        }
    }
}

enum Cleaner {
    struct Target {
        let name: String
        let dirs: [URL]
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let targets: [Target] = [
        Target(name: "Caches de apps (~/Library/Caches)", dirs: [home.appending(path: "Library/Caches")]),
        Target(name: "Xcode DerivedData", dirs: [home.appending(path: "Library/Developer/Xcode/DerivedData")]),
        Target(name: "Caches do Simulador", dirs: [home.appending(path: "Library/Developer/CoreSimulator/Caches")]),
        Target(name: "npm", dirs: [home.appending(path: ".npm/_cacache")]),
    ]

    /// Apaga o conteúdo das pastas (não as pastas em si); ignora o que estiver em uso ou protegido.
    static func clean(_ targets: [Target]) {
        let fm = FileManager.default
        for dir in targets.flatMap(\.dirs) {
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
        }
        run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
    }

    static func size(of target: Target) -> Int64 {
        var total: Int64 = 0
        for dir in target.dirs {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func freeSpace() -> Int64 {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

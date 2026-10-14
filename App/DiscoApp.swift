import AppKit
import ServiceManagement
import WidgetKit

/// Agente em segundo plano (sem Dock, com ícone na barra de menus): a cada minuto grava os apps que mais usam memória
/// para o widget, e atende os links do widget: discowidget://clean (aba Limpeza), ://activity e ://kill?app=<caminho>.
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
            onKill: { [weak self] path in self?.confirmAndKill(path) }
        )
        status = StatusController(
            onClean: { [weak self] in self?.mainWindow?.show(tab: .clean) },
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
            case "clean": mainWindow?.show(tab: .clean)
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
}

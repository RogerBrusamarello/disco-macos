import ServiceManagement

/// Abrir o Disco junto com o Mac (aba Ajustes). Vem ligado; a escolha fica salva e é aplicada a cada abertura do app.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()
    private static let key = "launchAtLogin"

    /// O que o macOS diz agora. Desligado pela pessoa em Itens de Início, fica em `.requiresApproval`.
    @Published private(set) var status = SMAppService.mainApp.status

    /// Registrado como item de início, mesmo que ainda falte a aprovação nos Ajustes do Sistema.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// Na abertura do app: aplica a escolha salva (sem escolha, liga).
    func apply() {
        let wanted = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        if wanted != isOn || status == .notFound { set(wanted) }
    }

    func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        if on {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

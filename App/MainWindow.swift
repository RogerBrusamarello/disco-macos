import AppKit
import Combine
import CoreText
import SwiftUI

/// Registra Fredoka e DM Sans (App/Fonts) só para este app.
func registerBrandFonts() {
    for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    static func fredoka(_ size: CGFloat) -> Font { .custom("Fredoka-Bold", size: size) }
}

enum WindowTab: String, CaseIterable {
    case overview = "Visão geral"
    case clean = "Limpeza"
    case updates = "Atualizações"
    case settings = "Ajustes"

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .updates: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }

    var help: String {
        switch self {
        case .overview: "Disco, memória e o que mais usa memória e espaço"
        case .clean: "Escolher e abduzir arquivos temporários"
        case .updates: "Versão instalada e versões novas no GitHub"
        case .settings: "Barra de menus e abrir junto com o Mac"
        }
    }
}

enum WindowTheme: String {
    case light, dark
}

/// Lista da Visão geral: apps que mais usam memória ou o que mais ocupa o disco.
enum OverviewList: String, CaseIterable {
    case memory = "Memória"
    case disk = "Disco"

    var systemImage: String { self == .memory ? "memorychip" : "internaldrive" }
    var title: String { self == .memory ? "Mais usam memória" : "Mais ocupam espaço" }
}

@MainActor
final class WindowState: ObservableObject {
    @Published var tab: WindowTab = .overview
    @Published var list: OverviewList = .memory
    /// nil = segue o tema do Mac; depois do primeiro clique no botão, fica salvo.
    @Published var theme: WindowTheme? = UserDefaults.standard.string(forKey: "windowTheme").flatMap(WindowTheme.init) {
        didSet { UserDefaults.standard.set(theme?.rawValue, forKey: "windowTheme") }
    }
}

/// Janela compacta no estilo dos Ajustes do Sistema, com a marca só no cabeçalho.
/// Enquanto está aberta, o app aparece no Dock e no ⌘Tab.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = StatsModel()
    private let cleanModel = CleanModel()
    private let spaceModel = SpaceModel()
    private let state = WindowState()
    private let onKill: (String) -> Void
    private var themeObserver: AnyCancellable?

    var isVisible: Bool { window?.isVisible ?? false }

    init(onKill: @escaping (String) -> Void) {
        self.onKill = onKill
        model.appLimit = 10
    }

    func show(tab: WindowTab? = nil, list: OverviewList? = nil) {
        if window == nil {
            let root = MainView(
                model: model,
                cleanModel: cleanModel,
                spaceModel: spaceModel,
                state: state,
                onKill: { [weak self] path in self?.onKill(path) },
                onActivity: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Disco"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self

            // Fundo translúcido do sistema (segue modo claro/escuro).
            let material = NSVisualEffectView()
            material.material = .underWindowBackground
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            let host = NSHostingView(rootView: root)
            host.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                host.topAnchor.constraint(equalTo: material.topAnchor),
                host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            window.contentView = material
            window.setContentSize(host.fittingSize)
            window.center()
            self.window = window
            themeObserver = state.$theme.sink { [weak window] theme in
                window?.appearance = theme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)! }
            }
        }
        if let tab { state.tab = tab }
        if let list { state.list = list }
        if state.tab == .clean { cleanModel.scan() }
        if state.tab == .overview, state.list == .disk { spaceModel.refreshIfStale() }
        model.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Views

private func appIcon(_ path: String) -> NSImage {
    let image = NSWorkspace.shared.icon(forFile: path)
    image.size = NSSize(width: 64, height: 64)
    return image
}

/// Altura fixa do conteúdo das abas, para a janela não mudar de tamanho ao trocar.
private let tabHeight: CGFloat = 468

struct MainView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var cleanModel: CleanModel
    @ObservedObject var spaceModel: SpaceModel
    @ObservedObject var state: WindowState
    @ObservedObject var updater = Updater.shared
    let onKill: (String) -> Void
    let onActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Hierarquia: marca primeiro, depois a troca de aba.
            TabToggle(selection: $state.tab)
                .frame(width: 500)
                .frame(maxWidth: .infinity)
            Group {
                switch state.tab {
                case .overview: overview
                case .clean:
                    CleanView(model: cleanModel) {
                        withAnimation(.snappy(duration: 0.25)) { state.tab = .overview }
                    }
                case .updates: UpdatesView(updater: updater)
                case .settings: SettingsView(settings: .shared, launch: .shared)
                }
            }
            .frame(height: tabHeight, alignment: .top)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.top, 44)  // abaixo da linha dos botões da janela (barra de título ~28 pt)
        .padding(.bottom, 20)
        .frame(width: 560)
        .overlay(alignment: .topTrailing) {
            ThemeToggle(state: state)
                .padding(.top, 3)  // centro em ~14 pt: mesma linha de fechar/minimizar
                .padding(.trailing, 10)
        }
        // Conteúdo a partir do topo real da janela (a barra de título é transparente).
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: state.tab) { _, tab in
            if tab == .clean { cleanModel.scan() }
            if tab == .overview, state.list == .disk { spaceModel.refreshIfStale() }
        }
        .onChange(of: state.list) { _, list in
            if list == .disk { spaceModel.refreshIfStale() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Ilustracao")
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 0) {
                Text("disco").font(.fredoka(26))
                Text("Dê espaço ao seu Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatCard(
                    title: "Macintosh HD",
                    fraction: model.diskFraction,
                    tint: .diskTint(model.diskFraction),
                    primary: "\(gb(model.disk.total - model.disk.free)) de \(gb(model.disk.total)) GB",
                    secondary: "\(gb(model.disk.free)) GB livres"
                ) {
                    Button { state.tab = .clean } label: {
                        CapsuleLabel(title: "Abduzir temporários", systemImage: "sparkles")
                    }
                    .buttonStyle(CapsuleButtonStyle())
                }
                StatCard(
                    title: "Memória",
                    fraction: model.memoryFraction,
                    tint: .memoryTint(model.memory.pressure),
                    primary: "\(ramGB(model.memory.used)) de \(ramGB(model.memory.total)) GB",
                    secondary: pressureLabel(model.memory.pressure).capitalizedFirst
                ) {
                    Button(action: onActivity) {
                        CapsuleLabel(title: "Monitor", systemImage: "waveform.path.ecg", prominent: false)
                    }
                    .buttonStyle(CapsuleButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(state.list.title)
                        .font(.system(size: 13, weight: .semibold))
                    if state.list == .disk { spaceStatus }
                    Spacer(minLength: 8)
                    ListToggle(selection: $state.list).fixedSize()
                }
                .padding(.leading, 4)
                ScrollView {
                    switch state.list {
                    case .memory: memoryList
                    case .disk: diskList
                    }
                }
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .groupBox()
                HStack(alignment: .bottom) {
                    Text(appVersion)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    UpdateStatus(updater: updater)
                }
                .padding(.horizontal, 4)  // mesma margem do título da lista
                .padding(.top, 2)
            }
        }
    }
}

extension MainView {
    private var memoryList: some View {
        VStack(spacing: 0) {
            let maxBytes = max(model.apps.first?.bytes ?? 1, 1)
            ForEach(Array(model.apps.enumerated()), id: \.element.path) { index, app in
                if index > 0 { Divider().padding(.leading, 44) }
                AppRow(app: app, share: Double(app.bytes) / Double(maxBytes)) { onKill(app.path) }
            }
        }
    }

    @ViewBuilder
    private var diskList: some View {
        if spaceModel.groups.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Medindo o espaço de cada app…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 90)
        } else {
            VStack(spacing: 0) {
                let maxBytes = max(spaceModel.groups.first?.bytes ?? 1, 1)
                ForEach(Array(spaceModel.groups.prefix(12).enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().padding(.leading, 44) }
                    SpaceRow(model: spaceModel, group: group, share: Double(group.bytes) / Double(maxBytes))
                }
            }
        }
    }

    /// Quando foi medido e o botão para medir de novo (a medição leva de segundos a um minuto).
    @ViewBuilder
    private var spaceStatus: some View {
        if let result = spaceModel.result {
            // Na Lixeira, o resultado leva à Limpeza, onde dá para esvaziar.
            Button { if spaceModel.resultInTrash { state.tab = .clean } } label: {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(spaceModel.resultInTrash ? "O espaço só volta ao disco quando a Lixeira é esvaziada. Clique para esvaziar na Limpeza." : "Estimativa: o tamanho medido antes de apagar")
        }
        if spaceModel.running != nil || spaceModel.scanning {
            ProgressView().controlSize(.mini)
        } else if let date = spaceModel.date {
            Button { spaceModel.scan() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Medido \(date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "pt_BR")))). Clique para medir de novo.")
        }
    }
}

/// Versão e build instaladas, lidas do próprio app (ex.: "Version: 1.2" / "Build: 3").
private let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "Version: \(version)\nBuild: \(build)"
}()

/// Alterna a janela entre tema claro e escuro.
struct ThemeToggle: View {
    @ObservedObject var state: WindowState
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Button {
            state.theme = isDark ? .light : .dark
        } label: {
            Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 22)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDark ? "Tema claro" : "Tema escuro")
        .onHover { hovering = $0 }
    }
}

/// Abas no mesmo padrão da cápsula "Abduzir temporários": trilho cinza e a aba ativa
/// como cápsula roxa que desliza entre os segmentos (de mesma largura).
struct TabToggle: View {
    @Binding var selection: WindowTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WindowTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                        Text(tab.rawValue)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.brandPurple)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.help)
            }
        }
        .padding(3)
        .background(.fill.secondary, in: Capsule())
    }
}

/// Troca a lista da Visão geral entre memória e disco, no padrão das abas, em tamanho menor.
struct ListToggle: View {
    @Binding var selection: OverviewList
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverviewList.allCases, id: \.self) { list in
                let selected = list == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = list }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: list.systemImage)
                        Text(list.rawValue)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.brandPurple)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(list.title)
            }
        }
        .padding(2)
        .background(.fill.secondary, in: Capsule())
    }
}

// MARK: Atualizações

/// Versão instalada, o último release do GitHub com as novidades e o botão para procurar na hora.
struct UpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Atualizações").font(.system(size: 13, weight: .semibold))
                Text("O Disco procura versões novas no GitHub e se atualiza sozinho, sem precisar baixar o .dmg.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                InfoRow(title: "Versão instalada", value: "\(updater.currentVersion) (build \(updater.currentBuild))")
                Divider().padding(.leading, 12)
                InfoRow(title: "Versão mais recente", value: updater.latest?.version ?? "—")
                Divider().padding(.leading, 12)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    InfoRow(title: "Última verificação", value: lastCheckLabel)
                }
                Divider().padding(.leading, 12)
                ToggleRow(title: "Procurar automaticamente todo dia", isOn: $updater.checksDaily)
            }
            .groupBox()

            VStack(alignment: .leading, spacing: 6) {
                Text(notesTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
                ScrollView {
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundStyle(updater.latest == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: .infinity)
                .groupBox()
            }

            HStack(alignment: .center) {
                Label(statusText, systemImage: statusIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if updater.isBusy {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                }
                Button { NSWorkspace.shared.open(updater.latest?.page ?? updater.releasesPage) } label: {
                    CapsuleLabel(title: "Ver no GitHub", systemImage: "arrow.up.right.square", style: .secondary)
                }
                .buttonStyle(CapsuleButtonStyle())
                if let release = updater.available {
                    Button { updater.confirmAndInstall() } label: {
                        CapsuleLabel(title: "Atualizar para \(release.version)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(CapsuleButtonStyle())
                } else {
                    Button { updater.check(userInitiated: true) } label: {
                        CapsuleLabel(title: "Procurar atualizações", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(updater.isBusy)
                }
            }
            .padding(.horizontal, 4)
        }
        // A versão mais recente não fica salva entre aberturas: ao entrar na aba, busca em silêncio.
        .task { if updater.latest == nil { updater.check(userInitiated: false) } }
    }

    private var lastCheckLabel: String {
        guard let date = updater.lastCheck else { return "Nunca" }
        if Date.now.timeIntervalSince(date) < 60 { return "Agora mesmo" }
        return date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "pt_BR")))
            .capitalizedFirst
    }

    private var notesTitle: String {
        guard let latest = updater.latest else { return "Novidades" }
        return "Novidades da versão \(latest.version)"
    }

    private var notes: String {
        guard let latest = updater.latest else { return "Procure atualizações para ver as novidades da versão mais recente." }
        var text = Updater.plainNotes(latest.notes)
        // O título da caixa já diz "Novidades da versão X".
        if text.hasPrefix("Novidades\n") { text = String(text.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.isEmpty ? "Sem notas para esta versão." : text
    }

    private var statusText: String {
        switch updater.state {
        case .checking: "Procurando atualizações…"
        case .installing(let step): step
        case .failed(let message): message
        case .available(let release): "Versão \(release.version) disponível"
        case .idle, .upToDate: updater.latest == nil ? "Não verificado" : "Está atualizado"
        }
    }

    private var statusIcon: String {
        switch updater.state {
        case .failed: "exclamationmark.triangle.fill"
        case .available: "arrow.down.circle.fill"
        case .checking, .installing: "arrow.triangle.2.circlepath"
        case .idle, .upToDate: updater.latest == nil ? "clock" : "checkmark.circle.fill"
        }
    }
}

// MARK: Ajustes

/// O que aparece ao lado do disco voador na barra de menus, com uma prévia de como fica, e se o disco abre junto com o Mac.
struct SettingsView: View {
    @ObservedObject var settings: MenuBarSettings
    @ObservedObject var launch: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            menuBar
            startup
        }
        // Volta dos Ajustes do Sistema com o item de início aprovado ou desligado.
        .onAppear { launch.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launch.refresh()
        }
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Início", "O disco voador aparece na barra de menus quando você entra no Mac, sem abrir a janela.")

            VStack(spacing: 0) {
                ToggleRow(
                    title: "Abrir junto com o Mac",
                    subtitle: launch.needsApproval
                        ? "Falta permitir em Ajustes do Sistema → Geral → Itens de Início"
                        : "Também aparece em Ajustes do Sistema → Geral → Itens de Início",
                    isOn: Binding(get: { launch.isOn }, set: { launch.set($0) })
                )
                if launch.needsApproval {
                    Divider().padding(.leading, 12)
                    HStack {
                        Spacer()
                        Button("Abrir Itens de Início") { launch.openLoginItems() }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
            }
            .groupBox()
        }
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Barra de menus", "Porcentagens ao lado do disco voador. Atualizam a cada 5 segundos.")

            preview

            VStack(spacing: 0) {
                ToggleRow(
                    title: "Memória (RAM)",
                    subtitle: "Quanto da memória está em uso, igual ao cartão Memória",
                    isOn: $settings.showMemory
                )
                Divider().padding(.leading, 12)
                ToggleRow(
                    title: "Disco (HD)",
                    subtitle: "Quanto do Macintosh HD está ocupado, igual ao cartão Macintosh HD",
                    isOn: $settings.showDisk
                )
            }
            .groupBox()

            Label {
                Text("Para mudar o disco voador de lugar na barra, segure **⌘** e arraste o ícone para onde quiser. A posição fica salva.")
            } icon: {
                Image(systemName: "hand.point.up.left")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
    }

    /// O ícone desenhado pelo mesmo código da barra, ampliado sobre uma faixa no tom da barra.
    private var preview: some View {
        let image = menuBarImage(settings.blocks())
        let scale: CGFloat = 2
        return HStack {
            Spacer()
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width * scale, height: image.size.height * scale)
                .foregroundStyle(.primary)
            Spacer()
        }
        .frame(height: 96)
        .groupBox()
        .accessibilityLabel(image.accessibilityDescription ?? "Disco")
    }
}

/// Linha com chave liga/desliga, no estilo dos Ajustes do Sistema.
struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.brandPurple)
        }
        .padding(.horizontal, 12)
        .frame(height: subtitle == nil ? 40 : 48)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

// MARK: Limpeza

struct CleanView: View {
    @ObservedObject var model: CleanModel
    let onShowApps: () -> Void
    @State private var expanded: Set<ProjectJunk.Kind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Limpeza do Mac").font(.system(size: 13, weight: .semibold))
                Text("Escolha o que apagar. Tudo aqui é recriado sozinho pelos apps quando precisarem.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            ScrollView {
                VStack(spacing: 0) {
                    TrashRow(model: model)
                    ForEach([ProjectJunk.Kind.build, .dependencies], id: \.self) { kind in
                        Divider().padding(.leading, 44)
                        ProjectGroupRow(model: model, kind: kind, expanded: Binding(
                            get: { expanded.contains(kind) },
                            set: { if $0 { expanded.insert(kind) } else { expanded.remove(kind) } }
                        ))
                    }
                    ForEach(Cleaner.items) { item in
                        Divider().padding(.leading, 44)
                        CleanRow(
                            item: item,
                            size: model.sizes[item.id],
                            selected: model.selected.contains(item.id),
                            blocked: model.blocked[item.id]
                        ) { model.toggle(item.id) }
                    }
                    if model.dyldBytes > 0 {
                        Divider().padding(.leading, 44)
                        ActionRow(
                            symbol: "lock",
                            title: "Cache dyld dos simuladores",
                            subtitle: "Pasta do sistema: pede a senha de administrador. O simulador recria quando abrir.",
                            size: Cleaner.format(model.dyldBytes),
                            button: "Apagar…",
                            help: "\(AdminCache.dyld.path). No Terminal: sudo rm -rf \(AdminCache.dyld.path)",
                            action: model.cleanDyld
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .groupBox()
            .disabled(model.cleaning || model.busy)

            SwapLink(used: model.swapUsed, action: onShowApps)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(footerCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(model.freed != nil ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                        .help(model.skipped.map { $0.project.path }.joined(separator: "\n"))
                    Text(Cleaner.format(model.total))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: model.total)
                }
                Spacer()
                if model.cleaning || model.scanning || model.busy || model.projects == nil {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                }
                Button(action: model.clean) {
                    CapsuleLabel(title: model.cleaning ? "Abduzindo…" : "Abduzir selecionados", systemImage: "sparkles")
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(model.selected.isEmpty || model.cleaning || model.busy)
            }
            .padding(.horizontal, 4)
        }
    }

    private var footerCaption: String {
        if let freed = model.freed {
            let skipped = model.skipped.count
            let note = skipped == 0 ? "selecionado agora"
                : skipped == 1 ? "1 projeto em uso ficou de fora" : "\(skipped) projetos em uso ficaram de fora"
            return "✓ \(Cleaner.format(freed)) liberados · \(note)"
        }
        return model.scanning ? "Calculando…" : "Selecionado"
    }
}

/// Marca da seleção: cheia, parcial (num grupo de projetos), vazia ou bloqueada.
private struct SelectionMark: View {
    enum State { case on, partial, off, blocked }
    let state: State

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(state == .on || state == .partial ? AnyShapeStyle(Color.brandPurple) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.circle.fill"
        case .partial: "minus.circle.fill"
        case .off: "circle"
        case .blocked: "nosign"
        }
    }
}

struct CleanRow: View {
    let item: CleanItem
    let size: Int64?
    let selected: Bool
    /// Por que não dá para apagar agora; a linha fica desligada.
    var blocked: String?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                SelectionMark(state: blocked != nil ? .blocked : selected ? .on : .off)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13))
                    Text(blocked ?? item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(blocked != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                SizeLabel(size: size)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked != nil)
    }
}

/// Tamanho à direita da linha: o valor, "Vazio" ou o carregando.
private struct SizeLabel: View {
    let size: Int64?

    var body: some View {
        Group {
            if let size, size > 0 {
                Text(Cleaner.format(size)).monospacedDigit().foregroundStyle(.secondary)
            } else if size != nil {
                Text("Vazio").foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 12))
    }
}

/// Linha com botão próprio, fora da seleção (Lixeira, cache do sistema).
struct ActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var size: String?
    let button: String
    var help: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let size {
                Text(size).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            Button(button, action: action).disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .help(help ?? "")
    }
}

/// O que foi para a Lixeira ainda ocupa o disco até ela ser esvaziada.
struct TrashRow: View {
    @ObservedObject var model: CleanModel

    var body: some View {
        ActionRow(
            symbol: "trash",
            title: "Lixeira",
            subtitle: subtitle,
            size: size,
            button: "Esvaziar…",
            help: model.trash?.whole == false
                ? "O macOS só deixa o disco ver a Lixeira inteira com Acesso Total ao Disco (Ajustes do Sistema → Privacidade e Segurança). Sem ele, o disco mede o que ele mesmo mandou para lá."
                : nil,
            disabled: model.trash == nil || (model.trash?.whole == true && model.trash?.bytes == 0),
            action: model.emptyTrash
        )
    }

    private var size: String? {
        guard let trash = model.trash else { return nil }
        if trash.bytes > 0 { return Cleaner.format(trash.bytes) }
        return trash.whole ? "Vazia" : nil
    }

    private var subtitle: String {
        guard let trash = model.trash else { return "Medindo…" }
        if trash.whole { return trash.bytes > 0 ? "Esse espaço só volta ao disco quando a Lixeira é esvaziada" : "Nada parado na Lixeira" }
        return trash.bytes > 0
            ? "O que o disco mandou para lá, mais o que você apagou no Finder. Só volta ao disco quando a Lixeira é esvaziada"
            : "O que está na Lixeira só volta ao disco quando ela é esvaziada"
    }
}

/// Builds ou dependências de todos os projetos achados, com a lista por projeto para escolher.
struct ProjectGroupRow: View {
    @ObservedObject var model: CleanModel
    let kind: ProjectJunk.Kind
    @Binding var expanded: Bool

    var body: some View {
        let list = model.projects(kind)
        let selectable = list.filter { !$0.inUse }
        let chosen = selectable.filter { model.selected.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.toggleAll(kind) } label: {
                    SelectionMark(state: selectable.isEmpty ? .off : chosen.isEmpty ? .off : chosen.count == selectable.count ? .on : .partial)
                }
                .buttonStyle(.plain)
                .disabled(selectable.isEmpty)
                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind == .build ? "Builds de projetos" : "Dependências de projetos").font(.system(size: 13))
                            Text(subtitle(list))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if model.projects == nil {
                            ProgressView().controlSize(.mini)
                        } else if list.isEmpty {
                            Text("Vazio").font(.system(size: 12)).foregroundStyle(.tertiary)
                        } else {
                            Text(sizeText(list, chosen)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)

            if expanded {
                ForEach(list) { item in
                    Divider().padding(.leading, 74)
                    ProjectRow(item: item, selected: model.selected.contains(item.id)) { model.toggle(item.id) }
                }
                Divider().padding(.leading, 74)
                RootsLine(model: model)
            }
        }
    }

    private func subtitle(_ list: [ProjectJunk]) -> String {
        if model.projects == nil { return "Procurando nas pastas de projetos…" }
        let what = kind == .build ? "build, .dart_tool, .next, target" : "voltam só com npm install ou pod install"
        guard !list.isEmpty else { return what }
        return "\(list.count == 1 ? "1 projeto" : "\(list.count) projetos") · \(what)"
    }

    /// O total do grupo, ou "marcado de total" quando só parte está marcada. Projetos em uso não entram.
    private func sizeText(_ list: [ProjectJunk], _ chosen: [ProjectJunk]) -> String {
        let total = list.filter { !$0.inUse }.reduce(0) { $0 + $1.bytes }
        let marked = chosen.reduce(0) { $0 + $1.bytes }
        if total == 0 { return "Em uso" }
        return marked == 0 || marked == total ? Cleaner.format(total) : "\(Cleaner.format(marked)) de \(Cleaner.format(total))"
    }
}

struct ProjectRow: View {
    let item: ProjectJunk
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                SelectionMark(state: item.inUse ? .blocked : selected ? .on : .off)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 13)).lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(item.inUse ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                Text(Cleaner.format(item.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.leading, 42)
            .padding(.trailing, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.inUse)
        .help(item.project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .contextMenu {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.folders) }
        }
    }

    private var detail: String {
        if item.inUse { return "Em uso por um processo (terminal, servidor…): fica de fora" }
        guard let date = item.lastUsed else { return item.contents }
        let when = date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "pt_BR")))
        return "\(item.contents) · usado \(when)"
    }
}

/// Onde o disco procura projetos, com o botão para mudar.
struct RootsLine: View {
    @ObservedObject var model: CleanModel
    @State private var editing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Procura em \(model.roots.map(tilde).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
                if !model.deniedRoots.isEmpty {
                    Text("Sem permissão para ler \(model.deniedRoots.map(tilde).joined(separator: ", ")): libere em Ajustes do Sistema → Privacidade e Segurança → Arquivos e Pastas → Disco.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .lineLimit(2)
            Spacer(minLength: 8)
            Button("Pastas…") { editing = true }
                .popover(isPresented: $editing, arrowEdge: .bottom) { RootsEditor(model: model) }
        }
        .font(.system(size: 11))
        .padding(.leading, 74)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }
}

/// Pastas onde o disco procura projetos: tirar, pôr e voltar ao padrão (Mesa, Documentos e Developer).
struct RootsEditor: View {
    @ObservedObject var model: CleanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pastas de projetos").font(.system(size: 13, weight: .semibold))
                Text("O disco procura builds e dependências dentro destas pastas, em até 8 níveis.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.roots.enumerated()), id: \.element.path) { index, url in
                    if index > 0 { Divider().padding(.leading, 34) }
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                        Text(tilde(url)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            model.setRoots(model.roots.filter { $0 != url })
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Parar de procurar aqui")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                }
            }
            .groupBox()
            HStack {
                Button("Voltar ao padrão") { model.setRoots(ProjectScanner.defaultRoots) }
                    .disabled(model.roots == ProjectScanner.defaultRoots)
                Spacer()
                Button("Adicionar pasta…", action: add)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar"
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { url in !model.roots.contains { $0.path == url.path } }
        model.setRoots(model.roots + new)
    }
}

private func tilde(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

/// Swap não entra na seleção (o macOS não deixa apagar): leva à Visão geral, onde encerrar
/// os apps que a ocupam devolve o espaço.
struct SwapLink: View {
    let used: Int64
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "memorychip")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(used > 0 ? "Swap: \(ramLabel(used)) em uso" : "Swap: nada em uso")
                        .font(.system(size: 13))
                        .monospacedDigit()
                    Text("Não dá para apagar direto. Encerrar os apps que mais usam memória devolve esse espaço.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Ver apps")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.brandPurple)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brandPurple)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .groupBox()
    }
}

extension Cleaner {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: Componentes

/// Caixa agrupada no estilo dos Ajustes do Sistema.
private extension View {
    func groupBox() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        )
    }
}

struct StatCard<Action: View>: View {
    let title: String
    let fraction: Double
    let tint: Color
    let primary: String
    let secondary: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(primary).font(.system(size: 12)).monospacedDigit()
                Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                action().padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .groupBox()
    }
}

struct AppRow: View {
    let app: TopApp
    let share: Double
    let onKill: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcon(app.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 13)).lineLimit(1)
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.brandMint)
                        .frame(width: max(geo.size.width * share, 3))
                }
                .frame(height: 3)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(ramLabel(app.bytes))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // Abaixo de ~50 MB é ruído; não vale a linha.
                if let swap = app.swap, swap >= 50 * 1_048_576 {
                    Text("≈ \(ramLabel(swap)) swap")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Estimativa da parte deste app na swap. Encerrar o app devolve esse espaço.")
                }
            }
            .monospacedDigit()
            .frame(width: 84, alignment: .trailing)
            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .help("Forçar encerrar \(app.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// App ou ferramenta com o espaço que ocupa e as partes maiores. Clicando, abre o detalhe com como liberar espaço.
struct SpaceRow: View {
    @ObservedObject var model: SpaceModel
    let group: SpaceGroup
    let share: Double
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 10) {
                icon.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.system(size: 13)).lineLimit(1)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.brandPurple)
                            .frame(width: max(geo.size.width * share, 3))
                    }
                    .frame(height: 3)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(Cleaner.format(group.bytes))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(hovering || showing ? AnyShapeStyle(Color.brandPurple) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Onde está o espaço de \(group.name) e como liberar")
        .popover(isPresented: $showing, arrowEdge: .trailing) { SpaceDetail(model: model, group: group) }
    }

    @ViewBuilder
    private var icon: some View {
        if let path = group.iconPath {
            Image(nsImage: appIcon(path)).resizable()
        } else {
            Image(systemName: group.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.brandPurple.opacity(0.85), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    /// As maiores coisas de dentro numa linha: "Emulador 5,7 GB · NDK 28.2 2,8 GB · …".
    private var summary: String {
        group.leaves.prefix(3)
            .map { "\($0.label) \(Cleaner.format($0.bytes))" }
            .joined(separator: " · ")
    }
}

/// Detalhe de um item da lista de espaço: cada parte, que se abre no que tem dentro, com lupa (Finder) e lixeira;
/// como liberar e, quando dá, o botão que libera com um clique.
struct SpaceDetail: View {
    @ObservedObject var model: SpaceModel
    let group: SpaceGroup
    @State private var expanded: Set<String> = []

    private var parts: [SpaceItem] { group.parts.sorted { $0.bytes > $1.bytes } }

    /// Altura da lista: cresce com as partes abertas, até rolar.
    private var listHeight: CGFloat {
        let rows = parts.reduce(0) { $0 + 1 + (expanded.contains($1.id) ? $1.children.count : 0) }
        return min(CGFloat(rows) * 27, 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Cleaner.format(group.bytes))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        if index > 0 { Divider() }
                        SpaceItemRow(model: model, group: group, item: part, expanded: expanded.contains(part.id)) {
                            withAnimation(.snappy(duration: 0.2)) {
                                if expanded.contains(part.id) { expanded.remove(part.id) } else { expanded.insert(part.id) }
                            }
                        }
                        if expanded.contains(part.id) {
                            ForEach(part.children) { child in
                                SpaceItemRow(model: model, group: group, item: child, nested: true)
                            }
                        }
                    }
                }
            }
            .frame(height: listHeight)
            VStack(alignment: .leading, spacing: 4) {
                Label("Como liberar espaço", systemImage: "lightbulb")
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(group.tip))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(group.optimizations) { optimization in
                let running = model.running == optimization.id
                Button { model.optimize(optimization) } label: {
                    CapsuleLabel(
                        title: running ? "Apagando…" : "\(optimization.title) · \(Cleaner.format(optimization.bytes))",
                        systemImage: "trash", fullWidth: true
                    )
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(model.running != nil)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// Uma linha do detalhe: seta para abrir (se tiver o que mostrar dentro), nome, tamanho, lupa e lixeira.
struct SpaceItemRow: View {
    @ObservedObject var model: SpaceModel
    let group: SpaceGroup
    let item: SpaceItem
    var nested = false
    var expanded = false
    var onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            // Seta e nome são um botão só: abre e fecha o que tem dentro.
            Button { onToggle?() } label: {
                HStack(spacing: 8) {
                    if nested {
                        Color.clear.frame(width: 20, height: 1)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                            .opacity(item.children.isEmpty ? 0 : 1)
                    }
                    Text(item.label)
                        .font(.system(size: nested ? 11 : 12))
                        .foregroundStyle(nested ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.children.isEmpty)
            .help(item.children.isEmpty ? "" : (expanded ? "Fechar" : "Ver o que tem dentro"))
            Text(Cleaner.format(item.bytes))
                .font(.system(size: nested ? 11 : 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Mostrar no Finder: \(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
            trash.frame(width: 14)
        }
        .frame(height: 27)
    }

    /// Lixeira ativa quando dá para apagar; riscada, com o motivo na dica, quando não dá.
    @ViewBuilder
    private var trash: some View {
        if model.running == item.id {
            ProgressView().controlSize(.mini)
        } else {
            switch item.removal {
            case .blocked(let reason):
                Image(systemName: "trash.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help(reason)
            case .trash(let note):
                removeButton(help: "Mover para a Lixeira. \(note)")
            case .simulator:
                removeButton(help: "Apagar o simulador, com os apps e arquivos dele (de vez, pelo Xcode).")
            case .runtime:
                removeButton(help: "Apagar esta versão do iOS para os simuladores (de vez, pelo Xcode).")
            }
        }
    }

    private func removeButton(help: String) -> some View {
        Button { model.remove(item, in: group) } label: {
            Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(model.running != nil)
        .help(help)
    }
}

/// Estado da atualização em uma linha: link para procurar, progresso, resultado ou o botão para atualizar.
struct UpdateStatus: View {
    @ObservedObject var updater: Updater
    var onInstall: () -> Void = { Updater.shared.confirmAndInstall() }
    @State private var hovering = false

    var body: some View {
        Group {
            switch updater.state {
            case .idle:
                Button { updater.check(userInitiated: true) } label: {
                    Label("Procurar atualizações", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            case .checking:
                progress("Procurando atualizações…")
            case .installing(let step):
                progress(step)
            case .upToDate:
                Label("Você tem a versão mais recente", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            case .available(let release):
                Button(action: onInstall) {
                    CapsuleLabel(title: "Atualizar para \(release.version)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(CapsuleButtonStyle())
                .help("Nova versão do Disco disponível no GitHub")
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

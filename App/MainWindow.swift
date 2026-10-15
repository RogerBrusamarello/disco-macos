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

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .updates: "arrow.down.circle"
        }
    }

    var help: String {
        switch self {
        case .overview: "Disco, memória e apps que mais usam memória"
        case .clean: "Escolher e abduzir arquivos temporários"
        case .updates: "Versão instalada e versões novas no GitHub"
        }
    }
}

enum WindowTheme: String {
    case light, dark
}

@MainActor
final class WindowState: ObservableObject {
    @Published var tab: WindowTab = .overview
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
    private let state = WindowState()
    private let onKill: (String) -> Void
    private var themeObserver: AnyCancellable?

    var isVisible: Bool { window?.isVisible ?? false }

    init(onKill: @escaping (String) -> Void) {
        self.onKill = onKill
        model.appLimit = 10
    }

    func show(tab: WindowTab? = nil) {
        if window == nil {
            let root = MainView(
                model: model,
                cleanModel: cleanModel,
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
        if state.tab == .clean { cleanModel.scan() }
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
    @ObservedObject var state: WindowState
    @ObservedObject var updater = Updater.shared
    let onKill: (String) -> Void
    let onActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Hierarquia: marca primeiro, depois a troca de aba.
            TabToggle(selection: $state.tab)
                .frame(width: 400)
                .frame(maxWidth: .infinity)
            Group {
                switch state.tab {
                case .overview: overview
                case .clean:
                    CleanView(model: cleanModel) {
                        withAnimation(.snappy(duration: 0.25)) { state.tab = .overview }
                    }
                case .updates: UpdatesView(updater: updater)
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
                Text("Mais usam memória")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
                ScrollView {
                    VStack(spacing: 0) {
                        let maxBytes = max(model.apps.first?.bytes ?? 1, 1)
                        ForEach(Array(model.apps.enumerated()), id: \.element.path) { index, app in
                            if index > 0 { Divider().padding(.leading, 44) }
                            AppRow(app: app, share: Double(app.bytes) / Double(maxBytes)) { onKill(app.path) }
                        }
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
                .padding(.horizontal, 4)  // mesma margem de "Mais usam memória"
                .padding(.top, 2)
            }
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
                HStack {
                    Text("Procurar automaticamente todo dia").font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $updater.checksDaily)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(.brandPurple)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
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
                    ForEach(Array(Cleaner.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 44) }
                        CleanRow(
                            item: item,
                            size: model.sizes[item.id],
                            selected: model.selected.contains(item.id)
                        ) { model.toggle(item.id) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .groupBox()
            .disabled(model.cleaning)

            SwapLink(used: model.swapUsed, action: onShowApps)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(footerCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(model.freed != nil ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    Text(Cleaner.format(model.total))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: model.total)
                }
                Spacer()
                if model.cleaning || model.scanning {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                }
                Button(action: model.clean) {
                    CapsuleLabel(title: model.cleaning ? "Abduzindo…" : "Abduzir selecionados", systemImage: "sparkles")
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(model.selected.isEmpty || model.cleaning)
            }
            .padding(.horizontal, 4)
        }
    }

    private var footerCaption: String {
        if let freed = model.freed { return "✓ \(Cleaner.format(freed)) liberados · selecionado agora" }
        return model.scanning ? "Calculando…" : "Selecionado"
    }
}

struct CleanRow: View {
    let item: CleanItem
    let size: Int64?
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.brandPurple) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13))
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
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
            .padding(.horizontal, 12)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
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

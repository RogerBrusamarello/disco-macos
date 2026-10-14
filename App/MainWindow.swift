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
private let tabHeight: CGFloat = 352

struct MainView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var cleanModel: CleanModel
    @ObservedObject var state: WindowState
    let onKill: (String) -> Void
    let onActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Hierarquia: marca primeiro, depois a troca de aba.
            TabSegments(selection: $state.tab)
                .frame(width: 240)
                .frame(maxWidth: .infinity)
            Group {
                switch state.tab {
                case .overview: overview
                case .clean: CleanView(model: cleanModel)
                }
            }
            .frame(height: tabHeight, alignment: .top)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.top, 34)  // abaixo dos botões da janela
        .padding(.bottom, 20)
        .frame(width: 560)
        .overlay(alignment: .topTrailing) {
            ThemeToggle(state: state)
                .padding(.top, 5)  // na linha dos botões fechar/minimizar
                .padding(.trailing, 10)
        }
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
            }
        }
    }
}

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

/// Controle segmentado nativo do macOS (HIG): segmentos de mesma largura, um selecionado por vez.
struct TabSegments: NSViewRepresentable {
    @Binding var selection: WindowTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: WindowTab.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentDistribution = .fillEqually
        control.segmentStyle = .automatic
        control.controlSize = .regular
        // HIG (macOS): se o app usa dicas, uma por segmento.
        control.setToolTip("Disco, memória e apps que mais usam memória", forSegment: 0)
        control.setToolTip("Escolher e abduzir arquivos temporários", forSegment: 1)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = WindowTab.allCases.firstIndex(of: selection) ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<WindowTab>
        init(selection: Binding<WindowTab>) { self.selection = selection }

        @objc func changed(_ sender: NSSegmentedControl) {
            selection.wrappedValue = WindowTab.allCases[sender.selectedSegment]
        }
    }
}

// MARK: Limpeza

struct CleanView: View {
    @ObservedObject var model: CleanModel

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
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
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
                        .fill(Color.brandMint.gradient)
                        .frame(width: max(geo.size.width * share, 3))
                }
                .frame(height: 3)
            }
            Text(ramLabel(app.bytes))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

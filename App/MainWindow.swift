import AppKit
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

/// Janela compacta no estilo dos Ajustes do Sistema, com a marca só no cabeçalho.
/// Enquanto está aberta, o app aparece no Dock e no ⌘Tab.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = StatsModel()
    private let onClean: () -> Void
    private let onKill: (String) -> Void

    var isVisible: Bool { window?.isVisible ?? false }

    init(onClean: @escaping () -> Void, onKill: @escaping (String) -> Void) {
        self.onClean = onClean
        self.onKill = onKill
        model.appLimit = 10
    }

    func show() {
        if window == nil {
            let root = MainView(
                model: model,
                onClean: { [weak self] in self?.onClean() },
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
        }
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

struct MainView: View {
    @ObservedObject var model: StatsModel
    let onClean: () -> Void
    let onKill: (String) -> Void
    let onActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(spacing: 12) {
                StatCard(
                    title: "Macintosh HD",
                    fraction: model.diskFraction,
                    tint: .diskTint(model.diskFraction),
                    primary: "\(gb(model.disk.total - model.disk.free)) de \(gb(model.disk.total)) GB",
                    secondary: "\(gb(model.disk.free)) GB livres"
                ) {
                    Button("Limpar cache…", action: onClean)
                    .buttonStyle(.borderedProminent)
                    .tint(.brandPurple)
                }
                StatCard(
                    title: "Memória",
                    fraction: model.memoryFraction,
                    tint: .memoryTint(model.memory.pressure),
                    primary: "\(ramGB(model.memory.used)) de \(ramGB(model.memory.total)) GB",
                    secondary: pressureLabel(model.memory.pressure).capitalizedFirst
                ) {
                    Button("Monitor de Atividade", action: onActivity)
                }
            }
            appsSection
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.top, 34)  // abaixo dos botões da janela
        .padding(.bottom, 20)
        .frame(width: 560)
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
        }
    }

    private var appsSection: some View {
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
            .frame(height: 6 * 37)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .groupBox()
        }
    }
}

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
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(primary).font(.system(size: 12)).monospacedDigit()
                Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                action().padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
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
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Forçar encerrar \(app.name)")
            .opacity(hovering ? 1 : 0)
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

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
    static func dmSans(_ size: CGFloat) -> Font { .custom("DMSans-14pt", size: size) }
}

extension Color {
    /// Fundo do ícone
    static let brandNavy = Color(red: 0x07 / 255, green: 0x0D / 255, blue: 0x39 / 255)
    static let brandBlue = Color(red: 0x0B / 255, green: 0x2B / 255, blue: 0x70 / 255)
}

/// Janela centralizada com a identidade do disco. Enquanto está aberta, o app aparece no Dock e no ⌘Tab.
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
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Color.brandNavy)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: root)
            window.setContentSize(window.contentView!.fittingSize)
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
        VStack(spacing: 18) {
            header
            HStack(spacing: 16) {
                GaugeCard(
                    title: "Disco",
                    fraction: model.diskFraction,
                    tint: .diskTint(model.diskFraction),
                    gradient: [.brandPurple, .brandCyan],
                    primary: "\(gb(model.disk.total - model.disk.free)) de \(gb(model.disk.total)) GB",
                    secondary: "\(gb(model.disk.free)) GB livres",
                    button: ("Limpar cache", "sparkles", onClean)
                )
                GaugeCard(
                    title: "Memória",
                    fraction: model.memoryFraction,
                    tint: .memoryTint(model.memory.pressure),
                    gradient: [.brandMint, .brandCyan],
                    primary: "\(ramGB(model.memory.used)) de \(ramGB(model.memory.total)) GB",
                    secondary: pressureLabel(model.memory.pressure).capitalizedFirst,
                    button: ("Monitor de Atividade", "waveform.path.ecg", onActivity)
                )
            }
            appsCard
            Text("Abre junto com o Mac · fica na barra de menus")
                .font(.dmSans(11))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 600)
        .background(background)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [.brandBlue, .brandNavy], startPoint: .top, endPoint: .bottom)
            // brilho do feixe atrás da ilustração
            RadialGradient(colors: [Color.brandMint.opacity(0.28), .clear], center: .init(x: 0.5, y: 0.17), startRadius: 0, endRadius: 230)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 2) {
            Image("Ilustracao")
                .resizable()
                .interpolation(.high)
                .frame(width: 136, height: 136)
                .shadow(color: .brandMint.opacity(0.35), radius: 24)
            Text("disco")
                .font(.fredoka(48))
                .foregroundStyle(.white)
                .padding(.top, -6)
            Text("Dê espaço ao seu Mac.")
                .font(.dmSans(16))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mais usam memória")
                .font(.fredoka(15))
                .foregroundStyle(.white.opacity(0.9))
            let maxBytes = max(model.apps.first?.bytes ?? 1, 1)
            ForEach(model.apps, id: \.path) { app in
                AppBarRow(app: app, share: Double(app.bytes) / Double(maxBytes)) { onKill(app.path) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct GaugeCard: View {
    let title: String
    let fraction: Double
    let tint: Color
    let gradient: [Color]
    let primary: String
    let secondary: String
    let button: (title: String, icon: String, action: () -> Void)

    /// Normal: degradê da marca; alerta: cor sólida (laranja/vermelho).
    private var ringStyle: AnyShapeStyle {
        tint == gradient.first
            ? AnyShapeStyle(AngularGradient(colors: gradient + [gradient[0]], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
            : AnyShapeStyle(tint)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.fredoka(17))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringStyle, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 8)
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.fredoka(34))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 112, height: 112)
            VStack(spacing: 2) {
                Text(primary).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(secondary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .monospacedDigit()
            Button(action: button.action) {
                Label(button.title, systemImage: button.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.brandPurple.gradient, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .glassCard()
    }
}

struct AppBarRow: View {
    let app: TopApp
    let share: Double
    let onKill: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcon(app.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text(ramLabel(app.bytes)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [.brandMint, .brandCyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(geo.size.width * share, 4))
                    }
                }
                .frame(height: 4)
            }
            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.3))
            }
            .buttonStyle(.plain)
            .help("Forçar encerrar \(app.name)")
            .onHover { hovering = $0 }
        }
    }
}

private extension View {
    func glassCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

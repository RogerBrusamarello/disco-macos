import AppKit
import SwiftUI

/// Números ao vivo do popover; só atualiza (a cada 2s) enquanto ele está aberto.
@MainActor
final class StatsModel: ObservableObject {
    @Published var disk: (total: Int64, free: Int64) = (0, 0)
    @Published var memory: (total: Int64, used: Int64, pressure: Int32) = (0, 0, 1)
    @Published var apps: [TopApp] = []
    var appLimit = 5
    private var timer: Timer?

    var diskFraction: Double { disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0 }
    var memoryFraction: Double { memory.total > 0 ? min(Double(memory.used) / Double(memory.total), 1) : 0 }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        disk = Metrics.disk()
        memory = Metrics.memory()
        apps = Sampler.topApps(limit: appLimit)
    }
}

@MainActor
private let panelRadius: CGFloat = 16

/// Máscara esticável com cantos arredondados para o vidro do painel.
private func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// Contorno fino e claro, como o dos painéis da Central de Controle; acompanha o tema.
final class PanelBorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = panelRadius
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // não rouba cliques

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    private func updateBorder() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1)).cgColor
    }
}

/// Painel que pode receber cliques sem ativar o app (como os da Central de Controle).
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuBarPanel
    private let host: NSHostingView<PopoverView>
    private let model = StatsModel()
    private var iconTimer: Timer?
    private var clickOutsideMonitor: Any?

    private var isShown: Bool { panel.isVisible }

    init(onClean: @escaping () -> Void, onKill: @escaping (String) -> Void, onOpen: @escaping () -> Void) {
        // Painel sem setinha: vidro translúcido, cantos arredondados e sombra, logo abaixo do ícone.
        panel = MenuBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        host = NSHostingView(rootView: PopoverView(model: model, onClean: {}, onKill: { _ in }, onOpen: {}))
        super.init()

        host.rootView = PopoverView(
            model: model,
            onClean: { [weak self] in self?.close(); onClean() },
            onKill: { [weak self] path in self?.close(); onKill(path) },
            onOpen: { [weak self] in self?.close(); onOpen() }
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // O vidro (desfoque do que está atrás) só é recortado por maskImage; cornerRadius não basta.
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.maskImage = roundedMask(radius: panelRadius)
        let border = PanelBorderView()
        for view in [host, border] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                view.topAnchor.constraint(equalTo: glass.topAnchor),
                view.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
        }
        panel.contentView = glass

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
        }
        refreshIcon()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
    }

    @objc private func toggle() {
        isShown ? close() : show()
    }

    private func show() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        model.start()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        // Centralizado sob o ícone, sem sair da tela.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        // Sem ativar o app: assim a janela do Disco (se aberta) não vem para frente junto.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()  // sombra acompanha os cantos arredondados
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        button.highlight(true)

        // Como os menus de Som/Wi-Fi: qualquer clique fora fecha.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func close() {
        guard isShown else { return }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [panel] in
            panel.orderOut(nil)
        }
        model.stop()
        refreshIcon()
    }

    /// Clicou em outra janela do próprio app (ex.: a janela do Disco): fecha também.
    func windowDidResignKey(_ notification: Notification) { close() }

    /// Só o disco voador em contorno; os números ficam na dica e no popover.
    func refreshIcon() {
        guard let button = item.button else { return }
        let disk = Metrics.disk()
        let memory = Metrics.memory()
        button.image = ufoOutline
        button.toolTip = "Memória: \(ramGB(memory.used)) de \(ramGB(memory.total)) GB · \(pressureLabel(memory.pressure))\n"
            + "Macintosh HD: \(gb(disk.free)) GB livres"
    }
}

/// Disco voador em contorno, a partir de brand/menubar.svg (viewBox 32×20):
/// silhueta externa + linha da aba sob a cúpula + linha da base.
let ufoOutline: NSImage = {
    let line: CGFloat = 1.3
    let scale: CGFloat = 0.72
    let size = NSSize(width: 32 * scale + line, height: 20 * scale + line)
    let image = NSImage(size: size, flipped: true) { _ in
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale + line / 2, y: y * scale + line / 2) }

        let body = NSBezierPath()
        body.move(to: pt(16, 0))
        body.curve(to: pt(6.5, 7), controlPoint1: pt(10.8, 0), controlPoint2: pt(7.4, 2.8))
        body.curve(to: pt(0, 11), controlPoint1: pt(2.6, 7.9), controlPoint2: pt(0, 9.3))
        body.curve(to: pt(10, 16.2), controlPoint1: pt(0, 13.5), controlPoint2: pt(4.5, 15.4))
        body.line(to: pt(10, 18))
        body.curve(to: pt(16, 20), controlPoint1: pt(10, 19.1), controlPoint2: pt(12.7, 20))
        body.curve(to: pt(22, 18), controlPoint1: pt(19.3, 20), controlPoint2: pt(22, 19.1))
        body.line(to: pt(22, 16.2))
        body.curve(to: pt(32, 11), controlPoint1: pt(27.5, 15.4), controlPoint2: pt(32, 13.5))
        body.curve(to: pt(25.5, 7), controlPoint1: pt(32, 9.3), controlPoint2: pt(29.4, 7.9))
        body.curve(to: pt(16, 0), controlPoint1: pt(24.6, 2.8), controlPoint2: pt(21.2, 0))
        body.close()

        let details = NSBezierPath()
        details.move(to: pt(6.5, 7))     // aba sob a cúpula
        details.curve(to: pt(25.5, 7), controlPoint1: pt(12, 9), controlPoint2: pt(20, 9))
        details.move(to: pt(10, 16.2))   // topo da base
        details.curve(to: pt(22, 16.2), controlPoint1: pt(14, 16.9), controlPoint2: pt(18, 16.9))

        NSColor.black.setStroke()
        for path in [body, details] {
            path.lineWidth = line
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Disco"
    return image
}()

private func icon(_ path: String) -> NSImage {
    let image = NSWorkspace.shared.icon(forFile: path)
    image.size = NSSize(width: 64, height: 64)
    return image
}

private let driveIcon = icon("/")
private let activityIcon = icon("/System/Applications/Utilities/Activity Monitor.app")

struct Bar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(geo.size.width * fraction, 6))
            }
        }
        .frame(height: 6)
    }
}

struct StatSection: View {
    let icon: NSImage
    let title: String
    let fraction: Double
    let tint: Color
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Bar(fraction: fraction, tint: tint)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct AppLine: View {
    let app: TopApp
    let onKill: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon(app.path)).resizable().frame(width: 18, height: 18)
            Text(app.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Text(ramLabel(app.bytes))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .help("Forçar encerrar \(app.name)")
            .onHover { hovering = $0 }
        }
        .padding(.vertical, 1)
    }
}

struct PopoverView: View {
    @ObservedObject var model: StatsModel
    let onClean: () -> Void
    let onKill: (String) -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("Ilustracao")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                Text("disco").font(.fredoka(19))
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                StatSection(
                    icon: driveIcon,
                    title: "Macintosh HD",
                    fraction: model.diskFraction,
                    tint: .diskTint(model.diskFraction),
                    detail: "\(gb(model.disk.total - model.disk.free)) de \(gb(model.disk.total)) GB · \(gb(model.disk.free)) GB livres"
                )
                Button(action: onClean) {
                    CapsuleLabel(title: "Abduzir temporários", systemImage: "sparkles", fullWidth: true)
                }
                .buttonStyle(CapsuleButtonStyle())
            }
            .module()

            VStack(alignment: .leading, spacing: 12) {
                StatSection(
                    icon: activityIcon,
                    title: "Memória",
                    fraction: model.memoryFraction,
                    tint: .memoryTint(model.memory.pressure),
                    detail: "\(ramGB(model.memory.used)) de \(ramGB(model.memory.total)) GB · \(pressureLabel(model.memory.pressure))"
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mais usam memória")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.apps, id: \.path) { app in
                        AppLine(app: app) { onKill(app.path) }
                    }
                }
            }
            .module()

            Button(action: onOpen) {
                CapsuleLabel(title: "Abrir Disco", systemImage: "macwindow", style: .outline, fullWidth: true)
            }
            .buttonStyle(CapsuleButtonStyle())
        }
        .padding(12)
        .frame(width: 320)
    }
}

private extension View {
    /// Cartão no estilo dos módulos da Central de Controle.
    func module() -> some View {
        padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

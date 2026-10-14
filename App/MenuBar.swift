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
final class StatusController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = StatsModel()
    private var iconTimer: Timer?
    private var clickOutsideMonitor: Any?

    init(onClean: @escaping () -> Void, onKill: @escaping (String) -> Void, onOpen: @escaping () -> Void) {
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
        }
        refreshIcon()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        popover.behavior = .transient
        popover.delegate = self
        let root = PopoverView(
            model: model,
            onClean: { [weak self] in self?.close(); onClean() },
            onKill: { [weak self] path in self?.close(); onKill(path) },
            onOpen: { [weak self] in self?.close(); onOpen() },
            onActivity: { [weak self] in
                self?.close()
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        )
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            close()
        } else {
            model.start()
            // Sem ativar o app: assim a janela do Disco (se aberta) não vem para frente junto.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Como os menus de Som/Wi-Fi: qualquer clique fora fecha.
            clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    private func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        model.stop()
        refreshIcon()
    }

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
                Capsule().fill(tint.gradient).frame(width: max(geo.size.width * fraction, 6))
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

/// Linha clicável no estilo do rodapé dos menus de Som/Wi-Fi.
struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PopoverView: View {
    @ObservedObject var model: StatsModel
    let onClean: () -> Void
    let onKill: (String) -> Void
    let onOpen: () -> Void
    let onActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatSection(
                icon: driveIcon,
                title: "Macintosh HD",
                fraction: model.diskFraction,
                tint: .diskTint(model.diskFraction),
                detail: "\(gb(model.disk.total - model.disk.free)) de \(gb(model.disk.total)) GB · \(gb(model.disk.free)) GB livres"
            )
            Button(action: onClean) {
                Label("Limpar cache…", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.brandPurple)

            Divider()

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

            Divider()

            VStack(spacing: 0) {
                MenuRow(title: "Abrir Disco…", action: onOpen)
                MenuRow(title: "Monitor de Atividade…", action: onActivity)
            }
            .padding(.horizontal, -8)
            .padding(.top, -6)
        }
        .padding(16)
        .frame(width: 310)
    }
}

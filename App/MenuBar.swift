import AppKit
import SwiftUI

/// Números ao vivo do popover; só atualiza (a cada 2s) enquanto ele está aberto.
@MainActor
final class StatsModel: ObservableObject {
    @Published var disk: (total: Int64, free: Int64) = (0, 0)
    @Published var memory: (total: Int64, used: Int64, pressure: Int32) = (0, 0, 1)
    @Published var apps: [TopApp] = []
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
        apps = Sampler.topApps(limit: 5)
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = StatsModel()
    private var iconTimer: Timer?

    init(onClean: @escaping () -> Void, onKill: @escaping (String) -> Void) {
        super.init()
        if let button = item.button {
            button.imagePosition = .imageRight
            button.target = self
            button.action = #selector(toggle)
        }
        refreshIcon()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        popover.behavior = .transient
        popover.delegate = self
        let root = PopoverView(
            model: model,
            onClean: { [weak self] in self?.close(); onClean() },
            onKill: { [weak self] path in self?.close(); onKill(path) },
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        model.stop()
        refreshIcon()
    }

    /// "84%" + ícone de disco que enche, no estilo do ícone de bateria.
    func refreshIcon() {
        guard let button = item.button else { return }
        let disk = Metrics.disk()
        let fraction = disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0
        let critical = fraction >= 0.9
        button.image = gaugeImage(fraction: fraction, critical: critical)
        button.attributedTitle = NSAttributedString(
            string: "\(Int((fraction * 100).rounded()))% ",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .baselineOffset: 0.5,
            ]
        )
        button.toolTip = "Macintosh HD: \(gb(disk.free)) GB livres"
    }

    /// Ícone de disco que "enche" da esquerda para a direita conforme o uso.
    private func gaugeImage(fraction: Double, critical: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: "Disco")?
            .withSymbolConfiguration(config) else { return NSImage() }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.3)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: rect.width * fraction, height: rect.height)).addClip()
            symbol.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            if critical {
                NSColor.systemRed.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        // Template = segue a cor da barra de menus; vermelho precisa ser imagem colorida.
        image.isTemplate = !critical
        return image
    }
}

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
            .help("Forçar encerramento")
            .onHover { hovering = $0 }
        }
        .padding(.vertical, 1)
    }
}

struct PopoverView: View {
    @ObservedObject var model: StatsModel
    let onClean: () -> Void
    let onKill: (String) -> Void
    let onActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatSection(
                icon: driveIcon,
                title: "Macintosh HD",
                fraction: model.diskFraction,
                tint: model.diskFraction < 0.9 ? .blue : .red,
                detail: "\(gb(model.disk.total - model.disk.free)) de \(gb(model.disk.total)) GB · \(gb(model.disk.free)) GB livres"
            )
            Button(action: onClean) {
                Label("Limpar cache…", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Divider()

            StatSection(
                icon: activityIcon,
                title: "Memória",
                fraction: model.memoryFraction,
                tint: model.memory.pressure == 4 ? .red : model.memory.pressure == 2 ? .orange : .blue,
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

            Button("Monitor de Atividade", action: onActivity)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 310)
    }
}

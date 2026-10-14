import WidgetKit
import SwiftUI
import AppIntents

/// Botão interativo: o WidgetKit recarrega a timeline sozinho depois do perform().
/// Conta os cliques por widget para o ↻ dar uma volta a cada atualização manual.
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Atualizar"

    @Parameter(title: "Widget") var kind: String

    init() {}
    init(kind: String) { self.kind = kind }

    func perform() async throws -> some IntentResult {
        Spins.increment(kind)
        return .result()
    }
}

enum Spins {
    static func count(_ kind: String) -> Int { UserDefaults.standard.integer(forKey: "spins.\(kind)") }
    static func increment(_ kind: String) { UserDefaults.standard.set(count(kind) + 1, forKey: "spins.\(kind)") }
}

struct DiskEntry: TimelineEntry {
    let date: Date
    let total: Int64
    let free: Int64
    var spins = 0

    var used: Int64 { max(total - free, 0) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DiskEntry {
        let disk = Metrics.disk()
        return DiskEntry(date: .now, total: disk.total, free: disk.free, spins: Spins.count("DiscoWidget"))
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DiskEntry {
        DiskEntry(date: .now, total: 245_000_000_000, free: 40_000_000_000)
    }

    func getSnapshot(in context: Context, completion: @escaping (DiskEntry) -> Void) {
        completion(.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiskEntry>) -> Void) {
        completion(Timeline(entries: [.current()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

extension DiskEntry {
    var tint: Color { .diskTint(fraction) }
    var percent: String { "\(Int((fraction * 100).rounded()))%" }
}

/// Ícone real de um arquivo/app, em alta resolução.
func systemIcon(_ path: String) -> NSImage {
    let icon = NSWorkspace.shared.icon(forFile: path)
    icon.size = NSSize(width: 256, height: 256)
    return icon
}

private let driveIcon = systemIcon("/")

struct RefreshButton: View {
    let kind: String
    let spins: Int

    var body: some View {
        Button(intent: RefreshIntent(kind: kind)) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(Double(spins) * 360))
                .animation(.easeInOut(duration: 0.7), value: spins)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Link do widget com a cápsula padrão (Shared/Brand.swift).
struct ActionButton: View {
    let title: String
    let systemImage: String
    let url: String
    var prominent = true
    var fullWidth = false

    var body: some View {
        Link(destination: URL(string: url)!) {
            CapsuleLabel(title: title, systemImage: systemImage, prominent: prominent, fullWidth: fullWidth)
        }
    }
}

/// Anel no estilo do widget Baterias, com um ícone no centro.
struct UsageRing: View {
    let fraction: Double
    let tint: Color
    let icon: NSImage
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.09)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 0.58, height: size * 0.58)
        }
        .frame(width: size, height: size)
    }
}

struct DiscoWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: DiskEntry

    var body: some View {
        if family == .systemSmall { small } else { medium }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                UsageRing(fraction: entry.fraction, tint: entry.tint, icon: driveIcon, size: 54)
                Spacer(minLength: 0)
                RefreshButton(kind: "DiscoWidget", spins: entry.spins)
            }
            Spacer(minLength: 4)
            Text(entry.percent)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("\(gb(entry.free)) GB livres")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 6)
            ActionButton(title: "Abduzir temporários", systemImage: "sparkles", url: "discowidget://clean", fullWidth: true)
        }
    }

    var medium: some View {
        HStack(spacing: 16) {
            UsageRing(fraction: entry.fraction, tint: entry.tint, icon: driveIcon, size: 104)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Macintosh HD")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    RefreshButton(kind: "DiscoWidget", spins: entry.spins)
                }
                Spacer(minLength: 2)
                Text(entry.percent)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(gb(entry.used)) de \(gb(entry.total)) GB · \(gb(entry.free)) GB livres")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                ActionButton(title: "Abduzir temporários", systemImage: "sparkles", url: "discowidget://clean")
            }
        }
    }
}

struct DiscoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DiscoWidget", provider: Provider()) { entry in
            DiscoWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "discowidget://open"))
        }
        .configurationDisplayName("Disco")
        .description("Uso do disco e limpeza de cache.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

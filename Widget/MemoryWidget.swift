import WidgetKit
import SwiftUI

struct MemoryEntry: TimelineEntry {
    let date: Date
    let total: Int64
    let used: Int64
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 alerta, 4 crítica
    let pressure: Int32
    /// Lista gravada pelo app Disco (o widget não enxerga outros processos por causa do sandbox).
    var apps: [TopApp] = []
    var spins = 0

    var fraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }
    var percent: String { "\(Int((fraction * 100).rounded()))%" }

    var tint: Color { .memoryTint(pressure) }


    static func current() -> MemoryEntry {
        let (total, used, level) = Metrics.memory()
        let snapshot = TopAppsSnapshot.load()
        let fresh = snapshot.map { Date.now.timeIntervalSince($0.date) < 10 * 60 } ?? false
        return MemoryEntry(date: .now, total: total, used: used, pressure: level, apps: fresh ? snapshot!.apps : [], spins: Spins.count("MemoryWidget"))
    }
}

struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry {
        MemoryEntry(date: .now, total: 17_179_869_184, used: 11_000_000_000, pressure: 1)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        completion(.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        completion(Timeline(entries: [.current()], policy: .after(.now.addingTimeInterval(5 * 60))))
    }
}

struct AppRow: View {
    let app: TopApp
    var compact = false

    var killURL: URL {
        var c = URLComponents()
        c.scheme = "discowidget"
        c.host = "kill"
        c.queryItems = [URLQueryItem(name: "app", value: app.path)]
        return c.url!
    }

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Image(nsImage: systemIcon(app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
            Text(app.name)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(ramLabel(app.bytes))
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Link(destination: killURL) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct AppList: View {
    let apps: [TopApp]
    let limit: Int
    let spacing: CGFloat
    var compact = false

    var body: some View {
        if apps.isEmpty {
            Text(compact ? "Abra o app Disco para ver a lista." : "Abra o app Disco para ver os apps que mais usam memória.")
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .center)
        } else {
            VStack(spacing: spacing) {
                ForEach(apps.prefix(limit), id: \.self) { AppRow(app: $0, compact: compact) }
            }
        }
    }
}

private let activityIcon = systemIcon("/System/Applications/Utilities/Activity Monitor.app")

struct MemoryWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: MemoryEntry

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                UsageRing(fraction: entry.fraction, tint: entry.tint, icon: activityIcon, size: 38)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.percent)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                    Text("\(ramGB(entry.used)) de \(entry.total / 1_073_741_824) GB")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .monospacedDigit()
                Spacer(minLength: 0)
                VStack { RefreshButton(kind: "MemoryWidget", spins: entry.spins); Spacer(minLength: 0) }
            }
            .fixedSize(horizontal: false, vertical: true)
            AppList(apps: entry.apps, limit: 4, spacing: 6, compact: true)
            Spacer(minLength: 0)
        }
    }

    var summary: some View {
        VStack(spacing: 2) {
            Text(entry.percent)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("\(ramGB(entry.used)) de \(ramGB(entry.total)) GB")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }

    var medium: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                UsageRing(fraction: entry.fraction, tint: entry.tint, icon: activityIcon, size: 74)
                summary
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Memória")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    RefreshButton(kind: "MemoryWidget", spins: entry.spins)
                }
                AppList(apps: entry.apps, limit: 3, spacing: 7)
                Spacer(minLength: 0)
            }
        }
    }

    var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                UsageRing(fraction: entry.fraction, tint: entry.tint, icon: activityIcon, size: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memória")
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.percent)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("\(ramGB(entry.used)) de \(ramGB(entry.total)) GB · \(pressureLabel(entry.pressure))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                Spacer(minLength: 0)
                VStack { RefreshButton(kind: "MemoryWidget", spins: entry.spins); Spacer() }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Mais usam memória")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            AppList(apps: entry.apps, limit: 7, spacing: 9)
            Spacer(minLength: 0)
            ActionButton(title: "Monitor de Atividade", systemImage: "waveform.path.ecg", url: "discowidget://activity", prominent: false, fullWidth: true)
        }
    }
}

struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MemoryWidget", provider: MemoryProvider()) { entry in
            MemoryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "discowidget://open"))
        }
        .configurationDisplayName("Memória")
        .description("Uso da memória RAM e os apps que mais consomem.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct DiscoWidgets: WidgetBundle {
    var body: some Widget {
        DiscoWidget()
        MemoryWidget()
    }
}

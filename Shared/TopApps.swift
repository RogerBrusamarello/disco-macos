import Foundation

/// App que mais consome memória, gravado pelo app Disco e lido pelo widget.
struct TopApp: Codable, Hashable {
    let name: String
    let path: String
    let bytes: Int64
}

struct TopAppsSnapshot: Codable {
    let date: Date
    let apps: [TopApp]

    static let appGroup = "HM8VRSUTC3.br.com.attodev.disco"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "topapps.json")
    }

    static func load() -> TopAppsSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TopAppsSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

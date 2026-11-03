import Foundation

/// Pastas de um projeto que dá para apagar: o build se recria sozinho, as dependências voltam com `npm install` ou `pod install`.
struct ProjectJunk: Identifiable, Hashable {
    enum Kind: String {
        /// build, .dart_tool, .next, target (e os Pods de um app Flutter, que o `flutter run` reinstala).
        case build
        /// node_modules e Pods: o projeto só volta a rodar depois do `npm install` ou do `pod install`.
        case dependencies
    }

    let kind: Kind
    /// Pasta do projeto, onde está o marcador (pubspec.yaml, package.json, Cargo.toml ou Podfile).
    let project: URL
    /// O que é apagado, inteiro.
    let folders: [URL]
    let bytes: Int64
    /// Última modificação do projeto, do marcador ou das pastas: quando o projeto foi usado.
    let lastUsed: Date?
    /// Um processo está com o cwd dentro do projeto (terminal, servidor, build): fica de fora.
    let inUse: Bool

    var id: String { "\(kind.rawValue):\(project.path)" }
    var name: String { project.lastPathComponent }
    /// "build, .dart_tool"
    var contents: String {
        folders.map { $0.path.replacingOccurrences(of: project.path + "/", with: "") }.joined(separator: ", ")
    }
}

/// Procura nas pastas de projetos o que se recria sozinho. Só conta uma pasta com o marcador do projeto ao lado:
/// um `build/` sem `pubspec.yaml` pode ser código-fonte ou guardar arquivos de release.
enum ProjectScanner {
    private static let fm = FileManager.default
    private static let home = fm.homeDirectoryForCurrentUser

    // MARK: Pastas de projetos

    static let defaultRoots = ["Desktop", "Documents", "Developer"].map { home.appending(path: $0) }

    /// Onde procurar (aba Limpeza → Pastas…). Salvo como caminhos; `-projectRoots '("/caminho")'` troca na linha de comando.
    static var roots: [URL] {
        get { UserDefaults.standard.stringArray(forKey: "projectRoots")?.map { URL(fileURLWithPath: $0) } ?? defaultRoots }
        set {
            let paths = newValue.map(\.path)
            if paths == defaultRoots.map(\.path) {
                UserDefaults.standard.removeObject(forKey: "projectRoots")
            } else {
                UserDefaults.standard.set(paths, forKey: "projectRoots")
            }
        }
    }

    // MARK: Regras

    private struct Rule {
        /// Arquivo que marca o projeto, na pasta do projeto.
        let marker: String
        /// Caminho da pasta apagável, a partir da pasta do projeto.
        let folder: String
        let kind: ProjectJunk.Kind
        /// Arquivo que também tem que estar ao lado da pasta (o Podfile, para os Pods).
        var sibling: String?
    }

    private static let rules = [
        Rule(marker: "pubspec.yaml", folder: "build", kind: .build),
        Rule(marker: "pubspec.yaml", folder: ".dart_tool", kind: .build),
        Rule(marker: "pubspec.yaml", folder: "ios/Pods", kind: .build, sibling: "Podfile"),
        Rule(marker: "pubspec.yaml", folder: "macos/Pods", kind: .build, sibling: "Podfile"),
        Rule(marker: "package.json", folder: ".next", kind: .build),
        Rule(marker: "package.json", folder: "node_modules", kind: .dependencies),
        Rule(marker: "Cargo.toml", folder: "target", kind: .build),
        Rule(marker: "Podfile", folder: "Pods", kind: .dependencies, sibling: "Podfile"),
    ]

    /// Arquivos que só existem num SDK (Flutter, Dart, Android): nada dentro dele é tocado.
    private static let sdkSigns = ["bin/flutter", "bin/cache/dart-sdk", "platform-tools", "build-tools"]
    /// Até onde descer a partir de cada pasta de projetos.
    private static let maxDepth = 8
    /// Abaixo disso o projeto não vale uma linha.
    private static let minimum: Int64 = 1_000_000

    // MARK: Procura

    /// Os projetos com pastas apagáveis, do maior para o menor, e as pastas de projetos sem permissão de leitura.
    /// Demora alguns segundos (node_modules têm muitos arquivos): rode fora da main.
    static func scan(roots: [URL] = roots) -> (junk: [ProjectJunk], denied: [URL]) {
        var found: [(project: URL, kind: ProjectJunk.Kind, folders: [URL])] = []
        var denied: [URL] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            if (try? fm.contentsOfDirectory(atPath: root.path)) == nil {
                denied.append(root)
                continue
            }
            visit(root, depth: 0, inFlutter: false, into: &found)
        }

        let cwds = workingDirectories()
        var junk = [ProjectJunk?](repeating: nil, count: found.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            let (project, kind, folders) = found[i]
            let bytes = folders.reduce(0) { $0 + SpaceScanner.size(of: $1) }
            guard bytes >= minimum else { return }
            let item = ProjectJunk(
                kind: kind, project: project, folders: folders, bytes: bytes,
                lastUsed: lastUsed(project, folders), inUse: isInUse(project, cwds)
            )
            lock.lock()
            junk[i] = item
            lock.unlock()
        }
        return (junk.compactMap { $0 }.sorted { $0.bytes > $1.bytes }, denied)
    }

    /// Olha uma pasta e desce nas de dentro. `inFlutter`: a pasta de cima é um projeto Flutter, que já ficou com os Pods.
    private static func visit(_ dir: URL, depth: Int, inFlutter: Bool, into found: inout [(project: URL, kind: ProjectJunk.Kind, folders: [URL])]) {
        guard !isSDK(dir) else { return }
        let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        var taken: Set<String> = []
        for kind in [ProjectJunk.Kind.build, .dependencies] {
            let folders = rules.filter { $0.kind == kind && names.contains($0.marker) }.compactMap { rule -> URL? in
                if rule.folder == "Pods", inFlutter, ["ios", "macos"].contains(dir.lastPathComponent) { return nil }
                let url = dir.appending(path: rule.folder)
                return isDeletable(url, in: dir) ? url : nil
            }
            guard !folders.isEmpty else { continue }
            found.append((dir, kind, folders))
            taken.formUnion(folders.map { $0.path })
        }
        guard depth < maxDepth else { return }
        let flutter = names.contains("pubspec.yaml")
        for name in names.sorted() where !name.hasPrefix(".") && name != "node_modules" && name != "Pods" {
            let child = dir.appending(path: name)
            guard !taken.contains(child.path), isPlainDirectory(child) else { continue }
            visit(child, depth: depth + 1, inFlutter: flutter, into: &found)
        }
    }

    /// Confere tudo de novo: a pasta bate com uma regra cujo marcador está no projeto, é uma pasta de verdade
    /// (não um atalho) e não fica dentro de node_modules nem de um SDK. Vale para a procura e para a hora de apagar.
    static func isDeletable(_ folder: URL, in project: URL) -> Bool {
        guard folder.path.hasPrefix(project.path + "/") else { return false }
        let relative = String(folder.path.dropFirst(project.path.count + 1))
        guard let rule = rules.first(where: { $0.folder == relative }),
              fm.fileExists(atPath: project.appending(path: rule.marker).path),
              isPlainDirectory(folder),
              !project.pathComponents.contains("node_modules"),
              !isSDK(project)
        else { return false }
        if let sibling = rule.sibling, !fm.fileExists(atPath: folder.deletingLastPathComponent().appending(path: sibling).path) { return false }
        return true
    }

    private static func isSDK(_ dir: URL) -> Bool {
        sdkSigns.contains { fm.fileExists(atPath: dir.appending(path: $0).path) }
    }

    /// Pasta comum: nem atalho, nem pacote (.app, .xcodeproj, .photoslibrary…).
    private static func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true
    }

    private static func lastUsed(_ project: URL, _ folders: [URL]) -> Date? {
        ([project] + folders).compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
    }

    // MARK: Em uso

    /// Pastas atuais (cwd) dos processos do usuário, pelo `lsof`.
    static func workingDirectories() -> [String] {
        let result = SpaceScanner.execute("/usr/sbin/lsof", ["-a", "-d", "cwd", "-F", "n"], timeout: 20)
        let text = String(data: result.output, encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    static func isInUse(_ project: URL, _ cwds: [String]) -> Bool {
        // realpath, como o lsof mostra: resolvingSymlinksInPath tira o /private de /private/tmp.
        let path = project.withUnsafeFileSystemRepresentation { $0.flatMap { realpath($0, nil) } }
            .map { real in defer { free(real) }; return String(cString: real) } ?? project.path
        return cwds.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    // MARK: Limpeza

    /// Apaga as pastas de vez. Antes, confere de novo o marcador de cada pasta e se algum processo está no projeto.
    /// Devolve os projetos que ficaram de fora por estarem em uso.
    static func clean(_ junk: [ProjectJunk]) -> [ProjectJunk] {
        let cwds = workingDirectories()
        var skipped: [ProjectJunk] = []
        for item in junk {
            if isInUse(item.project, cwds) {
                skipped.append(item)
                continue
            }
            for folder in item.folders where isDeletable(folder, in: item.project) {
                try? fm.removeItem(at: folder)
            }
        }
        return skipped
    }
}

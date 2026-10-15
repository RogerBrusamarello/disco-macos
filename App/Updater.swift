import AppKit
import CryptoKit
import Security

/// Atualização pelo GitHub: lê o último release (tag `vX.Y` com o asset `Disco.dmg`), compara com a versão instalada
/// e, se a pessoa aceitar, baixa, confere o sha256 e a assinatura (mesmo time), troca o app no lugar e reabre.
/// Baixado pelo próprio app, o .app não ganha quarentena, então o Gatekeeper não bloqueia a versão nova.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL
        let sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Último release lido do GitHub (também quando já é a versão instalada).
    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    @Published var checksDaily = UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksDaily, forKey: Self.autoCheckKey) }
    }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    let releasesPage = URL(string: "https://github.com/RogerBrusamarello/disco-macos/releases")!

    private static let latestURL = URL(string: "https://api.github.com/repos/RogerBrusamarello/disco-macos/releases/latest")!
    private static let lastCheckKey = "updateLastCheck"
    private static let autoCheckKey = "updateAutoCheck"
    private static let interval: TimeInterval = 24 * 60 * 60
    /// Mesmo app, assinado pelo mesmo time de desenvolvedor.
    private nonisolated static let requirement = #"identifier "br.com.attodev.disco" and anchor apple generic and certificate leaf[subject.OU] = "HM8VRSUTC3""#

    private var timer: Timer?

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: true
        default: false
        }
    }

    /// Checa logo depois de abrir e, a cada hora, vê se já passou um dia desde a última checagem.
    func startDailyChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard checksDaily else { return }
        if Date.now.timeIntervalSince(lastCheck ?? .distantPast) >= Self.interval { check(userInitiated: false) }
    }

    /// Na checagem automática, falhas (sem internet, limite da API) ficam em silêncio.
    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        let previous = state
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                latest = release
                lastCheck = .now
                UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
                if let release, release.version.compare(currentVersion, options: .numeric) == .orderedDescending {
                    state = .available(release)
                } else {
                    state = userInitiated ? .upToDate : .idle
                }
            } catch {
                state = userInitiated ? .failed("Não foi possível procurar atualizações.") : previous
            }
            if userInitiated, state == .upToDate || state.isFailure {
                try? await Task.sleep(for: .seconds(4))
                if state == .upToDate || state.isFailure { state = .idle }
            }
        }
    }

    /// Mostra as novidades e, se a pessoa aceitar, instala e reabre.
    func confirmAndInstall() {
        guard let release = available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Atualizar o Disco para a versão \(release.version)?"
        alert.informativeText = Self.plainNotes(release.notes, limit: 700)
            + "\n\nVocê está na versão \(currentVersion). O Disco fecha e abre de novo sozinho."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Atualizar e Reabrir")
        alert.addButton(withTitle: "Agora Não")
        alert.addButton(withTitle: "Ver no GitHub")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    private func install(_ release: Release) {
        let app = Bundle.main.bundleURL
        // Sem permissão para trocar o app (ex.: usuário sem admin): baixa pelo navegador.
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.dmg)
            return
        }
        state = .installing("Baixando…")
        Task {
            do {
                let staged = try await Self.download(release, replacing: app) { [weak self] step in
                    Task { @MainActor in self?.state = .installing(step) }
                }
                state = .installing("Instalando…")
                try Self.replace(app, with: staged)
                Self.relaunch(app)
            } catch {
                state = .failed((error as? UpdateError)?.message ?? "Não foi possível atualizar.")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Não foi possível atualizar o Disco"
                alert.informativeText = "\((error as? UpdateError)?.message ?? error.localizedDescription)\n\nVocê pode baixar a versão \(release.version) pelo GitHub."
                alert.addButton(withTitle: "Abrir GitHub")
                alert.addButton(withTitle: "Fechar")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
                state = .available(release)
            }
        }
    }

    // MARK: - Etapas

    private struct UpdateError: Error {
        let message: String
    }

    private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Disco-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "GitHub indisponível.") }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let sha256 = dmg.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, notes: payload.body ?? "", page: payload.html_url,
                       dmg: dmg.browser_download_url, sha256: sha256)
    }

    /// Baixa e monta o .dmg, confere hash e assinatura e copia o app para uma pasta no mesmo volume do atual.
    private nonisolated static func download(
        _ release: Release, replacing app: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let (file, response) = try await URLSession.shared.download(from: release.dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "Falha no download.") }
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let dmg = work.appendingPathComponent("Disco.dmg")
        try fm.moveItem(at: file, to: dmg)

        progress("Conferindo…")
        if let expected = release.sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError(message: "O arquivo baixado não confere com o do GitHub.") }
        }

        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appendingPathComponent(app.lastPathComponent)
        let found = fm.fileExists(atPath: source.path)
            ? source
            : try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first { $0.pathExtension == "app" }
        guard let found else { throw UpdateError(message: "O .dmg não tem o app.") }
        try verifySignature(found)

        let staged = work.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [found.path, staged.path])
        try verifySignature(staged)
        return staged
    }

    private nonisolated static func verifySignature(_ app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw UpdateError(message: "A assinatura da versão nova não confere.") }
    }

    /// Troca o app no lugar (o processo atual continua rodando com o binário já carregado)
    /// e registra o app e o widget de novo, como o scripts/install.sh.
    private static func replace(_ app: URL, with staged: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
        } catch {
            throw UpdateError(message: "Sem permissão para substituir \(app.path).")
        }
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try? run(lsregister, ["-f", app.path])
        try? run("/usr/bin/pluginkit", ["-a", app.appendingPathComponent("Contents/PlugIns/DiscoWidgetExtension.appex").path])
    }

    /// Um shell espera este processo sair e abre a versão nova; o widget antigo é encerrado para o sistema carregar o novo.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            pkill -f DiscoWidgetExtension
            open "$0"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "\((tool as NSString).lastPathComponent) falhou (\(process.terminationStatus)).")
        }
    }

    /// Notas do release em Markdown viram texto simples e curto (alerta e aba Atualizações).
    static func plainNotes(_ markdown: String, limit: Int = .max) -> String {
        let lines = markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .components(separatedBy: .newlines)
            .map { line -> String in
                var line = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { line = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }
                return line
            }
        var text = lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > limit { text = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return text
    }
}

private extension Updater.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

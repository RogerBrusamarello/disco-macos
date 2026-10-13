import AppKit
import Darwin

/// Lê a memória ("Memória" do Monitor de Atividade = phys_footprint) de cada processo,
/// agrupando helpers dentro do bundle do app (ex.: os vários processos do Chrome).
enum Sampler {
    /// Só apps instalados de verdade; ignora bundles internos (ex.: o motor do Claude Code em Application Support).
    private static let appFolders = [
        "/Applications/",
        "/System/Applications/",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path + "/",
    ]

    static func topApps(limit: Int = 8) -> [TopApp] {
        var byBundle: [String: Int64] = [:]
        let own = Bundle.main.bundlePath
        for (pid, path) in processes() {
            guard let bundle = outerBundle(of: path), bundle != own,
                  appFolders.contains(where: bundle.hasPrefix) else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 { byBundle[bundle, default: 0] += Int64(info.ri_phys_footprint) }
        }
        return byBundle
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { path, bytes in
                var name = FileManager.default.displayName(atPath: path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                return TopApp(name: name, path: path, bytes: bytes)
            }
    }

    /// Força o encerramento do app e de qualquer processo que tenha sobrado dentro do bundle.
    static func forceQuit(bundlePath: String) {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.path == bundlePath }
            .forEach { $0.forceTerminate() }
        for (pid, path) in processes() where path.hasPrefix(bundlePath + "/") {
            kill(pid, SIGKILL)
        }
    }

    private static func processes() -> [(pid_t, String)] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: 4096)
        return pids.prefix(Int(max(n, 0))).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
            return (pid, String(cString: buf))
        }
    }

    private static func outerBundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

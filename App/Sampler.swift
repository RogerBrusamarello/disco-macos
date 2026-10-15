import AppKit
import Darwin

/// Lê a memória ("Memória" do Monitor de Atividade = phys_footprint) de cada processo,
/// agrupando helpers dentro do bundle do app (ex.: os vários processos do Chrome).
enum Sampler {
    /// Só apps instalados de verdade; bundles internos (ex.: o motor do Claude Code em Application Support)
    /// entram na conta do app que os abriu.
    private static let appFolders = [
        "/Applications/",
        "/System/Applications/",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path + "/",
    ]

    static func topApps(limit: Int = 8) -> [TopApp] {
        var byBundle: [String: (bytes: Int64, compressed: Int64)] = [:]
        for (pid, bundle) in attributed() {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            // O que está no footprint mas não residente está comprimido (na RAM ou na swap).
            // Fica perto da coluna "Memória comprimida" do Monitor de Atividade.
            let footprint = Int64(info.ri_phys_footprint)
            byBundle[bundle, default: (0, 0)].bytes += footprint
            byBundle[bundle, default: (0, 0)].compressed += max(footprint - Int64(info.ri_resident_size), 0)
        }
        // O macOS não diz quanto de cada app foi para a swap, só quanto foi comprimido (na RAM ou no disco).
        // Rateia a swap real pela fatia de cada app no total comprimido, para a soma bater com a swap do sistema.
        let stored = Metrics.compressedStored()
        let swapShare = stored > 0 ? Double(Metrics.swap().used) / Double(stored) : 0
        return byBundle
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(limit)
            .map { path, usage in
                var name = FileManager.default.displayName(atPath: path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                return TopApp(name: name, path: path, bytes: usage.bytes, swap: Int64(Double(usage.compressed) * swapShare))
            }
    }

    /// Força o encerramento do app e de tudo que é contado nele, inclusive processos abertos no terminal do app.
    static func forceQuit(bundlePath: String) {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.path == bundlePath }
            .forEach { $0.forceTerminate() }
        for (pid, bundle) in attributed() where bundle == bundlePath {
            kill(pid, SIGKILL)
        }
    }

    /// Cada processo com o app a que pertence: o .app que o contém ou, para processos de terminal
    /// (node, gopls…), o primeiro app instalado acima dele na cadeia de pais (VS Code, Terminal).
    private static func attributed() -> [(pid_t, String)] {
        let own = Bundle.main.bundlePath
        let all = processes()
        var byPID: [pid_t: (parent: pid_t, path: String)] = [:]
        for (pid, path) in all { byPID[pid] = (parentPID(pid), path) }
        var cache: [pid_t: String?] = [:]
        func app(of pid: pid_t, depth: Int) -> String? {
            if let hit = cache[pid] { return hit }
            guard depth < 32, pid > 1, let proc = byPID[pid] else { return nil }  // 1 = launchd
            let result: String?
            if let bundle = outerBundle(of: proc.path), appFolders.contains(where: bundle.hasPrefix) {
                result = bundle
            } else {
                result = app(of: proc.parent, depth: depth + 1)
            }
            cache[pid] = result
            return result
        }
        return all.compactMap { pid, _ in
            guard let bundle = app(of: pid, depth: 0), bundle != own else { return nil }
            return (pid, bundle)
        }
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
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

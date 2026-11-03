import AppKit

/// Otimização com um clique: apaga algo que a ferramenta baixa ou recria quando precisar.
struct SpaceOptimization: Hashable, Identifiable {
    enum Action: Hashable {
        /// Runtimes de simulador, pelo identificador do `simctl`.
        case deleteRuntimes([String])
        /// ~/.gradle/caches
        case cleanGradleCache
        /// Um simulador, pelo udid.
        case deleteSimulator(String)
    }

    let id: String
    let title: String
    /// Texto do alerta de confirmação.
    let confirmation: String
    let bytes: Int64
    let action: Action
}

/// Como apagar um item da lista de espaço, ou por que não dá.
enum SpaceRemoval: Hashable {
    /// Move para a Lixeira (dá para recuperar). A nota entra na confirmação e na dica.
    case trash(note: String)
    /// Simulador do iOS, pelo `simctl delete` (apaga de vez).
    case simulator(udid: String)
    /// Runtime de simulador, pelo `simctl runtime delete` (apaga de vez).
    case runtime(id: String)
    /// Não dá para apagar pelo disco; o motivo vira a dica da lixeira riscada.
    case blocked(String)
}

/// Uma pasta (ou arquivo) que um app ou ferramenta ocupa no disco, com o que tem dentro.
struct SpaceItem: Identifiable, Hashable {
    let label: String
    let bytes: Int64
    /// O que a lupa mostra (o primeiro) e o que vai para a Lixeira (todos).
    let urls: [URL]
    var removal: SpaceRemoval
    /// Itens de dentro, do maior para o menor (ex.: cada versão do NDK).
    var children: [SpaceItem] = []

    var id: String { label + "|" + (urls.first?.path ?? "") }
    var url: URL { urls.first ?? FileManager.default.homeDirectoryForCurrentUser }

    /// O tamanho como a soma dos itens de dentro.
    func summed() -> SpaceItem {
        SpaceItem(label: label, bytes: children.reduce(0) { $0 + $1.bytes }, urls: urls, removal: removal, children: children)
    }
}

/// App ou ferramenta com tudo o que ocupa no disco, separado em partes, e como liberar espaço.
struct SpaceGroup: Identifiable {
    let id: String
    let name: String
    /// .app usado como ícone (e para saber se está aberto); sem ele, vale o símbolo.
    let iconPath: String?
    let symbol: String
    let parts: [SpaceItem]
    /// Como liberar espaço, em Markdown.
    let tip: String
    var optimizations: [SpaceOptimization] = []

    var bytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }

    /// As maiores coisas de dentro: os itens de cada parte, ou a parte quando ela não se abre.
    var leaves: [SpaceItem] {
        parts.flatMap { $0.children.isEmpty ? [$0] : $0.children }.sorted { $0.bytes > $1.bytes }
    }
}

/// Textos das lixeiras: o que acontece ao apagar, ou por que não dá.
enum SpaceWhy {
    static let cache = "É cache: o app recria sozinho quando precisar."
    static let appData = "Dados do app, como configurações, contas e arquivos. Apagar pode fazer o app perder informações ou parar de abrir. Use a opção de limpar do próprio app."
    static let system = "Faz parte do macOS: não dá para apagar."
    static let permission = "Sem permissão para apagar: pertence ao sistema ou a outro usuário."
    static let several = "Junta pastas diferentes: abra a lista e apague item por item."
    static let uninstall = "Desinstala o app. Os dados dele continuam no Mac: apague também as outras partes, se quiser."
}

/// Mede o que os apps e as ferramentas de desenvolvimento ocupam no disco e diz o que dá para apagar.
/// Não entra em Mesa, Documentos, Downloads nem nos containers de outros apps: o macOS pediria permissão para cada um.
enum SpaceScanner {
    private static let fm = FileManager.default
    private static let home = fm.homeDirectoryForCurrentUser
    private static func h(_ path: String) -> URL { home.appending(path: path) }
    private static let support = h("Library/Application Support")
    private static let caches = h("Library/Caches")

    /// Abaixo disso o grupo não vale uma linha.
    private static let minimum: Int64 = 100_000_000

    private static let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
    private static let androidStudio = URL(fileURLWithPath: "/Applications/Android Studio.app")
    private static let docker = URL(fileURLWithPath: "/Applications/Docker.app")
    private static let ollama = URL(fileURLWithPath: "/Applications/Ollama.app")
    private static let lmStudio = URL(fileURLWithPath: "/Applications/LM Studio.app")
    /// Apps com linha própria abaixo; ficam fora da conta genérica de apps.
    private static let curatedApps = Set([xcode, androidStudio, docker, ollama, lmStudio].map(\.path))
    /// Pastas de ~/.cache que já entram em outra linha.
    private static let claimedCLICaches: Set<String> = ["uv", "pip", "lm-studio"]

    /// Os grupos que passam do mínimo, do maior para o menor. Demora de segundos a um minuto: rode fora da main.
    static func scan() -> [SpaceGroup] {
        let builders: [() -> SpaceGroup?] = [
            simulators, xcodeGroup, android, dockerGroup, homebrew, node, rust, go, python,
            ollamaGroup, lmStudioGroup, cliCaches, iPhoneBackups,
        ] + installedApps().map { app in { appGroup(app) } }
        var groups: [SpaceGroup] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: builders.count) { i in
            guard let group = builders[i]() else { return }
            lock.lock()
            groups.append(group)
            lock.unlock()
        }
        return groups.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Grupos

    private static func simulators() -> SpaceGroup? {
        let runtimes = installedRuntimes()
        // Antigos: todos menos a versão mais nova de cada plataforma.
        let newest = Dictionary(grouping: runtimes, by: \.os).compactMapValues { list in
            list.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.id
        }
        let old = runtimes.filter { $0.deletable && newest[$0.os] != $0.id }
        let devices = simulatorDevices()
        return group(
            "simulators", "Simuladores do iOS",
            icon: xcode.appending(path: "Contents/Developer/Applications/Simulator.app"), symbol: "iphone",
            parts: runtimes.map { runtime in
                SpaceItem(
                    label: runtime.name, bytes: runtime.bytes, urls: [runtime.url],
                    removal: runtime.deletable ? .runtime(id: runtime.id) : .blocked("O macOS não deixa apagar este runtime.")
                )
            } + [
                folder("Simuladores", h("Library/Developer/CoreSimulator/Devices"), removal: .blocked(SpaceWhy.several)) { url in
                    guard let device = devices[url.lastPathComponent] else { return (url.lastPathComponent, trashable(url, note: "Pasta de um simulador que o Xcode não conhece mais.")) }
                    return (device, .simulator(udid: url.lastPathComponent))
                },
                folders("Caches", [URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"), h("Library/Developer/CoreSimulator/Caches")]) { url in
                    (url.lastPathComponent, trashable(url, note: SpaceWhy.cache))
                },
            ],
            tip: """
            Cada versão do iOS instalada para os simuladores ocupa vários GB. \
            \(old.isEmpty ? "Aqui só tem a versão mais nova de cada plataforma." : "**Apagar runtimes antigos** deixa só a versão mais nova de cada plataforma.") \
            Abrindo **Simuladores**, cada aparelho mostra quanto ocupa: os que você não usa podem sair. \
            Para baixar uma versão de novo, use o Xcode, em **Settings → Components**.
            """,
            optimizations: old.isEmpty ? [] : [deleteRuntimes(old, title: "Apagar runtimes antigos")]
        )
    }

    private static func deleteRuntimes(_ runtimes: [Runtime], title: String) -> SpaceOptimization {
        let bytes = runtimes.reduce(0) { $0 + $1.bytes }
        let names = runtimes.map(\.name).formatted(.list(type: .and).locale(Locale(identifier: "pt_BR")))
        return SpaceOptimization(
            id: "runtimes:" + runtimes.map(\.id).joined(separator: ","),
            title: title,
            confirmation: """
            Apaga \(names) e libera cerca de \(Cleaner.format(bytes)). Os simuladores dessas versões são fechados e apagados junto. \
            Para usar de novo, baixe no Xcode, em Settings → Components.
            """,
            bytes: bytes,
            action: .deleteRuntimes(runtimes.map(\.id))
        )
    }

    private static func xcodeGroup() -> SpaceGroup? {
        let dev = h("Library/Developer/Xcode")
        let deviceSupport = children(of: dev).filter { $0.lastPathComponent.hasSuffix("DeviceSupport") }
        return group(
            "xcode", "Xcode", icon: xcode, symbol: "hammer",
            parts: [
                appItem(xcode),
                folders("DeviceSupport", deviceSupport) { url in
                    let platform = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: " DeviceSupport", with: "")
                    return ("\(platform) \(url.lastPathComponent)", trashable(url, note: "Símbolos para depurar essa versão num aparelho. O Xcode copia de novo quando você conectar um aparelho com ela."))
                },
                folder("Archives", dev.appending(path: "Archives"), removal: .blocked(SpaceWhy.several)) { url in
                    (url.lastPathComponent, trashable(url, note: "Builds enviados para a App Store nesse dia. Apagar não mexe no que já foi publicado, mas você perde os símbolos para ler os relatórios de falha."))
                },
                folder("DerivedData", dev.appending(path: "DerivedData"), removal: trashable(dev.appending(path: "DerivedData"), note: "Builds temporários: o próximo build compila do zero.")) { url in
                    (url.lastPathComponent.components(separatedBy: "-").dropLast().joined(separator: "-"), trashable(url, note: "Build temporário do projeto: o próximo build compila do zero."))
                },
            ],
            tip: """
            **DeviceSupport** guarda os símbolos de cada versão do iOS dos aparelhos que você já conectou: as versões antigas podem sair. \
            **Archives** são os builds enviados para a App Store. **DerivedData** são builds temporários (também saem na Limpeza).
            """
        )
    }

    private static func android() -> SpaceGroup? {
        let installed = fm.fileExists(atPath: androidStudio.path)
        let gradle = h(".gradle")
        let gradleCache = folder("Cache do Gradle", gradle.appending(path: "caches"), removal: trashable(gradle.appending(path: "caches"), note: gradleNote)) { url in
            let name = url.lastPathComponent
            let label = name.first?.isNumber == true ? "Gradle \(name)" : name == "modules-2" ? "Dependências baixadas" : name
            return (label, trashable(url, note: gradleNote))
        }
        // Configurações das versões antigas do Android Studio ficam para trás depois de atualizar.
        let studioData = children(of: support.appending(path: "Google"), prefix: "AndroidStudio")
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        return group(
            "android", installed ? "Android Studio" : "Android e Gradle", icon: androidStudio, symbol: "smartphone",
            parts: [
                appItem(androidStudio),
                androidSDK(),
                emulators(),
                gradleCache,
                folder("Gradle", gradle, removal: .blocked(SpaceWhy.several), only: { $0.lastPathComponent != "caches" }) { url in
                    isDirectory(url)
                        ? (url.lastPathComponent, trashable(url, note: "O Gradle baixa ou recria quando precisar."))
                        : (url.lastPathComponent, .blocked("Configuração do Gradle."))
                },
                folders("Dados e caches", studioData + children(of: caches.appending(path: "Google"), prefix: "AndroidStudio")) { url in
                    if url.path.hasPrefix(caches.path) { return (url.lastPathComponent + " (cache)", trashable(url, note: SpaceWhy.cache)) }
                    if url == studioData.last { return (url.lastPathComponent, .blocked(SpaceWhy.appData)) }
                    return (url.lastPathComponent, trashable(url, note: "Configurações de uma versão antiga do Android Studio, que ficaram para trás depois de atualizar."))
                },
            ],
            tip: """
            Abra cada parte para ver o que pesa: **Android SDK** separa cada NDK, system image, plataforma e build-tools; \
            **Emuladores** e **Cache do Gradle**, cada emulador e cada versão. O que você não usa pode ir para a Lixeira. \
            No **SDK Manager** do Android Studio dá para baixar de novo o que precisar.
            """,
            optimizations: [SpaceOptimization(
                id: "gradle", title: "Apagar o cache do Gradle",
                confirmation: """
                Apaga ~/.gradle/caches de vez e libera cerca de \(Cleaner.format(gradleCache.bytes)). Os daemons do Gradle são encerrados, \
                e o próximo build de cada projeto baixa de novo as dependências e demora mais.
                """,
                bytes: gradleCache.bytes, action: .cleanGradleCache
            )]
        )
    }

    /// Emuladores do Android, cada um com o .ini que aponta para ele (sem o .ini, o Android Studio mostra um emulador quebrado).
    private static func emulators() -> SpaceItem {
        let dir = h(".android/avd")
        let inis = children(of: dir).filter { $0.pathExtension == "ini" }
        let items = children(of: dir).filter { $0.pathExtension == "avd" }.map { avd in
            let ini = inis.filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(avd.lastPathComponent) }
            return SpaceItem(
                label: "Emulador \(avd.deletingPathExtension().lastPathComponent)", bytes: size(of: avd), urls: [avd] + ini,
                removal: trashable(avd, note: "O emulador com os apps e arquivos dele. Para ter de novo, crie no Device Manager.")
            )
        }
        return SpaceItem(label: "Emuladores", bytes: items.reduce(0) { $0 + $1.bytes }, urls: [dir], removal: .blocked(SpaceWhy.several), children: items)
    }

    private static let gradleNote = "Cache do Gradle: o próximo build baixa ou recria o que precisar, e demora mais."

    /// SDK do Android com cada versão separada: NDKs, system images, plataformas, build-tools…
    private static func androidSDK() -> SpaceItem {
        let sdk = h("Library/Android/sdk")
        let versioned: [String: (String, String)] = [
            "ndk": ("NDK", "Para compilar código nativo (C/C++). Os projetos dizem qual versão usam; o SDK Manager baixa de novo."),
            "build-tools": ("Build-tools", "O Gradle baixa de novo a versão que um projeto pedir."),
            "platforms": ("Plataforma", "Necessária para compilar para essa versão do Android; o SDK Manager baixa de novo."),
            "sources": ("Código-fonte", "Só para ler o código do Android no editor."),
            "cmake": ("CMake", "Para compilar código nativo; o SDK Manager baixa de novo."),
        ]
        var items: [SpaceItem] = []
        for entry in children(of: sdk) {
            let name = entry.lastPathComponent
            if let (label, note) = versioned[name] {
                items += children(of: entry).map { item("\(label) \($0.lastPathComponent)", [$0], removal: trashable($0, note: note)) }
            } else if name == "system-images" {
                // system-images/android-36.1/google_apis_playstore
                for api in children(of: entry) {
                    for variant in children(of: api) {
                        let kind = ["google_apis_playstore": "Play Store", "google_apis": "Google APIs", "default": "AOSP"][variant.lastPathComponent] ?? variant.lastPathComponent
                        items.append(item(
                            "System image \(api.lastPathComponent.replacingOccurrences(of: "android-", with: "Android ")) · \(kind)", [variant],
                            removal: trashable(variant, note: "Imagem usada pelos emuladores dessa versão: eles param de abrir até você baixar de novo no SDK Manager.")
                        ))
                    }
                }
            } else {
                items.append(item(name, [entry], removal: .blocked("O Android Studio precisa desta parte do SDK. Atualize ou remova pelo SDK Manager.")))
            }
        }
        return SpaceItem(label: "Android SDK", bytes: items.reduce(0) { $0 + $1.bytes }, urls: [sdk], removal: .blocked("O Android Studio precisa do SDK. Abra a lista e apague só as versões que não usa."), children: items)
    }

    private static func dockerGroup() -> SpaceGroup? {
        let vm = h("Library/Containers/com.docker.docker/Data/vms/0/data")
        var tip = """
        Imagens, containers, volumes e cache de build ficam dentro do disco virtual. `docker system df` mostra o que dá para liberar, \
        e `docker system prune` apaga containers parados, redes sem uso e o cache de build; com `-a`, também as imagens que nenhum container usa \
        (são baixadas de novo quando precisar). O Docker devolve o espaço ao Mac sozinho.
        """
        if let reclaimable = dockerReclaimable(), reclaimable > 0 {
            tip += "\n\nAgora o Docker diz que **\(Cleaner.format(reclaimable))** podem ser liberados."
        }
        return group(
            "docker", "Docker", icon: docker, symbol: "shippingbox",
            parts: [
                appItem(docker),
                // Só o arquivo do disco: o resto do container do Docker não pesa, e o macOS pediria permissão para entrar nele.
                item("Disco virtual", [vm.appending(path: "Docker.raw"), vm.appending(path: "Docker.qcow2")],
                     removal: .blocked("Apagar o disco virtual apaga todas as imagens, containers e volumes. Use docker system prune no Terminal.")),
                item("Dados", [h(".docker"), support.appending(path: "Docker Desktop")], removal: .blocked(SpaceWhy.appData)),
            ],
            tip: tip
        )
    }

    private static func homebrew() -> SpaceGroup? {
        group(
            "homebrew", "Homebrew", symbol: "mug",
            parts: [
                item("Pacotes", [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local/Homebrew"), URL(fileURLWithPath: "/usr/local/Cellar")],
                     removal: .blocked("Pacotes saem com brew uninstall no Terminal, para o Homebrew saber que saíram.")),
                folder("Downloads", caches.appending(path: "Homebrew"), removal: trashable(caches.appending(path: "Homebrew"), note: SpaceWhy.cache)) { url in
                    (url.lastPathComponent, trashable(url, note: SpaceWhy.cache))
                },
            ],
            tip: "`brew cleanup --prune=all` apaga as versões antigas dos pacotes e os downloads. `brew autoremove` tira as dependências que mais nada usa."
        )
    }

    private static func node() -> SpaceGroup? {
        let packageCaches = [h(".npm"), h(".yarn/berry/cache"), h("Library/pnpm"), caches.appending(path: "Yarn")]
        return group(
            "node", "Node.js", symbol: "cube",
            parts: [
                folder("Versões (nvm)", h(".nvm/versions/node"), removal: .blocked(SpaceWhy.several)) { url in
                    ("Node \(url.lastPathComponent)", trashable(url, note: "Para usar de novo: nvm install \(url.lastPathComponent)."))
                },
                folder("Bun", h(".bun"), removal: .blocked(SpaceWhy.several)) { url in
                    url.lastPathComponent == "install"
                        ? ("Cache de pacotes", trashable(url, note: SpaceWhy.cache))
                        : (url.lastPathComponent, .blocked("O próprio Bun: desinstale pelo Terminal."))
                },
                each("Caches de pacotes", packageCaches) { url in
                    (url.path.replacingOccurrences(of: home.path, with: "~"), trashable(url, note: "Cache de pacotes: o próximo install baixa de novo."))
                },
            ],
            tip: "Cada versão do Node instalada pelo nvm ocupa de 100 a 200 MB: as que você não usa podem sair. Os caches de pacotes também saem na Limpeza, em **npm / Yarn / pnpm**."
        )
    }

    private static func rust() -> SpaceGroup? {
        group(
            "rust", "Rust", symbol: "gearshape.2",
            parts: [
                folder("Toolchains", h(".rustup/toolchains"), removal: .blocked(SpaceWhy.several)) { url in
                    (url.lastPathComponent, trashable(url, note: "Para usar de novo: rustup toolchain install."))
                },
                folder("Cargo", h(".cargo"), removal: .blocked(SpaceWhy.several)) { url in
                    ["registry", "git"].contains(url.lastPathComponent)
                        ? ("Pacotes baixados (\(url.lastPathComponent))", trashable(url, note: "O cargo baixa de novo no próximo build."))
                        : (url.lastPathComponent, .blocked("Programas e configurações do cargo."))
                },
            ],
            tip: "As toolchains que você não usa podem sair (`rustup toolchain list` mostra todas). As pastas `target` dos projetos costumam pesar mais: saem na Limpeza, em **Builds de projetos**."
        )
    }

    private static func go() -> SpaceGroup? {
        group(
            "go", "Go", symbol: "chevron.left.forwardslash.chevron.right",
            parts: [
                item("Módulos", [h("go")], removal: .blocked("Os módulos do Go são só leitura: use go clean -modcache no Terminal.")),
                folder("Cache de build", caches.appending(path: "go-build"), removal: trashable(caches.appending(path: "go-build"), note: SpaceWhy.cache), listed: false) { url in
                    (url.lastPathComponent, trashable(url, note: SpaceWhy.cache))
                },
            ],
            tip: "`go clean -modcache` apaga os módulos baixados e `go clean -cache`, o cache de build. Os dois voltam no próximo build."
        )
    }

    private static func python() -> SpaceGroup? {
        group(
            "python", "Python", symbol: "terminal",
            parts: [
                folder("Versões (pyenv)", h(".pyenv/versions"), removal: .blocked(SpaceWhy.several)) { url in
                    ("Python \(url.lastPathComponent)", trashable(url, note: "Para usar de novo: pyenv install \(url.lastPathComponent)."))
                },
                item("Conda", [h("miniconda3"), h("anaconda3"), h(".conda")], removal: .blocked("Ambientes do conda saem com conda env remove, no Terminal.")),
                each("Caches", [h(".cache/uv"), h(".cache/pip"), caches.appending(path: "pip")]) { url in
                    (url.path.replacingOccurrences(of: home.path, with: "~"), trashable(url, note: "Cache de pacotes: o próximo install baixa de novo."))
                },
            ],
            tip: "`uv cache clean` e `pip cache purge` apagam os caches de pacotes. As versões do pyenv que você não usa podem sair."
        )
    }

    private static func ollamaGroup() -> SpaceGroup? {
        group(
            "ollama", "Ollama", icon: ollama, symbol: "brain",
            parts: [
                appItem(ollama),
                item("Modelos", [h(".ollama")], removal: .blocked("Os modelos dividem arquivos entre si: apague com ollama rm <nome> no Terminal.")),
            ],
            tip: "`ollama list` mostra os modelos baixados e `ollama rm <nome>` apaga um deles."
        )
    }

    private static func lmStudioGroup() -> SpaceGroup? {
        let models = h(".lmstudio/models")
        return group(
            "lmstudio", "LM Studio", icon: lmStudio, symbol: "brain",
            parts: [
                appItem(lmStudio),
                SpaceItem(
                    label: "Modelos", bytes: 0, urls: [models], removal: .blocked(SpaceWhy.several),
                    children: children(of: models).flatMap { publisher in
                        children(of: publisher).map { item($0.lastPathComponent, [$0], removal: trashable($0, note: "Modelo baixado: dá para baixar de novo no LM Studio.")) }
                    }
                ).summed(),
            ],
            tip: "Os modelos baixados também saem na aba **My Models** do LM Studio."
        )
    }

    private static func cliCaches() -> SpaceGroup? {
        let folders = children(of: h(".cache")).filter { !claimedCLICaches.contains($0.lastPathComponent) }
        return group(
            "cli-caches", "Caches de ferramentas", symbol: "archivebox",
            parts: folders.map { item($0.lastPathComponent, [$0], removal: trashable($0, note: "Cache de uma ferramenta de linha de comando: ela baixa ou recria o que precisar.")) },
            tip: "Em `~/.cache` cada pasta é o cache de uma ferramenta de linha de comando. Apagar a pasta não quebra a ferramenta: ela baixa ou recria o que precisar."
        )
    }

    private static func iPhoneBackups() -> SpaceGroup? {
        group(
            "backups", "Backups do iPhone", symbol: "iphone.gen3",
            parts: [item("Backups", [support.appending(path: "MobileSync/Backup")], removal: .blocked("Apague pelo Finder: selecione o iPhone e clique em Gerenciar Backups."))],
            tip: "Os backups antigos saem no Finder: selecione o iPhone na barra lateral e clique em **Gerenciar Backups**."
        )
    }

    /// Um app qualquer: o próprio app, os dados em Application Support e o cache, com o que tem dentro de cada um.
    /// Dentro dos dados, só o que tem cara de cache pode ir para a Lixeira; o resto é do app.
    private static func appGroup(_ app: URL) -> SpaceGroup? {
        let bundle = Bundle(url: app)
        // Nome como o Finder mostra (o VS Code se chama "Code" por dentro).
        var name = fm.displayName(atPath: app.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        var parts = [appItem(app)]
        var tip = "Para desinstalar, use a lixeira do **App**: os dados ficam no Mac até você apagar as outras partes também."
        // Os dados dos apps da Apple ficam em lugares protegidos do sistema: conta só o app.
        if let id = bundle?.bundleIdentifier, !id.hasPrefix("com.apple.") {
            var names = [app.deletingPathExtension().lastPathComponent, id]
            if let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String { names.append(bundleName) }
            // "Google Chrome" guarda em Google/Chrome.
            let words = app.deletingPathExtension().lastPathComponent.split(separator: " ")
            if words.count == 2 { names.append(words.joined(separator: "/")) }
            names = names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

            let data = names.map { support.appending(path: $0) }.filter(isDirectory)
            parts.append(folders("Dados", data, removal: .blocked(SpaceWhy.appData)) { url in
                (url.lastPathComponent, isCacheLike(url) ? trashable(url, note: SpaceWhy.cache) : .blocked(SpaceWhy.appData))
            })
            let cache = names.map { caches.appending(path: $0) }.filter(isDirectory)
            parts.append(folders("Cache", cache, removal: cache.count == 1 ? trashable(cache[0], note: SpaceWhy.cache) : .blocked(SpaceWhy.several)) { url in
                (url.lastPathComponent, trashable(url, note: SpaceWhy.cache))
            })
            if let folder = data.first?.path.replacingOccurrences(of: home.path, with: "~") {
                tip = "Os dados ficam em `\(folder)`. Abra **Dados** para ver o que pesa: o que é cache dá para apagar daqui; o resto é do app, e quem limpa é ele. " + tip
            }
        }
        return group("app:" + app.path, name, icon: app, symbol: "app", parts: parts, tip: tip)
    }

    // MARK: Ajudantes

    private static func group(
        _ id: String, _ name: String, icon: URL? = nil, symbol: String, parts: [SpaceItem], tip: String,
        optimizations: [SpaceOptimization] = []
    ) -> SpaceGroup? {
        // Partes de poucos MB só poluem o detalhe; dentro delas, itens a partir de 1 MB.
        let parts = parts.filter { $0.bytes >= 10_000_000 }.map { part in
            var part = part
            part.children = Array(part.children.filter { $0.bytes >= 1_000_000 }.sorted { $0.bytes > $1.bytes }.prefix(40))
            return part
        }
        let group = SpaceGroup(
            id: id, name: name,
            iconPath: icon.flatMap { fm.fileExists(atPath: $0.path) ? $0.path : nil },
            symbol: symbol, parts: parts, tip: tip,
            optimizations: optimizations.filter { $0.bytes >= 10_000_000 }
        )
        return group.bytes >= minimum ? group : nil
    }

    /// Soma das pastas (ou arquivos) que existem.
    private static func item(_ label: String, _ urls: [URL], removal: SpaceRemoval) -> SpaceItem {
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        return SpaceItem(label: label, bytes: existing.reduce(0) { $0 + size(of: $1) }, urls: existing.isEmpty ? urls : existing, removal: removal)
    }

    /// Uma pasta com cada coisa de dentro como item. O tamanho da pasta é a soma dos itens, então nada é medido duas vezes.
    private static func folder(
        _ label: String, _ dir: URL, removal: SpaceRemoval, listed: Bool = true, only: (URL) -> Bool = { _ in true },
        _ describe: (URL) -> (String, SpaceRemoval)
    ) -> SpaceItem {
        folders(label, [dir], removal: removal, listed: listed, only: only, describe)
    }

    private static func folders(
        _ label: String, _ dirs: [URL], removal: SpaceRemoval = .blocked(SpaceWhy.several), listed: Bool = true,
        only: (URL) -> Bool = { _ in true }, _ describe: (URL) -> (String, SpaceRemoval)
    ) -> SpaceItem {
        let entries = dirs.flatMap { children(of: $0) }.filter(only)
        let items = entries.map { url in
            let (name, removal) = describe(url)
            return SpaceItem(label: name, bytes: size(of: url), urls: [url], removal: removal)
        }
        return SpaceItem(label: label, bytes: items.reduce(0) { $0 + $1.bytes }, urls: dirs.isEmpty ? [home] : dirs, removal: removal, children: listed ? items : [])
    }

    /// Várias pastas soltas, cada uma como item.
    private static func each(_ label: String, _ urls: [URL], _ describe: (URL) -> (String, SpaceRemoval)) -> SpaceItem {
        let items = urls.filter { fm.fileExists(atPath: $0.path) }.map { url in
            let (name, removal) = describe(url)
            return SpaceItem(label: name, bytes: size(of: url), urls: [url], removal: removal)
        }
        return SpaceItem(
            label: label, bytes: items.reduce(0) { $0 + $1.bytes }, urls: items.isEmpty ? [home] : items.map(\.url),
            removal: items.count == 1 ? items[0].removal : .blocked(SpaceWhy.several), children: items
        )
    }

    /// O próprio app: vai para a Lixeira (desinstala), menos os que fazem parte do macOS.
    private static func appItem(_ app: URL) -> SpaceItem {
        let system = app.resolvingSymlinksInPath().path.hasPrefix("/System")
        return item("App", [app], removal: system ? .blocked(SpaceWhy.system) : trashable(app, note: SpaceWhy.uninstall))
    }

    /// Lixeira se o usuário pode mexer na pasta de cima; senão, a lixeira fica riscada.
    private static func trashable(_ url: URL, note: String) -> SpaceRemoval {
        fm.isWritableFile(atPath: url.deletingLastPathComponent().path) ? .trash(note: note) : .blocked(SpaceWhy.permission)
    }

    /// Pastas que os apps recriam sozinhos: caches, logs e relatórios de falha.
    private static func isCacheLike(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.contains("cache") || ["logs", "log", "crashpad", "crash reports", "tmp", "temp", "optguideondevicemodel"].contains(name)
    }

    /// udid → "iPhone 17 Pro Max (iOS 26.2)", pelo `simctl`.
    private static func simulatorDevices() -> [String: String] {
        guard Cleaner.hasDeveloperTools,
              let data = run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]]
        else { return [:] }
        var names: [String: String] = [:]
        for (runtime, devices) in byRuntime {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-2 → iOS 26.2
            let os = runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ", options: [], range: nil) ?? ""
            let parts = os.split(separator: " ")
            let version = parts.count > 1 ? "\(parts[0]) \(parts.dropFirst().joined(separator: "."))" : os
            for device in devices {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                names[udid] = "\(name) (\(version))"
            }
        }
        return names
    }

    /// Espaço que o arquivo ou a pasta ocupa de fato (arquivos esparsos, como o disco do Docker, contam só o que está gravado).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true })
        while let child = e?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func children(of dir: URL, prefix: String = "") -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// Apps de /Applications e ~/Applications, inclusive dentro de pastas (ex.: Adobe), fora os que têm linha própria.
    private static func installedApps() -> [URL] {
        var apps: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), h("Applications")] {
            for item in children(of: root) {
                if item.pathExtension == "app" {
                    apps.append(item)
                } else if isDirectory(item) {
                    apps += children(of: item).filter { $0.pathExtension == "app" }
                }
            }
        }
        return apps.filter { !curatedApps.contains($0.path) }
    }

    private struct Runtime {
        let id: String
        let os: String
        let version: String
        let bytes: Int64
        let url: URL
        let deletable: Bool
        var name: String { "\(os) \(version)" }
    }

    /// Runtimes do iOS (e watchOS, tvOS, visionOS) instalados para os simuladores, pelo `simctl`.
    private static func installedRuntimes() -> [Runtime] {
        guard Cleaner.hasDeveloperTools,
              let data = run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [] }
        return list.compactMap { id, runtime in
            guard let bytes = (runtime["sizeBytes"] as? NSNumber)?.int64Value else { return nil }
            let platform = runtime["platformIdentifier"] as? String ?? ""
            let os = platform.contains("watch") ? "watchOS" : platform.contains("appletv") ? "tvOS" : platform.contains("xr") ? "visionOS" : "iOS"
            let version = runtime["version"] as? String ?? ""
            let path = runtime["mountPath"] as? String ?? "/Library/Developer/CoreSimulator"
            return Runtime(
                id: id, os: os, version: version, bytes: bytes, url: URL(fileURLWithPath: path),
                deletable: (runtime["deletable"] as? Bool) ?? false
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Quanto o Docker diz que dá para liberar (`docker system df`). nil se o Docker não estiver aberto.
    private static func dockerReclaimable() -> Int64? {
        let cli = ["/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
            .first(where: fm.isExecutableFile(atPath:))
        guard let cli, let data = run(cli, ["system", "df", "--format", "{{json .}}"], timeout: 8),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n").reduce(0) { total, line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let value = (row["Reclaimable"] as? String)?.split(separator: " ").first
            else { return total }
            return total + dockerBytes(String(value))
        }
    }

    /// "6.995GB" → bytes. O Docker usa base 10.
    private static func dockerBytes(_ text: String) -> Int64 {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            return Int64((Double(text.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    /// Roda um comando e devolve a saída, ou nil se falhar.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> Data? {
        let result = execute(path, arguments, timeout: timeout)
        return result.ok ? result.output : nil
    }

    /// Roda um comando e devolve a saída e o erro; desiste depois do tempo limite.
    static func execute(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (ok: Bool, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return (false, Data(), "Não deu para abrir \(path).") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        // Lê o erro em paralelo: com os dois pipes cheios, o processo travaria.
        var errorData = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errorData = err.fileHandleForReading.readDataToEndOfFile() }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, output, error)
    }
}

/// Faz as otimizações com um clique.
enum SpaceOptimizer {
    /// Devolve a mensagem de erro, se der errado.
    static func run(_ action: SpaceOptimization.Action) -> String? {
        switch action {
        case .deleteRuntimes(let ids):
            for id in ids {
                // Desmontar e apagar uma imagem de vários GB pode levar alguns minutos.
                let result = SpaceScanner.execute("/usr/bin/xcrun", ["simctl", "runtime", "delete", id], timeout: 600)
                if !result.ok { return result.error.isEmpty ? "O simctl não conseguiu apagar o runtime." : result.error }
            }
            // Os simuladores das versões apagadas ficam indisponíveis.
            _ = SpaceScanner.execute("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 120)
            return nil
        case .deleteSimulator(let udid):
            let result = SpaceScanner.execute("/usr/bin/xcrun", ["simctl", "delete", udid], timeout: 120)
            return result.ok ? nil : (result.error.isEmpty ? "O simctl não conseguiu apagar o simulador." : result.error)
        case .cleanGradleCache:
            // Um daemon parado não perde nada: o próximo build abre outro. Sem isso, ele recria arquivos no meio da limpeza.
            _ = SpaceScanner.execute("/usr/bin/pkill", ["-f", "org.gradle.launcher.daemon"], timeout: 10)
            let caches = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gradle/caches")
            for child in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: child)
            }
            return nil
        }
    }
}

/// Lista "Mais ocupam espaço" da Visão geral: calcula na primeira vez que aparece e de novo se já faz mais de 30 minutos.
@MainActor
final class SpaceModel: ObservableObject {
    @Published var groups: [SpaceGroup] = []
    @Published var scanning = false
    @Published var date: Date?
    /// Otimização em andamento.
    @Published var running: String?
    /// Resultado da última otimização (ex.: "✓ 8,4 GB liberados"); o tamanho é o medido antes de apagar.
    @Published var result: String?
    /// O resultado foi para a Lixeira: o espaço só volta quando ela for esvaziada.
    @Published var resultInTrash = false
    /// Uma otimização terminou durante uma medição: mede de novo no fim.
    private var rescan = false

    func refreshIfStale() {
        guard let date else { return scan() }
        if Date.now.timeIntervalSince(date) > 30 * 60 { scan() }
    }

    func scan() {
        guard !scanning else { rescan = true; return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let groups = SpaceScanner.scan()
            DispatchQueue.main.async {
                self.groups = groups
                self.date = .now
                self.scanning = false
                if self.rescan {
                    self.rescan = false
                    self.scan()
                }
            }
        }
    }

    /// Confirma, apaga em segundo plano e mede de novo.
    func optimize(_ optimization: SpaceOptimization) {
        guard running == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        if optimization.action == .cleanGradleCache,
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.android.studio" }) {
            let alert = NSAlert()
            alert.messageText = "Feche o Android Studio antes"
            alert.informativeText = "Com o Android Studio aberto, o Gradle está usando o cache e um build pode quebrar no meio."
            alert.runModal()
            return
        }
        guard confirm(title: "\(optimization.title)?", text: optimization.confirmation, button: "Apagar") else { return }
        perform(optimization.action, id: optimization.id, bytes: optimization.bytes)
    }

    /// Apaga um item do detalhe: vai para a Lixeira ou, nos simuladores, sai pelo `simctl`.
    func remove(_ item: SpaceItem, in group: SpaceGroup) {
        guard running == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let size = Cleaner.format(item.bytes)
        switch item.removal {
        case .blocked:
            return
        case .trash(let note):
            if let app = group.iconPath, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app }) {
                let alert = NSAlert()
                alert.messageText = "Feche o \(group.name) antes"
                alert.informativeText = "Com o app aberto, \(item.label) pode estar em uso e o app pode perder dados."
                alert.runModal()
                return
            }
            guard confirm(
                title: "Mover \(item.label) para a Lixeira?",
                text: "\(note)\n\nLibera \(size) quando você esvaziar a Lixeira. Até lá, dá para recuperar.",
                button: "Mover para a Lixeira"
            ) else { return }
            running = item.id
            result = nil
            NSWorkspace.shared.recycle(item.urls) { trashed, error in
                Trash.record(Array(trashed.values))
                DispatchQueue.main.async {
                    self.running = nil
                    if let error {
                        self.fail(error.localizedDescription)
                    } else {
                        self.result = "✓ \(size) na Lixeira"
                        self.resultInTrash = true
                    }
                    self.scan()
                }
            }
        case .simulator(let udid):
            guard confirm(
                title: "Apagar o simulador \(item.label)?",
                text: "Apaga de vez o simulador, com os apps e arquivos dentro dele, e libera \(size). Para ter de novo, crie no Xcode, em Window → Devices and Simulators.",
                button: "Apagar"
            ) else { return }
            perform(.deleteSimulator(udid), id: item.id, bytes: item.bytes)
        case .runtime(let id):
            guard confirm(
                title: "Apagar o runtime \(item.label)?",
                text: "Apaga de vez e libera \(size). Os simuladores dessa versão são fechados e apagados junto. Para usar de novo, baixe no Xcode, em Settings → Components.",
                button: "Apagar"
            ) else { return }
            perform(.deleteRuntimes([id]), id: item.id, bytes: item.bytes)
        }
    }

    private func confirm(title: String, text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Não deu para terminar"
        alert.informativeText = message
        alert.runModal()
    }

    /// Apaga de vez em segundo plano e mede de novo.
    private func perform(_ action: SpaceOptimization.Action, id: String, bytes: Int64) {
        running = id
        result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let error = SpaceOptimizer.run(action)
            DispatchQueue.main.async {
                self.running = nil
                if let error {
                    self.fail(error)
                } else {
                    self.result = "✓ \(Cleaner.format(bytes)) liberados"
                    self.resultInTrash = false
                }
                self.scan()
            }
        }
    }
}

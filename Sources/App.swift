// T90ABC Flasher — app logic and user interface.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Links are set in build.sh and stored in Info.plist.
enum Links {
    static func info(_ key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap(URL.init(string:))
    }
    static let download = URL(string: "https://en.alientek.com/download/p-0-10.html")!
    static var project: URL? { info("T90ProjectURL") }
    static var support: URL? { info("T90SupportURL") }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    /// "owner/repo" on GitHub; missing or placeholder disables update checks.
    static var repo: String? {
        guard let r = Bundle.main.object(forInfoDictionaryKey: "T90GitHubRepo") as? String,
              !r.contains("YOUR_"),
              r.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
        return r
    }

    /// Only https links to GitHub are opened from update information.
    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }
}

// MARK: - Update check (GitHub Releases)

enum Updater {
    struct Release { let version: String; let notes: String; let url: URL }

    /// "v1.2.0" > "1.1.9"
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Latest release. Only api.github.com is contacted; no user data is sent.
    static func fetchLatest(repo: String, done: @escaping (Release?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { done(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { done(nil); return }
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = (assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String)
                .flatMap(URL.init(string:))
            let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let target = zip.flatMap { Links.isTrustedDownload($0) ? $0 : nil } ?? page
            guard Links.isTrustedDownload(target) else { done(nil); return }
            done(Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                         notes: notes, url: target))
        }.resume()
    }
}

struct FwOption: Identifiable {
    let url: URL
    let blocks: [FwBlock]
    var id: String { url.path }
    var date: String { blocks[0].date }
    var isFix: Bool { url.lastPathComponent.lowercased().contains("set_hw") }
}

struct LogoOption: Identifiable, Equatable {
    enum Kind { case english, chinese, file, custom }
    let id: String
    let kind: Kind
    let url: URL?
}

final class AppModel: ObservableObject {
    // Device
    @Published var connected = false
    @Published var info: DevInfo?
    // Firmware
    @Published var packageName: String?
    @Published var fwOptions: [FwOption] = []
    @Published var selectedFw: String = ""
    // Logo
    @Published var logoOptions: [LogoOption] = [LogoOption(id: "custom", kind: .custom, url: nil)]
    @Published var selectedLogo: String = "custom" { didSet { logoChanged(from: oldValue) } }
    @Published var customLogoURL: URL?
    @Published var logoPreview: NSImage?
    @Published var withLogo = true
    // Progress
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var stageKey = ""
    @Published var log: [String] = []
    // Dialogs
    @Published var confirm: (fw: Bool, logo: Bool)?
    @Published var errorText: String?
    @Published var showDone = false
    @Published var showAbout = false
    // Language ("" = system)
    @Published var langSetting: String = UserDefaults.standard.string(forKey: "lang") ?? "" {
        didSet { UserDefaults.standard.set(langSetting, forKey: "lang") }
    }

    private var logoPixels: [UInt8]?
    private var activity: NSObjectProtocol?

    let maxZipSize = 100 * 1024 * 1024
    let maxUnzippedSize = 300 * 1024 * 1024
    let maxImageSize = 20 * 1024 * 1024
    let link = HIDLink()

    var lang: Lang {
        if let env = ProcessInfo.processInfo.environment["T90_LANG"], let l = Lang(rawValue: env) { return l }
        return Lang(rawValue: langSetting) ?? .system()
    }

    func t(_ key: String) -> String { tr(key, lang) }
    func t(_ key: String, _ args: CVarArg...) -> String { String(format: tr(key, lang), arguments: args) }

    static weak var current: AppModel?

    init() {
        AppModel.current = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkForUpdates(manual: false) }
        link.onChange = { [weak self] on in
            guard let self = self else { return }
            self.connected = on
            self.info = nil
            if on { self.refreshInfo() }
        }
        cleanupTemp()
        if let last = UserDefaults.standard.string(forKey: "lastPackage"),
           FileManager.default.fileExists(atPath: last) {
            loadPackage(URL(fileURLWithPath: last), silent: true)
        }
    }

    static let tempPrefix = "t90pkg-"

    /// Removes the folders this app unpacked ZIPs into (also leftovers from earlier runs).
    func cleanupTemp(keep: URL? = nil) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let items = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        // Compare by name: the same folder may appear as /var/… or /private/var/….
        for u in items where u.lastPathComponent.hasPrefix(AppModel.tempPrefix)
                          && u.lastPathComponent != keep?.lastPathComponent {
            try? fm.removeItem(at: u)
        }
    }

    var currentFw: FwOption? { fwOptions.first { $0.id == selectedFw } }
    var ready: Bool { connected && (info?.inBootloader ?? false) && !busy }

    // MARK: Firmware package

    func choosePackage() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "atk") ?? .data]
        p.message = t("pkg.pickPrompt")
        if p.runModal() == .OK, let u = p.url { loadPackage(u) }
    }

    func handleDrop(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "bmp", "gif", "heic", "tiff"].contains(ext) {
            customLogoURL = url
            if selectedLogo == "custom" { updateLogo() } else { selectedLogo = "custom" }
        } else {
            loadPackage(url)
        }
    }

    func loadPackage(_ url: URL, silent: Bool = false) {
        let fm = FileManager.default
        var root = url
        if url.pathExtension.lowercased() == "zip" {
            // Refuse oversized archives (official packages are a few MB) and ZIP bombs.
            guard fileSize(url) <= maxZipSize, unzippedSize(url).map({ $0 <= maxUnzippedSize }) == true else {
                if !silent { errorText = t("err.badFile") }
                return
            }
            let tmp = fm.temporaryDirectory.appendingPathComponent(AppModel.tempPrefix + UUID().uuidString)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, tmp.path]
            try? p.run(); p.waitUntilExit()
            root = tmp
        }

        var atks: [URL] = [], images: [URL] = []
        var isDir: ObjCBool = false
        fm.fileExists(atPath: root.path, isDirectory: &isDir)
        if isDir.boolValue {
            scan(root, atks: &atks, images: &images)
        } else if root.pathExtension.lowercased() == "atk" {
            atks = [root]
            // Logos next to the file: a "logo" folder in the same or the parent folder.
            let dir = root.deletingLastPathComponent()
            for d in [dir.appendingPathComponent("logo"), dir.deletingLastPathComponent().appendingPathComponent("logo")] {
                scan(d, atks: &atks, images: &images, atkToo: false)
            }
        }

        let fws: [FwOption] = atks.compactMap { u in
            guard fileSize(u) <= maxATKSize,
                  let raw = try? Data(contentsOf: u), let b = try? parseATK([UInt8](raw)),
                  b[0].devType == Proto.devType else { return nil }
            return FwOption(url: u, blocks: b)
        }.sorted { ($0.isFix ? 0 : 1, $0.date) > ($1.isFix ? 0 : 1, $1.date) }

        var logos: [LogoOption] = images.compactMap { u in
            guard fileSize(u) <= maxImageSize, let rep = NSImageRep(contentsOf: u), rep.pixelsWide == Logo.w, rep.pixelsHigh == Logo.h else { return nil }
            let name = u.deletingPathExtension().lastPathComponent
            let kind: LogoOption.Kind
            if name.lowercased().contains("alientek") { kind = .english }
            // Chinese name (正点原子…). Inside ZIPs it is often GBK-encoded and unpacks as
            // garbled text, so any non-ASCII name is treated as the Chinese logo.
            else if name.unicodeScalars.contains(where: { !$0.isASCII }) { kind = .chinese }
            else { kind = .file }
            return LogoOption(id: u.path, kind: kind, url: u)
        }
        logos.sort { order($0.kind) < order($1.kind) }

        if fws.isEmpty && logos.isEmpty {
            if root != url { try? fm.removeItem(at: root) }
            if !silent { errorText = t("err.noAtk") }
            return
        }
        cleanupTemp(keep: root != url ? root : nil)  // drop folders of previously unpacked ZIPs
        packageName = url.lastPathComponent
        fwOptions = fws
        selectedFw = fws.first?.id ?? ""
        logoOptions = logos + [LogoOption(id: "custom", kind: .custom, url: nil)]
        setLogo(logos.first(where: { $0.kind == .english })?.id ?? logos.first?.id ?? "custom")
        updateLogo()
        UserDefaults.standard.set(url.path, forKey: "lastPackage")
    }

    private func order(_ k: LogoOption.Kind) -> Int {
        switch k { case .english: return 0; case .chinese: return 1; case .file: return 2; case .custom: return 3 }
    }

    private func fileSize(_ u: URL) -> Int {
        (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
    }

    /// Total unpacked size of a ZIP, read from its directory with /usr/bin/zipinfo.
    private func unzippedSize(_ zip: URL) -> Int? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-t", zip.path]
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // "12 files, 4325721 bytes uncompressed, …"
        guard let line = String(data: data, encoding: .utf8),
              let r = line.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression) else { return nil }
        return Int(line[r].split(separator: " ")[0])
    }

    private func scan(_ dir: URL, atks: inout [URL], images: inout [URL], atkToo: Bool = true) {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var count = 0
        for case let u as URL in en {
            count += 1
            if count > 3000 { break }
            if u.path.contains("__MACOSX") { continue }
            // Never follow links: a crafted archive could point them at other files on the Mac.
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            switch u.pathExtension.lowercased() {
            case "atk" where atkToo: atks.append(u)
            case "jpg", "jpeg", "png", "bmp": images.append(u)
            default: break
            }
        }
    }

    func fwLabel(_ o: FwOption) -> String {
        if o.isFix { return "\(t("pkg.fixName")) · \(prettyDate(o.date))" }
        let v = knownVersions[o.date].map { "\($0) · " } ?? ""
        return "\(v)\(prettyDate(o.date)) · \(o.url.lastPathComponent)"
    }

    func logoLabel(_ o: LogoOption) -> String {
        switch o.kind {
        case .english: return t("logo.english")
        case .chinese: return t("logo.chinese")
        case .custom: return t("logo.custom")
        case .file: return o.url?.deletingPathExtension().lastPathComponent ?? "?"
        }
    }

    // MARK: Logo

    private func logoChanged(from old: String) {
        // Open the file picker only when the user switched to "Custom image" themselves.
        if !programmatic && selectedLogo == "custom" && old != "custom" && customLogoURL == nil {
            DispatchQueue.main.async {
                self.chooseCustomLogo()
                if self.customLogoURL == nil { self.setLogo(old) }
            }
        }
        updateLogo()
    }

    private var programmatic = false
    private func setLogo(_ id: String) {
        programmatic = true; selectedLogo = id; programmatic = false
    }

    func chooseCustomLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = t("logo.pickPrompt")
        if p.runModal() == .OK, let u = p.url {
            customLogoURL = u
            if selectedLogo == "custom" { updateLogo() } else { selectedLogo = "custom" }
        }
    }

    func updateLogo() {
        let url = selectedLogo == "custom" ? customLogoURL : logoOptions.first { $0.id == selectedLogo }?.url
        guard let u = url, fileSize(u) <= maxImageSize,
              let img = NSImage(contentsOf: u), let (prev, px) = Logo.render(img) else {
            logoPreview = nil; logoPixels = nil; return
        }
        logoPreview = prev; logoPixels = px
    }

    // MARK: Updates

    func checkForUpdates(manual: Bool) {
        guard let repo = Links.repo else {
            if manual { info(t("update.none", Links.version)) }
            return
        }
        Updater.fetchLatest(repo: repo) { rel in
            DispatchQueue.main.async {
                guard let rel = rel else {
                    if manual { self.info(self.t("update.failed")) }
                    return
                }
                let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                guard Updater.isNewer(rel.version, than: Links.version),
                      manual || rel.version != skipped else {
                    if manual { self.info(self.t("update.none", Links.version)) }
                    return
                }
                let a = NSAlert()
                a.messageText = self.t("update.title")
                var text = self.t("update.msg", rel.version, Links.version)
                if !rel.notes.isEmpty { text += "\n\n" + String(rel.notes.prefix(600)) }
                a.informativeText = text
                a.addButton(withTitle: self.t("update.download"))
                a.addButton(withTitle: self.t("update.later"))
                a.addButton(withTitle: self.t("update.skip"))
                switch a.runModal() {
                case .alertFirstButtonReturn: NSWorkspace.shared.open(rel.url)
                case .alertThirdButtonReturn: UserDefaults.standard.set(rel.version, forKey: "skippedVersion")
                default: break
                }
            }
        }
    }

    private func info(_ text: String) {
        let a = NSAlert()
        a.messageText = "T90ABC Flasher"
        a.informativeText = text
        a.addButton(withTitle: t("ok"))
        a.runModal()
    }

    /// Dialog on quit. Returns false if quitting is not allowed (update in progress).
    func confirmQuit() -> Bool {
        if busy {
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = t("quit.busyTitle")
            a.informativeText = t("quit.busyMsg")
            a.addButton(withTitle: t("ok"))
            a.runModal()
            return false
        }
        guard let support = Links.support else { return true }
        let a = NSAlert()
        a.messageText = t("quit.title")
        a.informativeText = t("quit.msg")
        a.addButton(withTitle: t("quit.donate"))
        a.addButton(withTitle: t("quit.later"))
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(support) }
        return true
    }

    // MARK: Device

    func refreshInfo() {
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.2)
            let i = try? self.link.devInfo()
            DispatchQueue.main.async { self.info = i }
        }
    }

    func start(firmware: Bool, logo: Bool) {
        var blocks: [FwBlock] = []
        if firmware {
            guard let fw = currentFw else { errorText = t("err.noFw"); return }
            blocks += fw.blocks
        }
        if logo {
            guard let px = logoPixels else { errorText = t("err.noLogo"); return }
            blocks.append(Logo.block(pixels: px))
        }
        busy = true; progress = 0; log.removeAll(); stageKey = "progress.preparing"
        // Keep the Mac awake while writing: sleeping mid-update would interrupt it.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Updating the soldering iron")
        let endActivity = { [weak self] in
            if let a = self?.activity { ProcessInfo.processInfo.endActivity(a); self?.activity = nil }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.link.flash(blocks,
                    progress: { p in DispatchQueue.main.async { self.progress = p } },
                    stage: { k in DispatchQueue.main.async { self.stageKey = k } },
                    log: { s in DispatchQueue.main.async { self.log.append(s) } })
                DispatchQueue.main.async {
                    endActivity()
                    self.busy = false; self.progress = 1; self.stageKey = ""
                    self.showDone = true
                }
            } catch {
                let text: String
                if let e = error as? FlashError {
                    text = String(format: tr(e.key, self.lang), arguments: e.args)
                } else {
                    text = error.localizedDescription
                }
                DispatchQueue.main.async {
                    endActivity()
                    self.log.append("Error: \(text)")
                    self.busy = false; self.stageKey = ""
                    self.errorText = text
                }
            }
        }
    }
}

// MARK: - User interface

struct StatusCard: View {
    @ObservedObject var m: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                // Shown only when the iron reports real values; in update mode it usually does not.
                if let i = m.info, i.dateKnown, i.hwKnown {
                    let ver = knownVersions[i.date].map { "\($0) (\(prettyDate(i.date)))" } ?? prettyDate(i.date)
                    Text(m.t("status.installed", ver, String(format: "%.1f", Double(i.hwVer) / 10)))
                        .font(.callout).foregroundColor(.secondary)
                }
                if !m.connected || (m.info.map { !$0.inBootloader } ?? false) {
                    Text(m.t("status.howto"))
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    var color: Color {
        if !m.connected { return .gray }
        guard let i = m.info else { return .yellow }
        return i.inBootloader ? .green : .orange
    }

    var title: String {
        if !m.connected { return m.t("status.notConnected") }
        guard let i = m.info else { return m.t("status.connecting") }
        return i.inBootloader ? m.t("status.ready") : m.t("status.notBoot")
    }
}

struct ContentView: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "flame.fill").font(.title).foregroundColor(.orange)
                Text("T90ABC Flasher").font(.title2.bold())
                Spacer()
                Menu {
                    Picker(m.t("about.lang"), selection: $m.langSetting) {
                        Text(m.t("about.auto")).tag("")
                        Divider()
                        ForEach(Lang.allCases) { Text($0.name).tag($0.rawValue) }
                    }.pickerStyle(.inline)
                } label: {
                    Label(m.lang.name, systemImage: "globe")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(m.t("about.lang"))
                Button { m.showAbout = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).help(m.t("about.title"))
            }

            StatusCard(m: m)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if m.fwOptions.isEmpty {
                        Text(m.t("pkg.hint")).font(.callout).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if m.fwOptions.count == 1, let fw = m.currentFw {
                        Text(m.fwLabel(fw)).font(.callout)
                    } else {
                        Picker("", selection: $m.selectedFw) {
                            ForEach(m.fwOptions) { Text(m.fwLabel($0)).tag($0.id) }
                        }.labelsHidden().disabled(m.busy)
                    }
                    HStack {
                        Button(m.t("pkg.choose")) { m.choosePackage() }.disabled(m.busy)
                        Button(m.t("pkg.download")) { NSWorkspace.shared.open(Links.download) }
                        Spacer()
                    }
                    if !m.fwOptions.isEmpty {
                        Toggle(m.t("fw.withLogo"), isOn: $m.withLogo)
                        Button {
                            m.confirm = (true, m.withLogo && m.logoPreview != nil)
                        } label: {
                            Label(m.t("fw.update"), systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!m.ready)
                    }
                }.padding(6)
            } label: { Text(m.t("pkg.title")).font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if m.logoOptions.count > 1 {
                        Picker("", selection: $m.selectedLogo) {
                            ForEach(m.logoOptions) { Text(m.logoLabel($0)).tag($0.id) }
                        }
                        .pickerStyle(.segmented).labelsHidden().disabled(m.busy)
                    }

                    HStack {
                        Spacer()
                        ZStack {
                            Rectangle().fill(Color.black)
                            if let img = m.logoPreview {
                                Image(nsImage: img).interpolation(.none).resizable()
                            } else {
                                Text(m.t("logo.noImage")).foregroundColor(.gray)
                            }
                        }
                        .frame(width: 320, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    if m.logoOptions.count == 1 {
                        Text(m.t("logo.fromPkg")).font(.caption).foregroundColor(.secondary)
                    }
                    if m.selectedLogo == "custom" {
                        Button(m.customLogoURL == nil ? m.t("logo.custom") + "…" : m.t("logo.chooseOther")) {
                            m.chooseCustomLogo()
                        }.disabled(m.busy)
                    }
                    Button {
                        m.confirm = (false, true)
                    } label: {
                        Label(m.t("logo.only"), systemImage: "photo").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!m.ready || m.logoPreview == nil)
                }.padding(6)
            } label: { Text(m.t("logo.title")).font(.headline) }

            if m.busy {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: m.progress)
                    Text("\(m.t(m.stageKey)) \(Int(m.progress * 100))% — \(m.t("progress.dontUnplug"))")
                        .font(.callout).foregroundColor(.orange)
                }
            }

            if !m.log.isEmpty {
                DisclosureGroup(m.t("details")) {
                    ScrollView {
                        Text(m.log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.frame(height: 90)
                }.font(.callout)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { DispatchQueue.main.async { m.handleDrop(url) } }
            }
            return true
        }
        .alert(confirmTitle, isPresented: Binding(get: { m.confirm != nil }, set: { if !$0 { m.confirm = nil } })) {
            Button(m.t("confirm.start")) { if let c = m.confirm { m.start(firmware: c.fw, logo: c.logo) }; m.confirm = nil }
            Button(m.t("cancel"), role: .cancel) { m.confirm = nil }
        } message: {
            Text(m.t("confirm.msg"))
        }
        .alert(m.t("err.title"), isPresented: Binding(get: { m.errorText != nil }, set: { if !$0 { m.errorText = nil } })) {
            Button(m.t("ok")) { m.errorText = nil }
        } message: {
            Text(m.errorText ?? "")
        }
        .alert(m.t("done.title"), isPresented: $m.showDone) {
            if let s = Links.support {
                Button(m.t("done.support")) { NSWorkspace.shared.open(s) }
            }
            Button(m.t("done.close"), role: .cancel) {}
        } message: {
            Text(m.t("done.msg"))
        }
        .sheet(isPresented: $m.showAbout) { AboutView(m: m) }
    }

    var confirmTitle: String {
        guard let c = m.confirm else { return "" }
        if c.fw && c.logo { return m.t("confirm.fwLogo") }
        return c.fw ? m.t("confirm.fw") : m.t("confirm.logo")
    }
}

struct AboutView: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("T90ABC Flasher").font(.title2.bold())
            Text(m.t("about.version", Links.version)).font(.callout).foregroundColor(.secondary)
            Text(m.t("about.text")).font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Picker(m.t("about.lang"), selection: $m.langSetting) {
                Text(m.t("about.auto")).tag("")
                ForEach(Lang.allCases) { Text($0.name).tag($0.rawValue) }
            }.frame(width: 260)
            HStack {
                if let p = Links.project { Button(m.t("about.github")) { NSWorkspace.shared.open(p) } }
                if let s = Links.support { Button(m.t("about.support")) { NSWorkspace.shared.open(s) } }
            }
            Button(m.t("ok")) { m.showAbout = false }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 400)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Do not block logout, restart or shutdown with a dialog.
        if let ev = NSAppleEventManager.shared().currentAppleEvent,
           let why = ev.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue,
           [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown,
            kAEShowRestartDialog, kAEShowShutdownDialog].map({ OSType($0) }).contains(why) {
            return .terminateNow
        }
        guard let m = AppModel.current else { return .terminateNow }
        return m.confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.current?.cleanupTemp()
    }
}

@main
struct T90FlasherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("T90ABC Flasher") { ContentView(m: model) }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button(model.t("about.title")) { model.showAbout = true }
                    Button(model.t("update.check")) { model.checkForUpdates(manual: true) }
                }
                CommandGroup(replacing: .newItem) {}
            }
    }
}

import AppKit
import CryptoKit
import Foundation
import AuralCore

struct AuralAvailableUpdate: Equatable, Sendable {
    let version: String
    let pageURL: URL
    let downloadURL: URL
    let sha256: String
    /// 旧版本发布的是 zip；新版本发布 DMG。安装器按实际扩展名选择解析方式。
    let archiveKind: AuralUpdateArchiveKind
}

enum AuralUpdateArchiveKind: String, Equatable, Sendable {
    case dmg
    case zip
}

/// 下载、校验和安装阶段全部由同一个状态机表达，界面只根据它绘图。
enum AuralUpdatePhase: Equatable {
    case idle
    case available
    case downloading(progress: Double)
    case preparing
    case ready
    case failed(String)
}

/// 检查公开 GitHub Release，并在本机完成下载、SHA-256 校验和安装包暂存。
@MainActor
final class AuralUpdateChecker: ObservableObject {
    static let shared = AuralUpdateChecker()

    @Published private(set) var availableUpdate: AuralAvailableUpdate?
    @Published private(set) var phase: AuralUpdatePhase = .idle
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    /// 只在用户主动检查并确认没有更新后显示，关闭设置窗口时清除。
    @Published private(set) var didCheckWithoutUpdate = false

    private let defaults: UserDefaults
    private let currentVersion: String
    private let checkInterval: TimeInterval = 6 * 60 * 60
    private let lastCheckKey = "local.aural.updates.lastCheck"
    private let skippedVersionKey = "local.aural.updates.skippedVersion"
    private var checkTask: Task<Void, Never>?
    private var periodicTimer: Timer?
    private var downloadSession: URLSession?
    private var downloadGeneration: UInt64 = 0
    private var pendingRestart = false

    init(defaults: UserDefaults = .standard,
         currentVersion: String = AuralVersion.current) {
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    /// 启动立即检查一次，随后每六小时检查一次；长期运行的应用不能只依赖首次启动。
    func startAutomaticChecking() {
        checkIfNeeded()
        guard periodicTimer == nil else { return }
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.check(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    /// 启动时最多每六小时请求一次，避免后台常驻时反复访问 GitHub。
    func checkIfNeeded() {
        let lastCheck = defaults.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - lastCheck >= checkInterval else { return }
        check(force: false)
    }

    func check(force: Bool) {
        guard !isChecking else { return }
        if !force {
            let lastCheck = defaults.double(forKey: lastCheckKey)
            guard Date().timeIntervalSince1970 - lastCheck >= checkInterval else { return }
        }
        // 下载或安装已经就绪时不能被一次后台检查覆盖本地暂存状态。
        switch phase {
        case .downloading, .preparing, .ready:
            return
        case .idle, .available, .failed:
            break
        }
        isChecking = true
        lastError = nil
        if force { didCheckWithoutUpdate = false }
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { isChecking = false }
            do {
                let update = try await fetchAvailableUpdate()
                defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                guard let update else {
                    availableUpdate = nil
                    phase = .idle
                    didCheckWithoutUpdate = force
                    return
                }
                let skippedVersion = defaults.string(forKey: skippedVersionKey)
                guard Self.shouldPresent(update: update,
                                         skippedVersion: skippedVersion,
                                         manualCheck: force) else {
                    availableUpdate = nil
                    phase = .idle
                    didCheckWithoutUpdate = force
                    return
                }
                // 手动检查可以重新展示被关闭的版本；点击更新后不能继续保留“已跳过”状态。
                if skippedVersion != nil {
                    defaults.removeObject(forKey: skippedVersionKey)
                }
                availableUpdate = update
                phase = .available
                didCheckWithoutUpdate = false
            } catch {
                // 已有更新提示不能因一次网络失败消失，只记录本次检查错误。
                lastError = error.localizedDescription
                if availableUpdate == nil {
                    if case .failed = phase {
                        // 保留下载失败原因。
                    } else {
                        phase = .idle
                    }
                }
            }
        }
    }

    /// 用户点击更新后下载 DMG，完成摘要校验和签名验证后才允许重启安装。
    func downloadAndPrepare() {
        guard let update = availableUpdate else { return }
        switch phase {
        case .downloading, .preparing, .ready:
            return
        case .idle, .available, .failed:
            break
        }
        lastError = nil
        do {
            let paths = try AuralUpdateInstaller.prepareStaging(for: update)
            phase = .downloading(progress: 0)
            startDownload(update: update, paths: paths)
        } catch {
            recordUpdateFailure(error)
        }
    }

    /// 跳过当前发现的版本，并删除已下载的暂存内容。
    func skipAvailableUpdate() {
        guard let update = availableUpdate else { return }
        defaults.set(update.version, forKey: skippedVersionKey)
        cancelDownload()
        AuralUpdateInstaller.removeStaging()
        availableUpdate = nil
        phase = .idle
        lastError = nil
    }

    /// 设置窗口关闭后，下一次打开重新从默认入口开始。
    func resetSettingsPresentation() {
        didCheckWithoutUpdate = false
    }

#if DEBUG
    /// 视觉回归测试只注入“发现更新”的静止状态，不发起网络请求或下载。
    func installPreviewUpdate(version: String) {
        availableUpdate = AuralAvailableUpdate(
            version: version,
            pageURL: URL(string: "https://github.com/example/Aural/releases/tag/v\(version)")!,
            downloadURL: URL(string: "https://github.com/example/Aural/releases/download/v\(version)/Aural-\(version)-macOS-arm64.dmg")!,
            sha256: String(repeating: "0", count: 64),
            archiveKind: .dmg
        )
        phase = .available
        isChecking = false
        lastError = nil
        didCheckWithoutUpdate = false
    }

    /// 截图完成后恢复共享单例，避免测试状态泄漏到其他界面快照。
    func clearPreviewUpdate() {
        availableUpdate = nil
        phase = .idle
        isChecking = false
        lastError = nil
        didCheckWithoutUpdate = false
    }
#endif

    /// 真正重启前再确认 helper、payload 和版本，避免退出了才发现安装文件缺失。
    func restartAndInstall() {
        guard phase == .ready, let update = availableUpdate else { return }
        do {
            try AuralUpdateInstaller.validateReadyInstall(expectedVersion: update.version)
            pendingRestart = true
            NSApp.terminate(nil)
        } catch {
            recordUpdateFailure(error)
        }
    }

    /// 音频资源清理成功后由 AppDelegate 在退出阶段调用；helper 会等待当前进程退出再替换应用。
    func launchInstallerIfPending() {
        guard pendingRestart, let update = availableUpdate else { return }
        do {
            try AuralUpdateInstaller.launchHelper(expectedVersion: update.version)
        } catch {
            // 此时 AppKit 已进入退出流程，不能再取消；把明确错误写入日志供下次启动排查。
            AuralUpdateInstaller.appendLog("启动更新 helper 失败：\(error.localizedDescription)\n")
        }
    }

    func cancelPendingRestart() {
        pendingRestart = false
    }

    /// Releases Atom 源不占用 GitHub REST API 的匿名配额，也不依赖客户端内置密钥。
    nonisolated static func newestUpdate(from data: Data, currentVersion: String,
                                         repository: String) throws -> AuralAvailableUpdate? {
        let parser = GitHubReleaseFeedParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else {
            throw AuralUpdateError.invalidReleaseFeed
        }
        guard let current = AuralVersionNumber(currentVersion) else {
            throw AuralUpdateError.invalidCurrentVersion
        }
        let newest = parser.releases
            .compactMap { release -> (AuralVersionNumber, GitHubReleaseEntry)? in
                guard let version = AuralVersionNumber(release.tagName) else { return nil }
                return (version, release)
            }
            .max { $0.0 < $1.0 }
        guard let newest, newest.0 > current else { return nil }
        let version = newest.0.description
        // 新版本只发布 DMG；安装器仍保留 zip 解析分支，避免旧发布资产无法被已安装版本读取。
        let assetName = "Aural-\(version)-macOS-arm64.dmg"
        guard let downloadURL = URL(string:
                "https://github.com/\(repository)/releases/download/v\(version)/\(assetName)") else {
            throw AuralUpdateError.invalidRepository
        }
        return AuralAvailableUpdate(version: version,
                                    pageURL: newest.1.pageURL,
                                    downloadURL: downloadURL,
                                    sha256: "",
                                    archiveKind: .dmg)
    }

    /// 关闭只抑制自动提示；用户主动检查时必须重新展示同一版本。
    nonisolated static func shouldPresent(update: AuralAvailableUpdate,
                                          skippedVersion: String?,
                                          manualCheck: Bool) -> Bool {
        if manualCheck { return true }
        guard let skippedVersion, let skipped = AuralVersionNumber(skippedVersion) else { return true }
        guard let version = AuralVersionNumber(update.version) else { return true }
        return version > skipped
    }

    nonisolated static func parseSHA256Digest(_ digest: String) throws -> String {
        guard digest.hasPrefix("sha256:") else {
            throw AuralUpdateError.invalidDigest(digest)
        }
        let value = String(digest.dropFirst("sha256:".count)).lowercased()
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
            throw AuralUpdateError.invalidDigest(digest)
        }
        return value
    }

    /// Release 的 `.dmg.sha256` 与 `shasum -a 256` 使用相同格式。
    nonisolated static func parseChecksumFile(_ text: String) throws -> String {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard let value = fields.first.map(String.init),
              value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
            throw AuralUpdateError.invalidDigest(text)
        }
        return value.lowercased()
    }

    private func fetchAvailableUpdate() async throws -> AuralAvailableUpdate? {
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "AuralUpdateRepository") as? String,
              !repository.isEmpty else {
            throw AuralUpdateError.missingRepository
        }
        guard let url = URL(string: "https://github.com/\(repository)/releases.atom") else {
            throw AuralUpdateError.invalidRepository
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("Aural/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuralUpdateError.httpFailure((response as? HTTPURLResponse)?.statusCode)
        }
        guard var update = try Self.newestUpdate(from: data, currentVersion: currentVersion,
                                                  repository: repository) else { return nil }
        let checksumURL = update.downloadURL.appendingPathExtension("sha256")
        var checksumRequest = URLRequest(url: checksumURL,
                                         cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 15)
        checksumRequest.setValue("Aural/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (checksumData, checksumResponse) = try await URLSession.shared.data(for: checksumRequest)
        guard let checksumHTTP = checksumResponse as? HTTPURLResponse else {
            throw AuralUpdateError.httpFailure(nil)
        }
        guard checksumHTTP.statusCode == 200 else {
            throw AuralUpdateError.httpFailure(checksumHTTP.statusCode)
        }
        update = AuralAvailableUpdate(version: update.version,
                                      pageURL: update.pageURL,
                                      downloadURL: update.downloadURL,
                                      sha256: try Self.parseChecksumFile(
                                        String(decoding: checksumData, as: UTF8.self)),
                                      archiveKind: update.archiveKind)
        return update
    }

    private func startDownload(update: AuralAvailableUpdate, paths: AuralUpdateInstaller.Paths) {
        cancelDownload()
        downloadGeneration &+= 1
        let generation = downloadGeneration
        let delegate = AuralUpdateDownloadDelegate(
            destination: paths.archive,
            progress: { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.downloadGeneration else { return }
                    if case .downloading = self.phase {
                        self.phase = .downloading(progress: value)
                    }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.downloadGeneration else { return }
                    self.downloadSession = nil
                    self.handleDownload(result, update: update, paths: paths, generation: generation)
                }
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 10 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: update.downloadURL).resume()
    }

    private func handleDownload(_ result: Result<URL, Error>,
                                update: AuralAvailableUpdate,
                                paths: AuralUpdateInstaller.Paths,
                                generation: UInt64) {
        switch result {
        case .failure(let error):
            recordUpdateFailure(error)
        case .success:
            phase = .preparing
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try AuralUpdateInstaller.verifyAndPrepareDownloadedArchive(update: update, paths: paths)
                    }.value
                    guard generation == self.downloadGeneration else { return }
                    phase = .ready
                } catch {
                    guard generation == self.downloadGeneration else { return }
                    recordUpdateFailure(error)
                }
            }
        }
    }

    private func recordUpdateFailure(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        phase = .failed(message)
        AuralUpdateInstaller.appendLog("更新失败：\(message)\n")
    }

    private func cancelDownload() {
        downloadGeneration &+= 1
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
    }
}

/// Atom 条目只承载公开版本标签与页面地址；安装包名由固定发布约定构造。
private struct GitHubReleaseEntry {
    let tagName: String
    let pageURL: URL
}

/// GitHub Releases Atom 中的 entry/title/link 足够发现版本，不需要 REST JSON。
private final class GitHubReleaseFeedParser: NSObject, XMLParserDelegate {
    private(set) var releases: [GitHubReleaseEntry] = []
    private var currentID = ""
    private var readingID = false
    private var currentPageURL: URL?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "entry" {
            currentID = ""
            currentPageURL = nil
        } else if elementName == "id" {
            readingID = true
        } else if elementName == "link", attributeDict["rel"] == "alternate",
                  let value = attributeDict["href"] {
            currentPageURL = URL(string: value)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingID { currentID += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "entry", let pageURL = currentPageURL {
            // GitHub 页面地址不总是带标签前缀，entry id 才严格包含 /v<版本>。
            let tagName = currentID.split(separator: "/").last.map(String.init) ?? ""
            if tagName.hasPrefix("v") {
                releases.append(GitHubReleaseEntry(tagName: tagName, pageURL: pageURL))
            }
        }
        if elementName == "id" { readingID = false }
    }
}

/// URLSession 的下载代理只负责落盘和进度，不在这里改动界面状态。
private final class AuralUpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var didFinish = false

    init(destination: URL,
         progress: @escaping @Sendable (Double) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(0)
            return
        }
        // 只按整数百分比更新界面，避免 URLSession 高频回调触发无意义的 SwiftUI 重绘。
        let raw = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        progress((raw * 100).rounded(.down) / 100)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            finish(.failure(AuralUpdateError.httpFailure((downloadTask.response as? HTTPURLResponse)?.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(destination))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        completion(result)
    }
}

enum AuralSHA256 {
    static func hexDigest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum AuralUpdateError: LocalizedError {
    case missingRepository
    case invalidRepository
    case invalidCurrentVersion
    case httpFailure(Int?)
    case invalidReleaseFeed
    case missingUpdateAsset(String)
    case missingDigest(String)
    case invalidDigest(String)
    case invalidAssetSize(String)
    case appDirectoryNotWritable(String)
    case checksumMismatch
    case archiveSizeMismatch
    case invalidArchive
    case commandFailed(String)
    case invalidBundle
    case bundleIdentifierMismatch(String)
    case bundleVersionMismatch(expected: String, actual: String)
    case invalidSignature(String)
    case helperMissing(String)
    case readyInstallMissing

    var errorDescription: String? {
        switch self {
        case .missingRepository: return "应用未配置更新仓库"
        case .invalidRepository: return "更新仓库地址无效"
        case .invalidCurrentVersion: return "当前版本号无效"
        case .httpFailure(let status):
            return status.map { "服务器返回 HTTP \($0)" } ?? "服务器未返回有效响应"
        case .invalidReleaseFeed:
            return "更新源返回了无法解析的发布信息"
        case .missingUpdateAsset(let name):
            return "最新版本缺少更新包 \(name)"
        case .missingDigest(let name):
            return "更新包 \(name) 缺少 SHA-256 摘要，已拒绝下载"
        case .invalidDigest(let value):
            return "更新包 SHA-256 摘要格式无效：\(value)"
        case .invalidAssetSize(let name):
            return "更新包 \(name) 的文件大小无效"
        case .appDirectoryNotWritable(let path):
            return "无法写入应用所在目录 \(path)，请将 Aural 安装到当前用户可写的应用程序目录"
        case .checksumMismatch:
            return "下载文件 SHA-256 校验失败，已删除该文件"
        case .archiveSizeMismatch:
            return "下载文件大小与 GitHub Release 不一致，已删除该文件"
        case .invalidArchive:
            return "更新包中没有且只有一个 Aural.app"
        case .commandFailed(let message):
            return "更新命令执行失败：\(message)"
        case .invalidBundle:
            return "更新包不是有效的 macOS 应用"
        case .bundleIdentifierMismatch(let value):
            return "更新包 Bundle Identifier 无效：\(value)"
        case .bundleVersionMismatch(let expected, let actual):
            return "更新包版本不匹配：需要 \(expected)，实际为 \(actual)"
        case .invalidSignature(let message):
            return "更新包代码签名验证失败：\(message)"
        case .helperMissing(let path):
            return "更新 helper 缺失：\(path)"
        case .readyInstallMissing:
            return "暂存更新已失效，请重新下载"
        }
    }
}

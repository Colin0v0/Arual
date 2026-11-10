import AppKit
import CryptoKit
import Foundation
import AuralCore

struct AuralAvailableUpdate: Equatable, Sendable {
    let version: String
    let pageURL: URL
    let downloadURL: URL
    let assetSize: Int
    let sha256: String
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
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { isChecking = false }
            do {
                let update = try await fetchAvailableUpdate()
                defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                guard let update else {
                    availableUpdate = nil
                    phase = .idle
                    return
                }
                let skippedVersion = defaults.string(forKey: skippedVersionKey)
                guard Self.shouldPresent(update: update, skippedVersion: skippedVersion) else {
                    availableUpdate = nil
                    phase = .idle
                    return
                }
                // 跳过只对当时那个版本生效；发现更高版本后清除旧记录。
                if skippedVersion != nil {
                    defaults.removeObject(forKey: skippedVersionKey)
                }
                availableUpdate = update
                phase = .available
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

    /// 用户点击更新后下载 zip，完成摘要校验、解压、签名验证后才允许重启安装。
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

    /// 解析层独立于网络，测试可直接覆盖预发布、草稿、乱序响应和资源选择。
    nonisolated static func newestUpdate(from data: Data, currentVersion: String) throws -> AuralAvailableUpdate? {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let current = AuralVersionNumber(currentVersion) else {
            throw AuralUpdateError.invalidCurrentVersion
        }
        let newest = releases
            .filter { !$0.draft }
            .compactMap { release -> (AuralVersionNumber, GitHubRelease)? in
                guard let version = AuralVersionNumber(release.tagName) else { return nil }
                return (version, release)
            }
            .max { $0.0 < $1.0 }
        guard let newest, newest.0 > current else { return nil }
        let version = newest.0.description
        let expectedAssetName = "Aural-\(version)-macOS-arm64.zip"
        guard let asset = newest.1.assets.first(where: { $0.name == expectedAssetName }) else {
            throw AuralUpdateError.missingUpdateAsset(expectedAssetName)
        }
        guard let digest = asset.digest else {
            throw AuralUpdateError.missingDigest(expectedAssetName)
        }
        let sha256 = try parseSHA256Digest(digest)
        guard asset.size > 0 else {
            throw AuralUpdateError.invalidAssetSize(expectedAssetName)
        }
        return AuralAvailableUpdate(version: version,
                                    pageURL: newest.1.htmlURL,
                                    downloadURL: asset.browserDownloadURL,
                                    assetSize: asset.size,
                                    sha256: sha256)
    }

    /// 同一个版本只要被用户关闭过就不再主动展示，更高版本会自动解除跳过状态。
    nonisolated static func shouldPresent(update: AuralAvailableUpdate, skippedVersion: String?) -> Bool {
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

    private func fetchAvailableUpdate() async throws -> AuralAvailableUpdate? {
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "AuralUpdateRepository") as? String,
              !repository.isEmpty else {
            throw AuralUpdateError.missingRepository
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30") else {
            throw AuralUpdateError.invalidRepository
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Aural/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuralUpdateError.httpFailure((response as? HTTPURLResponse)?.statusCode)
        }
        return try Self.newestUpdate(from: data, currentVersion: currentVersion)
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

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
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

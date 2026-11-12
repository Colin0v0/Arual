import Foundation
import AuralCore

/// 应用路由只保存稳定的 bundle 身份，避免 PID 或临时 AudioObjectID 在重启后指向错误应用。
enum AppAudioRouteStoreError: LocalizedError {
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed:
            return "应用路由配置无法读取，请检查本地设置"
        case .writeFailed:
            return "应用路由配置无法保存，请检查本地设置"
        }
    }
}

final class AppAudioRouteStore {
    private static let key = "local.aural.settings.appAudioRoutes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 没有记录是首次使用的正常状态；只有已存在的记录解码失败才明确报错。
    func load() throws -> [String: AppAudioRoute] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        do {
            let routes = try JSONDecoder().decode([String: AppAudioRoute].self, from: data)
            guard routes.keys.allSatisfy({ $0.hasPrefix("bundle:") }) else {
                throw AppAudioRouteStoreError.readFailed
            }
            return routes
        } catch {
            throw AppAudioRouteStoreError.readFailed
        }
    }

    func save(_ routes: [String: AppAudioRoute]) throws {
        guard routes.keys.allSatisfy({ $0.hasPrefix("bundle:") }) else {
            throw AppAudioRouteStoreError.writeFailed
        }
        do {
            let encoder = JSONEncoder()
            // 排序键让持久化结果只由配置内容决定，便于诊断和回归测试。
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(routes)
            defaults.set(data, forKey: Self.key)
        } catch {
            throw AppAudioRouteStoreError.writeFailed
        }
    }
}

import SwiftUI

/// 单个应用的实时电平发布源。
/// 把 30Hz 的更新限制在电平表叶子节点，避免整个面板、分区和应用列表跟着重算。
@MainActor
final class ApplicationLevelSource: ObservableObject {
    @Published private(set) var level: Float?

    /// 只有显示值真正变化时才发布；安静时不为电平表制造无意义的 SwiftUI 更新。
    func update(_ nextLevel: Float?) {
        guard level != nextLevel else { return }
        level = nextLevel
    }
}

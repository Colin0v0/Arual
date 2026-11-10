/// 顶部唯一导航层：输出与麦克风保留同一套 APP 播放控制，耳机功能单独成页。
enum AudioPanelPage: CaseIterable, Hashable {
    case output, microphone, headphones

    var title: String {
        title(language: .chinese)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .output: return L10n.text("输出", language: language)
        case .microphone: return L10n.text("麦克风", language: language)
        case .headphones: return L10n.text("耳机控制", language: language)
        }
    }

    var displaysApplications: Bool { self != .headphones }

    /// 功能关闭后直接移除导航页，不保留一个点击后没有内容的空标签。
    static func available(showHeadphoneControls: Bool) -> [AudioPanelPage] {
        allCases.filter { showHeadphoneControls || $0 != .headphones }
    }
}

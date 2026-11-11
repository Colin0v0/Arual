import AppKit
import SwiftUI

/// 这个类型只用于取得当前代码实际所在的 bundle。
/// 主程序与 SwiftPM 测试宿主会分别提供 `.app` 和 `.xctest` 资源目录。
private final class AuralBrandBundleToken {}

/// 平面标记直接来自用户提供的版本 2 图标，只抠出白色 A 与三层声波弧线，
/// 不再由代码临摹轮廓。
struct AuralBrandMark: View {
    var size: CGFloat = 18
    var tint: Color = PanelStyle.ink

    var body: some View {
        Image(nsImage: AuralBrandAsset.template)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum AuralBrandAsset {
    /// 不读取 SwiftPM 生成的 Bundle.module；不同工具链对该入口查找资源包的位置不同。
    static let bundle: Bundle = {
        guard let resources = Bundle(for: AuralBrandBundleToken.self).resourceURL,
              let bundle = Bundle(url: resources.appendingPathComponent("Aural_Aural.bundle")) else {
            fatalError("缺少 Aural_Aural.bundle 资源包")
        }
        return bundle
    }()

    /// 资源缺失意味着构建不完整，直接暴露错误，不退回手绘或系统占位图标。
    static let template: NSImage = {
        guard let url = bundle.url(forResource: "AuralMarkTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            fatalError("缺少 AuralMarkTemplate.png 品牌标记资源")
        }
        image.isTemplate = true
        return image
    }()
}

/// 状态栏直接复用抠出的透明模板，系统负责按菜单栏明暗模式着色。
enum AuralStatusIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        guard let image = AuralBrandAsset.template.copy() as? NSImage else {
            fatalError("无法复制 Aural 品牌标记模板")
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

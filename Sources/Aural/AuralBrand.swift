import AppKit
import SwiftUI

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
    /// 资源缺失意味着构建不完整，直接暴露错误，不退回手绘或系统占位图标。
    static let template: NSImage = {
        guard let url = Bundle.module.url(forResource: "AuralMarkTemplate", withExtension: "png"),
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

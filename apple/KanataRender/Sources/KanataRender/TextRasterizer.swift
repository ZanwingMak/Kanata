#if canImport(UIKit)
import UIKit

/// 弹幕文本预渲染。
/// 每帧只更新图层位置，文本本身预先光栅化成图片并缓存，
/// 避免高密度下反复排版造成掉帧（NFR-PERF-002）。
final class TextRasterizer {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        // 单集弹幕的不重复文本量有限，上限按条目数控制即可
        cache.countLimit = 2000
    }

    /// 渲染一条弹幕文本
    /// - Parameters:
    ///   - text: 显示内容，已包含合并计数后缀
    ///   - fontSize: 实际字号（点）
    ///   - color: RGB 十进制颜色
    ///   - bold: 是否加粗
    ///   - strokeWidth: 描边宽度
    ///   - fontName: 自定义字体名，nil 用系统字体
    /// - Returns: 可直接赋给 CALayer.contents 的图片
    func image(
        text: String,
        fontSize: Double,
        color: Int,
        bold: Bool,
        strokeWidth: Double,
        fontName: String?
    ) -> UIImage {
        let key = "\(text)|\(fontSize)|\(color)|\(bold)|\(strokeWidth)|\(fontName ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let baseFont: UIFont
        if fontName == "__kanata_system_rounded__",
           let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.rounded) {
            baseFont = UIFont(descriptor: descriptor, size: fontSize)
        } else if fontName == "__kanata_system_serif__",
                  let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.serif) {
            baseFont = UIFont(descriptor: descriptor, size: fontSize)
        } else if let fontName, let custom = UIFont(name: fontName, size: fontSize) {
            baseFont = custom
        } else {
            baseFont = UIFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        }
        let font = bold && fontName != nil
            ? UIFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? baseFont.fontDescriptor,
                size: fontSize
            )
            : baseFont

        // NSAttributedString 的描边值是字号百分比，先把视觉点数换算为百分比。
        let strokePercent = fontSize > 0 ? strokeWidth / fontSize * 100 : 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.uiColor(from: color),
            .strokeColor: UIColor.black.withAlphaComponent(0.85),
            .strokeWidth: -strokePercent
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        // 留出描边溢出的边距
        let inset = CGFloat(strokeWidth) + 2
        let canvasSize = CGSize(width: ceil(size.width) + inset * 2, height: ceil(size.height) + inset * 2)

        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let image = renderer.image { _ in
            attributed.draw(at: CGPoint(x: inset, y: inset))
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 清空缓存。字号或样式整体变化时调用，避免缓存失配
    func clear() {
        cache.removeAllObjects()
    }

    /// 把 RGB 十进制颜色转成 UIColor
    private static func uiColor(from value: Int) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif

import SwiftUI

/// Kanata 的统一影院视觉令牌，集中控制背景、表面与交互色。
enum KanataTheme {
    static let accent = Color(red: 0.18, green: 0.72, blue: 0.86)
    static let accentStrong = Color(red: 0.08, green: 0.58, blue: 0.76)
    static let background = Color(red: 0.025, green: 0.035, blue: 0.065)
    static let surface = Color.white.opacity(0.075)
    static let elevatedSurface = Color.white.opacity(0.11)
    static let separator = Color.white.opacity(0.10)
    static let success = Color(red: 0.28, green: 0.78, blue: 0.55)
    static let warning = Color(red: 0.96, green: 0.67, blue: 0.25)
}

/// 适合表单主操作的高对比度按钮样式。
struct KanataPrimaryButtonStyle: ButtonStyle {
    /// 根据按压状态绘制不缩放的主按钮。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 保持清晰触控反馈的按钮视图。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(
                    colors: [KanataTheme.accent, KanataTheme.accentStrong],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

/// 适合列表和设置页次级操作的表面按钮样式。
struct KanataSecondaryButtonStyle: ButtonStyle {
    /// 根据按压状态绘制带细边框的次级按钮。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 无缩放动画的次级按钮视图。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 14)
            .background(
                configuration.isPressed ? KanataTheme.elevatedSurface : KanataTheme.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(KanataTheme.separator, lineWidth: 1)
            }
    }
}

/// 统一设置页与媒体源页面的图标标题行。
struct KanataRowLabel: View {
    let title: String
    let detail: String?
    let symbol: String
    var tint = KanataTheme.accent

    /// 生成固定图标宽度和稳定文字基线的行标签。
    /// - Parameters:
    ///   - title: 主标题。
    ///   - detail: 可选说明。
    ///   - symbol: SF Symbol 名称。
    ///   - tint: 图标强调色。
    init(title: String, detail: String? = nil, symbol: String, tint: Color = KanataTheme.accent) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// 为 iOS Form 隐藏系统底色，并在 tvOS 使用兼容背景。
    /// - Returns: 应用统一影院背景的视图。
    @ViewBuilder
    func kanataFormBackground() -> some View {
        #if os(tvOS)
        self.background(KanataTheme.background.ignoresSafeArea())
        #else
        self
            .scrollContentBackground(.hidden)
            .background(KanataTheme.background.ignoresSafeArea())
        #endif
    }
}

import SwiftUI
import UIKit

/// 用户可切换的 Kanata 强调色主题。
enum KanataAccentTheme: String, CaseIterable, Identifiable {
    case galaxy
    case aurora
    case sunset
    case amethyst
    case gold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .galaxy: "星河蓝"
        case .aurora: "极光绿"
        case .sunset: "落日红"
        case .amethyst: "紫水晶"
        case .gold: "影院金"
        }
    }

    var accent: Color {
        switch self {
        case .galaxy: Color(red: 0.18, green: 0.72, blue: 0.86)
        case .aurora: Color(red: 0.16, green: 0.78, blue: 0.61)
        case .sunset: Color(red: 1.00, green: 0.38, blue: 0.34)
        case .amethyst: Color(red: 0.66, green: 0.48, blue: 0.96)
        case .gold: Color(red: 0.94, green: 0.67, blue: 0.22)
        }
    }

    var accentStrong: Color {
        switch self {
        case .galaxy: Color(red: 0.08, green: 0.58, blue: 0.76)
        case .aurora: Color(red: 0.05, green: 0.59, blue: 0.45)
        case .sunset: Color(red: 0.82, green: 0.16, blue: 0.30)
        case .amethyst: Color(red: 0.43, green: 0.28, blue: 0.82)
        case .gold: Color(red: 0.72, green: 0.42, blue: 0.08)
        }
    }
}

/// 应用外观模式，可跟随系统或固定为浅色、深色。
enum KanataAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Kanata 的统一影院视觉令牌，集中控制背景、表面与交互色。
enum KanataTheme {
    static let accentStorageKey = "appearance.accentTheme"

    /// 返回 UserDefaults 中当前选择的强调色主题。
    private static var currentAccentTheme: KanataAccentTheme {
        let raw = UserDefaults.standard.string(forKey: accentStorageKey) ?? KanataAccentTheme.galaxy.rawValue
        return KanataAccentTheme(rawValue: raw) ?? .galaxy
    }

    static var accent: Color { currentAccentTheme.accent }
    static var accentStrong: Color { currentAccentTheme.accentStrong }
    static let backgroundTop = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.87, green: 0.92, blue: 0.97, alpha: 1)
            : UIColor(red: 0.005, green: 0.01, blue: 0.025, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
            : UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1)
    })
    static let surface = Color.primary.opacity(0.07)
    static let elevatedSurface = Color.primary.opacity(0.11)
    static let separator = Color.primary.opacity(0.10)
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

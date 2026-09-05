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
        adaptiveColor(light: lightAccent, dark: darkAccent)
    }

    var accentStrong: Color {
        adaptiveColor(light: lightAccentStrong, dark: darkAccentStrong)
    }

    /// 浅色背景使用较深的强调色，保证文字、图标与开关对比度。
    private var lightAccent: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.02, green: 0.42, blue: 0.58, alpha: 1)
        case .aurora: UIColor(red: 0.02, green: 0.43, blue: 0.31, alpha: 1)
        case .sunset: UIColor(red: 0.78, green: 0.13, blue: 0.20, alpha: 1)
        case .amethyst: UIColor(red: 0.43, green: 0.28, blue: 0.76, alpha: 1)
        case .gold: UIColor(red: 0.62, green: 0.37, blue: 0.04, alpha: 1)
        }
    }

    /// 深色背景使用较明亮的强调色，保持影院界面的辨识度。
    private var darkAccent: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.18, green: 0.72, blue: 0.86, alpha: 1)
        case .aurora: UIColor(red: 0.16, green: 0.78, blue: 0.61, alpha: 1)
        case .sunset: UIColor(red: 1.00, green: 0.38, blue: 0.34, alpha: 1)
        case .amethyst: UIColor(red: 0.66, green: 0.48, blue: 0.96, alpha: 1)
        case .gold: UIColor(red: 0.94, green: 0.67, blue: 0.22, alpha: 1)
        }
    }

    /// 浅色模式下用于渐变末端和聚焦边界的更深颜色。
    private var lightAccentStrong: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.01, green: 0.30, blue: 0.46, alpha: 1)
        case .aurora: UIColor(red: 0.01, green: 0.31, blue: 0.22, alpha: 1)
        case .sunset: UIColor(red: 0.62, green: 0.07, blue: 0.15, alpha: 1)
        case .amethyst: UIColor(red: 0.32, green: 0.18, blue: 0.62, alpha: 1)
        case .gold: UIColor(red: 0.48, green: 0.25, blue: 0.01, alpha: 1)
        }
    }

    /// 深色模式下用于渐变末端和聚焦边界的强调色。
    private var darkAccentStrong: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.08, green: 0.58, blue: 0.76, alpha: 1)
        case .aurora: UIColor(red: 0.05, green: 0.59, blue: 0.45, alpha: 1)
        case .sunset: UIColor(red: 0.82, green: 0.16, blue: 0.30, alpha: 1)
        case .amethyst: UIColor(red: 0.43, green: 0.28, blue: 0.82, alpha: 1)
        case .gold: UIColor(red: 0.72, green: 0.42, blue: 0.08, alpha: 1)
        }
    }

    /// 根据系统当前明暗外观返回动态 UIColor，切换外观时无需重建页面。
    /// - Parameters:
    ///   - light: 浅色模式颜色。
    ///   - dark: 深色模式颜色。
    /// - Returns: 会随 trait collection 自动刷新的 SwiftUI 颜色。
    private func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? light : dark
        })
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
    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.04, green: 0.47, blue: 0.28, alpha: 1)
            : UIColor(red: 0.28, green: 0.78, blue: 0.55, alpha: 1)
    })
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.66, green: 0.37, blue: 0.02, alpha: 1)
            : UIColor(red: 0.96, green: 0.67, blue: 0.25, alpha: 1)
    })
}

/// 适合表单主操作的高对比度按钮样式。
struct KanataPrimaryButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    /// 根据按压状态绘制不缩放的主按钮。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 保持清晰触控反馈的按钮视图。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .frame(minHeight: 50, alignment: .center)
            .background(
                LinearGradient(
                    colors: [KanataTheme.accent, KanataTheme.accentStrong],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(primaryFocusOpacity), lineWidth: primaryFocusLineWidth)
            }
            .shadow(color: KanataTheme.accent.opacity(primaryFocusOpacity), radius: 14)
            #if os(tvOS)
            .scaleEffect(isFocused ? 1.018 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: 0.16), value: isFocused)
            #endif
            .opacity(configuration.isPressed ? 0.78 : 1)
    }

    /// 返回 Apple TV 当前焦点的描边透明度。
    private var primaryFocusOpacity: Double {
        #if os(tvOS)
        isFocused ? 0.72 : 0
        #else
        0
        #endif
    }

    /// 返回 Apple TV 当前焦点的描边宽度。
    private var primaryFocusLineWidth: CGFloat {
        #if os(tvOS)
        isFocused ? 2 : 0
        #else
        0
        #endif
    }
}

/// 适合列表和设置页次级操作的表面按钮样式。
struct KanataSecondaryButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    /// 根据按压状态绘制带细边框的次级按钮。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 无缩放动画的次级按钮视图。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 14)
            .frame(minHeight: 48, alignment: .center)
            .background(
                secondaryBackground(configuration: configuration),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(secondaryBorder, lineWidth: secondaryLineWidth)
            }
            .shadow(color: KanataTheme.accent.opacity(secondaryFocusOpacity), radius: 12)
            #if os(tvOS)
            .scaleEffect(isFocused ? 1.015 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: 0.16), value: isFocused)
            #endif
    }

    /// 返回次级按钮在按压和 Apple TV 聚焦状态下的背景色。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 不依赖缩放的清晰焦点背景。
    private func secondaryBackground(configuration: Configuration) -> Color {
        if configuration.isPressed { return KanataTheme.elevatedSurface }
        #if os(tvOS)
        if isFocused { return KanataTheme.accent.opacity(0.16) }
        #endif
        return KanataTheme.surface
    }

    /// 返回次级按钮当前描边颜色。
    private var secondaryBorder: Color {
        #if os(tvOS)
        if isFocused { return KanataTheme.accent }
        #endif
        return KanataTheme.separator
    }

    /// 返回次级按钮当前描边宽度。
    private var secondaryLineWidth: CGFloat {
        #if os(tvOS)
        isFocused ? 2 : 1
        #else
        1
        #endif
    }

    /// 返回次级按钮 Apple TV 焦点阴影透明度。
    private var secondaryFocusOpacity: Double {
        #if os(tvOS)
        isFocused ? 0.24 : 0
        #else
        0
        #endif
    }
}

#if os(tvOS)
/// Apple TV 顶部操作使用的紧凑文字按钮，保证图标、文案和焦点都清晰可见。
struct KanataTVActionButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    /// 绘制带文字的电视操作按钮，聚焦时仅轻微放大并使用主题色描边。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 适合遥控器焦点移动的操作按钮。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 58)
            .background(
                isFocused ? KanataTheme.accent.opacity(0.18) : KanataTheme.elevatedSurface,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isFocused ? KanataTheme.accent : KanataTheme.separator, lineWidth: isFocused ? 2 : 1)
            }
            .shadow(color: KanataTheme.accent.opacity(isFocused ? 0.22 : 0), radius: 14)
            .scaleEffect(isFocused ? 1.025 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}
#endif

#if os(tvOS)
/// Apple TV 卡片与列表行统一使用无白色材质的克制焦点样式。
private struct KanataTVFocusButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    @Environment(\.isFocused) private var isFocused

    /// 直接接管按钮焦点绘制，避免系统白色材质与自定义效果叠加。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 仅使用主题色描边、轻微提亮和阴影的按钮。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? KanataTheme.accent.opacity(0.92) : Color.clear, lineWidth: 2)
            }
            .shadow(color: .black.opacity(isFocused ? 0.34 : 0), radius: 18, y: 10)
            .shadow(color: KanataTheme.accent.opacity(isFocused ? 0.20 : 0), radius: 12)
            .brightness(isFocused ? 0.035 : 0)
            .saturation(isFocused ? 1.05 : 1)
            .scaleEffect(isFocused ? 1.022 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .zIndex(isFocused ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}
#endif

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
                #if os(tvOS)
                .font(.title3.weight(.semibold))
                .frame(width: 46, height: 46)
                #else
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                #endif
                .foregroundStyle(tint)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    #if os(tvOS)
                    .font(.title3.weight(.semibold))
                    #else
                    .font(.body.weight(.medium))
                    #endif
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        #if os(tvOS)
                        .font(.body)
                        #else
                        .font(.caption)
                        #endif
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        #if os(tvOS)
        .frame(minHeight: 68)
        #endif
        .contentShape(Rectangle())
    }
}

extension View {
    /// 在 Apple TV 接管按钮焦点绘制，其他平台继续使用无附加材质的 plain 样式。
    /// - Parameter cornerRadius: 控件焦点框圆角。
    /// - Returns: 不会叠加系统白色焦点材质的按钮或导航入口。
    @ViewBuilder
    func kanataTVFocus(cornerRadius: CGFloat = 14) -> some View {
        #if os(tvOS)
        buttonStyle(KanataTVFocusButtonStyle(cornerRadius: cornerRadius))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// 在 Apple TV 的子目录中让遥控器返回键优先返回上一级，根目录保持系统导航行为。
    /// - Parameters:
    ///   - isEnabled: 当前是否存在可返回的内部目录层级。
    ///   - action: 返回上一级目录的操作。
    /// - Returns: 仅在需要时拦截遥控器返回键的视图。
    @ViewBuilder
    func kanataTVExitCommand(isEnabled: Bool, perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        if isEnabled {
            self.onExitCommand(perform: action)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// 统一文字工具栏按钮的最小触控区和文字基线，避免胶囊内视觉偏移。
    /// - Returns: 文字在 44pt 触控区内水平、垂直居中的按钮标签。
    func kanataToolbarTextButton() -> some View {
        self
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .frame(minWidth: 44, minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
    }

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

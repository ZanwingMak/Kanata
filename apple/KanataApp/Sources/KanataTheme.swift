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

    /// 实心操作按钮始终使用深色底，保证白色标签在所有主题下可读。
    var actionFill: Color { Color(uiColor: lightAccent) }
    var actionFillStrong: Color { Color(uiColor: lightAccentStrong) }

    /// 返回主题用于大面积环境光的陪衬色，避免界面只剩单一强调色。
    var ambientCompanion: Color {
        adaptiveColor(light: lightAmbientCompanion, dark: darkAmbientCompanion)
    }

    /// 返回主题用于局部高光的暖色或冷色补色。
    var ambientHighlight: Color {
        adaptiveColor(light: lightAmbientHighlight, dark: darkAmbientHighlight)
    }

    /// 返回主题预览与强调控件使用的完整三色渐变。
    var palette: [Color] {
        [accent, ambientCompanion, ambientHighlight]
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

    /// 浅色模式下的大面积环境陪衬色。
    private var lightAmbientCompanion: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.36, green: 0.30, blue: 0.77, alpha: 1)
        case .aurora: UIColor(red: 0.12, green: 0.45, blue: 0.66, alpha: 1)
        case .sunset: UIColor(red: 0.70, green: 0.25, blue: 0.52, alpha: 1)
        case .amethyst: UIColor(red: 0.22, green: 0.42, blue: 0.77, alpha: 1)
        case .gold: UIColor(red: 0.68, green: 0.25, blue: 0.18, alpha: 1)
        }
    }

    /// 深色模式下的大面积环境陪衬色。
    private var darkAmbientCompanion: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.28, green: 0.22, blue: 0.68, alpha: 1)
        case .aurora: UIColor(red: 0.08, green: 0.40, blue: 0.62, alpha: 1)
        case .sunset: UIColor(red: 0.70, green: 0.18, blue: 0.48, alpha: 1)
        case .amethyst: UIColor(red: 0.18, green: 0.34, blue: 0.72, alpha: 1)
        case .gold: UIColor(red: 0.64, green: 0.20, blue: 0.12, alpha: 1)
        }
    }

    /// 浅色模式下的小面积环境高光色。
    private var lightAmbientHighlight: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.18, green: 0.66, blue: 0.72, alpha: 1)
        case .aurora: UIColor(red: 0.66, green: 0.64, blue: 0.16, alpha: 1)
        case .sunset: UIColor(red: 0.92, green: 0.53, blue: 0.16, alpha: 1)
        case .amethyst: UIColor(red: 0.78, green: 0.25, blue: 0.58, alpha: 1)
        case .gold: UIColor(red: 0.90, green: 0.61, blue: 0.16, alpha: 1)
        }
    }

    /// 深色模式下的小面积环境高光色。
    private var darkAmbientHighlight: UIColor {
        switch self {
        case .galaxy: UIColor(red: 0.10, green: 0.62, blue: 0.72, alpha: 1)
        case .aurora: UIColor(red: 0.56, green: 0.60, blue: 0.10, alpha: 1)
        case .sunset: UIColor(red: 0.92, green: 0.42, blue: 0.10, alpha: 1)
        case .amethyst: UIColor(red: 0.70, green: 0.18, blue: 0.54, alpha: 1)
        case .gold: UIColor(red: 0.86, green: 0.48, blue: 0.08, alpha: 1)
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
    static var actionFill: Color { currentAccentTheme.actionFill }
    static var actionFillStrong: Color { currentAccentTheme.actionFillStrong }
    static var ambientCompanion: Color { currentAccentTheme.ambientCompanion }
    static var ambientHighlight: Color { currentAccentTheme.ambientHighlight }
    static let backgroundTop = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.87, green: 0.92, blue: 0.97, alpha: 1)
            : UIColor(red: 0.025, green: 0.029, blue: 0.038, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
            : UIColor(red: 0.035, green: 0.041, blue: 0.055, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.98, green: 0.985, blue: 0.995, alpha: 0.88)
            : UIColor(red: 0.085, green: 0.095, blue: 0.115, alpha: 0.96)
    })
    static let elevatedSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.96)
            : UIColor(red: 0.13, green: 0.145, blue: 0.17, alpha: 0.98)
    })
    static let overlaySurface = Color.black.opacity(0.82)
    static let separator = Color.primary.opacity(0.12)
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

/// 在所有层级页面后方绘制随主题变化的柔和环境光背景。
struct KanataAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [KanataTheme.backgroundTop, KanataTheme.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    KanataTheme.ambientCompanion.opacity(colorScheme == .dark ? 0.08 : 0.08),
                    .clear,
                    KanataTheme.accent.opacity(colorScheme == .dark ? 0.06 : 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [.clear, KanataTheme.ambientHighlight.opacity(colorScheme == .dark ? 0.07 : 0.04)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 为信息卡片提供统一的液态玻璃承载层。
private struct KanataGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isElevated: Bool

    /// 绘制带主题染色、内高光和柔和阴影的玻璃表面。
    /// - Parameter content: 需要承载的卡片内容。
    /// - Returns: 统一视觉深度的玻璃卡片。
    @ViewBuilder
    func body(content: Content) -> some View {
        if isElevated {
            content.kanataFloatingSurface(cornerRadius: cornerRadius)
        } else {
            content.background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// 仅浮层采样系统玻璃，静态列表不叠加昂贵的背景折射。
private struct KanataFloatingSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 原生玻璃支持降低透明度设置，旧系统使用常规材质。
    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(KanataTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(iOS 26, tvOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// 电视设置使用固定内边距的分组滚动布局，避免系统 Form 随焦点横移和放大。
struct KanataSettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(tvOS)
        if #available(tvOS 18.0, *) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(sections: content) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            section.header
                                .font(.system(size: 23, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                            ForEach(section.content) { row in
                                row
                                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            }
                            section.footer
                                .font(.system(size: 21))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .font(.system(size: 27))
                .padding(24)
            }
        } else {
            Form { content }.padding(.horizontal, 24)
        }
        #else
        Form { content }
        #endif
    }
}

extension View {
    /// 为导航与弹出面板提供统一玻璃表面。
    func kanataFloatingSurface(cornerRadius: CGFloat = 24) -> some View {
        modifier(KanataFloatingSurface(cornerRadius: cornerRadius))
    }
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
                    colors: [KanataTheme.actionFill, KanataTheme.actionFillStrong],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(primaryFocusOpacity), lineWidth: primaryFocusLineWidth)
            }
            #if os(tvOS)
            .focusEffectDisabled()
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
            .foregroundStyle(secondaryForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 14)
            .frame(minHeight: 48, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(secondaryTint(configuration: configuration))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(secondaryBorder, lineWidth: secondaryLineWidth)
            }
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
    }

    /// 返回次级按钮在按压和 Apple TV 聚焦状态下的背景色。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 不依赖缩放的清晰焦点背景。
    private func secondaryTint(configuration: Configuration) -> Color {
        if configuration.isPressed { return KanataTheme.elevatedSurface }
        #if os(tvOS)
        if isFocused { return KanataTheme.elevatedSurface }
        #endif
        return KanataTheme.surface
    }

    /// 返回次级按钮在电视高亮状态下的高对比度文字颜色。
    private var secondaryForeground: Color {
        #if os(tvOS)
        .primary
        #else
        .primary
        #endif
    }

    /// 返回次级按钮当前描边颜色。
    private var secondaryBorder: Color {
        #if os(tvOS)
        if isFocused { return .white.opacity(0.72) }
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

}

#if os(tvOS)
/// Apple TV 顶部操作使用的紧凑文字按钮，保证图标、文案和焦点都清晰可见。
struct KanataTVActionButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 绘制带文字的电视操作按钮，聚焦时使用高对比度主题底色。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 适合遥控器焦点移动的操作按钮。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 58)
            .background {
                Capsule()
                    .fill(isFocused ? Color.white : Color.clear)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .focusEffectDisabled()
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }
}
#endif

#if os(tvOS)
/// Apple TV 卡片与列表行统一使用无白色材质的克制焦点样式。
private struct KanataTVFocusButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 直接接管按钮焦点绘制，避免系统白色材质与自定义效果叠加。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 仅使用主题色描边、轻微提亮和阴影的按钮。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? Color.primary.opacity(0.92) : Color.clear, lineWidth: 3)
            }
            .background(
                isFocused ? KanataTheme.accent.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .brightness(isFocused ? 0.025 : 0)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .zIndex(isFocused ? 1 : 0)
            .scaleEffect(isFocused ? 1.025 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }
}
#endif

#if os(tvOS)
/// 表单行在焦点切换时保持原有尺寸，避免系统放大越过抽屉与侧栏边界。
struct KanataTVFormButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    /// 以内部描边和轻微提亮表示焦点，不改变行的位置或宽度。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(isFocused ? KanataTheme.accent.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isFocused ? Color.primary.opacity(0.9) : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .focusEffectDisabled()
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 电视表单开关使用与按钮相同的焦点规则，并明确显示中文状态。
struct KanataTVFormToggleStyle: ToggleStyle {
    /// 用单个按钮承载开关，避免行和内嵌控件竞争遥控器焦点。
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 20) {
                configuration.label
                Spacer(minLength: 12)
                Text(configuration.isOn ? "开启" : "关闭")
                    .font(.system(size: 23, weight: .medium))
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 25))
                    .foregroundStyle(configuration.isOn ? KanataTheme.accent : .secondary)
            }
        }
        .buttonStyle(KanataTVFormButtonStyle())
        .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}
#endif

/// 文件浏览器密集行专用样式；焦点边框贴合控件本身，不额外放大或挤占相邻操作。
private struct KanataDirectoryRowButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    /// 绘制单层行背景与内描边，避免系统焦点、背景和外边框形成双框。
    /// - Parameter configuration: SwiftUI 按钮状态。
    /// - Returns: 尺寸稳定的目录行按钮。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(rowBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(rowBorder, lineWidth: rowBorderWidth)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            #if os(tvOS)
            .focusEffectDisabled()
            .brightness(isFocused ? 0.025 : 0)
            #endif
            .opacity(configuration.isPressed ? 0.76 : 1)
    }

    /// 当前焦点状态对应的行背景。
    private var rowBackground: Color {
        #if os(tvOS)
        isFocused ? KanataTheme.accent.opacity(0.20) : KanataTheme.surface
        #else
        KanataTheme.surface
        #endif
    }

    /// 当前焦点状态对应的单层边框颜色。
    private var rowBorder: Color {
        #if os(tvOS)
        isFocused ? KanataTheme.accent : KanataTheme.separator.opacity(0.65)
        #else
        KanataTheme.separator.opacity(0.55)
        #endif
    }

    /// 当前焦点状态对应的边框宽度。
    private var rowBorderWidth: CGFloat {
        #if os(tvOS)
        isFocused ? 2 : 1
        #else
        1
        #endif
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
                #if os(tvOS)
                .font(.system(size: 26, weight: .medium))
                .frame(width: 44, height: 44)
                #else
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                #endif
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    #if os(tvOS)
                    .font(.system(size: 27, weight: .semibold))
                    #else
                    .font(.body.weight(.medium))
                    #endif
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        #if os(tvOS)
                        .font(.system(size: 21))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 68)
        #endif
        .contentShape(Rectangle())
    }
}

/// 在设置页中直观展示主题色与环境光配色。
struct KanataThemePreview: View {
    let theme: KanataAccentTheme
    let isSelected: Bool

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: theme.palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 100)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Capsule().frame(width: 68, height: 5)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.caption)
                    .padding(16)
                }
            HStack {
                Text(theme.title).font(.system(size: 23, weight: .medium))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.accent : Color.secondary.opacity(0.4))
            }
        }
        .padding(14)
        .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        #else
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: theme.palette,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
            Text(theme.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 58)
        .kanataGlassSurface(cornerRadius: 16, isElevated: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        #endif
    }
}

extension View {
    /// 表单中的按钮与开关使用稳定尺寸的电视焦点，手机保持系统交互。
    @ViewBuilder
    func kanataTVFormControls() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(KanataTVFormButtonStyle())
            .toggleStyle(KanataTVFormToggleStyle())
        #else
        self
        #endif
    }

    /// 在 Apple TV 使用全屏任务面板，在触屏设备保留系统 Sheet。
    /// - Parameters:
    ///   - isPresented: 是否显示面板。
    ///   - content: 面板内容。
    /// - Returns: 符合当前平台交互距离的模态界面。
    @ViewBuilder
    func kanataModal<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    /// 在 Apple TV 使用全屏数据面板，在触屏设备保留系统 Sheet。
    /// - Parameters:
    ///   - item: 驱动面板展示的数据。
    ///   - content: 使用当前数据构建的面板内容。
    /// - Returns: 符合当前平台交互距离的数据模态界面。
    @ViewBuilder
    func kanataModal<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }

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

    /// 为目录主行和右侧操作提供无缩放、单描边的稳定焦点样式。
    /// - Parameter cornerRadius: 行背景与焦点框圆角。
    /// - Returns: 不会与相邻按钮边框重叠的目录按钮。
    func kanataDirectoryRowStyle(cornerRadius: CGFloat = 14) -> some View {
        buttonStyle(KanataDirectoryRowButtonStyle(cornerRadius: cornerRadius))
    }

    /// 将普通内容提升为统一的液态玻璃卡片。
    /// - Parameters:
    ///   - cornerRadius: 卡片圆角。
    ///   - isElevated: 是否使用更明显的材质与阴影层级。
    /// - Returns: 带主题染色的玻璃表面。
    func kanataGlassSurface(cornerRadius: CGFloat = 20, isElevated: Bool = false) -> some View {
        modifier(KanataGlassSurfaceModifier(cornerRadius: cornerRadius, isElevated: isElevated))
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
        self
            .contentMargins(.horizontal, 32, for: .scrollContent)
            .kanataTVFormControls()
            .background(KanataAmbientBackground())
        #else
        self
            .scrollContentBackground(.hidden)
            .background(KanataAmbientBackground())
        #endif
    }
}

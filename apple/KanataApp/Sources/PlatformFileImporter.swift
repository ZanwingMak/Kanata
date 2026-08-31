import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// 在 iOS/iPadOS 挂载系统文件选择器；tvOS 不提供文件选择能力时保持原视图。
    @ViewBuilder
    func kanataFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
        #if os(tvOS)
        self
        #else
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            onCompletion: onCompletion
        )
        #endif
    }

    /// 在支持状态栏的系统隐藏状态栏；tvOS 保持原视图。
    @ViewBuilder
    func kanataStatusBarHidden() -> some View {
        #if os(tvOS)
        self
        #else
        statusBarHidden()
        #endif
    }

    /// 在 iOS/iPadOS 使用行内导航标题；tvOS 使用系统默认标题样式。
    @ViewBuilder
    func kanataInlineNavigationTitle() -> some View {
        #if os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

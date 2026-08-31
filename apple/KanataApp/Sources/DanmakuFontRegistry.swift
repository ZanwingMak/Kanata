import CoreText
import Foundation
import UIKit

/// 弹幕设置中可选的一种字体。
struct DanmakuFontOption: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 管理系统预置字体和用户导入的 TTF/OTF 字体。
enum DanmakuFontRegistry {
    static let roundedFontName = "__kanata_system_rounded__"
    static let serifFontName = "__kanata_system_serif__"

    /// 注册应用支持目录内已导入的全部字体。
    static func registerStoredFonts() {
        for url in storedFontURLs() {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// 返回当前设备可用且适合弹幕显示的字体选项。
    /// - Returns: 系统字体、系统设计字体和已导入字体。
    static func availableFonts() -> [DanmakuFontOption] {
        registerStoredFonts()
        var options = [
            DanmakuFontOption(id: "", title: "系统黑体"),
            DanmakuFontOption(id: roundedFontName, title: "系统圆体"),
            DanmakuFontOption(id: serifFontName, title: "系统宋体"),
        ]
        let preferred = [
            ("PingFangSC-Regular", "苹方"),
            ("PingFangSC-Semibold", "苹方中粗"),
            ("STHeitiSC-Light", "华文黑体"),
        ]
        for (name, title) in preferred where UIFont(name: name, size: 20) != nil {
            options.append(DanmakuFontOption(id: name, title: title))
        }
        for url in storedFontURLs() {
            for name in postScriptNames(at: url) where !options.contains(where: { $0.id == name }) {
                options.append(DanmakuFontOption(id: name, title: "导入 · \(name)"))
            }
        }
        return options
    }

    /// 把用户选择的字体复制进应用支持目录并注册到当前进程。
    /// - Parameter sourceURL: 文件选择器返回的 TTF 或 OTF 地址。
    /// - Returns: 可写入渲染配置的 PostScript 字体名。
    static func importFont(from sourceURL: URL) throws -> String {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(fileExtension) else {
            throw DanmakuFontError.unsupportedFormat
        }
        let directory = try fontsDirectory()
        let destination = directory.appendingPathComponent(
            "\(UUID().uuidString).\(fileExtension)",
            isDirectory: false
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        guard let name = postScriptNames(at: destination).first else {
            try? FileManager.default.removeItem(at: destination)
            throw DanmakuFontError.invalidFont
        }
        let registered = CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
        guard registered || UIFont(name: name, size: 20) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw DanmakuFontError.invalidFont
        }
        return name
    }

    /// 构建应用支持目录中的字体存储位置。
    /// - Returns: 已创建的字体目录。
    private static func fontsDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("DanmakuFonts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 扫描应用支持目录中已保存的字体文件。
    /// - Returns: 按文件名排序的字体 URL。
    private static func storedFontURLs() -> [URL] {
        guard let directory = try? fontsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls
            .filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 从字体文件读取所有 PostScript 名称。
    /// - Parameter url: 已复制到应用目录的字体文件。
    /// - Returns: 可供 UIFont 创建字体的名称。
    private static func postScriptNames(at url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }
    }
}

/// 用户导入字体时可直接展示的错误。
private enum DanmakuFontError: LocalizedError {
    case unsupportedFormat
    case invalidFont

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "请选择 TTF、OTF 或 TTC 字体文件"
        case .invalidFont: "字体文件无效或系统无法注册该字体"
        }
    }
}

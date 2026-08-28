import AppKit
import Darwin
import Foundation

private let appTitle = "一键整理桌面文件"
private let fileManager = FileManager.default

private struct Metrics: Codable {
    var total = 0
    var moved = 0
    var copied = 0
    var images = 0
    var documents = 0
    var tables = 0
    var other = 0
    var failed = 0
    var elapsedSeconds = 0.0
}

private enum FileCategory: String {
    case image = "图片归档"
    case document = "文档归档"
    case table = "表格归档"
}

private struct Options {
    var desktopOverride: URL?
    var headless = false
    var dryRun = false
}

private func parseOptions() -> Options {
    var options = Options()
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        switch arguments[index] {
        case "--desktop" where index + 1 < arguments.count:
            options.desktopOverride = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            index += 2
        case "--headless":
            options.headless = true
            index += 1
        case "--dry-run":
            options.dryRun = true
            index += 1
        default:
            index += 1
        }
    }
    return options
}

private func desktopURL(for options: Options) -> URL {
    if let override = options.desktopOverride { return override.standardizedFileURL }
    return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
}

private func category(for filename: String) -> FileCategory? {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic"].contains(ext) {
        return .image
    }
    if ext == "txt" { return .document }
    if ["xlsx", "xls", "csv"].contains(ext) { return .table }
    return nil
}

private let prefixedNameRegex = try! NSRegularExpression(pattern: "^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2} .+")
private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy.MM.dd"
    return formatter
}()

private func hasDatePrefix(_ name: String) -> Bool {
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    return prefixedNameRegex.firstMatch(in: name, range: range) != nil
}

private func sourceDate(for file: URL, filename: String) -> Date {
    if hasDatePrefix(filename), filename.count >= 10 {
        let prefix = String(filename.prefix(10))
        if let date = dateFormatter.date(from: prefix) { return date }
    }
    let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return values?.creationDate ?? values?.contentModificationDate ?? Date()
}

private func originalName(from filename: String) -> String {
    guard hasDatePrefix(filename), filename.count > 11 else { return filename }
    return String(filename.dropFirst(11))
}

private func weekFolder(for date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    let weekday = calendar.component(.weekday, from: date)
    let daysAfterMonday = (weekday + 5) % 7
    let monday = calendar.date(byAdding: .day, value: -daysAfterMonday, to: calendar.startOfDay(for: date)) ?? date
    let sunday = calendar.date(byAdding: .day, value: 6, to: monday) ?? date
    return "\(dateFormatter.string(from: monday))-\(dateFormatter.string(from: sunday))"
}

private func uniqueDestination(in directory: URL, filename: String) -> URL {
    let desired = directory.appendingPathComponent(filename)
    if !fileManager.fileExists(atPath: desired.path) { return desired }

    let source = URL(fileURLWithPath: filename)
    let ext = source.pathExtension
    let stem = source.deletingPathExtension().lastPathComponent
    var number = 2
    while true {
        let candidateName = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
        let candidate = directory.appendingPathComponent(candidateName)
        if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        number += 1
    }
}

private func candidateFiles(on desktop: URL) throws -> [URL] {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let urls = try fileManager.contentsOfDirectory(
        at: desktop,
        includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
        options: [.skipsHiddenFiles]
    )
    return try urls.filter { url in
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
        guard values.isRegularFile == true, values.isHidden != true else { return false }
        guard !url.lastPathComponent.hasPrefix("~$") else { return false }
        return url.standardizedFileURL != executable
    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

private func logURL() -> URL {
    fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/一键整理桌面文件", isDirectory: true)
        .appendingPathComponent("last-run.log")
}

private func writeLog(_ text: String) {
    let url = logURL()
    do {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        // 日志失败不阻止用户整理桌面。
    }
}

private func runCleanup(options: Options) throws -> (Metrics, [String]) {
    let startedAt = Date()
    let desktop = desktopURL(for: options)
    var metrics = Metrics()
    var errors: [String] = []
    let files = try candidateFiles(on: desktop)
    metrics.total = files.count

    for file in files {
        let filename = file.lastPathComponent
        let original = originalName(from: filename)
        let fileCategory = category(for: original)

        if options.dryRun {
            switch fileCategory {
            case .image: metrics.images += 1
            case .document: metrics.documents += 1
            case .table: metrics.tables += 1
            case nil: metrics.other += 1
            }
            continue
        }

        do {
            let date = sourceDate(for: file, filename: filename)
            let datedName = hasDatePrefix(filename) ? filename : "\(dateFormatter.string(from: date)) \(filename)"
            let weeklyDirectory = desktop
                .appendingPathComponent("归档", isDirectory: true)
                .appendingPathComponent("按周归档", isDirectory: true)
                .appendingPathComponent(weekFolder(for: date), isDirectory: true)
            try fileManager.createDirectory(at: weeklyDirectory, withIntermediateDirectories: true)
            let movedURL = uniqueDestination(in: weeklyDirectory, filename: datedName)
            try fileManager.moveItem(at: file, to: movedURL)
            metrics.moved += 1

            if let fileCategory {
                let typeDirectory = desktop
                    .appendingPathComponent("归档", isDirectory: true)
                    .appendingPathComponent(fileCategory.rawValue, isDirectory: true)
                try fileManager.createDirectory(at: typeDirectory, withIntermediateDirectories: true)
                let copyURL = uniqueDestination(in: typeDirectory, filename: movedURL.lastPathComponent)
                try fileManager.copyItem(at: movedURL, to: copyURL)
                metrics.copied += 1
                switch fileCategory {
                case .image: metrics.images += 1
                case .document: metrics.documents += 1
                case .table: metrics.tables += 1
                }
            } else {
                metrics.other += 1
            }
        } catch {
            metrics.failed += 1
            errors.append("\(filename)：\(error.localizedDescription)")
        }
    }

    metrics.elapsedSeconds = Date().timeIntervalSince(startedAt)
    return (metrics, errors)
}

private func summaryText(metrics: Metrics, dryRun: Bool) -> String {
    let action = dryRun ? "预计发现" : "共处理"
    return """
    \(action) \(metrics.total) 个文件 · 用时 \(String(format: "%.1f", metrics.elapsedSeconds)) 秒

    图片 \(metrics.images)　文档 \(metrics.documents)　表格 \(metrics.tables)　其他 \(metrics.other)
    移动 \(metrics.moved) 个 · 生成分类副本 \(metrics.copied) 份
    \(metrics.failed > 0 ? "未完成 \(metrics.failed) 个" : "所有文件处理正常")
    """
}

private func showResult(metrics: Metrics, errors: [String], dryRun: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = errors.isEmpty ? .informational : .warning
    alert.messageText = errors.isEmpty ? (dryRun ? "桌面整理预览" : "整理完成 ✓") : "部分文件没有整理完成"
    alert.informativeText = summaryText(metrics: metrics, dryRun: dryRun)
    alert.addButton(withTitle: "关闭")
    alert.runModal()
}

private func acquireLock() -> URL? {
    let url = fileManager.temporaryDirectory.appendingPathComponent("online.yuanzi.desktop-cleanup.lock", isDirectory: true)
    if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
       let modified = values.contentModificationDate,
       Date().timeIntervalSince(modified) > 3600 {
        try? fileManager.removeItem(at: url)
    }
    do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    } catch {
        return nil
    }
}

@main
struct DesktopCleanupApp {
    static func main() {
        let options = parseOptions()
        guard let lockURL = acquireLock() else {
            if options.headless {
                fputs("整理任务已经在运行。\n", stderr)
            } else {
                let alert = NSAlert()
                alert.messageText = appTitle
                alert.informativeText = "整理任务已经在运行，请稍候。"
                alert.runModal()
            }
            exit(2)
        }
        defer { try? fileManager.removeItem(at: lockURL) }

        do {
            let (metrics, errors) = try runCleanup(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(data: try encoder.encode(metrics), encoding: .utf8) ?? "{}"
            let log = "\(Date())\n桌面：\(desktopURL(for: options).path)\n\(summaryText(metrics: metrics, dryRun: options.dryRun))\n\(errors.joined(separator: "\n"))\n"
            writeLog(log)
            if options.headless {
                print(json)
            } else {
                showResult(metrics: metrics, errors: errors, dryRun: options.dryRun)
            }
            exit(errors.isEmpty ? 0 : 1)
        } catch {
            let message = "无法读取或整理桌面：\(error.localizedDescription)"
            writeLog("\(Date())\n\(message)\n")
            if options.headless {
                fputs("\(message)\n", stderr)
            } else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = appTitle
                alert.informativeText = message
                alert.addButton(withTitle: "关闭")
                alert.runModal()
            }
            exit(1)
        }
    }
}

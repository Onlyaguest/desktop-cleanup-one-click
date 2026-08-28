using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Yuanzi.DesktopCleanup;

internal enum FileCategory
{
    Image,
    Document,
    Table
}

internal sealed class Metrics
{
    public int Total { get; set; }
    public int Moved { get; set; }
    public int Copied { get; set; }
    public int Images { get; set; }
    public int Documents { get; set; }
    public int Tables { get; set; }
    public int Other { get; set; }
    public int Failed { get; set; }
    public double ElapsedSeconds { get; set; }
}

internal sealed class Options
{
    public string? DesktopOverride { get; set; }
    public bool Headless { get; set; }
    public bool DryRun { get; set; }
}

internal static partial class Program
{
    private const string AppTitle = "一键整理桌面文件";
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
        { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".webp", ".heic" };
    private static readonly HashSet<string> TableExtensions = new(StringComparer.OrdinalIgnoreCase)
        { ".xlsx", ".xls", ".csv" };

    [GeneratedRegex(@"^\d{4}\.\d{2}\.\d{2} .+")]
    private static partial Regex DatePrefixRegex();

    [STAThread]
    private static int Main(string[] args)
    {
        var options = ParseOptions(args);
        using var mutex = new Mutex(true, @"Local\Yuanzi.DesktopCleanup.OneClick", out var createdNew);
        if (!createdNew)
        {
            if (!options.Headless)
                MessageBox.Show("整理任务已经在运行，请稍候。", AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 2;
        }

        try
        {
            var desktop = DesktopPath(options);
            var (metrics, errors) = RunCleanup(desktop, options.DryRun);
            WriteLog(desktop, metrics, errors, options.DryRun);

            if (options.Headless)
            {
                var json = JsonSerializer.Serialize(metrics, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "yuanzi-desktop-cleanup-last-run.json"), json);
            }
            else
            {
                ShowResult(metrics, errors, options.DryRun);
            }
            return errors.Count == 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            WriteFatalLog(ex);
            if (!options.Headless)
                MessageBox.Show($"无法读取或整理桌面：{ex.Message}", AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    private static Options ParseOptions(string[] args)
    {
        var options = new Options();
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--desktop" when i + 1 < args.Length:
                    options.DesktopOverride = args[++i];
                    break;
                case "--headless":
                    options.Headless = true;
                    break;
                case "--dry-run":
                    options.DryRun = true;
                    break;
            }
        }
        return options;
    }

    private static string DesktopPath(Options options)
    {
        var path = options.DesktopOverride ?? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            throw new DirectoryNotFoundException("没有找到当前用户的桌面目录。");
        return Path.GetFullPath(path);
    }

    private static (Metrics, List<string>) RunCleanup(string desktop, bool dryRun)
    {
        var stopwatch = Stopwatch.StartNew();
        var metrics = new Metrics();
        var errors = new List<string>();
        var executable = Environment.ProcessPath is null ? null : Path.GetFullPath(Environment.ProcessPath);

        var files = Directory.EnumerateFiles(desktop, "*", SearchOption.TopDirectoryOnly)
            .Where(path => IsCandidate(path, executable))
            .OrderBy(Path.GetFileName, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        metrics.Total = files.Count;

        foreach (var file in files)
        {
            var filename = Path.GetFileName(file);
            var originalName = OriginalName(filename);
            var category = CategoryFor(originalName);

            if (dryRun)
            {
                IncrementCategory(metrics, category);
                continue;
            }

            try
            {
                var date = SourceDate(file, filename);
                var datedName = DatePrefixRegex().IsMatch(filename) ? filename : $"{date:yyyy.MM.dd} {filename}";
                var weeklyDirectory = Path.Combine(desktop, "归档", "按周归档", WeekFolder(date));
                Directory.CreateDirectory(weeklyDirectory);
                var movedPath = UniqueDestination(weeklyDirectory, datedName);
                File.Move(file, movedPath);
                metrics.Moved++;
                IncrementCategory(metrics, category);

                if (category is not null)
                {
                    var typeDirectory = Path.Combine(desktop, "归档", CategoryFolder(category.Value));
                    Directory.CreateDirectory(typeDirectory);
                    var copyPath = UniqueDestination(typeDirectory, Path.GetFileName(movedPath));
                    File.Copy(movedPath, copyPath, overwrite: false);
                    metrics.Copied++;
                }
            }
            catch (Exception ex)
            {
                metrics.Failed++;
                errors.Add($"{filename}：{ex.Message}");
            }
        }

        stopwatch.Stop();
        metrics.ElapsedSeconds = stopwatch.Elapsed.TotalSeconds;
        return (metrics, errors);
    }

    private static bool IsCandidate(string path, string? executable)
    {
        var filename = Path.GetFileName(path);
        if (filename.StartsWith("~$", StringComparison.Ordinal)) return false;
        if (string.Equals(Path.GetExtension(filename), ".lnk", StringComparison.OrdinalIgnoreCase)) return false;
        if (string.Equals(Path.GetExtension(filename), ".url", StringComparison.OrdinalIgnoreCase)) return false;
        if (executable is not null && string.Equals(Path.GetFullPath(path), executable, StringComparison.OrdinalIgnoreCase)) return false;
        var attributes = File.GetAttributes(path);
        return !attributes.HasFlag(FileAttributes.Hidden) && !attributes.HasFlag(FileAttributes.System);
    }

    private static DateTime SourceDate(string path, string filename)
    {
        if (DatePrefixRegex().IsMatch(filename) &&
            DateTime.TryParseExact(filename[..10], "yyyy.MM.dd", null,
                System.Globalization.DateTimeStyles.None, out var prefixedDate))
            return prefixedDate;

        var creation = File.GetCreationTime(path);
        return creation.Year > 1970 ? creation : File.GetLastWriteTime(path);
    }

    private static string OriginalName(string filename) =>
        DatePrefixRegex().IsMatch(filename) && filename.Length > 11 ? filename[11..] : filename;

    private static string WeekFolder(DateTime date)
    {
        var daysAfterMonday = ((int)date.DayOfWeek + 6) % 7;
        var monday = date.Date.AddDays(-daysAfterMonday);
        var sunday = monday.AddDays(6);
        return $"{monday:yyyy.MM.dd}-{sunday:yyyy.MM.dd}";
    }

    private static FileCategory? CategoryFor(string filename)
    {
        var ext = Path.GetExtension(filename);
        if (ImageExtensions.Contains(ext)) return FileCategory.Image;
        if (string.Equals(ext, ".txt", StringComparison.OrdinalIgnoreCase)) return FileCategory.Document;
        if (TableExtensions.Contains(ext)) return FileCategory.Table;
        return null;
    }

    private static string CategoryFolder(FileCategory category) => category switch
    {
        FileCategory.Image => "图片归档",
        FileCategory.Document => "文档归档",
        FileCategory.Table => "表格归档",
        _ => throw new ArgumentOutOfRangeException(nameof(category))
    };

    private static void IncrementCategory(Metrics metrics, FileCategory? category)
    {
        switch (category)
        {
            case FileCategory.Image: metrics.Images++; break;
            case FileCategory.Document: metrics.Documents++; break;
            case FileCategory.Table: metrics.Tables++; break;
            default: metrics.Other++; break;
        }
    }

    private static string UniqueDestination(string directory, string filename)
    {
        var desired = Path.Combine(directory, filename);
        if (!File.Exists(desired)) return desired;
        var stem = Path.GetFileNameWithoutExtension(filename);
        var ext = Path.GetExtension(filename);
        for (var number = 2; ; number++)
        {
            var candidate = Path.Combine(directory, $"{stem} ({number}){ext}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private static string Summary(Metrics metrics, bool dryRun)
    {
        var action = dryRun ? "预计发现" : "共处理";
        return $"{action} {metrics.Total} 个文件 · 用时 {metrics.ElapsedSeconds:F1} 秒\n\n" +
               $"图片 {metrics.Images}　文档 {metrics.Documents}　表格 {metrics.Tables}　其他 {metrics.Other}\n" +
               $"移动 {metrics.Moved} 个 · 生成分类副本 {metrics.Copied} 份\n" +
               (metrics.Failed > 0 ? $"未完成 {metrics.Failed} 个" : "所有文件处理正常");
    }

    private static void ShowResult(Metrics metrics, List<string> errors, bool dryRun)
    {
        var title = errors.Count == 0 ? (dryRun ? "桌面整理预览" : "整理完成 ✓") : "部分文件没有整理完成";
        var details = errors.Count == 0 ? "" : $"\n\n详情已保存到日志。\n{string.Join("\n", errors.Take(3))}";
        MessageBox.Show(Summary(metrics, dryRun) + details, title,
            MessageBoxButtons.OK, errors.Count == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
    }

    private static string LogPath()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Yuanzi", "一键整理桌面文件");
        Directory.CreateDirectory(directory);
        return Path.Combine(directory, "last-run.log");
    }

    private static void WriteLog(string desktop, Metrics metrics, List<string> errors, bool dryRun)
    {
        var text = $"{DateTime.Now:O}\n桌面：{desktop}\n{Summary(metrics, dryRun)}\n{string.Join("\n", errors)}\n";
        try { File.WriteAllText(LogPath(), text); } catch { }
    }

    private static void WriteFatalLog(Exception exception)
    {
        try { File.WriteAllText(LogPath(), $"{DateTime.Now:O}\n{exception}\n"); } catch { }
    }
}

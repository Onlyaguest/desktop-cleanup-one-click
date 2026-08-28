# 一键整理桌面文件

一个很小的桌面收拾按钮：双击一次，把桌面第一层的普通文件按日期归档，结束后告诉你整理了多少。

支持：

- macOS 12 及以上（Apple 芯片与 Intel 通用）
- Windows 10/11（x64 与 ARM64 分包）
- EasyInput 等支持“打开应用”的硬件按键

## 下载与使用

请到仓库的 [Releases](../../releases/latest) 下载适合自己电脑的压缩包。

### macOS

1. 下载 `一键整理桌面文件-macOS-universal.zip` 并解压。
2. 第一次打开时，右键点击 App，选择“打开”。
3. 如果系统询问桌面访问权限，请允许。
4. 之后直接双击即可；也可以在 EasyInput 中选择“打开应用”，绑定这个 App。

### Windows

绝大多数 Windows 电脑下载 `Windows-x64.zip`；ARM Windows 设备下载 `Windows-arm64.zip`。

1. 解压后得到 `一键整理桌面文件.exe`。
2. 双击直接运行；也可以在 EasyInput 中用“打开应用”绑定这个 exe。
3. 未购买代码签名证书前，Windows 可能出现 SmartScreen 提醒；确认来源是本仓库后，可选择“更多信息 → 仍要运行”。

## 它会做什么

假设桌面上有这些文件：

```text
照片.png
记录.txt
数据.xlsx
临时材料.pdf
```

运行后会得到：

```text
桌面/归档/
├── 按周归档/
│   └── 2026.08.24-2026.08.30/
│       ├── 2026.08.28 照片.png
│       ├── 2026.08.28 记录.txt
│       ├── 2026.08.28 数据.xlsx
│       └── 2026.08.28 临时材料.pdf
├── 图片归档/    # 图片副本
├── 文档归档/    # TXT 副本
└── 表格归档/    # Excel / CSV 副本
```

它的边界很明确：

- 只处理桌面第一层的普通文件。
- 不处理任何文件夹，不删除文件。
- Windows 的快捷方式（`.lnk`、`.url`）不会移动。
- 已经带 `yyyy.MM.dd` 日期前缀的文件不会重复加日期。
- 遇到同名文件不会覆盖，会自动增加 `(2)`、`(3)`。
- 图片、TXT、Excel/CSV 会在类型归档中额外生成副本，所以它不是“节省磁盘空间”工具。
- 自动识别当前使用者的桌面，不写死用户名，也支持 Windows 的桌面重定向。

## 完成弹窗与日志

每次完成后都会出现一个可以直接关闭的小弹窗，包括：

- 文件总数
- 图片、文档、表格、其他的数量
- 移动数、分类副本数
- 失败数与耗时

日志位置：

- macOS：`~/Library/Logs/一键整理桌面文件/last-run.log`
- Windows：`%LOCALAPPDATA%\Yuanzi\一键整理桌面文件\last-run.log`

## 开发与安全测试

两个版本都支持用临时目录做无界面测试：

```bash
# macOS
一键整理桌面文件.app/Contents/MacOS/DesktopCleanup --desktop /path/to/test --headless
```

```powershell
# Windows
一键整理桌面文件.exe --desktop C:\path\to\test --headless
```

加上 `--dry-run` 只统计，不移动文件。

构建 macOS 通用包：

```bash
./scripts/build-macos.sh
```

构建 Windows x64 包：

```powershell
dotnet publish windows/DesktopCleanup/DesktopCleanup.csproj -c Release -r win-x64 --self-contained true
```

每次创建 `v*` 标签时，GitHub Actions 会分别在 macOS 与 Windows 环境构建、做临时目录实测，并把三个压缩包放进 Release。

## 来历

这个小工具来自元子对 EasyInput 的一次真实改造：硬件不一定非要拥有复杂能力，它也可以只是一个让人愿意开始工作的入口。把一个空按键绑定为“打开应用”以后，按一下，桌面被收好，电脑再用一张小弹窗告诉我结果。

项目保留了原始工具最重要的克制：不碰文件夹、不删除文件、先把一次小动作做成闭环。

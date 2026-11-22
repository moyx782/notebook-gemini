# SyncCanvas Notebook · 三端共用同一画板的跨平台笔记本

一套基于 **Flutter 跨平台客户端 + HLC-CRDT 同步引擎 + 自托管 WebSocket/HTTP 服务** 构建的多页手写与白板笔记本系统，支持 **电脑桌面端（macOS / Windows / Linux / 浏览器）**、**平板端（iPad Apple Pencil / Android 平板）** 与 **手机端（iOS / Android / 移动 Web PWA）** 实时共用同一个画板。

---

## 核心特性

- **三端同屏实时画板（HLC-CRDT 无冲突合并）**
  - 所有笔记本、画板页、压感笔迹、荧光笔、几何图形、Markdown 卡片、便签与图片卡片均基于字段级 LWW-CRDT（`packages/notebook_core`）同步。
  - **实时流式协同**：书写时实时流式同步远端笔迹轨迹、协作光标与渐隐霓虹激光笔；断网离线编辑自动入队并持久化至本地缓存，重连后秒级收敛不丢失任何内容。
  - **单用户独立撤销 / 重做**：`Ctrl/Cmd+Z` 只撤销本机自己的操作，不会误回滚其他设备上协作者的新笔迹。
- **专业手写笔记增强与全平台 PDF 讲义导入**
  - **多页 PDF 讲义单页连续渲染与锁底批注**：支持在 Windows、macOS、Linux、Android 与离线 Web/PWA 端直接选择本地多页 PDF，按顺序从上到下**单页纵向连续排布**渲染在同一画板页上，自动锁定为防误擦/防误拖底图（`locked: true`），支持单人或多人同屏圈点手写批注。
  - **MindFlow 空间概念导图 × AI MCP 无缝同画布融合**：
    - **同画布无界共存**：在同一张无限画板上与 PDF 讲义底图、手写压感笔迹自由混排 **6 语义色概念词块（`N` / 鼠标双击空白画布）**、**三次贝塞尔有向因果连线（`C` / 右侧锚点拖拽连接或拖至空白自动衍生 / `Tab` 秒建分支）** 与 **虚线空间群组（`B` / `Cmd+G` 一键编组，拖动标题栏联动所有成员）**。
    - **智能拓扑排版与级联防护**：支持避开锁定 PDF 底图的自动分层拓扑排布（`整理拓扑布局`）、横纵等距对齐，以及删除节点时自动级联清理关联连线并支持 `Cmd/Ctrl+Z` 一步完整撤销。
    - **AI Skill 读写、SVG 导出与内置 MindFlow MCP Server**：支持一键复制完整 **AI 技能说明书 + 当前画板语义上下文**，直接导入导出标准 `mindflow` v1 JSON 与高清矢量 `.svg`；同时内置符合 Streamable HTTP JSON-RPC 2.0 规范的 **MindFlow MCP Server**（`/api/rooms/<roomId>/mindflow/mcp` + `server/bin/mindflow_mcp.dart` + 零依赖 `scripts/mindflow_mcp_bridge.mjs` stdio 桥），默认 `--read-only` 防误改、`expectedRevision` 乐观并发锁、20 版本自动滚动备份恢复与 WebSocket 多端实时落盘广播。
  - **自由套索多选（`G`）与组合撤销**：自由圈选多笔手写字迹、公式、图形与便签，支持整体拖拽平移、一键批量改色、复制（`Cmd/Ctrl+D`）、删除，且单步 `Cmd/Ctrl+Z` 即可原子回滚整组操作。
  - **笔尾停顿自动拉直（Hold-to-Snap）+ 3 档常用笔预设槽**：手写划线在笔尾停顿约 `0.38s` 即自动拉直为标准直线并支持继续拖动瞄准端点；底部工具栏内置 3 个常用笔/荧光笔预设槽（单击秒切、长按保存当前笔触）。
- **多页笔记本、全文检索与多格式导出**
  - 支持多笔记本与多页树状管理、**跨本全文搜索一键定位跳转**、**页面星标收藏（`⭐` 仅看星标）**、页面复制与上下排序、顶栏 `< 2/5 >` 快速翻页。
  - 纸张底纹涵盖空白 / 方格 / 点阵 / 横线 / **康奈尔笔记** / **错题本** / **日程待办**，支持 **羊皮黄 / 护眼绿 / 深色黑板** 纸色与可开关的 **A4 分页参考界**。
  - 支持 **导出当前页 2x 高清图片（`.png`，含 PDF 底图与手写批注合成）**、**导出整本笔记结构化摘要（`.md`）** 与完整 `.nbk.json` 房间快照备份。
  - **可交互 Markdown 卡片**：支持标题、加粗、行内代码、引用与 **可点击实时同步的 `- [ ]` / `- [x]` 待办复选框**。
- **无路由器自组网（随身房主 + BLE 蓝牙引导热点 + UDP 自动发现）**
  - **随身房主模式**：任意原生端（Android / macOS / Windows / Linux / iPad）均可在「三端连接」中一键开启「本机当房主」，内置启动同步服务端并推送本地画板快照，无需电脑或命令行。
  - **先蓝牙发现，再切热点高速同步**：房主端通过低功耗蓝牙（BLE GATT）广播房间信息与热点凭证（Android 端支持一键拉起本地直连热点或分享个人热点凭证）；附近 Android 端可在雷达中点击「秒连加入」自动接入热点并绑定网络通道，iPad/Mac 端通过 CoreBluetooth 发现后展示一键复制热点名密码弹窗并自动续连。
  - **零配置 UDP 雷达**：处于同一 Wi-Fi 或同一手机个人热点下时，无需任何蓝牙/定位权限即可通过 UDP `48788` 端口自动发现附近共享画板。
- **三端自适应交互体验**
  - **桌面端（>= 1024px）**：可折叠目录侧栏 + 顶部协作栏 + 可自由拖动贴靠四边的专业工具栏（竖排时撤销与重做固定置顶） + 鼠标滚轮/触控板双指缩放 + 完整键盘快捷键。
  - **平板端（600–1023px）**：全屏画布 + 抽屉目录 + Apple Pencil 硬件压感与橡皮擦端自动识别 + **「笔防误触」模式**（单指平移、双指捏合缩放、触控笔专职书写）+ **可拖动贴边变竖排（撤销/重做置顶）/ 一键收起为悬浮笔球**的工具栏。
  - **手机端（< 600px）**：单手拇指底部工具坞 + 底部弹出笔记本目录 + **「浏览 / 动笔」一键切换**，避免单指浏览时误画。

---

## 一键启动（服务端 + 局域网 Web/PWA）

确保三台设备连接同一局域网 Wi-Fi，在项目根目录执行：

```bash
chmod +x start.sh
./start.sh
```

服务启动后会在终端输出本机及局域网地址（默认端口 `8787`），例如：

- 电脑浏览器：`http://127.0.0.1:8787`
- iPad / 手机扫码或浏览器访问：`http://<你的局域网IP>:8787`

点击应用右上角 **「三端连接」**，即可直接弹出 **局域网二维码**、多网卡 IP 切换、房间号（`room`）切换及 `.nbk.json` 完整导入导出工具。

---

## 原生三端运行指南

### 1. macOS 原生桌面端

```bash
flutter run -d macos
```

### 2. iPad / iPhone 原生端

```bash
flutter run -d <你的iPad或iPhone设备ID>
```

然后在「三端连接」中输入电脑端显示的 `ws://<局域网IP>:8787/ws`（或直接用 Safari / Chrome 扫码打开 `http://<局域网IP>:8787` 并「添加到主屏幕」作为 PWA 使用）。

### 3. Android 平板 / 手机原生端

1. **打包安装包（APK）**：
   ```bash
   flutter build apk --release
   # 产物路径：build/app/outputs/flutter-apk/app-release.apk
   ```
2. **局域网扫码下载 APK**：执行 `./start.sh` 后，在电脑端「三端连接」弹窗切换到 **「扫码下载 Android APK」**，Android 设备用浏览器扫码即可下载 `http://<电脑局域网IP>:8787/download/android.apk` 并安装。
3. **内置原生功能**：
   - **摄像头扫码秒连**：点击顶栏扫码图标或「三端连接 → 摄像头扫码秒连」，直接扫描电脑/平板上的连接二维码（支持补光灯与相册二维码截图识别）。
   - **系统相册插图**：点击底部工具栏「插入图片 / 图示 → 从系统相册选择图片」，无需存储权限即可选取照片并自动按 EXIF 方向矫正压缩后同步到三端画板。
   - **USB / 无线调试直连**：`flutter run -d <你的Android设备ID>`。

### 4. Linux 桌面端（`.deb` / `.rpm` / `.AppImage`，支持 `x86_64` & `arm64`）

1. **直接安装发行版包**（可从 GitHub Releases 下载对应架构产物）：
   - **Debian / Ubuntu / Deepin / UOS (`.deb`)**：
     ```bash
     sudo apt install ./sync-canvas-notebook_1.2.0_amd64.deb   # arm64 架构将 amd64 替换为 arm64
     ```
   - **Fedora / RHEL / Rocky / Alma / openSUSE (`.rpm`)**：
     ```bash
     sudo dnf install ./sync-canvas-notebook-1.2.0-1.x86_64.rpm   # arm64 将 x86_64 替换为 aarch64
     ```
   - **通用便携版 (`.AppImage`)**：
     ```bash
     chmod +x SyncCanvas_Notebook-1.2.0-x86_64.AppImage
     ./SyncCanvas_Notebook-1.2.0-x86_64.AppImage
     ```
2. **在 Linux 本机一键打包三种格式**：
   ```bash
   ./scripts/build_linux_packages.sh
   # 输出位于 dist/linux/
   ```
3. **在 macOS / Windows 上通过 Docker 多架构交叉打包**：
   ```bash
   ./scripts/package_linux_docker.sh all   # 支持 amd64 / arm64 / all
   ```

### 5. Windows 桌面端（`.exe` 安装向导包 / `.zip` 免安装绿色版，支持 `x64` & `arm64`）

1. **下载安装包或绿色便携版**（可从 GitHub Releases 下载对应架构产物）：
   - **标准安装向导（推荐，`.exe`）**：运行 `SyncCanvas_Notebook_Setup_1.2.0_windows_x64.exe`（Windows ARM 设备请选择 `windows_arm64`），支持免管理员按用户安装并自动创建桌面与开始菜单快捷方式。
   - **免安装绿色便携版（`.zip`）**：解压 `SyncCanvas_Notebook-1.2.0-windows-x64-portable.zip` 后直接双击 `sync_canvas_notebook.exe` 运行（已随包附带 MSVC C++ 运行时 DLL）。
2. **在 Windows 本机一键打包双格式**：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_packages.ps1
   # 输出位于 dist\windows\（包含 .exe 安装包、.zip 绿色版与 SHA256SUMS）
   ```
3. **源码直连运行（Windows 10/11 + Visual Studio C++ 工具链）**：
   ```powershell
   flutter config --enable-windows-desktop
   flutter run -d windows
   ```

---

## 桌面端快捷键

| 快捷键 | 功能 |
| :--- | :--- |
| `V` | 选择 / 移动 / 点击 Markdown 复选框 / 解锁底图 |
| `G` | 自由套索多选（圈选后可整体平移 / 改色 / 复制 / 删除） |
| `P` | 压感钢笔（笔尾停顿 0.38s 自动拉直直线） |
| `H` | 荧光笔（笔尾停顿自动拉直划重点） |
| `E` | 橡皮擦（自动保护已锁定的 PDF 讲义底图） |
| `R` / `O` / `D` / `A` | 矩形 / 圆形 / 菱形 / 箭头 |
| `N` / `C` / `B` | MindFlow 概念词块 / 因果连线 / 区域分组 |
| `Tab` | 选中或编辑概念词块时快速向右派生新分支词块并自动连线 |
| `Cmd/Ctrl + G` | 将选中元素一键编组为 MindFlow 空间群组（Cluster） |
| `T` / `S` | 插入 Markdown 卡片 / 便签 |
| `L` | 协作激光笔 |
| `[` / `]` 或 `PageUp` / `PageDown` | 快速切换上一页 / 下一页 |
| 按住 `Space` + 拖拽 / 滚轮 | 抓手平移 / 缩放画布 |
| `Cmd/Ctrl + D` | 复制当前选中或套索框选的元素 |
| `Cmd/Ctrl + Z` / `Shift+Z` | 撤销 / 重做（支持套索与导入单步原子回滚） |
| `Delete` / `Backspace` | 删除选中元素 |

---

## 仓库目录结构

```text
├── packages/notebook_core/   # 纯 Dart 共享 HLC-CRDT 引擎、MindFlow 导图编解码器与同步协议
├── server/                   # 自托管 WebSocket 同步服务、内置 MindFlow MCP Server 与 20 版本滚动备份
├── skills/                   # 内置 AI 白板交互技能指南 (skills/mindflow-whiteboard/SKILL.md)
├── lib/
│   ├── platform/             # Web (dart:js_interop) 与 Native IO 条件平台适配层
│   ├── state/                # NotebookController 状态管理、离线队列与实时同步
│   ├── canvas/               # 压感几何引擎、7 层同画布渲染器 (PDF + MindFlow + Ink) 与交互层
│   └── ui/                   # 三端自适应壳层、可拖可竖排工具栏、MindFlow AI/MCP 中心与扫码弹窗
├── test/                     # 三端自适应界面与同步测试
├── windows/                  # Windows 桌面端 Win32/C++ 原生工程壳层
├── packaging/
│   ├── linux/                # Linux .desktop / SVG 图标与多架构 Dockerfile
│   └── windows/              # Windows Inno Setup (.exe) 安装包脚本配置
├── scripts/                  # Linux/Windows 打包脚本与零依赖 MindFlow MCP stdio 桥 (mindflow_mcp_bridge.mjs)
├── .github/workflows/        # GitHub Actions Linux 与 Windows 双架构自动构建发布流
└── start.sh                  # 一键构建与启动脚本
```

---

## 验证与测试命令

```bash
# 1. CRDT 核心库静态检查与单测
dart analyze packages/notebook_core
dart test packages/notebook_core

# 2. 同步服务端静态检查与三端并发 E2E 测试（含断网重连与重启持久化）
dart analyze server
dart test server

# 3. Flutter 客户端静态检查与跨端 UI/同步测试
flutter analyze
flutter test
```

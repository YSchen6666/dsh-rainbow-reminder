# 🌈 dsh-rainbow-reminder

**DeepSeek Harness · Windows 桌面提醒插件**

> 等待 · 错误 · 完成 —— 三色一屏，简洁科技。

```
任务等待你   →  琥珀光带  呼吸闪烁
任务出错了   →  红色光带  呼吸闪烁
任务完成了   →  绿色光带  呼吸闪烁
```

在 [DeepSeek Harness](https://www.deepseek.com/)（DSH）里跑任务时，不用一直盯着窗口：会话需要你处理的那一刻，屏幕顶部会亮起一条**发丝光带**，屏幕四周同步点亮**极光能量场**——颜色即状态，一眼就知道该不该回到电脑前。

---

## ✨ 三个状态，三种颜色

| 状态 | 信号 | 颜色 | 何时出现 |
|---|---|---|---|
| 🟠 **等待** | approval / question / waiting | 琥珀 `#FFB454` | 等待授权、等待回答、等待处理 |
| 🔴 **错误** | error / blocked | 红 `#FF6B6B` | 任务出错、任务无法继续 |
| 🟢 **完成** | done | 绿 `#35D07F` | 全部任务完成 |

- **单色锁定**：色相不漂移，琥珀就是琥珀，红就是红，绿就是绿；
- **呼吸感**：明暗深浅起伏，静默时完全不打扰；
- **科技感**：屏幕四周极光流光扫动、白热核心、四角节点，颜色跟随当前状态。

## 🚀 特性

- **为 DSH 而生**：监听 DSH 会话事件，只在真正需要你时提醒，其余时间静默；
- **双通道显示**：DSH 页面内色带 + 独立桌面助手进程（DSH 在后台也提醒）；
- **自动守护**：插件加载自动拉起助手，进程掉了自动重启；
- **效果设置窗口**：颜色 / 透明度 / 能量场 / 调试工具，点色块即换色，即时生效；
- **看过就收**：切回 DSH 窗口看过之后自动收提醒。

## 📦 安装（新手照做即可）

**前置条件（缺一不可）：**

1. Windows 10 / 11；
2. 已安装并登录 [DeepSeek Harness 桌面版](https://www.deepseek.com/)（0.2.2-rc.1 或更高）；
3. PowerShell 5.1（Windows 自带，无需另装）；
4. 系统装有 `node`（Node.js 18+，并在 PATH 里）。

**安装步骤：**

1. 把本仓库下载或 `git clone` 到一个**路径里没有中文和空格**的目录，例如 `D:\tools\dsh-rainbow-reminder`；
2. 打开 DSH → 插件管理器 → 选择"加载本地插件 / 本地目录"，指向第 1 步的目录；
   （如果你的 DSH 版本没有本地目录入口：把该目录路径以 `"@local/dsh-rainbow-reminder": "link:<目录路径>"` 的形式加入 DSH profile 的 `package.json` 的 bundles 里，然后重启 DSH。）
3. 重启 DSH 或在插件管理器里重载本插件。看到"桌面助手自动启动"、屏幕顶部出现光带即安装成功；
4. （可选）想让 DSH 完全关闭、最小化时也能提醒：在 PowerShell 里执行
   `powershell -ExecutionPolicy Bypass -File <插件目录>\desktop\autostart.ps1`，这会写入当前用户的开机自启（不需要管理员，可随时用 `-Remove` 关闭）。

**第一次测试：** 托盘图标（彩虹色小图标）右键 → "测试：依次演示 3 种颜色"。如果一闪就没，是"看过就收"在起作用——设置窗口里先关掉它再测。

## 🗑️ 卸载（三步，干净移除）

1. 在 PowerShell 里执行 `powershell -ExecutionPolicy Bypass -File <插件目录>\desktop\autostart.ps1 -Remove`（关闭开机自启；没开过自启可跳过）；
2. 执行 `powershell -ExecutionPolicy Bypass -File <插件目录>\desktop\stop.ps1` 停止桌面助手，然后在 DSH 插件管理器里停用并移除本插件；
3. 想清掉运行数据的话，删除文件夹 `%LOCALAPPDATA%\dsh-rainbow-reminder`（信号流与日志都在这里），再删除插件目录本身。

## 🎛️ 使用

托盘图标右键 → **效果设置窗口…**，可调：

- **通用**：显示器、看过就收、提示音、外观档
- **效果颜色**：等待 / 错误 / 完成 三类，点色块换色
- **色带**：全局透明度
- **边缘能量场**：启用 / 发光浓淡 / 闪烁节奏
- **调试工具**：测试三类、清除提示、演示、恢复默认

> 测试时若 DSH 窗口在前台，提示可能被「看过就收」自动清除，先关掉该开关再测试。

## ⚙️ 配置与数据

- 主配置 `desktop/config.json`，改动约 1 秒热加载；
- 信号流 `%LOCALAPPDATA%\dsh-rainbow-reminder\signal.jsonl`；
- 助手日志 `%LOCALAPPDATA%\dsh-rainbow-reminder\assistant.log`；
- 编辑过 `desktop/*.ps1` 或 `config.json` 后如果中文显示异常/助手起不来，先跑一次 `desktop\fix-bom.ps1`（修复 UTF-8 BOM）再重启助手。

## 📁 目录结构

```
├── index.js               # Host 半边：监听 DSH 会话事件 → signal.jsonl
├── client.js              # DSH 页面内色带
├── trust.js               # HTTP 路由信任围栏（回环 + 同源校验）
├── desktop/
│   ├── reminder.ps1       # 桌面助手：色带 + 极光能量场 + 设置窗口
│   ├── config.json        # 桌面端配置
│   ├── start.ps1          # 启动器（脱离 DSH Job Object）
│   ├── stop.ps1           # 停止助手
│   ├── autostart.ps1      # 开机自启辅助（-Remove / -Status）
│   ├── fix-bom.ps1        # BOM 修复辅助
│   └── assets/            # 贴图素材（可选装饰，默认关闭；仓库不含第三方衍生图）
├── locale/                # 中英文字典
├── icon.svg               # 插件图标
└── package.json           # 插件清单
```

## ❓ 常见问题

- **DSH 在后台能提醒吗？** 能，桌面助手是独立进程。
- **测试按钮一闪就没了？** 是「看过就收」生效，关掉该开关再测试。
- **改颜色重启会丢吗？** 不会，改动即时写回 config.json。
- **桌面光带一直不出现？** 按顺序查：① 看托盘有没有图标（没有 → 手动跑 `desktop\start.ps1` 看报错）；② 看日志 `%LOCALAPPDATA%\dsh-rainbow-reminder\assistant.log` 最后几行；③ 中文乱码导致起不来 → 先跑 `desktop\fix-bom.ps1`。
- **DSH 升级后插件失效？** 见下方免责声明，等本仓库跟进适配或回退 DSH 版本。

## ⚠️ 免责声明

- 本项目为**社区第三方插件**，非官方产品，与 DeepSeek 无任何隶属或认可关系；
- 插件依赖 DSH 当前版本**未公开承诺稳定的内部接口**（页面注入点、事件名、webServer 路由等），DeepSeek 升级 DSH 后随时可能失效，届时需要本仓库跟进适配；
- 本软件按 [MIT](./LICENSE) 提供，不附带任何担保；使用产生的任何问题由使用者自行承担。

## 📄 License

[MIT](./LICENSE)

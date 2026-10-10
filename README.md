<p align="center">
  <img src="Assets/BrandIcon.png" width="112" alt="SynorTool 图标" />
</p>

<h1 align="center">SynorTool</h1>
<p align="center">Synor 旗下的 macOS AI 桌面工具</p>
<p align="center">Codex 英文提示词翻译 · AI 对话 · 本地 Agent 工具</p>

SynorTool 是 Synor 的第一款产品，将 AI 对话、快捷翻译与本地工具调用整合到原生 macOS 菜单栏应用中。连接你自己的本地或远程模型服务，连按两次 Option，即可在当前工作中唤起助手。

项目使用 .NET 10、AppKit 和 React 构建，采用原生 Liquid Glass 窗口。我们选择开源，让使用者能够了解实现、反馈问题，并参与改善产品。

> **当前为早期版本，面向愿意从源码构建的 macOS 用户。** 当前构建路径面向 Apple Silicon 和 macOS 26+，尚未完成 Developer ID 签名与 Apple 公证。
>
> **使用前请了解 Agent 权限：** 聊天默认启用文件读取、写入和 shell 执行工具，以当前 macOS 用户权限自动执行，没有逐次确认或沙箱。工作目录仅用于解析相对路径，不限制访问范围。工具读取的内容可能随对话发送至你配置的模型服务，请仅在理解这些权限与数据流向后使用。

## 在 Codex 中，用中文输入，用英文发送

在 Codex 输入框中写好中文需求并选中，连按两次 **Option（⌥）**，SynorTool 会在后台自动翻译成英文，并尝试将译文替换回原选区，无需切换窗口或手动复制粘贴。检查译文后，再自行发送给 Codex。

如果你感觉 Codex 对中文提示词的理解或执行效果不稳定，可以用这个功能尝试英文表达、对比结果；翻译不保证改善模型表现。

1. 启动 SynorTool，配置可用的模型服务，并授予 macOS 辅助功能权限。
2. 在 Codex 的可编辑输入框中选中需要翻译的中文。
3. 连按两次 Option。**根据当前使用反馈，首次双击不生效，需要再次双击，从第二次双击起才生效。这里的“一次”指完整的两次连按，不是单次按键。**
4. 等待英文译文回填，检查后自行发送。翻译期间不要修改输入内容，否则会放弃回填。

此流程适用于 Codex 的可编辑输入框；选中 AI 回复正文等静态文本时，仍使用独立翻译面板。

## 主要功能

- **Codex 英文提示词翻译**：选中输入框中的中文，双击 Option，在后台翻译成英文并就地回填；首次双击不生效时，请再次双击。
- **随时唤起**：常驻菜单栏，连按两次左或右 Option 显示窗口；Esc 隐藏，隐藏后保留当前对话。
- **流式 AI 对话**：支持多轮上下文、停止生成、Markdown 与数学公式渲染、复制回答和剪贴板图片输入。图片理解需要模型支持视觉。
- **快捷翻译**：选中文字后连按两次 Option，将选区带入独立翻译窗口；支持目标语言选择、流式输出、停止和复制。翻译不启用 Agent 工具。
- **Apple 本地翻译（可选）**：在配置的“上下文与生成”中把翻译引擎切换为 Apple 本地翻译后，快捷翻译和 Codex 输入框翻译都通过 macOS Translation 在本机完成，不调用模型服务；首次使用按系统提示下载语言包，macOS 26.4+ 使用低延迟策略。本地翻译失败时自动改用当前模型服务。
- **本地 Agent**：提供 `read`、`grep`、`find`、`ls`、`write`、`edit`、`bash` 和 `web_fetch`，可查看工具调用的参数、状态与输出。
- **自选模型服务**：连接支持 OpenAI Responses API 的服务，配置基础地址、模型、API Key、附加提示词和思考控制，并从服务端获取模型列表。
- **用量信息**：显示首 Token 耗时、输出速度、上下文与累计 Token 用量；服务端返回缓存数据时显示缓存率。用量以服务端返回值为准。

## 从源码运行

### 环境要求

- Apple Silicon Mac，macOS 26 或更高版本。
- Xcode 及 macOS 26 SDK，确保 `xcrun clang` 与 `xcrun swiftc` 可用。
- .NET SDK **10.0.400**（允许更新的同系列补丁版本，见 `global.json`）。
- Node.js 与 npm，用于安装、检查和构建前端。
- 一个支持 **OpenAI Responses API** 的本地或远程模型服务。

```sh
git clone https://github.com/gtjaorg/SynorTool.git
cd SynorTool
npm --prefix Web ci
dotnet run
```

构建会检查 TypeScript、打包前端并编译原生桥接库。前端以本地单文件加载，无需启动开发服务器。仓库附带的 ripgrep / fd 为 Apple Silicon 二进制。

### 配置模型

点击输入框底部“配置”，或菜单栏右键菜单中的“AI 配置…”，填写：

| 配置项 | 说明 |
| --- | --- |
| API 基础地址 | 包含版本路径，例如 `http://127.0.0.1:1234/v1`；不要填写 `/responses` 等具体接口路径 |
| 模型 | 填写服务实际提供的模型标识，或通过“获取列表”从 `/models` 选择 |
| API Key | 按服务要求填写；本地无认证服务可留空 |
| 思考控制 | 服务不接受思考参数时，关闭“发送思考控制参数” |
| 工作目录 | Agent 解析相对路径的起点，不构成权限隔离 |

默认地址指向本机 LM Studio 服务，默认模型标识为 `google/gemma-4-e4b`；请根据实际加载的模型调整。远程服务要求 HTTPS，本机可使用 HTTP。仅支持 Chat Completions 的服务无法直接使用，所选服务与模型也需要支持你要使用的图片、工具调用等能力。

保存配置对下一次请求生效。聊天和翻译可以同时生成，停止操作相互独立。

## 使用方式

| 操作 | 效果 |
| --- | --- |
| 连按两次左或右 Option | 唤起窗口；能读取选区时进入翻译流程 |
| Enter / Shift + Enter | 发送消息 / 换行 |
| 粘贴图片 | 添加图片附件，可移除，也可仅发送图片 |
| Esc | 隐藏当前窗口 |
| 清理按钮 / ⌘L | 清空聊天上下文并取消正在进行的请求 |
| 菜单栏图标左键 / 右键 | 显示窗口 / 打开菜单 |

全局快捷键与选区读取需要在“系统设置 → 隐私与安全性 → 辅助功能”中授权。授权后点击菜单栏图标使权限生效。无法读取选区的应用可手动粘贴文字。

选区读取优先使用辅助功能接口；必要时会模拟 ⌘C，并备份、恢复剪贴板。对于 Chromium / Electron 应用，可能启用其辅助功能树，带来额外开销或屏幕阅读器模式变化。

在 Codex 的可编辑输入框内选中文字时，快捷翻译会自动翻译成英文并尝试替换回原选区。首次双击 Option 不生效时，请保持选区并再次双击；翻译期间输入内容发生变化时会放弃回填。静态文本选区仍使用翻译面板。

## 数据与权限

- 配置与 API Key 存储在 `~/Library/Application Support/Synor/settings.json`，文件权限限制为当前用户读写。**API Key 保存在 JSON 中，并非钥匙串加密存储**；不要上传该文件。
- 对话、图片及工具结果会按请求发送到你配置的模型服务。接入远程服务时，应自行了解该服务的数据处理方式。
- 退出应用后聊天记录清空；累计 Token 用量保存在配置文件中。窗口位置和大小保存在 `~/Library/Preferences/com.synor.tool.plist`。
- `bash` 完整输出可能写入系统临时目录，路径会返回给模型；工具结果在界面和上下文中可能被截断。
- 网页前端通过原生桥请求后端，不直接发起任意网络请求；这不限制后端 Agent 的系统权限。

## Agent 工具

| 工具 | 能力 |
| --- | --- |
| `read` | 读取文本和图片，支持文本分页 |
| `grep` / `find` / `ls` | 搜索内容、查找文件、列出目录，搜索使用随附的 ripgrep / fd |
| `write` / `edit` | 写入文件、替换文本；替换会检查匹配唯一性与重叠 |
| `bash` | 执行 `/bin/bash -c`，支持超时、输出和取消进程树；调用之间不保留 shell 状态 |
| `web_fetch` | 获取 HTTP(S) 页面、纯文本或 JSON，将网页正文转换为简洁 Markdown |

`web_fetch` 不执行 JavaScript、不使用浏览器登录态、不解析 PDF 或图片。网页内容属于不可信外部数据。Agent 工具调用可持续执行，直到任务完成或用户停止。

工具行为与提示词参考 Pi Coding Agent，相关来源和许可见 [ThirdParty](ThirdParty/README.md)。当前实现不包含 Pi 的技能、扩展或会话持久化。

## 开发与验证

```sh
# 构建前端、.NET 应用及原生桥接
dotnet build

# 工具行为测试
dotnet run --project Tests/ToolTests.csproj

# 使用本地模拟服务验证流式请求与工具循环
python3 Tests/stream_test.py
```

测试使用临时目录；流式测试通过 `SYNOR_SETTINGS_DIR` 隔离配置，不调用真实模型，也不读写日常使用的应用配置。

| 目录或文件 | 内容 |
| --- | --- |
| `NativePanel.m`、`SynorMarkdown.*` | 原生窗口、系统交互与选区 Markdown 转换 |
| `ChatClient.cs`、`PiAi/` | 对话流程与 OpenAI Responses 适配 |
| `AgentTools.cs`、`WebFetch.cs` | 本地工具与网页读取 |
| `Web/` | React 聊天、翻译及配置界面 |
| `Tests/` | 工具行为与流式集成测试 |
| `ThirdParty/`、`Tools/` | 第三方声明、许可证与随附工具 |

### SDK 选择问题

若本机同时安装多个 SDK，遇到 `unknown architecture: arm64e.x1` 或 `tapi error: malformed file`，请检查编译器与默认 SDK 是否匹配。本次验证使用 macOS 26.5 SDK；若本机存在下列路径，可为命令显式指定：

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk dotnet build
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk python3 Tests/stream_test.py
```

### 本机打包脚本

`scripts/package-macos.sh` 是维护者的本机开发打包脚本，依赖固定的本地签名证书与登录钥匙串，**不能在其他机器上直接作为通用安装脚本使用**。它会安装到 `/Applications/Synor.app`，并创建 `dist/Synor.app` 符号链接。

社区开发请优先使用上述源码运行方式。现有脚本产物包含 .NET 运行时，但尚未完成 Developer ID 签名与 Apple 公证。

### 已知限制

- 当前仅提供 macOS 实现；附带工具与打包脚本面向 Apple Silicon。
- 使用 KVC 调整 WKWebView 的 `drawsBackground`，该属性不是公开 API，系统升级时需要验证兼容性。
- 选区读取和回填取决于目标应用的辅助功能支持，并非所有应用都可用。
- 工具执行没有逐次确认或沙箱；当前版本不适合需要严格权限隔离的场景。
- 图片、思考输出、缓存与 Token 用量等能力取决于模型服务支持。

## 反馈与贡献

欢迎在 [Issues](https://github.com/gtjaorg/SynorTool/issues) 提交问题与建议，或通过 Pull Request 贡献改进。

报告问题时，请提供 macOS 版本、芯片类型、复现步骤，以及已去除敏感信息的错误输出。模型相关问题请注明服务类型与模型标识；不要提交 API Key、完整配置文件或私人对话。

修改代码前请阅读 [AGENTS.md](AGENTS.md)，提交与问题直接相关的修改，并运行相应构建或测试。较大的功能调整建议先通过 Issue 讨论范围。

## 许可证

SynorTool 项目代码采用 [MIT License](LICENSE)。随附的第三方代码、工具和依赖遵循各自许可证，已有声明见 [ThirdParty](ThirdParty/README.md)。

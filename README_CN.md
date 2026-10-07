# AppleTrace 🍎

[Discord](https://discord.gg/eGzEaP6TzR)

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/AppleTrace?style=flat-square&color=4ECDC4)](https://github.com/everettjf/AppleTrace/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/everettjf/AppleTrace?style=flat-square&color=4ECDC4)](https://github.com/everettjf/AppleTrace/network)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/everettjf/AppleTrace?style=flat-square)](https://github.com/everettjf/AppleTrace/commits/master)
[![Contributors](https://img.shields.io/github/contributors/everettjf/AppleTrace?style=flat-square)](https://github.com/everettjf/AppleTrace/graphs/contributors)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square&logo=apple)](https://github.com/everettjf/AppleTrace)

**轻量、可内嵌的 Objective-C 追踪器，产物可直接拖入 [Perfetto](https://ui.perfetto.dev) 分享**

📖 **[阅读完整教程与使用指南 →](https://everettjf.github.io/AppleTrace/zh.html)**

[English](README.md) | [中文](README_CN.md)

</div>

> 🚀 **按需维护。** AppleTrace 捕获 App 的执行时间线——手动 section 和/或每一次
> `objc_msgSend`——并在浏览器里用 Perfetto 直接呈现。随着 AI 时代的到来，可做的事情
> 更多了，后续会根据实际需要继续维护和改进。

![AppleTrace Demo](https://everettjf.github.io/stuff/appletrace/appletrace.gif)

---

## 目录

- [AppleTrace 是什么？](#-appletrace-是什么)
- [核心特性](#-核心特性)
- [快速开始](#-快速开始)
- [工作原理](#-工作原理)
- [安装](#-安装)
- [使用](#-使用)
- [处理与可视化 trace](#-处理与可视化-trace)
- [平台与 hook 支持](#-平台与-hook-支持)
- [测试](#-测试)
- [项目结构](#-项目结构)
- [FAQ](#-faq)
- [贡献](#-贡献)
- [许可证](#-许可证)

---

## 🎯 AppleTrace 是什么？

AppleTrace 是一个面向 iOS/macOS 的追踪工具。你给 App 埋点——既可以加手动的
`APTBeginSection` / `APTEndSection` 标记，也可以自动 hook 每一次 `objc_msgSend`——
AppleTrace 会把事件时间线写入沙盒里的 trace 片段。一个小巧的 Python 流水线把这些
片段合并成单个 `trace.json`，你直接在 [Perfetto](https://ui.perfetto.dev) 中打开，
即可分析调用时间线、耗时、线程与计数器。

![Demo Preview](image/appletrace-small.png)

*trace 可视化展示了方法执行时间线与调用关系。*

---

## ✨ 核心特性

- 📊 **自动方法追踪**：在 arm64 上直接重绑定 `objc_msgSend` / `objc_msgSendSuper2`，
  无需改动源码即可捕获 Objective-C 活动。
- 🎯 **手动 section**：`APTBeginSection` / `APTEndSection`（以及 `APTBegin` /
  `APTEnd` / `APTScopeSection` 辅助宏）精确标记你关心的区间——风险最低，适用于所有
  系统版本。
- 📈 **丰富的事件类型**：瞬时标记（`APTInstant`）、数值曲线（`APTCounter`，用于内存、
  FPS、队列深度等），以及跨线程/队列的异步事件（`APTAsyncBegin` / `APTAsyncEnd`）。
- ⚡ **为热路径而生**：对 `(Class, SEL)` 做名字 interning、每线程零分配调用栈、每线程
  批量写入，把 `malloc` / `snprintf` / dispatch 移出每条消息的路径。可选的二进制片段
  格式（`APPLETRACE_BINARY=1`）则把字符串格式化完全移出热路径。
- 🧵 **线程命名**：Perfetto 显示真实线程名，而非裸 id。
- 🔍 **运行时过滤**：用类名前缀 allow/deny 列表限定自动追踪范围
  （`APPLETRACE_TRACE_CLASS_ALLOW` / `APPLETRACE_TRACE_CLASS_DENY`）。
- 🌐 **Perfetto 优先**：在 [ui.perfetto.dev](https://ui.perfetto.dev) 打开
  `trace.json`，纯网页、无需安装、可承载大 trace。begin/end 默认折叠为 `X` complete
  事件，体积减半。
- 🐍 **Python 3 工具链**：统一 CLI（`scripts/appletrace_cli.py`）、面向大 trace 的
  流式合并、自动化测试与 GitHub Actions CI。

### 适用场景

- 🔍 **性能分析**：在真实时间线上定位热点与耗时方法。
- 🐛 **调试**：跨线程跟踪方法执行流程。
- 📚 **学习**：观察 iOS/macOS 框架实际如何派发消息。
- 🛡️ **安全研究**：分析第三方 App 行为。

---

## ⚡ 快速开始

```bash
# 1. 准备环境（macOS）
brew install python git ldid          # ldid 仅在重签名 loader 构建时需要

# 2. 克隆
git clone https://github.com/everettjf/AppleTrace.git
cd AppleTrace

# 3. 可选：用于合并/测试的 Python 工具链
python3 -m pip install -r requirements.txt
```

### 体验 Demo App（最快看到一条 trace）

`sample/AppleTraceSwiftDemo` 是一个开箱即用的示例。用 Xcode 打开，在模拟器
（或真机）上运行，点击 **Generate Trace** 按钮——它会跑一段精心设计的多线程
工作负载（App 启动 span、并行的 `ImageDecoder` / `NetworkClient` /
`DatabaseWriter` 线程、async 下载弧、带实时 FPS / 内存 counter 的 60 帧渲染
循环）并写出一条完整的 trace。界面随后会显示磁盘上的 trace 目录，以及合并并在
Perfetto 中打开它的完整命令。

```bash
open sample/AppleTraceSwiftDemo/AppleTraceSwiftDemo.xcodeproj   # 运行后点击 "Generate Trace"

# App 会显示 trace 目录；合并它并打开 Perfetto：
python3 merge.py -d "<App 中显示的 trace 目录>"               # → trace.json
# 或一步到位：
sh go.sh "<App 中显示的 trace 目录>"
```

模拟器上该目录就在你的 Mac 本地。真机上需先拉取 App 容器（Xcode ▸ *Window ▸
Devices and Simulators ▸ Download Container*，或 `xcrun devicectl device
copy from …`）——App 内会显示完整命令。

仓库内含两个示例：

| 示例 | 语言 | 演示内容 |
|------|------|---------|
| `sample/AppleTraceSwiftDemo` | Swift | `withSpan` + `@Traced` / `@TraceAll` 宏、counter / async，**以及** `AppleTraceAuto` 的 SwiftTrace 自动 hook |
| `sample/TraceAllMsgDemo` | Objective-C | 手动 `APTBeginSection` section **以及**自动 `objc_msgSend` hook |

Swift demo 依赖本地 SwiftPM 包，从仓库根目录打开
（`open sample/AppleTraceSwiftDemo/AppleTraceSwiftDemo.xcodeproj`），Xcode 会自动
解析 `AppleTrace` / `AppleTraceAuto` 两个 product。

### 模式 A — 手动埋点（推荐基线）

```objc
#import <appletrace/appletrace.h>

- (void)yourMethod {
    APTBegin;            // section 名为 "[ClassName yourMethod]"
    // ... 你的代码 ...
    APTEnd;
}
```

### 模式 B — 自动 `objc_msgSend` hook（arm64）

```objc
// 在 App 启动后调用：
APTInstallObjcMsgSendHook();
```

```bash
# …或者无需改代码，通过环境变量开启：
export APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1
```

### 采集与可视化

```bash
# 运行 App；片段落在 <App 沙盒>/Library/appletracedata。
# 从模拟器/真机拉取该目录，然后：

python3 merge.py -d /path/to/appletracedata     # → trace.json
# 或者合并并一步打开 Perfetto：
sh go.sh /path/to/appletracedata
```

打开 [ui.perfetto.dev](https://ui.perfetto.dev)，把 `trace.json` 拖进去（或用
**Open trace file**）。

---

## 🔧 工作原理

```
   你的 App（已埋点）                       主机工具链                    浏览器
┌───────────────────────────┐      ┌──────────────────────┐      ┌────────────────┐
│ APTBeginSection / APTEnd…  │      │  merge.py /           │      │                │
│ APTInstant / APTCounter    │ ───► │  appletrace_cli.py    │ ───► │ ui.perfetto.dev│
│ APTAsyncBegin / …          │      │                       │      │                │
│ objc_msgSend 自动 hook      │      │  片段 → trace.json     │      │  拖拽即可       │
└───────────────────────────┘      └──────────────────────┘      └────────────────┘
   每线程批量写入                          X-complete 折叠
   → <沙盒>/Library/appletracedata        → 单个 JSON 数组
```

1. **埋点**：加手动标记，或安装 `objc_msgSend` hook。
2. **采集**：事件在每线程缓冲累积、批量落盘到
   `<App 沙盒>/Library/appletracedata` 下的 trace 片段。
3. **合并**：拉取该目录并运行 `merge.py`；begin/end 对折叠为 Perfetto `X` complete
   事件。
4. **可视化**：把 `trace.json` 拖入 Perfetto。

---

## 📦 安装

### 环境要求

| 要求 | 版本 | 用途 |
|------|------|------|
| **macOS** | 10.15+ | 构建环境 |
| **Xcode** | 12+ | iOS/macOS 构建（arm64） |
| **Python** | 3.9+ | trace 合并、CLI 与测试 |
| **Perfetto** | Web | 在 [ui.perfetto.dev](https://ui.perfetto.dev) 可视化 |
| **ldid** | 可选 | 重签名 loader 内嵌的 framework |
| **LLDB** | 可选 | 驱动动态 hook 模式 |

### 构建 framework

在仓库根目录执行：

```bash
# iOS 真机（arm64；arm64e 验证构建可额外传入 ARCHS=arm64e）
xcodebuild -project appletrace/appletrace.xcodeproj -scheme appletrace \
  -configuration Release -sdk iphoneos build
```

> 自动 hook 支持 arm64 与 arm64e。arm64e 后端会按照标准函数指针
> PAC 规则重新签名 chained-fixup `__auth_got` 槽。模拟器无法验证指针认证，发布前必须在
> iOS 27 的 iPhone 17 Pro arm64e 真机上完成验证。

把生成的 `appletrace.framework` 嵌入你的目标（手动 section 与自动 hook 都见
`sample/TraceAllMsgDemo`）。注入第三方 App 见 `loader/` 工程，替换重新
构建的 framework 后运行 `loader/resign.sh`。

---

## 🛠️ 使用

### 手动埋点

**Objective-C**

```objc
#import <appletrace/appletrace.h>

- (void)viewDidLoad {
    APTBegin;                 // 自动命名为 "[ClassName viewDidLoad]"
    [super viewDidLoad];
    APTEnd;
}

- (void)networkRequest {
    APTBeginSection("network");   // 显式 section 名
    // ... 网络代码 ...
    APTEndSection("network");
}
```

**C / C++**

```cpp
#include <appletrace/appletrace.h>

void complexFunction() {
    APTBeginSection("processing");
    // ... C++ 代码 ...
    APTEndSection("processing");
}

void saferCppFunction() {
    APTScopeSection("processing");   // RAII：作用域结束自动 end
    // ... C++ 代码 ...
}
```

### 追踪 Swift 代码（SwiftPM）

`objc_msgSend` hook 看不到 Swift 的静态 / vtable / witness 派发，所以 Swift 走
**源码级埋点**。把本仓库作为 SwiftPM 依赖添加
（`https://github.com/everettjf/AppleTrace.git`），然后 `import AppleTrace`：

```swift
import AppleTrace

// 作用域 span（即使 throw / 提前返回也会闭合）：
withSpan("loadFeed") { try? loadFeed() }

// 或用宏标注——对 final 类、struct、protocol 方法都生效，
// 因为 begin/end 是在编译期插入函数体的：
@Traced
func decodeImage() { /* ... */ }

@TraceAll                 // 给每个有函数体的方法都自动加 @Traced
final class FeedViewModel {
    func reload() { /* 已追踪 */ }
    func render() { /* 已追踪 */ }
}

APTFlush()  // （或 AppleTrace.flush()）读取 trace 前先 flush
```

想要零标注地自动追踪整个类层级？可选的 `AppleTraceAuto` product 桥接了
[SwiftTrace](https://github.com/johnno1962/SwiftTrace)：

```swift
import AppleTraceAuto
AppleTraceAuto.trace(aClass: FeedViewModel.self)   // 进入/退出 → AppleTrace
```

`AppleTraceAuto` **仅限模拟器 / macOS**（SwiftTrace 会改写经过指针认证的 vtable 槽，
在真机上不安全——请用 `#if targetEnvironment(simulator)` 包起来），且看不到 `final` /
静态派发的方法。宏没有这些限制，是真机上的首选路径。详见 `docs/swift-tracing.md`
与可运行的 `AppleTraceAutoExample`（`swift run AppleTraceAutoExample`）。

### 瞬时标记、计数器与异步事件

```objc
// 在当前线程时间线上打一个点
APTInstant("cache_miss");

// 随时间绘制数值曲线（内存、FPS、队列深度……）
APTCounter("resident_mb", 142.5);
APTCounter("fps", 60);

// 跨线程/队列的异步事件（通过 name + id 配对）
uint64_t requestID = 42;
APTAsyncBegin("image_load", requestID);
dispatch_async(queue, ^{
    // ... 在另一个线程上的工作 ...
    APTAsyncEnd("image_load", requestID);
});
```

### 运行时控制

```objc
APTSetEnabled(NO);                       // 临时暂停记录
APTSetEnabled(YES);                      // 恢复
BOOL on = APTIsEnabled();                // 查询状态
APTFlush();                              // 强制把缓冲写入磁盘
APTSyncWait();                           // 阻塞直到挂起的写入完成
NSLog(@"trace dir = %s", APTGetTraceDirectory());
BOOL hooked = APTIsObjcMsgSendHookInstalled();
```

### 环境变量

```bash
export APPLETRACE_ENABLED=1
export APPLETRACE_DATA_DIR="$HOME/tmp/appletracedata"
export APPLETRACE_BLOCK_SIZE_MB=32
export APPLETRACE_KEEP_EXISTING=1

# arm64 自动 objc_msgSend hook
export APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1
# 仅追踪以这些前缀开头的类（逗号分隔）
export APPLETRACE_TRACE_CLASS_ALLOW="MyApp,UI"
# 永不追踪这些前缀的类（优先级高于 allow）
export APPLETRACE_TRACE_CLASS_DENY="NSKVO,_"

# 可选的二进制片段格式（把字符串格式化移出热路径）
export APPLETRACE_BINARY=1
```

---

## 📊 处理与可视化 trace

```bash
# 合并所有片段为 trace.json（默认 X complete 事件）
python3 merge.py -d /path/to/appletracedata

# 保留原始 begin/end 事件而不折叠
python3 merge.py -d /path/to/appletracedata --raw

# 统一 CLI
python3 scripts/appletrace_cli.py merge /path/to/appletracedata
python3 scripts/appletrace_cli.py open  /path/to/appletracedata   # 合并并打开 Perfetto

# 一行命令
sh go.sh /path/to/appletracedata
```

`merge.py` 会自动发现文本片段（`trace[_N].appletrace`）和二进制片段
（`trace[_N].appletracebin`），并按各自的 magic 头解码。随后把生成的 `trace.json`
拖入 [ui.perfetto.dev](https://ui.perfetto.dev)。

想不构建任何东西先体验一下？把仓库里现成的
[`sampledata/trace.json`](sampledata/trace.json) 拖进 Perfetto 即可。

---

## 🧩 平台与 hook 支持

AppleTrace 支持 **arm64 与 arm64e**。

| 模式 | arm64 | arm64e |
|------|:-----:|:------:|
| 手动 section 与显式事件（`APTBeginSection`、`APTInstant` 等） | ✅ | ✅ |
| 自动 `objc_msgSend` / `objc_msgSendSuper2` hook | ✅ | ✅ |

- **手动 section** 是风险最低的基线，适用于所有 iOS/macOS 版本。
- **arm64 自动 hook** 已在 iOS 模拟器与主机压测上端到端验证——嵌套调用、`super`
  派发、跨线程事件、10 参数调用、浮点/小型聚合返回值等 ABI 场景都能安全穿过追踪
  wrapper。
- **arm64e 自动 hook** 会检测 Mach-O chained fixups，并用 IA key、零 discriminator 和
  slot 地址对每个 `__auth_got` 替换指针重新签名；wrapper 同时使用 PAC-aware 调用/返回
  与 BTI landing pad。该路径已在 iOS 27 的 iPhone 17 Pro 上以 text、binary 两种 trace
  模式完成端到端验证。

---

## ✅ 测试

```bash
# Python 工具链（合并流水线 + 二进制片段格式）
python3 -m pytest tests

# objc_msgSend hook smoke test（在模拟器上构建并运行示例）
./scripts/test_objc_msgsend_hook.sh
./scripts/test_objc_msgsend_hook_experimental.sh

# 在已连接的 arm64 真机上运行同样的 smoke test（text + binary 两种模式）
./scripts/test_objc_msgsend_hook_device.sh

# 强制构建真正的 arm64e App/framework slice，验证 PAC 路径
DEVICE_ARCH=arm64e ./scripts/test_objc_msgsend_hook_device.sh

# 批量写入并发压测（host 构建，text + binary 两种模式）
./scripts/test_batching_stress.sh
```

其中 experimental 脚本额外验证 `super` 派发、跨线程事件、栈上传参与浮点参数，以及
小型聚合返回值。压测脚本断言跨线程、flush、线程退出后事件不丢不重。

---

## 📁 项目结构

```
AppleTrace/
├── appletrace/              # 核心追踪 framework（appletrace.xcodeproj）
│   └── appletrace/src/      # framework 源码 + objc_msgSend hook
├── loader/                  # 旧版越狱环境 loader（保留参考）
├── sample/
│   ├── AppleTraceSwiftDemo/ # Swift 示例：宏 + SwiftTrace 自动 hook
│   └── TraceAllMsgDemo/     # OC 示例：手动 + objc_msgSend hook
├── Web/console/              # React 控制台（作为静态资源嵌入 server）
├── Jailbreak/                # Theos tweak + appletraced 本地 daemon
├── scripts/                 # CLI + smoke/压测脚本
│   └── appletrace_cli.py    # 合并 + 打开 Perfetto 的 CLI
├── docs/                    # 二进制格式与批量写入设计说明
├── tests/                   # Python 回归测试 + 压测 harness
├── sampledata/              # 供 Perfetto 体验的示例 trace.json
├── merge.py                 # 合并片段 → trace.json
├── appletrace_binary.py     # 二进制片段编/解码
├── go.sh                    # 合并并打开 Perfetto
└── requirements.txt         # Python 开发/测试依赖
```

### 本地控制服务

`AppleTraceServer` 提供按需启动、token 鉴权、默认仅监听 loopback 的 HTTP 与
WebSocket 服务。集成 AppleTrace 的 App 可以通过内置 Web Console 开始/停止采集、
更新过滤条件、查看指标和下载 trace；服务不会自动启动。

`Jailbreak/` 包使用 bundle allowlist，并复用设备现有的 Substrate-compatible
injector。被注入的 App 只主动连接本机 `appletraced` Unix socket，不自行监听 TCP
端口。daemon 在 loopback 上提供同一套控制台，可选择进程，并分别控制采集、过滤、
trace 列表与下载。详见 [`Jailbreak/README.md`](Jailbreak/README.md)。

暂时没有手机时，可运行 `./scripts/verify_without_device.sh`，一次完成主机、模拟器、
arm64e 编译、控制面和导出器验收。可选的 Theos 打包方式及剩余真机检查见
[`docs/device-validation.md`](docs/device-validation.md)。
四个阶段各自的实现范围与验证证据见
[`docs/control-plane-phases.md`](docs/control-plane-phases.md)。

---

## ❓ FAQ

**AppleTrace 还在维护吗？**
是的——按需维护。AppleTrace 现在不再是持续活跃开发状态，但随着 AI 时代的到来，可做的
事情更多了，后续会根据实际需要继续维护和改进。

**支持较新的 iOS 版本吗？**
手动埋点适用于所有 iOS 版本。自动 hook 模式支持 arm64 与 arm64e（见
[平台与 hook 支持](#-平台与-hook-支持)）。

**能追踪第三方 App 吗？**
只能在有授权的环境中进行。非越狱设备需要把 AppleTrace 编译并签名进自己的 App；
`Jailbreak/` 包可以借助设备已有的 tweak injector 注入 allowlist 中的 App，但该路径仍需
完成越狱真机验证后才能作为稳定能力发布。

**为什么需要 Python 3？**
Python 2 已于 2020 年停止维护，工具链需要 Python 3.9+。

**可以用在 macOS App 上吗？**
可以——AppleTrace 同时适用于 iOS 和 macOS 应用。

---

## 🤝 贡献

欢迎贡献！请阅读[贡献指南](CONTRIBUTING.md)与 [Agent 指南](AGENT.md)了解仓库约定。

1. **Fork** 仓库。
2. **创建**特性分支：`git checkout -b feature/amazing-feature`
3. **提交**改动（先跑测试）。
4. **Push** 并发起 **Pull Request**。

**代码风格：** [Google Objective-C Style Guide](https://google.github.io/styleguide/objcguide.html) ·
[PEP 8](https://www.python.org/dev/peps/pep-0008/) ·
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)

---

## 🛠️ 技术栈

<div align="center">

![Objective-C](https://img.shields.io/badge/Objective--C-438EFF?style=flat-square&logo=apple)
![C](https://img.shields.io/badge/C-00599C?style=flat-square&logo=c)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat-square&logo=python)
![Xcode](https://img.shields.io/badge/Xcode-147EFB?style=flat-square&logo=xcode)
![Perfetto](https://img.shields.io/badge/Perfetto-2E2E2E?style=flat-square&logo=google)
![LLDB](https://img.shields.io/badge/LLDB-1A73E8?style=flat-square&logo=llvm)

</div>

---

## 🙏 致谢

灵感来自 Facebook 的 [fbtrace](https://github.com/facebookarchive/fbtrace)，并围绕
Google 的 [Perfetto](https://perfetto.dev) 和
[Trace Event Format](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview)
构建。

---

## 📜 许可证

AppleTrace 基于 MIT 许可证发布，详见 [LICENSE](LICENSE)。

---

## 📞 支持

<div align="center">

<a href="https://github.com/everettjf/AppleTrace/issues">
  <img src="https://img.shields.io/badge/Issues-Bug_Reports-FF6B6B?style=for-the-badge&logo=github" />
</a>
<a href="https://github.com/everettjf/AppleTrace/discussions">
  <img src="https://img.shields.io/badge/Discussions-Questions-4ECDC4?style=for-the-badge&logo=github" />
</a>
<a href="http://everettjf.github.io/2017/09/21/appletrace/">
  <img src="https://img.shields.io/badge/Docs-中文教程-45B7D1?style=for-the-badge&logo=readthedocs" />
</a>

**Made with ❤️ by [Everett](https://github.com/everettjf)**

</div>

---

## 📈 Star History

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/AppleTrace&type=Date)](https://star-history.com/#everettjf/AppleTrace&Date)

</div>

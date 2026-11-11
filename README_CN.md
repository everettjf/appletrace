# AppleTrace 🍎

[Discord](https://discord.gg/eGzEaP6TzR)

仓库地址：<https://github.com/everettjf/appletrace>

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/AppleTrace?style=flat-square&color=4ECDC4)](https://github.com/everettjf/AppleTrace/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/everettjf/AppleTrace?style=flat-square&color=4ECDC4)](https://github.com/everettjf/AppleTrace/network)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/everettjf/AppleTrace?style=flat-square)](https://github.com/everettjf/AppleTrace/commits/master)
[![Contributors](https://img.shields.io/github/contributors/everettjf/AppleTrace?style=flat-square)](https://github.com/everettjf/AppleTrace/graphs/contributors)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square&logo=apple)](https://github.com/everettjf/AppleTrace)

**轻量、可内嵌的 Objective-C 与 Swift 追踪器，产物可直接在 [Perfetto](https://ui.perfetto.dev) 中打开和分享**

📖 **[阅读完整教程与使用指南 →](https://everettjf.github.io/AppleTrace/zh.html)**

[English](README.md) | [中文](README_CN.md)

</div>

> 🚀 **按需维护。** AppleTrace 捕获 App 的执行时间线——手动 section、Swift 宏和/或
> 每一次 `objc_msgSend`——并在浏览器里用 Perfetto 直接呈现。2.0 版本新增一条命令完成
> 采集的 `appletrace` CLI、默认二进制格式、对 async 安全的 Swift 宏，以及支持 rootless /
> roothide 越狱的 loader。详见 [CHANGELOG](CHANGELOG.md)。

![AppleTrace Demo](https://everettjf.github.io/stuff/appletrace/appletrace.gif)

---

## 目录

- [AppleTrace 是什么？](#-appletrace-是什么)
- [核心特性](#-核心特性)
- [快速开始](#-快速开始)
- [工作原理](#-工作原理)
- [安装](#-安装)
- [使用](#-使用)
- [`appletrace` 命令行工具](#️-appletrace-命令行工具)
- [在越狱设备上追踪任意 App](#-在越狱设备上追踪任意-app)
- [平台与 hook 支持](#-平台与-hook-支持)
- [测试](#-测试)
- [项目结构](#-项目结构)
- [FAQ](#-faq)
- [贡献](#-贡献)
- [许可证](#-许可证)

---

## 🎯 AppleTrace 是什么？

AppleTrace 是一个面向 iOS/macOS 的追踪工具。你给 App 埋点——手动的
`APTBeginSection` / `APTEndSection` 标记、Swift 的 `@Traced` 宏，或者自动 hook 每一次
`objc_msgSend`——AppleTrace 会把事件时间线写入 App 沙盒里的 trace 片段。`appletrace`
命令行工具负责把片段从设备上拉下来、合并成单个 `trace.json`，并在
[Perfetto](https://ui.perfetto.dev) 中打开，用来分析调用时间线、耗时、线程与计数器。

![Demo Preview](image/appletrace-small.png)

*trace 可视化展示了方法执行时间线与调用关系。*

---

## ✨ 核心特性

- 📊 **自动方法追踪**——在 arm64 / arm64e 上直接重绑定 `objc_msgSend` /
  `objc_msgSendSuper2`，无需改源码即可捕获 Objective-C 调用，之后 `dlopen` 加载的
  framework 也会被覆盖。
- 🧩 **Swift 宏**——`@Traced` / `@TraceAll` 在编译期插桩（final class、struct、actor、
  协议扩展都可以）。名字带类型限定（`FeedViewModel.reload(force:)`）；`async` 函数使用
  async span，`await` 之后换线程继续执行也仍是一个完整的片段。
- 🎯 **手动 section**——`APTBeginSection` / `APTEndSection`（以及 `APTBegin` /
  `APTEnd` / `APTScopeSection`）精确标记你关心的区间，风险最低，所有系统版本都可用。
- 📈 **丰富的事件类型**——瞬时标记（`APTInstant`）、计数器曲线（`APTCounter`，可画内存、
  FPS、队列深度等）、跨线程 / 跨队列的 async 事件（`APTAsyncBegin` / `APTAsyncEnd`）。
- ⚡ **为热路径而设计**——默认二进制 trace 片段、`(Class, SEL)` 名字驻留、按指针缓存的
  名字 id、按线程批量写入，让 `malloc`、字符串格式化和 dispatch 都不出现在每个事件的路径上。
- 💾 **崩溃也能留下 trace**——缓冲区每秒、App 进入后台时、进程退出时都会写入内存映射
  文件，即使 App 被杀，trace 依然可读。
- 🛠️ **一条命令完成采集**——`appletrace record` 在设备上启动 App、等待、停止、拉取、
  合并并打开 Perfetto，不再需要 Python。
- 🚦 **CI 性能门禁**——`appletrace summary` 输出每个 span 的次数、总耗时、自身耗时和
  p50/p95；`appletrace diff` 与基线对比，出现性能回退时以非零状态退出。
- 🔓 **越狱设备上追踪任意 App**——AppleTraceLoader 插件支持 rootless 与 roothide 越狱，
  通过 SSH 用 `appletrace jb …` 控制。
- 🔍 **运行时过滤**——用类名前缀白名单 / 黑名单（`APPLETRACE_TRACE_CLASS_ALLOW` /
  `APPLETRACE_TRACE_CLASS_DENY`）限定自动追踪的范围。

### 使用场景

- 🔍 **性能分析**——在真实时间线上找到热点与耗时方法。
- 🐛 **调试**——跨线程跟踪方法执行流程。
- 📚 **学习**——看清 iOS/macOS 框架实际是如何派发的。
- 🛡️ **安全研究**——在越狱设备上分析第三方 App 的行为。

---

## ⚡ 快速开始

```bash
git clone https://github.com/everettjf/AppleTrace.git
cd AppleTrace
swift build -c release --product appletrace     # 生成 .build/release/appletrace
```

每个 [GitHub release](https://github.com/everettjf/appletrace/releases) 都附带预编译的
`appletrace` 可执行文件、`appletrace.xcframework` 以及越狱安装包。

### 运行示例 App（最快看到 trace 的方式）

`sample/AppleTraceSwiftDemo` 会跑一段精心设计的多线程负载（启动阶段 span、并行的
`ImageDecoder` / `NetworkClient` / `DatabaseWriter` 线程、异步下载弧线、Swift 并发里的
`@Traced async` 方法，以及带实时 FPS / 内存计数器的 60 帧渲染循环）。

```bash
open sample/AppleTraceSwiftDemo/AppleTraceSwiftDemo.xcodeproj   # 先在设备上运行一次完成安装

# 然后一条命令完成采集——启动、等待、停止、拉取、合并、打开 Perfetto：
swift run appletrace record --bundle-id com.everettjf.AppleTraceSwiftDemo \
  --env APPLETRACE_AUTORUN=1 --open
```

在模拟器上，点击 **Generate Trace**，再执行 App 界面上显示的 `swift run appletrace open
<dir>` 命令即可。

仓库内含两个示例：

| 示例 | 语言 | 演示内容 |
|------|------|----------|
| `sample/AppleTraceSwiftDemo` | Swift | `withSpan` + `@Traced` / `@TraceAll` 宏（含 `async`）、计数器 / async span，**以及** `AppleTraceAuto` SwiftTrace 自动 hook |
| `sample/TraceAllMsgDemo` | Objective-C | 手动 `APTBeginSection` **以及**自动 `objc_msgSend` hook |

### 模式 A——手动埋点（推荐的基线方案）

```objc
#import <appletrace/appletrace.h>

- (void)yourMethod {
    APTBegin;            // section 名为 "[ClassName yourMethod]"
    // ... 你的代码 ...
    APTEnd;
}
```

### 模式 B——自动 `objc_msgSend` hook（arm64 / arm64e）

```objc
APTInstallObjcMsgSendHook();   // Swift 中：AppleTrace.installObjCMsgSendHook()
```

```bash
# 或者不改代码，用环境变量开启（`appletrace record --hook` 设置的就是它）：
export APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1
```

### 采集与可视化

```bash
# 设备上用开发证书签名的 App：
swift run appletrace record --bundle-id com.example.MyApp --duration 15 --hook --open

# 或者分步执行：
swift run appletrace pull --bundle-id com.example.MyApp -o mytrace
swift run appletrace open mytrace
```

`appletrace open` 通过浏览器里的一个本地页面把 trace 交给
[ui.perfetto.dev](https://ui.perfetto.dev)，文件不会被上传。也可以自己把 `trace.json`
拖进 Perfetto。

---

## 🔧 工作原理

```
   被埋点的 App                           appletrace CLI（macOS）              浏览器
┌────────────────────────────┐      ┌──────────────────────────┐      ┌────────────────┐
│ APTBeginSection / @Traced   │      │ record / pull（devicectl，│      │                │
│ APTInstant / APTCounter     │ ───► │   越狱设备走 SSH）        │ ───► │ ui.perfetto.dev│
│ APTAsyncBegin / async span  │      │ merge → trace.json       │      │                │
│ objc_msgSend 自动 hook      │      │ open → 本地页面交接       │      │                │
└────────────────────────────┘      └──────────────────────────┘      └────────────────┘
   按线程批量 → 内存映射文件               合并为 X 完整事件
   <sandbox>/Library/appletracedata       支持二进制与文本片段
```

1. **埋点**——加手动标记或 Swift 宏，或者安装 `objc_msgSend` hook。
2. **采集**——事件先进入每个线程自己的缓冲区，按顺序交给串行写线程，最终写入
   `<app sandbox>/Library/appletracedata` 下的内存映射二进制片段。
3. **合并**——`appletrace merge` 解码片段，并把 begin/end 对折叠成 Perfetto 的 `X`
   完整事件。
4. **可视化**——`appletrace open` 把 `trace.json` 加载进 Perfetto。

---

## 📦 安装

### 环境要求

| 依赖 | 版本 | 用途 |
|------|------|------|
| **macOS** | 12+ | 构建环境与 `appletrace` CLI |
| **Xcode** | 16+（Swift 6 工具链） | Swift 包、framework 与示例 |
| **iOS / macOS 部署目标** | iOS 15+ / macOS 12+ | 集成 AppleTrace 的 App |
| **Perfetto** | Web | 在 [ui.perfetto.dev](https://ui.perfetto.dev) 可视化 |
| **ldid**、**xz** | 可选 | 构建越狱安装包 |
| **Python** | 可选，3.9+ | 旧版 `merge.py` 工具及其测试 |

### Swift Package Manager

```swift
.package(url: "https://github.com/everettjf/appletrace.git", from: "2.1.0")
```

| Product | 说明 |
|---------|------|
| `AppleTrace` | C 内核 + `objc_msgSend` hook、Swift API，以及 `@Traced` / `@TraceAll` 宏 |
| `AppleTraceAuto` | 可选的 SwiftTrace 桥接（仅模拟器 / macOS） |
| `AppleTraceKit` | trace 片段解码与合并，可用于你自己的工具 |
| `appletrace` | 命令行工具 |

### Framework（Objective-C / Xcode）

使用 release 中的 `appletrace.xcframework`，或者自行构建：

```bash
xcodebuild -project appletrace/appletrace.xcodeproj -scheme appletrace \
  -configuration Release -sdk iphoneos build
```

> 自动 hook 支持 arm64 和 arm64e。arm64e 下，chained-fixup 的 `__auth_got` 槽位替换值
> 按标准函数指针 PAC 方案签名。模拟器 / Intel 架构编译为一个桩实现，安装调用返回 `NO`。

---

## 🛠️ 使用

### 手动埋点

**Objective-C**

```objc
#import <appletrace/appletrace.h>

- (void)viewDidLoad {
    APTBegin;                 // 自动命名为 "[ClassName viewDidLoad]"（名字会驻留，不会每次分配内存）
    [super viewDidLoad];
    APTEnd;
}

- (void)networkRequest {
    APTBeginSection("network");   // 显式指定 section 名
    // ... 网络代码 ...
    APTEndSection("network");
}
```

**C / C++**

```cpp
#include <appletrace/appletrace.h>

void saferCppFunction() {
    APTScopeSection("processing");   // RAII：离开作用域时自动结束
    APTScopeSection("inner");        // 同一作用域可以用多个
    // ... C++ 代码 ...
}
```

### 追踪 Swift（SwiftPM）

`objc_msgSend` hook 看不到 Swift 的静态派发 / vtable / witness 派发，因此 Swift 在
**源码层面**追踪：

```swift
import AppleTrace

// 作用域 span（抛错或提前 return 也会正确结束）。字符串字面量会匹配 StaticString
// 重载，直接把字面量传给 C 内核。
withSpan("loadFeed") { try? loadFeed() }

// 异步工作：async span 的开始和结束可以在不同线程。
let feed = try await withAsyncSpan("fetchFeed") { try await api.feed() }

// 注解——span 名带类型限定："FeedViewModel.reload(force:)"。
@TraceAll
final class FeedViewModel {
    func reload(force: Bool) { /* 被追踪 */ }
    func refresh() async throws { /* async span：await 处换线程也没问题 */ }
    @NotTraced func hotPath() { /* 不追踪 */ }
}

@Traced("feed.decode")       // 显式命名
func decodeImage() { /* ... */ }
```

运行时会每秒、进入后台时以及退出时自动刷盘；只有在进程内读取 trace 时才需要调用
`AppleTrace.flush()`。

想零注解地自动追踪某个类层级？可选的 `AppleTraceAuto` 产品桥接了
[SwiftTrace](https://github.com/johnno1962/SwiftTrace)：

```swift
import AppleTraceAuto
AppleTraceAuto.trace(aClass: FeedViewModel.self)   // 进入 / 退出 → AppleTrace
```

`AppleTraceAuto` **仅支持模拟器 / macOS**（SwiftTrace 会改写受指针认证保护的 vtable
槽位，在真机上不安全——请用 `#if targetEnvironment(simulator)` 包起来），并且看不到
`final` / 静态派发的方法。宏没有这些限制，是真机上的推荐方案。详见
[docs/swift-tracing.md](docs/swift-tracing.md)。

### 瞬时标记、计数器与 async 事件

```objc
APTInstant("cache_miss");                 // 时间点
APTCounter("resident_mb", 142.5);         // 随时间变化的数值

uint64_t requestID = APTNewAsyncID();     // 进程内唯一 id
APTAsyncBegin("image_load", requestID);
dispatch_async(queue, ^{
    // ... 在另一个线程上工作 ...
    APTAsyncEnd("image_load", requestID);
});
```

在 Swift 中，`withAsyncSpan` 和 `async` 函数上的 `@Traced` 会把当前任务的名字
（Swift 6.2 的 `Task(name:)` / `addTask(name:)`，iOS 26 / macOS 26 及以上）记录为
span 的 `task` 参数。在 Objective-C / C 中可以用 `APTAsyncBeginWithTask(name, id, label)`
传入标签。

### 运行时控制

```objc
APTSetEnabled(NO);                       // 暂停记录
APTSetEnabled(YES);                      // 恢复
BOOL on = APTIsEnabled();                // 查询状态
APTFlush();                              // 强制把缓冲写到磁盘
NSLog(@"trace dir = %s", APTGetTraceDirectory());
BOOL hooked = APTIsObjcMsgSendHookInstalled();
```

### 环境变量

| 变量 | 默认值 | 含义 |
|------|--------|------|
| `APPLETRACE_ENABLED` | `1` | 是否记录（`0` 表示启动时暂停） |
| `APPLETRACE_DATA_DIR` | `<sandbox>/Library/appletracedata` | 片段写入目录 |
| `APPLETRACE_FORMAT` | `binary` | `binary` 或 `text`（JSON 行，便于调试）。`APPLETRACE_BINARY=0/1` 仍然有效 |
| `APPLETRACE_FLUSH_INTERVAL_MS` | `1000` | 后台刷盘间隔；`0` 表示关闭 |
| `APPLETRACE_BLOCK_SIZE_MB` | `16` | 单个片段大小，超过后滚动到新片段（1–256） |
| `APPLETRACE_KEEP_EXISTING` | `0` | 保留之前的 trace（`appletracedata_N`），而不是覆盖 |
| `APPLETRACE_AUTO_HOOK_OBJC_MSGSEND` | `0` | 加载时安装 `objc_msgSend` hook |
| `APPLETRACE_TRACE_CLASS_ALLOW` | — | 逗号分隔的类名前缀，只追踪这些 |
| `APPLETRACE_TRACE_CLASS_DENY` | — | 永不追踪的前缀（优先于白名单） |

格式不正确的值会被记录日志并忽略（使用默认值）。

---

## 🖥️ `appletrace` 命令行工具

```text
appletrace merge <trace-dir> [-o trace.json] [--raw]
appletrace open <trace-dir | trace.json>
appletrace summary <trace>... [--top 20] [--sort total|self|mean|p50|p95|max|count|name]
                   [--only <prefixes>] [--json] [-o summary.json]
appletrace diff <baseline> <current> [--metric total|self|mean|p50|p95|max|count]
                [--threshold 10%] [--min-delta 1ms] [--only <prefixes>]
                [--fail-on-missing] [--all] [--json]
appletrace devices
appletrace pull   --bundle-id <id> [--device <udid|name>] [-o <dir>]
appletrace record --bundle-id <id> [--device <udid|name>] [--duration <sec>]
                  [--hook] [--allow <prefixes>] [--deny <prefixes>] [--text]
                  [--env KEY=VALUE]... [-o <dir>] [--open]
appletrace jb install|enable|disable|list|pull|record …
```

- `record` 通过 `devicectl` 带上对应的 `APPLETRACE_*` 环境变量启动 App，等待、停止、拉取
  `Library/appletracedata` 并合并。适用于开发证书签名的 App；其他 App 请用
  `appletrace jb record`。
- `merge` 同时支持二进制和文本片段（包括被杀进程留下的片段），默认折叠 begin/end 对，
  加 `--raw` 则保留原始事件。
- `summary` 输出每个 span 的次数、总耗时、自身耗时、平均、p50、p95 和最大耗时；
  每个参数算一次运行，多次运行会合并统计。`-o` 把结果保存为基线。
- `diff` 对比两份 trace 或 summary：某个 span 的变化同时超过 `--threshold` 和
  `--min-delta` 时以状态 2 退出（出错为 1，否则为 0）。GitHub Actions 的配置见
  [docs/ci-performance-gates.md](docs/ci-performance-gates.md)。
- Python 的 `merge.py` / `scripts/appletrace_cli.py` / `go.sh` 仍然可用，输出一致。

---

## 🔓 在越狱设备上追踪任意 App

AppleTraceLoader 插件会把 AppleTrace 注入到你指定的 App 中，支持 **rootless**
（`/var/jb`，例如 Dopamine）和 **roothide** 越狱。它根据自身路径推导越狱根目录，因此同一份
二进制在两种越狱上都能用。

1. 安装 release 中的安装包（或用 `./scripts/build_jailbreak_packages.sh` 自行构建）：
   - rootless：`appletrace-loader_<version>_iphoneos-arm64.deb`
   - roothide：`appletrace-loader_<version>_iphoneos-arm64e.deb`

   ```bash
   appletrace jb install appletrace-loader_2.1.0_iphoneos-arm64e.deb --host <设备地址> [--port 22]
   ```

   `jb install` 会执行 `dpkg`，需要 root SSH。如果只能以 `mobile` 登录（例如 roothide
   上 `sudo` 需要密码），请改用 Sileo / Zebra 安装 `.deb`，其余 `jb` 命令加
   `--user mobile` 即可，它们不需要 root。

2. 录制某个 App（它会以开启追踪的状态重新启动，然后被停止、拉取并合并）：

   ```bash
   appletrace jb record com.example.App --host <设备地址> --duration 15 --hook \
     --allow "EX,App" --open
   ```

   也可以分步执行：`appletrace jb enable <bundle-id> --hook`，操作 App，
   `appletrace jb pull <bundle-id>`，`appletrace open appletracedata-<bundle-id>`，
   完成后 `appletrace jb disable <bundle-id>`。

`enable` 会写入 `<jbroot>/var/mobile/Library/AppleTrace/<bundle-id>.plist`（要应用的
`APPLETRACE_*` 变量）。loader 只会处理存在该文件的 App，并在 App 自己的
`tmp/AppleTraceLoader.log` 里写一行状态（越狱根目录、重绑定诊断、trace 目录），
`jb pull` 会把它打印出来。SSH 需要密钥登录（`ssh-copy-id`）；通过 USB 时可以用
`iproxy 2222 22` 转发 22 端口，再传 `--host 127.0.0.1 --port 2222`。额外的 ssh/scp
参数放在 `APPLETRACE_SSH_OPTIONS` 里（例如 `"-i ~/.ssh/device_key"`）。

**已验证**：roothide 越狱（iPhone 11，iOS 26.0.1）上，一个 Flutter 的 App Store 应用
录到了 10 个线程上 22,849 次 hook 到的消息发送；类名过滤和文本格式正常；注入后的
arm64e 系统 App 运行正常。

> **限制——被封存的 App。** iOS 26 上，Apple 自带 App 的只读 `__DATA_CONST` 被映射为
> 永久不可写区域，GOT 无法重绑定，因此 hook 看不到它们自身的消息发送
> （`AppleTraceLoader.log` 中显示 `main_executable_slots=0 main_protect=2`）。第三方 App
> 不受影响，被封存的 App 也会照常运行。

---

## 🧩 平台与 hook 支持

| 模式 | arm64 | arm64e | x86_64（模拟器 / Intel Mac） |
|------|:-----:|:------:|:------:|
| 手动 section、Swift 宏与显式事件 | ✅ | ✅ | ✅ |
| 自动 `objc_msgSend` / `objc_msgSendSuper2` hook | ✅ | ✅ | —（桩实现返回 `NO`） |
| 越狱 loader（rootless / roothide） | ✅ | ✅ | — |

- **手动 section 与宏**风险最低，所有支持的系统版本都可用。
- **自动 hook** 用一段汇编跳板包裹每次被重绑定的消息发送，保留整数、浮点、栈传参和
  聚合返回值的 ABI 状态；已在模拟器、arm64e 的 iPhone 17 Pro（iOS 27）以及
  iPhone 11（iOS 26.0.1）的 arm64 与 arm64e 构建上验证。
- hook 重绑定的是 App 及其加载的 framework 的 GOT 槽位；共享缓存里系统 framework 之间的
  调用不经过可重绑定的 GOT，所以不会出现。`APTObjcMsgSendHookDiagnostics()` 会报告重绑定
  了多少个槽位。
- 部署目标为 iOS 14+ / macOS 11+ 时，clang 会把部分 `alloc`、`init`、`class`、`self`
  消息发送改成直接调用 `objc_alloc_init` / `objc_opt_*`，所以这些调用不会作为 hook
  事件出现。

---

## ✅ 测试

```bash
swift test                                     # 宏、运行时、async span、并发、解码器
./scripts/test_batching_stress.sh              # 写入压测：格式、刷盘、SIGKILL、滚动、错误配置
./scripts/test_ci_gates.sh                     # appletrace summary / diff 及其退出状态
./scripts/test_objc_msgsend_hook.sh            # 模拟器上的 hook 冒烟测试
./scripts/test_objc_msgsend_hook_experimental.sh
DEVICE_UDID=<udid> ./scripts/test_objc_msgsend_hook_device.sh                  # 真机，arm64
DEVICE_UDID=<udid> DEVICE_ARCH=arm64e ./scripts/test_objc_msgsend_hook_device.sh
python3 -m pytest Tests                        # 旧版 Python 导出工具
```

压测用 8 个线程 × 25,000 次嵌套且动态命名的 section，分别在文本和二进制模式、1 ms 后台
刷盘、不显式 flush、`SIGKILL` 之后、片段滚动、错误配置、不可写目录以及关闭追踪的情况下
运行，每次都校验事件数量精确、嵌套关系正确。

---

## 📁 项目结构

```
AppleTrace/
├── appletrace/              # 核心追踪 framework（appletrace.xcodeproj）
│   └── appletrace/src/      # C++ 内核 + objc_msgSend hook（与 SwiftPM 共用）
├── Sources/
│   ├── CAppleTrace/         # SwiftPM 对内核 + hook 的封装
│   ├── AppleTrace/          # Swift API 与宏
│   ├── AppleTraceMacrosPlugin/
│   ├── AppleTraceAuto/      # SwiftTrace 桥接
│   ├── AppleTraceKit/       # 片段解码与合并
│   └── AppleTraceCLI/       # `appletrace` 命令行工具
├── Tests/                   # Swift 测试、Python 测试、压测 harness
├── loader/                  # 越狱 AppleTraceLoader 插件（rootless / roothide）
├── sample/                  # Swift 与 Objective-C 示例 App
├── scripts/                 # 测试、压测与打包脚本
├── docs/                    # 格式与设计文档
├── Tutorial/                # GitHub Pages 教程
├── sampledata/              # 用于 Perfetto 的示例 trace
└── merge.py, appletrace_binary.py, go.sh   # 旧版 Python 工具
```

---

## ❓ FAQ

**AppleTrace 还在维护吗？**
是的——按需维护。随着 AI 时代的到来，可以探索和改进的地方更多了，后续会根据需要继续推进。

**AppleTrace 能在新版 iOS 上运行吗？**
可以。手动埋点和 Swift 宏在所有版本上都可用；自动 hook 已在 iOS 26 和 iOS 27 真机上
验证（arm64 与 arm64e）。

**能追踪第三方 App 吗？**
可以，需要 rootless 或 roothide 越狱——见[在越狱设备上追踪任意 App](#-在越狱设备上追踪任意-app)。

**还需要 Python 吗？**
不需要。`appletrace` CLI 已经取代了它；`merge.py` 为兼容已有脚本而保留。

**能用于 macOS App 吗？**
可以——AppleTrace 同时支持 iOS 和 macOS 应用。

**为什么 hook 的 trace 里看不到 `[NSObject alloc]` / `init`？**
见[平台与 hook 支持](#-平台与-hook-支持)中的说明：编译器把这些消息发送替换成了直接的
运行时调用。

---

## 🤝 贡献

欢迎贡献！请先阅读[贡献指南](CONTRIBUTING.md)和 [AGENTS.md](AGENTS.md) 了解仓库约定。

1. **Fork** 本仓库。
2. **创建**功能分支：`git checkout -b feature/amazing-feature`
3. **提交**修改（先跑一遍测试）。
4. **推送**并发起 **Pull Request**。

---

## 🛠️ 技术栈

<div align="center">

![Objective-C](https://img.shields.io/badge/Objective--C-438EFF?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![C++](https://img.shields.io/badge/C++-00599C?style=flat-square&logo=cplusplus)
![Xcode](https://img.shields.io/badge/Xcode-147EFB?style=flat-square&logo=xcode)
![Perfetto](https://img.shields.io/badge/Perfetto-2E2E2E?style=flat-square&logo=google)

</div>

---

## 🙏 致谢

灵感来自 Facebook 的 [fbtrace](https://github.com/facebookarchive/fbtrace)，并基于 Google 的
[Perfetto](https://perfetto.dev) 与
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

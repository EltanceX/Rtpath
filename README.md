# RtPath

![RtPath 应用图标](android/app/src/main/res/mipmap-hdpi/ic_launcher.png)

RtPath 是面向开发者的 Android 文件名搜索工具。它借鉴 Everything 的使用方式，首次扫描后在设备上建立 SQLite 索引，监听文件变更并增量更新。支持 Android 10 及以上版本，提供普通模式和显式授权的 Root 模式。

## 扫描与搜索

1. 在**普通模式**下打开扫描设置，选择应用自有目录或共享存储。填写 `Download` 等相对路径可限定范围，留空则扫描所选位置。共享存储的授权入口位于扫描设置内。
2. 从工具栏切换到 **Root 模式**，点击「连接 Root」并在设备的 Root 管理器中授权。在扫描设置中输入绝对路径，或从「常用目录」选择应用数据、下载目录、ADB 临时目录等预设，再开始扫描。「Root 挂载视图」列出 Root 服务实际可见的路径。
3. 扫描完成后，选择索引范围并输入文件名的一部分。支持中文名称和字面标点，也可组合前缀、扩展名、目录和大小条件，例如 `prefix:Main ext:kt path:"src/Feature A"`。用 `name:"Main Activity.kt"` 匹配完整名称，用 `size:>=1MiB` 按大小筛选。

结果支持按名称、路径、大小或修改时间排序，向下滚动可继续加载。每条结果显示文件类型图标和元数据，并可复制完整路径。普通与 Root 索引分别保存，重扫时仍可查询上次发布的结果。

## 实时更新与恢复

- 每种模式继续监听最近一次扫描的范围。文件创建、改写、改名或删除后，索引按事件批量更新。目录移入或改名时会补扫目标子树。搜索界面在滚动停稳后同步已提交的结果。 [增量更新](docs/phase4-inotify.md) · [实时更新时的滚动](docs/root-live-scroll.md)
- 普通模式使用 `inotify`。Root 模式只在目标挂载通过实际事件与文件句柄探测后启用 `fanotify`，其余范围使用 `inotify`。索引状态显示实际后端。经 FUSE 访问的共享存储可能漏掉底层直写事件，界面会标记部分实时覆盖。 [fanotify 探测与兼容性](docs/phase6-fanotify.md)
- 事件队列溢出后，若扫描根身份一致，应用会尝试自动重建该范围。应用重启或 Root 断开后仍可搜索历史索引，从历史索引选择「校验并恢复实时更新」可补录间隔期间的变更。Root 范围需要先重新连接 Root。 [恢复行为与设备验收](docs/phase5-recovery.md)

## 在 Windows 上构建并安装

已验证的工具链包括 Flutter 3.47.9 / Dart 3.13.7、JDK 21、Android SDK Platform 36、Build Tools 36.0.0、NDK 28.2.13676358 和 CMake 3.22.1。APK 包含 `arm64-v8a` 和 `x86_64`。

在项目根目录打开 PowerShell，将 SDK 和 JDK 路径替换为本机实际路径，再从 `adb devices` 的输出中选取设备序列号。

```powershell
. ./tools/enter-android-env.ps1 `
  -FlutterSdk '<Flutter SDK 路径>' `
  -AndroidSdk '<Android SDK 路径>' `
  -Jdk '<JDK 路径>'

adb devices
flutter pub get
flutter build apk --debug --target-platform 'android-arm64,android-x64'
./tools/install-android-apk.ps1 -Serial '<device-id>' `
  -Apk 'build/app/outputs/flutter-apk/app-debug.apk'
adb -s '<device-id>' shell am start -W -n io.github.eltancex.rtpath/.MainActivity
```

设备已授权 ADB Shell 使用 `su` 时，可给安装脚本追加 `-UseRoot`，通过包管理器安装并跳过普通 USB 安装确认。应用启动后以自己的普通 UID 运行。需要调试时可执行 `flutter attach -d '<device-id>'`。

## 实现与验证

Flutter 负责搜索界面与分页，Kotlin 负责 Android 权限、Root 服务连接和 SQLite 索引，原生 C++ 负责目录遍历及文件事件监听。首页的「能力检测」可查看应用 UID、SQLite 版本和普通进程挂载视图。连接 Root 后可在扫描设置中单独运行「探测 fanotify」。 [首版设计](docs/v1-design.md) · [开源项目参考](docs/open-source-references.md)

```powershell
flutter analyze
flutter test
```

在已授权 ADB Shell 使用 `su` 的真机上运行下列命令，覆盖普通扫描、搜索、共享存储、Root 和索引恢复。脚本会构建并安装独立测试包 `io.github.eltancex.rtpath.testhost`，需在 Root 管理器中为该包单独授权。`-Shared` 适用于 Android 11 及以上。

```powershell
./tools/verify-ordinary-scan.ps1 -Serial '<device-id>' -Shared -Root -Recovery
```

在 arm64 真机上可运行 10 万和 100 万条的 SQLite 与内存查询对照基准，原始结果保存在 `.local/artifacts/phase2-performance.txt`。

```powershell
./tools/verify-search-performance.ps1 -Serial '<device-id>'
```

[首版实现步骤](docs/v1-implementation-steps.md) · [首版验证计划](docs/v1-validation.md) · [环境与能力探针](docs/phase0-baseline.md) · [普通扫描](docs/phase1-baseline.md) · [搜索与性能](docs/phase2-search.md) · [Root 验证](docs/phase3-root.md)

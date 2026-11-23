# RtPath

RtPath 是面向开发者的 Android 文件搜索项目，采用 Flutter、Kotlin 和 C++。支持普通权限和显式 Root 扫描、持久化的文件名索引以及分页搜索。

## 使用

在首页打开扫描设置，选择应用自有目录或共享存储。相对目录留空时扫描所选位置，填写 `Download` 等相对路径可限定扫描范围。共享存储的授权入口位于扫描设置内。

扫描结束后选择索引范围，输入文件名的一部分。可组合 `name:"Main Activity.kt"`（完整名称）、`prefix:Main`（前缀）、`ext:kt`、`path:"src/Feature A"` 和 `size:>=1MiB` 中适用的条件。名称匹配支持中文和字面标点。搜索框旁的语法按钮列出了各个条件的写法。

按名称、路径、大小或修改时间排序，滚动至下方继续加载。每条结果显示类型和元数据，并可复制完整路径。重扫期间可以继续查询上次发布的索引。文件发生变化后，可手动扫描相同范围来更新索引。

在工具栏将「普通」切换为「Root 模式」，点「连接 Root」，并在设备的 Root 管理器确认授权。连接成功后输入实际绝对目录，再开始扫描。挂载视图会列出当前 Android 用户的应用数据和共享存储入口。目录路径中的符号链接可换成挂载视图列出的实际路径。Root 索引独立保存在应用私有目录，断开后仍可在 Root 模式查询上次发布的结果。

## 在 Windows 上构建并安装

在项目根目录使用 PowerShell，按本机路径调整参数。

```powershell
. ./tools/enter-android-env.ps1 `
  -FlutterSdk 'E:\Projects\.toolchains\flutter' `
  -AndroidSdk 'I:\Software\Android\SDK' `
  -Jdk 'D:\Software Environment\jdk-21.0.9'

flutter pub get
flutter build apk --debug --target-platform 'android-arm64,android-x64'
./tools/install-android-apk.ps1 -Serial '<device-id>' `
  -Apk 'build/app/outputs/flutter-apk/app-debug.apk' -UseRoot
adb -s '<device-id>' shell am start -W -n io.github.eltancex.rtpath/.MainActivity
```

已授权 Root 的开发机通过 `su` 调用包管理器安装，避免等待普通 USB 安装确认。普通设备可省略 `-UseRoot`。安装后应用以自己的普通 UID 运行。需要调试已启动的应用时可用 `flutter attach -d '<device-id>'`。

从首页工具栏打开能力检测，可查看 Android、ABI、应用 UID、SQLite 版本和普通进程的挂载视图。连接 Root 后，扫描设置中的「探测 fanotify」在实际 Root 进程执行，使用两个应用缓存目录做事件夹具。

## 验证

```powershell
flutter analyze
flutter test
```

完成首次 Android APK 构建后，可在已授权 ADB Shell 使用 `su` 的设备上运行真机回归。

```powershell
./tools/verify-ordinary-scan.ps1 -Serial '<device-id>' -Shared
```

脚本通过 `su` 安装独立的 `.testhost` 包并运行两轮测试，验证扫描、查询、滚动和索引重启。Android 11+ 可用 `-Shared` 验证共享存储，第二轮会撤销测试包所获授权并检查索引可见性。省略该参数可单测应用内部目录。

加上 `-Root` 可验证受保护目录、传输断开及 fanotify 探测。此用例要求在 Root 管理器中单独允许 `io.github.eltancex.rtpath.testhost` 使用 Root。

在 arm64 真机比较 10 万和 100 万条的 SQLite 与内存查询，可运行以下命令。脚本将原始结果写入 `.local/artifacts/phase2-performance.txt`。

```powershell
./tools/verify-search-performance.ps1 -Serial '<device-id>'
```

[阶段 3 Root 验证](docs/phase3-root.md) · [阶段 2 搜索验证与性能](docs/phase2-search.md) · [阶段 1 验证记录](docs/phase1-baseline.md) · [阶段 0 验证记录](docs/phase0-baseline.md) · [首版实现步骤](docs/v1-implementation-steps.md) · [首版设计](docs/v1-design.md)

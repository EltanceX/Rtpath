# RtPath

RtPath 是面向开发者的 Android 文件搜索项目，采用 Flutter、Kotlin 和 C++。当前版本可在普通应用权限下扫描目录、保存文件名索引并搜索已有结果。

## 使用

在首页打开扫描设置，选择应用自有目录或共享存储。相对目录留空时扫描所选位置，填写 `Download` 等相对路径可限定扫描范围。共享存储的授权入口位于扫描设置内。

扫描结束后选择索引范围，输入文件名的一部分。搜索支持中文与字面标点，也可复制结果的完整路径。重扫期间可以继续搜索上次发布的索引。文件发生变化后，可手动扫描相同范围来更新索引。

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

从首页工具栏打开能力检测，可查看 Android、ABI、应用 UID、SQLite 版本和存储入口的可见性。探针在应用临时目录验证原生文件读取及 inotify 事件，并在内存数据库执行 FTS5 trigram 查询。

## 验证

```powershell
flutter analyze
flutter test
```

完成首次 Android APK 构建后，可在已授权 ADB Shell 使用 `su` 的设备上运行真机回归。

```powershell
./tools/verify-ordinary-scan.ps1 -Serial '<device-id>' -Shared
```

脚本通过 `su` 安装独立的 `.testhost` 包并运行两轮测试。Android 11+ 可用 `-Shared` 验证共享存储，第二轮会撤销测试包所获授权并检查索引可见性。省略该参数可单测应用内部目录。本机额外验证产物可放在 `.local/`。

[阶段 1 验证记录](docs/phase1-baseline.md) · [阶段 0 验证记录](docs/phase0-baseline.md) · [首版实现步骤](docs/v1-implementation-steps.md) · [首版设计](docs/v1-design.md)

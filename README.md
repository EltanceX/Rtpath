# RtPath

RtPath 是面向开发者的 Android 文件搜索项目，采用 Flutter、Kotlin 和 C++。当前工程可运行阶段 0 的能力检测页。

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

能力页报告 Android、ABI、应用 UID、SQLite 版本和各存储入口的可见性。在应用自己的临时目录验证文件读取及 inotify 事件，在内存数据库执行 FTS5 trigram 查询。Root 侧 fanotify 探针随 Root 扫描后端接入。

## 验证

```powershell
flutter analyze
flutter test
```

`flutter test integration_test/capability_test.dart -d '<device-id>'` 会由 Flutter 执行普通 ADB 安装，适用于已允许该方式的测试设备。本机路径和额外验证产物可放在 `.local/`。

[阶段 0 验证记录](docs/phase0-baseline.md) · [首版实现步骤](docs/v1-implementation-steps.md) · [首版设计](docs/v1-design.md)

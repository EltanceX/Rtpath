# RtPath 阶段 0 验证记录

验证日期为 2026-11-22。Android Debug APK 已构建并在 Android 16 arm64 真机运行。阶段 0 的双 ABI 构建、应用进程探针和启动验收通过。

## 工程和构建

| 项目 | 验证值 |
| --- | --- |
| 应用 ID | `io.github.eltancex.rtpath` |
| Flutter / Dart | 3.47.9 / 3.13.7 |
| Gradle / AGP / Kotlin 插件 | 9.3.1 / 9.1.0 / 2.4.0 |
| Gradle JDK / JVM 目标 | 21.0.9 / 17 |
| Android API | minSdk 29，compileSdk 36，targetSdk 36 |
| 原生工具 | NDK 28.2.13676358，CMake 3.22.1，C++20 |
| 打包的 SQLite | `androidx.sqlite:sqlite-bundled:2.6.2`，真机返回 SQLite 3.50.1 |
| Debug APK | 已检查 `arm64-v8a` 和 `x86_64` 均包含 Flutter、RtPath JNI 和 SQLite JNI 库 |

本次 APK 在 `.local/artifacts/rtpath-stage0-debug.apk`。该副本由默认应用入口构建，独立于集成测试生成的 APK。本次 SHA-256 为 `6847119d140778b1ed1a3a57094d0e07aa41e2876699485c650a275f586cbd90`。

## 真机结果

设备为 Xiaomi sheng，Android 16 / API 36，arm64-v8a，内核 5.15.178。探针通过 Flutter 的 MethodChannel 在普通 Android 应用进程执行。原生文件操作限于应用缓存下本次创建的夹具，探测其他存储入口时只尝试列目录。SQLite 探针使用内存数据库。

| 检查 | 结果 |
| --- | --- |
| Flutter 静态检查与界面测试 | 通过，界面测试覆盖普通权限受限的显示 |
| 原生文件探针 | 通过，`readdir` 找到夹具，`fstatat` 校验类型和大小，`openat` 读取标记内容 |
| inotify 探针 | 通过，收到创建、写关闭、改名两端及删除事件，改名 cookie 一致 |
| SQLite FTS5 trigram | 通过，实际建表并用含标点的三字符子串匹配中文文件名 |
| 普通权限可见性 | 应用内部和外部专属目录、共享存储根入口可列。所有文件访问未授权，共享根入口可列仅验证该路径本身 |
| 经 su 安装 | KernelSU 已授权的 ADB Shell 通过 `pm install -r` 安装同一份 APK。Activity 正常启动，应用进程 UID 为 10390 |

复现命令和 Root 设备安装入口见 [项目 README](../README.md)。本次集成测试通过普通 ADB 安装执行。x86_64 已完成构建和包内校验，Android 10 及 x86_64 运行验证留待首版设备矩阵。Root 侧扫描及 fanotify 探针在接入 RootService 后验证。

[首版实现步骤](v1-implementation-steps.md) · [首版验证](v1-validation.md)

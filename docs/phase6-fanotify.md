# 阶段 6 · Root fanotify

## 选择监听后端

显式连接 Root 后，每次为范围建库或手动校验时，RootService 先尝试建立 fanotify 文件系统级标记。探针在该挂载上的 RtPath 自有缓存生成临时夹具，验证文件创建、删除、写入、关闭写入和属性变更，还验证文件与目录跨父目录移动时 `FAN_RENAME` 同时提供旧、新父目录句柄和名称。探针使用与实际监听相同的事件解析器，并从目标挂载打开父目录句柄、验证路径。

只有探针完整通过的范围使用 fanotify。缺少同挂载的可用应用缓存、内核或权限不支持、事件不完整或句柄无法解析时，选择 inotify。FUSE 路径直接使用 inotify 并显示部分覆盖。普通模式继续使用 inotify。Root 索引状态显示实际后端、目录数或文件系统标记数，以及适用的回退原因。 [fanotify_init](https://man7.org/linux/man-pages/man2/fanotify_init.2.html) · [fanotify_mark](https://man7.org/linux/man-pages/man2/fanotify_mark.2.html)

## 增量与恢复

- 在开始枚举前建立监听，基线发布前回放已排队的变更。文件系统标记可覆盖枚举过程中新增的目录，标记接收的事件随后按应用选定的扫描路径和挂载边界过滤。
- 解析文件系统 ID、父目录句柄和原始文件名字节。通过 `open_by_handle_at` 和固定扫描根核对路径。跨范围移动只处理范围内的一侧，同范围两侧纳入同一批事务。目录移动沿用原有的目标子树枚举，包括目录下的现有文件。
- 数据库事务、索引修订、扫描器自写入过滤及 Flutter 刷新由两种后端共享。收到 fanotify 队列溢出、事件格式错误或句柄定位缺口后，保持最后一次已提交索引可查，并核对原扫描根的设备、inode 和挂载 ID。身份一致时用新 inotify 会话重建基线。挂载或根目录身份已改变时停止监听，可发起显式校验。 [fanotify 事件格式](https://man7.org/linux/man-pages/man7/fanotify.7.html)

## 验证结果

| 环境 | 后端 | 已验证 |
| --- | --- | --- |
| Xiaomi sheng，Android 16 / API 36，KernelSU，F2FS | inotify | 实际 RootService 的 `fanotify_init` 返回 `ENOSYS`，界面状态报告回退。保护范围内的文件新建、改名、删除、非空目录跨父目录移动及历史查询通过。 |
| QEMU x86_64，Alpine Linux 6.12.115，tmpfs | fanotify 和 inotify | 用同一原生夹具比对入队路径，覆盖跨范围移动、同名前缀的范围外目录、目录移动、数据库伴随文件过滤。实际生成超过内核队列容量的事件并识别 `FAN_Q_OVERFLOW`。 |

Linux 原生夹具使用一个文件系统标记或三个目录 watch。各取 100 次文件写入样本，从开始写入计到原生路径入队。单轮 P95 为 fanotify 450.62 µs、inotify 212.86 µs。该数据来自 QEMU，包含写入与原生事件处理。Android 上 fanotify 到 SQLite 提交的时延、应用内存及真实负载下的覆盖率还需要一台通过探针的设备验收。Android 集成测试会按实际选中的后端构造队列溢出，并检查重建后使用 inotify。

在小米真机上，两轮集成回归各通过 14 项。Root inotify 夹具的 100 次新建或删除，从写入完成到索引可查的 P95 为 51.72 ms，到 Flutter 可见为 272.86 ms。原始 Android 与 Linux 日志分别保存在 `.local/artifacts/rtpath-phase6-device.txt` 和 `.local/artifacts/rtpath-phase6-linux.txt`。

日常 Debug APK 包含 `arm64-v8a` 和 `x86_64`，通过 `su` 安装并启动成功。路径为 `.local/artifacts/rtpath-stage6-debug.apk`，SHA-256 为 `3c3e337d4bc812e7f6c01720df1b27ce237d1437861cd357f450f5291c4e2c41`。

## 复现

```powershell
. ./tools/enter-android-env.ps1 -FlutterSdk 'E:/Projects/.toolchains/flutter' -AndroidSdk 'I:/Software/Android/SDK' -Jdk 'D:/Software Environment/jdk-21.0.9'
./tools/verify-ordinary-scan.ps1 -Serial '7b9a982f' -Shared -Root -Recovery
flutter analyze --no-pub
flutter test --no-pub
```

在支持 fanotify 的 Linux 上可直接编译原生夹具，以具备文件系统标记和文件句柄访问权限的进程运行。所选测试目录需要支持可解码的文件句柄。

```sh
native=android/app/src/main/cpp
c++ -std=c++20 -O2 -Wall -Wextra -Werror -I "$native" \
  test/native/fanotify_watch_test.cpp "$native/fanotify_watch.cpp" "$native/inotify_watch.cpp" \
  -o /tmp/rtpath-fanotify-test
sudo /tmp/rtpath-fanotify-test /tmp
```

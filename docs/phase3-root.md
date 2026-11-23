# RtPath 阶段 3 Root 扫描验证

## 使用

在工具栏切换到「Root 模式」，点「连接 Root」，由设备的 Root 管理器授权。连接成功后，在扫描设置输入实际绝对目录。挂载视图会展示当前 Android 用户的常见应用数据和共享存储入口。

进入 Root 模式只切换查询范围。Root 连接请求由「连接 Root」触发。断开连接后，可继续在 Root 模式查询上次发布的索引。普通模式的范围列表只显示普通权限下发布的索引。ADB Shell 通过 `su` 安装 APK 的权限与应用的连接授权分别管理。

## 实现

- libsu 6.0.0 在独立的 RootService 启动 C++ 遍历器。服务处于普通应用客户端的绑定生命周期中，使用实际 Root 挂载视图，并在每个 AIDL 调用核对 Root 进程及客户端 UID。
- Binder 交付任务 ID、绝对目录、管道描述符和控制命令。批次走有背压的管道，按任务 ID、协议版本和结束帧校验。遍历固定于所选挂载；目录路径中的符号链接需要换成实际路径，访问失败以覆盖状态显示。
- Root 进程产生文件元数据。普通 UID 把批次写入应用私有目录中的 `root-index.sqlite`，校验完整结果后事务发布。取消和连接遗失会回收暂存版本并保留已发布结果。普通索引继续使用原来的数据库。
- 「探测 fanotify」先观察所选路径的文件系统和文件系统标记能力。若内核支持命名事件，再在应用内部缓存和外部专属缓存中测试创建、移动和删除的事件名。用户所选目录用于只读探测。

## 真机验证

2026-11-23，Xiaomi sheng，Android 16（API 36），arm64-v8a，Linux 5.15.178，KernelSU。APK 使用已获授权的 ADB Shell 经 `su` 安装。测试包首轮未获 Root 管理器授权，界面报告无法连接，普通模式仍能工作。授权后，两轮集成测试通过。

| 检查 | 结果 |
| --- | --- |
| 显式连接 | 普通 UID 10391 无法列出 Root 专属试验目录。切换模式时 Root 保持未连接，点击连接后服务报告 UID 0 和 SELinux 域 `u:r:ksu:s0`。 |
| 扫描和查询 | 从 Flutter 发起 Root 扫描，经批次管道入库 24,001 个文件，数量对账通过。普通进程能查询其中的中文文件名。普通范围列表隐藏该 Root 索引。 |
| 中断 | 取消任务和主动断开正在传输的 Root 连接均保留旧索引，暂存版本未发布。 |
| 重启 | 停止后重新启动普通应用进程，Root 连接保持关闭，Root 模式可直接查询已发布的版本。 |
| 回归 | 通过普通模式、共享目录授权撤回、持久化和搜索分页测试。 |

### 挂载视图

普通应用进程的挂载命名空间为 `mnt:[4026534992]`，内部专属目录是 F2FS（挂载 ID 17872），外部专属和主共享目录为 FUSE（挂载 ID 17867）。Root 进程处于 `mnt:[4026532508]`，其直接读取结果如下。观察值反映这台设备当前的挂载配置，路径别名仍作为各自的扫描范围。

| Root 入口 | 文件系统 | 挂载 ID |
| --- | --- | --- |
| `/data/user/0` | F2FS | 338 |
| `/data/user_de/0` | F2FS | 239 |
| `/data/media/0` | F2FS | 239 |
| `/storage/emulated/0` | FUSE | 7670 |

### fanotify

实际 RootService 在 F2FS 受控目录、F2FS 应用缓存和 FUSE 外部专属缓存均报告 `fanotify_init errno=38 (Function not implemented)`。结果止于初始化，内核配置 `/proc/config.gz` 同时显示 `# CONFIG_FANOTIFY is not set`。这台设备的实时更新将使用后续阶段的 inotify 路径。

本轮运行覆盖 Android 16 arm64 和 KernelSU。x86_64 已构建；其他 Root 管理器、突然杀死 RootService 的故障注入，以及启用 fanotify 内核的挂载标记和事件交付仍待验证。

## 复现

配置 Windows 构建环境并在 Root 管理器允许测试包 `io.github.eltancex.rtpath.testhost` 后运行。[项目 README](../README.md)

```powershell
./tools/verify-ordinary-scan.ps1 -Serial '<device-id>' -Shared -Root
```

双 ABI 日常 Debug APK 保存在 `.local/artifacts/rtpath-stage3-debug.apk`，SHA-256 为 `a334e7e54c076e68165d4e7c1c7621528ab9d180b8089fccd69630cebe2908c1`。

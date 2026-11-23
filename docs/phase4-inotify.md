# 阶段 4 · inotify 增量更新

普通扫描和显式 Root 扫描在成功发布基线后继续监听。普通模式在应用 UID 和挂载视图下读取事件，Root 模式由 RootService 在自己的挂载视图下读取事件。两种模式各保留最近一次扫描的监听范围。选择历史索引仍可搜索，重新扫描对应范围会建立新的监听会话。应用进程退出或 Root 断开后，已提交的索引仍在。

## 实现

- C++ 先打开目录，再通过 `/proc/self/fd/<fd>` 为该目录对象注册 inotify watch，随后枚举。枚举期间分批读取内核事件，按原始路径字节合并，发布基线前回放积累的变更。
- 监听批次配对移动 cookie，核对当前条目状态。文件创建、改写和删除只读取相关路径与父目录元数据。目录移入或改名时，对目的子树注册 watch 并枚举，同时撤销已移出的索引及监听。路径解析保持扫描原有的符号链接和挂载边界。
- 普通 UID 使用 SQLite WAL 写入两个权限独立的索引库。在同一事务内更新条目、路径键、FTS、条目数和修订号。RootService 只通过现有的 Binder 控制与管道传递元数据。Flutter 合并提交后的通知，在滚动停稳后按当前查询和排序同步已加载结果，游标绑定新修订。扫描器过滤自有索引库及其伴随文件。[Root 实时索引与滚动](root-live-scroll.md)
- 监听状态记录已注册目录数、失败数和已读取的事件序号。内核队列或应用待处理队列溢出、扫描根失效或 Root 连接中断时，停止该会话并保留已发布结果。FUSE 视图始终标为部分实时覆盖。

## 真机验证

Xiaomi sheng，Android 16 / API 36，Linux 5.15.178，arm64，KernelSU。测试通过 `su` 安装到独立测试包 `io.github.eltancex.rtpath.testhost`。普通共享存储和 Root 监听分别使用 `/storage/emulated/0` 与 `/data/media/0`。RootService 的 UID、SELinux 域和挂载视图见[阶段 3 Root 验证](phase3-root.md)。

| 场景 | 验证结果 |
| --- | --- |
| 普通内部存储 | 文件创建、改写、原子覆盖、删除、跨父目录改名、子树移入和移出均更新索引。移入及改名后的子目录继续接收事件。 |
| SQLite 和 Flutter | 普通更新沿用原 generation 并增加 revision，旧游标要求重置。搜索框保持当前查询，新建结果自动出现，删除后自动消失。最终一轮新建样本约 36 ms 可查、158 ms 显示。 |
| 枚举期并发修改 | 16,000 个文件扫描期间重命名目录，再删除和新增文件。首次发布的 16,001 条记录（含子目录）与独立遍历一致。随后移动扫描根，监听停止，最后修订仍可查。 |
| Root 保护范围 | 在含 24,001 个保护文件的范围内，通过管道验证实时创建、改名、删除。主动断开后保留最后修订。 |
| 进程重启 | 历史索引可搜索，监听状态需通过重新扫描建立。 |

### 共享存储的写入入口

下表表示测试变更后在 900 ms 观察窗口内，搜索结果是否达到预期。原生视图和 FUSE 视图各维护一份范围。该轮 Root 原生视图为 F2FS，mount ID 239。普通 FUSE 视图 mount ID 为 17867。

| 写入入口 | 监听视图 | 创建 | 改写 | 改名 | 删除 |
| --- | --- | --- | --- | --- | --- |
| 普通应用经 FUSE | 普通 FUSE | 是 | 是 | 是 | 是 |
| 普通应用经 FUSE | Root 原生 | 是 | 是 | 是 | 是 |
| Root 直写 `/data/media/0` | 普通 FUSE | 是 | 否 | 否 | 否 |
| Root 直写 `/data/media/0` | Root 原生 | 是 | 是 | 是 | 是 |

普通 FUSE 重扫能恢复本次夹具的名称集合。直写将样本由 4 字节改为 7 字节后，FUSE 重扫仍可能读到 4 字节。试验中的 `AT_STATX_FORCE_SYNC` 也未使该设备的 FUSE 读到新大小。Root 原生范围重扫后，名称和大小与两种入口的实际写入一致。

### 复现

```powershell
. ./tools/enter-android-env.ps1 -FlutterSdk 'E:/Projects/.toolchains/flutter' -AndroidSdk 'I:/Software/Android/SDK' -Jdk 'D:/Software Environment/jdk-21.0.9'
./tools/verify-ordinary-scan.ps1 -Serial '7b9a982f' -Shared -Root
flutter analyze --no-pub
flutter test --no-pub
```

目录改名当前重新枚举目标子树，成本随该子树大小增长。后续的故障注入、自动恢复与多设备回归见[阶段 5 恢复与设备验收](phase5-recovery.md)。

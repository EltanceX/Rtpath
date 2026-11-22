# RtPath 首版实现方案

首版面向 Android 开发者。用户选择目录或存储范围，建立文件名索引，此后可立即搜索已有结果。监听正常时，文件系统事件驱动索引更新。首次建库、移入未索引目录和发现事件缺口时，按受影响范围扫描。

- 搜索结果包含名称、路径、类型、大小和修改时间，支持复制完整路径。手机用可分页列表，宽屏用列布局。
- 搜索默认匹配文件名子串，支持 `ext:kt`、`path:/storage/emulated/0/Download`、`size:>100MB`。`path:` 按目录边界限定子树，`MB` 使用十进制，也支持二进制单位 `MiB`。支持名称、路径、大小和修改时间排序。
- 普通权限与用户主动授权的 Root 模式共用扫描器和索引逻辑。首版范围为元数据读取、搜索和刷新。内容索引、文件修改和跨重启持久在线监听留待后续评估。

## 组件与权限

| 组件 | 职责 |
| --- | --- |
| Flutter | 搜索框、筛选、分页、扫描和覆盖状态。对连续输入做防抖并丢弃过期结果。 |
| Pigeon / Kotlin 索引服务 | 提供扫描、取消、查询和状态 API。普通 UID 的服务统一持有数据库和写入队列，通过 JNI 启动原生扫描与监听。 |
| C++ 扫描和监听 | 通过 `readdir`、`openat`、`statx` 或 `fstatat` 遍历并读取元数据。流式批量输出条目、状态和问题。记录符号链接本身，默认以挂载边界为限。 |
| libsu RootService | 经过用户授权后，在独立进程运行同一 C++ 核心。Binder / AIDL 处理控制和生命周期，批量元数据和文件事件经过管道发送给普通服务。Root 服务校验调用方与请求范围。 |

DiskSize 可作为扫描遍历、JNI、RootService、管道协议和取消流程的参考。参考项目在 `E:\Projects\disksize-android`，入口位于 `android/app/src/main/cpp/core/stream_scanner.cpp`、`android/app/src/main/kotlin/com/example/disksize/root/` 及 `docs/root-mount-namespace.md`。RtPath 的索引围绕全局文件名搜索构建，目录容量聚合、快照对比和硬链接容量去重属于 DiskSize 的用途。

普通模式覆盖应用自有目录和用户授权的共享存储。Android 11+ 的「所有文件访问」仍限制访问其他应用的专属目录。Root 模式记录实际挂载视图和可读范围，并区分挂载隔离、SELinux、用户锁定和访问失败。重叠扫描范围要识别同一视图下的入口别名。原生共享存储视图和 FUSE 视图分别验证后再决定如何归并。Root 索引和普通索引隔离，Root 索引默认仅在 Root 范围查询中显示，数据库存于应用私有且不进入系统备份的位置。 [Android 存储权限](https://developer.android.com/training/data-storage/manage-all-files)

## 索引与查询

- 扫描范围记录路径、存储卷、Android 用户、访问模式和当前活跃版本。挂载 ID 仅用于当前视图的边界判断。目录以 ID 关联父目录，目录项按父目录和原始名称区分。保留原始名称字节，另存可显示、可搜索的文本。每条路径独立可搜，硬链接可共享已核实的文件身份和元数据。
- 普通 UID 服务使用 SQLite WAL 和单写入队列，以预编译语句分批入库。优先验证 AndroidX 打包的 SQLite 是否在最低支持版本提供 FTS5 trigram，再锁定依赖。B-tree 支持精确、前缀和结构化筛选，FTS5 支持字面子串。名称索引的普通表和 FTS 表在同一事务内更新。 [FTS5 trigram](https://sqlite.org/fts5.html#the_trigram_tokenizer)
- 1–2 字符查询按排序键分批检查候选，从游标继续，即使当前一批没有匹配结果也要返回可继续查询的状态。必须能继续查到所有匹配项；UI 区分已查无结果和仍有范围待查。测试中文单字、双字、标点、大小写和通配符字面量。
- 分页按排序键和条目 ID 保持确定顺序。游标绑定查询条件、范围、索引版本和已发布修订号；遇到修订变化，界面合并刷新请求并重新取页。目录移动时只修改目录本身的父 ID 和名称，返回结果时解析路径。路径筛选和排序要以新目录关系为准，相关缓存随同失效。

## 实时维护与恢复

1. **建立基线。** 创建监听后再枚举。使用 `inotify` 时，打开每个目录后先注册 watch，再列出其子项。注册时核对 watch 对应的目录与已打开的目录身份一致，避免路径被替换时监听错对象。持续消费事件并缓存或标记待校验目录，通过任务 ID 将事件与本轮扫描关联。枚举结束后按已读取的事件位置校正待发布索引，切换活跃版本，继续消费后续事件。旧版本在切换前可查询。
2. **应用变更。** 统一接收创建、删除、移动、写入、属性变更和事件缺口。写入以 `CLOSE_WRITE` 为主，长时间打开的写入可合并 `MODIFY` 更新。对事件路径重新读取当前状态，处理重复事件、路径复用、写后删除以及临时文件 rename 覆盖。发布后通知 Flutter 合并刷新。删除、移动和 FTS 更新与目录项变更在同一事务提交。
3. **处理目录移动。** `inotify` 通过 cookie 配对旧、新位置；`fanotify` 有 `FAN_RENAME` 时用事件携带的旧、新父目录句柄和名称定位。通过文件系统与父目录句柄映射找到索引目录。配对或定位失败时复核已知父目录。移入未索引子树时先挂监听，再枚举该子树；移出时撤销该子树在当前范围内的索引和监听。
4. **恢复覆盖。** 局部监听失败只标记并复核相关目录。队列溢出、监听进程失联或挂载视图改变时，将受影响的监听范围标为待校验。若多个范围共用已溢出的监听队列，则共同标记。重建覆盖和校验完成后再恢复实时状态。遇到磁盘不足、取消或进程死亡，保留已提交结果。首次遇到不可读子树可发布有明确覆盖标记的部分结果；已有健康基线时，仅根据成功枚举的范围确认删除，未知子树保留上次可用记录。
5. **接入 fanotify。** 首版兼容路径为 `inotify`。在实际 Root 服务进程中按文件系统验证 `fanotify_init`、`FAN_MARK_FILESYSTEM`、目录项 FID/名称报告及事件交付。通过能力验证的范围可启用 fanotify。标记需要 `CAP_SYS_ADMIN`；同一文件系统可能通过多个挂载可见，事件仅应用到配置的范围。较旧内核可验证分离的移动事件并复核父目录。无法取得所需事件时使用 inotify。 [fanotify_mark](https://man7.org/linux/man-pages/man2/fanotify_mark.2.html) · [fanotify_init](https://man7.org/linux/man-pages/man2/fanotify_init.2.html)

实时状态依赖活跃的监听进程和当前范围的覆盖情况。Linux 通知队列与持久化的 NTFS USN Journal 有不同的恢复语义，监听停止期间的变化需要通过校验找回。两个 Linux 接口均可能漏报 `mmap` 写入，目录时间戳也无法覆盖已有文件的全部元数据变化。界面分别显示扫描中、实时更新、部分覆盖、待校验和暂停，以及最近一次完整校验时间。 [inotify](https://man7.org/linux/man-pages/man7/inotify.7.html) · [fanotify](https://man7.org/linux/man-pages/man7/fanotify.7.html) · [NTFS USN Journal](https://learn.microsoft.com/en-us/windows/win32/fileio/change-journals)

[首版验证](v1-validation.md) · [首版实现步骤](v1-implementation-steps.md)

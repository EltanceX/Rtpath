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

普通模式覆盖应用自有目录和用户授权的共享存储。Android 11+ 的「所有文件访问」仍限制访问其他应用的专属目录。Root 模式记录实际挂载视图和可读范围，并区分挂载隔离、SELinux、用户锁定和访问失败。Root 索引和普通索引隔离，Root 索引默认仅在 Root 范围查询中显示，数据库存于应用私有且不进入系统备份的位置。 [Android 存储权限](https://developer.android.com/training/data-storage/manage-all-files)

### 范围身份和访问视图

- 持久范围由卷身份、Android 用户、访问模式及选定根标识。运行时另外记录监听进程、挂载命名空间、挂载 ID 和根目录身份。重连后重新探测挂载和权限。挂载身份有变化时结束上一监听会话，并校验受影响范围。
- 普通监听在执行普通扫描的进程和视图里运行。Root 监听与 Root 扫描使用同一 RootService 和挂载视图。将 `/storage/emulated/<user>` 与 `/data/media/<user>` 作为两个实测入口。只有对当前用户和卷验证映射及事件交付后，才按产品所选的展示路径归并，保持已选其他用户和可移动卷的边界。参见[Anything 的路径映射](open-source-references.md#anything)。
- 控制通道携带范围和任务 ID。数据通道批量输出元数据和变更。对每条记录校验来源会话、范围和路径边界。Root 服务只向索引服务交付授权范围的元数据。

## 索引与查询

- 每个范围记录当前活跃索引版本。目录以 ID 关联父目录，目录项按父目录和原始名称区分。保留原始名称字节，另存可显示、可搜索的文本。每条路径独立可搜，硬链接可共享已核实的文件身份和元数据。
- 普通 UID 服务使用 SQLite WAL 和单写入队列，以预编译语句分批入库。优先验证 AndroidX 打包的 SQLite 是否在最低支持版本提供 FTS5 trigram，再锁定依赖。B-tree 支持精确、前缀和结构化筛选，FTS5 支持字面子串。名称索引的普通表和 FTS 表在同一事务内更新。 [FTS5 trigram](https://sqlite.org/fts5.html#the_trigram_tokenizer)
- 分页游标绑定查询条件、范围、活跃索引版本和已发布修订号。遇到修订变化，界面合并刷新请求并重新取页。阶段 2 从父目录关系生成相对路径排序键，以同一键做路径过滤。接入目录变更时，路径排序键与父目录关系需要在同一已发布修订下保持一致。

### 查询契约

| 输入 | 首版处理 |
| --- | --- |
| 普通文本 | 按文件名进行不区分大小写的字面子串匹配。名称与查询共用 Unicode 正规化及大小写折叠。原始路径字节和展示名称单独保留。 |
| 精确和前缀 | `name:` 匹配折叠后的完整名称，`prefix:` 匹配折叠后的名称开头。含空格的值可加双引号。 |
| 三字符及以上的子串 | 在折叠后的搜索键上使用 FTS5 trigram。将用户文本按 FTS 字面量规则引用后作为绑定参数。短索引和高命中的查询也可以按顺序检查有界候选，控制排序开销。 |
| 一字符或二字符的子串 | 按稳定排序键分批取候选并做字面匹配。游标以最后已检查候选为准。无命中的批次也可继续。只有候选耗尽，才确认该查询已查完。 |
| 结构化筛选与排序 | `path:` 按目录边界限定子树内条目，`ext:` 与 `size:` 作用在条目字段。排序并列时按条目 ID 排序。未记录大小的条目在升序时排在最前，降序时排在最后。 |

应用启动探针在实际打包的 SQLite 上建临时 trigram 表，写入中文和含标点的样本并用 `MATCH` 查询。若能力不可用，使用有界字面量路径维持可搜索性并记录降级，由最低 API 验收确认正式构建的 FTS 能力。首版以 SQLite 为持久索引。用同数据、同过滤和同排序的内存过滤作性能对照，再决定是否为二字查询加入 bigram。参见 [Filet](open-source-references.md#filet)、[Android Everything](open-source-references.md#android-everything)和 [Kerything](open-source-references.md#kerything)。

## 实时维护与恢复

### 建立和发布基线

1. 先开启监听，再枚举。使用 `inotify` 时，打开每个目录后先注册 watch，再列出其子项。注册时核对 watch 对应的目录与已打开的目录身份一致，避免路径被替换时监听错对象。
2. 给每次监听分配会话 ID，按事件读取顺序编号。普通服务拒收旧会话的迟到数据。普通模式在 JNI 批次之间读取事件，Root 模式通过管道传输批次。内核队列与应用待处理队列有容量上限。超限时报告缺口和受影响范围。
3. 枚举结束后，以已读取的事件位置划出本轮追赶边界。校正暂存索引后，在同一事务里切换活跃版本并发布修订。切换前保留旧版查询，随后继续消费同一会话的后续事件。边界前存在未修复缺口时，按部分覆盖或待校验显示。已有可用基线时继续查询旧版，首次建库可发布标明覆盖的部分结果。

### 应用文件和目录变更

- 两种后端统一报告创建、删除、移动、写入、属性变更和缺口。写入以 `CLOSE_WRITE` 为主，长时间打开的写入可合并 `MODIFY` 更新。重复事件、路径重用和临时文件覆盖按当前文件系统状态判定。提交条目与 FTS 变更后通知 Flutter 合并刷新。参见 [FSearch 的事件处理](open-source-references.md#fsearch)。
- 移动先尝试配对，再合并重复路径。`inotify` 使用 cookie。`fanotify` 在支持 `FAN_RENAME` 时用文件系统身份、旧新父目录句柄及名称定位。阶段 4 在同一事务核对移动的源和目的路径，目录移动时先监听再重新枚举目的子树，同时撤销源路径下的索引和监听。索引条目的父 ID、路径筛选键及排序键一同发布。后续可基于身份验证优化同范围目录移动。

### 覆盖状态与校验

按范围公布最近一次完整校验和实时覆盖状态。inotify 记录拟监听的目录数、注册成功数及失败原因。fanotify 记录已标记的文件系统和实测通过的事件类型。对共享存储中已知漏报的写入入口按部分覆盖显示，成功校验时更新时间。参见 [Anything 的共享存储探测](open-source-references.md#anything)和 [Kestrel 的覆盖恢复](open-source-references.md#kestrel)。

| 观察结果 | 校验范围和发布行为 |
| --- | --- |
| 有基线且当前范围已覆盖，队列无已知缺口 | 显示实时更新，按批发布修订。 |
| 注册失败、部分事件漏报或目录暂不可读，位置已知 | 显示部分覆盖，核对相关目录。不可读子树保留上次可用条目。 |
| 内核或应用队列溢出，或失联导致变更范围未知 | 显示待校验。重建失效队列负责的全部范围，切换前旧索引可查。 |
| 用户暂停监听 | 显示暂停。恢复时重新建立监听并校验停机缺口。 |

仅根据成功的核对确认删除。数据库写入失败、取消或进程死亡时保留已提交结果。Linux 通知队列只记录监听存续期间的事件，且可能漏报 `mmap` 写入。目录时间戳仅用于可适用的目录项核对，文件大小和修改时间需要另行验证。 [inotify](https://man7.org/linux/man-pages/man7/inotify.7.html) · [fanotify](https://man7.org/linux/man-pages/man7/fanotify.7.html) · [NTFS USN Journal](https://learn.microsoft.com/en-us/windows/win32/fileio/change-journals)

### fanotify 启用及回退

首版兼容路径为 `inotify`。从实际 RootService 按文件系统验证 `fanotify_init`、`FAN_MARK_FILESYSTEM`、目录项 FID/名称报告和真实事件交付。文件系统标记需要 `CAP_SYS_ADMIN`。同一文件系统可能通过多个挂载可见，处理事件时仍限定在所选范围。较旧内核可验证分离的移动事件，并通过复核已知父目录处理。任一必要事件或路径解析能力缺失时，按该范围回退到 inotify 并报告实际覆盖。 [fanotify_mark](https://man7.org/linux/man-pages/man2/fanotify_mark.2.html) · [fanotify_init](https://man7.org/linux/man-pages/man2/fanotify_init.2.html) · [Kestrel 的文件系统级标记](open-source-references.md#kestrel)

MediaStore generation 可用于后续共享媒体追赶。若接入，按卷保存版本和 generation，仅在提交对应变更后推进。删除、未入库文件和 Root 私有目录仍靠文件系统事件或校验覆盖。参见 [Filet 的 MediaStore 追赶](open-source-references.md#filet)。

[首版验证](v1-validation.md) · [首版实现步骤](v1-implementation-steps.md) · [开源实现参考](open-source-references.md)

# RtPath 开源实现参考

核查日期为 2026-11-22。以下依据标注版本的公开源码和项目文档。Android 上的事件覆盖、性能和资源占用以 RtPath 的同机验证为准。

## Android

### Anything

Anything（MIT）是最接近 RtPath 的对照。它在手机上建立可持久化的普通或 Root 索引，Root 首扫通过 `su` 运行 C 辅助程序，遍历时用 `readdir` 和 `fstatat`，经进程输出传输记录。SQLite 保存快照，搜索在载入内存的条目上匹配。 [项目与许可](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/README.md) · [Root 启动](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/java/dev/fastsearch/android/IndexRootScanner.java#L103-L130) · [扫描器](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/cpp/rootindex.c#L55-L174) · [搜索循环](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/java/dev/fastsearch/android/MainActivity.java#L856-L946)

`FileObserver` 注册上限为 2,048 个目录，事件按路径合并后重新取元数据。Root 模式把共享存储索引路径映射到普通应用可见的共享存储入口来监听，其他 Root 路径可由 Root 工作进程核对。FUSE 跨挂载视图漏事件是源码明确处理的场景。RtPath 由与扫描同权限、同挂载视图的进程监听，单独验证两个共享存储视图，并用等价的内存过滤作为查询基准。 [监听上限](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/java/dev/fastsearch/android/FileIndex.java#L95-L97) · [FUSE 核对](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/java/dev/fastsearch/android/FileIndex.java#L432-L489) · [路径映射和核对](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/java/dev/fastsearch/android/FileIndex.java#L525-L538) · [事件合并](https://github.com/shamrat05/anything/blob/278913c9e650efad9b9a9a30bc142f09ed897a3c/app/src/main/java/dev/fastsearch/android/FileIndex.java#L1005-L1118)

### Filet

Filet（GPL-3.0）打包 SQLite，并实际建临时 FTS5 trigram 表探测能力。目录项按卷、父目录 ID 和名称区分，普通索引服务短前缀查询，FTS 检索三字符以上的候选。RtPath 沿用运行时能力检测和父子目录模型。默认子串语义下，中文一字或二字出现在文件名中间也必须可找到。 [项目与许可](https://github.com/uukjtisa/filet/blob/2b9c8c2c15601e07d4ed8caa2c55d65b4e4d297d/README.md#L352-L354) · [SQLite 能力探测](https://github.com/uukjtisa/filet/blob/2b9c8c2c15601e07d4ed8caa2c55d65b4e4d297d/core-index/src/main/java/dev/niccc2007/filet/index/IndexDb.kt#L136-L194) · [搜索设计](https://github.com/uukjtisa/filet/blob/2b9c8c2c15601e07d4ed8caa2c55d65b4e4d297d/docs/SEARCH.md#L59-L172)

热点目录由 inotify 更新，媒体变更由进程内 `ContentObserver` 触发，恢复前台时用每卷的 MediaStore generation 读取新增或修改的媒体条目，再核对相关目录。删除后的媒体行已不在增量查询中，结果核验和后续扫描可以发现残留条目。RtPath 将其作为后续共享媒体线索，文件系统监听及缺口恢复仍负责完整的文件名索引。 [更新调度](https://github.com/uukjtisa/filet/blob/2b9c8c2c15601e07d4ed8caa2c55d65b4e4d297d/app/src/main/java/dev/niccc2007/filet/index/IndexCoordinator.kt#L36-L54) · [媒体增量](https://github.com/uukjtisa/filet/blob/2b9c8c2c15601e07d4ed8caa2c55d65b4e4d297d/core-vfs/src/main/java/dev/niccc2007/filet/vfs/provider/MediaChanges.kt#L26-L58)

### Android Everything

Android Everything（MIT，v0.1.7）是 Windows 客户端，通过 ADB 按设备流式扫描文件，分批写入 SQLite 暂存表后原子替换已发布的索引。它把查询中的字面量安全地送入 FTS5 trigram，短词另用 `instr()`，通过手动 Index 入口刷新。RtPath 参考其暂存发布和字面量处理，并通过有界候选批次控制短词扫描成本。 [项目和架构](https://github.com/luli395/android_everything/blob/v0.1.7/README.md#L24-L36) · [暂存与发布](https://github.com/luli395/android_everything/blob/v0.1.7/file_indexer.py#L123-L243) · [查询实现](https://github.com/luli395/android_everything/blob/v0.1.7/database.py#L676-L757)

## Linux

### FSearch

FSearch 用 C 遍历目录，并把条目、父目录关联和排序数据序列化到索引文件。inotify 和 fanotify 事件进入同一队列及索引更新逻辑。fanotify 在这里用 `FAN_MARK_ONLYDIR` 逐目录加标记。RtPath 可参照其事件归一化，并按实际后端分别报告目录 watch 或文件系统标记的覆盖。 [0.3.2 的 fanotify 标记](https://github.com/cboxdoerfer/fsearch/blob/0.3.2/src/fsearch_folder_monitor_fanotify.c#L325-L382) · [事件处理](https://github.com/cboxdoerfer/fsearch/blob/d7a5daf31f52cde2977213ee1a6d614df6e5f5a5/src/fsearch_database_index.c#L775-L820) · [索引文件](https://github.com/cboxdoerfer/fsearch/blob/d7a5daf31f52cde2977213ee1a6d614df6e5f5a5/src/fsearch_database_file.c#L642-L750)

### Kestrel

Kestrel 的 Linux Root 守护进程用 `FAN_MARK_FILESYSTEM` 监听文件系统，通过 FID 和名称定位变更。它先开启监听，再用旧快照服务查询，扫描完成后应用事件。同批事件按路径归并，以磁盘最终状态更新。队列溢出时，旧索引在扫描和切换期间仍可查询。RtPath 参考其生命周期，在 Android 上由普通 UID 服务持有和发布索引，并为不同挂载和权限视图记录覆盖。 [文件系统标记](https://github.com/Stolly345/kestrel/blob/ab52cd66f6470d53de9bcbe9bfc339162a32430d/crates/kestrel-indexd/src/fan.rs#L87-L117) · [监听与快照启动](https://github.com/Stolly345/kestrel/blob/ab52cd66f6470d53de9bcbe9bfc339162a32430d/crates/kestrel-indexd/src/main.rs#L228-L261) · [溢出与重扫](https://github.com/Stolly345/kestrel/blob/ab52cd66f6470d53de9bcbe9bfc339162a32430d/crates/kestrel-indexd/src/main.rs#L346-L421)

### Kerything

Kerything 在支持的磁盘上直接读取 NTFS MFT 或通过 libext2fs 扫描 ext4 inode，其他挂载交给通用扫描器。它通过 fanotify 维护在线索引，事件流失去可信度时标记索引可能过期。查询用内存 bigram 和 trigram 加速两个字符以上的关键词，单字符线性匹配。RtPath 首版保留基于路径的 Android 遍历。bigram 只作为短词查询实验，先测中文双字查询的收益和索引体积。 [扫描方式](https://github.com/Reikooters/kerything/blob/15e3b1356b8781c6828cf798f7a8d8ff041b9dd5/README.md#L6-L25) · [实时更新与搜索](https://github.com/Reikooters/kerything/blob/15e3b1356b8781c6828cf798f7a8d8ff041b9dd5/README.md#L97-L171)

## 本地实现基线

DiskSize 的普通 UID 入库、原生扫描、Root 挂载视图和测试夹具仍是 RtPath 接入 Android 的主要参考。代码和设备记录在 `E:\Projects\disksize-android`。已有基准应保留各自的测试口径，RtPath 使用自己的索引和样本重新测量。 [扫描代码](E:/Projects/disksize-android/android/app/src/main/cpp/core/stream_scanner.cpp) · [Root 挂载视图记录](E:/Projects/disksize-android/docs/root-mount-namespace.md) · [性能验收](E:/Projects/disksize-android/docs/scan-performance-acceptance.md)

[首版实现方案](v1-design.md) · [首版验证](v1-validation.md) · [首版实现步骤](v1-implementation-steps.md)

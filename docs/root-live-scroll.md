# Root 实时索引与滚动

## 排查结果

在 Xiaomi sheng（Android 16、Linux 5.15.178、KernelSU）的旧版 `/data/data` 已发布索引中，读取到 191,883 条记录及累计 revision 4,633。搜索结果包含 RtPath 自己的 `root-index.sqlite`、`-wal`、`-shm`。监听器会接收 WAL 写入，提交文件元数据变更时又写入 WAL。每次提交推进 revision 后，Flutter 原本会重建搜索页，并最早在 60 ms 后重新查询。追加分页遇到旧游标则重启查询并跳回顶部。

## 修复

- 扫描器在当前进程的挂载视图中使用设备 ID 和 inode 识别 RtPath 的数据库目录。基线枚举、子树补扫和 inotify 事件入队都过滤该目录中的两个索引库及其 SQLite 伴随文件。其他目录的同名文件仍会正常索引。
- Flutter 在拖动和惯性滚动期间合并索引通知。停稳约 150 ms 后，按新版本重新加载已有结果和挂起的下一页。分页结果须来自同一个 generation 和 revision。结果内容相同时只更新游标和版本，复用已有结果列表。
- 已有 `/data/data` 历史索引可以通过「连接 Root」和「校验并恢复实时更新」清理旧的数据库条目，并重新开启监听。

## 验证

隔离测试包分别从 `/data/data` 和 `/data/user/0` 扫描自己的 `no_backup`。确认数据库与 WAL、SHM 文件存在且未进入查询结果，子目录中的同名文件仍能查询和改写，直属的测试文件连续四次写入均可查。两种入口的 revision 均从 1 增至 5，随后在 2 秒观察窗口内保持为 5。

Flutter widget 测试覆盖已加载两页时游标过期、滚动中接收连续通知，以及停稳后从最新版本加载三页。刷新保留原来的滚动偏移。

同轮 Debug 真机回归在列表静止时分别测量普通和 Root 夹具的 100 次新建或删除。变更到索引可查的 P95 分别为 53.21 和 54.61 ms，到 Flutter 可见的 P95 分别为 263.37 和 273.37 ms。

### 完整范围的滚动抽测

在同一台手机安装日常 Debug APK，重新校验已发布的 `/data/data` 索引。应用报告实时监听 20,344 个目录。以名称升序显示全部结果，在 60 Hz 刷新率下各做六次 900 ms 的 ADB 滑动，上下交替。用 SurfaceFlinger 记录 Flutter SurfaceView 的实际呈现时间，按相邻帧间隔的平均值估算 FPS。断开 Root 后复用相同索引。

| 状态 | 样本间隔数 | 估算 FPS | 帧间隔 P95 | 超过 25 ms |
| --- | ---: | ---: | ---: | ---: |
| 实时更新 | 366 | 59.4 | 16.67 ms | 4 |
| 断开 Root | 370 | 59.4 | 16.67 ms | 4 |

本轮是日常 Debug 短时抽测，使用当时的系统后台负载。旧版约 25 FPS 来自用户实测，未在相同脚本和负载下取样。

日常 APK 路径为 `.local/artifacts/rtpath-root-live-debug.apk`，包含 `arm64-v8a` 和 `x86_64`。SHA-256 为 `95dbd68c203376fd0d8e34fb70206b7fb30d6a8f49e50bce17c01a2ab4053df0`。

### 回归命令

```powershell
./tools/verify-ordinary-scan.ps1 -Serial '7b9a982f' -Shared -Root -Recovery
flutter analyze --no-pub
flutter test --no-pub
```

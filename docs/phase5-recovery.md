# 阶段 5 · 恢复与设备验收

## 恢复行为

目录 watch 注册失败时，界面标记部分实时覆盖。监听器每两秒轮换尝试恢复一个失败目录。注册成功后在 watch 保护下重新枚举该子树，按一次事务替换对应条目。旁支继续接收事件，活跃 generation 保持原值，提交后 revision 前进。

内核或应用事件队列溢出时，丢弃未提交的增量，保留可搜索的最后一版。重建前重新核对扫描根的挂载 ID、设备 ID 和 inode。身份一致时自动重建这个范围，发布后 Flutter 用新版本刷新当前查询。短时间内连续失效最多自动重试两次。根目录 watch 重新获得注册时也按范围重建。

挂载身份改变、权限失效、磁盘写入失败、RootService 中断和应用进程重启后，用户可从历史索引发起 **校验并恢复实时更新**。普通共享索引仍受当前存储授权限制。Root 模式需要先恢复显式 Root 连接。普通 UID 负责索引提交，RootService 的管道只传元数据和监听状态。

## 功能验收

真机为 Xiaomi sheng，Android 16 / API 36，arm64-v8a，Linux 5.15.178，KernelSU，内部目录为 F2FS。普通和 Root 分开验证。最低版本为 Android 10 / API 29 x86_64 AOSP 模拟器，Linux 4.14.175，内部目录为 ext4。两端的 SQLite 版本为 3.50.1，常规和重启回归均通过。

| 场景 | 方法和结果 |
| --- | --- |
| watch 上限 | 隔离测试包在注册处注入 `ENOSPC`。限制解除后局部补扫 1 个目录、2 条记录（含目录本身），真机等待 2,024 ms，遍历与传输 3 ms。未受影响的旁支继续更新，补扫后与独立遍历对账。 |
| 应用队列溢出 | 将待处理路径上限调低，再生成多条真实 inotify 事件。旧版本在恢复期间可查，自动重建 1 个目录、12 条记录。真机 387 ms，Flutter 自动显示新结果。 |
| 内核队列溢出 | 暂停测试 RootService，用两条交替路径填满 16,384 个事件槽，继续服务后实际收到 `IN_Q_OVERFLOW`。自动重建 1 个目录、3 条记录，383 ms。 |
| 挂载变化 | 在受控 Root 目录上接入 bind mount，再在监听仍存续时卸载。两次身份变化均停止旧监听并保留已发布结果，显式校验后发布当前挂载视图。 |
| RootService 突然死亡 | 对测试服务进程发送 `SIGKILL`。断线期间旧库可查，校验需要重新连接。重新授权连接后校验，离线期间写入的文件可查。 |
| 目录和共享存储权限 | 对应用自有目录执行 `chmod 000`，读失败时保留老版本。还原为 `700` 后校验并对账。真正撤销测试包的共享存储 AppOp 后，相关索引对普通查询隐藏。 |
| SQLite 空间不足 | 独立临时库用 `max_page_count` 触发真实 `SQLITE_FULL`。事务中先删历史条目再写入新条目，失败后旧条目与 revision 保持原状。放宽上限后重试并成功发布。 |
| 取消与应用重启 | 取消重扫保留已发布 generation。强制停止再启动后可查历史索引，从原范围发起校验可补入间隔期间的变更。Root 历史索引在重新连接前可查。 |
| 共享存储 | 复测普通 FUSE 与 Root 原生视图。Root `/data/media/0` 收到两种入口的四类测试变更；普通 FUSE 的底层直写漏报和大小缓存仍存在，界面标记部分覆盖。 [阶段 4 共享存储矩阵](phase4-inotify.md#共享存储的写入入口) |

局部和整范围的普通夹具对账比较路径、类型、大小与 mtime。watch 上限用例在测试包注入，系统级 watch 上限保持原值。磁盘空间用例使用独立 SQLite 库页数上限。

## 真机性能

Debug 真机套件在前台使用真实文件系统夹具。基线耗时从开始扫描到发布可见，各记录一轮。热查询计入 Pigeon 往返。首屏从提交精确名称查询到行可见。增量从新建或删除完成到索引可查、再到相应 UI 可见，每种模式合计 100 次，通过测试驱动轮询观察。

| 指标 | 普通 | Root |
| --- | ---: | ---: |
| 建库条目 / 耗时 | 10,041 / 1.130 s | 24,008 / 2.224 s |
| 热查询 P50 / P95，100 次 | 1.15 / 2.03 ms | 1.03 / 2.21 ms |
| 首屏 P50 / P95，10 次 | 50.75 / 66.30 ms | 36.87 / 53.91 ms |
| 增量可查 P50 / P95，100 次 | 52.58 / 55.70 ms | 48.64 / 56.39 ms |
| 增量可见 P50 / P95，100 次 | 173.69 / 190.70 ms | 165.32 / 186.40 ms |

套件结束前应用 PSS 为 608,368 KiB，包含 Debug Flutter 和整套集成测试的资源；RootService PSS 为 73,689 KiB。同一快照中普通主库 / WAL 为 144,601,088 / 5,982,272 字节，Root 主库 / WAL 为 151,822,336 / 17,629,512 字节。它们是含多轮回归历史范围的数据库文件体积。干净库体积由 Profile 合成基准单独报告。

### Profile 大索引复测

同一手机用阶段 2 的合成输入预热后重跑，比较 SQLite 与内存结果并对账所有按名称和大小排序的页面。建库含提交和 WAL 检查点，每种规模一轮。组合过滤计时为后端查询首批。 [阶段 2 性能口径](phase2-search.md#性能口径)

| 指标 | 10 万条 | 100 万条 |
| --- | ---: | ---: |
| 合成建库 | 9.492 s | 83.589 s |
| 主库体积 | 71,442,432 B | 711,421,952 B |
| SQLite / 内存对照 PSS | 36,326 / 53,814 KiB | 39,363 / 195,754 KiB |
| SQLite 组合过滤 P95 | 2.930 ms | 7.489 ms |
| 完整分页对账 | 每种排序 1,000 页 | 每种排序 10,000 页 |

百万条低命中的中文一字和二字查询仍约 1.2 s 才找到样本尾部结果。完整 Profile 输出在复现命令生成的 `.local/artifacts/phase5-profile.txt`。

## 范围与复现

API 29 模拟器回归使用 Flutter 软件渲染。默认 Impeller/OpenGLES 在该 AVD 的一次重启中发生 raster 线程崩溃。真机使用正常渲染路径。其他 Root 管理器、长时间后台保活、真实存储设备写满、重复冷热建库和百万条索引的 Profile 端到端首屏仍需独立验证。目录改名当前仍补扫目的子树。

```powershell
. ./tools/enter-android-env.ps1 -FlutterSdk 'E:/Projects/.toolchains/flutter' -AndroidSdk 'I:/Software/Android/SDK' -Jdk 'D:/Software Environment/jdk-21.0.9'
./tools/verify-ordinary-scan.ps1 -Serial '7b9a982f' -Shared -Root -Recovery
./tools/verify-ordinary-scan.ps1 -Serial 'emulator-5566' -Recovery -Emulator
./tools/verify-search-performance.ps1 -Serial '7b9a982f' -ReportName 'phase5-profile.txt'
flutter analyze --no-pub
flutter test --no-pub
```

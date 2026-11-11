# JarvisDomain：M01 Swift领域核心

没有UI、数据库、网络、模型、商店依赖的Swift Package。当前实际编译目标为Linux x86_64；包声明iOS17/macOS14最低版本只是工程候选，**没有用Xcode/iOS SDK验证**。

## 运行

仓库根目录（Docker daemon可用）：

```sh
./tools/check-domain.sh
```

分开运行：

```sh
./tools/swift.sh --version
./tools/swift.sh test --jobs 2
./tools/swift.sh run --skip-build domain-fixtures /repo/fixtures/domain/m01.json
```

本次使用Swift6.2.1官方镜像，摘要固定于[swift-image.txt](../../../../tools/swift-image.txt)。首次缺少镜像时Docker需联网下载；容器实际编译/运行使用`--network none`，Swift Package没有第三方依赖。`.build`缓存不会加入Git。

已有原生Swift6工具链时，可在本包目录执行`swift test --jobs 2`及`swift run domain-fixtures ../../../../fixtures/domain/m01.json`。Mac上的Xcode/iPhone测试仍需单独完成；鸿蒙端需要ArkTS实现消费同组JSON用例，不是把Swift包直接放入卡片。

## 模块

| 文件 | 责任 |
|---|---|
| Values.swift | UUID、正revision/估时、UTC毫秒时刻、本地日期、IANA时区、Clock、标题标量规则 |
| Entities.swift | Task/Project完整基础值对象、序列化与不变量 |
| Rules.swift | 状态迁移、依赖DAG、快照引用完整性 |
| Deadline.swift | Deadline联合类型、有限规则日期解析，不确定性与日期边界 |
| Changes.swift | 三态TaskPatch、批次信封与操作白名单 |
| ChangePlanner.swift | 预览、确认、版本核对、幂等重放、事件草稿与补偿撤销 |
| DomainFixtures | 执行共享JSON输入并报告真实规则结果；失败返回非零 |

所有Decodable入口校验值对象或拒绝不支持字段；未知状态不回退为Todo。序列化采用稳定英文枚举；ID规范化小写UUID；标题去首尾空白，按Unicode标量计1–200，不能以grapheme/字节数混算。

## 调用示意

```swift
import JarvisDomain

let now = try Instant("2026-11-11T10:00:00.000Z")
let planner = ChangePlanner(clock: FixedClock(now))
let snapshot = try DomainSnapshot()
let task = try TaskRecord(
    id: EntityID("11111111-1111-4111-8111-111111111111"),
    title: "整理数据", createdAt: now
)
let command = try ChangeBatch(
    commandId: EntityID("33333333-3333-4333-8333-333333333333"),
    source: .user, issuedAt: now, expectedRevisions: [],
    operations: [.createTask(task)]
)
let preview = try planner.preview(command, in: snapshot)
// 只有Application观察到用户Save/Confirm后，才把本次fingerprint交回。
let plan = try planner.commit(
    preview, current: snapshot, confirmedFingerprint: preview.fingerprint
)
// plan仍是值对象。M02负责原子存储变化、events与appliedRecord。
```

普通手动保存可以在同一次明确Save操作内prepare+确认，不要求额外弹一次确认框；AI批次/删除等必须先展示范围和差异。Domain无法证明“真人点击”，上层Application仍需正确绑定UI权限与来源。

`PatchField`：缺字段=`unchanged`，null=`clear`，其他=`set`；title/description不能null。估时只要求正整数，用户手工长任务可超过一天；AI输出Schema自己的1440分钟上限不扩大成所有手动任务的限制。

## 当前边界与工程折中

- 实现Task创建/patch/状态/依赖/软删除恢复、Project创建/状态；Workspace、合并任务、工时调整、项目正文编辑等由后续用例扩展，不冒充都已实现。
- 已完成任务归档后仍满足前置依赖；归档未完成任务不会变成已完成。
- DateResolver只识别今天/明天/后天、下周一至日、明确ISO日期；“明天下午”仅提供待确认日期提示，其他模糊内容保留原文。不是任意中文自然语言理解器。
- Preview读取全量值快照，commit/undo保守地拒绝任何快照变化，包括无关任务更新。该策略优先防丢数据；M02接入事务read-set时再缩小冲突粒度，并保持回归。
- fingerprint是规范化JSON字节的本地比较表示（Base64），**不是密码学摘要/签名/授权token**，也不记录进日志；其中可能包含任务内容。后端身份、预算或网络鉴权不能使用它。M02可单独计算索引hash，但仍须验证规范化内容一致。
- `prior`必须由M02在事务内读取的AppliedCommand记录提供；重复ID同内容返回原receipt、不重放事件，异内容报冲突。当前没有数据库幂等表，也没有验证数据库并发。
- Undo是新commit：内容可恢复，revision继续前进；新建记录的撤销产生tombstone。已有后续修改则返回UNDO_CONFLICT，不覆盖新内容。
- EventDraft未分配持久事件UUID；M02在同一事务分配/保存。依赖完成override reason保留在草稿，M06后续补充绑定的输入/提案来源。
- Task状态操作按批次顺序做迁移检查，最终还校验引用、DAG和前置条件；因此需要先解除依赖再完成时，应按此顺序给操作，不做推测重排。

校验记录与本阶段未测内容见[阶段报告](../../../../docs/implementation/M01-领域核心.md)。

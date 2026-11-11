# Jarvis ToDo 技术开发文档

版本：TDD 1.0，2026-11-10。需求基线：PRD V1.1。适用条件：中国大陆优先、个人开发、iPhone iOS26、用户报告的原生HarmonyOS5.x/6.x设备；Mac与商店账号条件尚未全部具备。

目标：开发者拿到任一工作包，即可知道其输入、输出、依赖、持有数据、失败行为和验收方式，不必先实现整套产品。

**已开始M01 Swift领域核心开发，当前实现与验证见[阶段报告](../implementation/M01-领域核心.md)。其他模块仍为设计/未实现状态。**示例Schema校验不代表应用、真机、模型或商店已经通过验证。本文中的“必须”为工程约束；“候选/门禁”为仍需验证的外部能力；工程默认参数可配置，不冒充PRD原有要求。

## 阅读入口

| 文档 | 回答的问题 |
|---|---|
| [01 架构与模块边界](01-架构与模块边界.md) | 技术基线、目录、依赖方向、接口、演示结构 |
| [02 领域、数据与事务](02-领域数据与事务.md) | 字段、状态机、日期、确认/撤销、存储、备份 |
| [03 本地核心模块](03-本地核心模块.md) | M01–M04如何逐个实现与验证 |
| [04 AI与语音模块](04-AI与语音模块.md) | M05–M07、Provider、密钥、草稿、ASR |
| [05 计划与执行闭环](05-计划与执行闭环.md) | M08/M12–M14、调度、复盘、专注、Memory |
| [06 购买与托管网关](06-购买与托管网关.md) | M09–M11、API、72h、身份、预算与并发 |
| [07 平台适配与验证](07-平台适配与验证.md) | M00/M15/M16、双平台、准入门禁、画像 |
| [08 实施与验收](08-实施与验收.md) | 单人执行顺序、具体工作包、22项发布追踪 |
| [AI提案Schema](contracts/ai-proposal.schema.json) | 机器可读的AI输出内部契约 |
| [统一错误Schema](contracts/error.schema.json) | 错误结果与恢复信息 |
| [交付校验工具](tools/validate_contracts.py) / [本次记录](交付校验记录.json) | 可复现文档与Schema验证，明确尚未运行的业务/平台测试 |
| [契约示例](contracts/examples/) | 正常、异常、过时版本提案的演示输入 |

## 适用顺序与决策状态

本套文档是**本次开发的工程执行基线**。PRD仍定义产品目标；历史[开发计划](../开发计划.md)、[平台调研](../平台与技术调研.md)与[最新证据](../前置调研结论与信息缺口-2026-11-10.md)保留，不重新套用其中三人团队排期。

冲突处理：安全/数据规则以02为准；AI契约以04及JSON Schema为准；托管鉴权/计费以06为准；用户体验与发布范围以PRD及08的显式映射为准。接口有破坏性变化时，先修订契约版本、示例和消费方测试，再更新模块。不能私自用页面行为覆盖规则。

| 状态 | 已决定 / 暂定内容 |
|---|---|
| 冻结的核心约束 | Local-first；用户确认写入；密钥单独存储；Hosted/BYOK不静默切换；无自建云同步 |
| 工程默认路线 | SwiftUI与ArkUI原生适配，共享协议、规则向量与设计token；单人按平台分阶段落地 |
| 可替换实现 | iOS SQLite wrapper、具体Markdown渲染器、Hosted模型与部署服务，不进入领域API |
| 尚未冻结 | 首个正式发布平台、最低覆盖版本、鸿蒙商用SDK版本、商店商品和¥3价格、Hosted供应商与预算数值 |

不因上述外部决策延迟M01领域与M02存储契约。M00只将实际平台门禁施加到相应适配器与商业发布，**不要求先完成支付审核才能写一个离线任务模块**。

## 模块目录与独立验收

| ID | 职责 / 数据所有者 | 硬依赖 | 独立验收入口 | 范围 |
|---|---|---|---|---|
| M00 | 工具链与平台探针 | 无 | capability-report | 适配器前置 |
| M01 | 领域、状态、命令、日期、变更 | 无 | domain-fixtures | R0 |
| M02 | 数据库、文件、迁移、备份 | M01契约 | repository-conformance | R0 |
| M03 | Todo/Project/Today/手动计划UI | M01/M02 | offline-task-journey | R0 |
| M04 | Notes/Log/Results/历史搜索 | M01/M02；页面接M03 | workspace-demo | R0 |
| M05 | Provider/transport/SecretStore | M01错误约定；不需真模型 | provider-fixtures | R1 |
| M06 | 文字捕获、拆解、合并草稿 | M01/M05；仓储可fake | capture-demo | R1 |
| M07 | CaptureSession/ASR | M01；不硬依赖LLM | speech-demo | R1 |
| M08 | 规则计划、理由、冲突 | M01；仓储可fake | plan-fixtures | R1 |
| M09 | 商店购买证据与归一化权益 | M01；真实适配需M00 | purchase-fixtures | R2 |
| M10 | Hosted主体、试用、预算、模型网关 | M05协议/M09验证接口 | gateway-lab | R2 |
| M11 | 路由、设置、同意、端到端集成 | 已启用的M03–M10 | mode-matrix-demo | R2 |
| M12 | 复盘提案、确认、次日计划 | M01/M05/M08；不硬依赖商店 | review-demo | R3 |
| M13 | 专注Session与日志草稿 | M01；M04接口 | focus-clock-demo | R4，可提前 |
| M14 | Memory/Reflection/项目摘要；增强搜索 | M04/M05；不硬依赖M12 | memory-demo | 核心R3，增强R4 |
| M15 | Widget/卡片/系统入口 | M01命令、M03快照；专注展示可接M13 | surface-demo | R4 |
| M16 | 自愿个性化偏好 | M08/M13接口与自愿反馈 | profile-fixtures | 后续，不阻塞V1 |

硬依赖指接口和规则已确定，不代表依赖服务必须在线。模块的fake是可替换实现；开发解耦不等于验收时可以一直使用fake。

## 交付范围

- R0：离线任务闭环。无AI/商店/麦克风仍可运行；属于内部开发包。
- R1：AI内测。BYOK/模拟Hosted、文字/语音、基础规则计划；不冒充商业上架包。
- R2：PRD第16节22项商业MVP。双端都需对应真实能力及审核证据。
- R3：完整功能章节P0。包括Daily Review、Task Reflection/Memory、项目AI摘要。
- R4：Focus、系统入口、增强搜索、画像等分批增强。基础版权益归属不因延期而变成订阅。

每次交付记录 `NOT_IMPLEMENTED / FAKE_VERIFIED / ADAPTER_VERIFIED / JOURNEY_VERIFIED`。商店审核另记 `NOT_SUBMITTED / IN_REVIEW / APPROVED / REJECTED`，两者不混用。

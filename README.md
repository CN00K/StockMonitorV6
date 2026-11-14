# 股票监测信息采集系统 v6

纯本地 iOS 行情与事件整理终端：行情监测和事件采集只在前台会话内进行；进入后台取消请求/轮询，结束会话并 checkpoint SQLite WAL。没有自建后台、后台常驻、账号体系或远程推送。行情/资讯只在用户操作时直连第三方公开站点；本项目不把请求转发到自有服务器。

本仓库包含合并后的 SwiftUI 界面与功能核心源码，以及 SwiftPM/Python 测试、数据 fixtures、设计 mockup 和来源说明；可从 `README-ui.md` 与 `README-functional.md` 查看原始源码包说明。仓库不包含生成的 IPA、Apple 签名材料或私密凭据；iOS 设备构建按配置手动触发并生成未签名 IPA。

## 当前实现

- SwiftUI 仪表盘提供会话状态、主要指数、自选股增删、报价来源时间/新鲜度、未读信号及已读操作；用户可录入/更新/删除持仓股数与成本价。
- 原批准的 14 类规则族保持原阈值，并新增 4 类功能规则：基于本地限价估算的 `seal_break`、默认关闭的 `main_flow_surge` 与 `late_session_pump`、以及自选股龙虎榜上榜提示。资金流规则默认关闭，阈值分别为每分钟主力净流入人民币 5,000 万元、尾盘每分钟超大单净流入人民币 2,500 万元；这些新增阈值尚未由用户逐项校准。每族可配置启用状态、阈值、确认次数、冷却、交易时段限制与静默时段。
- 规则 checkpoint 在 SQLite 本地保存，包括确认去重游标、冷却/每日触发状态、会话极值、VWAP/SMA/相对强弱窗口、事件去重与板块簇状态；实时行情、完整分钟 bars、信号及 checkpoint 在同一 SQLite 事务提交。规则族配置独立持久化。
- 实时报价使用来源协议与串行 fallback：Sina → Eastmoney → Tencent。每只报价保存来源 ID、采集时间，并标明时间来自 provider 还是仅本地采集；可选解析换手率、量比、PE、市值与东财资金流字段。只有 provider 时间较新（120 秒内）的报价参与报价规则；重复 provider 时间戳不重复计作确认。新增 User-Agent、gzip/deflate、429/403/HTML/无效 JSON 分类、指数退避、熔断和半开探活。
- 指数快照通过同一来源链采集；来源状态显示请求/返回数量、请求次数、来源时间新鲜度和错误。相对强弱规则仅使用上证综指作为已实现基准。
- `FunctionalServiceFactory` 在 core 中复用上述 quote registry，并默认注入 Eastmoney clist 市场扫描、分钟资金流、基本面缓存与其余本地服务；`App/MonitorViewModel` 现采用该 factory 作为唯一 engine/store/event runtime。常规 scan 最多 10 页/1,000 证券，每 15 分钟缓存一次；用户显式触发的扩展 scan 固定 `pz=100`，按 clist 报告 total 推导页数，最多 60 页/6,000 个去重证券，15 分钟缓存，并显示接口 total 对齐或不完整/截断状态；这不是交易所核验的全市场清单。资金流每次轮转最多 2 只、间隔 10 分钟且只返回 120 秒内的数据。基本面最多显式刷新 10 只并写入 SQLite schema v4；动态 PE 不冒充 PE-TTM。行情/scan/flow 仅在前台会话触发，基本面仍是显式调用；rule families 仍按原设置默认关闭。
- 重开时用 Eastmoney `trends2` 拉取 1 分钟历史，并与首个前台行情快照并行；最多请求 50 只股票，host budget 为每秒最多 4 次、每个前台会话至多 50 次历史请求。只评估接口确实返回的完整 bars；分钟历史不是逐笔回放，不能保证恢复离线期间每个事件。
- 用户可按按钮前台采集事件；当前适配器包含 CLS、Eastmoney 新闻、澎湃新闻、gov.cn 政策库搜索、CNINFO 深交所公告和 Eastmoney 龙虎榜摘要。雪球与工信部因当前匿名 API 阻挡/挑战，明确显示 unavailable，不登录、不收集 cookie、不绕过反爬。
- 事件保留源 ID、源条目 ID、源时间戳/抓取时间、原链接、优先级、板块/股票标签与跨源佐证。配置沿用并扩展已审计的 StockAgent P1–P5 collector seed；SimHash 去重、低优先级过滤与板块标签仅在本机运行。
- 当日事件聚类与日报按需从本地 SQLite 即时生成；core runtime facade 提供 Markdown 报告模型、纯 Swift PDF 文件导出及事件 CSV/JSON。Apple PDF 分支用系统 Unicode 字体和宽度换行；Linux 无 UIKit 的测试 renderer 仍用 Helvetica/WinAnsi，中文会替换为 `?`；PNG 尚未实现。`SQLitePortableBackupService` 提供限大小、校验后原子恢复的加密 portable backup/restore（报价、指数、事件、信号及已读状态、自选、规则、持仓、设置，以及满足行数/字节上限时的分钟/日线历史）；超限历史采用全有或全无并在 payload 记录 omission reason。原始响应归档、session ledger 与密钥不随备份迁移。密钥由调用方安全提供，LLM Key 不随备份导出。加密备份文件选择/恢复 UI 尚未接线。SQLite 事件保留 7 天且最多 10 万条。
- 本机事件可按标题、正文、来源、股票代码或板块搜索：SQLite FTS5 trigram 对长度至少 3 的词项做全文检索，短词回退到转义后的 LIKE；旧库通过 `user_version` 迁移并回填索引。搜索只返回 7 日窗口内已保存的事件。
- 成功的公开 HTTP 响应可选归档到本地 SQLite：端点会去掉 query/fragment/user/password，响应体最多 512 KB、每次刷新最多 16 条/2 MiB，总计最多 500 条/10 MiB，保留 7 天；不保存请求头或 query 参数。
- 本机七日健康面板累计 P1 官方来源（gov/CNINFO）请求成功率、解析有效率及用户触发 Analyst 占比，目标分别为 ≥99%、≥80%、≤50%。分母是 P1 请求数、源端候选事件记录数、以及成功 Analyst runs + 未送 Analyst 的去重可见事件数；一个 Analyst run 计 1 次，不按其六个模型请求重复计数。没有样本时 UI 显示“暂无数据”。
- 按需 Analyst 流程匹配现有 `StrategyResult`：supervisor 与技术/基本面/情绪/风险四个 specialist 并行，随后一次 refinement；五路并行返回和最终结果均使用 strict JSON Schema 与本地范围/字段校验。用户触发的核心 coordinator 提供按股票/交易日/endpoint/model/context fingerprint 缓存，并累计六个实际 provider 请求及响应中可用的 prompt/completion/total token 用量；Provider 不返回 usage 时 token 保持 unknown。成功完整分析才入缓存/账本，失败的部分完成调用尚未持久化。SQLite sessions 另有 tick/request/token counters。Endpoint/Model 由用户手动配置，API key 只写入 iOS Keychain（设备本机、解锁时可用）；Key 不进入 SQLite、日志、请求 body、资源或备份。选择股票后必须再次确认才发送所选报价、最多 60 根本地日线和最多 20 条近 7 天匹配事件/未读规则告警。提示会发出六次 HTTPS 请求、可能重复发送该上下文并由 Provider 收费；请求直达配置 endpoint，不经自建后台，进入后台会取消。结果带非投资建议提示。
- 自动事件 LLM enrichment 已由 factory 接入 App 使用的 EventCollector：P1/P2 full、P3 按缺失元数据条件调用、P4/P5 不调用；仅在启动时已有 HTTPS endpoint、model 与 Keychain key 才装配。构造 runtime 不发请求，用户显式刷新事件时才采集/调用；Endpoint/model/key 的设置变更于下次启动应用。Provider usage 写入本地 session ledger；开发测试只用 mock，没有实际外部 API 调用。
- 本地单因子回测只使用当前自选股（没有指数成分股清单时不会扩展 universe），支持 9 个价量因子和 20/60/120 个信号交易日；回测按钮仅读取 SQLite 已缓存日线，缺数据时停止并说明，不拉取新行情。Lab 已展示分层年化收益/波动、零无风险利率 Sharpe、最大回撤、Calmar、胜率、盈亏比、日收益分位数与按月复利。回测后对最高因子组日收益生成确定性 5/50/95 IID bootstrap 包络；相关性按钮只读取最多 540 天已缓存的日线，不访问网络。仍非持仓级净值：不推算换手、基准超额、单票贡献或成交可行性。A 股执行模拟器仍须 opt-in `LocalBacktest.run(..., execution:)`，可按显式配置计入佣金/最低佣金/印花税/滑点、整手、tick 与明确提供的涨跌停不可成交约束；当前每次运行只有一个交易方向，能拒绝无 T+1 可售库存的卖单，但不能模拟配对买卖的完整持仓生命周期。缺少历史成分股、公司行动或价格限制数据时会告警，不伪造成交。

## 规则族与限价边界

以下 14 类按用户批准方案执行，原阈值不变：日涨跌幅 ±3%（2 个不同 provider 报价、同方向冷却 30 分钟）；用户设置绝对高/低价（2 次确认）；完整分钟量能 ≥此前 5 根完整 bar 均量 2 倍（2 根确认、15 分钟冷却）；单分钟成交额 ≥人民币 5,000 万元（15 分钟冷却）；开盘跳空 ±2%（每方向每天一次）；首次刷新本会话已观察高/低点（每方向每天一次）；5/20 分钟 SMA 交叉（2 根完整 bar、每方向每天一次）；价格相对本地 VWAP 偏离 ±1.5%（2 根完整 bar、15 分钟冷却）；单分钟价格速度 ±1%（同方向冷却 10 分钟）；相对已观察高点回撤/低点反弹 3%（30 分钟冷却）；近 30 分钟相对上证综指强弱 ±2 个百分点（2 个窗口确认、30 分钟冷却）；持仓成本浮盈/浮亏 ±5%（30 分钟冷却）；明确匹配自选代码且来源 P1–P3 的重大新闻/公告（每个归一化事件一次）；以及 60 分钟内同板块至少 3 个独立事件、至少 2 个来源并含一条 P1–P3（每个聚类一次）。新增四类在上一节列明，不改变上述 14 类设置。

**当前无逐股权威限价行情源；规则比例已按 2026 官方材料核对。** 沪深主板一般 10%，主板风险警示股自 2026-07-06 起 10%，创业板/科创板 20%，北交所 30%；代码前缀与简称匹配仍是本地启发式，不等于交易所证券分类。公式按前收盘价和 0.01 元 tick 四舍五入，所有结果均明确显示为非权威估算。Runtime 没有上市/退市状态源：若 IPO/退市阶段显式标注则保留 unknown；未提供上市交易日序号时只能显示“假设非 IPO 前五日”。`seal_break` 只统计 App 前台实测到的封板→开板状态转换。来源规则见 [`SOURCE_EVIDENCE.md`](SOURCE_EVIDENCE.md)，不得把估算视作实际委托价或成交价。

## 数据源边界

所有行情、新闻、公告与龙虎榜接口均为公开但非正式/无合同端点；没有核实到服务 SLA、完整性、固定速率或新鲜度承诺。来源可能延迟、限流、变字段或暂时拒绝请求，app 会显示错误/不可用，而不是把失败伪装成“没有事件”。详细证据见 [`SOURCE_EVIDENCE.md`](SOURCE_EVIDENCE.md)。

CLS 依赖可在本机计算的签名参数，站点改版可能使适配器失效；gov.cn 当前接入的是“证券”政策库搜索，不是覆盖所有政府新闻的推送 feed。CNINFO 只对已核实的深交所代码映射查询自选公告，当前没有可靠的上交所代码映射；东方财富龙虎榜只查询最多 10 只自选股的摘要记录，不拉买卖席位明细。雪球接口曾返回 403/400016；普通未认证访问工信部 RSS/新闻候选也遇到 403 JavaScript challenge，因此保持 unavailable，不登录、不拿 cookie、不绕过。

分钟历史补齐的是服务返回的分钟 bars，不是逐笔或完整事件回放；分钟内所有离线异动不能保证恢复。盘中极值仅从本地实际观察到的数据建立，不能推断离线时段高低点。交易日历内置 2022–2026 年经上交所官方年度公告核实的工作日休市日期；深交所原文可直接交叉核验的范围为 2024 全年及 2026 中秋/国庆，其他深交所来源缺口见 [`SOURCE_EVIDENCE.md`](SOURCE_EVIDENCE.md)。Settings 可导入带来源字段的本地 JSON：只接受 HTTPS 上交所/深交所/北交所域名，只写入明示闭市日期并持久保存在本机；导入内容不经 App 独立认证，缺失日期仍 unknown，也没有自动联网更新。周末固定休市；Live Loop 不会假定开市。

前台请求会将必要的查询参数（例如所选深交所股票代码）直接发给对应公开数据源。功能数据仅保存在本机；SQLite 优先使用 App Group 容器，若系统无法取得该容器，则退回到本 App 私有的 Application Support。此时顶部默认显示紧凑提示，点按可展开 App Group 故障详情；数据不会与扩展或其他 App 共享。本 App 仅供信息整理与研究，不构成投资建议。

## 测试与构建

`swift test` 是测试命令。当前 XCTest 覆盖上述功能，并包含分钟指标/VWAP、扫描样本统计、Pearson 与因子相关矩阵、确定性 bootstrap、回测超额收益序列、Sankey/ForceGraph 布局，以及真实 D-6 响应 fixture 的字段/解析契约测试。

本次 UI v2 增加 News 本地日报 PDF 生成/分享与近 7 天 Feed 的类型、P1–P3 和自选标签筛选、Settings 的显式 F10 刷新/通知授权与投递/白名单诊断 JSON 分享、市场页 Workbench 看板/列表与本机来源/会话健康面板，以及 watchlist-aware 股票路由。App Group 不可用时，顶部降级提示默认收起为一行，并可点按展开故障与私有存储说明。健康面板仅读 SQLite 和最近实际观察到的来源状态，区分无样本、部分返回、来源时间未知、过期及失败；不会新增网络请求或补造指标。Feed 筛选仅作用于已加载的最多 100 条本地事件，不推断缺失关联、不新增网络请求。Monitor 未读信号区新增四档本机级别筛选（全部/紧急/警告/提示），仅筛选当前已加载的未读信号；`AlertSignal` 直接提供 `code`、`level`、`createdAt`，而规则族仅能从部分 `ruleID` 间接识别，旧/自定义规则 ID 不保证可映射。状态只含未读信号，无法据此断言规则从未触发，因此不显示猜测的空闲规则状态。使用 Linux Swift 6.4.2（`$HOME/.local/opt/swift-6.4.2/usr/bin`）验证：**259 项 XCTest 全部通过**；21 个 App Swift 文件通过 `swiftc -frontend -parse`；`git diff --check` 通过。当前无 Apple SDK，未做 iOS typecheck、Xcode Preview 或设备视觉验收；本轮没有真实 LLM 调用或外部数据刷新。Codemagic `unsigned-ios` 已从 `main` 提交 `80e72a71055c37b54f0a69f612226e720ffa9ec4` 成功生成未签名 arm64 IPA（build ID `6af823b890e83b09c4fa1ff9`）。

`UserDefaults.standard` 保存 Analyst endpoint/model 偏好与用户手动导入的交易日历 payload（不含行情、持仓或 Provider 密钥）；`Resources/PrivacyInfo.xcprivacy` 已声明 Apple required-reason API `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`。App 启动不请求通知权限；只有用户在 Settings 显式点按授权按钮才会调用系统提示，获准后仍需另行点按通知投递。当前没有相机、麦克风、位置或照片库权限调用。API key 仍由 iOS Keychain 管理，不包含在源码或 workflow 中。

`.github/workflows/build-ipa.yml` 只有 `main` 分支 `workflow_dispatch` 手动触发，且必须输入 `BUILD`；push 不会启动构建。工作流用 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、手动签名模式及空的签名身份/team/profile 设置构建 arm64 iOS 设备版，再把 `.app` 打包成 unsigned IPA；不读取 Apple signing secrets，不创建密钥串、不导入证书，也不嵌入 provisioning profile。Artifact `StockMonitorV6-unsigned-IPA` 保留 14 天，包含 IPA、`StockMonitorV6-signing.entitlements` sidecar、构建 manifest 和 IPA 文件清单。unsigned IPA 没有签名，也没有签名后生效的 entitlements；App Group 仅在 sidecar/源码 entitlement 中声明，必须由用户签名时通过匹配的 provisioning profile 授权。工作流修改需在公开仓库 [CN00K/StockMonitorV6](https://github.com/CN00K/StockMonitorV6) 的 `main` 上提交；XcodeGen 生成及 Apple SDK 设备构建由该手动工作流执行。

`Resources/Assets.xcassets/AppIcon.appiconset` 已包含 1024×1024、不透明 RGB PNG 图标：深蓝背景、青绿色雷达与市场走势，无文字。XcodeGen 将该 catalog 作为 App resource，并通过 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` 指定它；iOS 自行应用圆角遮罩。

`codemagic.yaml` 另提供 `unsigned-ios` 手动工作流，只使用 `mac_mini_m2`，总超时 30 分钟；没有 `triggering` 事件、环境变量组、Apple 集成、证书导入或 publishing。push、PR、tag 不会自动启动此 YAML 工作流。其无签名开关与 Bundle ID/App Group/arm64 校验和 GitHub 工作流一致，并校验编译产物的 AppIcon 名称。连接或手动启动前，必须在 Codemagic 确认使用个人账户、可用免费 M2 分钟足以覆盖这 30 分钟上限且没有其他构建消耗该额度，不启用 billing、不接受任何收费。配置选择 M2 本身不代表账户额度已通过核验；无法确认免费时不得启动。官方说明见 [手动触发规则](https://docs.codemagic.io/yaml-running-builds/starting-builds-automatically/) 和 [免费分钟适用范围](https://docs.codemagic.io/billing/pricing/)。API token 仅用于外部管理请求头，不进入仓库、YAML 或 IPA。

## 已选标识、仓库与 Apple 环境验收

- **仓库：** 项目位于公开仓库 [CN00K/StockMonitorV6](https://github.com/CN00K/StockMonitorV6) 的 `main` 分支。
- **App 标识：** App Bundle ID 为 `com.cn00k.stockmonitorv6`，核心 framework 标识为 `com.cn00k.stockmonitorv6.core`，App Group 为 `group.com.cn00k.stockmonitorv6`。工程配置、entitlements 和 SQLite 路径保持这些标识不变。若 iOS 无法取得配置的 App Group 容器，SQLite 会保存在本 App 私有 Application Support；UI 默认以紧凑提示说明数据仅本机保存、不与扩展或其他 App 共享，并可展开查看详情。该回退不会改变 App Group entitlement，也不会伪称正在使用共享容器。仍需在 Apple Developer 中核对对应 App ID 与 App Group 能力。
- **签名与分发：** 当前目标为 unsigned iOS 设备 IPA，由用户用自己的证书签名。workflow 不需要 Apple Team ID、P12、P12 密码或 provisioning profile，仓库不需要为该 workflow 配置这些签名 secrets。unsigned IPA 在签名之前不能安装；签名时，用户自己的 Apple Developer team 必须能注册 `com.cn00k.stockmonitorv6` 与 `group.com.cn00k.stockmonitorv6`，并提供匹配 Bundle ID、授权该 App Group 且包含目标设备 UDID 的 provisioning profile。artifact 同时给出 entitlement sidecar 供签名时使用。
- **Apple 验收：** workflow 只生成未签名 arm64 IPA；它不执行签名或设备安装。用户签名后仍需在目标 iOS 设备验证 Keychain、App Group、资源加载、前后台暂停/恢复、网络和分享。App Group 在未签名 IPA 中不会作为有效签名 entitlement 生效。
- **LLM Provider：** 必须在设备 App 内配置兼容 Structured Outputs 的 HTTPS `/chat/completions` endpoint、model ID 和 API key，并自行核对 Provider 价格/限额。股票 Analyst 仍要求明确触发与确认；自动事件补充由 App 的显式资讯刷新触发，仅对 tier policy 指定事件调用，并且只在 App 启动时 endpoint/model/Keychain key 已可用时装配。设置更改下次启动生效；开发测试不调用 Provider。
- **App Store 隐私披露：** 若选择 App Store/TestFlight，需另行核实对用户选择发送给其 LLM Provider 的本地材料应如何填写 App Privacy 披露；`PrivacyInfo.xcprivacy` 中的 `CA92.1` 仅声明 required-reason API，不等于完整隐私标签。
- **Core/App 边界：** `FunctionalServiceFactory` 已被 `MonitorViewModel` 用于唯一的 engine/store/event runtime；监测、资讯、日报/事件导出、缓存 Analyst、backtest 本地日线读取和 Lab 研究均复用该 runtime。六标签 shell 已提供 Market/Watch/News/Lab 的实用页面，并保留 Monitor 控制台。Settings 已提供显式 F10 快照刷新、通知权限请求/未读信号投递及白名单诊断 JSON 分享；News 已提供本地日报 PDF 生成/分享。备份仍没有安全口令派生与文件导入/导出流程；所有网络和通知动作仍要求用户点按。
- **数据与平台限制：** Eastmoney 涨停池行结构没有可信实录字段，因此连板数、封单额、炸板率保持 unknown，也没有基于炸板率的市场级规则。2026 官方规则已核验沪深主板、创业板/科创板及北交所的比例和主要 IPO/退市首日例外；但没有逐股权威限价源、上市日序号或退市状态，公式结果仍是明示假设的非权威估算。基本面缓存是当前 F10 快照，不是 point-in-time 历史因子；PE 动态值不冒充 PE-TTM。Sina 的未观测 quote metrics 不臆造。跨市场目前只有 symbol/venue/time-zone 路由元数据，没有经过契约测试的 HK/US/ETF 实时报价及节假日历。
- **其余工程边界：** Apple PDF 代码路径已改用系统 Unicode 字体；Linux 测试 fallback 仍只支持 Helvetica/WinAnsi，实际中文绘制尚待 Apple SDK/设备验收；PNG 未实现。Portable backup service 使用调用方提供的 32 字节 key；App 尚未提供安全口令派生和文件恢复流程，因此 Settings 不提供备份操作。Keychain adapter 仍需 Apple 设备验证。`OSLogDiagnosticLogger`、结构化日志与 JSON 诊断 bundle 已有核心原语，Settings 可分享 allowlist 诊断 JSON，但运行时调用点尚未覆盖全部采集/存储路径。通知授权/手动投递入口已接线；通知 action delegate 与 snooze/read 行为仍未实现。条件请求已接入行情/部分扫描请求，不代表每个新闻/历史 endpoint 都复用 ETag/Last-Modified。事件自动 LLM 与 Analyst 成功结果可记 provider usage，但失败的部分完成 Analyst 调用尚无完整 token 对账。
- **数据边界：** 行情/资讯仍受公开非正式接口限制；涨停/跌停价格仅是可识别证券的非权威公式估算，IPO 与无法分类证券保持 unknown；2027 及以后交易日状态保持 unknown。雪球、MIIT、CNINFO 上交所代码映射和龙虎榜席位明细仍不完整。逐项来源依据见 [`SOURCE_EVIDENCE.md`](SOURCE_EVIDENCE.md)。


## P0–P2 功能缺口逐项状态

状态针对**功能核心与既有 App runtime**；“部分完成”表示仍缺关键字段、显式操作入口或 Apple 设备验证。`MonitorViewModel` 已采用 core factory；六标签 shell 包含真实数据的 Market/Watch/News 页面与 Lab 本地回测研究，并保留既有 Monitor 控制台。自动 LLM 仅在启动时从本机配置与 Keychain 通过 gates 后、用户显式刷新事件时运行，所有开发测试均用 mock。

| # | 状态 | 实现与边界 |
|---:|---|---|
| 1 | 部分完成 | `DailyLimitSource`、本地板块公式估算及 `seal_break` 已实现；成熟且可识别 A 股可算，IPO、北交所未核验情形与未知代码保留 unknown，非权威价格不能代替交易所/实际委托价。 |
| 2 | 部分完成 | `MonitorViewModel` 已采用默认 money-flow decorator；每 10 分钟最多轮转 2 只自选、仅回传 120 秒内字段。`main_flow_surge`/`late_session_pump` 仍默认关闭，覆盖和来源字段仍有限。 |
| 3 | 部分完成 | Eastmoney/Tencent 实录字段的量比、换手、PE、市值解析已测；Sina 未观察到的字段及来源不提供的字段保持 nil，部分请求结果不保证具备全套指标。 |
| 4 | 部分完成 | 常规扫描最多 10 页/1,000；显式扩展扫描固定 pz=100、按 clist 报告 total 推导页数、最多 60 页/6,000 个去重证券并缓存 15 分钟。测试覆盖 total 对齐、total 缺失只取一页、重复页、精确 cap 与截断；Market 显示样本统计及接口相对覆盖状态，但不声称覆盖交易所完整证券全集。涨停池/炸板率仍 unknown，未添加猜测情绪规则。 |
| 5 | 部分完成 | Settings 已提供用户显式触发、最多 10 只自选股的当前 F10 快照刷新与字段展示；不会自动请求。快照非 point-in-time，动态 PE 不映射 PE-TTM，缺失字段保持 unknown。 |
| 6 | 部分完成 | quote registry 有异常价格闸门和 `suspectCodes`；缺可靠 IPO/特殊证券状态源，暂不能对所有股票正确套用“非新股”豁免。 |
| 7 | 部分完成 | registry 集成指数退避、jitter、熔断、半开恢复及 429/403/HTML/无效 JSON 分类；并非所有新闻/历史 provider 都共享全套策略。 |
| 8 | 部分完成 | MACD、KDJ、BOLL、ATR、OBV、BIAS、N 日高低、连涨连跌及 RSI 已有纯 Swift 日线和分钟 bar 接口；分钟 VWAP±1σ 为典型价×成交量的近似，指标尚未接入个股分时副图，也没有尾部增量缓存/vDSP。 |
| 9 | 部分完成 / unknown | Source 已使用所有者提供的 ut 与标准分页参数；2026-11-14 公共请求（date=20261113）两次 HTTP 200 但 `rc=206,data:null`，省略日期为 `rc=102,data:null`。用户报告的 37 行无法复现；无真实 pool row fixture，因此不猜字段、不入库、不喂给 sealBreak。 |
| 10 | 部分完成 | Eastmoney 龙虎榜 summary source 与自选股上榜规则已接；限制为已观察到的摘要字段/自选范围，不含完整买卖席位分析。 |
| 11 | 部分完成 | App 显式资讯刷新现在走 tiered enricher：P1/P2 full、P3 缺失元数据时条件调用、P4/P5 不调用；仅在启动时 endpoint/model/Keychain key 可用时装配。保存/更新设置后需下次启动；自动 provider 发送与设备验证仍待验收，开发测试均为 mock。 |
| 12 | 部分完成 | News 提供本地日报 PDF 生成与系统分享入口，按上海自然日 00:00–12:00、12:00–24:00 分段；仅汇总本机保存事件并显示来源覆盖提醒，不声称采集完整。Apple 分支使用系统 Unicode 字体，尚未在 Apple SDK/device 验证；PNG 未实现。 |
| 13 | 部分完成 | `SQLitePortableBackupService` 已接入 runtime，限大小、校验后原子恢复，保留核心设置/报价/事件/信号/已读状态；App 文件选择、密码派生及迁移 UI 未接，API key 排除在外，minute/daily bars 不随备份。 |
| 14 | 部分完成 | App 确认后的 Analyst 分析已改走 runtime cache/usage ledger；重复上下文可复用交易日缓存。Provider 未返回的 token 仍 unknown，失败的部分 Analyst runs 尚未入账。 |
| 15 | 部分完成 | A 股、港股、NYSE/NASDAQ 的 venue/time-zone/session metadata 与已验证 Eastmoney secid 前缀有单测；无可用的跨市场实时 quote adapter、ETF/099 路由和对应假日日历。 |
| 16 | 部分完成 | Settings 有显式通知授权和未读信号投递入口；不会自动弹授权或投递，投递按钮须先获授权。`UNUserNotificationCenter` action delegate 与 snooze/mark-read 行为仍未接线，UI 明确提示限制。 |
| 17 | 部分完成 | App backtest 只读取现有 SQLite 日线缓存，不主动联网拉取；A 股交易模拟仍需调用方 opt-in 桥接因子选股，历史成分股/公司行动限制不变。 |
| 18 | 部分完成 | 除 quote/资金流/clist/F10/pool 外，新增 trends2、daily kline、CNINFO SZSE 股票映射、澎湃、gov.cn 与龙虎榜六个真实响应 fixture 及 hash/解析测试；CLS 和可用 CNINFO 公告 row fixture 仍缺。 |
| 19 | 已实现 | Linux SwiftPM test workflow 与手动 iOS IPA workflow 均存在；自动 push 构建关闭。本轮通过 Codemagic 手动运行 `unsigned-ios`（M2），成功生成未签名 arm64 IPA；没有独立 macOS archive/export/release workflow。 |
| 20 | 已实现（待设备验收） | SwiftUI App 壳、六标签导航、route/deep-link/command palette、Market/Watch/News/Lab 页面、XcodeGen、Info.plist、entitlements、Bundle ID/App Group 与 SQLite 路径已存在；App Group 容器不可用时改存本 App 私有 Application Support，所有标签页显示不共享警告；尚无 Apple SDK/真机验证。 |
| 21 | 部分完成 | 结构化 redacted logger、Apple `os.Logger` sink、allowlist JSON 诊断 bundle 和 Settings 内的诊断文件分享入口已实现；文件仅包含版本、来源状态计数与本机健康汇总，运行时日志调用点尚未覆盖全部采集/存储路径。 |
| 22 | 已实现（报价源） | Sina、Eastmoney、Tencent 报价请求已带 User-Agent 和 Accept/压缩协商头；仍可能被站点策略拦截。 |
| 23 | 部分完成 | ETag/Last-Modified 条件请求与 gzip 解压缓存已接入报价及部分 clist 请求；没有对所有 event/history endpoints 全覆盖。 |
| 24 | 部分完成 | 内置 2022–2026 经上交所公告核验的交易休市日；Settings 新增本地 JSON 导入，限制 HTTPS 交易所域名并保存来源元数据。导入内容不经 App 独立真实性验证、无自动网络更新；每年只将明示闭市日期标为 closed，其他未覆盖工作日继续 unknown。 |
| 25 | 部分完成 | Apple Keychain adapter 与 AES-GCM 备份 envelope 核心已存在；备份密钥需调用方提供 32 字节数据，尚无 App 侧 passphrase/KDF、文件分享和恢复界面。 |

状态表覆盖 core 与 App runtime。六标签 shell 中 Market/Watch/News/Lab 使用真实报价/来源或本地分析结果；Lab 的治理、tick 缺口、情绪、因子矩阵/暴露和关系图仅读取本地已存/已加载数据。Settings 已接入交易日历 JSON 导入、最多 10 只 F10 快照刷新、显式通知授权/投递和白名单诊断 JSON 分享；安全口令派生及加密备份文件导入/导出仍无 UI，通知 action delegate 仍未接线。

## Owner-supplied A–D checklist

“Done”仅表示代码/测试范围完成；仍需 Apple SDK 或真机验证的项目明确标为 partial/pending。所有数据统计只描述来源实际返回的样本。

| 项目 | 状态 | 实现与剩余边界 |
|---|---|---|
| A-1 中文 PDF | 部分完成 | Apple renderer 使用系统 Unicode 字体与实际字宽换行；没有 Apple SDK/设备，中文输出尚未实测。Linux fallback 仍用 WinAnsi，PNG 未实现。 |
| A-2 分钟指标 | 部分完成 | MinuteBar 支持 MACD/KDJ/BOLL/RSI/ATR/OBV 等接口与按日重置 VWAP±1σ 近似；尚未接入个股分时副图，VWAP 不代表逐笔成交。 |
| A-3 涨停池 | 未完成 / unknown | 已加入提供的 ut 和 `dpt/Pageindex/pagesize/sort/date` 请求参数；实测仍为 HTTP 200、`rc=206,data:null`（不带 date 是 `rc=102,data:null`）。用户报告的 37 行未能复现；没有可见 pool row，`zttj/lbc/fbt/zbc/fund/hybk` 映射、持久化和 sealBreak feed 均保持未实现。 |
| A-4 市场宽度 | 部分完成 | 常规扫描最多 10 页/1,000；用户显式扩展扫描固定每页 100，按响应 total 推导页数且上限 60 页/6,000；15 分钟缓存。UI 明示 clist total 只是接口自报分母，截断/重复/无效行时标记部分，不能代表官方完整证券宇宙；涨停/炸板仍 unknown。 |
| A-7 限价边界 | 部分完成 | 已按 2026 官方规则核对沪深主板 10%（主板 ST 自 2026-07-06 起 10%）、创业板/科创板 20%、北交所 30%、IPO 首 5 日/北交所上市首日及退市整理首日例外；Watch 只显示公式估算或 unknown。仍无逐股权威限价源及可靠上市/退市状态，板块前缀/ST 简称识别为启发式；运行时未提供 IPO 序号时明确标示“假设非 IPO 前五日”。 |
| A-9 CI 死代码候选报告 | 已实现（启发式） | Linux workflow 会生成未引用 public Swift 声明候选 JSON/TXT 并上传 artifact；当前本地扫描 81 个 Swift 文件、1,873 个 public 声明，列出 45 个候选，候选不是死代码证明。本轮未运行 CI；可查看 [本地候选报告](Reports/unused-public-swift-declarations.txt)。 |
| B-1 连板结构 | 未开始 | 缺经验证的连板天数、封单额与炸板次数数据源/fixture。 |
| B-2 成本分布 | 未开始 | 没有逐笔/逐价成交量，不能从 OHLCV bars 假称真实筹码分布或获利比例。 |
| B-3 情绪指数 | 部分完成 | Lab 显示当前会话已加载 clist 样本的可用净宽度分数，并逐项标明缺失组件；没有已验证的涨跌停/炸板/资金流/参与度输入时分数为部分或未知，不自动扫描，也不代表全市场或预测。 |
| B-4 相关性矩阵 | 部分完成 | Lab 点按后仅读缓存日线计算收益 Pearson 配对，并展示同一上海日期基本面缓存的因子×因子矩阵与自选股横截面值。没有明确持仓权重时组合 exposure 保持未知；point-in-time 全量数据、行业映射和 Apple UI 验收仍缺。 |
| B-5 Bootstrap | 部分完成 | Lab 对最高因子组真实等权日收益显示固定种子的 5/50/95% IID 终值及最大回撤分位；不是逐笔交易路径，不建模序列相关、公司行动或未来预测。 |
| B-6 回测报告 | 部分完成 | Lab 显示日频 IC/ICIR、分层收益/风险、风险统计、逐日分布分位数和月度复利，并解释未提供数据的超额/换手/时长/贡献。默认因子回测仍为 gross；执行模拟器 opt-in 且没有接入该报告 UI。单一交易方向模拟不能验证完整配对买卖 T+1 生命周期。 |
| B-7 治理漏斗 | 部分完成 | Collector 将 rejection reason 写入本地 SQLite；Lab 显示近 24 小时拒绝原因计数与相邻 24 小时关键词样本/增长，并区分零样本、查询错误与缺失窗口。结果仅反映本机已存记录。 |
| B-8 会话缺口带 | 部分完成 | LiveEngine 持久化每 tick complete/partial/empty、请求/返回/缺失符号及 reconcile 结果；Lab 已显示本地历史 strip，空库明确为未知，无法补回未记录的离线逐笔事件。 |
| B-9 图表数据工具 | 部分完成 | Treemap、quantile、threshold、LTTB、Sankey 与 ForceGraph 都有 UI-free 纯函数和边界/批量测试；这些布局函数不是完整业务图表页面。 |
| B-10 板块资金序列 | 未开始 | 没有经验证的板块成分归属和 sector×day 成交/资金流序列。 |
| B-11 因子相关/暴露 | 部分完成 | Lab 已显示因子矩阵、自选股横截面值，并明确没有组合权重时组合暴露未知。输入仅限当前本地基本面快照；point-in-time 全量因子、行业权威映射和设备视觉验收未完成。 |
| B-12 回测分布数据 | 部分完成 | core 与 Lab 展示逐日/逐月策略收益及分位数；只有完整日期对齐的显式基准才产生超额序列。真实 fills 可支持 gross notional/activity；没有 NAV 或配对开平仓/实现盈亏记录时 turnover、持仓时长和 symbol contribution 仍为 unknown。 |
| B-13 Sankey/ForceGraph | 部分完成 | 有有界纯布局函数、64 节点批量测试及 Lab 可视化；Sankey 只表示本地事件来源→板块标签计数，力导向图只表示因子相关，不能当资金流。无足够标签/矩阵时显示 unknown；Apple 渲染未验收。 |
| C-1 更多资讯源 | 部分完成 | 已有 CLS、Eastmoney、澎湃、gov.cn、CNINFO 深交所公告及龙虎榜摘要；金十、华尔街见闻、第一财经、股吧/热榜未接入。 |
| C-2 Xueqiu/MIIT | unavailable | Xueqiu 仍不可用；一次普通未认证 MIIT RSS/新闻候选探测遇到 403 JavaScript challenge，因此保持 unavailable，不登录、取 cookie 或绕过挑战。 |
| C-3 龙虎榜席位分类 | 未开始 | 没有可审核的机构/游资/北向席位分类规则与来源证据。 |
| C-4 港美股/ETF | 部分完成 | 只有 venue/secid/time-zone 元数据；真实 quote/kline provider、单时区 MarketClock 扩展和假日历未完成。 |
| C-5 行业成分映射 | 部分完成 | 现有 SectorTagger 是标题关键词标签，不是权威代码→行业/板块成分表。 |
| C-6 Level-2 限制 | 已实现（代码） | Market/Watch 顶部明确标注轮询快照、不含逐笔/完整回放/Level-2；Apple 视觉验收待完成。 |
| D-1 CI | 部分完成 | Linux SwiftPM test workflow 与手动 unsigned IPA workflow 存在；自动 push 构建关闭。本轮通过 Codemagic 手动运行 `unsigned-ios`（M2，30 分钟上限），成功生成未签名 arm64 IPA；没有独立 macOS archive/export/release workflow。 |
| D-2 XcodeGen | 已实现 | 根目录 `project.yml` 已存在并用于既有工程生成。 |
| D-3 App target/router | 已实现（待 Apple 验收） | `stockmonitor://` scheme 已注册；经校验的 tab/stock deep link、六标签路由和 command palette 已接入 shell。已在自选中的股票路由到 Monitor；未在自选中的安全六位代码路由到 Watchlist 并预填输入框，不会自动添加；冷启动路由等待本地会话恢复后再解析。未在 Xcode/设备验证 URL 启动行为；未知 URL 仅显示通用提示，不回显 query。 |
| D-4 Info/entitlements | 部分完成 | Info.plist、App Group entitlement 与 Keychain adapter 存在；没有显式共享 Keychain access group，iOS signing entitlement 仍待设备验证。 |
| D-5 App Group 路径 | 已实现（待设备验收） | iOS Store 优先通过 group container 取 SQLite 路径；若容器不可用则写入本 App 私有 Application Support，UI 明确告知数据不与扩展或其他 App 共享；App Group entitlement 保持原值。 |
| D-6 录制 fixtures | 部分完成 | 新增 6 个 HTTP-200 真实 raw 响应及 sidecar/parser tests：Eastmoney trends2、daily kline、CNINFO SZSE stock map、The Paper、gov.cn 与 Eastmoney 龙虎榜。CNINFO 公告查询未得可用 row list，CLS 未绕过不可用状态；pool 仍为 null。 |
| D-7 Apple 设备验收 | 待外部环境 | 当前环境无 Apple SDK/真机，CSQLite 链接、Keychain entitlement、盘中 CPU/内存均未实测。 |
| D-8 2027 日历 | 部分完成 | Settings 支持导入受限大小的本地 JSON，HTTPS 来源 host 限于 SSE/SZSE/BSE，payload 会本机持久保存；2027 未列闭市日期仍 unknown。导入内容非签名验证，无自动更新，需人工对照原公告。 |
| D-9 历史备份 | 部分完成 | 加密 portable backup/restore 在默认每类 100,000 行、历史块 16 MiB 上限内纳入分钟与日线 bars；超限时整个历史块不导出并携带 omission reason，导入此类备份不会部分替换目标历史。Raw archive、session ledger、key 不迁移；App 侧密码派生、文件选择/恢复 UI 仍未接线。 |


## UI v2 · 设计基础与已接线页面

- `App/Views/WorkbenchView.swift` 提供市场页工具栏可达的本机工作台，可切换看板/列表；汇总当前会话/日历、已有指数与扫描样本、自选报价、逐项持仓相对成本变化及未读信号标记已读，并直达现有自选/监测/资讯/Lab。新增来源与会话健康面板，展示实际行情/分钟补齐来源状态、七日本机健康分母/比率及最近前台会话已记账 tick、请求和可用 token 计数；刷新只读本机 SQLite，无样本、部分返回、来源时间未知、过期及失败均明确标注。小屏单列、大屏双列；没有报价或接口覆盖不完整时分别明示，未加入猜测的涨停、炸板、Level-2、板块资金或情绪指标。SwiftUI 仍需 Apple SDK、Preview 与设备验收。
- `App/Views/BoardModeView.swift` 新增市场页可达的全屏行情看板：隐藏标签导航与状态栏，按可用宽度自适应纵向/双栏布局，读取当前本机快照中的核心指数、自选报价及扫描样本宽度；缺失报价、来源时间未知、超过 120 秒及扫描覆盖不完整均显式标注。刷新沿用既有前台会话规则，不触发扩展扫描或外部分析。此版本不强制横屏、不支持音量键控制、应用内截图或多屏输出；当前 Linux 环境没有 Apple SDK，尚未完成 Xcode 编译、Preview 和设备视觉验收。
- `StockMonitorRoute` 的股票 destination 按当前已恢复自选列表解析：已关注代码打开 Monitor 分析候选，未关注代码转到 Watchlist 并预填代码，仍需用户显式点击“添加”；冷启动期间暂存深链，避免恢复前误判。Command Palette 的 VoiceOver 提示同步说明此行为。路由解析已有 Swift 单测；SwiftUI 冷启动/URL 系统派发仍待 Apple SDK 与设备验收。
- `App/Views/StockDetailView.swift` 可从 Watchlist 自选卡片打开，分为“概览 / K线”两段：概览使用当前已加载报价字段并标注来源时间未知或超过 120 秒；K线只读 SQLite 最近最多 60 条通过 OHLC 合法性校验的未复权日线，并以开、高、低、收绘制真正的蜡烛图，颜色沿用现有涨跌语义色；图下保留首末缓存收盘变化、最近 OHLC 行和最后一条记录的来源/本机抓取时间。无缓存、单条蜡烛、读取失败分别明确呈现；页面进入和手动重读都不发网络请求。它是新增的 Watchlist 详情入口，不改变现有深链 destination（已关注股票仍路由到 Monitor）。`App/Charts/StockDailyCandleChart.swift` 实现带价格刻度、日期标记及 VoiceOver 说明的 K 线图。
- 新增 Dusk 与高对比浅色两套 palette，以及集中式 paper/ink/accent/data/heat/flow、12–33 pt 字阶、间距、圆角、触控目标、opacity 与 skeleton 尺寸令牌。关键文字/语义色对 paper0/paper1 的本地 WCAG 对比度检查均高于 4.5:1。
- `App/DesignSystem/ComponentSkeletons.swift` 提供 32 项基础组件骨架目录、Surface/Metric/Provenance 复用组件，以及 loading、empty、partial、error、stale 五类明确数据状态；`App/Previews/DesignSystemPreviewGallery.swift` 展示四态图库、额外 stale/provenance 示例与两套主题预览。
- `App/Charts/StockChartTheme.swift` 集中图表色彩角色、用 quantile bucket 选择 heat 色、用线性阈值位置绘制 marker，并格式化 CNY/股数/百分比及 Asia/Shanghai 时间。纯 Swift `VisualizationMapping` 不依赖 SwiftUI，覆盖 treemap 面积分配、quantile tie 处理、threshold axis clamp 与 LTTB 降采样测试，继续包含在 UI-free functional-source ZIP 中。
- `App/Views/StockMonitorTabShell.swift` 提供六标签入口；Market 展示核心指数与真实扫描样本并声明样本覆盖，Watch 展示自选报价/来源/限价状态，News 提供本地摘要、FTS 搜索、近 7 天事件的类型/P1–P3/自选相关筛选、逐源状态和本机日报 PDF 分享。筛选只作用于最近最多 100 条本机事件，自选相关只匹配事件已有证券标签。Lab 有单因子回测、分层风险统计、bootstrap 包络、只读缓存相关性配对、治理/tick/情绪/因子/关系图面板和既有 Analyst。Settings 提供本地日历 JSON 导入、显式最多 10 只当前 F10 快照刷新、用户触发的本机通知授权/未读信号投递和白名单诊断 JSON 分享。加密备份仍无安全口令派生与文件导入/导出 UI；通知 action delegate 未接线，32 个骨架不是完整业务组件。SwiftUI 当前只经语法解析，仍需 Xcode 编译、Preview 与设备视觉验收。


## 本轮 UI 更新与未签名构建

- App Group 不可用时，顶栏默认显示紧凑的一行“仅保存在本 App · 不与其他 App 共享”；点按可展开容器 ID、故障原因及私有 Application Support 回退说明。
- 源码提交：`a66024a95559f570e8571c407c0894978090925e`。Codemagic `unsigned-ios` 在个人账户的 `mac_mini_m2` 上从 `main` 成功构建，build ID 为 `6af829cd90e83b09c4fa21fc`。
- 验证：259 项 Swift 测试通过，21 个 App Swift 文件解析通过；交付 IPA 的 Bundle ID 为 `com.cn00k.stockmonitorv6`、架构为 arm64，且不含代码签名目录或 provisioning profile。
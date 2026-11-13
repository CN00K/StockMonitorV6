# 股票监测信息采集系统 v6

纯本地 iOS 行情与事件整理终端：行情监测和事件采集只在前台会话内进行；进入后台取消请求/轮询，结束会话并 checkpoint SQLite WAL。没有自建后台、后台常驻、账号体系或远程推送。行情/资讯只在用户操作时直连第三方公开站点；本项目不把请求转发到自有服务器。

## 当前实现

- SwiftUI 仪表盘提供会话状态、主要指数、自选股增删、报价来源时间/新鲜度、未读信号及已读操作；用户可录入/更新/删除持仓股数与成本价。
- 14 类经用户批准的规则族已接入实时前台报价、完成分钟 bar、历史补齐和本地事件。每族可编辑启用状态、阈值、确认次数、冷却、交易时段限制与静默时段；绝对高/低价按自选股设置，持仓 P/L 使用用户录入成本。
- 规则 checkpoint 在 SQLite 本地保存，包括确认去重游标、冷却/每日触发状态、会话极值、VWAP/SMA/相对强弱窗口、事件去重与板块簇状态；实时行情、完整分钟 bars、信号及 checkpoint 在同一 SQLite 事务提交。规则族配置独立持久化。
- 实时报价使用来源协议与串行 fallback：Sina → Eastmoney → Tencent。每只报价保存来源 ID、采集时间，并标明时间来自 provider 还是仅本地采集。只有 provider 时间较新（120 秒内）的报价参与报价规则；重复 provider 时间戳不重复计作确认。
- 指数快照通过同一来源链采集；来源状态显示请求/返回数量、请求次数、来源时间新鲜度和错误。相对强弱规则仅使用上证综指作为已实现基准。
- 重开时用 Eastmoney `trends2` 拉取 1 分钟历史，并与首个前台行情快照并行；最多请求 50 只股票，host budget 为每秒最多 4 次、每个前台会话至多 50 次历史请求。只评估接口确实返回的完整 bars；分钟历史不是逐笔回放，不能保证恢复离线期间每个事件。
- 用户可按按钮前台采集事件；当前适配器包含 CLS、Eastmoney 新闻、澎湃新闻、gov.cn 政策库搜索、CNINFO 深交所公告和 Eastmoney 龙虎榜摘要。雪球与工信部因当前匿名 API 阻挡/挑战，明确显示 unavailable，不登录、不收集 cookie、不绕过反爬。
- 事件保留源 ID、源条目 ID、源时间戳/抓取时间、原链接、优先级、板块/股票标签与跨源佐证。配置沿用并扩展已审计的 StockAgent P1–P5 collector seed；SimHash 去重、低优先级过滤与板块标签仅在本机运行。
- 当日事件聚类与日报按需从本地 SQLite 即时生成；支持 CSV/JSON 导出和系统分享面板，不调用 LLM。SQLite 事件保留 7 天且最多 10 万条。
- 本机事件可按标题、正文、来源、股票代码或板块搜索：SQLite FTS5 trigram 对长度至少 3 的词项做全文检索，短词回退到转义后的 LIKE；旧库通过 `user_version` 迁移并回填索引。搜索只返回 7 日窗口内已保存的事件。
- 成功的公开 HTTP 响应可选归档到本地 SQLite：端点会去掉 query/fragment/user/password，响应体最多 512 KB、每次刷新最多 16 条/2 MiB，总计最多 500 条/10 MiB，保留 7 天；不保存请求头或 query 参数。
- 本机七日健康面板累计 P1 官方来源（gov/CNINFO）请求成功率、解析有效率及用户触发 Analyst 占比，目标分别为 ≥99%、≥80%、≤50%。分母是 P1 请求数、源端候选事件记录数、以及成功 Analyst runs + 未送 Analyst 的去重可见事件数；一个 Analyst run 计 1 次，不按其六个模型请求重复计数。没有样本时 UI 显示“暂无数据”。
- 按需 Analyst 流程匹配现有 `StrategyResult`：supervisor 与技术/基本面/情绪/风险四个 specialist 并行，随后一次 refinement；五路并行返回和最终结果均使用 strict JSON Schema 与本地范围/字段校验。默认关闭，Endpoint/Model 由用户手动配置，API key 只写入 iOS Keychain（设备本机、解锁时可用）；Key 不进入 SQLite、日志、请求 body、资源或 IPA。选择股票后必须再次确认才发送所选报价、最多 60 根本地日线和最多 20 条近 7 天匹配事件/未读规则告警。提示会发出六次 HTTPS 请求、可能重复发送该上下文并由 Provider 收费；请求直达配置 endpoint，不经自建后台，进入后台会取消。结果带非投资建议提示。
- 本地单因子回测只使用当前自选股（没有指数成分股清单时不会扩展 universe），支持 9 个由日线 OHLCV/成交额/换手率可计算的因子和 20/60/120 个信号交易日；下载 Eastmoney `klt=101`、`fqt=0` 未复权日线，本机算分层收益曲线、逐日 Spearman IC 与未年化 ICIR。当前交易日 15:05（中国时间）前不纳入未完成日线。日线本地最多保留 3 年/10 万条，数据接口预算与分钟补齐共享。

## 14 类规则族

默认值按批准方案执行，均可在规则卡片调整：日涨跌幅 ±3%（2 个不同 provider 报价、同方向冷却 30 分钟）；用户设置绝对高/低价（2 次确认）；完整分钟量能 ≥此前 5 根完整 bar 均量 2 倍（2 根确认、15 分钟冷却）；单分钟成交额 ≥人民币 5,000 万元（15 分钟冷却）；开盘跳空 ±2%（每方向每天一次）；首次刷新本会话已观察高/低点（每方向每天一次）；5/20 分钟 SMA 交叉（2 根完整 bar、每方向每天一次）；价格相对本地 VWAP 偏离 ±1.5%（2 根完整 bar、15 分钟冷却）；单分钟价格速度 ±1%（同方向冷却 10 分钟）；相对已观察高点回撤/低点反弹 3%（30 分钟冷却）；近 30 分钟相对上证综指强弱 ±2 个百分点（2 个窗口确认、30 分钟冷却）；持仓成本浮盈/浮亏 ±5%（30 分钟冷却）；明确匹配自选代码且来源 P1–P3 的重大新闻/公告（每个归一化事件一次）；以及 60 分钟内同板块至少 3 个独立事件、至少 2 个来源并含一条 P1–P3（每个聚类一次）。

**未添加涨停/跌停规则，也不会根据固定 10%/20% 猜测日限价。** 目前没有经核验的逐股每日涨跌停价源。

## 数据源边界

所有行情、新闻、公告与龙虎榜接口均为公开但非正式/无合同端点；没有核实到服务 SLA、完整性、固定速率或新鲜度承诺。来源可能延迟、限流、变字段或暂时拒绝请求，app 会显示错误/不可用，而不是把失败伪装成“没有事件”。详细证据见 [`SOURCE_EVIDENCE.md`](SOURCE_EVIDENCE.md)。

CLS 依赖可在本机计算的签名参数，站点改版可能使适配器失效；gov.cn 当前接入的是“证券”政策库搜索，不是覆盖所有政府新闻的推送 feed。CNINFO 只对已核实的深交所代码映射查询自选公告，当前没有可靠的上交所代码映射；东方财富龙虎榜只查询最多 10 只自选股的摘要记录，不拉买卖席位明细。雪球接口曾返回 403/400016，工信部新闻页遇到 403 JavaScript challenge，因此暂时不可用。

分钟历史补齐的是服务返回的分钟 bars，不是逐笔或完整事件回放；分钟内所有离线异动不能保证恢复。盘中极值仅从本地实际观察到的数据建立，不能推断离线时段高低点。交易日历编码 2022–2026 年经上交所官方年度公告核实的工作日休市日期；深交所原文可直接交叉核验的范围为 2024 全年及 2026 中秋/国庆，其他深交所来源缺口见 [`SOURCE_EVIDENCE.md`](SOURCE_EVIDENCE.md)。周末固定休市；超出 2022–2026 覆盖的工作日状态为 unknown，Live Loop 不会假定开市。

前台请求会将必要的查询参数（例如所选深交所股票代码）直接发给对应公开数据源；内容和 SQLite 数据仅在本机/App Group 保存。本 App 仅供信息整理与研究，不构成投资建议。

## 测试与构建

`swift test` 是测试命令。fixture 测试覆盖 14 个规则族的关键触发条件、重复时间戳去重、静默时段、分钟 bar 完整性、来源优先级/低价值过滤、SimHash 聚类、SQLite 规则设置/checkpoint 与事件 round-trip、FTS5 旧库迁移/长短词搜索、raw archive 脱敏/年龄与总量 pruning、健康分母和阈值累计、CSV/JSON 导出、行情 fallback/请求预算、日线字段解析/SQLite round-trip、因子分层/IC/ICIR/曲线，以及 Analyst 的 strict schema、六请求编排、失败验证和 API key 不进入请求 body。

最终静态审计状态：在 Linux Swift 6.4.2 下运行 `PATH="$HOME/.local/opt/swift-6.4.2/usr/bin:$PATH" swift test`，**57 项通过、0 失败**。Tree-sitter 对 App、Sources、Tests 下的 39 个 Swift 文件解析无语法错误；`project.yml`、collector 与 workflow YAML、行业 JSON、entitlements 和 privacy manifest 均通过解析，XcodeGen 声明的源码/资源/entitlement 路径均存在。扫描未发现高置信度凭据模式。iOS SwiftUI/Keychain 源码经过静态检查，未发现明显编译障碍；这不等同于 Apple SDK 编译。

`UserDefaults.standard` 仅保存 App 自身的 Analyst endpoint/model 偏好；`Resources/PrivacyInfo.xcprivacy` 已声明 Apple required-reason API `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`。当前代码未发现相机、麦克风、位置、照片库或通知权限 API，因此没有相应的 usage-description 字符串需求。API key 仍由 iOS Keychain 管理，不包含在源码或 workflow 中。

`.github/workflows/build-ipa.yml` 只有 `main` 分支 `workflow_dispatch` 手动触发，且必须输入 `BUILD`；push 不会启动构建。工作流用 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、手动签名模式及空的签名身份/team/profile 设置构建 arm64 iOS 设备版，再把 `.app` 打包成 unsigned IPA；不读取 Apple signing secrets，不创建密钥串、不导入证书，也不嵌入 provisioning profile。Artifact `StockMonitorV6-unsigned-IPA` 保留 14 天，包含 IPA、`StockMonitorV6-signing.entitlements` sidecar、构建 manifest 和 IPA 文件清单。unsigned IPA 没有签名，也没有签名后生效的 entitlements；App Group 仅在 sidecar/源码 entitlement 中声明，必须由用户签名时通过匹配的 provisioning profile 授权。工作流修改需在私有仓库 [CN00K/StockMonitorV6](https://github.com/CN00K/StockMonitorV6) 的 `main` 上提交；XcodeGen 生成及 Apple SDK 设备构建由该手动工作流执行。

`Resources/Assets.xcassets/AppIcon.appiconset` 已包含 1024×1024、不透明 RGB PNG 图标：深蓝背景、青绿色雷达与市场走势，无文字。XcodeGen 将该 catalog 作为 App resource，并通过 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` 指定它；iOS 自行应用圆角遮罩。

`codemagic.yaml` 另提供 `unsigned-ios` 手动工作流，只使用 `mac_mini_m2`，总超时 30 分钟；没有 `triggering` 事件、环境变量组、Apple 集成、证书导入或 publishing。push、PR、tag 不会自动启动此 YAML 工作流。其无签名开关与 Bundle ID/App Group/arm64 校验和 GitHub 工作流一致，并校验编译产物的 AppIcon 名称。连接或手动启动前，必须在 Codemagic 确认使用个人账户、可用免费 M2 分钟足以覆盖这 30 分钟上限且没有其他构建消耗该额度，不启用 billing、不接受任何收费。配置选择 M2 本身不代表账户额度已通过核验；无法确认免费时不得启动。官方说明见 [手动触发规则](https://docs.codemagic.io/yaml-running-builds/starting-builds-automatically/) 和 [免费分钟适用范围](https://docs.codemagic.io/billing/pricing/)。API token 仅用于外部管理请求头，不进入仓库、YAML 或 IPA。

## 已选标识、仓库与 Apple 环境验收

- **仓库：** 项目位于私有 [CN00K/StockMonitorV6](https://github.com/CN00K/StockMonitorV6)，初始 `main` 提交为 `aceb771ace6c2023181f74a3c5e58f37418ee76f`。
- **App 标识：** App Bundle ID 为 `com.cn00k.stockmonitorv6`，核心 framework 标识为 `com.cn00k.stockmonitorv6.core`，App Group 为 `group.com.cn00k.stockmonitorv6`。三处工程配置、entitlements 和 SQLite fallback 必须保持一致，并在 Apple Developer 中核对对应 App ID 与 App Group 能力。
- **签名与分发：** 当前目标为 unsigned iOS 设备 IPA，由用户用自己的证书签名。workflow 不需要 Apple Team ID、P12、P12 密码或 provisioning profile，仓库不需要为该 workflow 配置这些签名 secrets。unsigned IPA 在签名之前不能安装；签名时，用户自己的 Apple Developer team 必须能注册 `com.cn00k.stockmonitorv6` 与 `group.com.cn00k.stockmonitorv6`，并提供匹配 Bundle ID、授权该 App Group 且包含目标设备 UDID 的 provisioning profile。artifact 同时给出 entitlement sidecar 供签名时使用。
- **Apple 验收：** workflow 只生成未签名 arm64 IPA；它不执行签名或设备安装。用户签名后仍需在目标 iOS 设备验证 Keychain、App Group、资源加载、前后台暂停/恢复、网络和分享。App Group 在未签名 IPA 中不会作为有效签名 entitlement 生效。
- **LLM Provider：** App 内尚未配置兼容 Structured Outputs 的 HTTPS `/chat/completions` endpoint、model ID 和 API key。用户需在设备上自行设置并核对 Provider 的价格、限额与兼容性；分析只在用户明确触发并确认后发送。
- **App Store 隐私披露：** 若选择 App Store/TestFlight，需另行核实对用户选择发送给其 LLM Provider 的本地材料应如何填写 App Privacy 披露；`PrivacyInfo.xcprivacy` 中的 `CA92.1` 仅声明 required-reason API，不等于完整隐私标签。
- 市场数据/资讯覆盖仍受公开非正式接口限制；未核实的日历年份保持 unknown，未添加猜测型每日涨跌停价。雪球、MIIT、CNINFO 上交所代码映射和龙虎榜席位明细仍不完整。

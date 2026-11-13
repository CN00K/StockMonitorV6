# 上游只读审计记录

上游仓库为 `https://github.com/qilihei/StockAgent`，只读检查的 commit 是 `82fbd66`。仓库许可证为 MIT（Copyright 2024 StockAgent）；工程中保留了许可全文，提取出来的板块种子在 JSON 内标记来源。第三方行情与新闻端点的使用条款仍需单独遵守。

实际存在的采集治理文件是 `AgentServer/config/collector.yaml`，新闻主题映射在 `AgentServer/config/news_filter.yaml`。已从新闻配置中提取 111 条标题-板块映射、12 个同义词和 15 个聚类池，打包为 `Resources/sector_map.json`；它们是新闻主题词，不是股票成分板块表。THS 成分映射需联网采集并依赖 MongoDB，不能直接作为静态本地表。

用户提供的因子段落标题写“17 个”，但逐项列出的实际是 19 项；上游 `factor_library.py` 有 20 项定义，另含用户未列出的 `price_position`。当前 Swift 子集实现用户列出的 19 项。上游 `FactorEngine` 明确有 MAD 缩尾和横截面 Z 分数；在审读的版本里没有 neutralize 步骤。工程只提供了显式传入分组后的可选去组均值，不把它伪称为上游逐值对齐。

用户规格提到的 `core/prompts/stock_analysis/*.yaml` 在此 commit 不存在；可见提示词位于 `AgentServer/config/prompts/` 与 `AgentServer/src/llm/prompts/`。目前没有复制提示词内容。Listener 九步在 `AgentServer/nodes/listener/node.py` 的 `_poll_cycle`；本工程收敛为前台会话、SQLite 落库、公开行情 fallback、分钟差异补齐和手动事件采集。

`collector.yaml` 中的 P1–P5 优先级与低价值过滤沿用上游语义，并为本地事件适配器扩展 source ID 映射；事件标题可使用上游板块种子标记标签。当前只实现 CLS、Eastmoney 新闻、澎湃、gov.cn 政策搜索、CNINFO 深交所公告和 Eastmoney 龙虎榜摘要的 best-effort 适配。Xueqiu 因匿名 API 阻挡/cookie 依赖、MIIT 因 403 JavaScript challenge，明确标为不可用，不绕过访问控制。接口证据见 `SOURCE_EVIDENCE.md`。

14 类告警规则尚未扩展或启用。当前规则引擎仍限于原有基础条件；建议的 14 类和默认值单独列在 `RULE_FAMILY_PROPOSAL.md`，仅在用户明确审批后才可进入实现。当前没有权威逐股每日涨跌停价，不按固定比例推算；也没有多代理 LLM、完整交易所节假日日历或全量离线事件恢复。

# DeepSeek SSE 代理网关 (ds-free-api) 综合修复日志

本文档梳理了导致 DeepSeek 代理网关在与 Aider/Claude 客户端进行超长上下文交互（如 >80k Tokens）时频繁"断开"、"崩溃"的全部底层 Bug 及其系统级解决策略。本次修复遵循"协议合规"、"本地优先"与"透明度最大化"三大原则，避免了拆东墙补西墙的临时性硬编码方案。

---

## 一、协议与格式不兼容 Bug（导致客户端强制断开）

### 1. SSE 保持活跃 (Keep-Alive) 协议违规
- **现象**：大模型进行长时间"思考"时，原代理使用 `{"type": "thinking"}` 作为占位符防止连接超时。但这不符合 Anthropic API 标准规范，导致 Claude/Aider 客户端底层协议解析失败，发生"无效块"断开。
- **系统性修复**：
  - 在 `anthropic_compat/types.rs` 扩展 `MessagesResponseChunk::Ping` 枚举。
  - 在 `anthropic_compat/response/stream.rs` 中，将空闲保活机制修改为发送标准的 Anthropic SSE Ping 事件 (`: ping\n\n`)。

### 2. 缺少必填的响应文本块 (Missing Text Block)
- **现象**：当 DeepSeek 遇到错误或只输出 `Thinking` (思考过程) 就突然结束时，未输出任何实质性正文（Text块）。Anthropic 协议强制要求如果输出流结束，必须至少包含一段文本。由于缺失该块，客户端判定响应残缺并抛出致命异常。
- **系统性修复**：
  - 在 `stream.rs` 流结束时（`finish` 事件），如果检测到当前状态机未发送过真正的文本块或工具调用块，则在关闭流之前强制注入一个内容为空的 `Text` 块 (`{"type": "text", "text": ""}`)，满足协议完整性要求。

---

## 二、截断与容错处理 Bug（导致服务端请求瘫痪）

### 3. 残缺 JSON 引发高频模型修复（Token爆炸与限流根源）
- **现象**：Aider 将全部源码加载导致历史 Token 飙升至 80k+。DeepSeek 后端压力剧增，极大概率在生成工具调用 JSON 时"一刀切"强行截断（如丢失结尾的 `]}`）。
  原代理一旦解析 JSON 失败，会将其发给网关自带的 `RepairStream`（修复模型）。由于上下文极其庞大，导致修复模型频繁触发 DeepSeek 的账号并发限流 (`Service Overloaded`)，整个连接最终彻底暴毙。
- **系统性修复**：
  - 在 `openai_adapter/response.rs` 的 `try_parse_tool_calls_directly` 中实现**零延迟的本地 JSON 补全机制**。如果检测到尾部缺失 `]`，网关会智能探测并在内存中补齐括号。100% 绕过了昂贵且容易失败的 `RepairStream`。

### 4. 内部状态标记外泄 (State Leakage)
- **现象**：DeepSeek 的底层状态碎片（如 `FINISHED`, `SEARCHING`, `WEB_SEARCH`）偶尔会混入普通文本块流出。这不仅污染了正常对话，更会导致工具调用的 JSON 格式彻底损坏。
- **系统性修复**：
  - 在 `openai_adapter/response/state.rs` 中增加了脏数据清洗器，遇到指定的后台指令字符串时自动执行 `.replace(xxx, "")` 抹除，保证吐给客户端的纯净度。

---

## 三、异常信号丢失 Bug（导致"假死"和无法续写）

### 5. `stop_reason` 硬编码导致截断无感知
- **现象**：由于 80k 超长上下文，模型达到单次生成上限 (Max Tokens) 时，DeepSeek 返回了 `INCOMPLETE` 状态。但在 `converter.rs` 中，所有的状态都被错误地硬编码为 `stop`（Anthropic 对应 `end_turn`）。这使得 Aider 误以为模型已经主动且完整地发言完毕，从而不再发起"继续生成"的请求。
- **系统性修复**：
  - 更新 `converter.rs` 状态机映射。遇到 `INCOMPLETE` 时正确抛出 `length` 停止原因，并在流控层准确映射为 Anthropic 协议标准的 `max_tokens`。这样 Aider 就能在底层捕捉到截断事件，并做自动化处理。

### 6. DeepSeek 官方系统警告 (TIP) 被静默吞噬
- **现象**：当模型因超载或违规等原因被中断时，DeepSeek 通常会派发一个 `TIP` 碎片（包含具体的警告原因）。过去的网关代码只处理了 `THINK` 和 `RESPONSE` 块，导致 `TIP` 警告被静默丢弃，用户看到的就是"模型莫名其妙断开了，什么都没留下"。
- **系统性修复**：
  - 在 `state.rs` 中新增对 `TIP` 类型的拦截。
  - 将其封装成 `DsFrame::ContentDelta`，以 `[DeepSeek System TIP: xxxx]` 的形式作为普通回答文本直接返回。让开发者/客户端对断流的真实原因拥有 100% 的知情权。

### 7. 转换器流提前结束导致 TCP 强断 (Socket Closed Unexpectedly)
- **现象**：当上下文超过 222k 字符时，DeepSeek 官方服务器可能会直接切断底层 HTTP 流，甚至来不及下发任何 `FINISHED` 或 `INCOMPLETE` 状态标记。这时代理内部的 `converter.rs` 在收到流末尾 (`None`) 时直接结束，导致未向 Anthropic 适配层发送 `message_stop` 事件。由于缺失合法的停止标记，客户端（如 Aider）直接抛出协议层网络错误：`API Error: The socket connection was closed unexpectedly.`
- **系统性修复**：
  - 在 `converter.rs` 的流轮询 `poll_next` 的 `Poll::Ready(None)` 分支中增加状态拦截。如果上游异常断流且状态机未置于 `finished` 状态，代理会手动生成一个携带 `finish_reason: "length"` 的结束 Chunk。这样 Anthropic 适配层就能发出合规的 `message_stop`，客户端将平滑识别为"上下文超长而截断"，而不是因为非法关流而发生崩溃。

### 8. UTF-8 字符截断引发的运行时 Panic (Rust 致命崩溃)
- **现象**：客户端再次遇到 `The socket connection was closed unexpectedly.`。经过分析日志，发现这一次并非网络层面的提前结束，而是代理网关本身发生了 **Rust 线程恐慌 (Panic)**。
  具体原因：当模型截断时触发 `RepairStream`，日志试图打印出残缺片段的前 200 个字节 `&tool_text[..tool_text.len().min(200)]`。由于 DeepSeek 偶尔会输出全角或特殊字符（如 `｜` 或 `▁`），它们在 UTF-8 编码下占用 3 个字节。字节切片刚好切碎了多字节字符的内部边界，直接导致 Rust 安全机制触发 `panic!`，进而瞬间强杀了对应的 Tokio 协程和所有的 TCP Socket 连接。
- **系统性修复**：
  - 在 `openai_adapter/response.rs` 中修复了所有字符串的切割逻辑。使用字符迭代器 `.char_indices().nth(200)` 来安全地获取前 200 个"字符"的正确字节偏移量，彻底杜绝了因多字节字符被劈开而导致的服务端崩溃。

---

## 四、超大上下文深水区 Bug（340k+ 字符 / 93k+ Token 场景）

### 9. 模型只思考不回答导致客户端静默中断 (Empty Response After Thinking)
- **现象**：当上下文达到 340k+ 字符（约 93k Tokens）时，DeepSeek 模型有时会消耗大量 Token 进行思考（`THINK` 碎片，167 字符），然后直接以 `FINISHED` 状态结束，**完全不产生任何 `RESPONSE` 碎片**。日志表现为：
  `WARN: 状态机 FINISHED 但无 RESPONSE 内容: fragments=["THINK/167"], accumulated_token_usage=Some(93885)`
  此时虽然 `stream.rs` 已有 Bug #2 的修复（注入空文本块），但该空文本块**内容长度为 0**。Aider 收到一个协议合法但语义全空的 assistant 消息后，将其解释为 API 返回异常而中断执行。
- **根因分析（三层数据流追踪）**：
  - **第一层 `state.rs`**：状态机在收到 `FINISHED` 时检测到无 RESPONSE，但只打了 WARN 日志，没有注入任何实质内容。`DsFrame::Status("FINISHED")` 直接流向下游。
  - **第二层 `converter.rs`**：`Status("FINISHED")` 被映射为 `finish_reason="stop"` 的 chunk。由于从未收到过 `ContentDelta`，下游看到的是一个只有 `role=assistant` + `finish` 的空响应。
  - **第三层 `stream.rs`**：在 `finish_reason` 处理中，`was_thinking=true`（因为最后一个活跃块是 THINK），于是注入了 `ResponseContentBlock::Text { text: "" }` 空块。**协议上合规（满足 Bug #2 的修复），但语义上空**——客户端认为模型没输出任何内容。
  - 该问题在 `INCOMPLETE`（超长截断）+ 无 RESPONSE 的场景下**同样存在**，但初始修复仅覆盖了 `FINISHED` 条件。
- **系统性修复（三层联防）**：
  - **`state.rs`（源头注入）**：当检测到 `FINISHED` 或 `INCOMPLETE` 状态且 fragments 中不存在非空 `RESPONSE` 碎片时，**在 Status 帧之前**注入一个携带零宽空格（`\u200b`）的 `DsFrame::ContentDelta`。这确保下游 `converter.rs` 一定会产出至少一个 content delta，使得 `stream.rs` 的文本块携带非空内容。
  - **`converter.rs`（兜底不变）**：原有 `Poll::Ready(None)` 分支的流提前结束保护仍然生效——如果上游连 Status 都没发就断了，会自动补发 `finish_reason="length"`。
  - **`stream.rs`（协议补齐不变）**：原有 `was_thinking || block_index == 0` 逻辑继续作为最后一道保险，确保空文本块满足 Anthropic 协议的 content block 要求。
- **与 Bug #2 的关系**：Bug #2 解决的是"协议层面缺少文本块"的问题（注入空壳），Bug #9 解决的是"语义层面文本块无内容"的问题（注入非空占位符）。两者互为补充。

### 10. 分块写入第二段收到空流导致 500 错误 (Chunk 2/2 Empty Stream)
- **现象**：当超大上下文（340k+ 字符）触发分块写入机制（chunked write）时，DeepSeek 服务端在成功接收第 1 段后，**第 2 段的 SSE 流直接返回空**（服务端静默断开 HTTP 连接）。日志表现为：
  `500 Internal Server Error Anthropic error: internal error: req=req-9d 分块 2/2 收到空流`
  此错误发生在 `ds_core/completions.rs` 的 `wait_ready_and_update()` 函数中——`stream.next().await` 返回 `None`，被转化为 `CoreError::Stream`，最终作为 Anthropic `Internal` 错误以 HTTP 500 响应返回。
- **根因分析**：
  - 这是 DeepSeek **服务端行为**：当 context 压力过大时，服务端可能在分块写入的后续请求中直接拒绝服务（不返回任何数据就关闭连接）。
  - 该错误发生在 SSE 流建立之前（`wait_ready` 阶段），因此 `converter.rs` 和 `stream.rs` 的流兜底机制**完全没有机会介入**——错误在更上游的 `ds_core` 层就已抛出。
  - 最终走 `AnthropicCompatError::Internal` -> HTTP 500 JSON 错误响应路径，Aider 收到 500 后中断。
- **当前状态**：此问题属于**上游服务端强制行为**，网关层面无法在 HTTP 流建立前伪造数据。目前的处理（返回 500 + 明确的错误消息 `分块 2/2 收到空流`）是合理且透明的。Aider 在收到 500 后会自动重试。
- **缓解建议**：如需进一步优化，可考虑在 `completions.rs` 的分块逻辑中加入重试机制（对第 2+ 段的空流做 1-2 次自动重试），但需权衡请求延迟和账号限流风险。

### 11. 空工具调用块触发 RepairStream 引发中断 (Empty Tool Block Triggers Repair)
- **现象**（2026-05-24 发现）：Aider 使用工具调用模式时，DeepSeek 模型偶尔会输出**内容为空的工具调用标签对**，如：
  ```
  <|tool▁calls▁begin|>
  <|tool▁calls▁end|>
  ```
  即开启了工具调用标签，但标签内**没有任何 JSON 工具调用内容**。日志表现为：
  ```
  WARN  adapter  tool_parser 解析失败→请求修复
  WARN  adapter  RepairStream 捕获修复请求: len=46, snippet='<|tool▁calls▁begin|>\n<|tool▁calls▁end|'
  WARN  adapter  tool_calls 修复失败: internal error: 修复模型返回无法解析为工具调用: []
  ```
  修复模型看到空内容，原样返回 `[]`，修复程序随即抛出 `Internal` 错误，整个请求中断。

- **与 Bug #3 的关系**：Bug #3 是 JSON **残缺**触发 Repair（有内容但被截断），本 Bug 是标签对**语义为空**触发 Repair（标签存在但里面什么都没有）。二者场景不同，原有修复不覆盖此 case。

- **根因分析**：
  - `tool_parser.rs` 的 `ToolCallStream` 状态机检测到了开始标签 `<|tool▁calls▁begin|>`，随即进入 `CollectingXml` 状态收集内容。
  - 当结束标签 `<|tool▁calls▁end|>` 到来时，`parse_tool_calls()` 拿到的 inner 内容为空字符串，无法解析为工具调用，于是触发 `ToolCallRepairNeeded` 错误，流向 `RepairStream`。
  - 模型幻觉产生这种"空包"的可能性：模型尝试调用工具，但在写入参数前改变了主意或被截断，导致产出了格式骨架但没有内容。

- **系统性修复**（`openai_adapter/response/tool_parser.rs`）：
  - 在 `ToolCallStream` 状态机的所有4个结束路径中增加**空块检测**：在尝试解析 JSON 之前，先检查 inner 内容是否为空字符串、`[]` 或 `{}`。
  - 一旦检测到空块，**不报错、不触发 RepairStream**，而是直接忽略这对标签，将状态机重置回 `Detecting`，输出流正常继续。
  - 已修复的4个路径：`Detecting` 状态检测到完整标签对、`CollectingXml` 状态接收完整标签、带 `finish_reason` 的 chunk 处理路径、`Poll::Ready(None)` 流结束路径。

- **关于"是否可以动态配置"的分析**：
  - **现有系统的动态配置能力**：工具调用标签配置（`ToolCallTagConfig`）已具备完善的动态配置体系：
    - 在 `config.rs` 中定义 `ToolCallTagConfig { extra_starts, extra_ends }`。
    - 在管理面板 `/admin/config` 的「工具调用标签」区块中可以在线增删自定义开始/结束标签，**无需重启服务**。
    - `TagConfig::from_config()` 在每次请求时从全局 `Arc<Config>` 读取最新配置，完全热加载。
  - **本次 Bug #11 的修复是否需要配置化**：本次修复的逻辑是"遇到空内容，忽略标签对"，这是**无条件的兜底行为**（任何一个空工具块都不该触发 Repair），其本身的逻辑没有任何"参数"可以让用户控制，因此**不需要暴露到配置文件**中。与标签字符串的增删（用户可能需要适应新的模型幻觉变体）性质不同，空块忽略是一个纯粹的协议健壮性补丁，固化在代码中是正确的做法。
  - **如果未来需要配置化的扩展场景**：若有需要让用户控制"空块处理行为"的场景（如：调试模式下将空块报告给客户端），可参照现有 `ToolCallTagConfig` 模式，在 `config.rs` 中增加字段（如 `ignore_empty_tool_blocks: bool`），并在 `TagConfig` 中携带该参数，最终在 `tool_parser.rs` 中读取即可，全程无需修改 Admin 页面以外的任何 UI 代码。

---

## 五、代码审查与次生问题修复（2026-05-24 补充）

### 12. 双重开始标签导致 JSON 解析失败 (Duplicate Start Tag)
- **现象**：模型幻觉输出两个连续的开始标签（例如 `<|tool_calls_begin|>\n<|tool_calls_begin|>[{...}]`）。`parse_tool_calls` 的 XML 解析器在提取 `inner` 内容时，内部包含了多余的第二个开始标签，导致 `inner.find('[')` 定位后，结束标签的匹配发生错位，正常解析路径失败，触发 `RepairStream`。
- **系统性修复**：
  - 在 `tool_parser.rs` 的 `parse_tool_calls_with` 中增加**嵌套标签剥离逻辑**。
  - 在提取出 `inner` 内容后，再次探测是否包含嵌套的 `start_tag`。如果包含，且其后跟着 JSON 数组 `[` 或对象 `{` 的标识符，则自动切除这层多余的外壳，直接解析最内层的纯净 JSON，彻底杜绝此类幻觉引起的解析崩溃。

### 13. 隐蔽的 UTF-8 字节切割残留隐患 (同 Bug #8)
- **现象**：在 Bug #8 中修复了 `response.rs` 中的切割逻辑，但代码审查发现在其他文件中仍有 3 处使用硬编码字节切片的逻辑，一旦遇到多字节字符（如中文或 `▁`）可能引发 `panic!`：
  - `state.rs:369` 的 `trace_frame` 函数 (`&s[..60]`)。
  - `tool_parser.rs:619` 和 `704` 的 `TRACE` 日志 (`&collected[..500]`)。
- **系统性修复**：
  - 将 `state.rs` 中的切片改为字符迭代器 `.char_indices().nth(60)`。
  - 将 `tool_parser.rs` 中的切片改为调用 `floor_char_boundary(collected, 500)`，确保按字符边界安全切割。

### 14. Anthropic 停止原因映射不严格 (Strict Mapping)
- **现象**：超长截断时 `state.rs` 抛出 `length` 停止原因，但 `finish_reason_map` 中没有显式处理，导致它被原样透传。虽然客户端碰巧兼容，但不符合严格的 Anthropic 协议。
- **系统性修复**：
  - 在 `anthropic_compat/response.rs` 中显式添加 `"length" => "max_tokens"` 的规范映射。

---

## 六、系统优化与增强功能 (Enhancements)

### 1. 核心请求日志可视化提升 (Log Level Visibility)
- **优化内容**：将 `handlers.rs` 中关键生命周期节点（如 `POST /v1/...` 和 `200 SSE stream started`）的日志级别从 `debug!` 提升为 `info!`，使用户在默认级别下能清晰观测每个请求的流入和处理进度，避免误判为代理"卡死"。

### 2. Aider/Claude Code 编辑死锁防幻觉拦截 (Anti-Hallucination Prompt Injection)
- **背景**：在超大上下文下，模型在使用 `Edit` 工具时容易"偷懒"，提供过短且不唯一的 `old_string`（如单行 `except: return None`），导致客户端无法精确定位替换位置，引发 `Error editing file` 并陷入无限重试死锁。此为上游模型能力局限，非代理错误。
- **优化方案**：
  - 在代理层构建 System Prompt 时（`openai_adapter/request/tools.rs`），针对带有工具调用的请求进行**隐式指令劫持**。
  - 强行注入一条防呆指令（Rule 12），要求模型提供的 `old_string` 必须包含充足上下文以确保 100% 唯一性，从代理层根治这种跨生态工具调用的幻觉死锁。

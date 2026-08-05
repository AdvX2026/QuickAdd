# Spike: deepseek-probe

M0 开工前的验证脚本。**不是产品代码**，跑完拿到结论就可以丢。

它要回答两个问题 —— 这两个问题不解决，写 UI 和数据模型都是在赌：

1. **thinking 开启时，响应体到底长什么样？** JSON 是干净地落在 `content` 里，还是被推理内容污染了？（PRD §13 第一条待确认）
2. **`deepseek-v4-flash` 的中文日期推理够不够用？** 这是整个项目最大的质量风险。

## 准备 API key

二选一，两种都不会进 git，也不会进 shell 历史：

```bash
# 方式一：写进 gitignored 文件（推荐）
echo 'sk-你的key' > secrets/deepseek.key

# 方式二：环境变量
export DEEPSEEK_API_KEY=sk-你的key
```

脚本从不打印、不记录、不写出 key。

## 运行

在**仓库根目录**执行（脚本按相对路径找 `secrets/` 和 `Spike/out/`）：

```bash
swift Spike/deepseek-probe.swift
```

参数：

```bash
--effort low|high|max     # reasoning_effort，默认 low
--no-thinking             # 关掉 thinking 做对照
--input "<文本>"           # 换自己的输入；此时跳过验收比对
```

建议至少跑这三组做对照：

```bash
swift Spike/deepseek-probe.swift --no-thinking
swift Spike/deepseek-probe.swift --effort low
swift Spike/deepseek-probe.swift --effort high
```

## 输出

终端打印四段：**响应结构**（`message` 上有哪些字段、usage、finish_reason）、**解析结果**（第一层直接解码是否成功，是否需要第二层剥壳）、**抽取内容**、**PRD §11 期望值对照**。

完整原始响应写到 `Spike/out/raw-<时间戳>-<effort>.json`（已 gitignore）。**响应结构那段和这个文件是本次 spike 的主要产物** —— 判断题 1 靠它。

## 怎么看结果

**问题 1** 看 `message keys` 那一行：

- 只有 `role, content` → JSON 干净，按 PRD §8.4 正常解析即可
- 多出 `reasoning_content` 之类 → 推理是独立字段，`content` 仍然干净，但要确认 `usage` 里 thinking token 怎么计
- `content` 里混进了推理文本 → 第二层剥壳（§8.4 tier 2）从"廉价保险"升级为"必需"，要重新设计

**问题 2** 看抽取内容与期望值对照。重点不是数量对不对，是：

- 「下周一早上九点」有没有算成正确日期（这是最容易错的）
- 「聊了一个半小时」有没有推出 `end = start + 1.5h`
- 「晚上」这种模糊时段怎么处理
- **「订机票」归到哪个日历** —— 它是有意设计的边界项，用来检验日历定义的边界描述是否生效

日历定义写死在脚本的 `staticPrompt` 里（创意/工作/生活/个人）。如果归类不准，改那段文字重跑，比改代码有效得多。

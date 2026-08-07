# notice — Settings

## `CalendarSetup` 里硬编码了具体的日历名，这是刻意的

`CalendarSetup.eventDefinitions` 是一张 `工作/创意/学习/个人/生活/旅行/睡眠/日历` → 说明文本的表。这八个名字是**本项目所有者本人 iCloud 里的日历标题**，不是通用分类。

这么做的理由：

- 说明文本是整个归类质量的命门。写坏了归类就崩（见根 `notice.md`「给判定标准，不要只举例」一节），写好了要反复在 spike 里验证。让它只存在于设备上的 UserDefaults 里，意味着**唯一一份验证过的文本不在版本库里** —— 重装、换机、清数据都要在 iOS 键盘上重敲八段共约五百字。
- QuickAdd 目前是单人自用工具。为「未来可能有别的用户」去做一层通用映射，属于给不存在的需求写代码。

**不要把它「修正」成从 EventKit 动态生成、或挪进 UserDefaults 当默认值。** 现在这样它跟 `Spike/deepseek-probe.swift` 一起进 git、一起 diff，改定义就是提一个 commit。

### 两条必须保住的行为

- **种子只填空，绝不覆盖**。用户手写的说明是设置里最贵的东西，`CalendarSetup.merge` 里那个 `written.isEmpty` 判断是唯一的护栏，`CalendarSetupTests` 钉住了它。
  - 副作用：把说明清空后再「重新读取」，种子会回来。这是有意的 —— 空说明不是一个有意义的状态，那一行会显示橙色告警。
- **改了这里要同步 `Spike/deepseek-probe.swift` 顶部的 `eventCalendars`**，反之亦然。两边漂了 spike 就预测不了 App 行为。流程见根 `notice.md`。

## 如果以后要上架

按标题匹配这件事**必须换掉**，否则对第一个非本人用户就是坏的：

1. **`eventDefinitions` 对别人全都匹配不上** → 所有日历说明为空 → 归类质量回落到没有定义的水平。不崩，但等于没配置。
2. **`defaultEventCalendarTitle = "日历"` 是中文系统下默认日历的本地化标题**，英文环境叫 "Calendar"。改用 `EKEventStore.defaultCalendarForNewEvents` 的标识符，别匹配字符串。
3. **说明文本只有中文**，要跟着做本地化。

建议的改法（成本从低到高）：

- **把这八段变成「模板」而不是「种子」**：`CalendarDefinitionEditor` 里加一组内置模板供用户一键插入再自行修改。文本的价值保住了，又不再假装知道对方的日历叫什么。这是改动最小的一条，推荐。
- 引导式配置：让用户把自己的日历逐个映射到内置分类上。
- 首次配置时让模型根据日历标题生成初稿。质量不可控，需要用户确认，不建议作为唯一路径。

无论走哪条，`merge` / `resolveDefault` 这两个纯函数和它们的测试都不用动 —— 变的只是 `seeds` 从哪来。

## 其他

- API Key 在 Keychain（`KeychainStore`，service `cn.Teethe.QuickAdd`），不进 UserDefaults、不进版本库。
- `AppSettings` 的每个属性都用 `didSet` 落盘，没有显式 save。新增属性记得同时加 `Key` 枚举项和 `didSet`。

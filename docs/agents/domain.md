# Domain Docs

本仓库采用 **single-context**。工程 skills 探索代码时，按以下规则读取领域文档。

## 探索前读取

- 根目录 `GLOSSARY.md`：项目术语及定义。
- `docs/adr/`：与当前工作相关的架构和设计决策。
- 如果以后存在根目录 `GLOSSARY-MAP.md`，优先按其中的索引读取与当前主题相关的各个 `GLOSSARY.md`。

这些文件不存在时，静默继续；不要因缺失而中断工作或建议预先创建。由 `domain-modeling` 在术语或决策真正确定后逐步建立；`grill-with-docs` 等工程 skills 可调用它。

## File structure

```text
/
├── GLOSSARY.md
├── docs/
│   ├── agents/
│   │   ├── issue-tracker.md
│   │   └── domain.md
│   └── adr/
│       ├── 0001-<decision>.md
│       └── 0002-<decision>.md
└── Sources/
```

这是约定的布局；`GLOSSARY.md` 与 ADR 按需产生。

## 使用术语表中的词汇

在 Issue 标题、重构建议、假设或测试名称中提到领域概念时，使用 `GLOSSARY.md` 已定义的术语，避免采用术语表明确排除的同义词。

需要的概念尚未收录时，先检查它是否符合项目现有语言；确有缺口时，记录给 `domain-modeling` 补充。

## 明确指出 ADR 冲突

建议或输出与既有 ADR 冲突时，指出具体 ADR、冲突内容和重新讨论的理由，不要静默覆盖已有决策。

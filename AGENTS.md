# 项目 Agent 约定

## Agent skills

### Issue tracker

需求、缺陷和开发规格使用 `trrywui/textlet` 的 GitHub Issues 管理。详见 `docs/agents/issue-tracker.md`。

### Domain docs

采用 single-context：根目录 `GLOSSARY.md` 和 `docs/adr/`。详见 `docs/agents/domain.md`。

## 构建约束

生产构建与测试构建必须分离，按 `README.md` 的“构建与验证”执行。自动验证只运行 `bash scripts/test.sh`；测试结束时项目内不得新增测试 `.app`，`/private/tmp` 中不得遗留 `textlet-tests.*`。

Finder 自动探针、性能基准和独立实验构建均已退役。`docs/` 与 `Benchmarks/` 中的旧命令仅作历史证据，除非用户明确要求恢复，否则不要执行或重新生成对应测试应用和临时目录。真实系统功能手测完成后运行 `bash scripts/clean-generated.sh`。

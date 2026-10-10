# Issue tracker: GitHub

本仓库的需求、缺陷、开发任务和规格使用 GitHub Issues 管理，通过 `gh` CLI 操作。

- 仓库：`trrywui/textlet`
- 地址：https://github.com/trrywui/textlet/issues
- 在仓库内运行时，`gh` 可从 Git remote 推断目标仓库；需要明确指定时使用 `--repo trrywui/textlet`。

## Conventions

- 创建 Issue：`gh issue create --repo trrywui/textlet --title "..." --body-file <body.md>`。
- 读取 Issue：`gh issue view <number> --repo trrywui/textlet --json number,title,body,labels,comments`。
- 列出 Issue：`gh issue list --repo trrywui/textlet --state open --json number,title,body,labels,comments`，按需添加 `--label` 和 `--state`；较多任务应调整 `--limit` 或使用分页查询。
- 编辑正文：`gh issue edit <number> --repo trrywui/textlet --body-file <body.md>`。
- 添加评论：`gh issue comment <number> --repo trrywui/textlet --body-file <comment.md>`。
- 添加或移除标签：`gh issue edit <number> --repo trrywui/textlet --add-label "..."` 或 `--remove-label "..."`。
- 关闭 Issue：先留下处理结论，再运行 `gh issue close <number> --repo trrywui/textlet`。
- 多行正文与评论先写入临时文件，再用 `--body-file` 提交，保留真实换行。
- 子任务：`gh issue create --repo trrywui/textlet --parent <parent> ...`；已有任务可用 `gh issue edit <parent> --repo trrywui/textlet --add-sub-issue <child>` 关联。旧版 CLI 或仓库不支持子任务时，在父任务中使用任务列表，并在子任务正文顶部写 `Part of #<parent>`。

## Pull requests as a triage surface

**PRs as a request surface: no.**

将此配置改为 `yes` 后，外部 PR 才进入 triage 队列，使用与 Issue 相同的状态与标签：

- 读取 PR：`gh pr view <number> --repo trrywui/textlet --comments`；检查代码：`gh pr diff <number> --repo trrywui/textlet`。
- 外部 PR 的作者不属于 `OWNER`、`MEMBER` 或 `COLLABORATOR`；列举队列时按 `author_association` 筛选。
- 评论、标签和关闭操作分别使用 `gh pr comment`、`gh pr edit` 和 `gh pr close`；多行正文使用 `--body-file`。

GitHub 的 Issue 和 PR 共用编号。遇到未明确类型的 `#42`，先尝试 `gh pr view 42`；确认不是 PR 后，再使用 `gh issue view 42`。

## 当 skill 要求“发布到 issue tracker”

创建 GitHub Issue。

## 当 skill 要求“获取相关 ticket”

按上述读取方式，获取指定 Issue 的正文、标签和评论。

## Wayfinding operations

供 `wayfinder` 使用：一个 map Issue 汇总工作，每个 ticket 是关联的子 Issue。

- **Map**：使用 `wayfinder:map` 标签，正文包含 Notes、Decisions-so-far 和 Fog。
- **Child ticket**：关联为 map 的子任务；不支持子任务时，使用父任务列表和 `Part of #<map>`。任务类型使用 `wayfinder:research`、`wayfinder:prototype`、`wayfinder:grilling` 或 `wayfinder:task` 标签。
- **Blocking**：优先使用 GitHub 原生依赖；支持该选项的 CLI 可用 `gh issue edit <child> --repo trrywui/textlet --add-blocked-by <blocker>`。不支持时，在正文顶部记录 `Blocked by: #<n>, #<n>`。所有阻塞任务关闭后，任务才可开始。
- **Frontier**：读取 map 的子任务，筛选仍开放、没有未完成依赖、尚未指派的任务，按 map 中的顺序选择。
- **Claim**：开始工作前，用 `gh issue edit <number> --repo trrywui/textlet --add-assignee @me` 认领。
- **Resolve**：评论记录结果、关闭 ticket，并在 map 的 Decisions-so-far 中追加结论摘要与链接。

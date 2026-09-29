# Textlet

面向 macOS 14 Intel 的原生纯文本编辑器。Swift + AppKit，无 WebView、Electron、第三方运行时和语言服务器。当前版本为 **0.5.0（build 7）**，默认采用已试用的 CPU/内存平衡绘制实现。50MB 不是所有场景下的硬上限，性能取舍见 [平衡报告](docs/逐行绘制CPU内存平衡-2026-09-28.md)。

## 运行

运行 `bash scripts/build.sh`，得到正式项目的 `build/Textlet.app`，可拖进“应用程序”目录。本机构建采用临时签名，尚未公证。安装前退出旧 Textlet，避免同一草稿目录被两个进程使用。

## 0.5.0 更新与项目归档

优化试用版的绘制实现已成为正式构建默认：复用未变化的行图片、限制离屏缓存、合并绘制请求，并减少纯文本编辑不需要的 Touch Bar 状态更新。应用名仍为 **Textlet**，草稿目录仍为 `~/Library/Application Support/Textlet/`，不自动迁移试用版草稿。

后续功能直接在 `/Users/lee/workspace/code/textlet` 开发。整合前的完整项目快照位于 `archives/textlet-before-promotion-2026-09-28/`，包含当时的未提交代码、测试记录、构建产物和独立 Git 历史包；该本地归档不纳入 Git。它保存了原正式构建及当时已有的实验实现，不能直接当成只有旧版代码的干净分支。

交接与验证见 [正式版整合记录](docs/正式版整合-2026-09-28.md)。电脑中已安装的应用和用户草稿未在本次整合中删除或替换；项目外测试遗留见 [清理交接清单](docs/项目外测试遗留清单-2026-09-28.md)。

## 0.4.1 更新

应用名称、窗口标题、菜单与关于信息统一为 **Textlet**；项目目录和本地 Git 仓库目录为 `textlet`，可执行文件为 `textlet`，主控制器类型与 Swift 模块名为 `Textlet`。图标采用 01 方案：深橄榄灰底、米白 T 和琥珀色横画，使用静态 `.icns` 资源，不增加运行时绘制或依赖。

## 0.4 功能

- **经典 Monokai。** 固定深橄榄灰底色、暖白正文和琥珀色标签标记，统一正文、行号、标签和状态栏；使用原生控件及纯色绘制。
- **SQL / YAML / TOML 基础高亮。** 打开 `.sql`、`.yaml`、`.yml`、`.toml` 自动识别，扩展名不区分大小写。通过“语法”菜单手动切换，或选“纯文本”关闭高亮；每个标签独立保存选择，重启恢复。新建临时笔记默认纯文本。“按文件名自动识别”模式下，重命名后会重新识别。
- **大文件保持纯文本。** 超过 8MiB 或手动以只读日志模式打开的文件均不高亮，保留分段查看和全文件搜索。

SQL 识别常用关键词、引号文本、数字和注释；YAML 识别常用键名、引号文本、布尔值、数字、注释和缩进块文本；TOML 识别配置段、键名、字符串（含三引号）、数字、布尔值和注释。这是基础着色，不是完整语法解析器，不提供语义分析、错误检查或代码补全；部分 SQL 方言及复杂配置语法可能不会准确着色。


- **0.3.1 标签滚动条。** 底部显示 3pt 浅灰色圆角细条，继续使用系统原有的滚动及自动隐藏机制，不增加悬停效果、额外视图或常驻计时器。

- **替换：`⌘R`。** 打开 macOS 原生查找替换栏，支持单次替换、全部替换、撤销和重做。只读日志不可替换；切到日志时关闭普通替换栏，日志仍使用全文件搜索。查找和替换输入框也关闭智能引号、破折号和自动纠错。
- **双击标签栏空白处新建笔记。** 点击已有标签仍然切换标签；单击空白处不新建。
- **复用标签控件。** 切换标签只更新选择状态，避免反复销毁、创建按钮、约束和标签视图；正文和撤销记录不因此删除。进入后台时，在辅助线程归还分配器已经空闲的内存页，不清除仍在使用的正文和撤销记录。

## 编辑与查看

- **JSON 格式化：`⌘⇧J`。** 有选区时格式化选区，否则格式化全文；两空格缩进，一次撤销即可还原。保留键顺序、重复键、数字原始表示和字符串转义；非法 JSON 提示错误，不修改原文。单次输入限 2MiB、输出限 8MiB、嵌套限 128 层，避免异常输入撑大内存。
- **行号。** 仅绘制可见逻辑行；自动折行不会增加行号。小笔记支持 LF、CRLF、CR 和 Unicode 换行。大日志按 LF/CRLF/CR 计数，显示文件中的绝对行号。
- **大日志分段查看。** 超过 8MiB 的文件自动进入只读模式；小文件也可通过“文件 → 以只读日志模式打开”使用。每段约 48KiB，后台以 256KiB 缓冲扫描并建立稀疏行号索引，不把整个文件读进编辑器或复制到草稿。

## 大日志操作

顶部工具栏可跳到开头、末尾、上一段、下一段，也可拖动位置滑块跳转。索引建立期间先显示开头，索引完成后可任意跳转。段内使用普通滚轮滚动、选择和复制；**全选只选中当前段**。

`⌘F` 聚焦全文件搜索，回车或 `⌘G` 查找下一个，搜索至末尾会从开头继续。搜索为区分大小写的 UTF-8 字面搜索，不支持正则；单次查询最长 4096 字节。“停止”取消当前扫描。查找结果会定位并选中对应文本，搜索不会保存全文件匹配列表。

- 大日志支持 UTF-8 / ASCII。UTF-16/32 BOM 文件会提示先转换；无效 UTF-8 字节在视图中显示为 `�`，原文件不变。
- 超长单行也分段，续段第一行用 `↳` 标识，状态栏显示实际起始行号。
- 文件发生追加、截断、修改或替换后，点击“重新载入”读取新内容；当前不自动追踪实时日志。
- 退出后恢复路径、分段位置和段内滚动位置。原文件缺失时该标签显示错误，其他草稿仍能恢复。
- 日志只读，`⌘S`、`⌘R` 和 JSON 格式化不可用；关闭日志标签不删除原文件。

## 日常操作

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` | 新建笔记 |
| `⌘O` | 打开文本；超过 8MiB 自动进入只读日志模式 |
| `⌘S` | 导出普通笔记为 UTF-8 文件 |
| `⌘⇧J` | 格式化选中 JSON 或全文 |
| `⌘F` / `⌘G` | 查找 / 查找下一个 |
| `⌘R` | 查找并替换（普通笔记） |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做 |
| `⇧⌘]` / `⇧⌘[` | 下一个 / 上一个标签 |
| `⌘+` / `⌘-` | 放大 / 缩小文字 |
| `⌘W` | 关闭当前标签；空草稿直接关闭，有内容时选择不保存、保存或取消 |
| `⌘Q` | 保存会话并退出，下次恢复 |

关闭窗口也会保存会话并退出。要保留笔记，直接退出即可，不必逐个关闭标签。

有内容的普通标签关闭时提示“您想保存对文件所做的更改吗？”，按钮从左到右为“不保存、保存、取消”。保存会打开现有 UTF-8 导出面板，成功后关闭标签；取消面板或导出失败会保留标签。空格、换行也算内容。关闭最后一个标签后会保留一个新的空白标签。

窗口退出时的尺寸与位置随会话保存，下次启动恢复；双击标题栏放大后的窗口同样恢复为放大尺寸。显示器断开或分辨率改变时会调整到当前屏幕可见区域。

普通文本打开为草稿副本，自动保存不会改写原文件。需要写回文件时，使用 `⌘S` 导出并选择原路径。每个普通标签有独立撤销记录。

编辑区粘贴纯文本，关闭智能引号、破折号、自动文本替换、自动纠错、补全和智能空格插入。去除的是字体、颜色等格式；原文已有的弯引号、不换行空格等字符不会被擅自替换。

## 草稿与恢复

默认目录为 `~/Library/Application Support/Textlet/`，可从“帮助 → 打开草稿目录”访问。输入暂停 0.8 秒后保存；切换标签、切到后台和退出时也保存。

- 内容先写入新的修订文件，再原子替换会话清单，保留当前和上一代快照。
- 当前快照损坏时尝试上一代并提示；两代都损坏时停止加载，不覆盖原稿。
- 同一草稿目录只允许一个写入进程；保存失败会阻止正常退出。
- 0.4 可读取 0.1 / 0.2 / 0.3 会话；写入仍使用 v2 清单，新增可选的标签语言字段。
- 窗口位置使用可选的 `windowFrame` 字段；旧会话没有此字段时使用默认窗口大小。
- 撤销记录不跨重启保留；突然断电或强制结束进程仍可能丢失最后尚未保存的输入。

## 内存设计与边界

所有标签共用一个 `NSTextView` / `NSLayoutManager`。不活动且无撤销记录的普通标签在进入后台时释放正文缓冲。大日志仅保留稀疏索引和文件描述符；活动视图最多显示约 48KiB，文件内容不进入草稿和撤销记录。行号使用自绘栏，限制绘制范围，不使用系统标尺的附加视觉效果。

高亮共用当前编辑器，只对可见范围添加临时文字颜色，最多覆盖 64Ki 个 UTF-16 单元；切换标签时释放高亮状态，不给后台标签保留着色副本。为识别前文中的多行注释/字符串，按约 4096 个 UTF-16 单元记录稀疏状态，远距离跳转分批扫描；输入和滚动事件合并处理，无空闲轮询。高亮不进入草稿、导出文本和撤销记录。直接粘贴超过 8Mi 个 UTF-16 单元的草稿也停止着色。

Java、Python、Rust 和 JSON 尚无语法高亮；JSON 格式化仍然可用。大日志采用分段查看，不是全文件连续滚动编辑。无限标签、撤销历史、字体缓存、窗口尺寸和系统绘制都可能影响内存。

“帮助 → 性能信息”显示进程 `TASK_VM_INFO.phys_footprint`、本次运行物理占用峰值、RSS、窗口尺寸和像素倍率，单位 MiB。50MB（十进制）约为 47.68MiB。测量不包含 WindowServer 和输入法等独立进程，采样可能漏掉瞬时峰值。自动测试含中文和 emoji，但不等于真实中文输入法或长时间常驻测试。

## 项目结构

- `Sources/`：应用代码，主控制器为 `Textlet.swift`。
- `AppIcon.svg` / `AppIcon.icns`：图标矢量源文件与应用图标。
- `Tests/`：功能测试与窗口基准测试。
- `scripts/`：构建和合成日志生成脚本。
- `docs/`、`Benchmarks/`：性能报告、历史测量及验收记录。
- `build/`：本机构建产物，已被 Git 忽略。
- `test-output/`：新的测试会话、临时基线源码与检查输出，已被 Git 忽略。
- `archives/`：整合前的本地项目归档，已被 Git 忽略。

## 构建与测试

需要 Xcode / Command Line Tools，目标为 `x86_64-apple-macosx14.0`。

```sh
bash scripts/build.sh
./build/Textlet.app/Contents/MacOS/textlet --build-info
./build/Textlet.app/Contents/MacOS/textlet --self-test
```

构建脚本也可接收自定义 `.app` 输出路径。需要重新生成图标时，执行 `bash scripts/build-icon.sh`（由 `scripts/icon.swift` 按矢量源的几何绘制），随后重新构建应用。应用包、压缩包和大型日志不纳入 Git。

下列示例均从项目根目录运行，先执行 `mkdir -p test-output`。每次新测量应使用未占用的会话目录。普通窗口回归测试持续约 30 秒，自动结束。附加 `--stress` 测试十标签。

```sh
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-small-session \
  --benchmark test-output/textlet-small.json
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-small-session \
  --restore-check test-output/textlet-small.expected.json
```

大日志与 JSON 快捷键测试：

```sh
python3 scripts/make-log-fixtures.py test-output/textlet-fixtures
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-log-session \
  --feature-benchmark test-output/textlet-log.json \
  --log-fixture test-output/textlet-fixtures/500MB.log
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-log-session \
  --feature-restore test-output/textlet-log.expected.json
```

所有测试必须用隔离目录。基准测试拒绝覆盖已有会话；重启检查使用相应测试会话。测试窗口会自行切换、编辑和隐藏，请勿操作它们。测试结束后才截图；普通启动不采样、不截图。原始结果见 `Benchmarks/v0.2/` 和 `Benchmarks/v0.3/`。


替换、标签双击、循环切换/编辑/撤销和大小窗口内存测试约 90 秒：

```sh
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-interaction-session \
  --interaction-benchmark test-output/textlet-interaction.json
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-interaction-session \
  --restore-check test-output/textlet-interaction.expected.json
```

附加 `--quick-check` 可运行约 17 秒的快速功能检查，跳过大小窗口和长循环测量。

该测试使用合成文本和隔离会话，临时使用并还原系统查找剪贴板，不修改普通剪贴板。大窗口失去焦点后保持显示，用于区别“后台但仍可见”和“隐藏窗口”。报告检查结果之外还需核对实际循环次数和前台采样数。


0.4 的针对性检查（未追加大范围性能测试）：

```sh
./build/Textlet.app/Contents/MacOS/textlet --syntax-test
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-appearance-session \
  --appearance-check test-output/textlet-appearance.json
```

第二项约 8 秒，只用合成文本检查配色、三种高亮、语言保存、撤销、只读模式和查找替换栏；草稿目录必须为空。截图仅用于检查测试窗口外观。

关闭标签与窗口恢复回归：

```sh
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-lifecycle-session \
  --lifecycle-check test-output/textlet-lifecycle.json
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-window-session \
  --window-check test-output/textlet-window-zoom.json --window-size zoom
./build/Textlet.app/Contents/MacOS/textlet \
  --data-dir test-output/textlet-window-session \
  --window-check test-output/textlet-window-restored.json
```

关闭回归必须使用新建的隔离草稿目录，输出目录也应独立且为空（会生成合成导出文件）。窗口回归可使用 `--window-size small` 验证小窗口退出与恢复。GUI 测试需要可访问 macOS 图形会话。

关闭回归使用真实确认框和文件写入，路径选择由测试替身提供，不代表系统保存面板交互已经完整自动化验证。附加 `--no-screenshot` 可禁用关闭确认框截图，便于独立进行内存扫描。本次完整结果和限制见 [2026-09-27 回归报告](docs/回归测试-2026-09-27.md)。


## 可选的独立实验构建

可单独构建带完整编辑功能的“Textlet 实验版”：

```sh
bash scripts/build-experimental.sh
open 'build/Textlet Rows.app'
```

正式版与实验版现在使用同一套优化绘制实现，均保留系统输入、撤销、查找替换及现有功能。实验构建额外启用 `TEXTLET_EXPERIMENTAL`，草稿位于独立的 `~/Library/Application Support/Textlet-Rows-Experiment/`，不会自动导入正式版草稿。日常使用和后续功能开发以正式构建为准。

使用方法和测量边界见 [实验版说明](Experiments/TextletRows/README.md)；完整结果见 [实验版集成验证](docs/Textlet实验版集成验证-2026-09-27.md)。

正式版的行图片缓存预算为 32MiB，供滚动复用；这不是整个应用的内存上限，可见行超出预算时优先保证显示。历史实验报告中“正式版”“原版”指当时的旧构建，请按报告日期理解。验证过程与取舍见 [CPU/内存平衡报告](docs/逐行绘制CPU内存平衡-2026-09-28.md)。

连续输入、滚动和停止后的 CPU 对照见 [2026-09-28 测量报告](docs/真实连续输入与滚动CPU对照-2026-09-28.md)。

# Textlet 实验版

逐行绘制的 CPU/内存平衡实现已在 Textlet 0.5.0 成为正式构建默认。此目录保留实验工具和历史对照说明；独立实验构建仍可用于隔离草稿。两种构建都保留 NSTextView / TextKit 的输入、排版、撤销和查找替换，使用可见行图片缓存替代正文整体位图；背景和选区用图层绘制。

```sh
bash scripts/build-experimental.sh
open 'build/Textlet Rows.app'
```

应用名为“Textlet 实验版”，标识为 `local.textlet.rows-experiment`。默认草稿保存到 `~/Library/Application Support/Textlet-Rows-Experiment/`。与正式版草稿目录分开；退出后可恢复自己的标签与正文。不会自动导入正式版草稿。

这与 `Experiments/RowRenderer` 中不保存草稿的最小原型不同：实验版使用完整应用功能，没有原型的 128Ki UTF-16 正文限制，保留 JSON 格式化、高亮、行号和大日志分段查看。

实现入口为 `Sources/RowRenderingTextView.swift`，在 `ROW_RENDERER` 编译条件下启用。`scripts/build.sh` 和 `scripts/build-experimental.sh` 均启用它，实验脚本另加 `TEXTLET_EXPERIMENTAL` 来隔离应用身份。普通构建输出正式的 `build/Textlet.app`。

## 验证

所有测试使用合成数据和独立临时目录。带值的参数写在无值开关前，避免 AppKit 将后续路径当作待打开的文件。

```sh
APP='build/Textlet Rows.app/Contents/MacOS/textlet-rows'
"$APP" --self-test
"$APP" --syntax-test
mkdir -p test-output
RUN_DIR=$(mktemp -d "$PWD/test-output/rows-check.XXXXXX")
"$APP" --data-dir "$RUN_DIR/session" --rows-check "$RUN_DIR/result.json"
```

`--rows-check` 约40秒，测量大小窗口、短文本和满屏文字；在停止内存采样后检查画面、中文组合输入、撤销和查找栏。追加 `--quick-check` 只运行快速功能检查，不用于内存结论。

实验数据只统计应用自身的 `phys_footprint`，不包含 WindowServer、输入法进程或独显显存。比较之前要确认显卡、窗口尺寸和前台状态一致。图层快照不等同于操作系统屏幕截图，也不代表真实输入法候选窗已验证。


## 完整应用的同条件对照

历史对照使用同一份源码分别编译原绘制和逐行绘制，并通过 `--rendering-comparison` 测量。现在两个默认构建均使用优化绘制，不能再把 `scripts/build.sh` 的产物标成原绘制。若需复现整合前的对照，先将归档快照复制到项目内的临时目录，再用其原构建脚本（保留归档本身不变）：

```sh
mkdir -p test-output
RUN_DIR=$(mktemp -d "$PWD/test-output/comparison.XXXXXX")
cp -R archives/textlet-before-promotion-2026-09-28/project "$RUN_DIR/source"
TMPDIR="$RUN_DIR/" bash "$RUN_DIR/source/scripts/build.sh" "$RUN_DIR/Native.app"
TMPDIR="$RUN_DIR/" bash "$RUN_DIR/source/scripts/build-experimental.sh" "$RUN_DIR/Rows.app"
python3 Experiments/TextletRows/compare.py \
  --native-app "$RUN_DIR/Native.app" \
  --rows-app "$RUN_DIR/Rows.app" \
  --output "$RUN_DIR/results"
```

输出目录必须不存在。两轮顺序运行，每轮约一分钟，均使用全新临时会话。测试操作数固定，慢帧会延长阶段，不会少做操作；比较相同文字、字体、窗口尺寸、倍率与前台状态。运行前后及过程中每两秒采集 `ActiveGPU` 和 `SwitchCount`，条件不一致时返回失败并保留原始记录。当前显卡核对依赖本机 Intel/AMD 双显卡的 AppleMuxControl。

测试全程不截图；分别记录采样最高值、系统累计峰值、停止操作后的末值，以及每阶段编辑/绘制的主线程耗时。CPU耗时不代表输入法或GPU端到端延迟。只统计被测应用进程，其他应用可以保留打开，但测量期间应保持测试窗口在前台。

2026-09-27 的完整应用集显对照结果见[同条件报告](../../docs/完整应用同条件绘制对照-2026-09-27.md)。

## 连续输入与滚动 CPU 对照

使用 `--real-usage-benchmark` 可以在完整应用上测量密集文本的连续输入、连续滚动以及停止后的空闲 CPU。测试窗口应使用全新的 `--data-dir`，并通过系统的 `open -n -W` 启动应用包，使它保持前台：

```sh
mkdir -p test-output
RUN_DIR=$(mktemp -d "$PWD/test-output/real-usage.XXXXXX")
open -n -W 'build/Textlet.app' --args \
  --data-dir "$RUN_DIR/session" \
  --real-usage-benchmark "$RUN_DIR/result.json"
```

原版应用可以用同样的参数运行。测试会发送经过 AppKit 窗口和 `NSTextView` 事件路径的合成键盘事件，以及经过 `NSScrollView` 的滚动事件；它测的是编辑和绘制开销，不包含物理键盘输入或真实中文输入法候选窗。结果说明见[连续输入与滚动 CPU 对照报告](../../docs/真实连续输入与滚动CPU对照-2026-09-28.md)。

# Textlet 逐行绘制实验

独立的 Swift + AppKit + Core Text 原型，用来验证能否降低大窗口的文字绘制内存。不替换正式 Textlet，不访问草稿目录。输入内容不自动保存；菜单中的“载入文本”会替换当前实验内容。

## 打开试用

项目根目录运行：

```sh
bash Experiments/RowRenderer/build.sh
open build/RowRenderer.app
```

放大窗口后直接输入。菜单“实验”可载入短文本或多行文本，或查看内存。支持基本输入、退格/Delete、方向键、Shift+方向键选择、鼠标拖选、滚轮、剪切/复制/粘贴、全选和撤销重做。

原生输入框对照：

```sh
open -n build/RowRenderer.app --args --mode native
```

## 思路

背景只设置颜色，不绘制完整窗口位图；文字用 Core Text 排版，按可见行生成窄幅 CGImage，交给 CALayer 合成。空白区域不生成文字位图，未变化的行复用图像，滚出视口后丢弃。选区、组合输入下划线、光标使用独立图层。按窗口的真实像素倍率生成文字，未降低 Retina 清晰度。

原生对照使用同一应用外壳、相同字体、文字颜色、23pt 行高、20pt 内边距、窗口尺寸和操作时序。逐行原型使用自定义 NSView / NSTextInputClient，不借助屏幕外的 NSTextView；对照使用系统 NSTextView / NSScrollView。

原型限制输入为 128Ki 个 UTF-16 单元；这是文档大小的实验边界，不是内存目标。每次修改会重排全文，尚无生产级增量排版。双击仅选中单个组合字符；不支持完整的按词移动、所有系统编辑快捷键、查找替换或完整无障碍文本访问。没有标签、保存恢复、语法高亮或生产日志功能。

已实现组合输入接口和程序化测试，但不等于真实中文输入法候选窗、拼音选词等端到端验证。复制粘贴只有用户实际执行命令时才访问系统普通剪贴板；自动基准不使用它。

## 测试

```sh
build/RowRenderer.app/Contents/MacOS/row-renderer --self-test \
  --test-output /tmp/row-renderer-self-test.json
build/RowRenderer.app/Contents/MacOS/row-renderer --mode rows \
  --benchmark /tmp/rows.json --vmmap --capture
build/RowRenderer.app/Contents/MacOS/row-renderer --mode native \
  --benchmark /tmp/native.json --vmmap --capture
python3 Experiments/RowRenderer/summarize.py Benchmarks/2026-09-27/row-renderer
```

基准每组约54秒；附加截图约55秒。依次测小窗口编辑、放大、短文本编辑、空闲、载入满屏文本、连续编辑、滚动、缩回小窗口。每次使用独立进程，顺序运行以避免焦点干扰，不操作测试窗口。

`--vmmap` 可选，仅扫描实验进程。`--capture` 仅在所有采样结束后截取实验窗口，因此截图不计入报告峰值。基准只测本进程 phys_footprint，不含 WindowServer；50ms采样最高值与系统累计峰值分别记录。编辑耗时包含调用、布局和 displayIfNeeded 返回，不包含 GPU 完成，不能当作端到端显示延迟。

详细结果见 [实验报告](../../docs/逐行绘制实验-2026-09-27.md)。

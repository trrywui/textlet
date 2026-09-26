"""生成合成日志；不读取真实日志。用法：python3 make-log-fixtures.py /tmp/textlet-fixtures"""
from pathlib import Path
import sys

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
line = "2026-09-25 16:30:00 INFO 请求处理完成 user=123 trace=abcdef0123456789 中文🙂 --flag  保留空格\r\n".encode()
block = line * 8000
for megabytes in (100, 500):
    path = root / f"{megabytes}MB.log"
    with path.open("xb") as stream:
        target = megabytes * 1_000_000
        while stream.tell() + len(block) < target:
            stream.write(block)
        while stream.tell() + len(line) < target:
            stream.write(line)
        stream.write("TEXTLET_NEAR_END 中文🙂\r\n最后一行，无换行".encode())
    print(path, path.stat().st_size)

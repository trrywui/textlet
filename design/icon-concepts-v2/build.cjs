const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const dir = __dirname;
const designs = [
  {
    name: 'Textlet', id: 'textlet', bg: '#24251F',
    mark: '<path fill="#EEEDE4" d="M140 146H296V202H284V374H228V202H140Z"/><path fill="#E6B450" d="M308 146H372V202H308Z"/>',
    description: '断开右端的大写 T；琥珀色横画呼应 Monokai。'
  },
  {
    name: 'Textbit', id: 'textbit', bg: '#1C2129',
    mark: '<path fill="#DEE5E9" d="M232 208H288V220H364V272H288V338C288 348 294 352 304 352H348V404H290C250 404 232 384 232 346V272H156V220H232Z"/><path fill="#8EBACD" d="M232 128H288V188H232Z"/>',
    description: '小写 t 顶端拆出一个蓝灰方块，强调轻巧与小片段。'
  },
  {
    name: 'Textmark', id: 'textmark', bg: '#242124',
    mark: '<path fill="#EBE7DF" d="M160 140H382L368 202H344L344 184H302L264 354H292L284 382H172L180 354H204L242 184H198L188 202H146Z"/><path fill="#C69272" d="M165 402H295L291 414H161Z"/>',
    description: '窄斜体 T 与细短下划线，偏排印与阅读气质。'
  },
  {
    name: 'Mintext', id: 'mintext', bg: '#1F2524',
    mark: '<g fill="none" stroke-width="24" stroke-linecap="square" stroke-linejoin="round"><path stroke="#E5E9E3" d="M132 176V298Q132 330 164 330H176M98 224H178M350 176V298Q350 330 382 330H394M316 224H396"/><path stroke="#9CBAA7" d="M216 232L272 320M272 232L216 320"/></g>',
    description: '紧凑的 txt 字形；灰绿 x 连接两侧米白 t，最接近文本文件的直接表达。'
  }
];
function icon(d) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img" aria-label="${d.name} icon"><title>${d.name}</title><rect x="28" y="28" width="456" height="456" rx="100" fill="${d.bg}"/>${d.mark}</svg>`;
}
function nested(d, x, y, size) {
  return `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="0 0 512 512"><rect x="28" y="28" width="456" height="456" rx="100" fill="${d.bg}"/>${d.mark}</svg>`;
}
(async () => {
  for (const d of designs) {
    const svg = icon(d);
    fs.writeFileSync(path.join(dir, `${d.id}.svg`), svg + '\n');
    await sharp(Buffer.from(svg), { density: 192 }).resize(1024, 1024).png().toFile(path.join(dir, `${d.id}.png`));
    for (const size of [24,40,64]) {
      await sharp(Buffer.from(svg), { density: 192 }).resize(size, size).png().toFile(path.join(dir, `${d.id}-${size}.png`));
    }
  }
  let body = '<rect width="960" height="900" fill="#111312"/>';
  designs.forEach((d, i) => {
    const cx = i % 2 ? 720 : 240;
    const y = i < 2 ? 20 : 462;
    body += nested(d, cx - 128, y, 256);
    body += `<text x="${cx}" y="${y + 288}" fill="#E4E7E1" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="23" font-weight="500">${String(i + 1).padStart(2,'0')} / ${d.name}</text>`;
    const slots = [{s:24,c:cx-68},{s:40,c:cx},{s:64,c:cx+80}];
    for (const {s,c} of slots) {
      // Embed rasterized small assets at 1:1 rather than relying on the browser's SVG scaling.
      const png = fs.readFileSync(path.join(dir,`${d.id}-${s}.png`)).toString('base64');
      body += `<image href="data:image/png;base64,${png}" x="${c-s/2}" y="${y+340-s/2}" width="${s}" height="${s}"/>`;
      body += `<text x="${c}" y="${y+394}" fill="#969F98" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="12">${s}px</text>`;
    }
  });
  const board = `<svg xmlns="http://www.w3.org/2000/svg" width="960" height="900" viewBox="0 0 960 900"><title>Text editor icon concepts — flat typography</title>${body}</svg>`;
  fs.writeFileSync(path.join(dir,'comparison.svg'),board+'\n');
  await sharp(Buffer.from(board)).png().toFile(path.join(dir,'comparison.png'));
  fs.writeFileSync(path.join(dir,'concepts.json'), JSON.stringify(designs.map(({name,id,bg,description})=>({name,id,background:bg,description})),null,2)+'\n');
  console.log('Created four SVG sources, PNG previews and comparison.png');
})();

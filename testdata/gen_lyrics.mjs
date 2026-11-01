// testdata/gen_lyrics.mjs — 生成 testdata/mock/lyrics.json（node ≥ 20，无依赖）。
//
// 把明文 LRC 反向混淆成波点歌词接口的原始格式：与 src/core/lyrics.zig 的
// decodeWordTiming 互为逆变换——[kuwo:21]（八进制 17，起始系数 1、时长
// 系数 7）下，要得到起始 S、时长 D 的字级时间对，写 <S+7D, S-7D> 即可，
// 因为 |a+b| = 2S、|a-b| = 14D。base64 后写进 data.content，完整复刻
// 真实响应形状。重复时间戳的行为“翻译行”（不带时间对），UI 层按 LRC
// 惯例配对成翻译。
//
// 用法：node testdata/gen_lyrics.mjs

import { writeFileSync } from 'node:fs';

// 明文 LRC：时间戳 + 歌词；紧跟同时间戳的英文行会被当作翻译
const plain = `
[00:24.00]今天我 寒夜里看雪飘过
[00:24.00]Today I watch snow drift by on a cold night
[00:29.50]怀着冷却了的心窝漂远方
[00:35.00]风雨里追赶
[00:39.00]雾里分不清影踪
[00:43.50]天空海阔你与我
[00:48.00]可会变 谁没在变
[00:52.50]多少次 迎着冷眼与嘲笑
[00:58.00]从没有放弃过心中的理想
[01:03.50]一刹那恍惚
[01:08.00]若有所失的感觉
[01:12.50]不知不觉已变淡
[01:17.00]心里爱 谁明白我
[01:21.50]原谅我这一生不羁放纵爱自由
[01:21.50]Forgive me for loving freedom all my unruly life
[01:27.00]也会怕有一天会跌倒
[01:31.50]背弃了理想 谁人都可以
[01:31.50]Anyone can abandon their ideals
[01:36.50]哪会怕有一天只你共我
[01:41.50]仍然要倔强地追赶
[01:46.50]仍然自由的永远唱
[01:52.00]走遍千里
[02:00.00]原谅我这一生不羁放纵爱自由
[02:05.50]也会怕有一天会跌倒
[02:10.00]背弃了理想 谁人都可以
[02:15.00]哪会怕有一天只你共我
`;

const START_FACTOR = 1; // parseInt('21', 8) = 17 → 十位 1
const DUR_FACTOR = 7; //     个位 7

const lines = plain
  .split('\n')
  .map((l) => l.trim())
  .filter(Boolean)
  .map((l) => {
    const m = l.match(/^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/);
    if (!m) throw new Error(`无法解析行: ${l}`);
    return { ms: (+m[1]) * 60000 + Math.round(parseFloat(m[2]) * 1000), text: m[3] };
  });

function ts(ms) {
  const m = Math.floor(ms / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  const x = Math.floor(ms % 1000);
  return `[${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}.${String(x).padStart(3, '0')}]`;
}

// 把一行文字拆成“字”（CJK 逐字，拉丁按词）
function words(text) {
  return text.match(/[\u4e00-\u9fff]|[A-Za-z]+|\s+|[^\s]/gu) ?? [];
}

// 判断是否翻译行：与上一行同时间戳且内容以拉丁字母开头
const tagged = lines.map((l, i) => {
  const is_translation = i > 0 && lines[i - 1].ms === l.ms && /^[A-Za-z]/.test(l.text);
  return { ...l, is_translation };
});

let out = '[kuwo:21]';
for (let i = 0; i < tagged.length; i++) {
  const l = tagged[i];
  out += '\n' + ts(l.ms);
  if (l.is_translation) {
    out += l.text; // 翻译行不带字级时间对
    continue;
  }
  // 行内时间分配：到下一行（跳过翻译行）为止，最长 4 秒
  let next = l.ms + 4000;
  for (let j = i + 1; j < tagged.length; j++) {
    if (!tagged[j].is_translation) {
      next = tagged[j].ms;
      break;
    }
  }
  const span = Math.max(200, Math.min(next - l.ms, 4000));
  const ws = words(l.text).filter((w) => w.trim());
  const per = span / ws.length;
  let cursor = l.ms;
  for (const w of ws) {
    const start = Math.round(cursor);
    const dur = Math.round(per * 1.3);
    const a = start + DUR_FACTOR * dur;
    const b = start - DUR_FACTOR * dur;
    out += `<${a},${b}>${w}`;
    cursor += per;
  }
}

writeFileSync(
  new URL('./mock/lyrics.json', import.meta.url),
  JSON.stringify({ code: 200, data: { musicId: '968387', content: Buffer.from(out, 'utf8').toString('base64') } }, null, 2) + '\n',
);
console.log(`生成 ${lines.length} 行（含翻译 ${tagged.filter((l) => l.is_translation).length} 行），content ${out.length} 字符`);

// Opens a page in the bundled Chromium, optionally presses keys / clicks, and
// reports page errors, a frozen main thread or a runaway animation loop.
// usage: node page-check.mjs <url> <outPrefix> [step ...]
//   step: key:Space | hold:ArrowRight:800 |
//         chord:ArrowRight+Space:800 | click:<css selector> | wait:1500
import { chromium } from "playwright-core";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [url, outPrefix, ...steps] = process.argv.slice(2);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
fs.mkdirSync(path.dirname(outPrefix), { recursive: true });
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_BIN ??
    path.join(root, "runtime/ms-playwright/chromium-1234/chrome-linux/chrome"),
  args: ["--no-sandbox", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
const errors = [];
page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
page.on("console", (m) => { if (m.type() === "error") errors.push(`console: ${m.text()}`); });
page.on("requestfailed", (r) => errors.push(`requestfailed: ${r.url()}`));
await page.addInitScript(() => {
  const raf = window.requestAnimationFrame.bind(window);
  const stats = { calls: 0, frames: 0, last: -1 };
  window.__raf = stats;
  window.requestAnimationFrame = (callback) => {
    stats.calls += 1;
    return raf((time) => {
      if (time !== stats.last) { stats.last = time; stats.frames += 1; }
      callback(time);
    });
  };
});

// A healthy page registers about one animation frame per rendered frame; a loop
// that schedules itself twice per frame doubles every frame and soon freezes the tab.
async function checkLoop(moment) {
  const sample = page.evaluate(async () => {
    const start = { ...window.__raf };
    await new Promise((resolve) => setTimeout(resolve, 1000));
    return { calls: window.__raf.calls - start.calls, frames: window.__raf.frames - start.frames };
  });
  const frozen = new Promise((resolve) => setTimeout(() => resolve(null), 8000));
  const result = await Promise.race([sample, frozen]);
  if (!result) {
    errors.push(`页面主线程在${moment}卡死：可能有死循环，或每帧重复注册了 requestAnimationFrame。`);
    return false;
  }
  const perFrame = result.frames ? result.calls / result.frames : 0;
  if (result.calls > 12 && perFrame > 3) {
    errors.push(
      `${moment}每帧注册了约 ${perFrame.toFixed(1)} 次 requestAnimationFrame（正常为 1 次）：动画循环被重复注册，` +
        "例如 loop() 和 draw() 里都调用了 requestAnimationFrame，回调数量每帧翻倍，页面很快会卡死。" +
        "整个游戏循环里只能在一处调用 requestAnimationFrame。",
    );
    return false;
  }
  return true;
}

let healthy = true;
try {
  await page.goto(url, { waitUntil: "load", timeout: 30000 });
  await page.waitForTimeout(1500);
  healthy = await checkLoop("加载后");
  if (healthy) await page.screenshot({ path: `${outPrefix}-0.png`, timeout: 10000 });
  let shot = 1;
  for (const step of healthy ? steps : []) {
    const [kind, a, b] = step.split(":");
    if (kind === "key") await page.keyboard.press(a);
    else if (kind === "hold") { await page.keyboard.down(a); await page.waitForTimeout(Number(b || 500)); await page.keyboard.up(a); }
    else if (kind === "chord") {
      const keys = a.split("+").filter(Boolean);
      for (const key of keys) await page.keyboard.down(key);
      await page.waitForTimeout(Number(b || 800));
      for (const key of keys.reverse()) await page.keyboard.up(key);
    }
    else if (kind === "click") await page.click(step.slice(6), { timeout: 5000 });
    else if (kind === "wait") await page.waitForTimeout(Number(a));
    else if (kind === "shot") await page.screenshot({ path: `${outPrefix}-${shot++}.png`, timeout: 10000 });
  }
  if (healthy && steps.length) healthy = await checkLoop("按键操作后");
  if (healthy) await page.screenshot({ path: `${outPrefix}-${shot}.png`, timeout: 10000 });
} catch (error) {
  errors.push(`检查过程中出错：${error.message.split("\n")[0]}`);
}
console.log(JSON.stringify({ url, title: await page.title().catch(() => ""), errors }, null, 2));
await browser.close();
if (errors.length) process.exitCode = 1;

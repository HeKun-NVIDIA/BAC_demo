import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "../openclaw/node_modules/playwright-core/index.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const target = process.argv[2];
const project = target === "pong-upgrade" ? "pong" : target;
const port = process.env.SHOWCASE_PORT ?? "18088";
const url = `http://127.0.0.1:${port}/workspace/demos/${project}/`;
const output = path.join(root, "runtime/tmp/published-demo-tests");
fs.mkdirSync(output, { recursive: true });

const allowed = new Set([
  "pong",
  "pong-upgrade",
  "platformer",
  "spark3d",
  "breathe",
  "kart3d",
  "voice",
]);
if (!allowed.has(target)) throw new Error(`unsupported demo: ${target}`);

const browser = await chromium.launch({
  executablePath: path.join(
    root,
    "runtime/ms-playwright/chromium-1234/chrome-linux/chrome",
  ),
  args: ["--no-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
const errors = [];
page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
page.on("console", (message) => {
  if (message.type() === "error") errors.push(`console: ${message.text()}`);
});
page.on("requestfailed", (request) => errors.push(`request: ${request.url()}`));

// Frame-polled input (e.g. Phaser JustDown) misses a down+up inside one frame.
async function tap(key) {
  await page.keyboard.down(key);
  await page.waitForTimeout(80);
  await page.keyboard.up(key);
}

const telemetry = () =>
  page.evaluate(() => ({ ...(document.querySelector("#telemetry")?.dataset ?? {}) }));
const show = (data) => JSON.stringify(data);

async function waitTelemetry(predicate, timeout, hint) {
  try {
    await page.waitForFunction(predicate, null, { timeout });
  } catch {
    const present = await page.evaluate(() => Boolean(document.querySelector("#telemetry")));
    throw new Error(
      `${hint} 当前 #telemetry ${present ? `数据为 ${show(await telemetry())}` : "元素不存在"}。` +
        "请检查游戏循环是否在运行、每帧是否更新 #telemetry 的 dataset。",
    );
  }
}

let kind = target;
try {
  await page.goto(url, { waitUntil: "load", timeout: 30_000 });

  // The upgraded Pong lives in the same folder, so detect it by its menu telemetry.
  if (target === "pong" || target === "pong-upgrade") {
    await waitTelemetry(
      () => {
        const data = document.querySelector("#telemetry")?.dataset;
        return data && (data.ballx || data.selected);
      },
      8000,
      "页面加载 8 秒后仍没有 Pong 测试数据（需要 dataset.ballx；升级版还需要 dataset.selected）。",
    );
    kind = (await telemetry()).mode === "menu" ? "pong-upgrade" : "pong";
  }

  if (kind === "pong") {
    await page.locator("canvas").click();
    const before = await telemetry();
    await page.waitForTimeout(600);
    const moving = await telemetry();
    await page.keyboard.down("KeyW");
    await page.waitForTimeout(350);
    await page.keyboard.up("KeyW");
    const paddle = await telemetry();
    if (Math.abs(Number(moving.ballx) - Number(before.ballx)) < 40) {
      throw new Error(
        `球在 0.6 秒内几乎没动（ballx ${before.ballx} → ${moving.ballx}）。` +
          "球应在页面加载后立即自动发出，并持续更新 dataset.ballx。",
      );
    }
    if (Number(paddle.playery) >= Number(moving.playery) - 20) {
      throw new Error(
        `按住 W 0.35 秒后左球拍没有上移（playery ${moving.playery} → ${paddle.playery}）。` +
          "W/上键应让左球拍 y 变小，并把当前 y 写入 dataset.playery。",
      );
    }
    await tap("Space");
    await page.waitForTimeout(200);
    const pausedA = await telemetry();
    await page.waitForTimeout(1200);
    const pausedB = await telemetry();
    if (pausedA.running !== "false" || Math.abs(Number(pausedB.ballx) - Number(pausedA.ballx)) > 2) {
      throw new Error(
        `按空格后没有暂停（running=${pausedA.running}，ballx ${pausedA.ballx} → ${pausedB.ballx}）。` +
          '空格应暂停：球停住且 dataset.running 为 "false"。',
      );
    }
    await tap("Space");
    // A point may have just been scored, and games often pause briefly before serving.
    let resumed = await telemetry();
    for (let waited = 0; waited < 2500; waited += 250) {
      await page.waitForTimeout(250);
      resumed = await telemetry();
      if (resumed.running === "true" && Math.abs(Number(resumed.ballx) - Number(pausedB.ballx)) >= 20) break;
    }
    if (resumed.running !== "true" || Math.abs(Number(resumed.ballx) - Number(pausedB.ballx)) < 20) {
      throw new Error(
        `再按空格后没有继续（running=${resumed.running}，ballx ${pausedB.ballx} → ${resumed.ballx}）。`,
      );
    }
  } else if (kind === "pong-upgrade") {
    await page.locator("canvas").click();
    const initial = await telemetry();
    await page.keyboard.down("ArrowRight");
    await page.waitForTimeout(250);
    await page.keyboard.up("ArrowRight");
    await page.waitForTimeout(100);
    const selected = await telemetry();
    await tap("Enter");
    await page.waitForTimeout(250);
    const started = await telemetry();
    await page.waitForTimeout(500);
    const playing = await telemetry();
    if (initial.selected !== "1" || selected.selected !== "2" || playing.mode !== "play") {
      throw new Error(
        '难度菜单检查失败：加载后应停在菜单（mode="menu"、selected="1"），按右键后 selected="2"，' +
          `按 Enter 后 mode="play"。实际：初始 ${show(initial)}，按右键后 ${show(selected)}，` +
          `按 Enter 后 ${show(playing)}。`,
      );
    }
    if (Math.abs(Number(playing.ballx) - Number(started.ballx)) < 40) {
      throw new Error(`按 Enter 开始后球没有运动（ballx ${started.ballx} → ${playing.ballx}）。`);
    }
    await page.waitForTimeout(900);
  } else if (target === "platformer") {
    await waitTelemetry(
      () => document.querySelector("#telemetry")?.dataset.grounded === "true",
      6000,
      '开局 6 秒内角色没有站到地面上（需要 dataset.grounded 为 "true"，可用 body.blocked.down 判断）。',
    );
    await page.locator("canvas").click();
    const before = await telemetry();
    await page.keyboard.down("ArrowRight");
    await page.keyboard.down("Space");
    await page.waitForTimeout(280);
    const airborne = await telemetry();
    await page.keyboard.up("Space");
    await page.keyboard.up("ArrowRight");
    await page.waitForTimeout(1900);
    const landed = await telemetry();
    if (Number(airborne.x) <= Number(before.x) + 3 || airborne.grounded !== "false") {
      throw new Error(
        `同时按住右键和空格 0.28 秒后，角色应边向右移动边起跳。实际：按键前 ${show(before)}，` +
          `按键后 ${show(airborne)}（x 应增大、grounded 应为 "false"）。`,
      );
    }
    if (landed.grounded !== "true" || landed.lives !== "3") {
      throw new Error(
        `跳起约 2 秒后角色应落回地面且仍有 3 条命，实际 ${show(landed)}。` +
          "检查重力和地面碰撞；出生点右侧 400 像素内不要放敌人或坑。",
      );
    }
    await tap("Space");
    await page.waitForTimeout(300);
    const secondJump = await telemetry();
    if (secondJump.grounded !== "false" || Number(secondJump.y) >= Number(landed.y) - 20) {
      throw new Error(
        `落地后再按空格应能再次起跳，实际 落地时 ${show(landed)}，按空格 0.3 秒后 ${show(secondJump)}。` +
          "落地时要重置跳跃次数。",
      );
    }
    await page.waitForTimeout(1900);
    const secondLanding = await telemetry();
    if (secondLanding.grounded !== "true" || secondLanding.lives !== "3") {
      throw new Error(`第二次跳跃后角色没有正常落地，实际 ${show(secondLanding)}。`);
    }
  } else if (target === "kart3d") {
    await page.waitForTimeout(1200);
    await page.locator("canvas").click();
    const before = await page.locator("#telemetry").evaluate((el) => ({ ...el.dataset }));
    await page.keyboard.down("ArrowUp");
    await page.keyboard.down("ArrowLeft");
    await page.waitForTimeout(1800);
    const after = await page.locator("#telemetry").evaluate((el) => ({ ...el.dataset }));
    await page.keyboard.up("ArrowLeft");
    await page.keyboard.up("ArrowUp");
    const distance = Math.hypot(
      Number(after.x) - Number(before.x),
      Number(after.z) - Number(before.z),
    );
    if (Number(after.speed) < 3 || distance < 3) {
      throw new Error("Kart throttle/steering failed");
    }
    await tap("Space");
    await page.keyboard.down("ArrowUp");
    await page.waitForTimeout(1200);
    await page.keyboard.up("ArrowUp");
    const boosted = await page.locator("#telemetry").evaluate((el) => ({ ...el.dataset }));
    if (Number(boosted.speed) <= 0 || boosted.z === after.z) {
      throw new Error("Kart boost/forward motion failed");
    }
  } else if (target === "spark3d") {
    await page.waitForTimeout(1800);
    if (await page.locator("canvas").count() !== 1) throw new Error("3D canvas missing");
    await page.mouse.move(640, 400);
    await page.mouse.down();
    await page.mouse.move(760, 440, { steps: 5 });
    await page.mouse.up();
    await page.mouse.wheel(0, -300);
    await page.waitForTimeout(2000);
  } else if (target === "breathe") {
    await page.locator("#start-btn").click();
    await page.waitForTimeout(1300);
    const phase = await page.locator("#phase-text").innerText();
    if (!phase || phase === "准备开始") throw new Error("Breathing session did not start");
    const firstCountdown = await page.locator("#countdown").innerText();
    await page.waitForTimeout(2500);
    const nextCountdown = await page.locator("#countdown").innerText();
    if (firstCountdown === nextCountdown) throw new Error("Breathing countdown did not advance");
    await page.locator('[data-theme="ocean"]').click();
  } else if (target === "voice") {
    await page.locator("#txt").fill(
      "页面正在进行本地语音合成验收，确认音色、语速、播放与下载功能都可以正常使用。",
    );
    await page.locator("#speed").fill("1.5");
    await page.locator("#voice").selectOption("serena");
    if ((await page.locator("#speedVal").innerText()).trim() !== "1.5x") {
      throw new Error("Voice speed control did not update");
    }
    await page.locator("#btn").click();
    await page.waitForFunction(
      () => {
        const wrap = document.querySelector("#audioWrap");
        const status = document.querySelector("#status")?.textContent || "";
        return !wrap?.classList.contains("hidden") && status.includes("播报完成");
      },
      { timeout: 30_000 },
    );
  }

  const title = await page.title();
  if (!title || title === "Error response") throw new Error("页面没有标题，可能没有正确加载 index.html。");
  await page.screenshot({ path: path.join(output, `${target}.png`) });
  if (errors.length) throw new Error(`页面有 JavaScript 或资源错误：${errors.join("; ")}`);
  console.log(`PUBLISHED_DEMO_OK target=${target} detected=${kind} title=${title} screenshot=${output}/${target}.png`);
} catch (error) {
  console.log(`WORKSHOP_VERIFY_FAIL (${kind}): ${error.message}`);
  if (errors.length) console.log(`页面报错：${errors.slice(0, 5).join("; ")}`);
  console.log("按上面的说明修改页面代码后再运行一次检查，不需要阅读检查脚本源码。");
  process.exitCode = 1;
} finally {
  await browser.close();
}

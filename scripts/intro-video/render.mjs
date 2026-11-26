#!/usr/bin/env node
// Renders scripts/intro-video/intro.html to an mp4: headless Chrome draws each frame (the page is a
// pure function of time), ffmpeg encodes them. No npm packages; needs Node 22+, Chrome and ffmpeg.
//
//   node render.mjs --theme dark --frames <effect frames folder> --out intro-dark.mp4
//   node render.mjs --theme dark --frames <folder> --stills 1.5,7.2 --stills-dir <folder>   (PNG spot checks)
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const theme = args.theme === "light" ? "light" : "dark";
const framesDir = resolve(args.frames || join(root, "build/intro-video/frames"));
const fps = Number(args.fps || 60);
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const WIDTH = 640, HEIGHT = 400, SCALE = 2;

// A static server: the repo, plus the effect frames at /frames.
const types = { ".html": "text/html", ".json": "application/json", ".png": "image/png", ".js": "text/javascript" };
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = path.startsWith("/frames/") ? join(framesDir, normalize(path.slice(8))) : join(root, normalize(path));
  if (!file.startsWith(root) && !file.startsWith(framesDir) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream" }).end(readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

// Chrome, driven over the DevTools protocol.
const profile = mkdtempSync(join(tmpdir(), "ghosttype-intro-"));
const browser = spawn(chrome, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--hide-scrollbars",
  "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--mute-audio",
  `--window-size=${WIDTH},${HEIGHT}`, "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });
const debugPort = await new Promise((ok, fail) => {
  let err = "";
  browser.stderr.on("data", (d) => {
    err += d;
    const m = err.match(/DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//);
    if (m) ok(Number(m[1]));
  });
  browser.on("exit", () => fail(new Error("Chrome exited: " + err)));
});
const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let nextId = 0;
const pending = new Map();
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) {
    const { ok, fail } = pending.get(m.id);
    pending.delete(m.id);
    m.error ? fail(new Error(m.error.message)) : ok(m.result);
  }
};
const send = (method, params = {}) => new Promise((ok, fail) => {
  const id = ++nextId;
  pending.set(id, { ok, fail });
  ws.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};

let ffmpeg = null;
try {
  await send("Emulation.setDeviceMetricsOverride", { width: WIDTH, height: HEIGHT, deviceScaleFactor: SCALE, mobile: false });
  await send("Page.enable");
  const url = `http://127.0.0.1:${port}/scripts/intro-video/intro.html?theme=${theme}&frames=/frames&icon=/Resources/AppIcon-1024.png`;
  await send("Page.navigate", { url });
  // The page's `ready` exists once its script has run.
  for (let i = 0; i < 200 && !(await evaluate("typeof window.ready === 'object'")); i++) await new Promise((r) => setTimeout(r, 50));
  await evaluate("window.ready");
  const duration = await evaluate("window.DURATION");
  const shoot = async (t) => {
    // Draw, let the frame be laid out and painted, then capture it.
    await evaluate(`new Promise((done) => { render(${t}); requestAnimationFrame(() => done(true)); })`);
    const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
    return Buffer.from(shot.data, "base64");
  };

  if (args.stills) {
    const dir = resolve(args["stills-dir"] || ".");
    mkdirSync(dir, { recursive: true });
    for (const t of String(args.stills).split(",").map(Number)) {
      writeFileSync(join(dir, `${theme}-${t.toFixed(2).padStart(5, "0")}.png`), await shoot(t));
    }
  } else {
    const out = resolve(args.out || `intro-${theme}.mp4`);
    mkdirSync(dirname(out), { recursive: true });
    // H.264, tagged sRGB/BT.709 so AVPlayer shows the colors as drawn; faststart for quick opening.
    ffmpeg = spawn("ffmpeg", [
      "-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-",
      "-vf", "scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p,"
        + "setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=tv",
      "-c:v", "libx264", "-preset", "slow", "-crf", String(args.crf || 20), "-profile:v", "high", "-tune", "animation",
      "-color_primaries", "bt709", "-color_trc", "iec61966-2-1", "-colorspace", "bt709", "-color_range", "tv",
      "-movflags", "+faststart", "-tag:v", "avc1", "-an", out,
    ], { stdio: ["pipe", "inherit", "inherit"] });
    const total = Math.round(duration * fps);
    for (let i = 0; i < total; i++) {
      const png = await shoot(i / fps);
      if (!ffmpeg.stdin.write(png)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
      if (i % 120 === 0) process.stderr.write(`\r${theme}: frame ${i}/${total}`);
    }
    ffmpeg.stdin.end();
    await new Promise((ok, fail) => ffmpeg.on("exit", (code) => (code === 0 ? ok() : fail(new Error(`ffmpeg exited ${code}`)))));
    process.stderr.write(`\r${theme}: wrote ${out}\n`);
  }
} finally {
  ws.close();
  browser.kill();
  server.close();
  await new Promise((r) => setTimeout(r, 300));
  rmSync(profile, { recursive: true, force: true });
}
// A socket to the closed browser can linger and keep Node alive: the work is done, so leave.
process.exit(0);

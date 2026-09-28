import { spawn } from "node:child_process";
import { access, mkdtemp, readdir } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const extensionDir = path.join(root, "dist", "pocketclip");
async function resolveChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    "/tmp/cft/chrome-linux64/chrome",
    "/opt/google/chrome/chrome",
  ].filter((candidate) => candidate);
  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next Chrome binary. Branded Chrome ignores --load-extension.
    }
  }
  throw new Error("Chrome was not found");
}

const chromePath = await resolveChrome();
const sounds = ["capture", "copy", "save", "error"];
const bundledSounds = await readdir(path.join(extensionDir, "assets", "sfx"));
if (bundledSounds.some((file) => file.endsWith(".ogg")) || bundledSounds.length !== sounds.length) {
  throw new Error(`Unexpected bundled sounds: ${bundledSounds.join(", ")}`);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("no-port"));
        return;
      }
      server.close(() => resolve(address.port));
    });
  });
}

const port = await freePort();
const userDataDir = await mkdtemp(path.join(tmpdir(), "pocketclip-"));
const chrome = spawn(
  chromePath,
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--no-first-run",
    "--autoplay-policy=no-user-gesture-required",
    `--user-data-dir=${userDataDir}`,
    `--load-extension=${extensionDir}`,
    `--remote-debugging-port=${port}`,
    "about:blank",
  ],
  { stdio: "ignore" },
);

let browser;
const pageErrors = [];
const consoleErrors = [];

function watchPage(page, label) {
  page.on("pageerror", (error) => {
    pageErrors.push(`${label}: ${error.message}`);
  });
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(`${label}: ${message.text()}`);
  });
}

try {
  let connected = false;
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) {
        connected = true;
        break;
      }
    } catch {
      // Chrome is still starting.
    }
    await delay(100);
  }
  if (!connected) throw new Error("Chrome did not open a debugging port");

  browser = await puppeteer.connect({
    browserURL: `http://127.0.0.1:${port}`,
    defaultViewport: { width: 800, height: 600 },
  });

  let workerTarget;
  let worker;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    for (const target of browser.targets()) {
      if (target.type() !== "service_worker" || !target.url().endsWith("/background.js")) continue;
      const candidate = await target.worker();
      if (!candidate) continue;
      try {
        const match = await candidate.evaluate(
          () => typeof globalThis.pocketclip?.playFromBackground === "function",
        );
        if (match) {
          workerTarget = target;
          worker = candidate;
          break;
        }
      } catch {
        // This worker is not the extension service worker.
      }
    }
    if (worker) break;
    await delay(100);
  }
  if (!worker || !workerTarget) throw new Error("Pocketclip service worker did not register");

  worker.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(`sw: ${message.text()}`);
  });

  const manifest = await worker.evaluate(() => {
    const current = chrome.runtime.getManifest();
    return {
      name: current.name,
      version: current.version,
      permissions: current.permissions,
    };
  });
  if (manifest.name !== "Pocketclip") throw new Error(`Unexpected extension name: ${manifest.name}`);
  if (!manifest.permissions?.includes("offscreen")) throw new Error("offscreen permission missing");

  const offscreenCount = await worker.evaluate(async () => {
    await Promise.all([
      globalThis.pocketclip.ensureOffscreen(),
      globalThis.pocketclip.ensureOffscreen(),
      globalThis.pocketclip.ensureOffscreen(),
    ]);
    const contexts = await chrome.runtime.getContexts({
      contextTypes: ["OFFSCREEN_DOCUMENT"],
    });
    return contexts.length;
  });
  if (offscreenCount !== 1) throw new Error(`Expected 1 offscreen document, got ${offscreenCount}`);

  const playback = await worker.evaluate(async (names) => {
    const results = [];
    for (const name of names) {
      results.push({ name, ...(await globalThis.pocketclip.playFromBackground(name)) });
    }
    const repeat = await globalThis.pocketclip.playFromBackground("capture");
    return { results, repeat };
  }, sounds);

  const failed = playback.results.filter((result) => result.ok !== true);
  if (failed.length > 0) {
    throw new Error(`play() did not resolve: ${JSON.stringify(playback)}`);
  }

  const extensionId = new URL(workerTarget.url()).host;
  const popup = await browser.newPage();
  watchPage(popup, "popup");
  await popup.goto(`chrome-extension://${extensionId}/popup.html`, { waitUntil: "domcontentloaded" });
  const popupState = await popup.evaluate(async () => {
    const clips = [...document.querySelectorAll("audio[data-sfx]")].map((node) => ({
      name: node.dataset.sfx,
      volume: node.volume,
      preload: node.preload,
      readyState: node.readyState,
    }));
    const files = {};
    for (const name of ["capture", "copy", "save", "error"]) {
      const response = await fetch(chrome.runtime.getURL(`assets/sfx/${name}.mp3`));
      files[name] = response.status;
    }
    const missingOgg = { status: 0 };
    const capture = document.querySelector('audio[data-sfx="capture"]');
    let play = "missing";
    if (capture instanceof HTMLAudioElement) {
      capture.currentTime = 0;
      await capture.play();
      play = capture.paused ? "paused" : "playing";
    }
    return {
      clips,
      files,
      oggStatus: missingOgg.status,
      play,
      status: document.querySelector("#status")?.textContent ?? "",
      title: document.querySelector("h1")?.textContent ?? "",
    };
  });

  if (popupState.clips.length !== 4) throw new Error(`Expected 4 preloaded sounds, got ${popupState.clips.length}`);
  for (const clip of popupState.clips) {
    if (Math.abs(clip.volume - 0.4) > 0.001) throw new Error(`Volume for ${clip.name} is ${clip.volume}`);
  }
  for (const name of sounds) {
    if (popupState.files[name] !== 200) throw new Error(`${name}.mp3 status ${popupState.files[name]}`);
  }
  if (popupState.oggStatus === 200) throw new Error("ogg file was bundled");
  if (popupState.play === "paused") throw new Error("popup play() left the element paused");
  if (popupState.title !== "Pocketclip") throw new Error(`Unexpected popup title: ${popupState.title}`);

  await popup.click('button[data-action="capture-viewport"]');
  await popup.waitForFunction(
    () => {
      const status = document.querySelector("#status")?.textContent ?? "";
      return status === "Captured" || status === "Something went wrong";
    },
    { timeout: 10000 },
  );
  const captureStatus = await popup.$eval("#status", (node) => node.textContent);

  if (pageErrors.length > 0 || consoleErrors.length > 0) {
    throw new Error(`Console errors:\n${[...pageErrors, ...consoleErrors].join("\n")}`);
  }

  console.log(JSON.stringify({ manifest, offscreenCount, playback, popupState, captureStatus }, null, 2));
} finally {
  if (browser) await browser.disconnect();
  chrome.kill("SIGKILL");
}

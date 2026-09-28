import { mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const extensionDir = path.join(root, "dist", "pocketclip");
const downloadDir = "/tmp/pocketclip-downloads";
const chromePath = process.env.CHROME_PATH || "/opt/google/chrome/chrome";
const sounds = ["capture", "copy", "save", "error"];

await mkdir(downloadDir, { recursive: true });

const browser = await puppeteer.launch({
  executablePath: chromePath,
  headless: "new",
  dumpio: false,
  args: [
    `--disable-extensions-except=${extensionDir}`,
    `--load-extension=${extensionDir}`,
    "--autoplay-policy=no-user-gesture-required",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--no-sandbox",
    `--download-default-directory=${downloadDir}`,
  ],
});

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
  const workerTarget = await browser.waitForTarget(
    (target) => target.type() === "service_worker" && target.url().includes("background.js"),
    { timeout: 15000 },
  );
  const worker = await workerTarget.worker();
  if (!worker) throw new Error("Service worker target has no worker");

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
    const missingOgg = await fetch(chrome.runtime.getURL("assets/sfx/capture.ogg"));
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
  if (popupState.play === "missing") throw new Error("popup capture audio missing");
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
  await browser.close();
}

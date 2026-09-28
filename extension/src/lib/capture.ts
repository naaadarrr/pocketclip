import type { PageMetrics, RegionSelection } from "../types";

const LAST_CAPTURE_KEY = "lastCapture";
const MAX_FULL_PAGE_SLICES = 24;

let memoryCapture: string | null = null;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export async function saveCapture(dataUrl: string): Promise<void> {
  memoryCapture = dataUrl;
  try {
    await chrome.storage.session.set({ [LAST_CAPTURE_KEY]: dataUrl });
  } catch {
    // Session storage can reject a very large image. The in-memory copy remains.
  }
}

export async function loadCapture(): Promise<string | null> {
  try {
    const stored = await chrome.storage.session.get(LAST_CAPTURE_KEY);
    const value = stored[LAST_CAPTURE_KEY];
    if (typeof value === "string") {
      memoryCapture = value;
      return value;
    }
  } catch {
    // Fall back to the in-memory image captured in this document.
  }
  return memoryCapture;
}

export async function blobToDataUrl(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const chunkSize = 0x4000;
  let binary = "";
  for (let index = 0; index < bytes.length; index += chunkSize) {
    const chunk = bytes.subarray(index, index + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  const type = blob.type || "image/png";
  return `data:${type};base64,${btoa(binary)}`;
}

function isRestricted(url: string | undefined): boolean {
  if (!url) return false;
  return (
    url.startsWith("chrome://") ||
    url.startsWith("chrome-extension://") ||
    url.startsWith("edge://") ||
    url.startsWith("devtools://")
  );
}

export async function activeTab(): Promise<chrome.tabs.Tab> {
  const current = await chrome.tabs.query({ active: true, currentWindow: true });
  const focused = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const ordered = [...current, ...focused];
  const usable = ordered.find((tab) => tab.id != null && tab.windowId != null && !isRestricted(tab.url));
  if (usable) return usable;
  const fallback = ordered.find((tab) => tab.id != null && tab.windowId != null);
  if (fallback) return fallback;
  throw new Error("no-tab");
}

export async function captureViewport(windowId: number): Promise<string> {
  const dataUrl = await chrome.tabs.captureVisibleTab(windowId, { format: "png" });
  if (!dataUrl) throw new Error("empty-capture");
  return dataUrl;
}

function isMetrics(value: unknown): value is PageMetrics {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.scrollHeight === "number" &&
    typeof record.clientHeight === "number" &&
    typeof record.clientWidth === "number" &&
    typeof record.scrollX === "number" &&
    typeof record.scrollY === "number"
  );
}

async function readMetrics(tabId: number): Promise<PageMetrics> {
  const [injection] = await chrome.scripting.executeScript({
    target: { tabId },
    func: () => {
      const doc = document.documentElement;
      const body = document.body;
      return {
        scrollHeight: Math.max(doc.scrollHeight, body?.scrollHeight ?? 0),
        clientHeight: doc.clientHeight || window.innerHeight,
        clientWidth: doc.clientWidth || window.innerWidth,
        scrollX: window.scrollX,
        scrollY: window.scrollY,
      };
    },
  });
  if (!isMetrics(injection?.result)) throw new Error("metrics-unavailable");
  return injection.result;
}

async function scrollPage(tabId: number, top: number, left: number): Promise<void> {
  await chrome.scripting.executeScript({
    target: { tabId },
    args: [top, left],
    func: (nextTop: number, nextLeft: number) =>
      new Promise<void>((resolve) => {
        window.scrollTo(nextLeft, nextTop);
        requestAnimationFrame(() => {
          requestAnimationFrame(() => resolve());
        });
      }),
  });
}

export async function captureFullPage(windowId: number, tabId: number): Promise<string> {
  const metrics = await readMetrics(tabId);
  const slices: ImageBitmap[] = [];
  const positions: number[] = [];
  try {
    let top = 0;
    const step = Math.max(1, metrics.clientHeight);
    while (positions.length < MAX_FULL_PAGE_SLICES) {
      await scrollPage(tabId, top, 0);
      await delay(80);
      const dataUrl = await captureViewport(windowId);
      const bitmap = await createImageBitmap(await (await fetch(dataUrl)).blob());
      slices.push(bitmap);
      positions.push(top);
      if (top + metrics.clientHeight >= metrics.scrollHeight - 1) break;
      const next = Math.min(top + step, Math.max(0, metrics.scrollHeight - metrics.clientHeight));
      if (next <= top) break;
      top = next;
    }
    const reachedBottom = positions.some((position) => position + metrics.clientHeight >= metrics.scrollHeight - 1);
    if (!reachedBottom) throw new Error("page-too-tall");
    return await stitchSlices(slices, positions, metrics);
  } finally {
    for (const slice of slices) slice.close();
    try {
      await scrollPage(tabId, metrics.scrollY, metrics.scrollX);
    } catch {
      // The tab may already be gone.
    }
  }
}

async function stitchSlices(slices: ImageBitmap[], positions: number[], metrics: PageMetrics): Promise<string> {
  const first = slices[0];
  if (!first) throw new Error("empty-capture");
  const scaleY = first.height / Math.max(1, metrics.clientHeight);
  const scaleX = first.width / Math.max(1, metrics.clientWidth);
  const width = Math.max(1, Math.round(metrics.clientWidth * scaleX));
  const height = Math.max(1, Math.round(metrics.scrollHeight * scaleY));
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d");
  if (!context) throw new Error("no-context");
  slices.forEach((slice, index) => {
    const position = positions[index] ?? 0;
    const destY = Math.round(position * scaleY);
    context.drawImage(slice, 0, destY);
  });
  const blob = await canvas.convertToBlob({ type: "image/png" });
  return blobToDataUrl(blob);
}

export function isRegionSelection(value: unknown): value is RegionSelection {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.x === "number" &&
    typeof record.y === "number" &&
    typeof record.width === "number" &&
    typeof record.height === "number" &&
    typeof record.viewWidth === "number" &&
    typeof record.viewHeight === "number" &&
    record.width >= 4 &&
    record.height >= 4
  );
}

export async function cropViewportImage(dataUrl: string, selection: RegionSelection): Promise<string> {
  const bitmap = await createImageBitmap(await (await fetch(dataUrl)).blob());
  try {
    const scaleX = bitmap.width / Math.max(1, selection.viewWidth);
    const scaleY = bitmap.height / Math.max(1, selection.viewHeight);
    const sx = Math.max(0, Math.round(selection.x * scaleX));
    const sy = Math.max(0, Math.round(selection.y * scaleY));
    const sw = Math.max(1, Math.min(bitmap.width - sx, Math.round(selection.width * scaleX)));
    const sh = Math.max(1, Math.min(bitmap.height - sy, Math.round(selection.height * scaleY)));
    const canvas = new OffscreenCanvas(sw, sh);
    const context = canvas.getContext("2d");
    if (!context) throw new Error("no-context");
    context.drawImage(bitmap, sx, sy, sw, sh, 0, 0, sw, sh);
    const blob = await canvas.convertToBlob({ type: "image/png" });
    return blobToDataUrl(blob);
  } finally {
    bitmap.close();
  }
}

export async function writeClipboardHere(dataUrl: string): Promise<void> {
  const blob = await (await fetch(dataUrl)).blob();
  const type = blob.type || "image/png";
  await navigator.clipboard.write([new ClipboardItem({ [type]: blob })]);
}

export async function writeClipboardInPage(tabId: number, dataUrl: string): Promise<void> {
  await chrome.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    args: [dataUrl],
    func: async (url: string) => {
      const blob = await (await fetch(url)).blob();
      const type = blob.type || "image/png";
      await navigator.clipboard.write([new ClipboardItem({ [type]: blob })]);
    },
  });
}

export function downloadFilename(): string {
  const now = new Date();
  const pad = (value: number) => String(value).padStart(2, "0");
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `Pocketclip/pocketclip-${stamp}.png`;
}

export function waitForDownload(downloadId: number): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (settle: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      chrome.downloads.onChanged.removeListener(onChanged);
      settle();
    };
    const onChanged = (delta: chrome.downloads.DownloadDelta) => {
      if (delta.id !== downloadId) return;
      if (delta.state?.current === "complete") finish(() => resolve());
      else if (delta.state?.current === "interrupted") finish(() => reject(new Error("interrupted")));
    };
    const timer = setTimeout(() => finish(() => reject(new Error("timeout"))), 20000);
    chrome.downloads.onChanged.addListener(onChanged);
    void chrome.downloads.search({ id: downloadId }).then((items) => {
      const item = items[0];
      if (!item) return;
      if (item.state === "complete") finish(() => resolve());
      else if (item.state === "interrupted") finish(() => reject(new Error(item.error ?? "interrupted")));
    });
  });
}

export async function saveCaptureFile(dataUrl: string): Promise<void> {
  const downloadId = await chrome.downloads.download({
    url: dataUrl,
    filename: downloadFilename(),
    saveAs: false,
    conflictAction: "uniquify",
  });
  await waitForDownload(downloadId);
}

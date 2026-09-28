import type { ActionId, PerformResult, RegionSelection } from "../types";
import { isRegionSelection } from "./capture";
import {
  activeTab,
  captureFullPage,
  captureViewport,
  cropViewportImage,
  loadCapture,
  saveCapture,
  saveCaptureFile,
  writeClipboardHere,
  writeClipboardInPage,
} from "./capture";

export type PerformOptions = {
  localClipboard: boolean;
};

let regionActive = false;

async function tryAutoCopy(dataUrl: string, tabId: number, localClipboard: boolean): Promise<void> {
  try {
    if (localClipboard) await writeClipboardHere(dataUrl);
    else await writeClipboardInPage(tabId, dataUrl);
  } catch (error) {
    const message = error instanceof Error ? error.message : "auto-copy failed";
    console.warn("auto-copy skipped", message);
  }
}

async function finishCapture(dataUrl: string, tabId: number, localClipboard: boolean): Promise<PerformResult> {
  await saveCapture(dataUrl);
  await tryAutoCopy(dataUrl, tabId, localClipboard);
  return { sound: "capture", status: "captured" };
}

function waitForRegion(tabId: number): Promise<RegionSelection | null> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      chrome.runtime.onMessage.removeListener(onMessage);
      resolve(null);
    }, 120000);
    const onMessage = (message: unknown, sender: chrome.runtime.MessageSender) => {
      if (sender.tab?.id !== tabId || !message || typeof message !== "object") return;
      const type = (message as { type?: unknown }).type;
      if (type === "REGION_CANCELLED") {
        clearTimeout(timer);
        chrome.runtime.onMessage.removeListener(onMessage);
        resolve(null);
        return;
      }
      if (type !== "REGION_SELECTED") return;
      const selection = (message as { selection?: unknown }).selection;
      clearTimeout(timer);
      chrome.runtime.onMessage.removeListener(onMessage);
      resolve(isRegionSelection(selection) ? selection : null);
    };
    chrome.runtime.onMessage.addListener(onMessage);
  });
}

async function performRegion(tab: chrome.tabs.Tab, localClipboard: boolean): Promise<PerformResult> {
  if (tab.id == null || regionActive) throw new Error("region-busy");
  regionActive = true;
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["region.js"],
    });
    const selection = await waitForRegion(tab.id);
    if (!selection) return { sound: null, status: "cancelled" };
    const shot = await captureViewport(tab.windowId);
    const cropped = await cropViewportImage(shot, selection);
    return finishCapture(cropped, tab.id, localClipboard);
  } finally {
    regionActive = false;
  }
}

export async function perform(action: ActionId, options: PerformOptions): Promise<PerformResult> {
  if (action === "copy" || action === "save") {
    const dataUrl = await loadCapture();
    if (!dataUrl) throw new Error("nothing-captured");
    if (action === "copy") {
      if (options.localClipboard) await writeClipboardHere(dataUrl);
      else {
        const tab = await activeTab();
        if (tab.id == null) throw new Error("no-tab");
        await writeClipboardInPage(tab.id, dataUrl);
      }
      return { sound: "copy", status: "copied" };
    }
    await saveCaptureFile(dataUrl);
    return { sound: "save", status: "saved" };
  }

  const tab = await activeTab();
  if (tab.id == null) throw new Error("no-tab");
  if (action === "capture-viewport") {
    const dataUrl = await captureViewport(tab.windowId);
    return finishCapture(dataUrl, tab.id, options.localClipboard);
  }
  if (action === "capture-full") {
    const dataUrl = await captureFullPage(tab.windowId, tab.id);
    return finishCapture(dataUrl, tab.id, options.localClipboard);
  }
  return performRegion(tab, options.localClipboard);
}

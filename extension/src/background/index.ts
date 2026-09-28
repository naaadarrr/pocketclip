import { perform } from "../lib/actions";
import { isActionId, type ActionId, type SoundName } from "../types";

const OFFSCREEN_URL = "offscreen.html";
const MENU_PARENT = "pocketclip";

const MENU_ITEMS: { id: ActionId; message: string }[] = [
  { id: "capture-viewport", message: "cmdCaptureViewport" },
  { id: "capture-region", message: "cmdCaptureRegion" },
  { id: "capture-full", message: "cmdCaptureFull" },
  { id: "copy", message: "cmdCopy" },
  { id: "save", message: "cmdSave" },
];

let offscreenPromise: Promise<void> | null = null;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function isSingleOffscreenError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return message.includes("single offscreen") || message.includes("already exists");
}

async function createOffscreenDocument(): Promise<void> {
  const url = chrome.runtime.getURL(OFFSCREEN_URL);
  const existing = await chrome.runtime.getContexts({
    contextTypes: [chrome.runtime.ContextType.OFFSCREEN_DOCUMENT],
    documentUrls: [url],
  });
  if (existing.length > 0) return;
  try {
    await chrome.offscreen.createDocument({
      url: OFFSCREEN_URL,
      reasons: [chrome.offscreen.Reason.AUDIO_PLAYBACK],
      justification: "Play short sounds for capture, copy, and save.",
    });
  } catch (error) {
    if (!isSingleOffscreenError(error)) throw error;
  }
}

export async function ensureOffscreen(): Promise<void> {
  if (!offscreenPromise) {
    offscreenPromise = createOffscreenDocument().finally(() => {
      offscreenPromise = null;
    });
  }
  await offscreenPromise;
}

export async function playFromBackground(name: SoundName): Promise<{ ok: boolean; error?: string }> {
  await ensureOffscreen();
  let lastError = "no-response";
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try {
      const response: unknown = await chrome.runtime.sendMessage({ type: "PLAY_SFX", name });
      if (response && typeof response === "object" && "ok" in response) {
        const record = response as { ok?: unknown; error?: unknown };
        return {
          ok: record.ok === true,
          error: typeof record.error === "string" ? record.error : undefined,
        };
      }
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    await delay(40);
  }
  return { ok: false, error: lastError };
}

export async function runFromBackground(action: ActionId): Promise<void> {
  let sound: SoundName | null = "error";
  try {
    const result = await perform(action, { localClipboard: false });
    sound = result.sound;
  } catch {
    sound = "error";
  }
  if (!sound) return;
  try {
    await playFromBackground(sound);
  } catch {
    // Playback is best-effort once the action result is known.
  }
}

async function rebuildMenus(): Promise<void> {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({
    id: MENU_PARENT,
    title: chrome.i18n.getMessage("extName"),
    contexts: ["page"],
  });
  for (const item of MENU_ITEMS) {
    chrome.contextMenus.create({
      id: item.id,
      parentId: MENU_PARENT,
      title: chrome.i18n.getMessage(item.message),
      contexts: ["page"],
    });
  }
}

chrome.runtime.onInstalled.addListener(() => {
  void rebuildMenus();
});

chrome.commands.onCommand.addListener((command) => {
  if (!isActionId(command)) return;
  void runFromBackground(command);
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (!isActionId(info.menuItemId)) return;
  void runFromBackground(info.menuItemId);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message !== "object") return;
  const type = (message as { type?: unknown }).type;
  if (type === "PLAY_SFX") return;
  if (type !== "RUN_BACKGROUND") return;
  const action = (message as { action?: unknown }).action;
  if (!isActionId(action)) return;
  void runFromBackground(action);
  sendResponse({ ok: true });
});

declare global {
  var pocketclip: {
    ensureOffscreen: typeof ensureOffscreen;
    playFromBackground: typeof playFromBackground;
    runFromBackground: typeof runFromBackground;
  };
}

globalThis.pocketclip = {
  ensureOffscreen,
  playFromBackground,
  runFromBackground,
};

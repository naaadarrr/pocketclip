import { perform } from "../lib/actions";
import { loadCapture } from "../lib/capture";
import { createSfxPlayer } from "../sfx/player";
import { isActionId, type ActionId, type ActionStatus } from "../types";

const STATUS_KEYS: Record<ActionStatus | "ready" | "working" | "error", string> = {
  ready: "statusReady",
  working: "statusWorking",
  captured: "statusCaptured",
  copied: "statusCopied",
  saved: "statusSaved",
  cancelled: "statusCancelled",
  error: "statusError",
};

function message(key: string): string {
  return chrome.i18n.getMessage(key);
}

function setStatus(kind: keyof typeof STATUS_KEYS): void {
  const status = document.querySelector("#status");
  if (!(status instanceof HTMLElement)) return;
  status.textContent = message(STATUS_KEYS[kind]);
  status.classList.toggle("error", kind === "error");
}

async function showPreview(): Promise<void> {
  const preview = document.querySelector("#preview");
  if (!(preview instanceof HTMLImageElement)) return;
  const dataUrl = await loadCapture();
  if (!dataUrl) {
    preview.hidden = true;
    preview.removeAttribute("src");
    return;
  }
  preview.src = dataUrl;
  preview.hidden = false;
}

function init(): void {
  const player = createSfxPlayer();
  document.querySelectorAll<HTMLElement>("[data-i18n]").forEach((node) => {
    const key = node.dataset.i18n;
    if (key) node.textContent = message(key);
  });
  const preview = document.querySelector("#preview");
  if (preview instanceof HTMLImageElement) preview.alt = message("previewAlt");
  setStatus("ready");
  void showPreview();

  const buttons = Array.from(document.querySelectorAll<HTMLButtonElement>("button[data-action]"));

  async function run(action: ActionId): Promise<void> {
    if (action === "capture-region") {
      try {
        await chrome.runtime.sendMessage({ type: "RUN_BACKGROUND", action });
      } catch {
        setStatus("error");
        try {
          await player.play("error");
        } catch {
          // The popup is only reporting that the background action could not start.
        }
      }
      return;
    }

    for (const button of buttons) button.disabled = true;
    setStatus("working");
    let sound: "capture" | "copy" | "save" | "error" | null = "error";
    try {
      const result = await perform(action, { localClipboard: true });
      sound = result.sound;
      await showPreview();
      setStatus(result.status);
    } catch {
      sound = "error";
      setStatus("error");
    } finally {
      for (const button of buttons) button.disabled = false;
    }
    if (!sound) return;
    try {
      await player.play(sound);
    } catch {
      // Autoplay can reject the attempt; the action result is already shown.
    }
  }

  for (const button of buttons) {
    button.addEventListener("click", () => {
      const action = button.dataset.action;
      if (!isActionId(action)) return;
      void run(action);
    });
  }
}

init();

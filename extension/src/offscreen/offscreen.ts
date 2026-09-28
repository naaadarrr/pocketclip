import { createSfxPlayer } from "../sfx/player";
import { isSoundName } from "../types";

const player = createSfxPlayer();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message !== "object") return;
  if ((message as { type?: unknown }).type !== "PLAY_SFX") return;
  const name = (message as { name?: unknown }).name;
  if (!isSoundName(name)) return;
  player.play(name).then(
    () => sendResponse({ ok: true }),
    (error: unknown) => {
      const text = error instanceof Error ? error.message : String(error);
      sendResponse({ ok: false, error: text });
    },
  );
  return true;
});

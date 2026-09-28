import { SOUND_NAMES, type SoundName } from "../types";

export const SFX_VOLUME = 0.4;
export const SFX_REPEAT_GUARD_MS = 150;

export type SfxPlayer = {
  play: (name: SoundName) => Promise<void>;
};

function soundUrl(name: SoundName): string {
  return chrome.runtime.getURL(`assets/sfx/${name}.mp3`);
}

async function startPlayback(audio: HTMLAudioElement): Promise<void> {
  audio.volume = SFX_VOLUME;
  try {
    audio.pause();
    audio.currentTime = 0;
    await audio.play();
  } catch {
    const clone = new Audio(audio.src);
    clone.preload = "auto";
    clone.volume = SFX_VOLUME;
    await clone.play();
  }
}

export function createSfxPlayer(): SfxPlayer {
  const elements = {} as Record<SoundName, HTMLAudioElement>;
  const lastAt = new Map<SoundName, number>();

  for (const name of SOUND_NAMES) {
    const audio = new Audio(soundUrl(name));
    audio.preload = "auto";
    audio.volume = SFX_VOLUME;
    audio.dataset.sfx = name;
    audio.load();
    (document.body ?? document.documentElement).append(audio);
    elements[name] = audio;
  }

  return {
    async play(name: SoundName) {
      const now = performance.now();
      const previous = lastAt.get(name) ?? Number.NEGATIVE_INFINITY;
      if (now - previous < SFX_REPEAT_GUARD_MS) return;
      lastAt.set(name, now);
      try {
        await startPlayback(elements[name]);
      } catch (error) {
        lastAt.set(name, Number.NEGATIVE_INFINITY);
        throw error;
      }
    },
  };
}

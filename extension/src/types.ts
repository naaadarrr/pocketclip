export const SOUND_NAMES = ["capture", "copy", "save", "error"] as const;
export type SoundName = (typeof SOUND_NAMES)[number];

export const ACTION_IDS = [
  "capture-viewport",
  "capture-region",
  "capture-full",
  "copy",
  "save",
] as const;
export type ActionId = (typeof ACTION_IDS)[number];

export function isSoundName(value: unknown): value is SoundName {
  return typeof value === "string" && (SOUND_NAMES as readonly string[]).includes(value);
}

export function isActionId(value: unknown): value is ActionId {
  return typeof value === "string" && (ACTION_IDS as readonly string[]).includes(value);
}

export type ActionStatus = "captured" | "copied" | "saved" | "cancelled";

export type PerformResult = {
  sound: SoundName | null;
  status: ActionStatus;
};

export type RegionSelection = {
  x: number;
  y: number;
  width: number;
  height: number;
  viewWidth: number;
  viewHeight: number;
};

export type ExtensionMessage =
  | { type: "RUN_BACKGROUND"; action: ActionId }
  | { type: "PLAY_SFX"; name: SoundName }
  | { type: "REGION_SELECTED"; selection: RegionSelection }
  | { type: "REGION_CANCELLED" };

export type PageMetrics = {
  scrollHeight: number;
  clientHeight: number;
  clientWidth: number;
  scrollX: number;
  scrollY: number;
};

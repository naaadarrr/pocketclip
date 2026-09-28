type RegionHandle = { destroy: () => void };

const rootGlobal = globalThis as typeof globalThis & { pocketclipRegion?: RegionHandle };

rootGlobal.pocketclipRegion?.destroy();

const root = document.createElement("div");
const shade = document.createElement("div");
const frame = document.createElement("div");
const bar = document.createElement("div");
const hint = document.createElement("p");
const cancel = document.createElement("button");

hint.textContent = chrome.i18n.getMessage("regionHint");
cancel.type = "button";
cancel.textContent = chrome.i18n.getMessage("regionCancel");

root.id = "pocketclip-region";
Object.assign(root.style, {
  position: "fixed",
  inset: "0",
  zIndex: "2147483646",
  cursor: "crosshair",
  userSelect: "none",
  touchAction: "none",
});
Object.assign(shade.style, {
  position: "absolute",
  inset: "0",
  background: "rgba(0, 0, 0, 0.28)",
});
Object.assign(frame.style, {
  position: "absolute",
  display: "none",
  border: "2px solid #fff",
  boxShadow: "0 0 0 1px rgba(0, 0, 0, 0.4)",
  background: "transparent",
});
Object.assign(bar.style, {
  position: "absolute",
  top: "12px",
  left: "50%",
  transform: "translateX(-50%)",
  display: "flex",
  gap: "8px",
  alignItems: "center",
  padding: "8px 10px",
  borderRadius: "8px",
  background: "#1c1917",
  color: "#fafaf9",
  font: "13px system-ui, sans-serif",
});
Object.assign(hint.style, { margin: "0" });
Object.assign(cancel.style, {
  border: "0",
  borderRadius: "6px",
  padding: "4px 8px",
  background: "#fff",
  color: "#1c1917",
  cursor: "pointer",
});

bar.append(hint, cancel);
root.append(shade, frame, bar);
root.tabIndex = -1;

let startX = 0;
let startY = 0;
let dragging = false;

function selectionFrom(event: PointerEvent): { x: number; y: number; width: number; height: number } {
  const x = Math.min(startX, event.clientX);
  const y = Math.min(startY, event.clientY);
  return {
    x,
    y,
    width: Math.abs(event.clientX - startX),
    height: Math.abs(event.clientY - startY),
  };
}

function paint(rect: { x: number; y: number; width: number; height: number }): void {
  frame.style.display = "block";
  frame.style.left = `${rect.x}px`;
  frame.style.top = `${rect.y}px`;
  frame.style.width = `${rect.width}px`;
  frame.style.height = `${rect.height}px`;
}

function finish(kind: "cancel" | { x: number; y: number; width: number; height: number }): void {
  destroy();
  if (kind === "cancel" || kind.width < 4 || kind.height < 4) {
    void chrome.runtime.sendMessage({ type: "REGION_CANCELLED" });
    return;
  }
  void chrome.runtime.sendMessage({
    type: "REGION_SELECTED",
    selection: {
      ...kind,
      viewWidth: window.innerWidth,
      viewHeight: window.innerHeight,
    },
  });
}

function onPointerDown(event: PointerEvent): void {
  if (event.target === cancel) return;
  dragging = true;
  startX = event.clientX;
  startY = event.clientY;
  root.setPointerCapture(event.pointerId);
  paint({ x: startX, y: startY, width: 0, height: 0 });
  event.preventDefault();
}

function onPointerMove(event: PointerEvent): void {
  if (!dragging) return;
  paint(selectionFrom(event));
}

function onPointerUp(event: PointerEvent): void {
  if (!dragging) return;
  dragging = false;
  finish(selectionFrom(event));
}

function onKeyDown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    finish("cancel");
  }
}

function destroy(): void {
  root.removeEventListener("pointerdown", onPointerDown);
  root.removeEventListener("pointermove", onPointerMove);
  root.removeEventListener("pointerup", onPointerUp);
  window.removeEventListener("keydown", onKeyDown, true);
  root.remove();
  if (rootGlobal.pocketclipRegion?.destroy === destroy) delete rootGlobal.pocketclipRegion;
}

cancel.addEventListener("click", (event) => {
  event.preventDefault();
  event.stopPropagation();
  finish("cancel");
});
root.addEventListener("pointerdown", onPointerDown);
root.addEventListener("pointermove", onPointerMove);
root.addEventListener("pointerup", onPointerUp);
window.addEventListener("keydown", onKeyDown, true);
root.addEventListener("contextmenu", (event) => event.preventDefault());

document.documentElement.append(root);
root.focus();

rootGlobal.pocketclipRegion = { destroy };

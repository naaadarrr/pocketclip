/**
 * Screenshot editor: perfect-freehand pen / text / eraser / eyedropper / undo / download / copy.
 * Base bitmap stays intact; annotations live on #draw. Eraser only clears ink.
 */
(() => {
  const base = document.getElementById("canvas");
  const baseCtx = base.getContext("2d");
  const canvas = document.getElementById("draw");
  const ctx = canvas.getContext("2d");
  const colorInput = document.getElementById("color");
  function syncPenIconColor(hex) {
    // keep sticker pen cursor fill in sync
    if (typeof syncDrawCursor === "function" && tool === "pen") syncDrawCursor();
    const pen = document.querySelector(".pen-icon");
    if (!pen) return;
    const v = (hex || colorInput.value || "#262523").trim();
    pen.style.setProperty("--pen", v);
  }
  const lineWidthInput = document.getElementById("lineWidth");
  const toastEl = document.getElementById("toast");
  const topbar = document.getElementById("topbar");
  const dockWrap = document.getElementById("dock-wrap");
  const viewMeta = document.getElementById("view-meta");

  let tool = "pen";
  let drawing = false;
  let start = null;
  let strokePoints = [];
  let strokeBaseline = null; // ImageData under current stroke
  let undoStack = [];
  let redoStack = [];
  const floatingTexts = [];
  const MAX_HISTORY = 40;

  let displayScale = 1;
  let captureDpr = 1;
  let cssDisplayW = 0;
  let cssDisplayH = 0;
  let baseCssW = 0;
  let baseCssH = 0;
  let userZoom = 1;
  const ZOOM_MIN = 0.1;
  const ZOOM_MAX = 8;

  function toast(msg, kind) {
    toastEl.hidden = false;
    toastEl.textContent = msg;
    toastEl.className = "toast" + (kind ? " " + kind : "");
    clearTimeout(toast._t);
    toast._t = setTimeout(() => {
      toastEl.hidden = true;
    }, 1000);
  }


  function syncCanvasDisplay(cssW, cssH) {
    const bw = base.width;
    const bh = base.height;
    if (cssW && cssH) {
      baseCssW = cssW;
      baseCssH = cssH;
    }
    let w = baseCssW;
    let h = baseCssH;
    if (!w || !h) {
      const dpr = captureDpr || window.devicePixelRatio || 1;
      w = Math.round(bw / dpr);
      h = Math.round(bh / dpr);
      baseCssW = w;
      baseCssH = h;
    }
    // Fit (and upscale if needed) inside #stage-wrap content box
    const wrapEl = document.getElementById("stage-wrap");
    let maxW = Math.max(320, window.visualViewport?.width || window.innerWidth);
    let maxH = Math.max(240, (window.visualViewport?.height || window.innerHeight) * 0.7);
    if (wrapEl) {
      const cs = getComputedStyle(wrapEl);
      const padX = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
      const padY = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
      maxW = Math.max(320, wrapEl.clientWidth - padX);
      maxH = Math.max(240, wrapEl.clientHeight - padY);
    }
    const boxW = maxW;
    const boxH = maxH;
    // 2px slack so 1px rounding never overflows and clips top/left
    maxW = Math.max(160, maxW - 2);
    maxH = Math.max(160, maxH - 2);
    // Uniform contain, including upscale past 100% for small captures.
    const fit = (w > 0 && h > 0) ? Math.min(maxW / w, maxH / h) : 1;
    const z = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, userZoom));
    userZoom = z;
    w = Math.max(1, Math.round(w * fit * z));
    h = Math.max(1, Math.round(h * fit * z));
    cssDisplayW = w;
    cssDisplayH = h;
    base.style.width = w + "px";
    base.style.height = h + "px";
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
    displayScale = bw / w;
    const stageEl = document.getElementById("stage");
    if (stageEl) {
      const overflowX = w > boxW + 0.5;
      const overflowY = h > boxH + 0.5;
      stageEl.style.marginLeft = overflowX ? "0" : "auto";
      stageEl.style.marginRight = overflowX ? "0" : "auto";
      stageEl.style.marginTop = overflowY ? "0" : "auto";
      stageEl.style.marginBottom = overflowY ? "0" : "auto";
    }
    if (wrapEl) {
      wrapEl.scrollTop = 0;
      wrapEl.scrollLeft = 0;
    }
    if (viewMeta) {
      const cw = baseCssW || Math.round(bw / (captureDpr || 1));
      const ch = baseCssH || Math.round(bh / (captureDpr || 1));
      viewMeta.innerHTML = `<span class="meta-size">${cw}×${ch}</span>`;
    }
    if (typeof syncFloatingTextPositions === "function") {
      syncFloatingTextPositions();
    }
  }

  function applyUserZoom(nextZoom, clientX, clientY) {
    const wrap = document.getElementById("stage-wrap");
    if (!wrap) {
      userZoom = nextZoom;
      syncCanvasDisplay();
      return;
    }
    const rect = wrap.getBoundingClientRect();
    const cx = clientX == null ? rect.left + rect.width / 2 : clientX;
    const cy = clientY == null ? rect.top + rect.height / 2 : clientY;
    const beforeX = wrap.scrollLeft + (cx - rect.left);
    const beforeY = wrap.scrollTop + (cy - rect.top);
    const prev = userZoom || 1;
    const next = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, nextZoom));
    if (Math.abs(next - prev) < 1e-6) return;
    const ratio = next / prev;
    userZoom = next;
    syncCanvasDisplay();
    wrap.scrollLeft = beforeX * ratio - (cx - rect.left);
    wrap.scrollTop = beforeY * ratio - (cy - rect.top);
  }

  function matchDrawSize() {
    if (canvas.width !== base.width || canvas.height !== base.height) {
      canvas.width = base.width;
      canvas.height = base.height;
    }
  }

  function hasAnnotations() {
    if (floatingTexts.length) return true;
    if (undoStack.length || redoStack.length) return true;
    return false;
  }

  function syncClearBtn() {
    const btn = document.getElementById("btn-clear");
    if (!btn) return;
    btn.hidden = !hasAnnotations();
  }

  function syncHistoryBtns() {
    const undoBtn = document.getElementById("btn-undo");
    const redoBtn = document.getElementById("btn-redo");
    if (undoBtn) undoBtn.disabled = !undoStack.length;
    if (redoBtn) redoBtn.disabled = !redoStack.length;
    syncClearBtn();
  }

  function snapshotDraw() {
    try {
      return canvas.toDataURL("image/png");
    } catch (_) {
      return null;
    }
  }

  function loadDrawUrl(url) {
    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        matchDrawSize();
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.globalCompositeOperation = "source-over";
        ctx.drawImage(img, 0, 0);
        resolve();
      };
      img.onerror = () => resolve();
      img.src = url;
    });
  }

  function pushHistory() {
    const snap = snapshotDraw();
    if (!snap) return;
    undoStack.push(snap);
    if (undoStack.length > MAX_HISTORY) undoStack.shift();
    redoStack = [];
    syncHistoryBtns();
  }

  async function undo() {
    if (!undoStack.length) {
      toast("Nothing to undo", "err");
      return;
    }
    const current = snapshotDraw();
    const prev = undoStack.pop();
    if (current) redoStack.push(current);
    await loadDrawUrl(prev);
    syncHistoryBtns();
  }

  async function redo() {
    if (!redoStack.length) {
      toast("Nothing to redo", "err");
      return;
    }
    const current = snapshotDraw();
    const next = redoStack.pop();
    if (current) undoStack.push(current);
    await loadDrawUrl(next);
    syncHistoryBtns();
  }

  function loadFromStorage() {
    return new Promise((resolve, reject) => {
      chrome.storage.local.get(
        ["screenshotDataUrl", "screenshotDpr", "screenshotCssWidth", "screenshotCssHeight"],
        (res) => {
          if (chrome.runtime.lastError) {
            reject(new Error(chrome.runtime.lastError.message));
            return;
          }
          if (!res.screenshotDataUrl) {
            reject(new Error("No screenshot found. Capture again."));
            return;
          }
          resolve(res);
        }
      );
    });
  }


  let editorTheme = "dark";

  function estimateImageLuma(img) {
    try {
      const tw = 64;
      const th = Math.max(1, Math.round((img.height / img.width) * tw));
      const c = document.createElement("canvas");
      c.width = tw;
      c.height = th;
      const x = c.getContext("2d", { willReadFrequently: true });
      x.drawImage(img, 0, 0, tw, th);
      const { data } = x.getImageData(0, 0, tw, th);
      let sum = 0;
      const n = tw * th;
      for (let i = 0; i < data.length; i += 4) {
        sum += 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
      }
      return sum / n / 255;
    } catch (_) {
      return 0.5;
    }
  }

  function setEditorTheme(theme) {
    editorTheme = theme === "light" ? "light" : "dark";
    document.body.dataset.theme = editorTheme;
  }

  function autoThemeFromImage(img) {
    const luma = estimateImageLuma(img);
    // dark screenshot → light editor bg; light screenshot → dark editor bg
    setEditorTheme(luma < 0.45 ? "light" : "dark");
  }

  function setImage(dataUrl, meta) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        base.width = img.width;
        base.height = img.height;
        baseCtx.drawImage(img, 0, 0);
        canvas.width = img.width;
        canvas.height = img.height;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        undoStack = [];
        redoStack = [];
        syncHistoryBtns();
        captureDpr = meta.dpr || window.devicePixelRatio || 1;
        let cssW = meta.cssWidth || 0;
        let cssH = meta.cssHeight || 0;
        if (!cssW || !cssH) {
          cssW = Math.round(img.width / captureDpr);
          cssH = Math.round(img.height / captureDpr);
        }
        const bmpAspect = img.width / img.height;
        const cssAspect = cssW / cssH;
        if (Math.abs(bmpAspect - cssAspect) > 0.02) {
          cssH = Math.round(cssW / bmpAspect);
        }
        userZoom = 1;
        syncCanvasDisplay(cssW, cssH);
        // Theme sample is cheap but still off the critical paint path
        requestAnimationFrame(() => autoThemeFromImage(img));
        resolve();
      };
      img.onerror = () => reject(new Error("Failed to load image"));
      img.src = dataUrl;
    });
  }

  function pointerPos(e) {
    const r = canvas.getBoundingClientRect();
    const scaleX = canvas.width / r.width;
    const scaleY = canvas.height / r.height;
    return {
      x: (e.clientX - r.left) * scaleX,
      y: (e.clientY - r.top) * scaleY,
    };
  }

  function strokeStyle() {
    const s = displayScale || 1;
    ctx.strokeStyle = colorInput.value;
    ctx.fillStyle = colorInput.value;
    ctx.lineWidth = (Number(lineWidthInput.value) || 4) * s;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
  }


  function inkOptions(sizePx) {
    // Variable-width ink options
    return {
      size: Math.max(1, sizePx),
      thinning: 0.1,
      smoothing: 0.1,
      streamline: 0.1,
      simulatePressure: true,
      start: { cap: true },
      end: { cap: true },
    };
  }

  function fillFreehand(points, color, composite) {
    if (!points || points.length < 1 || typeof getStroke !== "function") return;
    const input = points.map((pt) => [pt.x, pt.y, pt.pressure != null ? pt.pressure : 0.5]);
    const sizeCss = Number(lineWidthInput.value) || 6;
    const sizePx = sizeCss * (displayScale || 1) * (tool === "eraser" || composite === "destination-out" ? 2.2 : 1);
    const outline = getStroke(input, inkOptions(sizePx));
    if (!outline.length) return;
    ctx.save();
    ctx.globalCompositeOperation = composite || "source-over";
    ctx.fillStyle = color || colorInput.value;
    ctx.beginPath();
    ctx.moveTo(outline[0][0], outline[0][1]);
    for (let i = 1; i < outline.length; i++) {
      ctx.lineTo(outline[i][0], outline[i][1]);
    }
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  function redrawCurrentStroke() {
    if (!strokeBaseline) return;
    ctx.putImageData(strokeBaseline, 0, 0);
    if (tool === "eraser") {
      fillFreehand(strokePoints, "#000", "destination-out");
    } else if (tool === "arrow" && start && strokePoints.length) {
      const end = strokePoints[strokePoints.length - 1];
      drawArrowShape(ctx, start, end, colorInput.value);
    } else {
      fillFreehand(strokePoints, colorInput.value, "source-over");
    }
  }

  function drawArrowShape(targetCtx, from, to, color) {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const len = Math.hypot(dx, dy);
    if (len < 1) return;
    const sizeCss = Number(lineWidthInput.value) || 6;
    const lw = Math.max(2, sizeCss * (displayScale || 1));
    const head = Math.max(lw * 3.2, Math.min(len * 0.35, lw * 7));
    const angle = Math.atan2(dy, dx);
    targetCtx.save();
    targetCtx.globalCompositeOperation = "source-over";
    targetCtx.strokeStyle = color;
    targetCtx.fillStyle = color;
    targetCtx.lineWidth = lw;
    targetCtx.lineCap = "round";
    targetCtx.lineJoin = "round";
    // shaft stops before tip so head sits cleanly
    const tipBack = head * 0.72;
    const sx = to.x - Math.cos(angle) * tipBack;
    const sy = to.y - Math.sin(angle) * tipBack;
    targetCtx.beginPath();
    targetCtx.moveTo(from.x, from.y);
    targetCtx.lineTo(sx, sy);
    targetCtx.stroke();
    targetCtx.beginPath();
    targetCtx.moveTo(to.x, to.y);
    targetCtx.lineTo(
      to.x - head * Math.cos(angle - Math.PI / 7),
      to.y - head * Math.sin(angle - Math.PI / 7)
    );
    targetCtx.lineTo(
      to.x - head * Math.cos(angle + Math.PI / 7),
      to.y - head * Math.sin(angle + Math.PI / 7)
    );
    targetCtx.closePath();
    targetCtx.fill();
    targetCtx.restore();
  }


  let textEditorEl = null;
  let textEditorWrap = null;
  let textIgnoreBlur = false;
  let dragLabel = null;
  let dragTextEditor = false;
  let dragOffsetX = 0;
  let dragOffsetY = 0;
  let scaleLabel = null;
  let scaleTextEditor = false;
  let scaleStartSize = 0;
  let scaleStartDist = 0;

  function canvasToStage(cx, cy) {
    const stage = document.getElementById("stage");
    const sr = stage.getBoundingClientRect();
    const r = canvas.getBoundingClientRect();
    const scaleX = canvas.width / r.width;
    const scaleY = canvas.height / r.height;
    return {
      left: r.left - sr.left + cx / scaleX,
      top: r.top - sr.top + cy / scaleY,
    };
  }

  /** Capture-CSS px → on-screen px (scales with fit × userZoom). */
  function textScreenScale() {
    const baseW = baseCssW || (base.width / (captureDpr || window.devicePixelRatio || 1)) || 1;
    const screenW = cssDisplayW || baseW;
    return screenW / baseW;
  }

  function captureTextToScreen(cssSize) {
    return (Number(cssSize) || 14) * textScreenScale();
  }

  function captureTextToBitmap(cssSize) {
    const baseW = baseCssW || (base.width / (captureDpr || window.devicePixelRatio || 1)) || 1;
    return (Number(cssSize) || 14) * (base.width / baseW);
  }

  function screenTextToCapture(screenPx) {
    const s = textScreenScale() || 1;
    return screenPx / s;
  }

  function syncTextEditorLayout() {
    if (!textEditorEl || !textEditorWrap) return;
    const cssSize = Number(textEditorEl.dataset.cssSize) || 14;
    textEditorEl.style.fontSize = captureTextToScreen(cssSize) + "px";
    const pos = canvasToStage(Number(textEditorEl.dataset.canvasX), Number(textEditorEl.dataset.canvasY));
    textEditorWrap.style.left = (pos.left - 10) + "px";
    textEditorWrap.style.top = (pos.top - 10) + "px";
  }

  function syncFloatingTextPositions() {
    for (const el of floatingTexts) {
      const pos = canvasToStage(Number(el.dataset.canvasX), Number(el.dataset.canvasY));
      el.style.left = pos.left + "px";
      el.style.top = pos.top + "px";
      const cssSize = Number(el.dataset.cssSize) || 14;
      el.style.fontSize = captureTextToScreen(cssSize) + "px";
      el.dataset.bitmapSize = String(captureTextToBitmap(cssSize));
    }
    syncTextEditorLayout();
  }

  function paintLabelOnCtx(targetCtx, el) {
    const text = el.dataset.text || "";
    if (!text) return;
    const size = Number(el.dataset.bitmapSize) || Math.max(14, Number(el.dataset.cssSize || 14) * (displayScale || 1));
    targetCtx.save();
    targetCtx.globalCompositeOperation = "source-over";
    targetCtx.fillStyle = el.dataset.color || colorInput.value;
    targetCtx.font = `600 ${size}px PingFang SC, Microsoft YaHei, system-ui, sans-serif`;
    targetCtx.textBaseline = "top";
    targetCtx.fillText(text, Number(el.dataset.canvasX), Number(el.dataset.canvasY));
    targetCtx.restore();
  }

  function removeFloatingText(el) {
    const i = floatingTexts.indexOf(el);
    if (i >= 0) floatingTexts.splice(i, 1);
    el.remove();
    syncClearBtn();
  }

  function bakeFloatingTexts() {
    if (!floatingTexts.length) return;
    pushHistory();
    for (const el of floatingTexts.slice()) {
      paintLabelOnCtx(ctx, el);
      el.remove();
    }
    floatingTexts.length = 0;
  }

  function applyLabelSize(el, cssSize) {
    const size = Math.max(10, Math.min(240, cssSize));
    el.dataset.cssSize = String(size);
    el.dataset.bitmapSize = String(captureTextToBitmap(size));
    el.style.fontSize = captureTextToScreen(size) + "px";
    return size;
  }

  function createFloatingText({ text, canvasX, canvasY, color, cssSize }) {
    const stage = document.getElementById("stage");
    const el = document.createElement("div");
    el.className = "on-canvas-label";
    el.tabIndex = 0;
    el.dataset.text = text;
    el.dataset.canvasX = String(canvasX);
    el.dataset.canvasY = String(canvasY);
    el.dataset.color = color;
    const body = document.createElement("span");
    body.className = "on-canvas-label__text";
    body.textContent = text;
    const handle = document.createElement("span");
    handle.className = "on-canvas-label__handle";
    handle.title = "Drag to scale";
    el.appendChild(body);
    el.appendChild(handle);
    applyLabelSize(el, cssSize);
    const pos = canvasToStage(canvasX, canvasY);
    el.style.left = pos.left + "px";
    el.style.top = pos.top + "px";
    el.style.color = color;
    el.title = "Drag to move · Corner to scale · Scroll to scale · Double-click to edit";

    el.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      if (e.target === handle || handle.contains(e.target)) return;
      e.preventDefault();
      e.stopPropagation();
      dragLabel = el;
      scaleLabel = null;
      const rect = el.getBoundingClientRect();
      dragOffsetX = e.clientX - rect.left;
      dragOffsetY = e.clientY - rect.top;
      el.classList.add("is-dragging");
      el.focus();
    });

    handle.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      dragLabel = null;
      scaleLabel = el;
      const rect = el.getBoundingClientRect();
      const cx = rect.left;
      const cy = rect.top;
      scaleStartSize = Number(el.dataset.cssSize) || cssSize;
      scaleStartDist = Math.max(8, Math.hypot(e.clientX - cx, e.clientY - cy));
      el.classList.add("is-scaling");
      el.focus();
    });

    el.addEventListener("wheel", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const cur = Number(el.dataset.cssSize) || 14;
      const next = cur + (e.deltaY < 0 ? 2 : -2);
      applyLabelSize(el, next);
      el.focus();
    }, { passive: false });

    el.addEventListener("dblclick", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const cx = Number(el.dataset.canvasX);
      const cy = Number(el.dataset.canvasY);
      const col = el.dataset.color;
      const size = Number(el.dataset.cssSize);
      const prev = el.dataset.text;
      removeFloatingText(el);
      const pos2 = canvasToStage(cx, cy);
      openTextEditorAt(pos2.left, pos2.top, { x: cx, y: cy }, {
        value: prev,
        color: col,
        cssSize: size,
      });
    });

    el.addEventListener("keydown", (e) => {
      if (e.key === "Backspace" || e.key === "Delete") {
        e.preventDefault();
        removeFloatingText(el);
      } else if (e.key === "=" || e.key === "+") {
        e.preventDefault();
        applyLabelSize(el, (Number(el.dataset.cssSize) || 14) + 2);
      } else if (e.key === "-" || e.key === "_") {
        e.preventDefault();
        applyLabelSize(el, (Number(el.dataset.cssSize) || 14) - 2);
      }
    });

    floatingTexts.push(el);
    stage.appendChild(el);
    syncClearBtn();
    return el;
  }

  window.addEventListener("mousemove", (e) => {
    if (dragTextEditor && textEditorWrap && textEditorEl) {
      const stage = document.getElementById("stage");
      const sr = stage.getBoundingClientRect();
      const left = e.clientX - sr.left - dragOffsetX;
      const top = e.clientY - sr.top - dragOffsetY;
      textEditorWrap.style.left = left + "px";
      textEditorWrap.style.top = top + "px";
      const r = canvas.getBoundingClientRect();
      const scaleX = canvas.width / r.width;
      const scaleY = canvas.height / r.height;
      // account for wrap padding (10px) so caret origin stays aligned
      const pad = 10;
      textEditorEl.dataset.canvasX = String((left + pad - (r.left - sr.left)) * scaleX);
      textEditorEl.dataset.canvasY = String((top + pad - (r.top - sr.top)) * scaleY);
      return;
    }
    if (scaleTextEditor && textEditorEl) {
      const wrap = textEditorWrap || textEditorEl;
      const rect = wrap.getBoundingClientRect();
      const dist = Math.max(8, Math.hypot(e.clientX - rect.left, e.clientY - rect.top));
      const nextCapture = Math.max(10, Math.min(240, scaleStartSize * (dist / scaleStartDist)));
      textEditorEl.dataset.cssSize = String(nextCapture);
      textEditorEl.style.fontSize = captureTextToScreen(nextCapture) + "px";
      return;
    }
    if (scaleLabel) {
      const rect = scaleLabel.getBoundingClientRect();
      const dist = Math.max(8, Math.hypot(e.clientX - rect.left, e.clientY - rect.top));
      const next = scaleStartSize * (dist / scaleStartDist);
      applyLabelSize(scaleLabel, next);
      return;
    }
    if (!dragLabel) return;
    const stage = document.getElementById("stage");
    const sr = stage.getBoundingClientRect();
    const left = e.clientX - sr.left - dragOffsetX;
    const top = e.clientY - sr.top - dragOffsetY;
    dragLabel.style.left = left + "px";
    dragLabel.style.top = top + "px";
    const r = canvas.getBoundingClientRect();
    const scaleX = canvas.width / r.width;
    const scaleY = canvas.height / r.height;
    dragLabel.dataset.canvasX = String((e.clientX - dragOffsetX - r.left) * scaleX);
    dragLabel.dataset.canvasY = String((e.clientY - dragOffsetY - r.top) * scaleY);
  });

  window.addEventListener("mouseup", () => {
    if (dragLabel) {
      dragLabel.classList.remove("is-dragging");
      dragLabel = null;
    }
    if (scaleLabel) {
      scaleLabel.classList.remove("is-scaling");
      scaleLabel = null;
    }
    const endTextChrome = scaleTextEditor || dragTextEditor;
    if (dragTextEditor) {
      dragTextEditor = false;
      if (textEditorWrap) textEditorWrap.classList.remove("is-dragging");
    }
    if (scaleTextEditor) {
      scaleTextEditor = false;
      if (textEditorWrap) textEditorWrap.classList.remove("is-scaling");
    }
    if (endTextChrome && textEditorEl) {
      textIgnoreBlur = true;
      textEditorEl.focus();
      setTimeout(() => {
        textIgnoreBlur = false;
      }, 120);
    }
  });

  function dismissTextEditor(commit) {
    if (!textEditorEl) return;
    const el = textEditorEl;
    const wrap = textEditorWrap;
    textEditorEl = null;
    textEditorWrap = null;
    scaleTextEditor = false;
    dragTextEditor = false;
    textIgnoreBlur = false;
    const value = (el.value || "").trim();
    const x = Number(el.dataset.canvasX);
    const y = Number(el.dataset.canvasY);
    const color = el.style.color || colorInput.value;
    const cssSize = Number(el.dataset.cssSize) || Math.max(14, Number(lineWidthInput.value) * 5);
    if (wrap && wrap.parentNode) wrap.remove();
    else el.remove();
    if (commit && value) {
      createFloatingText({ text: value, canvasX: x, canvasY: y, color, cssSize });
    }
  }

  function openTextEditorAt(stageLeft, stageTop, canvasPt, opts) {
    opts = opts || {};
    dismissTextEditor(true);
    const stage = document.getElementById("stage");
    const wrap = document.createElement("div");
    wrap.className = "on-canvas-text-wrap";
    // wrap has 10px padding; keep textarea origin at click point
    wrap.style.left = (stageLeft - 10) + "px";
    wrap.style.top = (stageTop - 10) + "px";
    const el = document.createElement("textarea");
    el.id = "text-input";
    el.className = "on-canvas-text";
    el.rows = 1;
    el.placeholder = "Type…";
    el.spellcheck = false;
    el.dataset.canvasX = String(canvasPt.x);
    el.dataset.canvasY = String(canvasPt.y);
    const cssSize = opts.cssSize != null ? opts.cssSize : Math.max(14, Number(lineWidthInput.value) * 5);
    const color = opts.color || colorInput.value;
    el.dataset.cssSize = String(cssSize);
    el.style.color = color;
    el.style.fontSize = captureTextToScreen(cssSize) + "px";
    el.style.lineHeight = "1.25";
    el.style.caretColor = color;
    if (opts.value) el.value = opts.value;
    const handle = document.createElement("span");
    handle.className = "on-canvas-text__handle";
    handle.title = "Drag to scale";
    wrap.appendChild(el);
    wrap.appendChild(handle);
    textIgnoreBlur = true;
    stage.appendChild(wrap);
    textEditorEl = el;
    textEditorWrap = wrap;
    syncTextCursorPill(null, null, false);
    const scaleTyping = (delta) => {
      const cur = Number(el.dataset.cssSize) || cssSize;
      const next = Math.max(10, Math.min(240, cur + delta));
      el.dataset.cssSize = String(next);
      el.style.fontSize = captureTextToScreen(next) + "px";
    };
    handle.addEventListener("mousedown", (ev) => {
      if (ev.button !== 0) return;
      ev.preventDefault();
      ev.stopPropagation();
      textIgnoreBlur = true;
      scaleTextEditor = true;
      dragTextEditor = false;
      scaleLabel = null;
      dragLabel = null;
      const rect = wrap.getBoundingClientRect();
      scaleStartSize = Number(el.dataset.cssSize) || cssSize;
      scaleStartDist = Math.max(8, Math.hypot(ev.clientX - rect.left, ev.clientY - rect.top));
      wrap.classList.add("is-scaling");
    });
    const startTextDrag = (ev) => {
      if (ev.button !== 0) return;
      ev.preventDefault();
      ev.stopPropagation();
      textIgnoreBlur = true;
      dragTextEditor = true;
      scaleTextEditor = false;
      scaleLabel = null;
      dragLabel = null;
      const rect = wrap.getBoundingClientRect();
      const stage = document.getElementById("stage");
      const sr = stage.getBoundingClientRect();
      dragOffsetX = ev.clientX - rect.left;
      dragOffsetY = ev.clientY - rect.top;
      wrap.classList.add("is-dragging");
    };
    // Drag the dashed frame (padding), or Option-drag the text
    wrap.addEventListener("mousedown", (ev) => {
      if (ev.target === handle || handle.contains(ev.target)) return;
      if (ev.target === el || el.contains(ev.target)) return;
      startTextDrag(ev);
    });
    el.addEventListener("mousedown", (ev) => {
      if (ev.altKey || ev.metaKey) {
        startTextDrag(ev);
      }
    });
    el.addEventListener("wheel", (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      scaleTyping(ev.deltaY < 0 ? 2 : -2);
    }, { passive: false });
    wrap.addEventListener("wheel", (ev) => {
      if (ev.target === el) return;
      ev.preventDefault();
      ev.stopPropagation();
      scaleTyping(ev.deltaY < 0 ? 2 : -2);
    }, { passive: false });
    el.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && !ev.shiftKey) {
        ev.preventDefault();
        dismissTextEditor(true);
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        dismissTextEditor(false);
      } else if (ev.key === "=" || ev.key === "+") {
        ev.preventDefault();
        scaleTyping(2);
      } else if (ev.key === "-" || ev.key === "_") {
        ev.preventDefault();
        scaleTyping(-2);
      }
    });
    el.addEventListener("blur", () => {
      if (textIgnoreBlur || scaleTextEditor || dragTextEditor) return;
      dismissTextEditor(true);
    });
    requestAnimationFrame(() => {
      if (textEditorEl !== el) return;
      el.focus();
      if (opts.value) el.select();
      setTimeout(() => {
        if (!scaleTextEditor) textIgnoreBlur = false;
      }, 120);
    });
  }

  function openTextEditor(domEvent, canvasPt) {
    const stage = document.getElementById("stage");
    const stageRect = stage.getBoundingClientRect();
    openTextEditorAt(
      domEvent.clientX - stageRect.left,
      domEvent.clientY - stageRect.top,
      canvasPt,
      {}
    );
  }

  const textCursorPill = document.createElement("div");
  textCursorPill.className = "text-cursor-pill";
  textCursorPill.setAttribute("aria-hidden", "true");
  const textCursorLabel = document.createElement("span");
  textCursorLabel.className = "text-cursor-pill__text";
  textCursorLabel.textContent = "Type here…";
  const textCursorCaret = document.createElement("span");
  textCursorCaret.className = "text-cursor-pill__caret";
  textCursorPill.appendChild(textCursorLabel);
  textCursorPill.appendChild(textCursorCaret);
  document.body.appendChild(textCursorPill);

  function syncTextCursorPill(clientX, clientY, overDraw) {
    const show =
      tool === "text" &&
      !textEditorEl &&
      overDraw &&
      clientX != null &&
      clientY != null;
    textCursorPill.classList.toggle("is-on", !!show);
    if (show) {
      textCursorPill.style.left = clientX + "px";
      textCursorPill.style.top = clientY + "px";
    }
  }


  // Editor cursors — sticker SVG data-URLs
  const CURSOR_SIZE = { pencil: [32, 32], eraser: [34, 34] };
  const CURSOR_HOT = { pencil: [12, 28], eraser: [13, 28] };
  const CURSOR_PAD = 4;
  const PENCIL_CURSOR_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\" viewBox=\"-4 -4 40 40\" fill=\"none\">  <defs><filter id=\"ds\" x=\"-35%\" y=\"-35%\" width=\"170%\" height=\"170%\"><feDropShadow dx=\"0\" dy=\"0.6\" stdDeviation=\"1.1\" flood-color=\"black\" flood-opacity=\"0.28\"/></filter></defs>  <g filter=\"url(#ds)\" transform=\"scale(0.2)\"><g><path d=\"M120.794 57.636L102.363 39.2016C101.75 38.5886 101.023 38.1024 100.222 37.7702C99.4207 37.4385 98.5625 37.2677 97.6956 37.2677C96.8288 37.2677 95.9705 37.4385 95.1694 37.7702C94.3688 38.1024 93.6411 38.5886 93.0281 39.2016L39.3343 92.8994C38.7188 93.51 38.2308 94.237 37.8987 95.0379C37.5665 95.8388 37.3969 96.6977 37.3997 97.5648V115.999C37.3997 117.75 38.0951 119.429 39.3328 120.666C40.5706 121.904 42.2493 122.599 43.9997 122.599H62.4343C63.3014 122.602 64.1603 122.433 64.9612 122.1C65.7622 121.768 66.4891 121.28 67.0997 120.665L120.794 66.971C121.407 66.3581 121.893 65.6304 122.225 64.8297C122.556 64.0286 122.727 63.1704 122.727 62.3035C122.727 61.4366 122.556 60.5784 122.225 59.7773C121.893 58.9766 121.407 58.2489 120.794 57.636Z\" fill=\"__COLOR__\"/><path d=\"M62.436 125C63.6181 125.003 64.7893 124.768 65.8813 124.316C66.9729 123.863 67.9638 123.199 68.7969 122.361L122.489 68.6684C123.326 67.8327 123.992 66.84 124.444 65.748C124.896 64.6565 125.128 63.4844 125.128 62.3026C125.128 61.1213 124.896 59.9492 124.444 58.8577C123.992 57.7657 123.325 56.7725 122.489 55.9373L104.063 37.5058C103.228 36.6706 102.233 36.0082 101.142 35.5561C100.051 35.1039 98.8787 34.8673 97.6974 34.8668C96.5152 34.8668 95.344 35.1034 94.252 35.5561C93.16 36.0082 92.1674 36.6701 91.3317 37.5058L37.6391 91.2031C36.8021 92.0357 36.1368 93.0281 35.6844 94.1188C35.2304 95.2134 34.9963 96.3883 35 97.5734V116C35 118.387 35.9466 120.678 37.6344 122.366C39.3223 124.053 41.6131 125 44 125H62.436Z\" stroke=\"white\" stroke-width=\"6\"/><path d=\"M120.793 57.6363L102.363 39.2014C101.75 38.5885 101.022 38.1022 100.222 37.7706C99.4205 37.4389 98.5622 37.268 97.6954 37.268C96.8285 37.268 95.9703 37.4389 95.1691 37.7706C94.3685 38.1022 93.6408 38.5885 93.0279 39.2014L39.3341 92.8995C38.7186 93.5102 38.2305 94.2371 37.8984 95.038C37.5663 95.8389 37.3967 96.6978 37.3995 97.5649V116C37.3995 117.75 38.0948 119.429 39.3326 120.666C40.5703 121.904 42.249 122.6 43.9995 122.6H62.4341C63.3011 122.602 64.16 122.433 64.961 122.101C65.7619 121.768 66.4888 121.28 67.0995 120.665L120.793 66.9709C121.406 66.3584 121.893 65.6307 122.224 64.8296C122.556 64.029 122.727 63.1707 122.727 62.3039C122.727 61.437 122.556 60.5783 122.224 59.7776C121.893 58.977 121.406 58.2493 120.793 57.6363ZM45.3648 96.1995L83.1278 58.4365L101.563 76.8709L63.7995 114.634L45.3648 96.1995ZM43.9995 104.165L55.8341 116H43.9995V104.165ZM106.228 72.2058L87.7935 53.7709L97.6935 43.8709L116.128 62.3015L106.228 72.2058Z\" fill=\"black\"/></g></g></svg>";
  const ERASER_CURSOR_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"42\" height=\"42\" viewBox=\"-4 -4 42 42\" fill=\"none\">  <defs><filter id=\"ds\" x=\"-35%\" y=\"-35%\" width=\"170%\" height=\"170%\"><feDropShadow dx=\"0\" dy=\"0.6\" stdDeviation=\"1.1\" flood-color=\"black\" flood-opacity=\"0.28\"/></filter></defs>  <g filter=\"url(#ds)\" transform=\"scale(0.2125)\"><g><g><g><path d=\"M39.8453 97.9441C36.351 94.4499 36.351 88.7845 39.8453 85.2902L85.8247 39.3108C89.3189 35.8166 94.9843 35.8166 98.4785 39.3108L121.075 61.9071C124.569 65.4013 124.569 71.0667 121.075 74.5609L75.0954 120.54C71.6011 124.035 65.9357 124.035 62.4415 120.54L39.8453 97.9441Z\" fill=\"#FEBED4\" stroke=\"white\" stroke-width=\"5.11294\"/><path d=\"M42.0576 96.9211C38.7473 93.6108 38.7473 88.2437 42.0576 84.9334L85.4678 41.5232C88.7781 38.2129 94.1452 38.2129 97.4556 41.5232L118.862 62.93C122.173 66.2403 122.173 71.6074 118.862 74.9177L75.4522 118.328C72.1418 121.638 66.7747 121.638 63.4644 118.328L42.0576 96.9211Z\" fill=\"#FEBED4\"/><path d=\"M85.468 41.523C88.7783 38.2129 94.1454 38.2128 97.4556 41.523L118.862 62.9295C122.172 66.2398 122.172 71.6069 118.862 74.9172L75.4518 118.328C72.1414 121.638 66.7744 121.638 63.4641 118.328L42.0576 96.9211C38.7473 93.6108 38.7473 88.2437 42.0576 84.9334L85.468 41.523ZM87.1798 99.7495L115.437 71.4922C116.856 70.0734 116.856 67.7732 115.437 66.3546L94.0306 44.948C92.6119 43.5295 90.3117 43.5295 88.893 44.948L60.6357 73.2054L87.1798 99.7495ZM45.4826 88.3585C44.064 89.7772 44.064 92.0773 45.4826 93.496L66.8892 114.903C68.3079 116.321 70.608 116.321 72.0267 114.903L83.7548 103.175L57.2106 76.6304L45.4826 88.3585Z\" fill=\"black\"/></g><path d=\"M57.0734 73.5096L87.479 43.104C90.2127 40.3703 94.6448 40.3703 97.3785 43.104L117.178 62.903C119.911 65.6367 119.911 70.0688 117.178 72.8025L86.7719 103.208L57.0734 73.5096Z\" fill=\"#E8923A\" stroke=\"black\" stroke-width=\"4\"/><g><mask id=\"emask\" maskUnits=\"userSpaceOnUse\" x=\"59\" y=\"43\" width=\"59\" height=\"58\"><path d=\"M59.9019 73.5096L88.8932 44.5182C90.8459 42.5656 94.0117 42.5656 95.9643 44.5182L115.763 64.3172C117.716 66.2698 117.716 69.4356 115.763 71.3883L86.7719 100.38L59.9019 73.5096Z\" fill=\"#E8923A\"/></mask><g mask=\"url(#emask)\"><path d=\"M94.1075 111.241L89.6011 115.747L85.0946 111.241L89.6011 106.734L94.1075 111.241ZM103.121 102.227L98.6139 106.734L94.1075 102.228L98.6146 97.7206L103.121 102.227ZM112.134 93.2141L107.627 97.7206L103.121 93.2141L107.627 88.7077L112.134 93.2141ZM121.147 84.2006L116.641 88.707L112.135 84.2006L116.641 79.6942L121.147 84.2006ZM130.16 75.1877L125.654 79.6942L121.147 75.1877L125.654 70.6813L130.16 75.1877ZM139.174 66.1742L134.667 70.6806L130.161 66.1742L134.667 61.6678L139.174 66.1742ZM85.0946 111.241L80.5882 115.747L76.0818 111.241L80.5882 106.734L85.0946 111.241ZM94.1075 102.228L89.6011 106.734L85.0946 102.228L89.6011 97.7212L94.1075 102.228ZM103.121 93.2141L98.6146 97.7206L94.1082 93.2141L98.6146 88.7077L103.121 93.2141ZM112.135 84.2006L107.627 88.7077L103.121 84.2013L107.628 79.6942L112.135 84.2006ZM121.147 75.1877L116.641 79.6942L112.135 75.1877L116.641 70.6813L121.147 75.1877ZM130.161 66.1742L125.654 70.6813L121.147 66.1749L125.655 61.6678L130.161 66.1742ZM85.0946 102.228L80.5882 106.734L76.0811 102.227L80.5875 97.7206L85.0946 102.228ZM94.1082 93.2141L89.6011 97.7212L85.0939 93.2141L89.6011 88.707L94.1082 93.2141ZM103.121 84.2013L98.6146 88.7077L94.1075 84.2006L98.6139 79.6942L103.121 84.2013ZM112.135 75.1877L107.628 79.6942L103.121 75.1871L107.627 70.6806L112.135 75.1877ZM121.147 66.1749L116.641 70.6813L112.134 66.1742L116.64 61.6678L121.147 66.1749ZM130.161 57.1614L125.655 61.6678L121.147 57.1607L125.654 52.6542L130.161 57.1614ZM85.0946 93.2148L80.5882 97.7212L76.0811 93.2141L80.5875 88.7077L85.0946 93.2148ZM76.0811 102.227L71.5747 106.733L67.0682 102.227L71.5747 97.7206L76.0811 102.227ZM94.1075 84.2006L89.6011 88.707L85.0946 84.2006L89.6011 79.6942L94.1075 84.2006ZM103.12 75.1877L98.6139 79.6942L94.1075 75.1877L98.6139 70.6813L103.12 75.1877ZM112.134 66.1742L107.627 70.6806L103.121 66.1742L107.627 61.6678L112.134 66.1742ZM121.147 57.1607L116.64 61.6678L112.134 57.1614L116.641 52.6542L121.147 57.1607ZM76.0811 93.2141L71.5747 97.7206L67.0682 93.2141L71.5747 88.7077L76.0811 93.2141ZM85.0946 84.2006L80.5875 88.7077L76.0811 84.2013L80.5882 79.6942L85.0946 84.2006ZM94.1075 75.1877L89.6011 79.6942L85.0946 75.1877L89.6011 70.6813L94.1075 75.1877ZM103.121 66.1742L98.6139 70.6813L94.1075 66.1749L98.6146 61.6678L103.121 66.1742ZM112.134 57.1614L107.627 61.6678L103.121 57.1614L107.627 52.6549L112.134 57.1614ZM121.147 48.1478L116.641 52.6542L112.135 48.1478L116.641 43.6414L121.147 48.1478ZM67.0682 93.2141L62.5618 97.7206L58.0554 93.2141L62.5618 88.7077L67.0682 93.2141ZM76.0811 84.2013L71.5747 88.7077L67.0682 84.2013L71.5747 79.6949L76.0811 84.2013ZM85.0946 75.1877L80.5882 79.6942L76.0818 75.1877L80.5882 70.6813L85.0946 75.1877ZM94.1075 66.1749L89.6011 70.6813L85.0946 66.1749L89.6011 61.6685L94.1075 66.1749ZM103.121 57.1614L98.6146 61.6678L94.1082 57.1614L98.6146 52.6549L103.121 57.1614ZM112.135 48.1478L107.627 52.6549L103.121 48.1485L107.628 43.6414L112.135 48.1478ZM67.0682 84.2013L62.5618 88.7077L58.0547 84.2006L62.5611 79.6942L67.0682 84.2013ZM76.0818 75.1877L71.5747 79.6949L67.0675 75.1877L71.5747 70.6806L76.0818 75.1877ZM85.0946 66.1749L80.5882 70.6813L76.0811 66.1742L80.5875 61.6678L85.0946 66.1749ZM94.1082 57.1614L89.6011 61.6685L85.0939 57.1614L89.6011 52.6542L94.1082 57.1614ZM103.121 48.1485L98.6146 52.6549L94.1075 48.1478L98.6139 43.6414L103.121 48.1485ZM112.135 39.135L107.628 43.6414L103.121 39.1343L107.627 34.6279L112.135 39.135ZM58.0547 84.2006L53.5483 88.707L49.0418 84.2006L53.5483 79.6942L58.0547 84.2006ZM67.0675 75.1877L62.5611 79.6942L58.0547 75.1877L62.5611 70.6813L67.0675 75.1877ZM76.0811 66.1742L71.5747 70.6806L67.0682 66.1742L71.5747 61.6678L76.0811 66.1742ZM85.0939 57.1614L80.5875 61.6678L76.0811 57.1614L80.5875 52.6549L85.0939 57.1614ZM94.1075 48.1478L89.6011 52.6542L85.0946 48.1478L89.6011 43.6414L94.1075 48.1478ZM103.12 39.135L98.6139 43.6414L94.1075 39.135L98.6139 34.6285L103.12 39.135ZM58.0547 75.1877L53.5483 79.6942L49.0418 75.1877L53.5483 70.6813L58.0547 75.1877ZM67.0682 66.1742L62.5611 70.6813L58.0547 66.1749L62.5618 61.6678L67.0682 66.1742ZM76.0811 57.1614L71.5747 61.6678L67.0682 57.1614L71.5747 52.6549L76.0811 57.1614ZM76.0818 48.1478L80.5882 43.6414L85.0946 48.1478L80.5875 52.6549L76.0811 48.1485L71.5747 52.6549L67.0682 48.1485L71.5754 43.6414L76.0818 48.1478ZM94.1075 39.135L89.6011 43.6414L85.0946 39.135L89.6011 34.6285L94.1075 39.135ZM103.121 30.1214L98.6146 34.6279L94.1082 30.1214L98.6146 25.615L103.121 30.1214ZM49.0418 75.1877L44.5347 79.6949L40.0276 75.1877L44.5347 70.6806L49.0418 75.1877ZM58.0547 66.1749L53.5483 70.6813L49.0418 66.1749L53.5483 61.6685L58.0547 66.1749ZM67.0682 57.1614L62.5618 61.6678L58.0554 57.1614L62.5618 52.6549L67.0682 57.1614ZM85.0946 39.135L80.5882 43.6414L76.0818 39.135L80.5882 34.6285L85.0946 39.135ZM94.1082 30.1214L89.6011 34.6285L85.0946 30.1221L89.6017 25.615L94.1082 30.1214Z\" fill=\"#FFFAEE\"/></g></g></g></g></g></svg>";

  function buildStickerCursor(kind, color) {
    const [hx, hy] = CURSOR_HOT[kind] || [4, 4];
    const fallback = kind === "eraser" ? "cell" : "crosshair";
    let svg;
    if (kind === "eraser") {
      svg = ERASER_CURSOR_SVG;
    } else {
      const fill = (color || "#262523").trim() || "#262523";
      svg = PENCIL_CURSOR_SVG.split("__COLOR__").join(fill);
    }
    return 'url("data:image/svg+xml,' + encodeURIComponent(svg) + '") ' + hx + " " + hy + ", " + fallback;
  }

  function uiStr(key) {
    if (window.pcUI && window.pcUI[key]) return window.pcUI[key];
    const zh = [navigator.language, ...(navigator.languages || [])].some((l) => /^zh\b/i.test(String(l || "")));
    if (key === "eyedropper") return zh ? "取色" : "Eyedropper";
    if (key === "copied") return zh ? "已复制" : "Copied";
    return key;
  }

  // Sized/stroked to match the pencil & eraser sticker cursors.
  // Pencil: 40×40 canvas (32 content + 4px pad), 17.07px fill, 1.2px white ring → 19.23px visual.
  // Glyph scale 0.69 maps the dropper fill long axis 24.77 → 17.09 (same as the pencil).
  // Stroke system: 1px black outline (was 2px) + 1.2px white halo, same drop shadow as pen/eraser.
  // Pre-scale stroke widths: black 1/0.69=1.4493, white halo 3.4/0.69=4.9275.
  // Hotspot at the lower-left shaft tip. Path corner (3.61, 25.69) maps to viewBox (7.4537, 22.6831);
  // 1px rounded black stroke extends 0.5px along outward bisector (-0.8, 0.6) to (7.0537, 22.9831).
  // CSS = viewBox + 4px pad → (11.0537, 26.9831), integer (11, 27). Old hotspot was (3, 26) on 32×32.
  const EYEDROP_CURSOR = 'url("data:image/svg+xml,' + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="-4 -4 40 40" fill="none">' +
    '<defs><filter id="ds" x="-35%" y="-35%" width="170%" height="170%"><feDropShadow dx="0" dy="0.6" stdDeviation="1.1" flood-color="black" flood-opacity="0.28"/></filter></defs>' +
    '<g filter="url(#ds)" transform="translate(4.9606 4.9599) scale(0.69)">' +
    '<path d="M3.61328 25.6859L4.81328 22.2859L18.4133 12.0859L20.8133 15.2859L7.21328 25.4859L3.61328 25.6859Z" fill="none" stroke="white" stroke-width="4.9275" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<path d="M17.0137 11.8859L23.4137 7.08588C25.0137 5.88588 26.4137 6.08588 27.6137 7.68588C28.8137 9.28588 28.6137 10.6859 27.0137 11.8859L20.6137 16.6859L17.0137 11.8859Z" fill="none" stroke="white" stroke-width="4.9275" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<path d="M16.5342 11.2461L21.0942 17.3261" stroke="white" stroke-width="4.9275" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<path d="M3.61328 25.6859L4.81328 22.2859L18.4133 12.0859L20.8133 15.2859L7.21328 25.4859L3.61328 25.6859Z" fill="white" stroke="black" stroke-width="1.4493" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<path d="M7.61328 22.6861L18.8133 14.2861" stroke="white" stroke-width="1" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<path d="M17.0137 11.8859L23.4137 7.08588C25.0137 5.88588 26.4137 6.08588 27.6137 7.68588C28.8137 9.28588 28.6137 10.6859 27.0137 11.8859L20.6137 16.6859L17.0137 11.8859Z" fill="black" stroke="black" stroke-width="1.4493" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<path d="M16.5342 11.2461L21.0942 17.3261" stroke="black" stroke-width="1.4493" stroke-linecap="round" stroke-linejoin="round"/>' +
    '</g></svg>'
  ) + '") 11 27, crosshair';

  const eyedropChip = document.getElementById("eyedrop-chip");
  const eyedropChipMain = document.getElementById("eyedrop-chip-main");
  const eyedropChipSwatch = document.getElementById("eyedrop-chip-swatch");
  const eyedropChipValue = document.getElementById("eyedrop-chip-value");
  const eyedropChipMode = document.getElementById("eyedrop-chip-mode");
  const sampleCanvas = document.createElement("canvas");
  sampleCanvas.width = 3;
  sampleCanvas.height = 3;
  const sampleCtx = sampleCanvas.getContext("2d", { willReadFrequently: true });
  if (sampleCtx) sampleCtx.imageSmoothingEnabled = false;

  let eyedropFormat = "hex"; // "hex" | "rgb"
  let lastSample = null;
  let eyedropCopiedT = 0;
  let chipPinned = false; // true after a confirm, until the pointer samples again

  function toHex(r, g, b) {
    const h = (n) => Math.max(0, Math.min(255, n | 0)).toString(16).toUpperCase().padStart(2, "0");
    return "#" + h(r) + h(g) + h(b);
  }
  function formatSample(s) {
    if (!s) return "";
    if (eyedropFormat === "rgb") return s.r + " " + s.g + " " + s.b;
    return s.hex;
  }
  function copyHexText(hex) {
    if (!hex) return false;
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pc) {
        window.webkit.messageHandlers.pc.postMessage({ type: "copyText", data: hex });
        return true;
      }
    } catch (_) {}
    try {
      const ta = document.createElement("textarea");
      ta.value = hex;
      ta.setAttribute("readonly", "");
      ta.style.cssText = "position:fixed;left:-9999px;top:0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      return !!ok;
    } catch (_) {
      return false;
    }
  }
  function sampleAt(canvasX, canvasY) {
    if (!sampleCtx || !base.width || !base.height) return null;
    const x = Math.round(canvasX);
    const y = Math.round(canvasY);
    if (x < 0 || y < 0 || x >= base.width || y >= base.height) return null;
    const sx = Math.max(0, Math.min(base.width - 3, x - 1));
    const sy = Math.max(0, Math.min(base.height - 3, y - 1));
    try {
      sampleCtx.clearRect(0, 0, 3, 3);
      sampleCtx.drawImage(base, sx, sy, 3, 3, 0, 0, 3, 3);
      sampleCtx.drawImage(canvas, sx, sy, 3, 3, 0, 0, 3, 3);
      const { data } = sampleCtx.getImageData(0, 0, 3, 3);
      let r = 0, g = 0, b = 0, n = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (data[i + 3] === 0) continue;
        r += data[i];
        g += data[i + 1];
        b += data[i + 2];
        n++;
      }
      if (!n) return null;
      r = Math.round(r / n);
      g = Math.round(g / n);
      b = Math.round(b / n);
      return { r, g, b, hex: toHex(r, g, b) };
    } catch (_) {
      return null;
    }
  }
  function pointerOverCanvas(e) {
    const r = canvas.getBoundingClientRect();
    return e.clientX >= r.left && e.clientX < r.right && e.clientY >= r.top && e.clientY < r.bottom;
  }
  function placeEyedropChip(clientX, clientY) {
    if (!eyedropChip) return;
    eyedropChip.hidden = false;
    const gap = 16;
    const w = eyedropChip.offsetWidth || 128;
    const h = eyedropChip.offsetHeight || 40;
    let x = clientX + gap;
    let y = clientY + gap;
    if (x + w > window.innerWidth - 8) x = clientX - w - gap;
    if (y + h > window.innerHeight - 8) y = clientY - h - gap;
    if (x < 8) x = 8;
    if (y < 8) y = 8;
    eyedropChip.style.left = Math.round(x) + "px";
    eyedropChip.style.top = Math.round(y) + "px";
  }
  function paintEyedropChip(sample, copied) {
    if (!eyedropChip || !sample) return;
    eyedropChipSwatch.style.background = sample.hex;
    if (copied) {
      eyedropChip.classList.add("is-copied");
      eyedropChipValue.textContent = uiStr("copied");
    } else {
      eyedropChip.classList.remove("is-copied");
      eyedropChipValue.textContent = formatSample(sample);
    }
    if (eyedropChipMode) eyedropChipMode.textContent = eyedropFormat === "rgb" ? "RGB" : "HEX";
  }
  function hideEyedropChip(clear) {
    if (eyedropChip) eyedropChip.hidden = true;
    eyedropChip && eyedropChip.classList.remove("is-copied");
    if (clear) lastSample = null;
    chipPinned = false;
  }
  function showEyedropCopied(sample) {
    paintEyedropChip(sample, true);
    clearTimeout(eyedropCopiedT);
    eyedropCopiedT = setTimeout(() => {
      if (lastSample) paintEyedropChip(lastSample, false);
    }, 1400);
  }
  function applyEyedropHover(e) {
    if (tool !== "eyedropper") return;
    if (eyedropChip && e.target && eyedropChip.contains(e.target)) return;
    if (!pointerOverCanvas(e)) {
      if (!chipPinned) hideEyedropChip(false);
      return;
    }
    const p = pointerPos(e);
    const sample = sampleAt(p.x, p.y);
    if (!sample) return;
    lastSample = sample;
    chipPinned = false;
    paintEyedropChip(sample, false);
    placeEyedropChip(e.clientX, e.clientY);
  }
  function confirmEyedrop(e) {
    const p = pointerPos(e);
    const sample = sampleAt(p.x, p.y) || lastSample;
    if (!sample) return;
    lastSample = sample;
    chipPinned = true;
    paintEyedropChip(sample, false);
    placeEyedropChip(e.clientX, e.clientY);
    const ok = copyHexText(sample.hex);
    if (ok) {
      showEyedropCopied(sample);
      try { self.PocketclipSfx.playSafe("done"); } catch (_) {}
    } else {
      try { self.PocketclipSfx.playSafe("error"); } catch (_) {}
      toast(uiStr("copied") === "已复制" ? "复制失败" : "Copy failed", "err");
    }
  }
  function copyLastEyedrop() {
    if (!lastSample) return;
    const ok = copyHexText(lastSample.hex);
    if (ok) {
      showEyedropCopied(lastSample);
      try { self.PocketclipSfx.playSafe("done"); } catch (_) {}
    }
  }

  function localizeEyedropperButton() {
    const label = uiStr("eyedropper");
    const btn = document.querySelector('.draw-tool-btn[data-tool="eyedropper"]');
    if (!btn) return;
    btn.setAttribute("data-tooltip", label);
    btn.setAttribute("aria-label", label);
    const tip = btn.querySelector(".ui-tip__text");
    if (tip) tip.textContent = label;
  }
  localizeEyedropperButton();

  if (eyedropChipMain) {
    eyedropChipMain.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });
    eyedropChipMain.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); copyLastEyedrop(); });
  }
  if (eyedropChipMode) {
    eyedropChipMode.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });
    eyedropChipMode.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      eyedropFormat = eyedropFormat === "hex" ? "rgb" : "hex";
      eyedropChipMode.setAttribute("aria-label", eyedropFormat === "rgb" ? "RGB" : "HEX");
      if (lastSample) paintEyedropChip(lastSample, false);
    });
  }

  window.addEventListener("mousemove", applyEyedropHover);

  function syncDrawCursor() {
    if (!canvas) return;
    if (tool === "eraser") {
      canvas.style.cursor = buildStickerCursor("eraser");
    } else if (tool === "pen") {
      canvas.style.cursor = buildStickerCursor("pencil", colorInput && colorInput.value);
    } else if (tool === "eyedropper") {
      canvas.style.cursor = EYEDROP_CURSOR;
    } else {
      canvas.style.cursor = "";
    }
  }

  function setTool(next) {
    if (next === "arrow" || next === "text") next = "pen";
    if (tool === "text" && next !== "text") {
      dismissTextEditor(true);
    }
    tool = next;
    document.querySelectorAll(".draw-tool-btn").forEach((btn) => {
      const on = btn.dataset.tool === tool;
      btn.classList.toggle("active", on);
      const icon = btn.querySelector(".draw-tool-icon");
      if (icon) icon.classList.toggle("draw-tool-icon--selected", on);
    });
    canvas.classList.remove("cursor-pen", "cursor-eraser", "cursor-text", "cursor-arrow");
    if (tool === "text") {
      canvas.classList.add("cursor-text");
      canvas.style.cursor = "";
    } else if (tool === "arrow") {
      canvas.classList.add("cursor-arrow");
      canvas.style.cursor = "";
    } else {
      syncDrawCursor();
    }
    if (tool !== "text") syncTextCursorPill(null, null, false);
    if (tool !== "eyedropper") hideEyedropChip(false);
    // Hover-then-click: the pointer never leaves, so pointerover will not fire again.
    // Jump the tip to the raised (or resting) height immediately instead of waiting out the icon animation.
    document.querySelectorAll(".draw-tool-btn").forEach((btn) => syncToolTip(btn));
  }

  function exportMergedBlob(type) {
    return new Promise((resolve) => {
      const out = document.createElement("canvas");
      out.width = base.width;
      out.height = base.height;
      const octx = out.getContext("2d");
      octx.drawImage(base, 0, 0);
      octx.drawImage(canvas, 0, 0);
      for (const el of floatingTexts) {
        paintLabelOnCtx(octx, el);
      }
      if (type === "dataUrl") {
        resolve(out.toDataURL("image/png"));
        return;
      }
      out.toBlob((blob) => resolve(blob), "image/png");
    });
  }

  canvas.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    if (tool === "eyedropper") {
      e.preventDefault();
      confirmEyedrop(e);
      return;
    }
    const p = pointerPos(e);
    if (tool === "text") {
      e.preventDefault();
      openTextEditor(e, p);
      return;
    }
    bakeFloatingTexts();
    drawing = true;
    start = p;
    pushHistory();
    strokePoints = [{ x: p.x, y: p.y, pressure: e.pressure > 0 ? e.pressure : 0.5 }];
    try {
      strokeBaseline = ctx.getImageData(0, 0, canvas.width, canvas.height);
    } catch (_) {
      strokeBaseline = null;
    }
    redrawCurrentStroke();
  });

  canvas.addEventListener("mousemove", (e) => {
    if (tool !== "text" || textEditorEl) {
      syncTextCursorPill(null, null, false);
      return;
    }
    syncTextCursorPill(e.clientX, e.clientY, true);
  });
  canvas.addEventListener("mouseenter", (e) => {
    if (tool === "text" && !textEditorEl) syncTextCursorPill(e.clientX, e.clientY, true);
  });
  canvas.addEventListener("mouseleave", () => {
    syncTextCursorPill(null, null, false);
  });

  window.addEventListener("mousemove", (e) => {
    if (!drawing || !start) return;
    if (tool !== "pen" && tool !== "eraser" && tool !== "arrow") return;
    const p = pointerPos(e);
    const pr = e.pressure > 0 ? e.pressure : 0.5;
    const last = strokePoints[strokePoints.length - 1];
    if (last) {
      const dx = p.x - last.x;
      const dy = p.y - last.y;
      if (dx * dx + dy * dy < 0.25) return;
    }
    strokePoints.push({ x: p.x, y: p.y, pressure: pr });
    redrawCurrentStroke();
  });

  window.addEventListener("mouseup", () => {
    if (!drawing) return;
    const wasArrow = tool === "arrow";
    drawing = false;
    // Ensure at least a dot when click without move (pen/eraser only)
    if (!wasArrow && strokePoints.length === 1) {
      const p0 = strokePoints[0];
      strokePoints.push({ x: p0.x + 0.1, y: p0.y + 0.1, pressure: p0.pressure });
      redrawCurrentStroke();
    }
    if (wasArrow && strokePoints.length >= 1 && start) {
      const end = strokePoints[strokePoints.length - 1];
      if (Math.hypot(end.x - start.x, end.y - start.y) < 4 && strokeBaseline) {
        // too short — restore, no mark
        ctx.putImageData(strokeBaseline, 0, 0);
      }
    }
    start = null;
    strokePoints = [];
    strokeBaseline = null;
    ctx.globalCompositeOperation = "source-over";
  });

  document.querySelectorAll(".draw-tool-btn[data-tool]").forEach((btn) => {
    btn.addEventListener("click", () => {
      // Click always sounds. P/E go through shortcutSfx and only sound when the tool changes.
      // Pen and eraser have their own sounds; anything else on this row stays on select.
      const sfx = btn.dataset.tool === "pen" ? "pen" : btn.dataset.tool === "eraser" ? "eraser" : "select";
      self.PocketclipSfx.playSafe(sfx);
      setTool(btn.dataset.tool);
    });
  });

  document.querySelectorAll(".draw-color-btn[data-color]").forEach((btn) => {
    btn.addEventListener("click", () => {
      if (btn.id === "btn-custom-color") return;
      // One sound even if this also flips eraser -> pen below.
      self.PocketclipSfx.playSafe("swatch");
      document.querySelectorAll(".draw-color-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      colorInput.value = btn.dataset.color;
      syncPenIconColor(btn.dataset.color);
      if (tool === "eraser") setTool("pen");
      const pop = document.getElementById("color-picker-pop");
      const cbtn = document.getElementById("btn-custom-color");
      if (pop) pop.hidden = true;
      if (cbtn) cbtn.setAttribute("aria-expanded", "false");
    });
  });

  syncPenIconColor(colorInput.value);

  /* --- custom color picker --- */
  const customColorBtn = document.getElementById("btn-custom-color");
  const colorPop = document.getElementById("color-picker-pop");
  const colorWrap = document.getElementById("color-wrap");
  if (!colorPop) console.warn("[screenshot-ext] #color-picker-pop missing at init");
  const cpSv = document.getElementById("cp-sv");
  const cpSvCanvas = document.getElementById("cp-sv-canvas");
  const cpSvKnob = document.getElementById("cp-sv-knob");
  const cpHue = document.getElementById("cp-hue");
  const cpHueCanvas = document.getElementById("cp-hue-canvas");
  const cpHueKnob = document.getElementById("cp-hue-knob");
  const cpPreview = document.getElementById("cp-preview");
  const cpHex = document.getElementById("cp-hex");
  let cpH = 0, cpS = 1, cpV = 1;
  let pickerReady = false;

  function hsvToRgb(h, s, v) {
    const i = Math.floor(h * 6);
    const f = h * 6 - i;
    const p = v * (1 - s);
    const q = v * (1 - f * s);
    const t = v * (1 - (1 - f) * s);
    let r, g, b;
    switch (i % 6) {
      case 0: r = v; g = t; b = p; break;
      case 1: r = q; g = v; b = p; break;
      case 2: r = p; g = v; b = t; break;
      case 3: r = p; g = q; b = v; break;
      case 4: r = t; g = p; b = v; break;
      default: r = v; g = p; b = q;
    }
    return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
  }
  function rgbToHex(r, g, b) {
    return "#" + [r, g, b].map((x) => x.toString(16).padStart(2, "0")).join("").toUpperCase();
  }
  function hexToRgb(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec((hex || "").trim());
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgbToHsv(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const d = max - min;
    let h = 0;
    const s = max === 0 ? 0 : d / max;
    const v = max;
    if (d !== 0) {
      switch (max) {
        case r: h = ((g - b) / d + (g < b ? 6 : 0)); break;
        case g: h = (b - r) / d + 2; break;
        default: h = (r - g) / d + 4;
      }
      h /= 6;
    }
    return [h, s, v];
  }
  function currentHex() {
    const [r, g, b] = hsvToRgb(cpH, cpS, cpV);
    return rgbToHex(r, g, b);
  }
  function sizeCanvas(canvas, cssW, cssH) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
    canvas.style.width = cssW + "px";
    canvas.style.height = cssH + "px";
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return ctx;
  }
  function paintHue() {
    const cssW = 168, cssH = 12;
    const ctx = sizeCanvas(cpHueCanvas, cssW, cssH);
    const g = ctx.createLinearGradient(0, 0, cssW, 0);
    for (let i = 0; i <= 6; i++) {
      const [r, g2, b] = hsvToRgb(i / 6, 1, 1);
      g.addColorStop(i / 6, `rgb(${r},${g2},${b})`);
    }
    ctx.clearRect(0, 0, cssW, cssH);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, cssW, cssH);
  }
  function paintSv() {
    const cssW = 168, cssH = 108;
    const ctx = sizeCanvas(cpSvCanvas, cssW, cssH);
    const [hr, hg, hb] = hsvToRgb(cpH, 1, 1);
    ctx.clearRect(0, 0, cssW, cssH);
    // Base hue fill, then white→transparent left→right, then transparent→black top→bottom
    ctx.fillStyle = `rgb(${hr},${hg},${hb})`;
    ctx.fillRect(0, 0, cssW, cssH);
    const white = ctx.createLinearGradient(0, 0, cssW, 0);
    white.addColorStop(0, "rgba(255,255,255,1)");
    white.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = white;
    ctx.fillRect(0, 0, cssW, cssH);
    const black = ctx.createLinearGradient(0, 0, 0, cssH);
    black.addColorStop(0, "rgba(0,0,0,0)");
    black.addColorStop(1, "rgba(0,0,0,1)");
    ctx.fillStyle = black;
    ctx.fillRect(0, 0, cssW, cssH);
  }
  function syncPickerUi({ updateHex = true } = {}) {
    const hex = currentHex();
    paintSv();
    cpSvKnob.style.left = (cpS * 100) + "%";
    cpSvKnob.style.top = ((1 - cpV) * 100) + "%";
    cpSvKnob.style.background = hex;
    cpHueKnob.style.left = (cpH * 100) + "%";
    cpHueKnob.style.background = rgbToHex(...hsvToRgb(cpH, 1, 1));
    cpPreview.style.background = hex;
    if (updateHex) cpHex.value = hex;
    customColorBtn.style.setProperty("--swatch", hex);
    customColorBtn.dataset.color = hex;
  }
  function applyCustomColor(hex, { close = false } = {}) {
    const rgb = hexToRgb(hex);
    if (!rgb) return;
    const [h, s, v] = rgbToHsv(...rgb);
    cpH = h; cpS = s; cpV = v;
    syncPickerUi();
    document.querySelectorAll(".draw-color-btn").forEach((b) => b.classList.remove("active"));
    customColorBtn.classList.add("active");
    colorInput.value = hex.toUpperCase();
    syncPenIconColor(hex);
    if (tool === "eraser") setTool("pen");
    if (close) closeColorPicker();
  }
  function positionColorPicker() {
    if (!colorPop || !customColorBtn) return;
    const r = customColorBtn.getBoundingClientRect();
    const pad = 8;
    const gap = 8;
    const popW = colorPop.offsetWidth || 120;
    const popH = colorPop.offsetHeight || 110;
    // Anchor near the custom color disc above the dock
    let left = r.left + r.width / 2 - popW / 2;
    left = Math.max(pad, Math.min(left, window.innerWidth - popW - pad));
    let top = r.top - popH - gap;
    if (top < pad) {
      top = Math.min(r.bottom + gap, window.innerHeight - popH - pad);
    }
    if (top + popH > window.innerHeight - pad) {
      top = Math.max(pad, window.innerHeight - popH - pad);
    }
    colorPop.style.left = Math.round(left) + "px";
    colorPop.style.top = Math.round(top) + "px";
  }
  function openColorPicker() {
    const rgb = hexToRgb(colorInput.value) || [38, 37, 35];
    [cpH, cpS, cpV] = rgbToHsv(...rgb);
    if (!pickerReady) {
      paintHue();
      pickerReady = true;
    }
    syncPickerUi();
    colorPop.hidden = false;
    customColorBtn.setAttribute("aria-expanded", "true");
    positionColorPicker();
    requestAnimationFrame(() => {
      positionColorPicker();
      requestAnimationFrame(positionColorPicker);
    });
  }
  function closeColorPicker() {
    colorPop.hidden = true;
    customColorBtn.setAttribute("aria-expanded", "false");
  }
  function bindDrag(el, onMove) {
    const move = (e) => {
      const pt = e.touches ? e.touches[0] : e;
      onMove(pt.clientX, pt.clientY);
      e.preventDefault();
    };
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      window.removeEventListener("touchmove", move);
      window.removeEventListener("touchend", up);
    };
    el.addEventListener("mousedown", (e) => {
      move(e);
      window.addEventListener("mousemove", move);
      window.addEventListener("mouseup", up);
    });
    el.addEventListener("touchstart", (e) => {
      move(e);
      window.addEventListener("touchmove", move, { passive: false });
      window.addEventListener("touchend", up);
    }, { passive: false });
  }
  if (customColorBtn && colorPop) {
    customColorBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      if (colorPop.hidden) {
        // Once on open; never on SV/hue drags or hex edits.
        self.PocketclipSfx.playSafe("swatch");
        openColorPicker();
      } else closeColorPicker();
    });
    bindDrag(cpSv, (cx, cy) => {
      const r = cpSv.getBoundingClientRect();
      cpS = Math.min(1, Math.max(0, (cx - r.left) / r.width));
      cpV = Math.min(1, Math.max(0, 1 - (cy - r.top) / r.height));
      syncPickerUi();
      colorInput.value = currentHex();
      syncPenIconColor(colorInput.value);
      document.querySelectorAll(".draw-color-btn").forEach((b) => b.classList.remove("active"));
      customColorBtn.classList.add("active");
      if (tool === "eraser") setTool("pen");
    });
    bindDrag(cpHue, (cx) => {
      const r = cpHue.getBoundingClientRect();
      cpH = Math.min(1, Math.max(0, (cx - r.left) / r.width));
      syncPickerUi();
      colorInput.value = currentHex();
      syncPenIconColor(colorInput.value);
      document.querySelectorAll(".draw-color-btn").forEach((b) => b.classList.remove("active"));
      customColorBtn.classList.add("active");
      if (tool === "eraser") setTool("pen");
    });
    cpHex.addEventListener("change", () => {
      let v = cpHex.value.trim();
      if (v && v[0] !== "#") v = "#" + v;
      if (hexToRgb(v)) applyCustomColor(v);
      else syncPickerUi();
    });
    cpHex.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        cpHex.dispatchEvent(new Event("change"));
      }
    });
    document.addEventListener("click", (e) => {
      if (colorPop.hidden) return;
      if (e.target.closest("#color-wrap") || e.target.closest("#color-picker-pop")) return;
      closeColorPicker();
    });
    window.addEventListener("resize", () => {
      if (!colorPop.hidden) positionColorPicker();
    });
  }



  document.querySelectorAll(".stroke-size-btn[data-width]").forEach((btn) => {
    btn.addEventListener("click", () => {
      self.PocketclipSfx.playSafe("select");
      document.querySelectorAll(".stroke-size-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      lineWidthInput.value = btn.dataset.width;
    });
  });
  setTool("pen");
  syncHistoryBtns();

  // Sound only when there is a step to take (buttons are disabled otherwise); hotkeys stay silent.
  document.getElementById("btn-undo").addEventListener("click", () => {
    if (undoStack.length) self.PocketclipSfx.playSafe("history");
    undo();
  });
  document.getElementById("btn-redo").addEventListener("click", () => {
    if (redoStack.length) self.PocketclipSfx.playSafe("history");
    redo();
  });

  function clearAnnotations() {
    // Wipe annotation layer only; keep base screenshot.
    dismissTextEditor(false);
    for (const el of floatingTexts.slice()) el.remove();
    floatingTexts.length = 0;
    matchDrawSize();
    ctx.globalCompositeOperation = "source-over";
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    undoStack = [];
    redoStack = [];
    syncHistoryBtns();
  }

  document.getElementById("btn-clear").addEventListener("click", () => {
    if (hasAnnotations()) self.PocketclipSfx.playSafe("clear");
    clearAnnotations();
    toast("Cleared", "ok");
  });


  const ICON_COPY = `<svg class="top-btn__icon top-btn__icon--fill" width="16" height="16" viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M216,34H88a6,6,0,0,0-6,6V82H40a6,6,0,0,0-6,6V216a6,6,0,0,0,6,6H168a6,6,0,0,0,6-6V174h42a6,6,0,0,0,6-6V40A6,6,0,0,0,216,34ZM162,210H46V94H162Zm48-48H174V88a6,6,0,0,0-6-6H94V46H210Z"></path></svg>`;
  const ICON_CHECK = `<svg class="top-btn__icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6L9 17l-5-5"/></svg>`;

  function flashTopBtn(btn, label, kind, { checkIcon = false } = {}) {
    const span = btn.querySelector(".top-btn__label");
    if (!span) return;
    clearTimeout(btn._flashT);
    btn.classList.remove("is-copied", "is-error");
    const prev = span.dataset.defaultLabel || span.textContent;
    span.dataset.defaultLabel = prev;
    span.textContent = label;
    const icon = btn.querySelector(".top-btn__icon");
    if (checkIcon && icon && kind === "ok") {
      if (!btn._defaultIconHtml) btn._defaultIconHtml = icon.outerHTML;
      icon.outerHTML = ICON_CHECK;
    }
    if (kind === "ok") btn.classList.add("is-copied");
    if (kind === "err") btn.classList.add("is-error");
    btn._flashT = setTimeout(() => {
      span.textContent = span.dataset.defaultLabel || prev;
      btn.classList.remove("is-copied", "is-error");
      if (btn._defaultIconHtml) {
        const cur = btn.querySelector(".top-btn__icon");
        if (cur) cur.outerHTML = btn._defaultIconHtml;
      }
    }, 1600);
  }

  document.getElementById("btn-download").addEventListener("click", async () => {
    const a = document.createElement("a");
    const ts = new Date();
    const pad = (n) => String(n).padStart(2, "0");
    const name = `screenshot-${ts.getFullYear()}${pad(ts.getMonth() + 1)}${pad(ts.getDate())}-${pad(ts.getHours())}${pad(ts.getMinutes())}${pad(ts.getSeconds())}.png`;
    a.download = name;
    try {
      a.href = await exportMergedBlob("dataUrl");
    } catch (err) {
      self.PocketclipSfx.playSafe("error");
      throw err;
    }
    a.click();
    // Host shows NSSavePanel and plays the success sound only after a confirmed save.
  });

  document.getElementById("btn-copy").addEventListener("click", async () => {
    const btn = document.getElementById("btn-copy");
    try {
      const blob = await exportMergedBlob("blob");
      if (!blob) throw new Error("Could not create image");
      await navigator.clipboard.write([
        new ClipboardItem({ "image/png": blob }),
      ]);
      flashTopBtn(btn, "Copied", "ok", { checkIcon: true });
      self.PocketclipSfx.playSafe("done");
    } catch (err) {
      self.PocketclipSfx.playSafe("error");
      toast("Copy failed", "err");
      console.warn("Copy failed:", err);
    }
  });

  // Shortcut sounds (1.10.110, pending final call): flip to false to make every shortcut silent again.
  const SFX_ON_SHORTCUTS = true;
  function shortcutSfx(e, name, changed) {
    if (!SFX_ON_SHORTCUTS || e.repeat || !changed) return;
    self.PocketclipSfx.playSafe(name);
  }

  window.addEventListener("keydown", (e) => {
    const tag = (e.target && e.target.tagName) || "";
    const typing = tag === "INPUT" || tag === "TEXTAREA" || (e.target && e.target.isContentEditable);
    if (typing) return;

    const k = e.key.toLowerCase();
    if (!e.ctrlKey && !e.metaKey && !e.altKey) {
      if (k === "p") {
        e.preventDefault();
        shortcutSfx(e, "pen", tool !== "pen");
        setTool("pen");
        return;
      }
      // Arrow / Type tools hidden from dock — hotkeys off
      if (k === "e") {
        e.preventDefault();
        shortcutSfx(e, "eraser", tool !== "eraser");
        setTool("eraser");
        return;
      }
    }

    if (!(e.ctrlKey || e.metaKey)) return;
    if (k === "z" && !e.shiftKey) {
      e.preventDefault();
      shortcutSfx(e, "history", undoStack.length > 0);
      undo();
    } else if (k === "z" && e.shiftKey) {
      e.preventDefault();
      shortcutSfx(e, "history", redoStack.length > 0);
      redo();
    } else if (k === "y") {
      e.preventDefault();
      shortcutSfx(e, "history", redoStack.length > 0);
      redo();
    }
  });

  /* --- hover tips: keep fully inside the viewport --- */
  const TIP_PAD = 6;
  // Pen/eraser only: tip sits --tip-gap above the icon's current top.
  // Settled position, not the in-flight hover animation: unselected hover lifts 2px, selected does not.
  function specifiedBottom(icon) {
    let value = "";
    for (const sheet of document.styleSheets) {
      let rules;
      try { rules = sheet.cssRules; } catch (_) { continue; }
      for (const rule of rules) {
        if (!rule.style || !rule.selectorText || !rule.style.bottom) continue;
        try { if (!icon.matches(rule.selectorText)) continue; } catch (_) { continue; }
        value = rule.style.bottom;
      }
    }
    const n = parseFloat(value);
    return Number.isFinite(n) ? n : (parseFloat(getComputedStyle(icon).bottom) || 0);
  }

  function syncToolTip(host) {
    if (!host.classList.contains("draw-tool-btn")) return;
    const icon = host.querySelector(".draw-tool-icon");
    if (!icon) return;
    // Specified bottom, not the in-flight transition. Otherwise a click reads the old height
    // and the rising icon slides up through the tooltip.
    const bottom = specifiedBottom(icon);
    const hoverLift = host.classList.contains("active") ? 0 : 2;
    // SVG icons (the pen) have no offsetHeight; the border box does not include translateY.
    const iconH = icon.getBoundingClientRect().height;
    const hostH = host.getBoundingClientRect().height;
    const artRise = bottom + iconH - hostH + hoverLift;
    host.style.setProperty("--art-rise", (Math.round(artRise * 100) / 100) + "px");
  }

  function fitTip(host) {
    syncToolTip(host);
    host.style.removeProperty("--tip-dx");
    host.classList.remove("tip-below");
    const tip = host.querySelector(":scope > .ui-tip");
    let w = 0, h = 0;
    if (tip) {
      w = tip.offsetWidth;
      h = tip.offsetHeight;
    } else if (host.hasAttribute("data-tooltip")) {
      const cs = getComputedStyle(host, "::before");
      if (cs.display === "none" || cs.content === "none") return;
      const px = (p) => parseFloat(cs[p]) || 0;
      w = px("width") + px("paddingLeft") + px("paddingRight") + px("borderLeftWidth") + px("borderRightWidth");
      h = px("height") + px("paddingTop") + px("paddingBottom") + px("borderTopWidth") + px("borderBottomWidth");
    }
    if (!w) return;
    const r = host.getBoundingClientRect();
    const cx = r.left + r.width / 2;
    const vw = document.documentElement.clientWidth;
    const vh = document.documentElement.clientHeight;
    let dx = 0;
    if (cx - w / 2 < TIP_PAD) dx = TIP_PAD - (cx - w / 2);
    else if (cx + w / 2 > vw - TIP_PAD) dx = vw - TIP_PAD - (cx + w / 2);
    if (dx) host.style.setProperty("--tip-dx", Math.round(dx) + "px");
    const above = host.dataset.tip !== "bottom";
    const hs = getComputedStyle(host);
    const rise = (parseFloat(hs.getPropertyValue("--art-rise")) || 0) + (parseFloat(hs.getPropertyValue("--tip-gap")) || 4);
    if (above && r.top - rise - h < TIP_PAD && r.bottom + 4 + h <= vh - TIP_PAD) host.classList.add("tip-below");
  }
  const tipHostOf = (t) => (t && t.closest ? t.closest("[data-tooltip], [data-kbd]") : null);
  document.addEventListener("pointerover", (e) => { const h = tipHostOf(e.target); if (h) fitTip(h); });
  document.addEventListener("focusin", (e) => { const h = tipHostOf(e.target); if (h) fitTip(h); });

  const stageWrapEl = document.getElementById("stage-wrap");
  if (stageWrapEl) {
    stageWrapEl.addEventListener(
      "wheel",
      (e) => {
        if (!(e.metaKey || e.ctrlKey)) return;
        e.preventDefault();
        // Smooth exponential zoom; trackpads send small deltas
        const factor = Math.exp(-e.deltaY * 0.0018);
        applyUserZoom(userZoom * factor, e.clientX, e.clientY);
      },
      { passive: false }
    );
  }

  window.addEventListener("resize", () => {
    syncCanvasDisplay();
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", () => {
      syncCanvasDisplay();
      });
  }

  const stageEl = document.getElementById("stage");
  const capturePulse = document.getElementById("capture-pulse");
  let imageBooted = false;

  function setCapturing(on) {
    document.body.classList.toggle("is-capturing", !!on);
    if (capturePulse) capturePulse.hidden = !on;
    if (viewMeta && on) {
      viewMeta.innerHTML = `<span class="meta-size">Capturing…</span>`;
    }
  }

  function revealStage() {
    setCapturing(false);
    if (!stageEl) return;
    stageEl.classList.add("is-ready");
  }

  async function clearStoredShot() {
    try {
      await chrome.storage.local.remove([
        "screenshotDataUrl",
        "screenshotTs",
        "screenshotDpr",
        "screenshotCssWidth",
        "screenshotCssHeight",
        "screenshotError",
        "screenshotErrorTs",
      ]);
    } catch (_) {}
  }

  async function bootFromStorage() {
    if (imageBooted) return true;
    const res = await loadFromStorage();
    await setImage(res.screenshotDataUrl, {
      dpr: res.screenshotDpr || 1,
      cssWidth: res.screenshotCssWidth || 0,
      cssHeight: res.screenshotCssHeight || 0,
    });
    // Only lock after a successful paint — failed setImage must allow retry
    imageBooted = true;
    revealStage();
    await clearStoredShot();
    try {
      const u = new URL(location.href);
      if (u.searchParams.has("capturing")) {
        u.searchParams.delete("capturing");
        history.replaceState({}, "", u.pathname + u.search + u.hash);
      }
    } catch (_) {}
    return true;
  }

  function showBootError(msg) {
    setCapturing(false);
    toast(msg || "Capture failed", "err");
    baseCtx.fillStyle = "#1e293b";
    base.width = 640;
    base.height = 360;
    baseCtx.fillRect(0, 0, base.width, base.height);
    canvas.width = 640;
    canvas.height = 360;
    syncCanvasDisplay(640, 360);
    baseCtx.fillStyle = "#94a3b8";
    baseCtx.font = "16px sans-serif";
    baseCtx.fillText(msg || "No screenshot", 40, 80);
    revealStage();
  }

  const waitCapture = new URLSearchParams(location.search).has("capturing");
  if (waitCapture) {
    setCapturing(true);
    setTimeout(() => {
      if (!imageBooted) {
        // Worker never reported back, so it played nothing; signal failure here.
        self.PocketclipSfx.playSafe("error");
        showBootError("Capture timed out. Close this tab and try again.");
      }
    }, 20000);
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (!msg || typeof msg !== "object") return;
    if (msg.type === "SCREENSHOT_READY") {
      bootFromStorage().catch((e) => showBootError(e.message || String(e)));
    } else if (msg.type === "SCREENSHOT_ERROR") {
      showBootError(msg.error || "Capture failed");
    }
  });


  // Native Mac app: swap screenshot without reloading the page (reused WKWebView).
  window.pcLoadShot = async (url, dpr, cssW, cssH) => {
    try {
      setCapturing(true);
      if (stageEl) stageEl.classList.remove("is-ready");
      imageBooted = false;
      await setImage(url, {
        dpr: dpr || 1,
        cssWidth: cssW || 0,
        cssHeight: cssH || 0,
      });
      imageBooted = true;
      revealStage();
      try {
        window.webkit.messageHandlers.pc.postMessage({ type: "ready", data: "swap" });
      } catch (_) {}
      return true;
    } catch (e) {
      showBootError(e && e.message ? e.message : String(e));
      return false;
    }
  };

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local" || imageBooted) return;
    if (changes.screenshotDataUrl && changes.screenshotDataUrl.newValue) {
      bootFromStorage().catch((e) => showBootError(e.message || String(e)));
    }
    if (changes.screenshotError && changes.screenshotError.newValue && waitCapture) {
      showBootError(changes.screenshotError.newValue);
    }
  });

  (async () => {
    if (waitCapture) {
      // Shell is up; try once in case storage already landed
      try {
        await bootFromStorage();
      } catch (_) {
        // stay in capturing until READY / storage / error
      }
      return;
    }
    try {
      await bootFromStorage();
    } catch (e) {
      showBootError(e.message || String(e));
    }
  })();
})();

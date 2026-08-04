import {
  alphaStats,
  applyAlphaCutout,
  createVerificationReport,
  mapReferenceBox,
  normalizeBox,
  parsePngMetadata,
  verifyCutout,
} from "./core.js";
import { decodePngRgba, encodePngRgba } from "./png-codec.js";

const MAX_PIXELS = 30_000_000;

const elements = Object.fromEntries([
  "overlayInput", "referenceInput", "mappingMode", "mappingHelp",
  "overlayCanvas", "referenceCanvas", "outputCanvas",
  "overlayStage", "referenceStage", "outputStage",
  "overlaySelection", "referenceSelection", "overlayMeta", "referenceMeta",
  "drawOverlayButton", "drawReferenceButton", "referenceHint",
  "boxX", "boxY", "boxWidth", "boxHeight", "dimensionWarning",
  "outputStatus", "verifyButton", "copyReportButton", "downloadButton",
  "reportCanvas", "reportBox", "reportInteriorAlpha", "reportFullAlpha", "reportOutside",
  "reportFormat", "reportResult", "reportJson", "reportSummary",
  "verifyInput", "verifierResult", "installButton", "toast",
].map((id) => [id, document.getElementById(id)]));

const state = {
  overlay: null,
  overlayName: "overlay.png",
  reference: null,
  referenceName: null,
  box: null,
  referenceBox: null,
  mapping: null,
  outputRgba: null,
  lastReport: null,
  lastPngMetadata: null,
  activeTarget: "overlay",
  drag: null,
  installPrompt: null,
};

const overlayContext = elements.overlayCanvas.getContext("2d", { willReadFrequently: true });
const referenceContext = elements.referenceCanvas.getContext("2d", { willReadFrequently: true });
const outputContext = elements.outputCanvas.getContext("2d", { willReadFrequently: true });

function showToast(message) {
  elements.toast.textContent = message;
  elements.toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => elements.toast.classList.remove("show"), 2600);
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function decodeImage(file) {
  if ("createImageBitmap" in window) {
    return createImageBitmap(file);
  }
  const url = URL.createObjectURL(file);
  try {
    return await new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new TypeError("The browser could not decode this image."));
      image.src = url;
    });
  } finally {
    URL.revokeObjectURL(url);
  }
}

function decodedDimensions(image) {
  return {
    width: image.width || image.naturalWidth,
    height: image.height || image.naturalHeight,
  };
}

function assertReasonableDimensions(width, height) {
  if (width < 1 || height < 1) throw new RangeError("Image dimensions are invalid.");
  if (width * height > MAX_PIXELS) {
    throw new RangeError(`Image contains ${(width * height).toLocaleString()} pixels. The browser limit for this tool is ${MAX_PIXELS.toLocaleString()}.`);
  }
}

function drawDecodedImage(image, canvas, context) {
  const { width, height } = decodedDimensions(image);
  assertReasonableDimensions(width, height);
  canvas.width = width;
  canvas.height = height;
  context.clearRect(0, 0, width, height);
  context.drawImage(image, 0, 0, width, height);
  return { width, height };
}

async function loadOverlay(file) {
  if (!file) return;
  try {
    const encoded = await file.arrayBuffer();
    const sourceMetadata = parsePngMetadata(encoded);
    if (sourceMetadata.bit_depth !== 8) {
      throw new TypeError(`This overlay is ${sourceMetadata.bit_depth}-bit. Convert it to an 8-bit PNG so every exported channel can be preserved exactly.`);
    }
    const { width, height, rgba } = decodePngRgba(encoded);
    assertReasonableDimensions(width, height);
    elements.overlayCanvas.width = width;
    elements.overlayCanvas.height = height;
    const imageData = new ImageData(new Uint8ClampedArray(rgba), width, height);
    overlayContext.putImageData(imageData, 0, 0);
    state.overlay = { width, height, imageData, sourceMetadata };
    state.overlayName = file.name || "overlay.png";
    state.box = null;
    state.outputRgba = null;
    state.lastPngMetadata = null;
    elements.overlayStage.classList.remove("empty");
    elements.drawOverlayButton.disabled = false;
    elements.overlayMeta.textContent = `${state.overlayName} · ${width} × ${height} · ${formatBytes(file.size)}`;
    resetCoordinates(width, height);
    if (state.referenceBox) applyReferenceMapping();
    else clearOutput("Draw the transparent rectangle on the overlay or load a reference.");
    setActiveTarget(state.reference ? "reference" : "overlay");
    updateSelectionGeometry();
  } catch (error) {
    elements.overlayInput.value = "";
    elements.overlayMeta.textContent = error.message;
    showToast(error.message);
  }
}

async function loadReference(file) {
  if (!file) return;
  try {
    const image = await decodeImage(file);
    const { width, height } = drawDecodedImage(image, elements.referenceCanvas, referenceContext);
    state.reference = { width, height };
    state.referenceName = file.name || "reference.png";
    state.referenceBox = null;
    elements.referenceStage.classList.remove("empty");
    elements.drawReferenceButton.disabled = false;
    elements.referenceMeta.textContent = `${state.referenceName} · ${width} × ${height} · ${formatBytes(file.size)}`;
    elements.referenceHint.textContent = state.overlay
      ? dimensionMappingMessage()
      : "Draw the box now. It will be mapped after an overlay is loaded.";
    setActiveTarget("reference");
    updateSelectionGeometry();
  } catch (error) {
    elements.referenceInput.value = "";
    elements.referenceMeta.textContent = error.message;
    showToast(error.message);
  }
}

function resetCoordinates(width, height) {
  const suggested = {
    x: Math.round(width * 0.2),
    y: Math.round(height * 0.25),
    width: Math.max(1, Math.round(width * 0.6)),
    height: Math.max(1, Math.round(height * 0.5)),
  };
  elements.boxX.value = suggested.x;
  elements.boxY.value = suggested.y;
  elements.boxWidth.value = suggested.width;
  elements.boxHeight.value = suggested.height;
  elements.dimensionWarning.className = "dimension-warning";
  elements.dimensionWarning.textContent = `Canvas ${width} × ${height}. Draw a rectangle or edit the suggested values to activate the output.`;
}

function setActiveTarget(target) {
  if (target === "reference" && !state.reference) return;
  if (target === "overlay" && !state.overlay) return;
  state.activeTarget = target;
  const overlayActive = target === "overlay";
  elements.drawOverlayButton.classList.toggle("active", overlayActive);
  elements.drawOverlayButton.setAttribute("aria-pressed", String(overlayActive));
  elements.drawReferenceButton.classList.toggle("active", !overlayActive);
  elements.drawReferenceButton.setAttribute("aria-pressed", String(!overlayActive));
}

function boxFromInputs() {
  return {
    x: elements.boxX.value,
    y: elements.boxY.value,
    width: elements.boxWidth.value,
    height: elements.boxHeight.value,
  };
}

function writeBoxInputs(box) {
  elements.boxX.value = box.x;
  elements.boxY.value = box.y;
  elements.boxWidth.value = box.width;
  elements.boxHeight.value = box.height;
}

function applyManualCoordinates() {
  if (!state.overlay) return;
  state.box = normalizeBox(boxFromInputs(), state.overlay.width, state.overlay.height);
  state.mapping = {
    mode: "manual_overlay_coordinates",
    overlay_canvas: { width: state.overlay.width, height: state.overlay.height },
  };
  writeBoxInputs(state.box);
  renderOutput();
}

function dimensionMappingMessage() {
  if (!state.overlay || !state.reference) return "";
  if (state.overlay.width === state.reference.width && state.overlay.height === state.reference.height) {
    return `Dimensions match exactly at ${state.overlay.width} × ${state.overlay.height}.`;
  }
  const scaleX = state.overlay.width / state.reference.width;
  const scaleY = state.overlay.height / state.reference.height;
  return `Reference ${state.reference.width} × ${state.reference.height}; overlay ${state.overlay.width} × ${state.overlay.height}. Scale X ${scaleX.toFixed(6)}, Y ${scaleY.toFixed(6)}.`;
}

function applyReferenceMapping() {
  if (!state.referenceBox || !state.reference || !state.overlay) return;
  const mapped = mapReferenceBox(
    state.referenceBox,
    state.reference.width,
    state.reference.height,
    state.overlay.width,
    state.overlay.height,
    elements.mappingMode.value,
  );
  state.box = mapped.box;
  state.mapping = {
    mode: mapped.mode,
    scale_x: mapped.scale_x,
    scale_y: mapped.scale_y,
    reference_canvas: { width: state.reference.width, height: state.reference.height },
    reference_box: mapped.reference_box,
    overlay_canvas: { width: state.overlay.width, height: state.overlay.height },
    mapped_overlay_box: mapped.box,
  };
  writeBoxInputs(state.box);
  elements.mappingHelp.textContent = dimensionMappingMessage();
  elements.referenceHint.textContent = `${dimensionMappingMessage()} Mapped box: ${state.box.x}, ${state.box.y}, ${state.box.width} × ${state.box.height}.`;
  renderOutput();
}

function pointerPoint(event, canvas) {
  const rect = canvas.getBoundingClientRect();
  const x = Math.round(((event.clientX - rect.left) / rect.width) * canvas.width);
  const y = Math.round(((event.clientY - rect.top) / rect.height) * canvas.height);
  return {
    x: Math.max(0, Math.min(canvas.width, x)),
    y: Math.max(0, Math.min(canvas.height, y)),
  };
}

function dragBox(start, current, width, height) {
  const left = Math.min(start.x, current.x);
  const top = Math.min(start.y, current.y);
  const right = Math.max(start.x, current.x);
  const bottom = Math.max(start.y, current.y);
  return normalizeBox({
    x: left,
    y: top,
    width: Math.max(1, right - left),
    height: Math.max(1, bottom - top),
  }, width, height);
}

function beginDrag(event, target) {
  const source = target === "overlay" ? state.overlay : state.reference;
  if (!source) return;
  event.preventDefault();
  setActiveTarget(target);
  const canvas = target === "overlay" ? elements.overlayCanvas : elements.referenceCanvas;
  try {
    canvas.setPointerCapture?.(event.pointerId);
  } catch {
    // Synthetic accessibility/testing events may not own an active pointer.
  }
  state.drag = { target, start: pointerPoint(event, canvas), pointerId: event.pointerId };
  updateDrag(event);
}

function updateDrag(event) {
  if (!state.drag) return;
  const { target, start } = state.drag;
  const canvas = target === "overlay" ? elements.overlayCanvas : elements.referenceCanvas;
  const source = target === "overlay" ? state.overlay : state.reference;
  const box = dragBox(start, pointerPoint(event, canvas), source.width, source.height);

  if (target === "overlay") {
    state.box = box;
    state.mapping = {
      mode: "drawn_on_overlay",
      overlay_canvas: { width: source.width, height: source.height },
    };
    writeBoxInputs(box);
    renderOutput();
  } else {
    state.referenceBox = box;
    if (state.overlay) applyReferenceMapping();
  }
  updateSelectionGeometry();
}

function endDrag(event) {
  if (!state.drag) return;
  updateDrag(event);
  state.drag = null;
}

function positionSelection(selection, canvas, stage, box) {
  if (!box) {
    selection.hidden = true;
    return;
  }
  const canvasRect = canvas.getBoundingClientRect();
  const stageRect = stage.getBoundingClientRect();
  selection.hidden = false;
  selection.style.left = `${canvasRect.left - stageRect.left + (box.x / canvas.width) * canvasRect.width}px`;
  selection.style.top = `${canvasRect.top - stageRect.top + (box.y / canvas.height) * canvasRect.height}px`;
  selection.style.width = `${(box.width / canvas.width) * canvasRect.width}px`;
  selection.style.height = `${(box.height / canvas.height) * canvasRect.height}px`;
}

function updateSelectionGeometry() {
  positionSelection(elements.overlaySelection, elements.overlayCanvas, elements.overlayStage, state.box);
  positionSelection(elements.referenceSelection, elements.referenceCanvas, elements.referenceStage, state.referenceBox);
}

function clearOutput(message) {
  elements.outputStage.classList.add("empty");
  elements.outputStatus.className = "output-status waiting";
  elements.outputStatus.textContent = "Waiting";
  elements.verifyButton.disabled = true;
  elements.copyReportButton.disabled = true;
  elements.downloadButton.disabled = true;
  elements.dimensionWarning.className = "dimension-warning";
  elements.dimensionWarning.textContent = message;
  elements.reportCanvas.textContent = "—";
  elements.reportBox.textContent = "—";
  elements.reportInteriorAlpha.textContent = "—";
  elements.reportFullAlpha.textContent = "—";
  elements.reportOutside.textContent = "—";
  elements.reportFormat.textContent = "Not encoded";
  elements.reportResult.textContent = "Waiting";
  elements.reportJson.textContent = "{}";
}

function renderOutput() {
  if (!state.overlay || !state.box) {
    clearOutput("Load an overlay and define a rectangle.");
    return;
  }

  const { width, height, imageData } = state.overlay;
  const result = applyAlphaCutout(imageData.data, width, height, state.box);
  state.box = result.box;
  state.outputRgba = result.output;
  state.lastPngMetadata = null;
  elements.outputCanvas.width = width;
  elements.outputCanvas.height = height;
  outputContext.putImageData(new ImageData(result.output, width, height), 0, 0);
  elements.outputStage.classList.remove("empty");

  const pixelVerification = verifyCutout(imageData.data, result.output, width, height, state.box);
  state.lastReport = createVerificationReport(pixelVerification, null, state.mapping);
  updateReport(state.lastReport);
  writeBoxInputs(state.box);
  updateSelectionGeometry();
}

function updateReport(report) {
  const valid = report.valid;
  elements.outputStatus.className = `output-status ${valid ? "valid" : "invalid"}`;
  elements.outputStatus.textContent = valid ? "Pixel valid" : "Invalid";
  elements.reportCanvas.textContent = `${report.canvas.width} × ${report.canvas.height}`;
  elements.reportBox.textContent = `${report.transparent_box.x}, ${report.transparent_box.y} · ${report.transparent_box.width} × ${report.transparent_box.height}`;
  elements.reportInteriorAlpha.textContent = `${report.interior.alpha_minimum}–${report.interior.alpha_maximum} · ${report.interior.every_pixel_alpha_zero ? "all zero" : "failed"}`;
  elements.reportFullAlpha.textContent = `${report.full_image_alpha.minimum}–${report.full_image_alpha.maximum}`;
  elements.reportOutside.textContent = `${report.preservation.changed_outside_pixel_count} changed`;
  elements.reportFormat.textContent = report.format.encoded_png
    ? `${report.format.encoded_png.color_type_name} · ${report.format.encoded_png.bit_depth}-bit`
    : "RGBA buffer · encode pending";
  elements.reportResult.textContent = report.export_verified ? "Verified" : (valid ? "Pixel-valid" : "Failed");
  elements.reportResult.style.color = valid ? "var(--green)" : "var(--danger)";
  elements.reportJson.textContent = JSON.stringify(report, null, 2);
  elements.verifyButton.disabled = !valid;
  elements.copyReportButton.disabled = !valid;
  elements.downloadButton.disabled = !valid;
  elements.dimensionWarning.className = `dimension-warning ${valid ? "ok" : "error"}`;
  elements.dimensionWarning.textContent = valid
    ? `Ready: ${report.interior.pixel_count.toLocaleString()} interior pixels have alpha 0; every pixel outside the rectangle is unchanged.`
    : "Validation failed. The tool will not export this result.";
}

async function verifyEncodedOutput() {
  if (!state.overlay || !state.outputRgba || !state.lastReport?.valid) {
    throw new Error("There is no pixel-valid output to encode.");
  }
  const encoded = encodePngRgba(state.outputRgba, state.overlay.width, state.overlay.height);
  const metadata = parsePngMetadata(encoded);
  const blob = new Blob([encoded], { type: "image/png" });
  const pixelVerification = verifyCutout(
    state.overlay.imageData.data,
    state.outputRgba,
    state.overlay.width,
    state.overlay.height,
    state.box,
  );
  state.lastPngMetadata = metadata;
  state.lastReport = createVerificationReport(pixelVerification, metadata, state.mapping);
  updateReport(state.lastReport);
  if (!state.lastReport.export_verified) {
    throw new Error("Encoded PNG verification failed. No file was downloaded.");
  }
  return blob;
}

function outputFilename() {
  const base = state.overlayName.replace(/\.[^.]+$/, "").replace(/[^a-z0-9_-]+/gi, "-").replace(/^-+|-+$/g, "") || "overlay";
  return `${base}-transparent.png`;
}

async function verifyButtonAction() {
  try {
    await verifyEncodedOutput();
    showToast("Encoded PNG verified as truecolor RGBA.");
  } catch (error) {
    showToast(error.message);
  }
}

async function downloadOutput() {
  try {
    const blob = await verifyEncodedOutput();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = outputFilename();
    document.body.append(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1500);
    showToast("Verified RGBA PNG downloaded.");
  } catch (error) {
    showToast(error.message);
  }
}

async function copyReport() {
  if (!state.lastReport) return;
  try {
    await navigator.clipboard.writeText(JSON.stringify(state.lastReport, null, 2));
    showToast("Verification report copied.");
  } catch {
    const area = document.createElement("textarea");
    area.value = JSON.stringify(state.lastReport, null, 2);
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
    showToast("Verification report copied.");
  }
}

async function inspectPng(file) {
  if (!file) return;
  try {
    const encoded = await file.arrayBuffer();
    const metadata = parsePngMetadata(encoded);
    const { width, height, rgba } = decodePngRgba(encoded);
    assertReasonableDimensions(width, height);
    const stats = alphaStats(rgba, width, height);
    const rgbaLabel = metadata.is_rgba ? "PASS · RGBA" : `CHECK · ${metadata.color_type_name}`;
    elements.verifierResult.innerHTML = `
      <span class="card-kicker">Inspection result</span>
      <h3>${escapeHtml(file.name)}</h3>
      <dl>
        <div><dt>Canvas</dt><dd>${width} × ${height}</dd></div>
        <div><dt>PNG encoding</dt><dd>${rgbaLabel}</dd></div>
        <div><dt>Bit depth</dt><dd>${metadata.bit_depth}</dd></div>
        <div><dt>Alpha minimum</dt><dd>${stats.minimum}</dd></div>
        <div><dt>Alpha maximum</dt><dd>${stats.maximum}</dd></div>
        <div><dt>Alpha-zero pixels</dt><dd>${stats.transparent_pixel_count.toLocaleString()}</dd></div>
      </dl>`;
  } catch (error) {
    elements.verifyInput.value = "";
    elements.verifierResult.innerHTML = `<span class="card-kicker">Inspection failed</span><p>${escapeHtml(error.message)}</p>`;
  }
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[character]);
}

function wirePointerSelection(canvas, target) {
  canvas.addEventListener("pointerdown", (event) => beginDrag(event, target));
  canvas.addEventListener("pointermove", (event) => {
    if (state.drag?.target === target) updateDrag(event);
  });
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", () => { state.drag = null; });
}

function wireFileDrop(label, input) {
  for (const type of ["dragenter", "dragover"]) {
    label.addEventListener(type, (event) => {
      event.preventDefault();
      label.classList.add("dragging");
    });
  }
  for (const type of ["dragleave", "drop"]) {
    label.addEventListener(type, (event) => {
      event.preventDefault();
      label.classList.remove("dragging");
    });
  }
  label.addEventListener("drop", (event) => {
    const file = event.dataTransfer?.files?.[0];
    if (!file) return;
    const transfer = new DataTransfer();
    transfer.items.add(file);
    input.files = transfer.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

elements.overlayInput.addEventListener("change", () => loadOverlay(elements.overlayInput.files?.[0]));
elements.referenceInput.addEventListener("change", () => loadReference(elements.referenceInput.files?.[0]));
elements.verifyInput.addEventListener("change", () => inspectPng(elements.verifyInput.files?.[0]));
elements.mappingMode.addEventListener("change", applyReferenceMapping);
elements.drawOverlayButton.addEventListener("click", () => setActiveTarget("overlay"));
elements.drawReferenceButton.addEventListener("click", () => setActiveTarget("reference"));
elements.verifyButton.addEventListener("click", verifyButtonAction);
elements.copyReportButton.addEventListener("click", copyReport);
elements.downloadButton.addEventListener("click", downloadOutput);

for (const input of [elements.boxX, elements.boxY, elements.boxWidth, elements.boxHeight]) {
  input.addEventListener("input", applyManualCoordinates);
  input.addEventListener("change", applyManualCoordinates);
}

wirePointerSelection(elements.overlayCanvas, "overlay");
wirePointerSelection(elements.referenceCanvas, "reference");
wireFileDrop(elements.overlayInput.closest(".file-drop"), elements.overlayInput);
wireFileDrop(elements.referenceInput.closest(".file-drop"), elements.referenceInput);
wireFileDrop(elements.verifyInput.closest(".file-drop"), elements.verifyInput);
window.addEventListener("resize", updateSelectionGeometry);

window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  state.installPrompt = event;
  elements.installButton.hidden = false;
});

elements.installButton.addEventListener("click", async () => {
  if (!state.installPrompt) return;
  state.installPrompt.prompt();
  await state.installPrompt.userChoice;
  state.installPrompt = null;
  elements.installButton.hidden = true;
});

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => navigator.serviceWorker.register("./sw.js").catch(() => {}));
}

elements.drawOverlayButton.disabled = true;
clearOutput("Load an overlay to set the rectangle.");

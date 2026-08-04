import { readFile, stat } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const requiredFiles = [
  "tools/index.html",
  "tools/shared.css",
  "tools/tiktok-background-editor/index.html",
  "tools/tiktok-background-editor/editor.css",
  "tools/tiktok-background-editor/core.js",
  "tools/tiktok-background-editor/app.js",
  "tools/tiktok-background-editor/png-codec.js",
  "tools/tiktok-background-editor/manifest.webmanifest",
  "tools/tiktok-background-editor/sw.js",
  "tools/tiktok-background-editor/vendor/pako.min.js",
  "tools/tiktok-background-editor/vendor/upng.js",
  "tools/tiktok-background-editor/app-icon-192.png",
  "tools/tiktok-background-editor/app-icon-512.png",
];

const checks = [];
for (const path of requiredFiles) {
  const info = await stat(resolve(root, path));
  checks.push({ check: `file:${path}`, pass: info.isFile() && info.size > 0, bytes: info.size });
}

const html = await readFile(resolve(root, "tools/tiktok-background-editor/index.html"), "utf8");
const app = await readFile(resolve(root, "tools/tiktok-background-editor/app.js"), "utf8");
const core = await readFile(resolve(root, "tools/tiktok-background-editor/core.js"), "utf8");
const manifest = JSON.parse(await readFile(resolve(root, "tools/tiktok-background-editor/manifest.webmanifest"), "utf8"));

const requiredIds = [
  "overlayInput", "referenceInput", "mappingMode", "overlayCanvas", "referenceCanvas",
  "outputCanvas", "boxX", "boxY", "boxWidth", "boxHeight", "verifyButton",
  "downloadButton", "reportJson", "verifyInput",
];
for (const id of requiredIds) {
  checks.push({ check: `dom-id:${id}`, pass: html.includes(`id=\"${id}\"`) });
}

for (const symbol of ["applyAlphaCutout", "verifyCutout", "parsePngMetadata", "mapReferenceBox"]) {
  checks.push({ check: `core-export:${symbol}`, pass: core.includes(`export function ${symbol}`) });
  checks.push({ check: `app-use:${symbol}`, pass: app.includes(symbol) });
}

checks.push({ check: "no-image-model", pass: !/openai|grok|imagegen|stability\.ai/i.test(app + core) });
checks.push({ check: "no-network-upload", pass: !/fetch\(|XMLHttpRequest|WebSocket/i.test(app + core) });
checks.push({ check: "pwa-start-url", pass: manifest.start_url === "./" });

const failed = checks.filter((check) => !check.pass);
console.log(JSON.stringify({ pass: failed.length === 0, checks, failed }, null, 2));
if (failed.length) process.exitCode = 1;

import { createRequire } from "node:module";
import { access, mkdir, readFile } from "node:fs/promises";
import assert from "node:assert/strict";
import { resolve } from "node:path";

const moduleRoot = process.env.TEST_MODULE_ROOT;
const baseUrl = process.env.TEST_BASE_URL;
const overlayFixture = process.env.TEST_OVERLAY_FIXTURE;
const referenceFixture = process.env.TEST_REFERENCE_FIXTURE;
const downloadDirectory = process.env.TEST_DOWNLOAD_DIR;

for (const [name, value] of Object.entries({ moduleRoot, baseUrl, overlayFixture, referenceFixture, downloadDirectory })) {
  if (!value) throw new Error(`Missing required environment variable for browser test: ${name}`);
}

const require = createRequire(resolve(moduleRoot, "package.json"));
const puppeteer = require("puppeteer-core");
const chromium = require("@sparticuz/chromium").default;
const UPNG = require("upng-js");
chromium.setGraphicsMode = false;
await mkdir(downloadDirectory, { recursive: true });

const browser = await puppeteer.launch({
  args: chromium.args,
  defaultViewport: { width: 1500, height: 1100, deviceScaleFactor: 1 },
  executablePath: await chromium.executablePath(),
  headless: "shell",
});

const page = await browser.newPage();
await new Promise((resolveWait) => setTimeout(resolveWait, 250));
const browserErrors = [];
page.on("pageerror", (error) => browserErrors.push(error.message));

try {
  const response = await page.goto(`${baseUrl}/tools/tiktok-background-editor/`, { waitUntil: "networkidle0" });
  assert.equal(response.status(), 200);
  assert.match(await page.title(), /CodeFEDDY TikTok Background Editor/);
  await page.evaluate(async () => {
    const registrations = await navigator.serviceWorker?.getRegistrations?.() || [];
    await Promise.all(registrations.map((registration) => registration.unregister()));
    const keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
  });
  await page.reload({ waitUntil: "networkidle0" });

  const client = await page.createCDPSession();
  await client.send("Page.setDownloadBehavior", { behavior: "allow", downloadPath: downloadDirectory });

  const overlayInput = await page.$("#overlayInput");
  await overlayInput.uploadFile(overlayFixture);
  await page.waitForFunction(() => document.querySelector("#overlayMeta").textContent.includes("108 × 192"));

  const referenceInput = await page.$("#referenceInput");
  await referenceInput.uploadFile(referenceFixture);
  await page.waitForFunction(() => document.querySelector("#referenceMeta").textContent.includes("216 × 384"));

  await page.$eval("#referenceCanvas", (canvas) => {
    canvas.scrollIntoView({ block: "center" });
    const rect = canvas.getBoundingClientRect();
    const point = (x, y) => ({
      clientX: rect.left + (x / canvas.width) * rect.width,
      clientY: rect.top + (y / canvas.height) * rect.height,
    });
    const dispatch = (type, x, y) => canvas.dispatchEvent(new PointerEvent(type, {
      ...point(x, y),
      bubbles: true,
      cancelable: true,
      pointerId: 41,
      pointerType: "mouse",
      isPrimary: true,
    }));
    dispatch("pointerdown", 40, 80);
    dispatch("pointermove", 140, 240);
    dispatch("pointerup", 140, 240);
  });

  await new Promise((resolveWait) => setTimeout(resolveWait, 250));
  const dragState = await page.evaluate(() => ({
    result: document.querySelector("#reportResult").textContent,
    x: document.querySelector("#boxX").value,
    y: document.querySelector("#boxY").value,
    width: document.querySelector("#boxWidth").value,
    height: document.querySelector("#boxHeight").value,
    report: document.querySelector("#reportJson").textContent,
  }));
  if (dragState.result !== "Pixel-valid") console.error(JSON.stringify({ dragState, browserErrors }, null, 2));
  await page.waitForFunction(() => document.querySelector("#reportResult").textContent === "Pixel-valid");
  const coordinates = await page.evaluate(() => ({
    x: Number(document.querySelector("#boxX").value),
    y: Number(document.querySelector("#boxY").value),
    width: Number(document.querySelector("#boxWidth").value),
    height: Number(document.querySelector("#boxHeight").value),
  }));
  assert.deepEqual(coordinates, { x: 20, y: 40, width: 50, height: 80 });

  const pixelReport = JSON.parse(await page.$eval("#reportJson", (node) => node.textContent));
  assert.equal(pixelReport.interior.alpha_minimum, 0);
  assert.equal(pixelReport.interior.alpha_maximum, 0);
  assert.equal(pixelReport.interior.every_pixel_alpha_zero, true);
  assert.equal(pixelReport.preservation.changed_outside_pixel_count, 0);
  assert.equal(pixelReport.preservation.changed_rgb_pixel_count, 0);

  await page.click("#verifyButton");
  await page.waitForFunction(() => document.querySelector("#reportResult").textContent === "Verified");
  const encodedReport = JSON.parse(await page.$eval("#reportJson", (node) => node.textContent));
  assert.equal(encodedReport.format.encoded_png.color_type, 6);
  assert.equal(encodedReport.format.encoded_png.is_rgba, true);
  assert.equal(encodedReport.export_verified, true);

  await page.screenshot({ path: resolve(downloadDirectory, "editor-tested.png"), fullPage: true });
  await page.click("#downloadButton");
  const exportedPath = resolve(downloadDirectory, "overlay-fixture-transparent.png");
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await access(exportedPath);
      break;
    } catch {
      if (attempt === 99) throw new Error("Verified PNG did not download.");
      await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    }
  }

  const decode = async (path) => {
    const file = await readFile(path);
    const png = UPNG.decode(file.buffer.slice(file.byteOffset, file.byteOffset + file.byteLength));
    return { width: png.width, height: png.height, rgba: new Uint8Array(UPNG.toRGBA8(png)[0]) };
  };
  const original = await decode(overlayFixture);
  const exported = await decode(exportedPath);
  assert.deepEqual([exported.width, exported.height], [original.width, original.height]);
  let outsideChangedPixels = 0;
  let rgbChangedPixels = 0;
  for (let y = 0; y < original.height; y += 1) {
    for (let x = 0; x < original.width; x += 1) {
      const index = (y * original.width + x) * 4;
      const inside = x >= 20 && x < 70 && y >= 40 && y < 120;
      const rgbChanged = original.rgba[index] !== exported.rgba[index]
        || original.rgba[index + 1] !== exported.rgba[index + 1]
        || original.rgba[index + 2] !== exported.rgba[index + 2];
      const alphaChanged = original.rgba[index + 3] !== exported.rgba[index + 3];
      if (rgbChanged) rgbChangedPixels += 1;
      if (!inside && (rgbChanged || alphaChanged)) outsideChangedPixels += 1;
      if (inside) assert.equal(exported.rgba[index + 3], 0);
    }
  }
  assert.equal(outsideChangedPixels, 0);
  assert.equal(rgbChangedPixels, 0);

  const verifierInput = await page.$("#verifyInput");
  await verifierInput.uploadFile(exportedPath);
  await page.waitForFunction(() => document.querySelector("#verifierResult").textContent.includes("PASS · RGBA"));
  assert.deepEqual(browserErrors, []);

  const toolsResponse = await page.goto(`${baseUrl}/tools/`, { waitUntil: "networkidle0" });
  assert.equal(toolsResponse.status(), 200);
  assert.match(await page.title(), /CodeFEDDY Tools/);
  assert.equal(await page.$eval('a[href="tiktok-background-editor/"]', (node) => node.textContent.trim()), "Open TikTok Background Editor");

  const homeResponse = await page.goto(`${baseUrl}/`, { waitUntil: "domcontentloaded" });
  assert.equal(homeResponse.status(), 200);
  assert.equal(await page.$eval('nav a[href="tools/"]', (node) => node.textContent.trim()), "Tools");

  console.log(JSON.stringify({
    pass: true,
    coordinates,
    png_color_type: encodedReport.format.encoded_png.color_type,
    interior_alpha: [encodedReport.interior.alpha_minimum, encodedReport.interior.alpha_maximum],
    changed_outside_pixels: outsideChangedPixels,
    changed_rgb_pixels: rgbChangedPixels,
    screenshot: resolve(downloadDirectory, "editor-tested.png"),
    exported_png: exportedPath,
  }, null, 2));
} finally {
  await browser.close();
}

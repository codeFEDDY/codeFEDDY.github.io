import test from "node:test";
import assert from "node:assert/strict";

import {
  applyAlphaCutout,
  createVerificationReport,
  mapReferenceBox,
  normalizeBox,
  parsePngMetadata,
  verifyCutout,
} from "../tools/tiktok-background-editor/core.js";

function patternedRgba(width, height) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let pixel = 0; pixel < width * height; pixel += 1) {
    const index = pixel * 4;
    data[index] = (pixel * 31) % 256;
    data[index + 1] = (pixel * 47) % 256;
    data[index + 2] = (pixel * 59) % 256;
    data[index + 3] = pixel % 3 === 0 ? 180 : 255;
  }
  return data;
}

test("normalizes integer box coordinates using exclusive right and bottom edges", () => {
  assert.deepEqual(normalizeBox({ x: 2.9, y: 1.8, width: 99, height: 99 }, 5, 4), {
    x: 2,
    y: 1,
    width: 3,
    height: 3,
    right: 5,
    bottom: 4,
    coordinate_semantics: "right_and_bottom_exclusive",
  });
});

test("maps reference geometry proportionally with separately reported axes", () => {
  const mapped = mapReferenceBox(
    { x: 100, y: 200, width: 400, height: 600 },
    1000,
    2000,
    500,
    1000,
    "scale",
  );
  assert.equal(mapped.mode, "proportional_scale");
  assert.equal(mapped.scale_x, 0.5);
  assert.equal(mapped.scale_y, 0.5);
  assert.deepEqual(mapped.box, {
    x: 50,
    y: 100,
    width: 200,
    height: 300,
    right: 250,
    bottom: 400,
    coordinate_semantics: "right_and_bottom_exclusive",
  });
});

test("exact mapping preserves coordinates and clamps only at overlay edges", () => {
  const mapped = mapReferenceBox(
    { x: 80, y: 70, width: 40, height: 50 },
    200,
    200,
    100,
    90,
    "exact",
  );
  assert.equal(mapped.mode, "exact_pixels");
  assert.equal(mapped.box.x, 80);
  assert.equal(mapped.box.y, 70);
  assert.equal(mapped.box.width, 20);
  assert.equal(mapped.box.height, 20);
});

test("cutout changes only interior alpha bytes", () => {
  const width = 6;
  const height = 5;
  const source = patternedRgba(width, height);
  const box = { x: 1, y: 1, width: 3, height: 2 };
  const { output } = applyAlphaCutout(source, width, height, box);
  const report = verifyCutout(source, output, width, height, box);

  assert.equal(report.interior.pixel_count, 6);
  assert.equal(report.interior.transparent_pixel_count, 6);
  assert.equal(report.interior.alpha_minimum, 0);
  assert.equal(report.interior.alpha_maximum, 0);
  assert.equal(report.interior.every_pixel_alpha_zero, true);
  assert.equal(report.preservation.changed_outside_pixel_count, 0);
  assert.equal(report.preservation.changed_rgb_pixel_count, 0);
  assert.equal(report.preservation.every_outside_pixel_preserved, true);
  assert.equal(report.valid, true);
});

test("verification detects even one altered outside pixel", () => {
  const width = 4;
  const height = 4;
  const source = patternedRgba(width, height);
  const box = { x: 1, y: 1, width: 2, height: 2 };
  const { output } = applyAlphaCutout(source, width, height, box);
  output[0] ^= 1;
  const report = verifyCutout(source, output, width, height, box);

  assert.equal(report.preservation.changed_outside_pixel_count, 1);
  assert.equal(report.preservation.changed_rgb_pixel_count, 1);
  assert.equal(report.valid, false);
});

test("reads actual PNG IHDR RGBA metadata", () => {
  const header = new Uint8Array(33);
  header.set([137, 80, 78, 71, 13, 10, 26, 10], 0);
  header.set([0, 0, 0, 13], 8);
  header.set([73, 72, 68, 82], 12);
  new DataView(header.buffer).setUint32(16, 1080, false);
  new DataView(header.buffer).setUint32(20, 1920, false);
  header[24] = 8;
  header[25] = 6;

  assert.deepEqual(parsePngMetadata(header), {
    width: 1080,
    height: 1920,
    bit_depth: 8,
    color_type: 6,
    color_type_name: "truecolor_rgba",
    has_explicit_alpha_channel: true,
    is_rgba: true,
  });
});

test("final report refuses a non-RGBA encoded PNG", () => {
  const source = patternedRgba(2, 2);
  const { output, box } = applyAlphaCutout(source, 2, 2, { x: 0, y: 0, width: 1, height: 1 });
  const pixels = verifyCutout(source, output, 2, 2, box);
  const report = createVerificationReport(pixels, {
    width: 2,
    height: 2,
    bit_depth: 8,
    color_type: 2,
    color_type_name: "truecolor_rgb",
    has_explicit_alpha_channel: false,
    is_rgba: false,
  });
  assert.equal(report.export_verified, false);
});

test("pixel-valid output is not called export-verified before PNG encoding", () => {
  const source = patternedRgba(2, 2);
  const { output, box } = applyAlphaCutout(source, 2, 2, { x: 0, y: 0, width: 1, height: 1 });
  const pixels = verifyCutout(source, output, 2, 2, box);
  const report = createVerificationReport(pixels);
  assert.equal(report.pixel_buffer_verified, true);
  assert.equal(report.export_verified, false);
});

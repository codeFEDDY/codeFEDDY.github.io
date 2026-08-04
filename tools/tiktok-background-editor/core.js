export const PRODUCT_VERSION = "1.0.0";
export const DEPENDENCY_CLASS = "SELF_CONTAINED";

function integer(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : fallback;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

export function normalizeBox(box, canvasWidth, canvasHeight) {
  const width = integer(canvasWidth);
  const height = integer(canvasHeight);
  if (width < 1 || height < 1) {
    throw new RangeError("Canvas dimensions must be positive integers.");
  }

  const x = clamp(integer(box?.x), 0, width - 1);
  const y = clamp(integer(box?.y), 0, height - 1);
  const requestedWidth = Math.max(1, integer(box?.width, 1));
  const requestedHeight = Math.max(1, integer(box?.height, 1));
  const right = clamp(x + requestedWidth, x + 1, width);
  const bottom = clamp(y + requestedHeight, y + 1, height);

  return {
    x,
    y,
    width: right - x,
    height: bottom - y,
    right,
    bottom,
    coordinate_semantics: "right_and_bottom_exclusive",
  };
}

export function mapReferenceBox(referenceBox, referenceWidth, referenceHeight, overlayWidth, overlayHeight, mode = "scale") {
  const refWidth = integer(referenceWidth);
  const refHeight = integer(referenceHeight);
  const outWidth = integer(overlayWidth);
  const outHeight = integer(overlayHeight);
  if (refWidth < 1 || refHeight < 1 || outWidth < 1 || outHeight < 1) {
    throw new RangeError("Reference and overlay dimensions must be positive integers.");
  }

  const source = normalizeBox(referenceBox, refWidth, refHeight);
  if (mode === "exact") {
    return {
      box: normalizeBox(source, outWidth, outHeight),
      mode: "exact_pixels",
      scale_x: 1,
      scale_y: 1,
      reference_box: source,
    };
  }

  const scaleX = outWidth / refWidth;
  const scaleY = outHeight / refHeight;
  const left = Math.round(source.x * scaleX);
  const top = Math.round(source.y * scaleY);
  const right = Math.round(source.right * scaleX);
  const bottom = Math.round(source.bottom * scaleY);

  return {
    box: normalizeBox({ x: left, y: top, width: right - left, height: bottom - top }, outWidth, outHeight),
    mode: "proportional_scale",
    scale_x: scaleX,
    scale_y: scaleY,
    reference_box: source,
  };
}

function assertRgbaBuffer(buffer, width, height, name) {
  if (!(buffer instanceof Uint8ClampedArray) && !(buffer instanceof Uint8Array)) {
    throw new TypeError(`${name} must be a Uint8ClampedArray or Uint8Array.`);
  }
  const expected = width * height * 4;
  if (buffer.length !== expected) {
    throw new RangeError(`${name} contains ${buffer.length} bytes; expected ${expected}.`);
  }
}

export function applyAlphaCutout(sourceRgba, canvasWidth, canvasHeight, requestedBox) {
  const width = integer(canvasWidth);
  const height = integer(canvasHeight);
  assertRgbaBuffer(sourceRgba, width, height, "Source RGBA buffer");
  const box = normalizeBox(requestedBox, width, height);
  const output = new Uint8ClampedArray(sourceRgba);

  for (let y = box.y; y < box.bottom; y += 1) {
    let alphaIndex = ((y * width + box.x) * 4) + 3;
    for (let x = box.x; x < box.right; x += 1) {
      output[alphaIndex] = 0;
      alphaIndex += 4;
    }
  }

  return { output, box };
}

export function alphaStats(rgba, canvasWidth, canvasHeight) {
  const width = integer(canvasWidth);
  const height = integer(canvasHeight);
  assertRgbaBuffer(rgba, width, height, "RGBA buffer");
  let minimum = 255;
  let maximum = 0;
  let transparent = 0;
  let translucent = 0;
  let opaque = 0;

  for (let index = 3; index < rgba.length; index += 4) {
    const alpha = rgba[index];
    if (alpha < minimum) minimum = alpha;
    if (alpha > maximum) maximum = alpha;
    if (alpha === 0) transparent += 1;
    else if (alpha === 255) opaque += 1;
    else translucent += 1;
  }

  return {
    minimum,
    maximum,
    transparent_pixel_count: transparent,
    translucent_pixel_count: translucent,
    opaque_pixel_count: opaque,
    total_pixel_count: width * height,
  };
}

export function verifyCutout(sourceRgba, outputRgba, canvasWidth, canvasHeight, requestedBox) {
  const width = integer(canvasWidth);
  const height = integer(canvasHeight);
  assertRgbaBuffer(sourceRgba, width, height, "Source RGBA buffer");
  assertRgbaBuffer(outputRgba, width, height, "Output RGBA buffer");
  const box = normalizeBox(requestedBox, width, height);

  let interiorAlphaMinimum = 255;
  let interiorAlphaMaximum = 0;
  let interiorTransparentPixels = 0;
  let outsideChangedPixels = 0;
  let rgbChangedPixels = 0;
  let alphaChangedOutsidePixels = 0;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index = (y * width + x) * 4;
      const inside = x >= box.x && x < box.right && y >= box.y && y < box.bottom;
      const rgbChanged = sourceRgba[index] !== outputRgba[index]
        || sourceRgba[index + 1] !== outputRgba[index + 1]
        || sourceRgba[index + 2] !== outputRgba[index + 2];
      const alphaChanged = sourceRgba[index + 3] !== outputRgba[index + 3];

      if (rgbChanged) rgbChangedPixels += 1;
      if (inside) {
        const alpha = outputRgba[index + 3];
        if (alpha < interiorAlphaMinimum) interiorAlphaMinimum = alpha;
        if (alpha > interiorAlphaMaximum) interiorAlphaMaximum = alpha;
        if (alpha === 0) interiorTransparentPixels += 1;
      } else if (rgbChanged || alphaChanged) {
        outsideChangedPixels += 1;
        if (alphaChanged) alphaChangedOutsidePixels += 1;
      }
    }
  }

  const interiorPixelCount = box.width * box.height;
  const fullAlpha = alphaStats(outputRgba, width, height);
  const everyInteriorPixelAlphaZero = interiorPixelCount > 0
    && interiorTransparentPixels === interiorPixelCount
    && interiorAlphaMinimum === 0
    && interiorAlphaMaximum === 0;
  const everyOutsidePixelPreserved = outsideChangedPixels === 0;
  const everyRgbChannelPreserved = rgbChangedPixels === 0;

  return {
    canvas: { width, height },
    transparent_box: box,
    interior: {
      pixel_count: interiorPixelCount,
      transparent_pixel_count: interiorTransparentPixels,
      alpha_minimum: interiorAlphaMinimum,
      alpha_maximum: interiorAlphaMaximum,
      every_pixel_alpha_zero: everyInteriorPixelAlphaZero,
    },
    full_image_alpha: fullAlpha,
    preservation: {
      changed_outside_pixel_count: outsideChangedPixels,
      changed_outside_alpha_pixel_count: alphaChangedOutsidePixels,
      changed_rgb_pixel_count: rgbChangedPixels,
      every_outside_pixel_preserved: everyOutsidePixelPreserved,
      every_rgb_channel_preserved: everyRgbChannelPreserved,
    },
    valid: everyInteriorPixelAlphaZero && everyOutsidePixelPreserved && everyRgbChannelPreserved,
  };
}

export function parsePngMetadata(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 || signature.some((value, index) => bytes[index] !== value)) {
    throw new TypeError("The encoded file is not a valid PNG header.");
  }

  const chunkType = String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]);
  if (chunkType !== "IHDR") {
    throw new TypeError("PNG is missing the required IHDR chunk.");
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const width = view.getUint32(16, false);
  const height = view.getUint32(20, false);
  const bitDepth = bytes[24];
  const colorType = bytes[25];
  const colorTypeNames = {
    0: "grayscale",
    2: "truecolor_rgb",
    3: "indexed_color",
    4: "grayscale_alpha",
    6: "truecolor_rgba",
  };

  return {
    width,
    height,
    bit_depth: bitDepth,
    color_type: colorType,
    color_type_name: colorTypeNames[colorType] ?? "unknown",
    has_explicit_alpha_channel: colorType === 4 || colorType === 6,
    is_rgba: colorType === 6,
  };
}

export function createVerificationReport(pixelVerification, pngMetadata = null, mapping = null) {
  const pngValid = pngMetadata ? pngMetadata.is_rgba
    && pngMetadata.width === pixelVerification.canvas.width
    && pngMetadata.height === pixelVerification.canvas.height : null;

  return {
    product: "CodeFEDDY TikTok Background Editor",
    version: PRODUCT_VERSION,
    generated_at: new Date().toISOString(),
    classification: DEPENDENCY_CLASS,
    api_key_required: false,
    server_required: false,
    ai_model_required: false,
    per_image_cost_usd: 0,
    external_service_dependency: "none",
    format: {
      decoded_mode: "RGBA",
      encoded_png: pngMetadata,
      encoded_png_is_verified_rgba: pngValid,
    },
    mapping,
    ...pixelVerification,
    pixel_buffer_verified: pixelVerification.valid,
    export_verified: pixelVerification.valid && pngValid === true,
  };
}

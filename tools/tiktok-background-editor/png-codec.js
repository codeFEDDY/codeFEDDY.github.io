function codec() {
  const upng = globalThis.UPNG;
  if (!upng?.decode || !upng?.toRGBA8 || !upng?.encode) {
    throw new Error("The bundled lossless PNG codec did not load.");
  }
  return upng;
}

export function decodePngRgba(arrayBuffer) {
  const upng = codec();
  const decoded = upng.decode(arrayBuffer);
  const frames = upng.toRGBA8(decoded);
  if (frames.length !== 1) {
    throw new TypeError("Animated PNG overlays are not supported. Export a single-frame PNG first.");
  }
  const rgba = new Uint8ClampedArray(frames[0]);
  const expected = decoded.width * decoded.height * 4;
  if (rgba.length !== expected) {
    throw new Error(`Decoded PNG contains ${rgba.length} RGBA bytes; expected ${expected}.`);
  }
  return {
    width: decoded.width,
    height: decoded.height,
    rgba,
  };
}

export function encodePngRgba(rgba, width, height) {
  const upng = codec();
  if (!(rgba instanceof Uint8Array) && !(rgba instanceof Uint8ClampedArray)) {
    throw new TypeError("PNG encoder requires an RGBA byte array.");
  }
  if (rgba.length !== width * height * 4) {
    throw new RangeError("RGBA byte count does not match the canvas dimensions.");
  }
  const exactBuffer = rgba.byteOffset === 0 && rgba.byteLength === rgba.buffer.byteLength
    ? rgba.buffer
    : rgba.slice().buffer;
  return upng.encode([exactBuffer], width, height, 0);
}

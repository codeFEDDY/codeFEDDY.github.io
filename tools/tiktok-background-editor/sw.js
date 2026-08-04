const CACHE_NAME = "codefeddy-overlay-editor-v2";
const APP_FILES = [
  "./",
  "./index.html",
  "./editor.css?v=1",
  "./core.js",
  "./app.js?v=2",
  "./png-codec.js",
  "./vendor/pako.min.js",
  "./vendor/upng.js",
  "./manifest.webmanifest",
  "./app-icon-192.png",
  "./app-icon-512.png",
  "../shared.css?v=1",
  "../../assets/codefeddy-homepage-logo.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_FILES)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET" || new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request).then((response) => {
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
      }
      return response;
    })),
  );
});

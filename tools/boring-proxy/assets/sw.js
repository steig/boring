// sw.js — minimal service worker for boring PWA (ARD-0019 §6).
//
// Strategy:
//   - Precache the static picker shell on install so the "Install boring as
//     an app" flow has something to render offline.
//   - Network-first for everything else; fall back to cache on offline.
//   - Pass through API responses and per-project routes — those must never
//     be cached (presence/status data + the in-container boring-ui itself).

const CACHE = "boring-v1";
const SHELL = [
  "/",
  "/assets/picker.css",
  "/assets/picker.js",
  "/assets/manifest.json",
  "/assets/icon-192.png",
  "/assets/icon-512.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  // Never intercept API responses or per-project routes (everything that
  // isn't picker-shell). /<slug>/... matches the project routing in proxy.go.
  if (url.pathname.startsWith("/api/") || /^\/[^/]+\//.test(url.pathname)) {
    return;
  }
  // Network-first; fall back to cache on offline.
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request))
  );
});

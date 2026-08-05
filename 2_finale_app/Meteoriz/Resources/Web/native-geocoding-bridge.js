// native-geocoding-bridge.js
// Ersetzt Aufrufe an die Nominatim/OpenStreetMap-Ortssuche (nominatim.openstreetmap.org)
// durch native Apple-MapKit-Suche (LocationSearchBridge.swift). Grund: Nominatim liefert
// bei kurzen Eingaben oft unpassende Treffer ("Base" -> Tujetsch, Faido statt Basel);
// Apples eigene Ortssuche kennt Schweizer Orte deutlich zuverlässiger. Die Antwort wird
// im selben JSON-Format wie Nominatim zurückgegeben, damit der Seiten-Code (formatAddress,
// fetchGeoSuggestions, searchLocation, setLocalByCoords) unverändert bleiben kann.
(function () {
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.geocodeBridge) {
    return;
  }

  const pending = {};
  let nextId = 1;
  const originalFetch = window.fetch.bind(window);

  function isNominatim(url) {
    return typeof url === 'string' && url.indexOf('nominatim.openstreetmap.org') !== -1;
  }

  function b64ToUtf8(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder('utf-8').decode(bytes);
  }

  window.__geocodeBridgeResolve = function (id, base64Json) {
    const cb = pending[id];
    if (!cb) return;
    delete pending[id];
    cb.resolve(new Response(b64ToUtf8(base64Json), { status: 200, headers: { 'Content-Type': 'application/json' } }));
  };

  window.__geocodeBridgeReject = function (id, message) {
    const cb = pending[id];
    if (!cb) return;
    delete pending[id];
    cb.reject(new Error(message));
  };

  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url);
    if (!isNominatim(url)) return originalFetch(input, init);
    return new Promise(function (resolve, reject) {
      const id = nextId++;
      pending[id] = { resolve: resolve, reject: reject };
      window.webkit.messageHandlers.geocodeBridge.postMessage({ id: id, url: url });
    });
  };
})();

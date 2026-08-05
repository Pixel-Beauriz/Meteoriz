// layout-fix.js
// index.html setzt keine explizite Höhe auf html/body – der Seiteninhalt ist nur so
// hoch wie sein Inhalt, nicht zwingend so hoch wie der Bildschirm. Diese Regel sorgt
// dafür, dass der Hintergrund (body) immer MINDESTENS die Bildschirmhöhe ausfüllt –
// ohne index.html selbst anzufassen.
// Bewusst nur min-height, kein festes height:100%: .hero polstert sich jetzt zusätzlich
// mit env(safe-area-inset-top/bottom) ab und kann dadurch natürlicherweise etwas höher
// als 100dvh werden. Ein festes height:100% auf body/html hätte den Hintergrund exakt
// auf der alten (kürzeren) Höhe gedeckelt, während .hero schon darüber hinausragt –
// dadurch bliebe der neue, zusätzliche Bereich unten ungefüllt.
(function () {
  var style = document.createElement('style');
  style.textContent = 'html,body{min-height:100%;}';
  document.documentElement.appendChild(style);
})();

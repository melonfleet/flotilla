/* Inline SF-Symbols-flavoured icon sprite.
   Injected synchronously so <use href="#i-…"> resolves in the same document
   (no CDN, no icon font, works from file://). */
(function () {
  var S = [
    /* brand: the monochrome three-sails menu-bar template glyph */
    ['i-sails', '<path d="M8 1.6 3.2 10.2h4.8Z"/><path d="M11.9 4.4 8.9 10.2h4.4Z"/><path d="M4.6 6.2 2.6 10.2h3.4" opacity=".0"/><path d="M1.7 12.1h12.6c-.8 1.5-2.3 2.3-4 2.3H5.4c-1.6 0-3-.8-3.7-2.3Z"/>'],
    ['i-apple', '<path d="M10.6 8.6c0-1.5 1.2-2.2 1.3-2.3-.7-1-1.8-1.2-2.2-1.2-.9-.1-1.8.5-2.2.5-.5 0-1.2-.5-2-.5-1 0-2 .6-2.5 1.6-1.1 1.9-.3 4.6.8 6.1.5.7 1.1 1.5 1.9 1.5.8 0 1-.5 2-.5s1.1.5 1.9.5c.8 0 1.4-.8 1.9-1.5.4-.6.6-1.2.7-1.3-.1 0-1.6-.6-1.6-2.4Z" fill="currentColor" stroke="none"/><path d="M9.3 3.9c.4-.5.7-1.2.6-1.9-.6 0-1.4.4-1.8.9-.4.4-.7 1.1-.6 1.8.7.1 1.4-.3 1.8-.8Z" fill="currentColor" stroke="none"/>'],
    /* navigation */
    ['i-cube', '<path d="M8 1.9 14 5v6l-6 3.1L2 11V5Z"/><path d="M2 5l6 3 6-3"/><path d="M8 8v6.1"/>'],
    ['i-photo', '<rect x="2" y="4.4" width="12" height="9.2" rx="2"/><path d="M4.2 2.4h7.6"/><path d="M2.4 11.4 5.6 8.7l2.6 2.1 2.1-1.8 3.3 2.6"/><circle cx="10.6" cy="6.9" r="1"/>'],
    ['i-cylinder', '<ellipse cx="8" cy="4" rx="5" ry="2.1"/><path d="M3 4v8c0 1.2 2.2 2.1 5 2.1s5-.9 5-2.1V4"/><path d="M3 8.2c0 1.2 2.2 2.1 5 2.1s5-.9 5-2.1"/>'],
    ['i-server', '<rect x="2" y="2.4" width="12" height="4.4" rx="1.4"/><rect x="2" y="9.2" width="12" height="4.4" rx="1.4"/><circle cx="4.6" cy="4.6" r=".75" fill="currentColor" stroke="none"/><circle cx="4.6" cy="11.4" r=".75" fill="currentColor" stroke="none"/><path d="M7 4.6h4.6M7 11.4h4.6"/>'],
    ['i-gear', '<circle cx="8" cy="8" r="2.1"/><path d="M8 1.6l.5 1.6 1.7.3.9-1.4 1.4 1-.5 1.6 1.2 1.2 1.6-.5.4 1.7-1.4.9.1 1.7 1.5.6-.8 1.5-1.6-.4-1.2 1.2.3 1.6-1.7.4-.8-1.4-1.7.2-.6 1.5-1.5-.8.3-1.6-1.2-1.2-1.6.4-.4-1.7 1.4-.8-.1-1.7-1.5-.6.8-1.5 1.6.4L4.4 4l-.3-1.6 1.7-.4.8 1.4"/>'],
    ['i-sliders', '<path d="M2.4 4.6h11.2M2.4 11.4h11.2"/><circle cx="6" cy="4.6" r="1.7"/><circle cx="10.4" cy="11.4" r="1.7"/>'],
    /* actions */
    ['i-search', '<circle cx="7.1" cy="7.1" r="4.4"/><path d="M10.4 10.4 14 14"/>'],
    ['i-plus', '<path d="M8 3.2v9.6M3.2 8h9.6"/>'],
    ['i-download', '<path d="M8 2.6v7.6"/><path d="M5.2 7.6 8 10.4l2.8-2.8"/><path d="M2.8 12.4h10.4"/>'],
    ['i-play', '<path d="M5.2 3.4 12 8l-6.8 4.6Z" fill="currentColor" stroke="none"/>'],
    ['i-stop', '<rect x="4.4" y="4.4" width="7.2" height="7.2" rx="1.2" fill="currentColor" stroke="none"/>'],
    ['i-pause', '<path d="M6 4.2v7.6M10 4.2v7.6" stroke-width="1.8"/>'],
    ['i-restart', '<path d="M13.2 8a5.2 5.2 0 1 1-1.8-4"/><path d="M13.4 2.4v3.4h-3.4"/>'],
    ['i-refresh', '<path d="M13.2 8a5.2 5.2 0 1 1-1.8-4"/><path d="M13.4 2.4v3.4h-3.4"/>'],
    ['i-ellipsis', '<circle cx="3.6" cy="8" r="1.1" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r="1.1" fill="currentColor" stroke="none"/><circle cx="12.4" cy="8" r="1.1" fill="currentColor" stroke="none"/>'],
    ['i-trash', '<path d="M3.4 4.6h9.2"/><path d="M4.6 4.6 5.2 13a1 1 0 0 0 1 .9h3.6a1 1 0 0 0 1-.9l.6-8.4"/><path d="M6.4 4.6V3.2a.9.9 0 0 1 .9-.9h1.4a.9.9 0 0 1 .9.9v1.4"/>'],
    ['i-copy', '<rect x="5.6" y="5.6" width="8" height="8" rx="1.6"/><path d="M10.4 3.4a1.6 1.6 0 0 0-1.6-1.6H4a1.6 1.6 0 0 0-1.6 1.6v4.8c0 .9.7 1.6 1.6 1.6"/>'],
    ['i-external', '<path d="M6.6 3.4H4.2A1.6 1.6 0 0 0 2.6 5v6.8a1.6 1.6 0 0 0 1.6 1.6H11a1.6 1.6 0 0 0 1.6-1.6V9.4"/><path d="M9.2 2.6h4.2v4.2"/><path d="M13.4 2.6 7.6 8.4"/>'],
    ['i-eye', '<path d="M1.6 8S4 4 8 4s6.4 4 6.4 4S12 12 8 12 1.6 8 1.6 8Z"/><circle cx="8" cy="8" r="1.8"/>'],
    ['i-filter', '<path d="M2.6 4.2h10.8L9.4 8.8v4l-2.8-1.4V8.8Z"/>'],
    ['i-list', '<path d="M5.4 4.4h8.2M5.4 8h8.2M5.4 11.6h8.2"/><circle cx="2.9" cy="4.4" r=".8" fill="currentColor" stroke="none"/><circle cx="2.9" cy="8" r=".8" fill="currentColor" stroke="none"/><circle cx="2.9" cy="11.6" r=".8" fill="currentColor" stroke="none"/>'],
    ['i-grid', '<rect x="2.4" y="2.4" width="5" height="5" rx="1.2"/><rect x="8.6" y="2.4" width="5" height="5" rx="1.2"/><rect x="2.4" y="8.6" width="5" height="5" rx="1.2"/><rect x="8.6" y="8.6" width="5" height="5" rx="1.2"/>'],
    /* chevrons + marks */
    ['i-chev-right', '<path d="M6.2 3.6 10.6 8l-4.4 4.4"/>'],
    ['i-chev-down', '<path d="M3.6 6.2 8 10.6l4.4-4.4"/>'],
    ['i-chev-up-down', '<path d="M4.8 6.6 8 3.4l3.2 3.2"/><path d="M4.8 9.4 8 12.6l3.2-3.2"/>'],
    ['i-chev-updown-sm', '<path d="M5.2 7 8 4.2 10.8 7"/><path d="M5.2 9 8 11.8 10.8 9"/>'],
    ['i-check', '<path d="M3.2 8.4 6.4 11.6l6.4-7.2" stroke-width="1.7"/>'],
    ['i-x', '<path d="M4 4l8 8M12 4l-8 8"/>'],
    ['i-warn', '<path d="M8 2.6 14.4 13.4H1.6Z"/><path d="M8 6.4v3.2"/><circle cx="8" cy="11.5" r=".8" fill="currentColor" stroke="none"/>'],
    ['i-info', '<circle cx="8" cy="8" r="6.1"/><path d="M8 7.4v3.6"/><circle cx="8" cy="5.2" r=".8" fill="currentColor" stroke="none"/>'],
    ['i-check-circle', '<circle cx="8" cy="8" r="6.1"/><path d="M5.2 8.2 7.2 10.4l3.6-4.4"/>'],
    ['i-x-circle', '<circle cx="8" cy="8" r="6.1"/><path d="M5.9 5.9l4.2 4.2M10.1 5.9l-4.2 4.2"/>'],
    ['i-dash-circle', '<circle cx="8" cy="8" r="6.1"/><path d="M5.4 8h5.2"/>'],
    /* detail tabs */
    ['i-doc', '<path d="M4 2.4h5.2L12.6 6v7.6H4Z"/><path d="M9 2.6V6h3.4"/><path d="M6 9h4M6 11.2h3"/>'],
    ['i-terminal', '<rect x="1.9" y="2.9" width="12.2" height="10.2" rx="1.8"/><path d="M4.6 6.6 6.4 8.4 4.6 10.2"/><path d="M8.4 10.6h3"/>'],
    ['i-chart', '<path d="M2.4 13.2h11.4"/><path d="M2.8 10.4l3-3.6 2.6 2.2 4.4-5"/><circle cx="5.8" cy="6.8" r=".85" fill="currentColor" stroke="none"/><circle cx="8.4" cy="9" r=".85" fill="currentColor" stroke="none"/>'],
    ['i-folder', '<path d="M2 5.2a1.6 1.6 0 0 1 1.6-1.6h2.2l1.4 1.6h5.2A1.6 1.6 0 0 1 14 6.8v5A1.6 1.6 0 0 1 12.4 13.4H3.6A1.6 1.6 0 0 1 2 11.8Z"/>'],
    ['i-braces', '<path d="M6.4 2.6c-1.5 0-1.7 1-1.7 2.2S4.5 7 3.2 7c1.3 0 1.5 1 1.5 2.2s.2 2.2 1.7 2.2"/><path d="M9.6 2.6c1.5 0 1.7 1 1.7 2.2s.2 2.2 1.5 2.2c-1.3 0-1.5 1-1.5 2.2s-.2 2.2-1.7 2.2"/><path d="M6.4 13.4h3.2" opacity="0"/>'],
    ['i-file', '<path d="M4.2 2.4h4.6l3.2 3.4v8H4.2Z"/><path d="M8.6 2.6v3.3h3.3"/>'],
    /* trust / network */
    ['i-key', '<circle cx="5.4" cy="5.4" r="2.8"/><path d="M7.4 7.4 13 13"/><path d="M10.8 10.8 12.4 9.2M12.2 12.2 13.8 10.6"/>'],
    ['i-lock', '<rect x="3.6" y="7" width="8.8" height="6.6" rx="1.6"/><path d="M5.6 7V5.4a2.4 2.4 0 0 1 4.8 0V7"/><circle cx="8" cy="10.2" r=".9" fill="currentColor" stroke="none"/>'],
    ['i-shield', '<path d="M8 1.8 13.2 3.6v4.2c0 3.1-2.1 5.4-5.2 6.4-3.1-1-5.2-3.3-5.2-6.4V3.6Z"/><path d="M5.8 7.8 7.5 9.6l3-3.4"/>'],
    ['i-wifi', '<path d="M2 6.2a9 9 0 0 1 12 0"/><path d="M4.3 8.6a5.6 5.6 0 0 1 7.4 0"/><path d="M6.5 11a2.4 2.4 0 0 1 3 0"/><circle cx="8" cy="13" r=".9" fill="currentColor" stroke="none"/>'],
    ['i-broadcast', '<circle cx="8" cy="8" r="1.6" fill="currentColor" stroke="none"/><path d="M4.9 4.9a4.4 4.4 0 0 0 0 6.2M11.1 11.1a4.4 4.4 0 0 0 0-6.2"/><path d="M2.9 2.9a7.2 7.2 0 0 0 0 10.2M13.1 13.1a7.2 7.2 0 0 0 0-10.2"/>'],
    ['i-bell', '<path d="M8 2.2A4.2 4.2 0 0 0 3.8 6.4c0 3-1.2 3.8-1.2 3.8h10.8s-1.2-.8-1.2-3.8A4.2 4.2 0 0 0 8 2.2Z"/><path d="M6.6 12.4a1.6 1.6 0 0 0 2.8 0"/>'],
    ['i-power', '<path d="M8 2.4v5.2"/><path d="M11.8 4.6a5.2 5.2 0 1 1-7.6 0"/>'],
    /* hardware */
    ['i-laptop', '<rect x="3" y="3.2" width="10" height="7" rx="1.2"/><path d="M1.6 12.4h12.8"/>'],
    ['i-studio', '<rect x="2.6" y="4.2" width="10.8" height="7.6" rx="1.8"/><path d="M5.2 11.8v1.4h5.6v-1.4"/><circle cx="8" cy="8" r="1.6"/>'],
    ['i-mini', '<rect x="2.2" y="5.4" width="11.6" height="5.2" rx="1.6"/><circle cx="5" cy="8" r=".8" fill="currentColor" stroke="none"/><path d="M7.4 8h4.2"/>'],
    ['i-cpu', '<rect x="4.4" y="4.4" width="7.2" height="7.2" rx="1.4"/><path d="M6.6 2.2v2.2M9.4 2.2v2.2M6.6 11.6v2.2M9.4 11.6v2.2M2.2 6.6h2.2M2.2 9.4h2.2M11.6 6.6h2.2M11.6 9.4h2.2"/>'],
    ['i-memory', '<rect x="2.2" y="4.6" width="11.6" height="6.8" rx="1.4"/><path d="M5 11.4v1.8M8 11.4v1.8M11 11.4v1.8"/><path d="M5.4 7h5.2v2H5.4z"/>'],
    ['i-disk', '<rect x="2.2" y="2.6" width="11.6" height="10.8" rx="2"/><circle cx="8" cy="8" r="2.6"/><circle cx="8" cy="8" r=".7" fill="currentColor" stroke="none"/>'],
    ['i-clock', '<circle cx="8" cy="8" r="6.1"/><path d="M8 4.6V8l2.6 1.6"/>'],
    ['i-globe', '<circle cx="8" cy="8" r="6.1"/><path d="M1.9 8h12.2"/><path d="M8 1.9c1.8 2 2.6 4 2.6 6.1S9.8 12 8 14.1C6.2 12 5.4 10.1 5.4 8s.8-4.1 2.6-6.1Z"/>'],
    ['i-arrow-down-circle', '<circle cx="8" cy="8" r="6.1"/><path d="M8 4.8v6.2"/><path d="M5.6 8.6 8 11l2.4-2.4"/>'],
    ['i-arrow-right', '<path d="M2.6 8h10.4"/><path d="M9.6 4.6 13 8l-3.4 3.4"/>'],
    ['i-link', '<path d="M6.6 9.4a2.6 2.6 0 0 1 0-3.6l1.6-1.6a2.6 2.6 0 0 1 3.6 3.6l-.8.8"/><path d="M9.4 6.6a2.6 2.6 0 0 1 0 3.6l-1.6 1.6a2.6 2.6 0 0 1-3.6-3.6l.8-.8"/>'],
    /* menu-bar status glyphs */
    ['i-mb-wifi', '<path d="M2 6.4a9 9 0 0 1 12 0"/><path d="M4.3 8.8a5.6 5.6 0 0 1 7.4 0"/><path d="M6.5 11.2a2.4 2.4 0 0 1 3 0"/>'],
    ['i-mb-battery', '<rect x="1.6" y="5.4" width="11" height="5.2" rx="1.6"/><path d="M14 7.6v1.4"/><rect x="3" y="6.8" width="7.4" height="2.4" rx=".8" fill="currentColor" stroke="none"/>'],
    ['i-mb-control', '<path d="M3.4 5h9.2M3.4 11h9.2"/><circle cx="6" cy="5" r="1.5" fill="currentColor" stroke="none"/><circle cx="10" cy="11" r="1.5" fill="currentColor" stroke="none"/>'],
    ['i-mb-spotlight', '<circle cx="7.2" cy="7.2" r="4.2"/><path d="M10.2 10.2 13.6 13.6"/>']
  ];
  var out = '<svg aria-hidden="true" focusable="false" style="position:absolute;width:0;height:0;overflow:hidden"><defs>';
  for (var i = 0; i < S.length; i++) {
    out += '<symbol id="' + S[i][0] + '" viewBox="0 0 16 16" fill="none" stroke="currentColor" ' +
           'stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round">' + S[i][1] + '</symbol>';
  }
  out += '</defs></svg>';
  if (document.currentScript) {
    document.currentScript.insertAdjacentHTML('afterend', out);
  } else {
    document.body.insertAdjacentHTML('afterbegin', out);
  }
})();

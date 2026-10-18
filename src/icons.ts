// 16px stroke icons (currentColor). Usage: el.innerHTML = icon("play").
const P: Record<string, string> = {
  sidebar: '<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M6 3v10"/>',
  home: '<path d="M2.5 7.5 8 3l5.5 4.5V13a.5.5 0 0 1-.5.5H10V10H6v3.5H3a.5.5 0 0 1-.5-.5z"/>',
  play: '<path d="M5 3.5v9l7-4.5z" fill="currentColor"/>',
  stop: '<rect x="4" y="4" width="8" height="8" rx="1.5" fill="currentColor"/>',
  sun: '<circle cx="8" cy="8" r="3"/><path d="M8 1.5v1.5M8 13v1.5M1.5 8H3M13 8h1.5M3.4 3.4l1 1M11.6 11.6l1 1M3.4 12.6l1-1M11.6 4.4l1-1"/>',
  moon: '<path d="M13.5 9.5A5.5 5.5 0 0 1 6.5 2.5a5.5 5.5 0 1 0 7 7z"/>',
  auto: '<circle cx="8" cy="8" r="5.5"/><path d="M8 2.5v11a5.5 5.5 0 0 0 0-11z" fill="currentColor"/>',
  file: '<path d="M4 1.5h5L12.5 5v9a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5V2a.5.5 0 0 1 .5-.5z"/><path d="M9 1.5V5h3.5"/>',
  folder: '<path d="M1.5 4a1 1 0 0 1 1-1h3.6l1.5 1.5h5.9a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z"/>',
  chevron: '<path d="M6 4l4 4-4 4"/>',
  download: '<path d="M8 2v8M4.5 6.5 8 10l3.5-3.5M2.5 13.5h11"/>',
  search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3"/>',
  sync: '<path d="M13 5.5A5.5 5.5 0 0 0 3 6M3 10.5a5.5 5.5 0 0 0 10-.5"/><path d="M13 2.5v3h-3M3 13.5v-3h3"/>',
  plus: '<path d="M8 3v10M3 8h10"/>',
  log: '<path d="M3 4h10M3 8h10M3 12h6"/>',
  trash: '<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.5 9h6l.5-9"/>',
  fit: '<path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>',
  invert: '<circle cx="8" cy="8" r="5.5"/><path d="M8 2.5a5.5 5.5 0 0 1 0 11z" fill="currentColor"/>',
  check: '<path d="m3.5 8.5 3 3 6-7"/>',
  x: '<path d="m4 4 8 8M12 4l-8 8"/>',
  tex: '<path d="M2 4h6M5 4v8M7.5 8h6M10.5 8l3 4.5M13.5 8l-3 4.5"/>',
  diagram: '<rect x="1.5" y="2" width="5" height="4" rx="1"/><rect x="9.5" y="10" width="5" height="4" rx="1"/><path d="M4 6v3.5a1 1 0 0 0 1 1h4.5"/>',
  markdown: '<rect x="1.5" y="3.5" width="13" height="9" rx="1.5"/><path d="M4 10.5v-5l2 2.5 2-2.5v5M11 5.5v5M9.5 9l1.5 1.5L12.5 9"/>',
};

export function icon(name: keyof typeof P | string, size = 16): string {
  return `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[name] ?? ""}</svg>`;
}

/** Icon button with a native-style tooltip. */
export function iconButton(name: string, title: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement("button");
  b.className = "icon-btn";
  b.type = "button";
  b.title = title;
  b.setAttribute("aria-label", title);
  b.innerHTML = icon(name);
  b.addEventListener("click", onClick);
  return b;
}

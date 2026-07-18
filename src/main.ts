import "./app.css";
import App from "./App.svelte";
import LocalModelSetup from "./LocalModelSetup.svelte";
import RequestLogs from "./RequestLogs.svelte";
import TranslationPopover from "./TranslationPopover.svelte";
import { currentSurface, type AppSurface } from "./lib/surfaces";
import { mount } from "svelte";

const surfaceComponents: Record<AppSurface, typeof App> = {
  settings: App,
  translation: TranslationPopover as typeof App,
  "local-model-setup": LocalModelSetup as typeof App,
  "request-logs": RequestLogs as typeof App
};

const surface = currentSurface();
document.documentElement.dataset.surface = surface;
document.body.dataset.surface = surface;

// Native windows never show the browser context menu on chrome. Editable fields
// and selectable content keep it for the system text actions (Copy, Look Up...).
document.addEventListener("contextmenu", (event) => {
  const target = event.target instanceof Element ? event.target : null;
  if (!target?.closest("input, textarea, [contenteditable='true'], .translation-text, pre")) {
    event.preventDefault();
  }
});

const Component = surfaceComponents[surface];

const app = mount(Component, {
  target: document.getElementById("app")!
});

function prewarmFontFallbacks() {
  const span = document.createElement("span");
  span.setAttribute("aria-hidden", "true");
  span.style.cssText = "position:absolute;left:-9999px;top:0;opacity:0;pointer-events:none";
  span.textContent = "😀🎉✨ 中文 日本語 한국어 ∑∫√ ✓✗";
  document.body.appendChild(span);
  void span.getBoundingClientRect();
  // Double rAF: lets layout AND paint register the fallback fonts in Core Text's cache before removal.
  requestAnimationFrame(() => requestAnimationFrame(() => span.remove()));
}

prewarmFontFallbacks();

export default app;

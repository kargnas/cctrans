export type AppSurface =
  | "settings"
  | "translation"
  | "local-model-setup"
  | "request-logs";

export function currentSurface(): AppSurface {
  const surface = new URLSearchParams(window.location.search).get("surface");
  if (
    surface === "translation" ||
    surface === "local-model-setup" ||
    surface === "request-logs"
  ) {
    return surface;
  }
  return "settings";
}

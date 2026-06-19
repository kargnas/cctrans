<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";
  import {
    ArrowUpDown,
    Ban,
    Camera,
    Check,
    CheckCircle2,
    ChevronDown,
    ChevronRight,
    Cloud,
    Cpu,
    KeyRound,
    Info,
    Keyboard,
    Languages,
    Play,
    RotateCcw,
    ScrollText,
    Settings as SettingsIcon,
    ShieldCheck,
    SlidersHorizontal,
    Star,
    TriangleAlert
  } from "@lucide/svelte";
  import {
    cloneFallbackState,
    type ActionResult,
    type LoginItemState,
    type OpenRouterModelFilter,
    type OpenRouterModelOption,
    type SettingField,
    type Settings,
    type SettingsState,
    type ToastPosition,
    type TranslationProvider
  } from "./lib/settings";

  type Section = "general" | "models" | "shortcuts" | "excluded" | "advanced" | "info";
  type OpenRouterSortKey = "model" | "releaseDate" | "dailyRank" | "inputPrice" | "outputPrice" | "context";
  type SortDirection = "asc" | "desc";
  type OpenRouterAPIKeyState = {
    configured: boolean;
    path: string;
  };

  let settingsState = $state<SettingsState | null>(null);
  let activeSection = $state<Section>("general");
  let contentElement = $state<HTMLElement | null>(null);
  // Drives the System Settings-style toolbar material: the sticky header stays
  // transparent until content actually scrolls beneath it.
  let contentScrolled = $state(false);
  let isSaving = $state(false);
  let isTauri = $state(false);
  let lastResult = $state("No translation yet.");
  let notices = $state<ActionResult[]>([]);
  let openRouterAPIKeyState = $state<OpenRouterAPIKeyState>({ configured: false, path: "~/.config/cctrans/.env" });
  let openRouterAPIKeyInput = $state("");
  let isRefreshingOpenRouterModels = $state(false);
  let isUpdatingLoginItem = $state(false);
  let openTranslationModelMenu = $state<"general" | "models" | null>(null);
  let activeTranslationModelProvider = $state<TranslationProvider>("localHyMT2");
  let openRouterSort = $state<{ key: OpenRouterSortKey; direction: SortDirection }>({
    key: "releaseDate",
    direction: "desc"
  });

  let isOpenRouterTextOnly = $derived(
    settingsState?.settings.provider === "openRouter" &&
    !(settingsState?.options.openRouterModels.find((m) => m.value === settingsState?.settings.openRouterTextModel)?.modalities.includes("image") ?? false)
  );

  $effect(() => {
    void activeSection;
    // Each section is a fresh page: restore the top scroll position the old
    // per-pane scroll containers gave us for free.
    contentElement?.scrollTo({ top: 0 });
    contentScrolled = false;
  });

  const sectionTitles: Record<Section, string> = {
    general: "General",
    models: "Models",
    shortcuts: "Shortcuts",
    excluded: "Excluded Apps",
    advanced: "Advanced",
    info: "Info"
  };

  onMount(async () => {
    isTauri = "__TAURI_INTERNALS__" in window;
    await loadSettings();
    await loadOpenRouterAPIKeyState();
    void refreshOpenRouterModels(true);
  });

  async function loadSettings() {
    try {
      settingsState = isTauri
        ? await invoke<SettingsState>("load_settings")
        : cloneFallbackState();
    } catch (error) {
      settingsState = cloneFallbackState();
      pushNotice({
        title: "Settings",
        message: `Loaded browser preview. ${formatError(error)}`,
        ok: false
      });
    }
  }

  async function saveSettings(next: Settings) {
    if (!settingsState) return;

    isSaving = true;
    try {
      settingsState = isTauri
        ? await invoke<SettingsState>("save_settings", { settings: next })
        : withBrowserOverrides(settingsState, next);
    } catch (error) {
      pushNotice({
        title: "Save failed",
        message: formatError(error),
        ok: false
      });
    } finally {
      isSaving = false;
    }
  }

  async function updateField<K extends SettingField>(field: K, value: Settings[K]) {
    if (!settingsState) return;
    const next = {
      ...settingsState.settings,
      [field]: value
    };
    await saveSettings(next);
  }

  async function updateNullableField(field: "localHyMT2BackendPath" | "customLocalModelsPath", value: string) {
    const trimmed = value.trim();
    await updateField(field, (trimmed.length > 0 ? trimmed : null) as Settings[typeof field]);
  }

  async function toggleLaunchAtLogin(enabled: boolean) {
    if (!settingsState) return;

    isUpdatingLoginItem = true;
    try {
      const loginItem = isTauri
        ? await invoke<LoginItemState>("set_launch_at_login", { enabled })
        : {
            ...settingsState.loginItem,
            enabled,
            status: enabled ? "enabled" : "notRegistered",
            message: enabled
              ? "CCTrans will open automatically when you sign in."
              : "CCTrans is not set to open at login."
          };
      settingsState = { ...settingsState, loginItem };
    } catch (error) {
      pushNotice({
        title: "Login Item",
        message: formatError(error),
        ok: false
      });
      if (isTauri) {
        try {
          const loginItem = await invoke<LoginItemState>("login_item_status");
          settingsState = { ...settingsState, loginItem };
        } catch {
          // Keep the previous state when the status refresh is also unavailable.
        }
      }
    } finally {
      isUpdatingLoginItem = false;
    }
  }

  async function updateModelField(field: "openRouterTextModel" | "openRouterVisionModel", value: string) {
    const trimmed = value.trim();
    await updateField(field, trimmed === "default" ? settingsState?.defaults[field] ?? trimmed : trimmed);
  }

  async function selectTranslationModel(value: string) {
    if (!settingsState) return;
    const [provider, model] = value.split(/:(.*)/s).filter(Boolean);
    if (provider !== "localHyMT2" && provider !== "openRouter" && provider !== "appleTranslation") return;

    const next: Settings = { ...settingsState.settings, provider };
    if (provider === "localHyMT2") {
      next.localModelID = model === "default" ? settingsState.defaults.localModelID : model;
    } else if (provider === "openRouter") {
      next.openRouterTextModel = model === "default" ? settingsState.defaults.openRouterTextModel : model;
    }
    // appleTranslation is a single-model provider; only the provider changes.
    await saveSettings(next);
  }

  async function chooseTranslationModel(value: string) {
    await selectTranslationModel(value);
    closeTranslationModelMenu();
  }

  function toggleTranslationModelMenu(scope: "general" | "models") {
    if (!settingsState) return;
    if (openTranslationModelMenu === scope) {
      closeTranslationModelMenu();
      return;
    }
    activeTranslationModelProvider = settingsState.settings.provider;
    openTranslationModelMenu = scope;
  }

  function closeTranslationModelMenu() {
    openTranslationModelMenu = null;
  }

  let modelTypeAheadBuffer = "";
  let modelTypeAheadLastInput = 0;

  // Native list behavior (NSMenu/NSTableView): arrows walk the items and typing
  // letters jumps to the first item whose label matches the typed prefix.
  function handleModelPickerKeydown(event: KeyboardEvent) {
    if (!openTranslationModelMenu) return;
    const picker = event.currentTarget as HTMLElement;
    const options = [...picker.querySelectorAll<HTMLButtonElement>(".nested-model-options button")];
    if (options.length === 0) return;
    const activeIndex = options.indexOf(document.activeElement as HTMLButtonElement);

    const focusOption = (index: number) => {
      const option = options[Math.max(0, Math.min(options.length - 1, index))];
      option.focus();
      option.scrollIntoView({ block: "nearest" });
    };

    if (event.key === "ArrowDown") {
      event.preventDefault();
      focusOption(activeIndex + 1);
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      focusOption(activeIndex === -1 ? options.length - 1 : activeIndex - 1);
      return;
    }
    if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      focusOption(event.key === "Home" ? 0 : options.length - 1);
      return;
    }

    if (/^[\p{L}\p{N}]$/u.test(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey) {
      const now = performance.now();
      if (now - modelTypeAheadLastInput > 700) modelTypeAheadBuffer = "";
      modelTypeAheadLastInput = now;
      modelTypeAheadBuffer += event.key.toLowerCase();
      const match = options.find((option) =>
        (option.querySelector("strong")?.textContent ?? "").trim().toLowerCase().startsWith(modelTypeAheadBuffer)
      );
      if (match) {
        event.preventDefault();
        match.focus();
        match.scrollIntoView({ block: "nearest" });
      }
    }
  }

  function handleSettingsKeydown(event: KeyboardEvent) {
    const isClose = event.key === "Escape" || (event.metaKey && event.key.toLowerCase() === "w");
    if (!isClose) return;
    // Esc first dismisses an open model menu; only an already-closed menu lets Esc close the window.
    if (event.key === "Escape" && openTranslationModelMenu) {
      closeTranslationModelMenu();
      return;
    }
    if (!isTauri) return;
    event.preventDefault();
    void invoke("close_settings_window");
  }

  async function toggleFavorite(field: "favoriteLocalModelIDs" | "favoriteOpenRouterModels", modelID: string) {
    if (!settingsState) return;
    const current = settingsState.settings[field];
    const nextValue = current.includes(modelID)
      ? current.filter((value) => value !== modelID)
      : [...current, modelID];
    await updateField(field, nextValue);
  }

  async function useLocalModel(modelID: string) {
    if (!settingsState) return;
    await saveSettings({ ...settingsState.settings, provider: "localHyMT2", localModelID: modelID });
  }

  async function useOpenRouterTextModel(modelID: string) {
    if (!settingsState) return;
    await saveSettings({ ...settingsState.settings, provider: "openRouter", openRouterTextModel: modelID });
  }

  async function useOpenRouterVisionModel(modelID: string) {
    if (!settingsState) return;
    await saveSettings({ ...settingsState.settings, openRouterVisionModel: modelID });
  }

  async function loadOpenRouterAPIKeyState() {
    if (!isTauri) {
      openRouterAPIKeyState = { configured: false, path: "~/.config/cctrans/.env" };
      return;
    }
    try {
      openRouterAPIKeyState = await invoke<OpenRouterAPIKeyState>("load_openrouter_api_key_state");
    } catch (error) {
      pushNotice({ title: "OpenRouter API Key", message: formatError(error), ok: false });
    }
  }

  async function refreshOpenRouterModels(silent = false) {
    if (!isTauri) return;

    isRefreshingOpenRouterModels = true;
    try {
      settingsState = await invoke<SettingsState>("refresh_openrouter_models");
    } catch (error) {
      if (!silent) {
        pushNotice({ title: "OpenRouter Models", message: formatError(error), ok: false });
      } else {
        console.warn("OpenRouter model refresh failed", error);
      }
    } finally {
      isRefreshingOpenRouterModels = false;
    }
  }

  async function saveOpenRouterAPIKey() {
    if (!openRouterAPIKeyInput.trim()) {
      pushNotice({ title: "OpenRouter API Key", message: "Enter a key before saving.", ok: false });
      return;
    }
    try {
      openRouterAPIKeyState = isTauri
        ? await invoke<OpenRouterAPIKeyState>("save_openrouter_api_key", { value: openRouterAPIKeyInput })
        : { configured: true, path: "~/.config/cctrans/.env" };
      openRouterAPIKeyInput = "";
      pushNotice({ title: "OpenRouter API Key", message: "Saved.", ok: true });
    } catch (error) {
      pushNotice({ title: "OpenRouter API Key", message: formatError(error), ok: false });
    }
  }

  async function clearOpenRouterAPIKey() {
    try {
      openRouterAPIKeyState = isTauri
        ? await invoke<OpenRouterAPIKeyState>("clear_openrouter_api_key")
        : { configured: false, path: "~/.config/cctrans/.env" };
      openRouterAPIKeyInput = "";
      pushNotice({ title: "OpenRouter API Key", message: "Cleared.", ok: true });
    } catch (error) {
      pushNotice({ title: "OpenRouter API Key", message: formatError(error), ok: false });
    }
  }

  async function resetField(field: SettingField) {
    if (!settingsState) return;

    isSaving = true;
    try {
      settingsState = isTauri
        ? await invoke<SettingsState>("reset_setting", { field })
        : withBrowserOverrides(settingsState, {
            ...settingsState.settings,
            [field]: settingsState.defaults[field]
          });
    } catch (error) {
      pushNotice({
        title: "Reset failed",
        message: formatError(error),
        ok: false
      });
    } finally {
      isSaving = false;
    }
  }

  async function resetAll() {
    if (!settingsState) return;
    await saveSettings({ ...settingsState.defaults });
  }

  async function runAction(action: string) {
    if (!settingsState) return;

    const fallback: ActionResult = {
      title: actionTitle(action),
      message: "Preview action recorded.",
      ok: true
    };

    try {
      const result = isTauri
        ? await invoke<ActionResult>("perform_settings_action", {
            action,
            settings: settingsState.settings
          })
        : fallback;
      lastResult = `${result.title}: ${result.message}`;
      pushNotice(result);
    } catch (error) {
      const result = {
        title: actionTitle(action),
        message: formatError(error),
        ok: false
      };
      lastResult = `${result.title}: ${result.message}`;
      pushNotice(result);
    }
  }

  function withBrowserOverrides(current: SettingsState, settings: Settings): SettingsState {
    const overrides = Object.fromEntries(
      (Object.keys(current.overrides) as SettingField[]).map((field) => [field, isOverride(settings, current.defaults, field)])
    ) as Record<SettingField, boolean>;

    return {
      ...current,
      settings,
      overrides
    };
  }

  function pushNotice(result: ActionResult) {
    // Success feedback already lives inline (Saved state, status pills, Last Result);
    // only failures earn a banner. Floating success toasts are a web idiom.
    if (result.ok) return;
    notices = [result, ...notices].slice(0, 3);
  }

  function formatError(error: unknown) {
    return error instanceof Error ? error.message : String(error);
  }

  function actionTitle(action: string) {
    const titles: Record<string, string> = {
      runTextTest: "Text Test",
      translateScreenshot: "Screenshot Translation",
      showRequestLogs: "Request Logs",
      showLocalModelSetup: "Model Setup",
      openInputMonitoring: "Input Monitoring",
      openAccessibility: "Accessibility",
      openScreenRecording: "Screen Recording",
      requestKeyboardPrompt: "Keyboard Prompt",
      openPermissionHelper: "Permission Helper"
    };
    return titles[action] ?? "Action";
  }

  function toastPositionValue(value: string): ToastPosition {
    if (value === "bottomLeft" || value === "topRight" || value === "topLeft" || value === "custom") return value;
    return "bottomRight";
  }

  async function updateToastPosition(value: string) {
    if (!settingsState) return;
    const toastPosition = toastPositionValue(value);
    await saveSettings({
      ...settingsState.settings,
      toastPosition,
      toastCustomPosition: toastPosition === "custom" ? settingsState.settings.toastCustomPosition : null
    });
  }

  function isOverride(settings: Settings, defaults: Settings, field: SettingField) {
    const value = settings[field];
    const defaultValue = defaults[field];
    return Array.isArray(value) && Array.isArray(defaultValue)
      ? JSON.stringify(value) !== JSON.stringify(defaultValue)
      : typeof value === "object" && typeof defaultValue === "object"
        ? JSON.stringify(value) !== JSON.stringify(defaultValue)
      : value !== defaultValue;
  }

  function translationModelValue(settings: Settings, defaults: Settings) {
    if (settings.provider === "localHyMT2") {
      return settings.localModelID === defaults.localModelID ? "localHyMT2:default" : `localHyMT2:${settings.localModelID}`;
    }
    if (settings.provider === "appleTranslation") {
      return "appleTranslation:apple";
    }
    return settings.openRouterTextModel === defaults.openRouterTextModel
      ? "openRouter:default"
      : `openRouter:${settings.openRouterTextModel}`;
  }

  function localModelLabel(value: string) {
    return settingsState?.options.localModels.find((option) => option.value === value)?.label ?? value;
  }

  function openRouterModelLabel(value: string) {
    return settingsState?.options.openRouterModels.find((option) => option.value === value)?.label ?? value;
  }

  function translationModelProviderLabel(provider: TranslationProvider) {
    if (provider === "localHyMT2") return "Local Model";
    if (provider === "appleTranslation") return "Apple Translation";
    return "OpenRouter LLM";
  }

  function translationModelProviderDetail(settings: Settings) {
    if (settings.provider === "localHyMT2") return "Local runtime active";
    if (settings.provider === "appleTranslation") return "On-device Apple model active";
    return "OpenRouter API active";
  }

  function translationModelName(settings: Settings) {
    if (settings.provider === "localHyMT2") return localModelLabel(settings.localModelID);
    if (settings.provider === "appleTranslation") return "System (on-device)";
    return openRouterModelLabel(settings.openRouterTextModel);
  }

  function formatPrice(model: OpenRouterModelOption) {
    if (model.isFree) return "Free";
    if (model.promptPricePerMillion < 0 || model.completionPricePerMillion < 0) return "Variable price";
    return `$${formatCompactPrice(model.promptPricePerMillion)} in / $${formatCompactPrice(model.completionPricePerMillion)} out per 1M`;
  }

  function formatUnitPrice(value: number) {
    if (value < 0) return "Variable";
    if (value === 0) return "Free";
    return `$${formatCompactPrice(value)}`;
  }

  function formatCompactPrice(value: number) {
    return value.toFixed(value < 1 ? 2 : 1).replace(/\.?0+$/, "");
  }

  function modalityText(model: OpenRouterModelOption) {
    return model.modalities.map((value) => value.charAt(0).toUpperCase() + value.slice(1)).join(" + ");
  }

  function modelMetaText(model: OpenRouterModelOption) {
    const parts = [
      modalityText(model),
      model.releaseDate,
      `${formatContextWindow(model.contextWindow)} context`
    ];
    if (isDailyTopModel(model)) parts.push(`Top #${model.dailyTokenRank}`);
    if (model.isReasoning) parts.push("Reasoning");
    if (model.isRecommended) parts.push("Recommended");
    return parts.join(" · ");
  }

  function formatContextWindow(value: number) {
    if (value >= 1_000_000) return `${formatCompactPrice(value / 1_000_000)}M`;
    if (value >= 1_000) return `${formatCompactPrice(value / 1_000)}K`;
    return String(value);
  }

  function sortOpenRouterModels(models: OpenRouterModelOption[]) {
    const sorted = [...models];
    sorted.sort((left, right) => {
      const multiplier = openRouterSort.direction === "asc" ? 1 : -1;
      if (openRouterSort.key === "model") {
        return left.label.localeCompare(right.label) * multiplier;
      }
      if (openRouterSort.key === "releaseDate") {
        return (
          left.releaseDate.localeCompare(right.releaseDate) ||
          left.label.localeCompare(right.label)
        ) * multiplier;
      }
      if (openRouterSort.key === "dailyRank") {
        return compareOptionalDailyRank(left, right, openRouterSort.direction);
      }
      if (openRouterSort.key === "inputPrice") {
        return (
          sortablePrice(left.promptPricePerMillion) - sortablePrice(right.promptPricePerMillion) ||
          sortablePrice(left.completionPricePerMillion) - sortablePrice(right.completionPricePerMillion) ||
          left.label.localeCompare(right.label)
        ) * multiplier;
      }
      if (openRouterSort.key === "outputPrice") {
        return (
          sortablePrice(left.completionPricePerMillion) - sortablePrice(right.completionPricePerMillion) ||
          sortablePrice(left.promptPricePerMillion) - sortablePrice(right.promptPricePerMillion) ||
          left.label.localeCompare(right.label)
        ) * multiplier;
      }
      return (left.contextWindow - right.contextWindow || left.label.localeCompare(right.label)) * multiplier;
    });
    return sorted;
  }

  function sortablePrice(value: number) {
    return value < 0 ? Number.MAX_SAFE_INTEGER : value;
  }

  function compareOptionalDailyRank(left: OpenRouterModelOption, right: OpenRouterModelOption, direction: SortDirection) {
    const leftRank = sortableDailyRank(left);
    const rightRank = sortableDailyRank(right);
    const leftMissing = leftRank === Number.MAX_SAFE_INTEGER;
    const rightMissing = rightRank === Number.MAX_SAFE_INTEGER;
    if (leftMissing !== rightMissing) return leftMissing ? 1 : -1;
    const multiplier = direction === "asc" ? 1 : -1;
    return (leftRank - rightRank || left.label.localeCompare(right.label)) * multiplier;
  }

  function sortableDailyRank(model: OpenRouterModelOption) {
    return isDailyTopModel(model) ? model.dailyTokenRank ?? Number.MAX_SAFE_INTEGER : Number.MAX_SAFE_INTEGER;
  }

  function isDailyTopModel(model: OpenRouterModelOption) {
    return typeof model.dailyTokenRank === "number" &&
      model.dailyTokenRank >= 1 &&
      model.dailyTokenRank <= 20;
  }

  function visibleOpenRouterModels(models: OpenRouterModelOption[]) {
    const filter = settingsState?.settings.openRouterModelFilter ?? settingsState?.defaults.openRouterModelFilter;
    if (!filter) return sortOpenRouterModels(models);
    return sortOpenRouterModels(models).filter((model) => openRouterModelMatchesFilter(model, filter));
  }

  function openRouterModelMatchesFilter(model: OpenRouterModelOption, filter: OpenRouterModelFilter) {
    const modalities = model.modalities.map((value) => value.toLowerCase());
    if (filter.modalityMode === "textOrVision") {
      const hasText = modalities.includes("text");
      const hasVision = modalities.includes("image");
      if (!hasText || (modalities.length > 1 && !hasVision)) return false;
    }

    return model.promptPricePerMillion >= filter.minPromptPricePerMillion &&
      model.promptPricePerMillion <= filter.maxPromptPricePerMillion &&
      model.completionPricePerMillion >= filter.minCompletionPricePerMillion &&
      model.completionPricePerMillion <= filter.maxCompletionPricePerMillion;
  }

  async function updateOpenRouterModelFilter(patch: Partial<OpenRouterModelFilter>) {
    if (!settingsState) return;
    await updateField("openRouterModelFilter", {
      ...settingsState.settings.openRouterModelFilter,
      ...patch
    });
  }

  function numericFilterValue(value: string, fallback: number) {
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
  }

  function defaultOpenRouterModelFilter(): OpenRouterModelFilter {
    return settingsState?.defaults.openRouterModelFilter ?? {
      modalityMode: "textOrVision",
      minPromptPricePerMillion: 0,
      maxPromptPricePerMillion: 2,
      minCompletionPricePerMillion: 0,
      maxCompletionPricePerMillion: 10
    };
  }

  function updateOpenRouterSort(key: OpenRouterSortKey) {
    openRouterSort = {
      key,
      direction: openRouterSort.key === key
        ? openRouterSort.direction === "asc" ? "desc" : "asc"
        : defaultOpenRouterSortDirection(key)
    };
  }

  function sortLabel(key: OpenRouterSortKey) {
    if (openRouterSort.key !== key) return "Sort";
    if (key === "releaseDate") return openRouterSort.direction === "desc" ? "Newest" : "Oldest";
    if (key === "dailyRank") return openRouterSort.direction === "asc" ? "#1 First" : "#20 First";
    return openRouterSort.direction === "asc" ? "Asc" : "Desc";
  }

  function defaultOpenRouterSortDirection(key: OpenRouterSortKey): SortDirection {
    return key === "releaseDate" ? "desc" : "asc";
  }

</script>

{#snippet translationModelPicker(scope: "general" | "models", state: SettingsState)}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="nested-model-picker"
    class:open={openTranslationModelMenu === scope}
    onkeydown={handleModelPickerKeydown}
  >
    <button
      class="nested-model-trigger"
      type="button"
      aria-haspopup="menu"
      aria-expanded={openTranslationModelMenu === scope}
      onclick={() => toggleTranslationModelMenu(scope)}
    >
      <span class:open-router={state.settings.provider === "openRouter"} class="trigger-provider">
        {#if state.settings.provider === "localHyMT2"}<Cpu size={13} />{:else if state.settings.provider === "appleTranslation"}<Languages size={13} />{:else}<Cloud size={13} />{/if}
        {translationModelProviderLabel(state.settings.provider)}
      </span>
      <span class="trigger-model">{translationModelName(state.settings)}</span>
      <ChevronDown size={14} />
    </button>

    {#if openTranslationModelMenu === scope}
      <div class="nested-model-menu" role="menu" aria-label="Translation Model">
        <div class="nested-model-providers" role="group" aria-label="Model providers">
          {#if state.appVariant !== "mas"}
            <!-- The Python local backend cannot run inside the MAS sandbox. -->
            <button
              type="button"
              class:active={activeTranslationModelProvider === "localHyMT2"}
              onmouseenter={() => (activeTranslationModelProvider = "localHyMT2")}
              onclick={() => (activeTranslationModelProvider = "localHyMT2")}
            >
              <Cpu size={14} />
              <span>Local Model</span>
              <ChevronRight size={13} />
            </button>
          {/if}
          <button
            type="button"
            class:active={activeTranslationModelProvider === "appleTranslation"}
            onmouseenter={() => (activeTranslationModelProvider = "appleTranslation")}
            onclick={() => (activeTranslationModelProvider = "appleTranslation")}
          >
            <Languages size={14} />
            <span>Apple Translation</span>
            <ChevronRight size={13} />
          </button>
          <button
            type="button"
            class:active={activeTranslationModelProvider === "openRouter"}
            onmouseenter={() => (activeTranslationModelProvider = "openRouter")}
            onclick={() => (activeTranslationModelProvider = "openRouter")}
          >
            <Cloud size={14} />
            <span>OpenRouter LLM</span>
            <ChevronRight size={13} />
          </button>
        </div>

        <div class="nested-model-options" role="group" aria-label="Models">
          {#if activeTranslationModelProvider === "appleTranslation"}
            <button
              type="button"
              class:selected={translationModelValue(state.settings, state.defaults) === "appleTranslation:apple"}
              onclick={() => chooseTranslationModel("appleTranslation:apple")}
            >
              <span>
                <strong>System Translation</strong>
                <small>Free · offline · languages download on first use</small>
              </span>
              {#if translationModelValue(state.settings, state.defaults) === "appleTranslation:apple"}<Check size={14} />{/if}
            </button>
          {:else if activeTranslationModelProvider === "localHyMT2"}
            <button
              type="button"
              class:selected={translationModelValue(state.settings, state.defaults) === "localHyMT2:default"}
              onclick={() => chooseTranslationModel("localHyMT2:default")}
            >
              <span>
                <strong>Default</strong>
                <small>{localModelLabel(state.defaults.localModelID)}</small>
              </span>
              {#if translationModelValue(state.settings, state.defaults) === "localHyMT2:default"}<Check size={14} />{/if}
            </button>
            {#each state.options.localModels as option}
              <button
                type="button"
                class:selected={translationModelValue(state.settings, state.defaults) === `localHyMT2:${option.value}`}
                onclick={() => chooseTranslationModel(`localHyMT2:${option.value}`)}
              >
                <span>
                  <strong>{option.label}</strong>
                  <small>{option.note ?? "Local runtime"}</small>
                </span>
                {#if translationModelValue(state.settings, state.defaults) === `localHyMT2:${option.value}`}<Check size={14} />{/if}
              </button>
            {/each}
          {:else}
            <button
              type="button"
              class:selected={translationModelValue(state.settings, state.defaults) === "openRouter:default"}
              onclick={() => chooseTranslationModel("openRouter:default")}
            >
              <span>
                <strong>Default</strong>
                <small>{openRouterModelLabel(state.defaults.openRouterTextModel)}</small>
              </span>
              {#if translationModelValue(state.settings, state.defaults) === "openRouter:default"}<Check size={14} />{/if}
            </button>
            {#each visibleOpenRouterModels(state.options.openRouterModels) as option}
              <button
                type="button"
                class:selected={translationModelValue(state.settings, state.defaults) === `openRouter:${option.value}`}
                onclick={() => chooseTranslationModel(`openRouter:${option.value}`)}
              >
                <span>
                  <strong>{option.label}</strong>
                  <small>{formatPrice(option)} · {modelMetaText(option)}</small>
                </span>
                {#if translationModelValue(state.settings, state.defaults) === `openRouter:${option.value}`}<Check size={14} />{/if}
              </button>
            {/each}
          {/if}
        </div>
      </div>
    {/if}
  </div>
{/snippet}

<svelte:window onkeydown={handleSettingsKeydown} />

{#if settingsState}
  <div class="app-frame">
    {#if openTranslationModelMenu}
      <button class="menu-scrim" type="button" aria-label="Close model menu" onclick={closeTranslationModelMenu}></button>
    {/if}
    <aside class="sidebar" aria-label="Settings sections">
      <button class:active={activeSection === "general"} onclick={() => (activeSection = "general")}>
        <SettingsIcon size={15} />
        <span>General</span>
      </button>
      <button class:active={activeSection === "models"} onclick={() => (activeSection = "models")}>
        <Cpu size={15} />
        <span>Models</span>
      </button>
      <button class:active={activeSection === "shortcuts"} onclick={() => (activeSection = "shortcuts")}>
        <Keyboard size={15} />
        <span>Shortcuts</span>
      </button>
      <button class:active={activeSection === "excluded"} onclick={() => (activeSection = "excluded")}>
        <Ban size={15} />
        <span>Excluded Apps</span>
      </button>
      <div class="sidebar-separator"></div>
      <button class:active={activeSection === "advanced"} onclick={() => (activeSection = "advanced")}>
        <SlidersHorizontal size={15} />
        <span>Advanced</span>
      </button>
      <button class:active={activeSection === "info"} onclick={() => (activeSection = "info")}>
        <Info size={15} />
        <span>Info</span>
      </button>
      <button class="reset-all" title="Reset every setting to current code defaults" onclick={resetAll}>
        <RotateCcw size={14} />
        <span>Reset Defaults</span>
      </button>
    </aside>

    <main
      class="content"
      bind:this={contentElement}
      onscroll={() => (contentScrolled = (contentElement?.scrollTop ?? 0) > 0)}
    >
      <header class="content-header" class:scrolled={contentScrolled}>
        <h1>{sectionTitles[activeSection]}</h1>
        <span class:muted={isSaving} class="save-state">{isSaving ? "Saving..." : "Saved"}</span>
      </header>

      {#if notices.length > 0}
        <div class="toast-stack" aria-live="polite">
          {#each notices as notice}
            <article class="toast">
              <strong>{notice.title}</strong>
              <span>{notice.message}</span>
            </article>
          {/each}
        </div>
      {/if}

      {#if activeSection === "general"}
        <section class="pane">
          <h2>Default Behavior</h2>
          <div class="setting-group menu-setting-group">
            <div class="setting-row model-picker-row">
              <span class="setting-copy">
                <strong>Translation Model</strong>
                <span>{translationModelProviderDetail(settingsState.settings)}</span>
              </span>
              {@render translationModelPicker("general", settingsState)}
              <button
                class="reset-row"
                class:visible={settingsState.overrides.provider || settingsState.overrides.localModelID || settingsState.overrides.openRouterTextModel}
                disabled={!settingsState.overrides.provider && !settingsState.overrides.localModelID && !settingsState.overrides.openRouterTextModel}
                title="Reset Translation Model"
                onclick={async () => {
                  closeTranslationModelMenu();
                  await resetField("provider");
                  await resetField("localModelID");
                  await resetField("openRouterTextModel");
                }}
              >
                <RotateCcw size={13} />
              </button>
            </div>

            {#if isOpenRouterTextOnly}
              <div class="setting-row warning-row">
                <div class="warning-content">
                  <TriangleAlert size={14} />
                  <div>
                    <strong>Text-only model:</strong> This model can't read images, so screen context (a screenshot of your screen) won't be sent with translations. Pick a Text + Image model to enable screen context.
                  </div>
                </div>
              </div>
            {/if}

            <label class="setting-row toggle-row">
              <span class="setting-copy">
                <strong>Open at Login</strong>
                <span class="setting-note">{settingsState.loginItem.message}</span>
              </span>
              <input
                class="switch-input"
                type="checkbox"
                role="switch"
                checked={settingsState.loginItem.enabled}
                disabled={!settingsState.loginItem.supported || isUpdatingLoginItem}
                onchange={(event) => toggleLaunchAtLogin(event.currentTarget.checked)}
              />
              <span class="reset-row spacer"></span>
            </label>

            <label class="setting-row">
              <span class="setting-copy">
                <strong>Source Language</strong>
              </span>
              <select
                value={settingsState.settings.sourceLanguage}
                onchange={(event) => updateField("sourceLanguage", event.currentTarget.value)}
              >
                {#each settingsState.options.sourceLanguages as option}
                  <option value={option.value}>{option.label}</option>
                {/each}
              </select>
              <button
                class="reset-row"
                class:visible={settingsState.overrides.sourceLanguage}
                disabled={!settingsState.overrides.sourceLanguage}
                title="Reset Source Language"
                onclick={() => resetField("sourceLanguage")}
              >
                <RotateCcw size={13} />
              </button>
            </label>

            <label class="setting-row">
              <span class="setting-copy">
                <strong>Target Language</strong>
              </span>
              <select
                value={settingsState.settings.targetLanguage}
                onchange={(event) => updateField("targetLanguage", event.currentTarget.value)}
              >
                {#each settingsState.options.targetLanguages as option}
                  <option value={option.value}>{option.label}</option>
                {/each}
              </select>
              <button
                class="reset-row"
                class:visible={settingsState.overrides.targetLanguage}
                disabled={!settingsState.overrides.targetLanguage}
                title="Reset Target Language"
                onclick={() => resetField("targetLanguage")}
              >
                <RotateCcw size={13} />
              </button>
            </label>

            <label class="setting-row">
              <span class="setting-copy">
                <strong>Toast Position</strong>
              </span>
              <select
                value={settingsState.settings.toastPosition}
                onchange={(event) => updateToastPosition(event.currentTarget.value)}
              >
                {#each settingsState.options.toastPositions as option}
                  <option value={option.value}>{option.label}</option>
                {/each}
              </select>
              <button
                class="reset-row"
                class:visible={settingsState.overrides.toastPosition}
                disabled={!settingsState.overrides.toastPosition}
                title="Reset Toast Position"
                onclick={() => resetField("toastPosition")}
              >
                <RotateCcw size={13} />
              </button>
            </label>
          </div>

          <h2>Diagnostics</h2>
          <div class="setting-group">
            <div class="setting-row text-row">
              <span class="setting-copy">
                <strong>Last Result</strong>
              </span>
              <span class="last-result">{lastResult}</span>
              <span class="reset-row spacer"></span>
            </div>
            <div class="action-grid">
              <button onclick={() => runAction("runTextTest")}><Play size={14} />Run Text Test</button>
              <button onclick={() => runAction("translateScreenshot")}><Camera size={14} />Translate Screenshot</button>
              <button onclick={() => runAction("showRequestLogs")}><ScrollText size={14} />Request Logs</button>
            </div>
          </div>
        </section>
      {:else if activeSection === "models"}
        <section class="pane">
          <h2>Active Translation Model</h2>
          <div class="setting-group menu-setting-group">
            <div class="setting-row model-picker-row">
              <span class="setting-copy">
                <strong>Translation Model</strong>
                <span>{translationModelProviderDetail(settingsState.settings)}</span>
              </span>
              {@render translationModelPicker("models", settingsState)}
              <button
                class="reset-row"
                class:visible={settingsState.overrides.provider || settingsState.overrides.localModelID || settingsState.overrides.openRouterTextModel}
                disabled={!settingsState.overrides.provider && !settingsState.overrides.localModelID && !settingsState.overrides.openRouterTextModel}
                title="Reset Translation Model"
                onclick={async () => {
                  closeTranslationModelMenu();
                  await resetField("provider");
                  await resetField("localModelID");
                  await resetField("openRouterTextModel");
                }}
              >
                <RotateCcw size={13} />
              </button>
            </div>
          </div>

          <h2>Local Model Favorites</h2>
          <div class="setting-group">
            {#each settingsState.options.localModels as option}
              <div class="model-row">
                <button
                  class="favorite-button"
                  class:active={settingsState.settings.favoriteLocalModelIDs.includes(option.value)}
                  title="Toggle favorite"
                  onclick={() => toggleFavorite("favoriteLocalModelIDs", option.value)}
                >
                  <Star size={14} />
                </button>
                <div class="model-copy">
                  <strong>{option.label}</strong>
                  <span>{option.note ?? (option.value === settingsState.defaults.localModelID ? "Default" : "Local runtime")}</span>
                </div>
                <button class="inline-action" onclick={() => useLocalModel(option.value)}><Cpu size={13} />Use</button>
              </div>
            {/each}
            <div class="action-grid single">
              <button onclick={() => runAction("showLocalModelSetup")}><ShieldCheck size={14} />Model Setup</button>
            </div>
          </div>

          <h2>OpenRouter API Key</h2>
          <div class="setting-group">
            <div class="setting-row text-row">
              <span class="setting-copy">
                <strong>Status</strong>
                <span>{openRouterAPIKeyState.path}</span>
              </span>
              <span class:ready={openRouterAPIKeyState.configured} class="status-pill">
                <KeyRound size={13} />{openRouterAPIKeyState.configured ? "Configured" : "Not configured"}
              </span>
              <span class="reset-row spacer"></span>
            </div>
            <div class="api-key-row">
              <input
                type="password"
                placeholder={openRouterAPIKeyState.configured ? "Enter a new key to replace the saved key" : "OpenRouter API key"}
                value={openRouterAPIKeyInput}
                oninput={(event) => (openRouterAPIKeyInput = event.currentTarget.value)}
              />
              <button onclick={saveOpenRouterAPIKey}><KeyRound size={13} />Save</button>
              <button onclick={clearOpenRouterAPIKey}>Clear</button>
            </div>
          </div>

          <h2>OpenRouter Models</h2>
          <div class="setting-group">
            <div class="setting-row text-row">
              <span class="setting-copy">
                <strong>Catalog</strong>
                <span>{visibleOpenRouterModels(settingsState.options.openRouterModels).length} shown / {settingsState.options.openRouterModels.length} available</span>
              </span>
              <button
                class="inline-action catalog-refresh"
                disabled={isRefreshingOpenRouterModels}
                onclick={() => refreshOpenRouterModels(false)}
              >
                <Cloud size={13} />{isRefreshingOpenRouterModels ? "Refreshing" : "Refresh"}
              </button>
              <span class="reset-row spacer"></span>
            </div>
            <label class="setting-row">
              <span class="setting-copy">
                <strong>Text Model</strong>
              </span>
              <select
                value={settingsState.settings.openRouterTextModel === settingsState.defaults.openRouterTextModel ? "default" : settingsState.settings.openRouterTextModel}
                onchange={(event) => updateModelField("openRouterTextModel", event.currentTarget.value)}
              >
                <option value="default">Default ({openRouterModelLabel(settingsState.defaults.openRouterTextModel)})</option>
                {#each visibleOpenRouterModels(settingsState.options.openRouterModels) as option}
                  <option value={option.value}>{option.label}</option>
                {/each}
              </select>
              <button
                class="reset-row"
                class:visible={settingsState.overrides.openRouterTextModel}
                disabled={!settingsState.overrides.openRouterTextModel}
                title="Reset Text Model"
                onclick={() => resetField("openRouterTextModel")}
              >
                <RotateCcw size={13} />
              </button>
            </label>
            <label class="setting-row">
              <span class="setting-copy">
                <strong>Vision Model</strong>
              </span>
              <select
                value={settingsState.settings.openRouterVisionModel === settingsState.defaults.openRouterVisionModel ? "default" : settingsState.settings.openRouterVisionModel}
                onchange={(event) => updateModelField("openRouterVisionModel", event.currentTarget.value)}
              >
                <option value="default">Default ({openRouterModelLabel(settingsState.defaults.openRouterVisionModel)})</option>
                {#each visibleOpenRouterModels(settingsState.options.openRouterModels).filter((option) => option.modalities.includes("image")) as option}
                  <option value={option.value}>{option.label}</option>
                {/each}
              </select>
              <button
                class="reset-row"
                class:visible={settingsState.overrides.openRouterVisionModel}
                disabled={!settingsState.overrides.openRouterVisionModel}
                title="Reset Vision Model"
                onclick={() => resetField("openRouterVisionModel")}
              >
                <RotateCcw size={13} />
              </button>
            </label>
            <div class="openrouter-filter-panel" aria-label="OpenRouter model filters">
              <label>
                <span>Mode</span>
                <select
                  value={settingsState.settings.openRouterModelFilter.modalityMode}
                  onchange={(event) => updateOpenRouterModelFilter({ modalityMode: event.currentTarget.value as OpenRouterModelFilter["modalityMode"] })}
                >
                  <option value="textOrVision">Text / Vision</option>
                  <option value="all">All text-output</option>
                </select>
              </label>
              <label>
                <span>Input min $/1M</span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={settingsState.settings.openRouterModelFilter.minPromptPricePerMillion}
                  onchange={(event) => updateOpenRouterModelFilter({
                    minPromptPricePerMillion: numericFilterValue(
                      event.currentTarget.value,
                      defaultOpenRouterModelFilter().minPromptPricePerMillion
                    )
                  })}
                />
              </label>
              <label>
                <span>Input max $/1M</span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={settingsState.settings.openRouterModelFilter.maxPromptPricePerMillion}
                  onchange={(event) => updateOpenRouterModelFilter({
                    maxPromptPricePerMillion: numericFilterValue(
                      event.currentTarget.value,
                      defaultOpenRouterModelFilter().maxPromptPricePerMillion
                    )
                  })}
                />
              </label>
              <label>
                <span>Output min $/1M</span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={settingsState.settings.openRouterModelFilter.minCompletionPricePerMillion}
                  onchange={(event) => updateOpenRouterModelFilter({
                    minCompletionPricePerMillion: numericFilterValue(
                      event.currentTarget.value,
                      defaultOpenRouterModelFilter().minCompletionPricePerMillion
                    )
                  })}
                />
              </label>
              <label>
                <span>Output max $/1M</span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={settingsState.settings.openRouterModelFilter.maxCompletionPricePerMillion}
                  onchange={(event) => updateOpenRouterModelFilter({
                    maxCompletionPricePerMillion: numericFilterValue(
                      event.currentTarget.value,
                      defaultOpenRouterModelFilter().maxCompletionPricePerMillion
                    )
                  })}
                />
              </label>
              <button
                class="inline-action"
                disabled={!settingsState.overrides.openRouterModelFilter}
                onclick={() => resetField("openRouterModelFilter")}
              >
                <RotateCcw size={13} />Reset
              </button>
            </div>
            <div class="openrouter-sort-bar" role="group" aria-label="Sort models">
              <span class="sort-caption">Sort by</span>
              <button type="button" class:active={openRouterSort.key === "model"} onclick={() => updateOpenRouterSort("model")}>
                Model <ArrowUpDown size={11} /><span class="sort-state">{sortLabel("model")}</span>
              </button>
              <button type="button" class:active={openRouterSort.key === "releaseDate"} onclick={() => updateOpenRouterSort("releaseDate")}>
                Release <ArrowUpDown size={11} /><span class="sort-state">{sortLabel("releaseDate")}</span>
              </button>
              <button type="button" class:active={openRouterSort.key === "dailyRank"} onclick={() => updateOpenRouterSort("dailyRank")}>
                Top <ArrowUpDown size={11} /><span class="sort-state">{sortLabel("dailyRank")}</span>
              </button>
              <button type="button" class:active={openRouterSort.key === "inputPrice"} onclick={() => updateOpenRouterSort("inputPrice")}>
                Input <ArrowUpDown size={11} /><span class="sort-state">{sortLabel("inputPrice")}</span>
              </button>
              <button type="button" class:active={openRouterSort.key === "outputPrice"} onclick={() => updateOpenRouterSort("outputPrice")}>
                Output <ArrowUpDown size={11} /><span class="sort-state">{sortLabel("outputPrice")}</span>
              </button>
              <button type="button" class:active={openRouterSort.key === "context"} onclick={() => updateOpenRouterSort("context")}>
                Context <ArrowUpDown size={11} /><span class="sort-state">{sortLabel("context")}</span>
              </button>
            </div>
            {#each visibleOpenRouterModels(settingsState.options.openRouterModels) as model}
              <div
                class="model-row openrouter-row"
                class:selected-model={settingsState.settings.provider === "openRouter" && settingsState.settings.openRouterTextModel === model.value}
                class:top-ranked={isDailyTopModel(model)}
              >
                <button
                  class="favorite-button"
                  class:active={settingsState.settings.favoriteOpenRouterModels.includes(model.value)}
                  title="Toggle favorite"
                  onclick={() => toggleFavorite("favoriteOpenRouterModels", model.value)}
                >
                  <Star size={14} />
                </button>
                <div class="model-copy">
                  <strong>{model.label}</strong>
                  <span class="model-id">{model.value}</span>
                  <span>{modalityText(model)} · {formatContextWindow(model.contextWindow)} context · {model.releaseDate}</span>
                  {#if model.isRecommended || model.isFree || model.isReasoning || isDailyTopModel(model)}
                    <div class="model-badges">
                      {#if isDailyTopModel(model)}<em class="top-rank">Top #{model.dailyTokenRank}</em>{/if}
                      {#if model.isRecommended}<em>Recommended</em>{/if}
                      {#if model.isFree}<em class="free-event">Free event</em>{/if}
                      {#if model.isReasoning}<em>Reasoning</em>{/if}
                    </div>
                  {/if}
                </div>
                <div class="openrouter-price">
                  <span>In {formatUnitPrice(model.promptPricePerMillion)}</span>
                  <span>Out {formatUnitPrice(model.completionPricePerMillion)}</span>
                </div>
                <div class="model-actions">
                  <button class="inline-action primary-use" onclick={() => useOpenRouterTextModel(model.value)}><Cloud size={13} />Use this</button>
                  {#if model.modalities.includes("image")}
                    <button class="inline-action" onclick={() => useOpenRouterVisionModel(model.value)}>Vision</button>
                  {/if}
                </div>
              </div>
            {/each}
          </div>
        </section>
      {:else if activeSection === "shortcuts"}
        <section class="pane">
          <h2>Global Shortcuts</h2>
          <div class="setting-group">
            <div class="setting-row">
              <span class="setting-copy">
                <strong>Clipboard Translation</strong>
                <span>Cmd+C twice</span>
              </span>
              <kbd>⌘ C ×2</kbd>
              <span class="reset-row spacer"></span>
            </div>
            <div class="setting-row">
              <span class="setting-copy">
                <strong>Screenshot Translation</strong>
                <span>Shift+Cmd+2</span>
              </span>
              <kbd>⇧ ⌘ 2</kbd>
              <span class="reset-row spacer"></span>
            </div>
          </div>

          <h2>Permissions</h2>
          <div class="setting-group">
            <div class="setting-row">
              <span class="setting-copy">
                <strong>Keyboard</strong>
              </span>
              <span class:ready={settingsState.permissions.keyboard} class="status-pill">
                {settingsState.permissions.keyboard ? "Ready" : "Not granted"}
              </span>
              <span class="reset-row spacer"></span>
            </div>
            <div class="setting-row">
              <span class="setting-copy">
                <strong>Keyboard Cursor</strong>
                <span>Accessibility permission for caret-anchored popovers</span>
              </span>
              <span class:ready={settingsState.permissions.accessibility} class="status-pill">
                {settingsState.permissions.accessibility ? "Ready" : "Not granted"}
              </span>
              <span class="reset-row spacer"></span>
            </div>
            <div class="setting-row">
              <span class="setting-copy">
                <strong>Screen Recording</strong>
              </span>
              <span class:ready={settingsState.permissions.screen} class="status-pill">
                {settingsState.permissions.screen ? "Ready" : "Not granted"}
              </span>
              <span class="reset-row spacer"></span>
            </div>
            <div class="action-grid single">
              <button onclick={() => runAction("openPermissionHelper")}><ShieldCheck size={14} />Permission Helper</button>
            </div>
          </div>
        </section>
      {:else if activeSection === "excluded"}
        <section class="pane">
          <h2>Current App Contract</h2>
          <div class="setting-group">
            <div class="setting-row text-row">
              <span class="setting-copy">
                <strong>Excluded Apps</strong>
                <span>No persisted exclusion setting exists in the Swift app.</span>
              </span>
              <span class="last-result">None</span>
              <span class="reset-row spacer"></span>
            </div>
          </div>
        </section>
      {:else if activeSection === "advanced"}
        <section class="pane">
          <h2>Local Runtime</h2>
          <div class="setting-group">
            <label class="setting-row">
              <span class="setting-copy">
                <strong>Local Backend Script</strong>
                <span class="setting-note">Optional override for the local translation runner. Leave blank to use the bundled script or the selected model's backend.</span>
              </span>
              <input
                placeholder="Automatic"
                spellcheck={false}
                value={settingsState.settings.localHyMT2BackendPath ?? ""}
                onblur={(event) => updateNullableField("localHyMT2BackendPath", event.currentTarget.value)}
              />
              <button
                class="reset-row"
                class:visible={settingsState.overrides.localHyMT2BackendPath}
                disabled={!settingsState.overrides.localHyMT2BackendPath}
                title="Reset Backend Path"
                onclick={() => resetField("localHyMT2BackendPath")}
              >
                <RotateCcw size={13} />
              </button>
            </label>
            <label class="setting-row">
              <span class="setting-copy">
                <strong>Custom Model Catalog</strong>
                <span class="setting-note">JSON file that adds local model choices. Blank uses ~/.config/cctrans/local-models.json when present.</span>
              </span>
              <input
                placeholder="~/.config/cctrans/local-models.json"
                spellcheck={false}
                value={settingsState.settings.customLocalModelsPath ?? ""}
                onblur={(event) => updateNullableField("customLocalModelsPath", event.currentTarget.value)}
              />
              <button
                class="reset-row"
                class:visible={settingsState.overrides.customLocalModelsPath}
                disabled={!settingsState.overrides.customLocalModelsPath}
                title="Reset Custom Models JSON"
                onclick={() => resetField("customLocalModelsPath")}
              >
                <RotateCcw size={13} />
              </button>
            </label>
          </div>
        </section>
      {:else}
        <section class="pane">
          <h2>Storage</h2>
          <div class="setting-group">
            <div class="setting-row text-row">
              <span class="setting-copy">
                <strong>Override Store</strong>
                <span>{settingsState.storagePath}</span>
              </span>
              <span class="last-result">Code defaults apply when no override exists.</span>
              <span class="reset-row spacer"></span>
            </div>
          </div>

          <h2>Provider Status</h2>
          <div class="setting-group">
            <div class="setting-row">
              <span class="setting-copy">
                <strong>API</strong>
              </span>
              <span class="api-status"><CheckCircle2 size={14} />Configured externally</span>
              <span class="reset-row spacer"></span>
            </div>
          </div>
        </section>
      {/if}
    </main>

  </div>
{:else}
  <div class="loading">Loading settings...</div>
{/if}

<style>
  .warning-row {
    grid-template-columns: 1fr;
    background: rgba(255, 149, 0, 0.05);
  }
  .warning-content {
    display: flex;
    gap: 8px;
    align-items: flex-start;
    color: var(--favorite-ink);
    font-size: 11px;
    line-height: 1.35;
  }
  .warning-content strong {
    font-weight: 650;
  }
  :global(.warning-content svg) {
    flex-shrink: 0;
    margin-top: 1px;
  }
</style>

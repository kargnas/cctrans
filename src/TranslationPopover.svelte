<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { onMount } from "svelte";
  import { Check, Copy, Cpu, Eye, Languages, ShieldCheck, TriangleAlert, X } from "@lucide/svelte";
  import { fallbackTranslationState, type ShowToastResult, type TranslationMode, type TranslationPreviewState } from "./lib/translation";
  import { fallbackState, type OpenRouterModelOption, type SettingsState, type TranslationProvider } from "./lib/settings";

  const params = new URLSearchParams(window.location.search);
  const debugMode = params.get("debug") === "1";
  const requestedMode = modeFromQuery(params.get("mode"));
  type ToastRefreshPayload = { requestSequence: number; shown?: ShowToastResult | null };
  let arrowAbove = $state(params.get("placement") === "above");
  let arrowHidden = $state(params.get("placement") === "none");
  let anchorBottom = $state(params.get("anchor") === "bottom");

  // Must match `.translation-stage` vertical padding in app.css so the resized window
  // leaves exactly enough room for the bubble plus its caret arrow on either side.
  const stagePadding = 18;
  const appleTranslationModelID = "apple/translation";

  let isTauri = $state(false);
  let bubbleEl = $state<HTMLDivElement | undefined>();
  let translationTextEl = $state<HTMLParagraphElement | undefined>();
  let preview = $state<TranslationPreviewState>(fallbackTranslationState);
  let visibleMode = $state<TranslationMode>(requestedMode ?? fallbackTranslationState.mode);
  let copied = $state(false);
  let modelOptions = $state<PreviewModelOption[]>([]);
  let targetLanguageOptions = $state<PreviewLanguageOption[]>([]);
  let selectedModelValue = $state("");
  let persistedModelValue = $state("");
  let selectedTargetLanguage = $state("");
  let isChangingModel = $state(false);
  let isChangingLanguage = $state(false);
  let copyResetTimer: number | undefined;
  let dismissTimer: number | undefined;
  let countdownInterval: number | undefined;
  let resultPollTimer: number | undefined;
  let moveSaveTimer: number | undefined;
  let lastShownSequence = 0;
  let windowMoveUnlisten: (() => void) | undefined;
  let hoverUnlisten: (() => void) | undefined;
  let dismissRequestUnlisten: (() => void) | undefined;
  let refreshUnlisten: (() => void) | undefined;
  let pendingMovedPosition: WindowPosition | null = null;
  // onMoved fires for programmatic set_position (every show/resize) too, not just user drags.
  // Persist only after a real drag so the app's own repositioning never overwrites toast_position.
  let userInitiatedMove = false;
  let countdownStartedAt = $state(0);
  let countdownStartedRemaining = $state(fallbackTranslationState.toastDuration);
  let countdownDuration = $state(fallbackTranslationState.toastDuration);
  let countdownRemaining = $state(fallbackTranslationState.toastDuration);
  let countdownPaused = $state(false);
  let pointerOverToast = false;

  const uiStrings = {
    translating: "Translating...",
    translatingClipboard: "Translating clipboard text.",
    translatingScreenshot: "Translating selected screenshot.",
    error: "Error",
    translationFailed: "Translation failed.",
    showOriginal: "Original",
    showTranslation: "Translation",
    cancel: "Cancel",
    close: "Close",
    copyCurrent: "Copy",
    copied: "Copied",
    requestPermission: "Request Permission"
  };
  const targetLanguage = $derived(preview.targetLanguage);
  const modelName = $derived(preview.model.trim() || preview.providerTitle.trim() || "Unknown model");
  const modelWarning = $derived(preview.modelWarning?.trim() ?? "");
  const costLabel = $derived(formatCostCredits(preview.costCredits));
  const modelMetadata = $derived([modelName, costLabel].filter(Boolean).join(" · "));
  const bodyText = $derived(visibleMode === "original" ? preview.originalText : preview.translatedText);
  const loadingMessage = $derived(
    preview.originalText === "[screen screenshot]" || preview.originalText === "[selected screenshot]"
      ? uiStrings.translatingScreenshot
      : uiStrings.translatingClipboard
  );
  const compactMode = $derived(visibleMode === "translated" || visibleMode === "original");
  const tallMode = $derived(debugMode || visibleMode === "loading" || visibleMode === "error");
  const showCountdown = $derived(!debugMode && visibleMode !== "loading");
  const countdownLabel = $derived(`${countdownRemaining.toFixed(1)}s`);
  const countdownProgressValue = $derived(Math.max(0, Math.min(1, countdownRemaining / countdownDuration)));
  const countdownProgress = $derived(`${countdownProgressValue * 100}%`);
  const screenRecordingPermissionError = $derived(
    preview.permissionAction === "screenRecording" ||
      (preview.errorText ?? "").toLowerCase().includes("screen recording permission")
  );

  type PreviewModelOption = {
    label: string;
    value: string;
    provider: TranslationProvider;
    modelId: string;
  };

  type PreviewLanguageOption = {
    label: string;
    value: string;
  };

  type WindowPosition = {
    x: number;
    y: number;
  };

  onMount(() => {
    isTauri = "__TAURI_INTERNALS__" in window;
    let disposed = false;
    applySettingsState(fallbackState);
    if (isTauri) {
      void loadPreview();
      void getCurrentWindow()
        .onMoved(({ payload }) => queueMovedPosition(payload))
        .then((unlisten) => {
          if (disposed) {
            unlisten();
          } else {
            windowMoveUnlisten = unlisten;
          }
        })
        .catch(() => {
          // Move persistence is best-effort when window events are unavailable.
        });
      // A background non-activating panel never gets DOM hover events, so Rust hit-tests the
      // global cursor and tells us when it crosses the toast frame to pause/resume the countdown.
      void getCurrentWindow()
        .listen<boolean>("toast-hover", ({ payload }) => {
          pointerOverToast = payload;
          if (payload) pauseAutoDismiss();
          else resumeAutoDismiss();
        })
        .then((unlisten) => {
          if (disposed) {
            unlisten();
          } else {
            hoverUnlisten = unlisten;
          }
        })
        .catch(() => {
          // Hover pause is best-effort when window events are unavailable.
        });
      // Rust hit-tests outside clicks globally because the toast is non-activating.
      void getCurrentWindow()
        .listen("toast-dismiss-request", () => {
          void closePopover();
        })
        .then((unlisten) => {
          if (disposed) {
            unlisten();
          } else {
            dismissRequestUnlisten = unlisten;
          }
        })
        .catch(() => {
          // Outside-click dismissal is best-effort when window events are unavailable.
        });
      // The native watcher (Rust) detects a new/updated translation while this hidden WebView's JS
      // timers are suspended, shows the window, then fires this so the now-visible page re-renders.
      // allowShow:false because the watcher already showed it; we only sync state + placement here.
      void getCurrentWindow()
        .listen<ToastRefreshPayload>("toast-refresh", ({ payload }) => {
          if (payload.shown) {
            lastShownSequence = payload.requestSequence;
            arrowAbove = payload.shown.arrow === "above";
            arrowHidden = payload.shown.arrow === "none";
            anchorBottom = payload.shown.anchorBottom;
          }
          void loadPreview({ allowShow: false });
        })
        .then((unlisten) => {
          if (disposed) {
            unlisten();
          } else {
            refreshUnlisten = unlisten;
          }
        })
        .catch(() => {
          // Watcher-driven refresh is best-effort when window events are unavailable.
        });
      // Backup for a dropped toast-refresh event: when the window becomes visible the WebView
      // un-suspends, so re-read the authoritative state once to recover any missed update.
      document.addEventListener("visibilitychange", onVisibilityChange);
    }
    return () => {
      disposed = true;
      clearAutoDismiss();
      clearCountdown();
      clearCopyReset();
      stopResultPolling();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      windowMoveUnlisten?.();
      hoverUnlisten?.();
      dismissRequestUnlisten?.();
      refreshUnlisten?.();
      flushMovedPosition();
    };
  });

  $effect(() => {
    void bodyText;
    void visibleMode;
    void modelMetadata;
    void modelWarning;
    void preview.requestSequence;
    if (!isTauri || !bubbleEl) return;
    const frame = requestAnimationFrame(() => {
      syncWindowHeight();
    });
    return () => cancelAnimationFrame(frame);
  });

  $effect(() => {
    void bodyText;
    const el = translationTextEl;
    if (!el || visibleMode !== "translated") return;
    // Decide before the DOM grows: follow the bottom so each streamed chunk stays visible, but if
    // the user scrolled up to re-read, leave their position untouched.
    const stick = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    if (!stick) return;
    const frame = requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight;
    });
    return () => cancelAnimationFrame(frame);
  });

  function syncWindowHeight() {
    if (!isTauri || !bubbleEl) return;
    const height = bubbleEl.offsetHeight + stagePadding * 2;
    void invoke("resize_translation_preview", { height, anchorBottom }).catch(() => {
      // Window resize is best-effort; a stale fixed size still shows the translation.
    });
  }

  async function maybeShowForSequence() {
    const seq = preview.requestSequence ?? 0;
    // Sequence 0 means the legacy throwaway window (already visible); only a persistent reused
    // window needs an explicit per-translation show, signalled by Swift bumping the sequence.
    if (!isTauri || seq === 0 || seq === lastShownSequence) return;
    lastShownSequence = seq;
    // The upcoming show repositions the window programmatically; do not let that look like a drag.
    userInitiatedMove = false;
    try {
      const result = await invoke<ShowToastResult>("show_translation_toast");
      arrowAbove = result.arrow === "above";
      arrowHidden = result.arrow === "none";
      anchorBottom = result.anchorBottom;
    } catch {
      // Show is best-effort; a stale position still surfaces the translation.
    }
  }

  function onVisibilityChange() {
    if (!document.hidden) {
      void loadPreview({ allowShow: false });
    }
  }

  async function loadPreview(options: { allowShow?: boolean } = {}) {
    // The native watcher (Rust) owns showing the window, so refreshes it triggers pass allowShow:false
    // to avoid a redundant JS show that would recompute placement and reset the dismiss countdown.
    const allowShow = options.allowShow ?? true;
    try {
      preview = await invoke<TranslationPreviewState>("load_translation_preview");
      // The state file is authoritative: if the result already landed before mount, skip loading.
      visibleMode = requestedMode === "loading" && preview.mode !== "loading" ? preview.mode : (requestedMode ?? preview.mode);
    } catch {
      preview = fallbackTranslationState;
      visibleMode = requestedMode ?? "translated";
    }
    if (allowShow) void maybeShowForSequence();
    if (isTauri) {
      await loadModelOptions();
    } else {
      syncSelectedModel();
    }
    scheduleAutoDismiss();
    if (isTauri && !debugMode) {
      startResultPolling();
    }
  }

  // The state file is the single source of truth. Polling never stops while the toast lives, so a
  // fresh Cmd+C that rewrites the file (a retry during cold start) is absorbed by this same window
  // instead of spawning a second helper whose launch would pkill and flash-kill the first toast.
  function startResultPolling() {
    stopResultPolling();
    resultPollTimer = window.setInterval(async () => {
      let next: TranslationPreviewState;
      try {
        next = await invoke<TranslationPreviewState>("load_translation_preview");
      } catch {
        return;
      }
      const changed =
        next.mode !== preview.mode ||
        next.translatedText !== preview.translatedText ||
        next.errorText !== preview.errorText ||
        next.originalText !== preview.originalText ||
        next.targetLanguage !== preview.targetLanguage ||
        next.providerTitle !== preview.providerTitle ||
        next.model !== preview.model ||
        next.costCredits !== preview.costCredits ||
        (next.requestSequence ?? 0) !== (preview.requestSequence ?? 0);
      if (!changed) return;
      preview = next;
      void maybeShowForSequence();
      visibleMode = next.mode === "error" ? "error" : next.mode === "original" ? "original" : next.mode === "loading" ? "loading" : "translated";
      syncSelectedModel();
      syncSelectedTargetLanguage();
      scheduleAutoDismiss();
    }, 200);
  }

  function stopResultPolling() {
    if (resultPollTimer !== undefined) {
      window.clearInterval(resultPollTimer);
      resultPollTimer = undefined;
    }
  }

  async function loadModelOptions() {
    try {
      applySettingsState(await invoke<SettingsState>("load_settings"));
    } catch {
      applySettingsState(fallbackState);
    }
  }

  function applySettingsState(state: SettingsState) {
    const providerValues = new Set(state.options.providers.map((option) => option.value));
    const favoriteOpenRouterModels = state.options.openRouterModels.filter(
      (option) =>
        option.value === state.settings.openRouterTextModel ||
        state.settings.favoriteOpenRouterModels.includes(option.value)
    );
    modelOptions = [
      ...(providerValues.has("localHyMT2")
        ? state.options.localModels.map((option) => ({
            label: option.label,
            value: `localHyMT2:${option.value}`,
            provider: "localHyMT2" as const,
            modelId: option.value
          }))
        : []),
      ...(providerValues.has("appleTranslation")
        ? [
            {
              label: "Apple Translation",
              value: `appleTranslation:${appleTranslationModelID}`,
              provider: "appleTranslation" as const,
              modelId: appleTranslationModelID
            }
          ]
        : []),
      ...(providerValues.has("openRouter")
        ? favoriteOpenRouterModels.map((option) => ({
            label: openRouterPreviewModelLabel(option),
            value: `openRouter:${option.value}`,
            provider: "openRouter" as const,
            modelId: option.value
          }))
        : [])
    ];
    targetLanguageOptions = state.options.targetLanguages;
    persistedModelValue = modelValueForSettings(state);
    syncSelectedModel();
    syncSelectedTargetLanguage();
  }

  function openRouterPreviewModelLabel(option: OpenRouterModelOption) {
    if (!option.modalities.includes("image") || /\bvision\b/i.test(option.label)) {
      return option.label;
    }
    return `${option.label} (Vision)`;
  }

  function modelValueForSettings(state: SettingsState) {
    const modelId = modelIdForSettings(state);
    return `${state.settings.provider}:${modelId}`;
  }

  function modelIdForSettings(state: SettingsState) {
    if (state.settings.provider === "openRouter") return state.settings.openRouterTextModel;
    if (state.settings.provider === "appleTranslation") return appleTranslationModelID;
    return state.settings.localModelID;
  }

  function syncSelectedModel() {
    selectedModelValue =
      modelOptions.find((option) => option.value === persistedModelValue)?.value ??
      modelOptions.find((option) => previewModelMatchesOption(option, preview.model))?.value ??
      modelOptions[0]?.value ??
      "";
  }

  function previewModelMatchesOption(option: PreviewModelOption, model: string) {
    return option.label === model || option.label.replace(/ \(Vision\)$/, "") === model || option.modelId === model;
  }

  function syncSelectedTargetLanguage() {
    selectedTargetLanguage =
      targetLanguageOptions.find((option) => option.value === preview.targetLanguage)?.value ??
      preview.targetLanguage ??
      targetLanguageOptions[0]?.value ??
      "";
  }

  function modeFromQuery(value: string | null): TranslationMode | null {
    if (value === "loading" || value === "translated" || value === "original" || value === "error") {
      return value;
    }
    return null;
  }

  function formatCostCredits(value: number | null | undefined) {
    if (value === null || value === undefined) return "";
    const fixed = value < 0.0001 ? value.toFixed(8) : value.toFixed(6);
    const trimmed = fixed.replace(/\.?0+$/, "");
    return `Cost ${trimmed || "0"} credits`;
  }

  async function copyText() {
    await navigator.clipboard?.writeText(bodyText);
    markCopied();
  }

  function markCopied() {
    clearCopyReset();
    copied = true;
    copyResetTimer = window.setTimeout(() => {
      copied = false;
      copyResetTimer = undefined;
    }, 1200);
  }

  function clearCopyReset() {
    if (copyResetTimer !== undefined) {
      window.clearTimeout(copyResetTimer);
      copyResetTimer = undefined;
    }
  }

  function toggleOriginal() {
    visibleMode = visibleMode === "original" ? "translated" : "original";
  }

  async function selectModel(event: Event) {
    const value = event.currentTarget instanceof HTMLSelectElement ? event.currentTarget.value : "";
    const option = modelOptions.find((candidate) => candidate.value === value);
    if (!option || option.value === selectedModelValue) return;

    selectedModelValue = value;
    isChangingModel = true;
    const previousMode = visibleMode;
    visibleMode = "loading";
    clearAutoDismiss();
    clearCountdown();

    try {
      if (isTauri) {
        preview = await invoke<TranslationPreviewState>("translate_preview_to_model", {
          provider: option.provider,
          modelId: option.modelId
        });
      } else {
        preview = {
          ...preview,
          providerTitle: providerTitleForOption(option),
          model: option.label,
          translatedText: `${preview.originalText} (${option.label})`
        };
      }
      visibleMode = preview.mode === "error" ? "error" : "translated";
      await loadModelOptions();
    } catch (error) {
      preview = {
        ...preview,
        mode: "error",
        providerTitle: providerTitleForOption(option),
        model: option.label,
        errorText: error instanceof Error ? error.message : String(error)
      };
      visibleMode = "error";
    } finally {
      isChangingModel = false;
      if (visibleMode === "loading") {
        visibleMode = previousMode;
      }
      syncSelectedModel();
      scheduleAutoDismiss();
    }
  }

  async function selectTargetLanguage(event: Event) {
    const value = event.currentTarget instanceof HTMLSelectElement ? event.currentTarget.value : "";
    const option = targetLanguageOptions.find((candidate) => candidate.value === value);
    if (!option || option.value === preview.targetLanguage) return;

    selectedTargetLanguage = option.value;
    isChangingLanguage = true;
    const previousMode = visibleMode;
    visibleMode = "loading";
    clearAutoDismiss();
    clearCountdown();

    try {
      if (isTauri) {
        preview = await invoke<TranslationPreviewState>("translate_preview_to_language", {
          targetLanguage: option.value
        });
      } else {
        preview = {
          ...preview,
          targetLanguage: option.value,
          translatedText: `${preview.originalText} (${option.label})`
        };
      }
      visibleMode = preview.mode === "error" ? "error" : "translated";
      await loadModelOptions();
    } catch (error) {
      preview = {
        ...preview,
        mode: "error",
        targetLanguage: option.value,
        errorText: error instanceof Error ? error.message : String(error)
      };
      visibleMode = "error";
    } finally {
      isChangingLanguage = false;
      if (visibleMode === "loading") {
        visibleMode = previousMode;
      }
      syncSelectedTargetLanguage();
      scheduleAutoDismiss();
    }
  }

  function providerTitleForOption(option: PreviewModelOption) {
    if (option.provider === "openRouter") return "OpenRouter LLM";
    if (option.provider === "appleTranslation") return "Apple Translation";
    return "Local Model";
  }

  async function startDragging(event: MouseEvent) {
    const target = event.target instanceof Element ? event.target : null;
    if (!isTauri || event.button !== 0 || target?.closest("button, select")) return;
    // A scrollable result area owns its own scrollbar and text selection. Starting a window drag from
    // it hijacks the scrollbar thumb (the whole window moves instead of scrolling), so let those clicks
    // through — the window still drags from the surrounding chrome. Only skip when it actually overflows:
    // short results stay draggable from the text, and macOS overlay scrollbars give no usable hit-test
    // (they float over the content), so element-level detection is the reliable signal.
    const scrollable = target?.closest(".translation-text");
    if (scrollable instanceof HTMLElement && scrollable.scrollHeight > scrollable.clientHeight) return;
    try {
      userInitiatedMove = true;
      await getCurrentWindow().startDragging();
    } catch {
      // Dragging is best-effort in browser preview and unsupported shells.
    }
  }

  function queueMovedPosition(position: WindowPosition) {
    if (!userInitiatedMove) return;
    if (!Number.isFinite(position.x) || !Number.isFinite(position.y)) return;
    pendingMovedPosition = position;
    if (moveSaveTimer !== undefined) {
      window.clearTimeout(moveSaveTimer);
    }
    moveSaveTimer = window.setTimeout(() => {
      void saveMovedPosition();
    }, 180);
  }

  function flushMovedPosition() {
    if (moveSaveTimer !== undefined) {
      window.clearTimeout(moveSaveTimer);
      moveSaveTimer = undefined;
    }
    if (pendingMovedPosition) {
      void saveMovedPosition();
    }
  }

  async function saveMovedPosition() {
    const position = pendingMovedPosition;
    pendingMovedPosition = null;
    moveSaveTimer = undefined;
    if (!isTauri || !position) return;
    try {
      await invoke("save_translation_preview_position", { position });
    } catch {
      // Drag persistence should not block closing or translation controls.
    }
  }

  async function closePopover() {
    if (!isTauri) return;
    try {
      await invoke("close_translation_preview");
    } catch {
      await getCurrentWindow().close();
    }
  }

  async function cancelLoading() {
    if (debugMode) {
      visibleMode = "translated";
      return;
    }
    await closePopover();
  }

  async function requestScreenRecordingPermission() {
    if (!isTauri) return;
    try {
      await invoke("open_screen_recording_settings");
    } finally {
      await closePopover();
    }
  }

  function scheduleAutoDismiss() {
    clearAutoDismiss();
    clearCountdown();
    if (debugMode || visibleMode === "loading") return;

    countdownDuration = dismissDurationForText(bodyText);
    countdownRemaining = countdownDuration;
    countdownStartedRemaining = countdownDuration;
    if (pointerOverToast) {
      countdownPaused = true;
      return;
    }
    startCountdown(countdownRemaining);
  }

  function startCountdown(duration: number) {
    countdownPaused = false;
    countdownStartedAt = performance.now();
    countdownStartedRemaining = Math.max(0, duration);
    countdownInterval = window.setInterval(updateCountdown, 100);
    dismissTimer = window.setTimeout(() => {
      void closePopover();
    }, countdownStartedRemaining * 1000);
  }

  function clearAutoDismiss() {
    if (dismissTimer !== undefined) {
      window.clearTimeout(dismissTimer);
      dismissTimer = undefined;
    }
  }

  function pauseAutoDismiss() {
    if (debugMode || visibleMode === "loading") return;
    clearAutoDismiss();
    clearCountdown();
    countdownRemaining = countdownDuration;
    countdownStartedRemaining = countdownDuration;
    countdownPaused = true;
  }

  function resumeAutoDismiss() {
    clearAutoDismiss();
    clearCountdown();
    if (debugMode || visibleMode === "loading") return;
    if (countdownRemaining <= 0) {
      void closePopover();
      return;
    }
    startCountdown(countdownRemaining);
  }

  function dismissDurationForText(text: string) {
    const estimatedLines = Math.max(1, Math.ceil(text.length / 28));
    if (estimatedLines < 5) return 4;
    return Math.min(10, 4 + estimatedLines - 4);
  }

  function clearCountdown() {
    if (countdownInterval !== undefined) {
      window.clearInterval(countdownInterval);
      countdownInterval = undefined;
    }
  }

  function updateCountdown() {
    const elapsed = (performance.now() - countdownStartedAt) / 1000;
    countdownRemaining = Math.max(0, countdownStartedRemaining - elapsed);
    if (countdownRemaining <= 0) {
      clearCountdown();
    }
  }

</script>

<main class="translation-stage" class:debug={debugMode} class:tall={tallMode} aria-label="Translation popup">
  <div
    bind:this={bubbleEl}
    class="translation-bubble"
    class:above={arrowAbove}
    class:no-arrow={arrowHidden}
    class:compact={compactMode}
    class:error={visibleMode === "error"}
    role="dialog"
    aria-label="Translation result"
    tabindex="-1"
    onmousedown={startDragging}
  >
    <div class="translation-bubble-inner">
      {#if visibleMode === "loading"}
        <div class="loading-title">
          <span class="status-dot"></span>
          <span>{uiStrings.translating}</span>
        </div>
        <p class="copying">{loadingMessage}</p>
        <div class="progress-track" aria-hidden="true"><span class="progress-fill"></span></div>
        <footer class="bubble-footer">
          <div class="footer-meta">
            <span class="language"><Languages size={14} /><span class="language-text">{targetLanguage}</span></span>
            {#if modelMetadata}<span class="model-label">{modelMetadata}</span>{/if}
          </div>
          <div class="action-row">
            <button class="icon-button" aria-label={uiStrings.cancel} onclick={cancelLoading}><X size={16} /></button>
          </div>
        </footer>
      {:else if visibleMode === "error"}
        <div class="loading-title error-title">
          <span class="status-dot"></span>
          <span>{uiStrings.error}</span>
        </div>
        <p class="copying">{preview.errorText ?? uiStrings.translationFailed}</p>
        <div class="model-meta-strip" class:warn={modelWarning.length > 0}>
          <span class="model-meta-main"><Cpu size={12} /><span>{modelMetadata}</span></span>
          {#if modelWarning}
            <span class="model-warning"><TriangleAlert size={11} />{modelWarning}</span>
          {/if}
        </div>
        <footer class="bubble-footer error-footer">
          <label class="language-select-shell" aria-label="Target language">
            <Languages size={14} />
            <select class="language-select" aria-label="Target language" value={selectedTargetLanguage} onchange={selectTargetLanguage} disabled={isChangingLanguage || isChangingModel}>
              {#each targetLanguageOptions as option}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
          </label>
          <div class="action-row">
            {#if screenRecordingPermissionError}
              <button class="small-button permission-request-button" onclick={requestScreenRecordingPermission}>
                <ShieldCheck size={14} />{uiStrings.requestPermission}
              </button>
            {/if}
            {#if modelOptions.length > 1}
              <label class="model-select-shell" aria-label="Model">
                <Cpu size={16} />
                <select class="model-select" aria-label="Model" value={selectedModelValue} onchange={selectModel} disabled={isChangingModel}>
                  {#each modelOptions as option}
                    <option value={option.value}>{option.label}</option>
                  {/each}
                </select>
              </label>
            {/if}
            <button class="icon-button" aria-label={uiStrings.close} onclick={closePopover}><X size={16} /></button>
          </div>
        </footer>
      {:else}
        <p bind:this={translationTextEl} class:original={visibleMode === "original"} class="translation-text">{bodyText}</p>
        <div class="model-meta-strip" class:warn={modelWarning.length > 0}>
          <span class="model-meta-main"><Cpu size={12} /><span>{modelMetadata}</span></span>
          {#if modelWarning}
            <span class="model-warning"><TriangleAlert size={11} />{modelWarning}</span>
          {/if}
        </div>
        <footer class="bubble-footer">
          <label class="language-select-shell" aria-label="Target language">
            <Languages size={14} />
            <select class="language-select" aria-label="Target language" value={selectedTargetLanguage} onchange={selectTargetLanguage} disabled={isChangingLanguage || isChangingModel}>
              {#each targetLanguageOptions as option}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
          </label>
          <div class="action-row">
            {#if modelOptions.length > 1}
              <label class="model-select-shell" aria-label="Model">
                <Cpu size={16} />
                <select class="model-select" aria-label="Model" value={selectedModelValue} onchange={selectModel} disabled={isChangingModel}>
                  {#each modelOptions as option}
                    <option value={option.value}>{option.label}</option>
                  {/each}
                </select>
              </label>
            {/if}
            <button class="icon-button" aria-label={visibleMode === "original" ? uiStrings.showTranslation : uiStrings.showOriginal} onclick={toggleOriginal}>
              {#if visibleMode === "original"}<Languages size={16} />{:else}<Eye size={16} />{/if}
            </button>
            <button class="icon-button" aria-label={copied ? uiStrings.copied : uiStrings.copyCurrent} onclick={copyText}>
              {#if copied}<Check size={16} />{:else}<Copy size={16} />{/if}
            </button>
            <button class="icon-button" aria-label={uiStrings.close} onclick={closePopover}><X size={16} /></button>
          </div>
        </footer>
      {/if}
      {#if showCountdown}
        <div class="countdown-bar" aria-label={`Auto hide in ${countdownLabel}`}>
          <span class="countdown-bar-fill" style={`--countdown-progress: ${countdownProgress}`}></span>
        </div>
      {/if}
    </div>
  </div>

  {#if debugMode}
    <nav class="preview-switcher" aria-label="Preview state">
      <button class:active={visibleMode === "loading"} onclick={() => (visibleMode = "loading")}>Loading</button>
      <button class:active={visibleMode === "translated"} onclick={() => (visibleMode = "translated")}>Done</button>
      <button class:active={visibleMode === "original"} onclick={() => (visibleMode = "original")}>Original</button>
      <button class:active={visibleMode === "error"} onclick={() => (visibleMode = "error")}>Error</button>
    </nav>
  {/if}
</main>

<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";
  import { Accessibility, FolderSearch, Keyboard, Monitor, RefreshCw, ShieldCheck } from "@lucide/svelte";
  import { cloneFallbackState, type ActionResult, type SettingsState } from "./lib/settings";

  type PermissionAppTarget = {
    bundleName: string;
    bundlePath: string;
    bundleFileURL: string;
  };

  let settingsState = $state<SettingsState | null>(null);
  let permissionTarget = $state<PermissionAppTarget | null>(null);
  let result = $state<ActionResult | null>(null);
  let dragStart = $state<{ x: number; y: number } | null>(null);
  let isStartingNativeDrag = $state(false);

  onMount(load);

  async function load() {
    try {
      settingsState = await invoke<SettingsState>("load_settings");
    } catch {
      settingsState = cloneFallbackState();
    }

    try {
      permissionTarget = await invoke<PermissionAppTarget>("permission_app_target");
    } catch {
      permissionTarget = null;
    }
  }

  async function action(action: string) {
    if (!settingsState) return;
    result = await invoke<ActionResult>("perform_settings_action", {
      action,
      settings: settingsState.settings
    });
    await load();
  }

  function prepareAppDrag(event: PointerEvent) {
    if (!permissionTarget || event.button !== 0) return;
    dragStart = { x: event.clientX, y: event.clientY };
  }

  async function startAppDrag(event: PointerEvent) {
    if (!permissionTarget || !dragStart || isStartingNativeDrag || (event.buttons & 1) !== 1) {
      return;
    }

    const distance = Math.hypot(event.clientX - dragStart.x, event.clientY - dragStart.y);
    if (distance < 4) return;

    event.preventDefault();
    isStartingNativeDrag = true;

    try {
      result = await invoke<ActionResult>("start_permission_app_drag");
    } catch (error) {
      result = {
        title: "Drag failed",
        message: String(error),
        ok: false
      };
    } finally {
      dragStart = null;
      isStartingNativeDrag = false;
    }
  }

  function cancelAppDrag() {
    dragStart = null;
    isStartingNativeDrag = false;
  }
</script>

{#if settingsState}
  <main class="utility-frame permission-frame">
    <header class="surface-header">
      <div>
        <h1>Permission Helper</h1>
        {#if settingsState.appVariant === "mas"}
          <!-- Sandboxed build: Cmd+C detection runs through pasteboard polling (no Input
               Monitoring — App Review 2.4.5), and Accessibility is unavailable. -->
          <p>Cmd+C detection works automatically. Grant Screen Recording for screenshot translation.</p>
        {:else}
          <p>Grant keyboard permissions for Cmd+C detection, Accessibility for caret popovers, and screen permissions for screenshot translation.</p>
        {/if}
      </div>
      <button onclick={load}><RefreshCw size={14} />Refresh</button>
    </header>

    <section class="permission-grid">
      <article
        class="app-card"
        class:draggable={permissionTarget !== null}
        onpointerdown={prepareAppDrag}
        onpointermove={startAppDrag}
        onpointerup={cancelAppDrag}
        onpointercancel={cancelAppDrag}
        title={permissionTarget ? `Drag ${permissionTarget.bundlePath} into the macOS Privacy list` : "Build and launch the app bundle before dragging"}
      >
        <ShieldCheck size={58} />
        <strong>{permissionTarget?.bundleName ?? "CCTrans.app"}</strong>
        <span>Drag this card into the open macOS Privacy list. If macOS rejects the drop, reveal the app in Finder and drag the selected app.</span>
        {#if permissionTarget}
          <code class="app-path">{permissionTarget.bundlePath}</code>
        {/if}
      </article>

      <div class="permission-column">
        <section class="setting-group standalone">
          {#if settingsState.appVariant !== "mas"}
            <!-- Keyboard (Input Monitoring) + Keyboard Cursor (Accessibility) apply only to
                 the direct-distribution build. The MAS build requests neither: Cmd+C is
                 detected via pasteboard polling (App Review 2.4.5). -->
            <div class="setting-row">
              <span class="setting-copy"><strong>Keyboard</strong></span>
              <span class:ready={settingsState.permissions.keyboard} class="status-pill">
                {settingsState.permissions.keyboard ? "Ready" : "Not granted"}
              </span>
              {#if !settingsState.permissions.keyboard}
                <button class="small-button inline-btn" onclick={() => action("openInputMonitoring")}>
                  <Keyboard size={12} />Open Settings
                </button>
              {:else}
                <span class="reset-row spacer"></span>
              {/if}
            </div>
            <div class="setting-row">
              <span class="setting-copy">
                <strong>Keyboard Cursor</strong>
                <span>Required for popovers near the text caret</span>
              </span>
              <span class:ready={settingsState.permissions.accessibility} class="status-pill">
                {settingsState.permissions.accessibility ? "Ready" : "Not granted"}
              </span>
              {#if !settingsState.permissions.accessibility}
                <button class="small-button inline-btn" onclick={() => action("openAccessibility")}>
                  <Accessibility size={12} />Open Settings
                </button>
              {:else}
                <span class="reset-row spacer"></span>
              {/if}
            </div>
          {/if}
          <div class="setting-row">
            <span class="setting-copy"><strong>Screen Recording</strong></span>
            <span class:ready={settingsState.permissions.screen} class="status-pill">
              {settingsState.permissions.screen ? "Ready" : "Not granted"}
            </span>
            {#if !settingsState.permissions.screen}
              <button class="small-button inline-btn" onclick={() => action("openScreenRecording")}>
                <Monitor size={12} />Open Settings
              </button>
            {:else}
              <span class="reset-row spacer"></span>
            {/if}
          </div>
        </section>

        <section class="action-list">
          {#if settingsState.appVariant !== "mas"}
            <button onclick={() => action("openInputMonitoring")}><Keyboard size={14} />Open Input Monitoring Settings</button>
            <button onclick={() => action("openAccessibility")}><Accessibility size={14} />Open Accessibility Settings</button>
          {/if}
          <button onclick={() => action("openScreenRecording")}><Monitor size={14} />Open Screen Recording Settings</button>
          <button onclick={() => action("revealPermissionApp")}><FolderSearch size={14} />Reveal CCTrans.app</button>
        </section>

        {#if result}
          <p class:ok={result.ok} class="action-result">{result.title}: {result.message}</p>
        {/if}
      </div>
    </section>
  </main>
{:else}
  <div class="loading">Loading permissions...</div>
{/if}

<style>
  /* Ensure the button overlaps nicely over the empty space in column 2,
     keeping the 3-column grid structure perfectly aligned. */
  .inline-btn {
    grid-column: 3;
    justify-self: end;
    gap: 4px;
    height: 24px;
    min-height: 24px;
    padding: 0 8px;
    font-size: 11px;
    border-radius: 6px;
    background: var(--surface-1);
  }
  .inline-btn:active {
    background: var(--surface-2);
  }
</style>

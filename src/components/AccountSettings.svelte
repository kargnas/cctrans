<script lang="ts">
  import {
    CheckCircle2,
    CreditCard,
    ExternalLink,
    LoaderCircle,
    LogIn,
    LogOut,
    RefreshCcw,
    RotateCcw,
    ShieldAlert,
    User
  } from "@lucide/svelte";
  import { onMount } from "svelte";
  import {
    fallbackAccountState,
    loadCctransAccount,
    openCctransAccountWebSettings,
    runCctransAccountAction,
    type AccountShellAction,
    type CctransAccountState,
    type CctransAccountSummary
  } from "../lib/account";

  let { appVariant }: { appVariant: "mas" | "direct" } = $props();

  let accountState: CctransAccountState = $state(fallbackAccountState);
  let isTauri = $state(false);
  let isLoading = $state(true);
  let isWorking = $state(false);
  let message: { text: string; ok: boolean } | null = $state(null);

  onMount(() => {
    isTauri = "__TAURI_INTERNALS__" in window;
    void refreshAccount();
  });

  async function refreshAccount(clearMessage = true) {
    isLoading = true;
    try {
      accountState = await loadCctransAccount(isTauri);
      if (clearMessage) message = null;
    } catch (error) {
      message = { text: formatError(error), ok: false };
    } finally {
      isLoading = false;
    }
  }

  async function runShellAction(action: AccountShellAction) {
    if (!isTauri) {
      message = { text: "Preview action recorded.", ok: true };
      return;
    }
    isWorking = true;
    try {
      const result = await runCctransAccountAction(action);
      await refreshAccount(false);
      message = { text: result.message, ok: result.ok };
    } catch (error) {
      message = { text: formatError(error), ok: false };
    } finally {
      isWorking = false;
    }
  }

  async function openWebSettings() {
    if (!isTauri) {
      message = { text: "Preview action recorded.", ok: true };
      return;
    }
    isWorking = true;
    try {
      const result = await openCctransAccountWebSettings();
      message = { text: result.message, ok: result.ok };
    } catch (error) {
      message = { text: formatError(error), ok: false };
    } finally {
      isWorking = false;
    }
  }

  function formatError(error: unknown) {
    return error instanceof Error ? error.message : String(error);
  }

  function statusLabel(account: CctransAccountSummary | null) {
    if (!account) return "Logged out";
    if (account.syncing) return "Syncing";
    if (!account.email_verified) return "Verification needed";
    if (account.lifetime || account.plan === "lifetime") return "Lifetime";
    if (account.plan === "pro") return isExpired(account) ? "Expired" : "Pro";
    return "Free";
  }

  function statusClass(account: CctransAccountSummary | null) {
    const label = statusLabel(account);
    if (label === "Pro" || label === "Lifetime") return "ready";
    if (label === "Syncing") return "syncing";
    if (label === "Expired" || label === "Verification needed") return "warning";
    return "";
  }

  function statusIcon(account: CctransAccountSummary | null) {
    const label = statusLabel(account);
    if (label === "Syncing") return "syncing";
    if (label === "Expired" || label === "Verification needed") return "warning";
    if (label === "Pro" || label === "Lifetime") return "ready";
    return "user";
  }

  function sourceLabel(source: CctransAccountSummary["source"]) {
    if (source === "storekit") return "App Store";
    if (source === "stripe") return "Web billing";
    return "None";
  }

  function renewalText(account: CctransAccountSummary) {
    if (account.lifetime || account.plan === "lifetime") return "No renewal";
    if (!account.pro_until) return account.plan === "pro" ? "Verification pending" : "No active renewal";
    const date = new Date(account.pro_until);
    if (Number.isNaN(date.getTime())) return account.pro_until;
    return `${isExpired(account) ? "Expired" : "Renews"} ${date.toLocaleDateString()}`;
  }

  function isExpired(account: CctransAccountSummary) {
    if (!account.pro_until || account.lifetime || account.plan !== "pro") return false;
    const date = new Date(account.pro_until);
    return Number.isFinite(date.getTime()) && date.getTime() < Date.now();
  }
</script>

<section class="pane account-pane">
  <h2>Account</h2>
  <div class="setting-group">
    <div class="setting-row account-status-row">
      <span class="setting-copy">
        <strong>{accountState.account?.email ?? "Not signed in"}</strong>
        <span>{accountState.account ? accountState.account.name : "Use CCTrans Cloud without exposing your token in settings."}</span>
      </span>
      <span class:ready={statusClass(accountState.account) === "ready"} class:syncing={statusClass(accountState.account) === "syncing"} class:warning={statusClass(accountState.account) === "warning"} class="status-pill account-plan">
        {#if statusIcon(accountState.account) === "syncing"}<LoaderCircle size={13} />{:else if statusIcon(accountState.account) === "warning"}<ShieldAlert size={13} />{:else if statusIcon(accountState.account) === "ready"}<CheckCircle2 size={13} />{:else}<User size={13} />{/if}
        {statusLabel(accountState.account)}
      </span>
      <button
        class="reset-row visible"
        type="button"
        title="Refresh account"
        aria-label="Refresh account"
        disabled={isLoading || isWorking}
        onclick={() => runShellAction("refresh")}
      >
        <RefreshCcw size={13} />
      </button>
    </div>

    {#if accountState.account}
      <div class="setting-row">
        <span class="setting-copy">
          <strong>Login</strong>
          <span>Browser sign-in</span>
        </span>
        <span class="last-result">{accountState.account.email_verified ? "Email verified" : "Email verification needed"}</span>
        <span class="reset-row spacer"></span>
      </div>
      <div class="setting-row">
        <span class="setting-copy">
          <strong>Subscription</strong>
          <span>{sourceLabel(accountState.account.source)}</span>
        </span>
        <span class="last-result">{renewalText(accountState.account)}</span>
        <span class="reset-row spacer"></span>
      </div>
    {/if}
  </div>

  {#if !accountState.account}
    <h2>Sign In</h2>
    <div class="setting-group account-auth-group">
      <div class="setting-row">
        <span class="setting-copy">
          <strong>Browser sign-in</strong>
          <span>Continue with Apple, Google, or email.</span>
        </span>
        <span class="reset-row spacer"></span>
      </div>
      <div class="account-auth-footer">
        <button
          type="button"
          title="Continue in browser"
          aria-label="Continue in browser"
          disabled={isWorking}
          onclick={() => runShellAction("browserLogin")}
        >
          <LogIn size={13} />Continue in Browser
        </button>
      </div>
    </div>
  {/if}

  <h2>Billing</h2>
  <div class="setting-group">
    {#if appVariant === "mas"}
      <div class="action-grid">
        <button type="button" title="Purchase Pro with StoreKit" aria-label="Purchase Pro with StoreKit" disabled={isWorking} onclick={() => runShellAction("purchase")}>
          <CreditCard size={14} />Purchase Pro
        </button>
        <button type="button" title="Restore App Store purchases" aria-label="Restore App Store purchases" disabled={isWorking} onclick={() => runShellAction("restore")}>
          <RotateCcw size={14} />Restore
        </button>
      </div>
    {:else}
      <div class="action-grid single">
        <button type="button" title="Open web account settings" aria-label="Open web account settings" disabled={isWorking} onclick={openWebSettings}>
          <ExternalLink size={14} />Open Web Settings
        </button>
      </div>
    {/if}
  </div>

  {#if accountState.account}
    <div class="action-grid single account-logout">
      <button type="button" title="Logout" aria-label="Logout" disabled={isWorking} onclick={() => runShellAction("logout")}>
        <LogOut size={14} />Logout
      </button>
    </div>
  {/if}

  {#if message}
    <div class:ok={message.ok} class="account-message" role="status">{message.text}</div>
  {/if}
</section>

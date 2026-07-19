<script lang="ts">
  import {
    Apple,
    CheckCircle2,
    CreditCard,
    ExternalLink,
    LoaderCircle,
    LogIn,
    LogOut,
    Mail,
    RefreshCcw,
    RotateCcw,
    ShieldAlert,
    User
  } from "@lucide/svelte";
  import { onMount } from "svelte";
  import {
    fallbackAccountState,
    loadCctransAccount,
    loginCctransAccount,
    openCctransAccountWebSettings,
    registerCctransAccount,
    runCctransAccountAction,
    type AccountShellAction,
    type CctransAccountState,
    type CctransAccountSummary
  } from "../lib/account";

  let accountState: CctransAccountState = $state(fallbackAccountState);
  let isTauri = $state(false);
  let isLoading = $state(true);
  let isWorking = $state(false);
  let mode: "login" | "register" = $state("login");
  let name = $state("");
  let email = $state("");
  let password = $state("");
  let passwordConfirmation = $state("");
  let message: { text: string; ok: boolean } | null = $state(null);

  onMount(() => {
    isTauri = "__TAURI_INTERNALS__" in window;
    void refreshAccount();
  });

  async function refreshAccount() {
    isLoading = true;
    try {
      accountState = await loadCctransAccount(isTauri);
      message = null;
    } catch (error) {
      message = { text: formatError(error), ok: false };
    } finally {
      isLoading = false;
    }
  }

  async function submitEmailAuth(event: SubmitEvent) {
    event.preventDefault();
    if (!isTauri) {
      message = { text: "Preview mode cannot sign in.", ok: false };
      return;
    }
    isWorking = true;
    try {
      accountState = mode === "login"
        ? await loginCctransAccount(email, password)
        : await registerCctransAccount(name, email, password, passwordConfirmation);
      password = "";
      passwordConfirmation = "";
      message = { text: "Account saved on this Mac.", ok: true };
    } catch (error) {
      message = { text: formatError(error), ok: false };
    } finally {
      isWorking = false;
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
      message = { text: result.message, ok: result.ok };
      await refreshAccount();
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
          <span>{accountState.account.apple_linked ? "Apple linked" : "Email account"}</span>
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
      <div class="account-auth-tabs" role="tablist" aria-label="Account sign in mode">
        <button type="button" class:active={mode === "login"} onclick={() => (mode = "login")}>
          <LogIn size={13} />Login
        </button>
        <button type="button" class:active={mode === "register"} onclick={() => (mode = "register")}>
          <Mail size={13} />Register
        </button>
      </div>
      <form class="account-form" onsubmit={submitEmailAuth}>
        {#if mode === "register"}
          <input
            aria-label="Name"
            autocomplete="name"
            placeholder="Name"
            required
            value={name}
            oninput={(event) => (name = event.currentTarget.value)}
          />
        {/if}
        <input
          aria-label="Email"
          autocomplete="email"
          placeholder="Email"
          required
          type="email"
          value={email}
          oninput={(event) => (email = event.currentTarget.value)}
        />
        <input
          aria-label="Password"
          autocomplete={mode === "login" ? "current-password" : "new-password"}
          placeholder="Password"
          required
          type="password"
          value={password}
          oninput={(event) => (password = event.currentTarget.value)}
        />
        {#if mode === "register"}
          <input
            aria-label="Confirm password"
            autocomplete="new-password"
            placeholder="Confirm password"
            required
            type="password"
            value={passwordConfirmation}
            oninput={(event) => (passwordConfirmation = event.currentTarget.value)}
          />
        {/if}
        <button type="submit" disabled={isWorking}>
          <Mail size={13} />{mode === "login" ? "Continue with Email" : "Create Account"}
        </button>
      </form>
      {#if accountState.actions.canLoginWithApple}
        <div class="account-auth-footer">
          <button
            type="button"
            title="Continue with Apple"
            aria-label="Continue with Apple"
            disabled={isWorking}
            onclick={() => runShellAction("appleLogin")}
          >
            <Apple size={13} />Continue with Apple
          </button>
        </div>
      {/if}
    </div>
  {/if}

  <h2>Billing</h2>
  <div class="setting-group">
    {#if accountState.actions.canStorekitPurchase || accountState.actions.canStorekitRestore}
      <div class="action-grid">
        {#if accountState.actions.canStorekitPurchase}
          <button type="button" title="Purchase Pro with StoreKit" aria-label="Purchase Pro with StoreKit" disabled={isWorking} onclick={() => runShellAction("purchase")}>
            <CreditCard size={14} />Purchase Pro
          </button>
        {/if}
        {#if accountState.actions.canStorekitRestore}
          <button type="button" title="Restore App Store purchases" aria-label="Restore App Store purchases" disabled={isWorking} onclick={() => runShellAction("restore")}>
            <RotateCcw size={14} />Restore
          </button>
        {/if}
      </div>
    {:else if accountState.actions.canOpenWebSettings}
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

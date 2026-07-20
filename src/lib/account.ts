import { invoke } from "@tauri-apps/api/core";

export type AccountPlan = "free" | "pro" | "lifetime";
export type AccountEntitlementSource = "storekit" | "stripe";

export type CctransAccountSummary = {
  uuid: string;
  name: string;
  email: string;
  email_verified: boolean;
  apple_linked: boolean;
  plan: AccountPlan;
  source?: AccountEntitlementSource | null;
  pro_until?: string | null;
  lifetime: boolean;
  syncing: boolean;
};

export type CctransAccountState = {
  account: CctransAccountSummary | null;
};

export type AccountShellAction = "browserLogin" | "logout" | "refresh" | "purchase" | "restore";

export type ActionResult = {
  title: string;
  message: string;
  ok: boolean;
};

export type AccountActionResult = ActionResult & {
  code: "success" | "error" | "not_available";
};

export const fallbackAccountState: CctransAccountState = {
  account: null
};

export function loadCctransAccount(isTauri: boolean) {
  return isTauri ? invoke<CctransAccountState>("load_cctrans_account") : Promise.resolve(fallbackAccountState);
}

export function runCctransAccountAction(action: AccountShellAction) {
  return invoke<AccountActionResult>("cctrans_account_shell_action", { action });
}

export function openCctransAccountWebSettings() {
  return invoke<ActionResult>("open_cctrans_account_web_settings");
}

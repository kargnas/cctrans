use serde::{Deserialize, Serialize};
mod surfaces;

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use surfaces::{open_surface_window, AppSurface};
use tauri::window::{Effect, EffectState, EffectsBuilder};
#[cfg(target_os = "macos")]
use tauri::ActivationPolicy;
use tauri::{
    AppHandle, LogicalSize, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewUrl,
    WebviewWindowBuilder,
};

#[cfg(target_os = "macos")]
mod macos_toast {
    use block2::RcBlock;
    use objc2_app_kit::{NSEvent, NSEventMask, NSEventType, NSWindow};
    use std::cell::Cell;
    use std::ptr::NonNull;
    use std::rc::Rc;
    use tauri::{AppHandle, Emitter, Manager};

    // Screen-coordinate bounds of the visible toast, or None when it is hidden. Both NSWindow.frame
    // and NSEvent::mouseLocation use the same bottom-left screen origin, so they hit-test directly.
    fn visible_toast_bounds(app: &AppHandle) -> Option<(f64, f64, f64, f64)> {
        let window = app.get_webview_window("translation")?;
        if !window.is_visible().unwrap_or(false) {
            return None;
        }
        let ns_window = window.ns_window().ok()?;
        let frame = unsafe { (ns_window as *mut NSWindow).as_ref() }?.frame();
        Some((
            frame.origin.x,
            frame.origin.y,
            frame.origin.x + frame.size.width,
            frame.origin.y + frame.size.height,
        ))
    }

    // The toast is a non-activating panel in a background (accessory) helper process, so plain hover
    // never reaches its WebView: macOS posts those mouseMoved events to the active app underneath
    // instead, which is why hover only registered after a click woke the panel. A *global* monitor
    // gets a copy of exactly those events, so we hit-test the cursor against the toast frame here and
    // drive both hover-pause and outside-click-dismiss without the panel ever taking key focus.
    // (Mouse-event monitors need no accessibility permission, unlike keyboard ones.)
    pub fn install_pointer_monitor(app: AppHandle) {
        let mask = NSEventMask::MouseMoved
            | NSEventMask::LeftMouseDown
            | NSEventMask::RightMouseDown
            | NSEventMask::OtherMouseDown;
        let inside = Rc::new(Cell::new(false));
        let handler = RcBlock::new(move |event: NonNull<NSEvent>| {
            let event_type = unsafe { event.as_ref() }.r#type();
            let Some((min_x, min_y, max_x, max_y)) = visible_toast_bounds(&app) else {
                inside.set(false);
                return;
            };
            let location = NSEvent::mouseLocation();
            let hit = location.x >= min_x
                && location.x <= max_x
                && location.y >= min_y
                && location.y <= max_y;
            if event_type == NSEventType::MouseMoved {
                if hit != inside.get() {
                    inside.set(hit);
                    let _ = app.emit_to("translation", "toast-hover", hit);
                }
            } else if !hit {
                // The toast is non-focusable, so we cannot rely on window blur for click-outside
                // dismissal. The WebView owns close state and timer cleanup.
                let _ = app.emit_to("translation", "toast-dismiss-request", ());
            }
        });
        let token = NSEvent::addGlobalMonitorForEventsMatchingMask_handler(mask, &handler);
        // The toast helper outlives every individual popup, so keep the monitor for the whole
        // process lifetime; dropping the token would unregister it via its Drop glue.
        std::mem::forget(token);
    }

    // Re-shape the toast's native vibrancy so the card looks like image #8: an inset rounded panel with a
    // TRANSPARENT gutter the pin can overhang into. The window's `.effects()` makes the NSVisualEffectView
    // fill the entire 396px window, which would frost that gutter and nest a double border around the inset
    // 348px `.translation-bubble` (the fdcb42c bug). Replacing its maskImage with an inset rounded rect
    // clips the material to just the card; the gutter then shows the desktop, and the pin floats over it.
    //
    // The card is ALWAYS inset 24px horizontally / 18px vertically: the bubble is `window_width - 48`
    // (348 in 396, 512 in 560, …) centred under 18px stage padding, and `window_height - 36` tall. A 9-part
    // stretchable NSImage (cap insets pin the gutter + the 4 rounded corners, only the centre stretches)
    // tracks every resize, so this is set once and the OS rescales it.
    pub fn mask_toast_material_to_card(window: &tauri::WebviewWindow) {
        use objc2::rc::Retained;
        use objc2::{msg_send, AnyThread, ClassType};
        use objc2_app_kit::{NSBezierPath, NSColor, NSImage, NSVisualEffectView};
        use objc2_foundation::{NSEdgeInsets, NSPoint, NSRect, NSSize};

        const GUTTER_X: f64 = 24.0;
        const GUTTER_Y: f64 = 18.0;
        const RADIUS: f64 = 14.0;
        // A 2px stretchable centre strip; without it cap insets would meet and the mask could not resize.
        const STRETCH: f64 = 2.0;
        // The masked material renders a near-opaque light panel. Dropping the material view's alphaValue lets a
        // sliver of the desktop composite through the whole card so it reads as "a bit see-through" instead of a
        // solid slab. This is static CoreAnimation compositing (NOT CSS backdrop-filter), so it does NOT bring
        // back the per-frame blur-drop flicker, and the 30% --bubble-bg backing that stabilises the web layer
        // stays intact. 0.86 = the "살짝 투명" look the user picked.
        const MATERIAL_ALPHA: f64 = 0.86;

        let Ok(ptr) = window.ns_window() else {
            return;
        };
        let ns_window: &NSWindow = unsafe { &*(ptr as *mut NSWindow) };
        let Some(content_view) = ns_window.contentView() else {
            return;
        };
        let Some(frame_view) = (unsafe { content_view.superview() }) else {
            return;
        };

        let size = NSSize::new(
            GUTTER_X * 2.0 + RADIUS * 2.0 + STRETCH,
            GUTTER_Y * 2.0 + RADIUS * 2.0 + STRETCH,
        );
        unsafe {
            // Draw an opaque rounded rect inset by the gutter onto a transparent image; the alpha IS the mask.
            let mask: Retained<NSImage> = msg_send![NSImage::alloc(), initWithSize: size];
            let _: () = msg_send![&*mask, lockFocus];
            let card = NSRect::new(
                NSPoint::new(GUTTER_X, GUTTER_Y),
                NSSize::new(RADIUS * 2.0 + STRETCH, RADIUS * 2.0 + STRETCH),
            );
            let path: Retained<NSBezierPath> = msg_send![
                <NSBezierPath as ClassType>::class(),
                bezierPathWithRoundedRect: card,
                xRadius: RADIUS,
                yRadius: RADIUS,
            ];
            let black = NSColor::blackColor();
            let _: () = msg_send![&*black, set];
            let _: () = msg_send![&*path, fill];
            let _: () = msg_send![&*mask, unlockFocus];
            let insets = NSEdgeInsets {
                top: GUTTER_Y + RADIUS,
                left: GUTTER_X + RADIUS,
                bottom: GUTTER_Y + RADIUS,
                right: GUTTER_X + RADIUS,
            };
            let _: () = msg_send![&*mask, setCapInsets: insets];
            let _: () = msg_send![&*mask, setResizingMode: 1_isize]; // NSImageResizingMode::Stretch

            // `.effects()` adds exactly one NSVisualEffectView for the blur. window-vibrancy has put it
            // directly under the content view in some Tauri versions and under the content view's superview
            // in others, so re-mask any NSVisualEffectView found at either level.
            let vev_class = <NSVisualEffectView as ClassType>::class();
            for parent in [&content_view, &frame_view] {
                let subviews = parent.subviews();
                for i in 0..subviews.count() {
                    let view = subviews.objectAtIndex(i);
                    let is_vev: bool = msg_send![&*view, isKindOfClass: vev_class];
                    if is_vev {
                        let _: () = msg_send![&*view, setMaskImage: &*mask];
                        let _: () = msg_send![&*view, setAlphaValue: MATERIAL_ALPHA];
                    }
                }
            }
        }
    }
}

const TRANSLATION_WINDOW_WIDTH: f64 = 396.0;
const TRANSLATION_WINDOW_HEIGHT: f64 = 150.0;
const TRANSLATION_TALL_WINDOW_HEIGHT: f64 = 176.0;
const TRANSLATION_DEBUG_WINDOW_HEIGHT: f64 = 230.0;
const TRANSLATION_WINDOW_MARGIN: f64 = 24.0;
const TRANSLATION_CARET_GAP: f64 = 8.0;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct Settings {
    provider: TranslationProvider,
    #[serde(rename = "localModelID")]
    local_model_id: String,
    #[serde(rename = "localHyMT2BackendPath")]
    local_hy_mt2_backend_path: Option<String>,
    #[serde(rename = "customLocalModelsPath")]
    custom_local_models_path: Option<String>,
    #[serde(rename = "openRouterTextModel")]
    open_router_text_model: String,
    #[serde(rename = "openRouterVisionModel")]
    open_router_vision_model: String,
    #[serde(rename = "favoriteLocalModelIDs")]
    favorite_local_model_ids: Vec<String>,
    #[serde(rename = "favoriteOpenRouterModels")]
    favorite_open_router_models: Vec<String>,
    #[serde(rename = "openRouterModelFilter")]
    open_router_model_filter: OpenRouterModelFilter,
    #[serde(rename = "includeScreenContextForLLM")]
    include_screen_context_for_llm: bool,
    #[serde(rename = "sourceLanguage")]
    source_language: String,
    #[serde(rename = "targetLanguage")]
    target_language: String,
    #[serde(rename = "hasCompletedLocalModelSelection")]
    has_completed_local_model_selection: bool,
    #[serde(rename = "hasCompletedOnboarding")]
    has_completed_onboarding: bool,
    #[serde(rename = "toastPosition")]
    toast_position: ToastPosition,
    #[serde(rename = "toastCustomPosition")]
    toast_custom_position: Option<ToastCustomPosition>,
    #[serde(rename = "toastDuration")]
    toast_duration: f64,
    // Consumed only by the Swift launcher (start menu-bar-only with no Welcome window);
    // mirrored here so the settings round-trip through this helper preserves it.
    #[serde(rename = "startMenuBarOnly")]
    start_menu_bar_only: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
enum TranslationProvider {
    #[serde(rename = "localHyMT2")]
    LocalHyMT2,
    #[serde(rename = "openRouter")]
    OpenRouter,
    // Apple's on-device Translation framework; the only local provider the
    // sandboxed Mac App Store variant can offer.
    #[serde(rename = "appleTranslation")]
    AppleTranslation,
    // CCTrans Cloud: server-chosen managed model, no OpenRouter key.
    #[serde(rename = "kargnasManaged")]
    KargnasManaged,
}

impl std::str::FromStr for TranslationProvider {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "localHyMT2" => Ok(Self::LocalHyMT2),
            "openRouter" => Ok(Self::OpenRouter),
            "appleTranslation" => Ok(Self::AppleTranslation),
            "kargnasManaged" => Ok(Self::KargnasManaged),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
enum ToastPosition {
    #[serde(rename = "bottomRight")]
    BottomRight,
    #[serde(rename = "bottomLeft")]
    BottomLeft,
    #[serde(rename = "topRight")]
    TopRight,
    #[serde(rename = "topLeft")]
    TopLeft,
    #[serde(rename = "custom")]
    Custom,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct OpenRouterModelFilter {
    #[serde(rename = "modalityMode")]
    modality_mode: OpenRouterModalityMode,
    #[serde(rename = "minPromptPricePerMillion")]
    min_prompt_price_per_million: f64,
    #[serde(rename = "maxPromptPricePerMillion")]
    max_prompt_price_per_million: f64,
    #[serde(rename = "minCompletionPricePerMillion")]
    min_completion_price_per_million: f64,
    #[serde(rename = "maxCompletionPricePerMillion")]
    max_completion_price_per_million: f64,
    // Show only the most popular Top N models (daily-usage rank). 0 = no limit ("All").
    // serde default keeps filters stored before this field deserializing cleanly.
    #[serde(rename = "topRankLimit", default = "default_top_rank_limit")]
    top_rank_limit: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
enum OpenRouterModalityMode {
    #[serde(rename = "textOrVision")]
    TextOrVision,
    #[serde(rename = "others", alias = "all")]
    Others,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
struct ToastCustomPosition {
    x: f64,
    y: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
enum LegacyHyMT2Model {
    #[serde(rename = "tencent/Hy-MT2-30B-A3B")]
    HyMT230B,
    #[serde(rename = "tencent/Hy-MT2-1.8B")]
    HyMT218B,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct StoredSettings {
    provider: Option<TranslationProvider>,
    #[serde(rename = "hyMT2Model")]
    hy_mt2_model: Option<LegacyHyMT2Model>,
    #[serde(rename = "localModelID")]
    local_model_id: Option<String>,
    #[serde(rename = "localHyMT2BackendPath")]
    local_hy_mt2_backend_path: Option<String>,
    #[serde(rename = "customLocalModelsPath")]
    custom_local_models_path: Option<String>,
    #[serde(rename = "openRouterTextModel")]
    open_router_text_model: Option<String>,
    #[serde(rename = "openRouterVisionModel")]
    open_router_vision_model: Option<String>,
    #[serde(rename = "favoriteLocalModelIDs")]
    favorite_local_model_ids: Option<Vec<String>>,
    #[serde(rename = "favoriteOpenRouterModels")]
    favorite_open_router_models: Option<Vec<String>>,
    #[serde(rename = "openRouterModelFilter")]
    open_router_model_filter: Option<OpenRouterModelFilter>,
    #[serde(rename = "includeScreenContextForLLM")]
    include_screen_context_for_llm: Option<bool>,
    #[serde(rename = "sourceLanguage")]
    source_language: Option<String>,
    #[serde(rename = "targetLanguage")]
    target_language: Option<String>,
    #[serde(rename = "hasCompletedLocalModelSelection")]
    has_completed_local_model_selection: Option<bool>,
    #[serde(rename = "hasCompletedOnboarding")]
    has_completed_onboarding: Option<bool>,
    #[serde(rename = "toastPosition")]
    toast_position: Option<ToastPosition>,
    #[serde(rename = "toastCustomPosition")]
    toast_custom_position: Option<ToastCustomPosition>,
    #[serde(rename = "toastDuration")]
    toast_duration: Option<f64>,
    #[serde(rename = "startMenuBarOnly")]
    start_menu_bar_only: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AppVariant {
    Direct,
    MacAppStore,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SettingsRuntime {
    variant: AppVariant,
}

impl SettingsRuntime {
    fn current() -> Self {
        static RUNTIME: std::sync::OnceLock<SettingsRuntime> = std::sync::OnceLock::new();
        *RUNTIME.get_or_init(|| {
            let args = effective_args();
            let is_mas = args
                .windows(2)
                .any(|pair| pair[0] == "--app-variant" && pair[1] == "mas");
            let variant = if is_mas || sandbox_container_active() {
                AppVariant::MacAppStore
            } else {
                AppVariant::Direct
            };
            SettingsRuntime { variant }
        })
    }

    #[cfg(test)]
    fn for_variant(variant: AppVariant) -> Self {
        Self { variant }
    }

    fn app_variant_name(self) -> &'static str {
        match self.variant {
            AppVariant::Direct => "direct",
            AppVariant::MacAppStore => "mas",
        }
    }

    fn default_settings(self) -> Settings {
        let mut settings = default_settings();
        // Every variant declares its effective default provider explicitly; the
        // base default (KargnasManaged) is only the fail-safe for code paths
        // that never went through a variant.
        settings.provider = match self.variant {
            AppVariant::Direct => TranslationProvider::LocalHyMT2,
            AppVariant::MacAppStore => TranslationProvider::AppleTranslation,
        };
        settings
    }

    fn supports_provider(self, provider: TranslationProvider) -> bool {
        match self.variant {
            AppVariant::Direct => true,
            AppVariant::MacAppStore => !matches!(provider, TranslationProvider::LocalHyMT2),
        }
    }

    fn normalize(self, mut settings: Settings) -> Settings {
        if !self.supports_provider(settings.provider) {
            settings.provider = self.default_settings().provider;
        }
        settings.local_hy_mt2_backend_path =
            normalized_optional(settings.local_hy_mt2_backend_path);
        settings.custom_local_models_path = normalized_optional(settings.custom_local_models_path);
        settings.open_router_text_model = settings.open_router_text_model.trim().to_string();
        settings.open_router_vision_model = settings.open_router_vision_model.trim().to_string();
        settings.favorite_local_model_ids =
            normalized_string_list(settings.favorite_local_model_ids);
        settings.favorite_open_router_models =
            normalized_string_list(settings.favorite_open_router_models);
        settings.open_router_model_filter =
            normalized_openrouter_model_filter(settings.open_router_model_filter);
        settings.source_language = settings.source_language.trim().to_string();
        settings.target_language = settings.target_language.trim().to_string();
        if !settings.toast_duration.is_finite() || settings.toast_duration <= 0.0 {
            settings.toast_duration = default_settings().toast_duration;
        }
        settings.toast_custom_position = match (
            settings.toast_position.clone(),
            settings.toast_custom_position,
        ) {
            (ToastPosition::Custom, Some(position))
                if position.x.is_finite() && position.y.is_finite() =>
            {
                Some(position)
            }
            (ToastPosition::Custom, _) => None,
            _ => None,
        };
        settings
    }

    fn apply_stored(self, stored: StoredSettings) -> Settings {
        let mut settings = self.default_settings();
        if let Some(provider) = stored.provider {
            settings.provider = provider;
        }
        settings.local_model_id = stored
            .local_model_id
            .or_else(|| stored.hy_mt2_model.map(legacy_model_id))
            .unwrap_or(settings.local_model_id);
        settings.local_hy_mt2_backend_path = stored.local_hy_mt2_backend_path;
        settings.custom_local_models_path = stored.custom_local_models_path;
        if let Some(value) = stored.open_router_text_model {
            settings.open_router_text_model = value;
        }
        if let Some(value) = stored.open_router_vision_model {
            settings.open_router_vision_model = value;
        }
        if let Some(value) = stored.favorite_local_model_ids {
            settings.favorite_local_model_ids = value;
        }
        if let Some(value) = stored.favorite_open_router_models {
            settings.favorite_open_router_models = value;
        }
        if let Some(value) = stored.open_router_model_filter {
            settings.open_router_model_filter = value;
        }
        if let Some(value) = stored.include_screen_context_for_llm {
            settings.include_screen_context_for_llm = value;
        }
        if let Some(value) = stored.source_language {
            settings.source_language = value;
        }
        if let Some(value) = stored.target_language {
            settings.target_language = value;
        }
        if let Some(value) = stored.has_completed_local_model_selection {
            settings.has_completed_local_model_selection = value;
        }
        if let Some(value) = stored.has_completed_onboarding {
            settings.has_completed_onboarding = value;
        }
        if let Some(value) = stored.toast_position {
            settings.toast_position = value;
        }
        if let Some(value) = stored.toast_custom_position {
            settings.toast_custom_position = Some(value);
        }
        if let Some(value) = stored.toast_duration {
            settings.toast_duration = value;
        }
        if let Some(value) = stored.start_menu_bar_only {
            settings.start_menu_bar_only = value;
        }
        self.normalize(settings)
    }

    fn stored_from_effective(self, settings: &Settings) -> StoredSettings {
        StoredSettings::from_effective(
            settings,
            &self.default_settings(),
            self.variant == AppVariant::MacAppStore,
        )
    }

    fn provider_options(self) -> Vec<SettingOption> {
        [
            option("Local Model", "localHyMT2", None),
            option("Apple Translation", "appleTranslation", Some("On-device")),
            option("CCTrans Cloud", "kargnasManaged", Some("No API key")),
            option("OpenRouter LLM", "openRouter", None),
        ]
        .into_iter()
        .filter(|provider| {
            provider
                .value
                .parse::<TranslationProvider>()
                .map(|provider| self.supports_provider(provider))
                .unwrap_or(false)
        })
        .collect()
    }
}

#[derive(Clone, Debug, Serialize)]
struct SettingsState {
    // "mas" for the sandboxed Mac App Store bundle (Swift shell passes
    // --app-variant mas), "direct" otherwise. The UI hides the Python-backed
    // local provider and the Accessibility permission section on "mas".
    #[serde(rename = "appVariant")]
    app_variant: String,
    settings: Settings,
    defaults: Settings,
    overrides: BTreeMap<String, bool>,
    options: SettingsOptions,
    permissions: PermissionStatus,
    #[serde(rename = "loginItem")]
    login_item: LoginItemState,
    #[serde(rename = "storagePath")]
    storage_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct SettingsOptions {
    providers: Vec<SettingOption>,
    #[serde(rename = "localModels")]
    local_models: Vec<SettingOption>,
    #[serde(rename = "openRouterModels")]
    open_router_models: Vec<OpenRouterModelOption>,
    #[serde(rename = "sourceLanguages")]
    source_languages: Vec<SettingOption>,
    #[serde(rename = "targetLanguages")]
    target_languages: Vec<SettingOption>,
    #[serde(rename = "toastPositions")]
    toast_positions: Vec<SettingOption>,
}

#[derive(Clone, Debug, Serialize)]
struct SettingOption {
    label: String,
    value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OpenRouterModelOption {
    label: String,
    value: String,
    note: Option<String>,
    #[serde(rename = "promptPricePerMillion")]
    prompt_price_per_million: f64,
    #[serde(rename = "completionPricePerMillion")]
    completion_price_per_million: f64,
    modalities: Vec<String>,
    #[serde(
        default = "default_openrouter_output_modalities",
        rename = "outputModalities"
    )]
    output_modalities: Vec<String>,
    #[serde(rename = "releaseDate")]
    release_date: String,
    #[serde(rename = "contextWindow")]
    context_window: i64,
    #[serde(rename = "isReasoning")]
    is_reasoning: bool,
    #[serde(rename = "isFree")]
    is_free: bool,
    #[serde(rename = "isRecommended")]
    is_recommended: bool,
    #[serde(
        default,
        rename = "dailyTokenRank",
        skip_serializing_if = "Option::is_none"
    )]
    daily_token_rank: Option<i64>,
    #[serde(
        default,
        rename = "throughputRank",
        skip_serializing_if = "Option::is_none"
    )]
    throughput_rank: Option<i64>,
    // Position in OpenRouter's `sort=latency-low-to-high` list (1 = lowest latency / fastest
    // first token). Drives the "Fast #X" badge. Distinct from throughput_rank (tokens/sec).
    #[serde(
        default,
        rename = "latencyRank",
        skip_serializing_if = "Option::is_none"
    )]
    latency_rank: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tokenizer: Option<String>,
    #[serde(
        default,
        rename = "maxCompletionTokens",
        skip_serializing_if = "Option::is_none"
    )]
    max_completion_tokens: Option<i64>,
    #[serde(
        default,
        rename = "isModerated",
        skip_serializing_if = "Option::is_none"
    )]
    is_moderated: Option<bool>,
    #[serde(
        default,
        rename = "knowledgeCutoff",
        skip_serializing_if = "Option::is_none"
    )]
    knowledge_cutoff: Option<String>,
    #[serde(
        default,
        rename = "expirationDate",
        skip_serializing_if = "Option::is_none"
    )]
    expiration_date: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterModelsResponse {
    data: Vec<OpenRouterAPIModel>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterAPIModel {
    id: String,
    name: String,
    #[serde(default)]
    created: Option<i64>,
    #[serde(default)]
    context_length: Option<i64>,
    #[serde(default)]
    pricing: OpenRouterAPIPricing,
    #[serde(default)]
    architecture: OpenRouterAPIArchitecture,
    #[serde(default)]
    supported_parameters: Vec<String>,
    #[serde(default)]
    top_provider: OpenRouterAPITopProvider,
    #[serde(default)]
    knowledge_cutoff: Option<String>,
    #[serde(default)]
    expiration_date: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct OpenRouterAPIPricing {
    #[serde(default)]
    prompt: Option<serde_json::Value>,
    #[serde(default)]
    completion: Option<serde_json::Value>,
}

#[derive(Debug, Default, Deserialize)]
struct OpenRouterAPIArchitecture {
    #[serde(default)]
    tokenizer: Option<String>,
    #[serde(default)]
    input_modalities: Vec<String>,
    #[serde(default)]
    output_modalities: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct OpenRouterAPITopProvider {
    #[serde(default)]
    max_completion_tokens: Option<i64>,
    #[serde(default)]
    is_moderated: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterRankingsDailyResponse {
    data: Vec<OpenRouterRankingDailyRow>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterRankingDailyRow {
    date: String,
    model_permaslug: String,
    total_tokens: serde_json::Value,
}

#[derive(Clone, Debug, Serialize)]
struct OpenRouterAPIKeyState {
    configured: bool,
    path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PermissionStatus {
    keyboard: bool,
    accessibility: bool,
    screen: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct LoginItemState {
    supported: bool,
    enabled: bool,
    status: String,
    message: String,
}

impl LoginItemState {
    fn unsupported(message: impl Into<String>) -> Self {
        Self {
            supported: false,
            enabled: false,
            status: "unsupported".to_string(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
struct ActionResult {
    title: String,
    message: String,
    ok: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PermissionRequest {
    action: String,
    nonce: String,
    #[serde(rename = "createdAt")]
    created_at: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PermissionResponse {
    title: String,
    message: String,
    ok: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct RequestLogFile {
    entries: Vec<RequestLogEntryState>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RequestLogEntryState {
    id: String,
    timestamp: String,
    source: String,
    #[serde(rename = "providerTitle")]
    provider_title: String,
    model: String,
    #[serde(rename = "inputPreview")]
    input_preview: String,
    #[serde(rename = "outputPreview")]
    output_preview: String,
    #[serde(rename = "promptTokens")]
    prompt_tokens: i64,
    #[serde(rename = "completionTokens")]
    completion_tokens: i64,
    #[serde(rename = "totalTokens")]
    total_tokens: i64,
    #[serde(rename = "costCredits")]
    cost_credits: Option<f64>,
    #[serde(rename = "usageSource")]
    usage_source: String,
    #[serde(rename = "isDuplicateSuspect")]
    is_duplicate_suspect: bool,
    #[serde(rename = "imageInfo")]
    image_info: Option<String>,
    fingerprint: String,
}

#[derive(Clone, Debug, Serialize)]
struct RequestLogSummaryState {
    #[serde(rename = "requestCount")]
    request_count: usize,
    #[serde(rename = "duplicateSuspectCount")]
    duplicate_suspect_count: usize,
    #[serde(rename = "promptTokens")]
    prompt_tokens: i64,
    #[serde(rename = "completionTokens")]
    completion_tokens: i64,
    #[serde(rename = "totalTokens")]
    total_tokens: i64,
    #[serde(rename = "costCredits")]
    cost_credits: f64,
}

#[derive(Clone, Debug, Serialize)]
struct RequestLogsState {
    entries: Vec<RequestLogEntryState>,
    summary: RequestLogSummaryState,
    #[serde(rename = "storagePath")]
    storage_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct BenchmarkResult {
    output: String,
    ok: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct TranslationPreviewState {
    mode: String,
    #[serde(rename = "sourceLanguage")]
    source_language: String,
    #[serde(rename = "targetLanguage")]
    target_language: String,
    #[serde(rename = "didReverseBecauseLanguagesMatched", default)]
    did_reverse_because_languages_matched: bool,
    #[serde(rename = "originalText")]
    original_text: String,
    #[serde(rename = "translatedText")]
    translated_text: String,
    #[serde(rename = "translatedImageURL", default)]
    translated_image_url: Option<String>,
    #[serde(rename = "errorText")]
    error_text: Option<String>,
    #[serde(rename = "providerTitle")]
    provider_title: String,
    model: String,
    #[serde(rename = "modelWarning", default)]
    model_warning: Option<String>,
    #[serde(rename = "costCredits")]
    cost_credits: Option<f64>,
    #[serde(rename = "permissionAction")]
    permission_action: Option<String>,
    #[serde(rename = "toastDuration", default = "default_toast_duration_value")]
    toast_duration: f64,
    #[serde(rename = "requestSequence", default)]
    request_sequence: u64,
    #[serde(rename = "caretX", default)]
    caret_x: Option<f64>,
    #[serde(rename = "caretY", default)]
    caret_y: Option<f64>,
    #[serde(rename = "caretW", default)]
    caret_w: Option<f64>,
    #[serde(rename = "caretH", default)]
    caret_h: Option<f64>,
    #[serde(rename = "anchorBottom", default)]
    anchor_bottom: bool,
}

#[derive(Clone, Debug)]
struct TranslationPreviewRequest {
    mode: String,
    debug: bool,
}

#[derive(Clone, Copy, Debug, Deserialize)]
struct PhysicalToastPosition {
    x: f64,
    y: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct ScreenRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct WorkArea {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scale: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum TranslationArrowPlacement {
    BelowCaret,
    AboveCaret,
    Fallback,
}

impl TranslationArrowPlacement {
    fn as_query_value(self) -> &'static str {
        match self {
            // Fallback means the toast floats in a screen corner with no caret to point at, so the
            // Svelte bubble must hide its arrow instead of pointing at empty space.
            Self::Fallback => "none",
            Self::BelowCaret => "below",
            Self::AboveCaret => "above",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct TranslationWindowPlacement {
    position: PhysicalPosition<i32>,
    arrow: TranslationArrowPlacement,
}

#[tauri::command]
fn load_settings(app: AppHandle) -> Result<SettingsState, String> {
    state_from_disk(&app)
}

#[tauri::command]
fn refresh_openrouter_models(app: AppHandle) -> Result<SettingsState, String> {
    let api_key = openrouter_api_key().unwrap_or(None);
    let models = fetch_openrouter_models(api_key.as_deref())?;
    write_openrouter_models_cache(&app, &models)?;
    state_from_disk(&app)
}

#[tauri::command]
fn save_settings(app: AppHandle, settings: Settings) -> Result<SettingsState, String> {
    write_settings(&app, normalize_settings(settings))?;
    state_from_disk(&app)
}

#[tauri::command]
fn login_item_status(app: AppHandle) -> LoginItemState {
    login_item_state_impl(&app).unwrap_or_else(|error| {
        LoginItemState::unsupported(format!("Login item status unavailable: {error}"))
    })
}

#[tauri::command]
fn set_launch_at_login(app: AppHandle, enabled: bool) -> Result<LoginItemState, String> {
    set_launch_at_login_impl(&app, enabled)
}

#[tauri::command]
fn reset_setting(app: AppHandle, field: String) -> Result<SettingsState, String> {
    let mut settings = load_effective_settings(&app)?;
    let defaults = default_settings_for_current_variant();

    match field.as_str() {
        "provider" => settings.provider = defaults.provider,
        "localModelID" => settings.local_model_id = defaults.local_model_id,
        "sourceLanguage" => settings.source_language = defaults.source_language,
        "targetLanguage" => settings.target_language = defaults.target_language,
        "toastPosition" => {
            settings.toast_position = defaults.toast_position;
            settings.toast_custom_position = defaults.toast_custom_position;
        }
        "localHyMT2BackendPath" => {
            settings.local_hy_mt2_backend_path = defaults.local_hy_mt2_backend_path
        }
        "customLocalModelsPath" => {
            settings.custom_local_models_path = defaults.custom_local_models_path
        }
        "openRouterTextModel" => settings.open_router_text_model = defaults.open_router_text_model,
        "openRouterVisionModel" => {
            settings.open_router_vision_model = defaults.open_router_vision_model
        }
        "favoriteLocalModelIDs" => {
            settings.favorite_local_model_ids = defaults.favorite_local_model_ids
        }
        "favoriteOpenRouterModels" => {
            settings.favorite_open_router_models = defaults.favorite_open_router_models
        }
        "openRouterModelFilter" => {
            settings.open_router_model_filter = defaults.open_router_model_filter
        }
        _ => return Err(format!("Unknown setting field: {field}")),
    }

    write_settings(&app, settings)?;
    state_from_disk(&app)
}

#[tauri::command]
fn load_openrouter_api_key_state() -> Result<OpenRouterAPIKeyState, String> {
    openrouter_api_key_state()
}

#[tauri::command]
fn save_openrouter_api_key(value: String) -> Result<OpenRouterAPIKeyState, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("OpenRouter API key is empty.".to_string());
    }
    write_env_key("OPENROUTER_API_KEY", Some(trimmed))?;
    openrouter_api_key_state()
}

#[tauri::command]
fn clear_openrouter_api_key() -> Result<OpenRouterAPIKeyState, String> {
    write_env_key("OPENROUTER_API_KEY", None)?;
    openrouter_api_key_state()
}

#[tauri::command]
fn perform_settings_action(
    app: AppHandle,
    action: String,
    settings: Settings,
) -> Result<ActionResult, String> {
    let settings = normalize_settings(settings);
    match action.as_str() {
        "runTextTest" => run_legacy_cli(
            &app,
            legacy_cli_args(
                &settings,
                &[
                    "--translate-text-once",
                    "The quick brown fox jumps over the lazy dog.",
                ],
            ),
            "Text Test",
        ),
        "translateScreenshot" => request_screenshot_translation(&app, &settings),
        "showRequestLogs" => open_surface_action(&app, AppSurface::RequestLogs, "Request Logs"),
        "showLocalModelSetup" => {
            open_surface_action(&app, AppSurface::LocalModelSetup, "Model Setup")
        }
        // The permissions window is native in the Swift host on every variant
        // now (the Tauri permission-helper surface is gone): TCC preflight and
        // requests only mean anything in the process that taps the keyboard and
        // captures the screen, and that is the host, not this helper.
        "openPermissionHelper" => request_host_permission(&app, "show"),
        "requestScreenRecording" => request_host_permission(&app, "screen"),
        _ => Err(format!("Unknown settings action: {action}")),
    }
}

#[tauri::command]
fn open_screen_recording_settings(app: AppHandle) -> Result<ActionResult, String> {
    request_host_permission(&app, "screen")
}

#[tauri::command]
fn load_translation_preview(app: AppHandle) -> Result<TranslationPreviewState, String> {
    let settings =
        load_effective_settings(&app).unwrap_or_else(|_| default_settings_for_current_variant());
    read_translation_preview_state(&app).map(|state| {
        let mut state = state.unwrap_or_else(|| sample_translation_preview(&settings));
        state.toast_duration = settings.toast_duration;
        state
    })
}

#[tauri::command]
async fn translate_preview_to_language(
    app: AppHandle,
    target_language: String,
) -> Result<TranslationPreviewState, String> {
    let settings = apply_preview_target_language(load_effective_settings(&app)?, &target_language)?;
    write_settings(&app, settings)?;
    let settings = load_effective_settings(&app)?;
    let target_language = settings.target_language.clone();
    run_retranslate_off_main_thread(app, settings, Some(target_language)).await
}

#[tauri::command]
async fn translate_preview_to_model(
    app: AppHandle,
    provider: TranslationProvider,
    model_id: String,
) -> Result<TranslationPreviewState, String> {
    let settings =
        apply_preview_model_selection(load_effective_settings(&app)?, provider, &model_id)?;
    write_settings(&app, settings)?;
    let settings = load_effective_settings(&app)?;
    run_retranslate_off_main_thread(app, settings, None).await
}

// The commands are async so Tauri runs them off the main thread, and the blocking subprocess +
// streaming reads go to the blocking pool. This is what un-freezes the toast: the main thread keeps
// painting, so it can show the "translating" view and stream partials while the new model runs.
async fn run_retranslate_off_main_thread(
    app: AppHandle,
    settings: Settings,
    target_language: Option<String>,
) -> Result<TranslationPreviewState, String> {
    tauri::async_runtime::spawn_blocking(move || {
        retranslate_preview(&app, settings, target_language)
    })
    .await
    .map_err(|error| format!("Retranslation task failed: {error}"))?
}

// One NDJSON event from the streaming retranslate CLI (`--emit-partials`): `partial` carries the
// cumulative text-so-far for live rendering, `final` the cleaned result. Unknown lines are ignored.
#[derive(Deserialize)]
struct PreviewStreamEvent {
    #[serde(default)]
    partial: Option<String>,
    #[serde(default, rename = "final")]
    final_text: Option<String>,
}

fn retranslate_preview(
    app: &AppHandle,
    settings: Settings,
    target_language: Option<String>,
) -> Result<TranslationPreviewState, String> {
    let mut state = read_translation_preview_state(app)?
        .unwrap_or_else(|| sample_translation_preview(&settings));
    prepare_translation_preview_for_retranslate(&mut state, &settings, target_language);
    if state.original_text.trim().is_empty() || state.original_text == "[screen screenshot]" {
        state.mode = "error".to_string();
        state.error_text = Some("Cannot retranslate this preview without source text.".to_string());
        write_translation_preview_state(app, &state)?;
        return Ok(state);
    }

    // Flip the live toast to its "translating" view right away — same window, same requestSequence so
    // it stays in place (no reposition/reshow, so no extra window) — instead of leaving the stale
    // result frozen until the new model finishes. The watcher + JS poll pick this up within ~200ms.
    state.mode = "loading".to_string();
    state.translated_text = String::new();
    state.translated_image_url = None;
    state.error_text = None;
    write_translation_preview_state(app, &state)?;

    let mut translation_settings = settings;
    translation_settings.source_language = state.source_language.clone();
    translation_settings.target_language = state.target_language.clone();

    let original_text = state.original_text.clone();
    let args = legacy_cli_args(
        &translation_settings,
        &[
            "--translate-text-once",
            original_text.as_str(),
            "--emit-partials",
        ],
    );
    let binary = legacy_binary_path(app)?;
    let mut command = Command::new(&binary);
    command
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // NSWorkspace launches this Tauri helper with cwd `/`, but the spawned Swift CLI
    // resolves `scripts/runtimes/<backend>.py` relative to its cwd. Pin the workspace
    // root so local-model retranslation does not fail with localModelUnavailable.
    if let Some(dir) = legacy_working_dir(app) {
        command.current_dir(dir);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not run {}: {error}", binary.display()))?;

    // Stream each cumulative partial into the shared state file as it arrives so the toast grows the
    // translation in place (matching the Cmd+C flow), instead of the text popping in fully formed.
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Could not capture retranslation output.".to_string())?;
    let mut final_text: Option<String> = None;
    for line in BufReader::new(stdout).lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => break,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Non-JSON noise (e.g. a local backend's diagnostics) is skipped, not fatal.
        let event: PreviewStreamEvent = match serde_json::from_str(trimmed) {
            Ok(event) => event,
            Err(_) => continue,
        };
        if let Some(partial) = event.partial {
            state.mode = "translated".to_string();
            state.translated_text = partial;
            state.translated_image_url = None;
            state.error_text = None;
            let _ = write_translation_preview_state(app, &state);
        } else if let Some(text) = event.final_text {
            final_text = Some(text);
        }
    }

    let output = child
        .wait_with_output()
        .map_err(|error| format!("Could not run {}: {error}", binary.display()))?;
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if output.status.success() {
        // Prefer the explicit final line; fall back to the last streamed partial if it never arrived.
        let text = final_text.unwrap_or_else(|| state.translated_text.clone());
        if text.trim().is_empty() {
            state.mode = "error".to_string();
            state.error_text = Some(first_non_empty(&stderr, "Translation produced no text."));
        } else {
            state.mode = "translated".to_string();
            state.translated_text = text;
            state.error_text = None;
        }
    } else {
        state.mode = "error".to_string();
        state.error_text = Some(first_non_empty(&stderr, "Translation failed."));
    }
    write_translation_preview_state(app, &state)?;
    Ok(state)
}

#[tauri::command]
fn close_translation_preview(app: AppHandle) -> Result<(), String> {
    // Hide (never exit) so the warm WebView and its font cache survive for the next translation.
    if let Some(window) = app.get_webview_window("translation") {
        window.hide().map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn resize_translation_preview(
    app: AppHandle,
    height: f64,
    width: f64,
    anchor_bottom: bool,
) -> Result<(), String> {
    let window = app
        .get_webview_window("translation")
        .ok_or("Translation window is not available.")?;
    // Cap to the monitor work area (minus a margin) instead of a fixed 720px, otherwise a tall
    // image-translation result grows past the cap and the bottom — including the close button and
    // the "do not auto-dismiss" notice — is clipped off-screen with no way to close it. Fall back
    // to 720 when the monitor is unknown.
    let max_height = window
        .current_monitor()
        .ok()
        .flatten()
        .map(|monitor| work_area_from_monitor(&monitor).height - TRANSLATION_WINDOW_MARGIN * 2.0)
        .filter(|height| *height > TRANSLATION_WINDOW_HEIGHT)
        .unwrap_or(720.0);
    let clamped = height.clamp(TRANSLATION_WINDOW_HEIGHT, max_height);
    let width = width.clamp(TRANSLATION_WINDOW_WIDTH, 820.0);
    let scale = window.scale_factor().map_err(|error| error.to_string())?;
    let previous = window.outer_size().map_err(|error| error.to_string())?;
    window
        .set_size(LogicalSize::new(width, clamped))
        .map_err(|error| error.to_string())?;
    if anchor_bottom {
        // Keep the bottom edge (which points at the caret) fixed by moving the top up
        // by however much the window grew.
        let position = window.outer_position().map_err(|error| error.to_string())?;
        let grown = (clamped * scale).round() as i32 - previous.height as i32;
        window
            .set_position(PhysicalPosition::new(position.x, position.y - grown))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn open_translation_image_in_preview(app: AppHandle, image_data: Vec<u8>) -> Result<(), String> {
    if image_data.len() < 8 || &image_data[..8] != b"\x89PNG\r\n\x1a\n" {
        return Err("Translated image is not a PNG.".to_string());
    }
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let dir = shared_data_dir(&app)?.join("image-preview");
    fs::create_dir_all(&dir)
        .map_err(|error| format!("Could not create {}: {error}", dir.display()))?;
    let path = dir.join(format!("translated-{timestamp}.png"));
    fs::write(&path, image_data)
        .map_err(|error| format!("Could not write {}: {error}", path.display()))?;

    #[cfg(target_os = "macos")]
    {
        Command::new("/usr/bin/open")
            .args(["-a", "Preview"])
            .arg(&path)
            .spawn()
            .map_err(|error| format!("Could not open Preview: {error}"))?;
    }
    #[cfg(not(target_os = "macos"))]
    {
        Command::new("xdg-open")
            .arg(&path)
            .spawn()
            .map_err(|error| format!("Could not open image viewer: {error}"))?;
    }
    Ok(())
}

#[derive(Clone, Serialize)]
struct ShowToastResult {
    arrow: String,
    #[serde(rename = "anchorBottom")]
    anchor_bottom: bool,
}

#[tauri::command]
fn show_translation_toast(app: AppHandle) -> Result<ShowToastResult, String> {
    show_translation_toast_inner(&app)
}

// Shared by the JS command and the native watcher thread. Takes &AppHandle so the watcher can call
// it from inside run_on_main_thread without moving ownership; window ops must run on the main thread.
fn show_translation_toast_inner(app: &AppHandle) -> Result<ShowToastResult, String> {
    let window = app
        .get_webview_window("translation")
        .ok_or("Translation window is not available.")?;
    let settings =
        load_effective_settings(app).unwrap_or_else(|_| default_settings_for_current_variant());
    let state = read_translation_preview_state(app)?;
    let (mode, caret) = match &state {
        Some(s) => {
            let caret = match (s.caret_x, s.caret_y, s.caret_w, s.caret_h) {
                (Some(x), Some(y), Some(w), Some(h)) => ScreenRect::new(x, y, w, h),
                _ => None,
            };
            (s.mode.clone(), caret)
        }
        None => ("translated".to_string(), None),
    };
    let height = if mode == "loading" || mode == "error" {
        TRANSLATION_TALL_WINDOW_HEIGHT
    } else {
        TRANSLATION_WINDOW_HEIGHT
    };
    let placement =
        translation_window_placement(app, &settings, TRANSLATION_WINDOW_WIDTH, height, caret);
    let anchor_bottom = match placement.arrow {
        TranslationArrowPlacement::AboveCaret => true,
        TranslationArrowPlacement::BelowCaret => false,
        TranslationArrowPlacement::Fallback => matches!(
            settings.toast_position,
            ToastPosition::BottomRight | ToastPosition::BottomLeft
        ),
    };
    window
        .set_size(LogicalSize::new(TRANSLATION_WINDOW_WIDTH, height))
        .map_err(|error| error.to_string())?;
    let _ = window.set_position(placement.position);
    apply_toast_theme(&window);
    window.show().map_err(|error| error.to_string())?;
    // Re-apply on the visible window: at build time the window is hidden and the effect's view tree may not
    // be realized yet, so the build-time mask can miss. Re-masking here (idempotent) guarantees it lands.
    #[cfg(target_os = "macos")]
    macos_toast::mask_toast_material_to_card(&window);
    Ok(ShowToastResult {
        arrow: placement.arrow.as_query_value().to_string(),
        anchor_bottom,
    })
}

fn toast_refresh_should_show(
    seq: u64,
    mode: &str,
    last_shown_sequence: u64,
    previous_mode: Option<&str>,
) -> bool {
    if seq == 0 {
        return false;
    }
    seq != last_shown_sequence || (mode != "loading" && previous_mode == Some("loading"))
}

#[derive(Clone, Serialize)]
struct ToastRefreshPayload {
    #[serde(rename = "requestSequence")]
    request_sequence: u64,
    shown: Option<ShowToastResult>,
}

// macOS throttles then fully suspends a hidden WebView's JS timers (measured 200ms -> 1Hz -> 0), so
// the persistent toast's in-page setInterval cannot reliably detect a new translation while hidden.
// This native OS thread is immune to that WebKit page-visibility throttling: it watches the shared
// state file and, on a new requestSequence, shows the window on the main thread; the show un-suspends
// the WebView, then the emit makes it re-render. Emit fires only on content change to avoid IPC spam.
fn start_translation_toast_watcher(app: AppHandle) {
    let _ = std::thread::Builder::new()
        .name("translation-toast-watcher".into())
        .spawn(move || {
            use tauri::Emitter;
            let mut last_shown_sequence: u64 = 0;
            let mut last_mode: Option<String> = None;
            let mut last_fingerprint: Option<(
                u64,
                String,
                String,
                String,
                String,
                String,
                String,
                bool,
            )> = None;
            loop {
                std::thread::sleep(std::time::Duration::from_millis(180));
                // The claimed launch file is a lease: the sandboxed Swift
                // shell cannot pkill this process, so it deletes the file to
                // request shutdown (helper replacement, app quit).
                if let Some(lease) = claimed_lease_path() {
                    if !lease.exists() {
                        std::process::exit(0);
                    }
                }
                let state = match read_translation_preview_state(&app) {
                    Ok(Some(state)) => state,
                    // Skip transient parse failures from the writer's non-atomic mid-write window.
                    _ => continue,
                };
                let seq = state.request_sequence;
                let fingerprint = (
                    seq,
                    state.mode.clone(),
                    state.target_language.clone(),
                    state.original_text.clone(),
                    state.translated_text.clone(),
                    state.error_text.clone().unwrap_or_default(),
                    state.model.clone(),
                    state.did_reverse_because_languages_matched,
                );
                if last_fingerprint.as_ref() == Some(&fingerprint) {
                    continue;
                }
                last_fingerprint = Some(fingerprint);
                let should_show = toast_refresh_should_show(
                    seq,
                    &state.mode,
                    last_shown_sequence,
                    last_mode.as_deref(),
                );
                last_mode = Some(state.mode.clone());
                if should_show {
                    last_shown_sequence = seq;
                }
                let main_app = app.clone();
                let _ = app.run_on_main_thread(move || {
                    let shown = if should_show {
                        show_translation_toast_inner(&main_app).ok()
                    } else {
                        None
                    };
                    let _ = main_app.emit_to(
                        "translation",
                        "toast-refresh",
                        ToastRefreshPayload {
                            request_sequence: seq,
                            shown,
                        },
                    );
                });
            }
        });
}

#[tauri::command]
fn save_translation_preview_position(
    app: AppHandle,
    position: PhysicalToastPosition,
) -> Result<(), String> {
    let mut settings = load_effective_settings(&app)?;
    settings.toast_position = ToastPosition::Custom;
    settings.toast_custom_position = Some(logical_toast_position(&app, position));
    write_settings(&app, normalize_settings(settings))
}

#[tauri::command]
fn open_app_surface(app: AppHandle, surface: String) -> Result<ActionResult, String> {
    let surface =
        AppSurface::from_key(&surface).ok_or_else(|| format!("Unknown app surface: {surface}"))?;
    open_surface_action(&app, surface, surface.key())
}

#[tauri::command]
fn complete_local_model_setup(app: AppHandle, settings: Settings) -> Result<SettingsState, String> {
    let mut settings = normalize_settings(settings);
    settings.has_completed_local_model_selection = true;
    write_settings(&app, settings)?;
    state_from_disk(&app)
}

#[tauri::command]
fn prepare_custom_local_models(app: AppHandle) -> Result<SettingsState, String> {
    let mut settings = load_effective_settings(&app)?;
    if settings.custom_local_models_path.is_none() {
        settings.custom_local_models_path = Some("~/.config/cctrans/local-models.json".to_string());
        write_settings(&app, settings)?;
    }
    state_from_disk(&app)
}

#[tauri::command]
fn run_local_model_benchmark(
    app: AppHandle,
    settings: Settings,
    source_language: String,
    target_language: String,
) -> Result<BenchmarkResult, String> {
    if !settings_runtime().supports_provider(TranslationProvider::LocalHyMT2) {
        return Err("Local model benchmarks are not available in this app variant.".to_string());
    }
    let mut settings = normalize_settings(settings);
    settings.provider = TranslationProvider::LocalHyMT2;
    settings.source_language = source_language;
    settings.target_language = target_language;
    let args = legacy_cli_args(
        &settings,
        &["--benchmark-local-models", "--sample-limit", "9"],
    );
    let binary = legacy_binary_path(&app)?;
    let output = Command::new(&binary)
        .args(&args)
        .output()
        .map_err(|error| format!("Could not run {}: {error}", binary.display()))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Ok(BenchmarkResult {
        output: first_non_empty(&stdout, &stderr),
        ok: output.status.success(),
    })
}

#[tauri::command]
fn load_request_logs(app: AppHandle) -> Result<RequestLogsState, String> {
    request_logs_state(&app)
}

#[tauri::command]
fn clear_request_logs(app: AppHandle) -> Result<RequestLogsState, String> {
    write_request_log_file(&app, &RequestLogFile::default())?;
    request_logs_state(&app)
}

#[cfg(target_os = "macos")]
fn system_prefers_dark() -> bool {
    // Read the global AppleInterfaceStyle default directly: once set_theme pins a transparent
    // WebView, window.theme() reports that pinned value, so it cannot detect later system changes.
    use objc2_foundation::{NSString, NSUserDefaults};
    let defaults = NSUserDefaults::standardUserDefaults();
    let key = NSString::from_str("AppleInterfaceStyle");
    defaults
        .stringForKey(&key)
        .map(|value| value.to_string().eq_ignore_ascii_case("dark"))
        .unwrap_or(false)
}

#[cfg(not(target_os = "macos"))]
fn system_prefers_dark() -> bool {
    false
}

fn apply_toast_theme(window: &tauri::WebviewWindow) {
    // The transparent toast WebView does not follow the system color scheme on its own (unlike the
    // vibrancy-backed settings window), so force the current system theme every time it is shown.
    let theme = if system_prefers_dark() {
        tauri::Theme::Dark
    } else {
        tauri::Theme::Light
    };
    let _ = window.set_theme(Some(theme));
}

pub fn run() {
    if sandbox_container_active() && effective_args().is_empty() {
        // A bare sandboxed boot has no launch request: argv from the Swift
        // shell never arrives under App Sandbox, and no pending launch file
        // was claimed. This is a state-restore ghost (or a manual run);
        // exiting beats defaulting to a settings window with the wrong
        // variant, which is what a silent fallback used to produce.
        eprintln!("cctrans-tauri: sandboxed boot without a launch request; exiting.");
        std::process::exit(0);
    }
    tauri::Builder::default()
        .setup(|app| {
            if let Some(request) = translation_preview_request() {
                // The toast is a transient popover, so force this helper process to run as an
                // accessory: no Dock icon and no focus stealing from the app the user copied from.
                #[cfg(target_os = "macos")]
                let _ = app.set_activation_policy(ActivationPolicy::Accessory);
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
                let height = if request.debug {
                    TRANSLATION_DEBUG_WINDOW_HEIGHT
                } else if request.mode == "loading" || request.mode == "error" {
                    TRANSLATION_TALL_WINDOW_HEIGHT
                } else {
                    TRANSLATION_WINDOW_HEIGHT
                };
                // Built hidden and positioned per-translation by show_translation_toast, so one
                // warm WebView is reused instead of cold-starting a process on every Cmd+C.
                let url = persistent_translation_url(request.debug);
                let window =
                    WebviewWindowBuilder::new(app, "translation", WebviewUrl::App(url.into()))
                        .title("CCTrans Translation")
                        .inner_size(TRANSLATION_WINDOW_WIDTH, height)
                        .min_inner_size(TRANSLATION_WINDOW_WIDTH, height)
                        .resizable(false)
                        .decorations(false)
                        .transparent(true)
                        .always_on_top(true)
                        .skip_taskbar(true)
                        .focusable(false)
                        .focused(false)
                        .visible(false)
                        // Blur via the native NSVisualEffectView (windowEffects), not CSS
                        // backdrop-filter: on a transparent always-on-top WKWebView the CSS filter
                        // re-samples the live desktop behind the panel and intermittently drops for a
                        // frame (the visible "blur flicker"). The OS-composited material is stable.
                        // state=Active is mandatory because the toast is focusable(false)/non-key, so a
                        // default-state effect view would render inactive (desaturated). radius matches
                        // the bubble's 14px corners. UnderWindowBackground (not Popover): Popover's material
                        // is near-opaque white, so the masked card read as a solid white slab and the
                        // desktop never showed through (image #8 is a translucent glass that picks up the
                        // backdrop). UnderWindowBackground is the most translucent light material, so the
                        // card frosts the desktop behind it while staying readable via the 30% --bubble-bg tint.
                        .effects(
                            EffectsBuilder::new()
                                .effect(Effect::UnderWindowBackground)
                                .state(EffectState::Active)
                                .radius(14.0)
                                .build(),
                        )
                        .build()?;
                apply_toast_theme(&window);
                macos_toast::mask_toast_material_to_card(&window);
                macos_toast::install_pointer_monitor(app.handle().clone());
                start_translation_toast_watcher(app.handle().clone());
            } else if let Some(surface) = startup_surface() {
                if surface != AppSurface::Settings {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.hide();
                    }
                }
                open_surface_window(app.handle(), surface)?;
            }

            // Settings process: restore the last window frame and persist it on focus-loss/close so
            // the settings window reopens where the user left it (native-feel ship-readiness B.15).
            if translation_preview_request().is_none()
                && matches!(startup_surface(), None | Some(AppSurface::Settings))
            {
                if let Some(window) = app.get_webview_window("main") {
                    restore_main_window_geometry(app.handle(), &window);
                    let handle = app.handle().clone();
                    let geometry_window = window.clone();
                    window.on_window_event(move |event| {
                        if matches!(
                            event,
                            tauri::WindowEvent::Focused(false)
                                | tauri::WindowEvent::CloseRequested { .. }
                        ) {
                            let _ = save_main_window_geometry(&handle, &geometry_window);
                        }
                    });
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            load_settings,
            refresh_openrouter_models,
            save_settings,
            login_item_status,
            set_launch_at_login,
            reset_setting,
            load_openrouter_api_key_state,
            save_openrouter_api_key,
            clear_openrouter_api_key,
            perform_settings_action,
            open_app_surface,
            complete_local_model_setup,
            prepare_custom_local_models,
            run_local_model_benchmark,
            load_request_logs,
            clear_request_logs,
            load_translation_preview,
            translate_preview_to_language,
            translate_preview_to_model,
            save_translation_preview_position,
            open_screen_recording_settings,
            close_translation_preview,
            resize_translation_preview,
            open_translation_image_in_preview,
            show_translation_toast,
            close_settings_window
        ])
        .build(tauri::generate_context!())
        .expect("error while building CCTrans Tauri app")
        .run(|_app, event| {
            // The toast process must survive dismissing its only window so the next translation
            // reuses the warm WebView; only the toast process (not Settings) holds itself open.
            match event {
                tauri::RunEvent::ExitRequested { api, .. } => {
                    if translation_preview_request().is_some() {
                        api.prevent_exit();
                    }
                }
                tauri::RunEvent::Exit => {
                    // Free the claimed launch file so the Swift shell never
                    // mistakes a dead helper for a live one.
                    release_claimed_lease();
                }
                _ => {}
            }
        });
}

// ===== Mac App Store launch channel =====
//
// Under App Sandbox, NSWorkspace.OpenConfiguration.arguments from the Swift
// shell are silently dropped (documented macOS behavior for sandboxed
// callers), and the two bundle ids get separate sandbox containers, so argv
// and the default app_data_dir both stop working as IPC. The Swift shell
// instead writes a one-shot "pending-*.json" launch file into the shared App
// Group directory; this process claims it atomically (rename) on startup and
// treats its contents as argv. The claimed file doubles as a lease: the Swift
// side deletes it to ask a persistent helper to exit.

// Team-id-prefixed App Groups need no portal registration or provisioning
// profile entry on macOS, unlike iOS "group.*" identifiers.
const MAS_APP_GROUP_ID: &str = "6YQH3QFFK8.as.kargn.cctrans";

fn sandbox_container_active() -> bool {
    if std::env::var_os("APP_SANDBOX_CONTAINER_ID").is_some() {
        return true;
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return false;
    };
    let components = home
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>();
    components.windows(4).any(|window| {
        window[0].as_ref() == "Library"
            && window[1].as_ref() == "Containers"
            && window[2].starts_with("as.kargn.cctrans")
            && window[3].as_ref() == "Data"
    })
}

fn mas_shared_data_dir() -> Option<PathBuf> {
    if !sandbox_container_active() {
        return None;
    }
    // Sandboxed HOME is ~/Library/Containers/<bundle-id>/Data; the real user
    // home is four components up. The group container lives under the real
    // home and the sandbox grants access purely by entitlement + path prefix.
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let real_home = home.ancestors().nth(4)?.to_path_buf();
    Some(
        real_home
            .join("Library/Group Containers")
            .join(MAS_APP_GROUP_ID)
            .join("Library/Application Support/as.kargn.cctrans"),
    )
}

// Single source for every file shared with the Swift shell (settings
// overrides, toast state, request logs). Mirrors SharedAppStorage.swift.
fn shared_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    if let Some(dir) = mas_shared_data_dir() {
        return Ok(dir);
    }
    if let Some(host_id) = host_app_identifier() {
        let home = std::env::var("HOME").map_err(|_| "HOME is not set.".to_string())?;
        return Ok(host_application_support_dir(&PathBuf::from(home), &host_id));
    }
    app.path()
        .app_data_dir()
        .map_err(|error| format!("Could not resolve app data directory: {error}"))
}

fn host_application_support_dir(home: &Path, host_id: &str) -> PathBuf {
    home.join("Library/Application Support").join(host_id)
}

fn host_app_identifier() -> Option<String> {
    host_app_identifier_from_args(effective_args())
}

fn host_app_identifier_from_args(args: &[String]) -> Option<String> {
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--host-app-id=") {
            return sanitized_bundle_identifier(value);
        }
        if arg == "--host-app-id" {
            return args
                .next()
                .and_then(|value| sanitized_bundle_identifier(value));
        }
    }
    None
}

fn sanitized_bundle_identifier(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty()
        || !value.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '.' || character == '-'
        })
    {
        return None;
    }
    Some(value.to_string())
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperLaunch {
    arguments: Vec<String>,
    created_at: f64,
    #[serde(default)]
    pid: Option<u32>,
}

fn helper_launches_dir() -> Option<PathBuf> {
    mas_shared_data_dir().map(|dir| dir.join("helper-launches"))
}

// Login requests get their OWN subdir, NOT helper-launches: there the claimed-*
// files double as the helper shutdown lease, so reusing it would collide. The
// resident Swift host watches this dir and serves each request with
// SMAppService, where Bundle.main is the outer CCTrans.app. See
// request_login_item().
fn login_requests_dir() -> Option<PathBuf> {
    mas_shared_data_dir().map(|dir| dir.join("login-requests"))
}

// Screenshot-translate triggers get their own subdir. Only present in the MAS
// sandbox, where the capture cannot run in-helper without registering the wrong
// bundle in Screen Recording; off-sandbox this is None and the CLI path runs.
fn screenshot_requests_dir() -> Option<PathBuf> {
    mas_shared_data_dir().map(|dir| dir.join("screenshot-requests"))
}

fn permission_requests_dir(app: &AppHandle) -> Result<PathBuf, String> {
    shared_data_dir(app).map(|dir| dir.join("permission-requests"))
}

static CLAIMED_LEASE: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

fn claimed_lease_path() -> Option<&'static PathBuf> {
    CLAIMED_LEASE.get().and_then(|lease| lease.as_ref())
}

fn release_claimed_lease() {
    if let Some(path) = claimed_lease_path() {
        let _ = fs::remove_file(path);
    }
}

fn claim_launch_file() -> Option<Vec<String>> {
    let dir = helper_launches_dir()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs_f64();
    let mut pending: Vec<PathBuf> = fs::read_dir(&dir)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with("pending-") && name.ends_with(".json"))
                .unwrap_or(false)
        })
        .collect();
    // File names embed the epoch-millisecond write time, so a lexical sort is
    // chronological and the oldest pending launch is claimed first.
    pending.sort();

    for path in pending {
        let Ok(data) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(mut launch) = serde_json::from_str::<HelperLaunch>(&data) else {
            let _ = fs::remove_file(&path);
            continue;
        };
        // A pending file the launched process never claimed (crash, kill)
        // must not arm a future unrelated boot, e.g. macOS window restore.
        if now - launch.created_at > 30.0 {
            let _ = fs::remove_file(&path);
            continue;
        }
        let pid = std::process::id();
        let claimed = dir.join(format!("claimed-{pid}.json"));
        if fs::rename(&path, &claimed).is_err() {
            // Another helper instance won the rename race; try the next file.
            continue;
        }
        launch.pid = Some(pid);
        if let Ok(serialized) = serde_json::to_string_pretty(&launch) {
            let _ = fs::write(&claimed, serialized);
        }
        let _ = CLAIMED_LEASE.set(Some(claimed));
        return Some(launch.arguments);
    }
    None
}

// argv when present (dev/direct builds), otherwise the claimed launch file
// (sandboxed MAS builds). Every flag reader below must go through this.
fn effective_args() -> &'static [String] {
    static ARGS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    ARGS.get_or_init(|| {
        let argv: Vec<String> = std::env::args().skip(1).collect();
        if !argv.is_empty() {
            let _ = CLAIMED_LEASE.set(None);
            return argv;
        }
        let claimed = claim_launch_file();
        let _ = CLAIMED_LEASE.set(None); // no-op if claim_launch_file set it
        claimed.unwrap_or_default()
    })
}

fn startup_surface() -> Option<AppSurface> {
    let mut args = effective_args().iter();
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--surface=") {
            return AppSurface::from_key(value);
        }
        if arg.as_str() == "--surface" {
            return args.next().and_then(|value| AppSurface::from_key(value));
        }
    }
    None
}

fn translation_preview_request() -> Option<TranslationPreviewRequest> {
    let mut enabled = false;
    let mut mode = "translated".to_string();
    let mut debug = false;

    for arg in effective_args() {
        if arg.as_str() == "--translation-preview" {
            enabled = true;
        } else if arg.as_str() == "--translation-preview-debug" {
            enabled = true;
            debug = true;
        } else if let Some(value) = arg.strip_prefix("--translation-preview-state=") {
            enabled = true;
            mode = normalized_translation_mode(value).to_string();
        }
    }

    enabled.then_some(TranslationPreviewRequest { mode, debug })
}

fn persistent_translation_url(debug: bool) -> String {
    // Persistent toasts are reused across loading/result/error states. Do not pin `mode` in the URL;
    // the shared preview state is the runtime source of truth.
    format!(
        "index.html?surface=translation&debug={}",
        if debug { "1" } else { "0" }
    )
}

fn normalized_translation_mode(value: &str) -> &'static str {
    match value {
        "loading" => "loading",
        "original" => "original",
        "error" => "error",
        _ => "translated",
    }
}

fn translation_window_placement(
    app: &AppHandle,
    settings: &Settings,
    logical_width: f64,
    logical_height: f64,
    caret_override: Option<ScreenRect>,
) -> TranslationWindowPlacement {
    let monitors = app.available_monitors().unwrap_or_default();
    let fallback_monitor = app.primary_monitor().ok().flatten();
    // Caret comes solely from the host-supplied override (KeyboardCaretLocator runs
    // in the outer CCTrans.app and writes the rect into the shared toast state). The
    // helper must NOT query AX itself: an unauthorized AXUIElement* call from this
    // process registers the inner CCTransTauri.app in the macOS Accessibility list,
    // and the host's richer search already finds every caret the helper's simpler
    // system-wide query could.
    let caret = caret_override;

    // The popover follows the text caret whenever one is detected, so a saved corner or dragged
    // custom position only acts as the fallback for apps (terminals, Electron) that expose no caret.
    if let Some(caret) = caret {
        if let Some(work_area) = work_area_for_caret(&monitors, &caret)
            .or_else(|| fallback_monitor.as_ref().map(work_area_from_monitor))
        {
            return placement_near_caret(caret, work_area, logical_width, logical_height);
        }
    }

    if matches!(settings.toast_position, ToastPosition::Custom) {
        let work_area = work_area_for_custom_position(&monitors, settings.toast_custom_position)
            .or_else(|| fallback_monitor.as_ref().map(work_area_from_monitor))
            .or_else(|| monitors.first().map(work_area_from_monitor))
            .unwrap_or(WorkArea {
                x: 0.0,
                y: 0.0,
                width: 1440.0,
                height: 900.0,
                scale: 1.0,
            });
        return fallback_placement(settings, work_area, logical_width, logical_height);
    }

    let work_area = fallback_monitor
        .as_ref()
        .map(work_area_from_monitor)
        .or_else(|| monitors.first().map(work_area_from_monitor))
        .unwrap_or(WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1440.0,
            height: 900.0,
            scale: 1.0,
        });
    fallback_placement(settings, work_area, logical_width, logical_height)
}

fn work_area_for_caret(monitors: &[Monitor], caret: &ScreenRect) -> Option<WorkArea> {
    monitors
        .iter()
        .map(work_area_from_monitor)
        .find(|work_area| {
            let center_x = caret.mid_x();
            let center_y = caret.mid_y();
            center_x >= work_area.x
                && center_x <= work_area.max_x()
                && center_y >= work_area.y
                && center_y <= work_area.max_y()
        })
}

fn work_area_from_monitor(monitor: &Monitor) -> WorkArea {
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    WorkArea {
        x: area.position.x as f64 / scale,
        y: area.position.y as f64 / scale,
        width: area.size.width as f64 / scale,
        height: area.size.height as f64 / scale,
        scale,
    }
}

fn placement_near_caret(
    caret: ScreenRect,
    work_area: WorkArea,
    logical_width: f64,
    logical_height: f64,
) -> TranslationWindowPlacement {
    let x = clamp(
        caret.mid_x() - logical_width / 2.0,
        work_area.x + TRANSLATION_WINDOW_MARGIN,
        work_area.max_x() - logical_width - TRANSLATION_WINDOW_MARGIN,
    );

    let below_y = caret.max_y() + TRANSLATION_CARET_GAP;
    if below_y + logical_height <= work_area.max_y() - TRANSLATION_WINDOW_MARGIN {
        return TranslationWindowPlacement {
            position: physical_position(x, below_y, work_area.scale),
            arrow: TranslationArrowPlacement::BelowCaret,
        };
    }

    let above_y = caret.y - logical_height - TRANSLATION_CARET_GAP;
    if above_y >= work_area.y + TRANSLATION_WINDOW_MARGIN {
        return TranslationWindowPlacement {
            position: physical_position(x, above_y, work_area.scale),
            arrow: TranslationArrowPlacement::AboveCaret,
        };
    }

    let y = clamp(
        below_y,
        work_area.y + TRANSLATION_WINDOW_MARGIN,
        work_area.max_y() - logical_height - TRANSLATION_WINDOW_MARGIN,
    );
    TranslationWindowPlacement {
        position: physical_position(x, y, work_area.scale),
        arrow: TranslationArrowPlacement::BelowCaret,
    }
}

fn fallback_placement(
    settings: &Settings,
    work_area: WorkArea,
    logical_width: f64,
    logical_height: f64,
) -> TranslationWindowPlacement {
    let margin = TRANSLATION_WINDOW_MARGIN;
    let left = work_area.x + margin;
    let right = work_area.max_x() - logical_width - margin;
    let top = work_area.y + margin;
    let bottom = work_area.max_y() - logical_height - margin;

    let (x, y) = match settings.toast_position {
        ToastPosition::BottomRight => (right, bottom),
        ToastPosition::BottomLeft => (left, bottom),
        ToastPosition::TopRight => (right, top),
        ToastPosition::TopLeft => (left, top),
        ToastPosition::Custom => settings
            .toast_custom_position
            .map(|position| {
                (
                    clamp(position.x, left, right),
                    clamp(position.y, top, bottom),
                )
            })
            .unwrap_or((right, bottom)),
    };

    TranslationWindowPlacement {
        position: physical_position(x, y, work_area.scale),
        arrow: TranslationArrowPlacement::Fallback,
    }
}

fn work_area_for_custom_position(
    monitors: &[Monitor],
    position: Option<ToastCustomPosition>,
) -> Option<WorkArea> {
    let position = position?;
    monitors
        .iter()
        .map(work_area_from_monitor)
        .find(|work_area| {
            position.x >= work_area.x
                && position.x <= work_area.max_x()
                && position.y >= work_area.y
                && position.y <= work_area.max_y()
        })
}

fn logical_toast_position(app: &AppHandle, position: PhysicalToastPosition) -> ToastCustomPosition {
    let scale = app
        .available_monitors()
        .unwrap_or_default()
        .iter()
        .find(|monitor| {
            let monitor_position = monitor.position();
            let monitor_size = monitor.size();
            position.x >= monitor_position.x as f64
                && position.x <= monitor_position.x as f64 + monitor_size.width as f64
                && position.y >= monitor_position.y as f64
                && position.y <= monitor_position.y as f64 + monitor_size.height as f64
        })
        .map(Monitor::scale_factor)
        .unwrap_or(1.0);

    ToastCustomPosition {
        x: position.x / scale,
        y: position.y / scale,
    }
}

fn physical_position(x: f64, y: f64, scale: f64) -> PhysicalPosition<i32> {
    PhysicalPosition::new((x * scale).round() as i32, (y * scale).round() as i32)
}

fn clamp(value: f64, min: f64, max: f64) -> f64 {
    if min > max {
        return min;
    }
    value.clamp(min, max)
}

impl ScreenRect {
    fn new(x: f64, y: f64, width: f64, height: f64) -> Option<Self> {
        if !x.is_finite() || !y.is_finite() || !width.is_finite() || !height.is_finite() {
            return None;
        }
        if width < 0.0 || height <= 0.0 {
            return None;
        }
        Some(Self {
            x,
            y,
            width: width.max(1.0),
            height,
        })
    }

    fn mid_x(self) -> f64 {
        self.x + self.width / 2.0
    }

    fn mid_y(self) -> f64 {
        self.y + self.height / 2.0
    }

    fn max_y(self) -> f64 {
        self.y + self.height
    }
}

impl WorkArea {
    fn max_x(self) -> f64 {
        self.x + self.width
    }

    fn max_y(self) -> f64 {
        self.y + self.height
    }
}

fn read_translation_preview_state(
    app: &AppHandle,
) -> Result<Option<TranslationPreviewState>, String> {
    let path = translation_preview_path(app)?;
    if !path.exists() {
        return Ok(None);
    }

    let data = fs::read_to_string(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    let mut state: TranslationPreviewState = serde_json::from_str(&data)
        .map_err(|error| format!("Could not parse {}: {error}", path.display()))?;
    state.mode = normalized_translation_mode(&state.mode).to_string();
    Ok(Some(state))
}

fn write_translation_preview_state(
    app: &AppHandle,
    state: &TranslationPreviewState,
) -> Result<(), String> {
    let path = translation_preview_path(app)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    let data = serde_json::to_string_pretty(state)
        .map_err(|error| format!("Could not encode translation preview: {error}"))?;
    fs::write(&path, data).map_err(|error| format!("Could not write {}: {error}", path.display()))
}

fn translation_preview_path(app: &AppHandle) -> Result<PathBuf, String> {
    shared_data_dir(app).map(|dir| dir.join("translation-preview.json"))
}

fn sample_translation_preview(settings: &Settings) -> TranslationPreviewState {
    TranslationPreviewState {
        mode: "translated".to_string(),
        source_language: "English".to_string(),
        target_language: settings.target_language.clone(),
        did_reverse_because_languages_matched: false,
        original_text: "The future belongs to those who believe in the beauty of their dreams."
            .to_string(),
        translated_text: "미래는 자신의 꿈의 아름다움을 믿는 사람들의 것이다.".to_string(),
        translated_image_url: None,
        error_text: None,
        provider_title: provider_title(&settings.provider).to_string(),
        model: selected_model_title(settings),
        model_warning: None,
        cost_credits: None,
        permission_action: None,
        toast_duration: settings.toast_duration,
        request_sequence: 0,
        caret_x: None,
        caret_y: None,
        caret_w: None,
        caret_h: None,
        anchor_bottom: false,
    }
}

fn apply_preview_target_language(
    mut settings: Settings,
    target_language: &str,
) -> Result<Settings, String> {
    let requested_target = target_language.trim();
    let target_is_supported = language_options(false)
        .iter()
        .any(|option| option.value == requested_target);
    if requested_target.is_empty() || !target_is_supported {
        return Err(format!("Unsupported target language: {target_language}"));
    }

    settings.target_language = requested_target.to_string();
    Ok(normalize_settings(settings))
}

fn apply_preview_model_selection(
    settings: Settings,
    provider: TranslationProvider,
    model_id: &str,
) -> Result<Settings, String> {
    apply_preview_model_selection_for_runtime(settings_runtime(), settings, provider, model_id)
}

fn apply_preview_model_selection_for_runtime(
    runtime: SettingsRuntime,
    mut settings: Settings,
    provider: TranslationProvider,
    model_id: &str,
) -> Result<Settings, String> {
    let model_id = model_id.trim();
    if model_id.is_empty() {
        return Err("Model is empty.".to_string());
    }

    settings.provider = provider;
    match &settings.provider {
        TranslationProvider::LocalHyMT2 => settings.local_model_id = model_id.to_string(),
        TranslationProvider::OpenRouter => settings.open_router_text_model = model_id.to_string(),
        // Single-model / model-less providers; there is no model id to store.
        TranslationProvider::AppleTranslation | TranslationProvider::KargnasManaged => {}
    }
    Ok(runtime.normalize(settings))
}

fn prepare_translation_preview_for_retranslate(
    state: &mut TranslationPreviewState,
    settings: &Settings,
    target_language: Option<String>,
) {
    let explicit_target_language = target_language.is_some();
    let target_language = target_language
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            let current = state.target_language.trim();
            if current.is_empty() {
                settings.target_language.clone()
            } else {
                current.to_string()
            }
        });

    let (resolved_target, did_reverse) =
        if !explicit_target_language && state.did_reverse_because_languages_matched {
            (target_language, true)
        } else {
            resolve_preview_target_language(&state.source_language, &target_language)
        };
    state.target_language = resolved_target;
    state.did_reverse_because_languages_matched = did_reverse;
    state.toast_duration = settings.toast_duration;
    state.provider_title = provider_title(&settings.provider).to_string();
    state.model = selected_model_title(settings);
    state.model_warning = None;
    state.cost_credits = None;
    state.translated_image_url = None;
}

fn resolve_preview_target_language(
    source_language: &str,
    preferred_target: &str,
) -> (String, bool) {
    let source = normalized_language_name(source_language);
    let preferred = normalized_language_name(preferred_target);
    if source != preferred {
        return (preferred, false);
    }
    if source == "Korean" {
        return ("English".to_string(), true);
    }
    if source == "English" {
        return ("Korean".to_string(), true);
    }
    ("English".to_string(), true)
}

fn normalized_language_name(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return "Auto".to_string();
    }
    language_options(true)
        .into_iter()
        .find(|option| option.value.eq_ignore_ascii_case(trimmed))
        .map(|option| option.value)
        .unwrap_or_else(|| trimmed.to_string())
}

fn default_toast_duration_value() -> f64 {
    default_settings().toast_duration
}

fn provider_title(provider: &TranslationProvider) -> &'static str {
    match provider {
        TranslationProvider::LocalHyMT2 => "Local Model",
        TranslationProvider::OpenRouter => "OpenRouter LLM",
        TranslationProvider::AppleTranslation => "Apple Translation",
        TranslationProvider::KargnasManaged => "CCTrans Cloud",
    }
}

fn selected_model_title(settings: &Settings) -> String {
    match &settings.provider {
        TranslationProvider::LocalHyMT2 => {
            model_title(&settings.local_model_id, &settings.provider)
        }
        TranslationProvider::OpenRouter => {
            model_title(&settings.open_router_text_model, &settings.provider)
        }
        TranslationProvider::AppleTranslation => "Apple Translation".to_string(),
        TranslationProvider::KargnasManaged => "Managed (server-chosen)".to_string(),
    }
}

fn model_title(model_id: &str, provider: &TranslationProvider) -> String {
    if matches!(provider, TranslationProvider::OpenRouter) {
        return openrouter_models()
            .into_iter()
            .find(|model| model.value == model_id)
            .map(|model| model.label)
            .unwrap_or_else(|| model_id.to_string());
    }

    match model_id {
        "hymt2-mlx-1.8b-4bit" => "Hy-MT2 1.8B 4-bit (MLX)",
        "hymt2-transformers-1.8b" => "Hy-MT2 1.8B (Transformers)",
        "hymt2-transformers-30b" => "Hy-MT2 30B-A3B (Transformers)",
        _ => "Selected local model",
    }
    .to_string()
}

fn state_from_disk(app: &AppHandle) -> Result<SettingsState, String> {
    let runtime = settings_runtime();
    let settings = load_effective_settings(app)?;
    let defaults = runtime.default_settings();
    let storage_path = settings_path(app)?.display().to_string();

    Ok(SettingsState {
        app_variant: runtime.app_variant_name().to_string(),
        overrides: override_map(&settings, &defaults),
        settings,
        defaults,
        options: settings_options(app),
        permissions: permission_status(app),
        login_item: login_item_state_impl(app).unwrap_or_else(|error| {
            LoginItemState::unsupported(format!("Login item status unavailable: {error}"))
        }),
        storage_path,
    })
}

// Distribution variant of the host app. The Swift shell launches this helper
// with `--app-variant mas` in Mac App Store bundles; everything else is the
// direct (DMG/brew/dev) build.
fn is_mas_variant() -> bool {
    settings_runtime().variant == AppVariant::MacAppStore
}

fn settings_runtime() -> SettingsRuntime {
    SettingsRuntime::current()
}

fn load_effective_settings(app: &AppHandle) -> Result<Settings, String> {
    let path = settings_path(app)?;
    if !path.exists() {
        return Ok(default_settings_for_current_variant());
    }

    let data = fs::read_to_string(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    let stored: StoredSettings = serde_json::from_str(&data)
        .map_err(|error| format!("Could not parse {}: {error}", path.display()))?;
    Ok(apply_stored_settings(stored))
}

fn apply_stored_settings(stored: StoredSettings) -> Settings {
    settings_runtime().apply_stored(stored)
}

fn write_settings(app: &AppHandle, settings: Settings) -> Result<(), String> {
    let runtime = settings_runtime();
    let path = settings_path(app)?;
    let stored = runtime.stored_from_effective(&runtime.normalize(settings));

    if stored.is_empty() {
        if path.exists() {
            fs::remove_file(&path)
                .map_err(|error| format!("Could not remove {}: {error}", path.display()))?;
        }
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }

    let data = serde_json::to_string_pretty(&stored)
        .map_err(|error| format!("Could not encode settings: {error}"))?;
    replace_file_contents(&path, &data)
}

// The Swift menu-bar app watches the shared app-data directory with a kqueue
// source, which only fires on directory-entry changes (create/rename/delete).
// An in-place fs::write leaves the directory entry untouched, so the menu-bar
// app kept translating with stale settings until an unrelated file in the
// directory changed. Writing a sibling temp file and renaming it into place
// emits that event and keeps readers from ever seeing a half-written file.
fn replace_file_contents(path: &Path, data: &str) -> Result<(), String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("Could not resolve file name for {}", path.display()))?;
    // The settings window and the persistent toast process both write this file;
    // a pid suffix keeps their temp files from clobbering each other.
    let temp_path = path.with_file_name(format!("{file_name}.tmp-{}", std::process::id()));
    fs::write(&temp_path, data)
        .map_err(|error| format!("Could not write {}: {error}", temp_path.display()))?;
    fs::rename(&temp_path, path)
        .map_err(|error| format!("Could not replace {}: {error}", path.display()))
}

fn validate_env_value(value: &str) -> bool {
    !value.contains(['\n', '\r', '\0'])
}

fn replace_private_file_contents(path: &Path, data: &str) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;

        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| format!("Could not resolve file name for {}", path.display()))?;
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temp_path =
            path.with_file_name(format!(".{file_name}.tmp-{}-{nonce}", std::process::id()));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp_path)
                .map_err(|error| format!("Could not create {}: {error}", temp_path.display()))?;
            file.write_all(data.as_bytes())
                .map_err(|error| format!("Could not write {}: {error}", temp_path.display()))?;
            file.sync_all()
                .map_err(|error| format!("Could not sync {}: {error}", temp_path.display()))?;
            drop(file);
            fs::rename(&temp_path, path)
                .map_err(|error| format!("Could not replace {}: {error}", path.display()))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        return result;
    }

    #[cfg(not(unix))]
    {
        replace_file_contents(path, data)
    }
}

impl StoredSettings {
    fn from_effective(settings: &Settings, defaults: &Settings, keep_provider: bool) -> Self {
        Self {
            provider: (keep_provider || settings.provider != defaults.provider)
                .then(|| settings.provider.clone()),
            hy_mt2_model: None,
            local_model_id: (settings.local_model_id != defaults.local_model_id)
                .then(|| settings.local_model_id.clone()),
            local_hy_mt2_backend_path: (settings.local_hy_mt2_backend_path
                != defaults.local_hy_mt2_backend_path)
                .then(|| settings.local_hy_mt2_backend_path.clone())
                .flatten(),
            custom_local_models_path: (settings.custom_local_models_path
                != defaults.custom_local_models_path)
                .then(|| settings.custom_local_models_path.clone())
                .flatten(),
            open_router_text_model: (settings.open_router_text_model
                != defaults.open_router_text_model)
                .then(|| settings.open_router_text_model.clone()),
            open_router_vision_model: (settings.open_router_vision_model
                != defaults.open_router_vision_model)
                .then(|| settings.open_router_vision_model.clone()),
            favorite_local_model_ids: (settings.favorite_local_model_ids
                != defaults.favorite_local_model_ids)
                .then(|| settings.favorite_local_model_ids.clone()),
            favorite_open_router_models: (settings.favorite_open_router_models
                != defaults.favorite_open_router_models)
                .then(|| settings.favorite_open_router_models.clone()),
            open_router_model_filter: (settings.open_router_model_filter
                != defaults.open_router_model_filter)
                .then(|| settings.open_router_model_filter.clone()),
            include_screen_context_for_llm: (settings.include_screen_context_for_llm
                != defaults.include_screen_context_for_llm)
                .then_some(settings.include_screen_context_for_llm),
            source_language: (settings.source_language != defaults.source_language)
                .then(|| settings.source_language.clone()),
            target_language: (settings.target_language != defaults.target_language)
                .then(|| settings.target_language.clone()),
            has_completed_local_model_selection: (settings.has_completed_local_model_selection
                != defaults.has_completed_local_model_selection)
                .then_some(settings.has_completed_local_model_selection),
            has_completed_onboarding: (settings.has_completed_onboarding
                != defaults.has_completed_onboarding)
                .then_some(settings.has_completed_onboarding),
            toast_position: (settings.toast_position != defaults.toast_position)
                .then(|| settings.toast_position.clone()),
            toast_custom_position: (settings.toast_custom_position
                != defaults.toast_custom_position)
                .then_some(settings.toast_custom_position)
                .flatten(),
            toast_duration: ((settings.toast_duration - defaults.toast_duration).abs()
                > f64::EPSILON)
                .then_some(settings.toast_duration),
            start_menu_bar_only: (settings.start_menu_bar_only != defaults.start_menu_bar_only)
                .then_some(settings.start_menu_bar_only),
        }
    }

    fn is_empty(&self) -> bool {
        self.provider.is_none()
            && self.hy_mt2_model.is_none()
            && self.local_model_id.is_none()
            && self.local_hy_mt2_backend_path.is_none()
            && self.custom_local_models_path.is_none()
            && self.open_router_text_model.is_none()
            && self.open_router_vision_model.is_none()
            && self.favorite_local_model_ids.is_none()
            && self.favorite_open_router_models.is_none()
            && self.open_router_model_filter.is_none()
            && self.include_screen_context_for_llm.is_none()
            && self.source_language.is_none()
            && self.target_language.is_none()
            && self.has_completed_local_model_selection.is_none()
            && self.has_completed_onboarding.is_none()
            && self.toast_position.is_none()
            && self.toast_custom_position.is_none()
            && self.toast_duration.is_none()
            && self.start_menu_bar_only.is_none()
    }
}

fn settings_path(app: &AppHandle) -> Result<PathBuf, String> {
    shared_data_dir(app).map(|dir| dir.join("settings-overrides.json"))
}

#[derive(Serialize, Deserialize)]
struct WindowGeometry {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
}

fn window_state_path(app: &AppHandle) -> Result<PathBuf, String> {
    shared_data_dir(app).map(|dir| dir.join("window-state.json"))
}

fn save_main_window_geometry(app: &AppHandle, window: &tauri::WebviewWindow) -> Result<(), String> {
    let position = window.outer_position().map_err(|error| error.to_string())?;
    let size = window.inner_size().map_err(|error| error.to_string())?;
    // A minimized/zero-size frame would otherwise be persisted and reopen the window invisible.
    if size.width == 0 || size.height == 0 {
        return Ok(());
    }
    let geometry = WindowGeometry {
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height,
    };
    let path = window_state_path(app)?;
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let json = serde_json::to_string(&geometry).map_err(|error| error.to_string())?;
    fs::write(&path, json).map_err(|error| error.to_string())
}

fn restore_main_window_geometry(app: &AppHandle, window: &tauri::WebviewWindow) {
    let Ok(path) = window_state_path(app) else {
        return;
    };
    let Ok(bytes) = fs::read(&path) else {
        return;
    };
    let Ok(geometry) = serde_json::from_slice::<WindowGeometry>(&bytes) else {
        return;
    };
    if geometry.width == 0 || geometry.height == 0 {
        return;
    }
    // Size first, then position, so the restored origin is not re-centered by the size change.
    let _ = window.set_size(PhysicalSize::new(geometry.width, geometry.height));
    let _ = window.set_position(PhysicalPosition::new(geometry.x, geometry.y));
}

#[tauri::command]
fn close_settings_window(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        let _ = save_main_window_geometry(&app, &window);
        window.close().map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn default_settings() -> Settings {
    Settings {
        // Base (variant-less) default. KargnasManaged is the one provider valid
        // in every distribution variant, so a path that forgets the variant
        // mapping degrades to a working provider instead of leaking the
        // Python-backed local provider into the MAS build. Effective defaults
        // live in SettingsRuntime::default_settings (direct=local, mas=apple).
        provider: TranslationProvider::KargnasManaged,
        local_model_id: "hymt2-mlx-1.8b-4bit".to_string(),
        local_hy_mt2_backend_path: None,
        custom_local_models_path: None,
        open_router_text_model: "deepseek/deepseek-v4-flash".to_string(),
        open_router_vision_model: "google/gemini-3.1-flash-lite".to_string(),
        favorite_local_model_ids: vec!["hymt2-mlx-1.8b-4bit".to_string()],
        favorite_open_router_models: vec!["deepseek/deepseek-v4-flash".to_string()],
        open_router_model_filter: OpenRouterModelFilter {
            modality_mode: OpenRouterModalityMode::TextOrVision,
            min_prompt_price_per_million: 0.0,
            max_prompt_price_per_million: 2.0,
            min_completion_price_per_million: 0.0,
            max_completion_price_per_million: 10.0,
            top_rank_limit: 50,
        },
        include_screen_context_for_llm: false,
        source_language: "Auto".to_string(),
        target_language: "Korean".to_string(),
        has_completed_local_model_selection: false,
        has_completed_onboarding: false,
        toast_position: ToastPosition::BottomRight,
        toast_custom_position: None,
        toast_duration: 6.0,
        start_menu_bar_only: false,
    }
}

fn default_settings_for_current_variant() -> Settings {
    settings_runtime().default_settings()
}

fn normalize_settings(settings: Settings) -> Settings {
    settings_runtime().normalize(settings)
}

fn normalized_openrouter_model_filter(mut filter: OpenRouterModelFilter) -> OpenRouterModelFilter {
    let defaults = default_settings().open_router_model_filter;
    filter.min_prompt_price_per_million = normalized_price_filter_value(
        filter.min_prompt_price_per_million,
        defaults.min_prompt_price_per_million,
    );
    filter.max_prompt_price_per_million = normalized_price_filter_value(
        filter.max_prompt_price_per_million,
        defaults.max_prompt_price_per_million,
    );
    filter.min_completion_price_per_million = normalized_price_filter_value(
        filter.min_completion_price_per_million,
        defaults.min_completion_price_per_million,
    );
    filter.max_completion_price_per_million = normalized_price_filter_value(
        filter.max_completion_price_per_million,
        defaults.max_completion_price_per_million,
    );
    if filter.min_prompt_price_per_million > filter.max_prompt_price_per_million {
        std::mem::swap(
            &mut filter.min_prompt_price_per_million,
            &mut filter.max_prompt_price_per_million,
        );
    }
    if filter.min_completion_price_per_million > filter.max_completion_price_per_million {
        std::mem::swap(
            &mut filter.min_completion_price_per_million,
            &mut filter.max_completion_price_per_million,
        );
    }
    filter.top_rank_limit = normalized_top_rank_limit(filter.top_rank_limit);
    filter
}

fn normalized_price_filter_value(value: f64, fallback: f64) -> f64 {
    if value.is_finite() && value >= 0.0 {
        value
    } else {
        fallback
    }
}

fn default_top_rank_limit() -> i64 {
    50
}

// 0 means "All" (no limit); otherwise cap at 50, which matches how many daily-usage
// ranks we fetch from OpenRouter.
fn normalized_top_rank_limit(value: i64) -> i64 {
    value.clamp(0, 50)
}

fn normalized_string_list(values: Vec<String>) -> Vec<String> {
    let mut normalized = Vec::new();
    for value in values {
        let value = value.trim().to_string();
        if !value.is_empty() && !normalized.contains(&value) {
            normalized.push(value);
        }
    }
    normalized
}

fn normalized_optional(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn override_map(settings: &Settings, defaults: &Settings) -> BTreeMap<String, bool> {
    BTreeMap::from([
        (
            "provider".to_string(),
            settings.provider != defaults.provider,
        ),
        (
            "startMenuBarOnly".to_string(),
            settings.start_menu_bar_only != defaults.start_menu_bar_only,
        ),
        (
            "localModelID".to_string(),
            settings.local_model_id != defaults.local_model_id,
        ),
        (
            "sourceLanguage".to_string(),
            settings.source_language != defaults.source_language,
        ),
        (
            "targetLanguage".to_string(),
            settings.target_language != defaults.target_language,
        ),
        (
            "toastPosition".to_string(),
            settings.toast_position != defaults.toast_position
                || settings.toast_custom_position != defaults.toast_custom_position,
        ),
        (
            "localHyMT2BackendPath".to_string(),
            settings.local_hy_mt2_backend_path != defaults.local_hy_mt2_backend_path,
        ),
        (
            "customLocalModelsPath".to_string(),
            settings.custom_local_models_path != defaults.custom_local_models_path,
        ),
        (
            "openRouterTextModel".to_string(),
            settings.open_router_text_model != defaults.open_router_text_model,
        ),
        (
            "openRouterVisionModel".to_string(),
            settings.open_router_vision_model != defaults.open_router_vision_model,
        ),
        (
            "favoriteLocalModelIDs".to_string(),
            settings.favorite_local_model_ids != defaults.favorite_local_model_ids,
        ),
        (
            "favoriteOpenRouterModels".to_string(),
            settings.favorite_open_router_models != defaults.favorite_open_router_models,
        ),
        (
            "openRouterModelFilter".to_string(),
            settings.open_router_model_filter != defaults.open_router_model_filter,
        ),
    ])
}

fn settings_options(app: &AppHandle) -> SettingsOptions {
    let providers = settings_runtime().provider_options();
    SettingsOptions {
        providers,
        local_models: vec![
            option(
                "Hy-MT2 1.8B 4-bit (MLX)",
                "hymt2-mlx-1.8b-4bit",
                Some("Recommended"),
            ),
            option(
                "Hy-MT2 1.8B (Transformers)",
                "hymt2-transformers-1.8b",
                None,
            ),
            option(
                "Hy-MT2 30B-A3B (Transformers)",
                "hymt2-transformers-30b",
                None,
            ),
            option("Hy-MT2 1.8B IQ4_XS (GGUF)", "hymt2-gguf-iq4-xs", None),
            option("LFM2 Ko-En Q4_K_M (GGUF)", "lfm2-koen-q4-k-m", None),
            option("NLLB CTranslate2 int8", "nllb-ct2-int8", None),
            option("QuickMT En-Ko", "quickmt-en-ko", None),
            option("Kanana 1.5 2.1B AIHub Ko-En LoRA", "kanana-lora-koen", None),
            option("MADLAD-400 Swift int4", "madlad-swift-int4", None),
        ],
        open_router_models: openrouter_models_for_settings(app),
        source_languages: language_options(true),
        target_languages: language_options(false),
        toast_positions: vec![
            option("Bottom Right", "bottomRight", None),
            option("Bottom Left", "bottomLeft", None),
            option("Top Right", "topRight", None),
            option("Top Left", "topLeft", None),
            option("Custom", "custom", None),
        ],
    }
}

fn openrouter_models() -> Vec<OpenRouterModelOption> {
    vec![
        openrouter_model(
            "Google Gemini Flash Latest",
            "~google/gemini-flash-latest",
            None,
            1.50,
            9.00,
            &["text", "image", "video", "pdf", "audio"],
            "2026-04-27",
            1_048_576,
            true,
            false,
            false,
        ),
        openrouter_model(
            "MiniMax-M3",
            "minimax/minimax-m3",
            None,
            0.30,
            1.20,
            &["text", "image", "video"],
            "2026-06-01",
            524_288,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Claude Opus 4.8",
            "anthropic/claude-opus-4.8",
            None,
            5.00,
            25.00,
            &["text", "image", "pdf"],
            "2026-05-28",
            1_000_000,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Gemini 3.5 Flash",
            "google/gemini-3.5-flash",
            None,
            1.50,
            9.00,
            &["text", "image", "video", "pdf", "audio"],
            "2026-05-19",
            1_048_576,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Gemini 3.1 Flash Lite",
            "google/gemini-3.1-flash-lite",
            None,
            0.25,
            1.50,
            &["text", "image", "video", "pdf", "audio"],
            "2026-05-07",
            1_048_576,
            true,
            false,
            false,
        ),
        openrouter_model(
            "DeepSeek V4 Flash",
            "deepseek/deepseek-v4-flash",
            Some("Recommended"),
            0.0983,
            0.1966,
            &["text"],
            "2026-04-24",
            1_048_576,
            true,
            false,
            true,
        ),
        openrouter_model(
            "Anthropic Claude Sonnet Latest",
            "~anthropic/claude-sonnet-latest",
            None,
            3.00,
            15.00,
            &["text", "image", "pdf"],
            "2026-04-27",
            1_000_000,
            true,
            false,
            false,
        ),
        openrouter_model(
            "GPT-5.5",
            "openai/gpt-5.5",
            None,
            5.00,
            30.00,
            &["pdf", "image", "text"],
            "2026-04-23",
            1_050_000,
            true,
            false,
            false,
        ),
        openrouter_model(
            "OpenAI GPT Mini Latest",
            "~openai/gpt-mini-latest",
            None,
            0.75,
            4.50,
            &["pdf", "image", "text"],
            "2026-04-27",
            400_000,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Qwen3.7 Max",
            "qwen/qwen3.7-max",
            None,
            1.25,
            3.75,
            &["text"],
            "2026-05-21",
            1_000_000,
            true,
            false,
            false,
        ),
        openrouter_model(
            "DeepSeek V4 Pro",
            "deepseek/deepseek-v4-pro",
            None,
            0.435,
            0.87,
            &["text"],
            "2026-04-24",
            1_048_576,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Mistral Medium 3.5",
            "mistralai/mistral-medium-3-5",
            None,
            1.50,
            7.50,
            &["text", "image", "pdf"],
            "2026-04-30",
            262_144,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Kimi K2.6",
            "moonshotai/kimi-k2.6",
            None,
            0.684,
            3.42,
            &["text", "image"],
            "2026-04-21",
            262_144,
            true,
            false,
            false,
        ),
        openrouter_model(
            "Nemotron 3 Nano Omni (free)",
            "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
            Some("Free"),
            0.0,
            0.0,
            &["text", "audio", "image", "video"],
            "2026-04-28",
            256_000,
            true,
            true,
            false,
        ),
        openrouter_model(
            "Kimi K2.6 (free)",
            "moonshotai/kimi-k2.6:free",
            Some("Free"),
            0.0,
            0.0,
            &["text", "image"],
            "2026-04-21",
            262_144,
            true,
            true,
            false,
        ),
        openrouter_model(
            "Owl Alpha",
            "openrouter/owl-alpha",
            Some("Free"),
            0.0,
            0.0,
            &["text"],
            "2026-04-28",
            1_048_756,
            false,
            true,
            false,
        ),
    ]
}

fn openrouter_models_for_settings(app: &AppHandle) -> Vec<OpenRouterModelOption> {
    read_openrouter_models_cache(app).unwrap_or_else(|_| openrouter_models())
}

fn openrouter_models_cache_path(app: &AppHandle) -> Result<PathBuf, String> {
    shared_data_dir(app).map(|dir| dir.join("openrouter-models-cache.json"))
}

fn read_openrouter_models_cache(app: &AppHandle) -> Result<Vec<OpenRouterModelOption>, String> {
    let path = openrouter_models_cache_path(app)?;
    if !path.exists() {
        return Err("OpenRouter model cache does not exist.".to_string());
    }
    let data = fs::read_to_string(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    let models: Vec<OpenRouterModelOption> = serde_json::from_str(&data)
        .map_err(|error| format!("Could not parse {}: {error}", path.display()))?;
    if models.is_empty() {
        return Err("OpenRouter model cache is empty.".to_string());
    }
    Ok(models)
}

fn write_openrouter_models_cache(
    app: &AppHandle,
    models: &[OpenRouterModelOption],
) -> Result<(), String> {
    let path = openrouter_models_cache_path(app)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    let data = serde_json::to_string_pretty(models)
        .map_err(|error| format!("Could not encode OpenRouter model cache: {error}"))?;
    replace_file_contents(&path, &data)
}

fn fetch_openrouter_models(api_key: Option<&str>) -> Result<Vec<OpenRouterModelOption>, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_read(Duration::from_secs(15))
        .timeout_write(Duration::from_secs(15))
        .build();
    let response = agent
        .get("https://openrouter.ai/api/v1/models?sort=newest")
        .set("User-Agent", "CCTrans/0.1")
        .call()
        .map_err(|error| format!("Could not refresh OpenRouter models: {error}"))?;
    let payload: OpenRouterModelsResponse = response
        .into_json()
        .map_err(|error| format!("Could not decode OpenRouter models: {error}"))?;
    let mut models = payload
        .data
        .into_iter()
        .filter_map(openrouter_model_from_api)
        .collect::<Vec<_>>();
    if let Ok(rankings) = fetch_openrouter_throughput_top_rankings(&agent) {
        apply_openrouter_throughput_rankings(&mut models, &rankings);
    }
    if let Ok(rankings) = fetch_openrouter_latency_top_rankings(&agent) {
        apply_openrouter_latency_rankings(&mut models, &rankings);
    }
    if let Some(api_key) = api_key {
        if let Ok(rankings) = fetch_openrouter_daily_top_rankings(&agent, api_key) {
            apply_openrouter_daily_rankings(&mut models, &rankings);
        }
    }
    if models.is_empty() {
        return Err("OpenRouter returned no models.".to_string());
    }
    models.sort_by(|left, right| {
        right
            .release_date
            .cmp(&left.release_date)
            .then_with(|| left.label.cmp(&right.label))
    });
    Ok(models)
}

fn fetch_openrouter_throughput_top_rankings(
    agent: &ureq::Agent,
) -> Result<BTreeMap<String, i64>, String> {
    let response = agent
        .get("https://openrouter.ai/api/v1/models?sort=throughput-high-to-low")
        .set("User-Agent", "CCTrans/0.1")
        .call()
        .map_err(|error| format!("Could not refresh OpenRouter throughput rankings: {error}"))?;
    let payload: OpenRouterModelsResponse = response
        .into_json()
        .map_err(|error| format!("Could not decode OpenRouter throughput rankings: {error}"))?;
    Ok(openrouter_order_top_rankings(payload.data, 20))
}

// OpenRouter exposes no numeric latency in /models; it only orders results by latency. So
// "Fast #X" is the position in the latency-low-to-high list (1 = fastest first token), the same
// rank-by-order mechanism as throughput.
fn fetch_openrouter_latency_top_rankings(
    agent: &ureq::Agent,
) -> Result<BTreeMap<String, i64>, String> {
    let response = agent
        .get("https://openrouter.ai/api/v1/models?sort=latency-low-to-high")
        .set("User-Agent", "CCTrans/0.1")
        .call()
        .map_err(|error| format!("Could not refresh OpenRouter latency rankings: {error}"))?;
    let payload: OpenRouterModelsResponse = response
        .into_json()
        .map_err(|error| format!("Could not decode OpenRouter latency rankings: {error}"))?;
    Ok(openrouter_order_top_rankings(payload.data, 20))
}

// Assigns rank 1..=limit by the order OpenRouter returned (the API is already sorted by the
// requested metric), so this is shared by throughput and latency.
fn openrouter_order_top_rankings(
    models: Vec<OpenRouterAPIModel>,
    limit: usize,
) -> BTreeMap<String, i64> {
    models
        .into_iter()
        .filter_map(|model| {
            let id = model.id.trim().to_string();
            (!id.is_empty()).then_some(id)
        })
        .take(limit)
        .enumerate()
        .map(|(index, id)| (id, (index + 1) as i64))
        .collect()
}

fn fetch_openrouter_daily_top_rankings(
    agent: &ureq::Agent,
    api_key: &str,
) -> Result<BTreeMap<String, i64>, String> {
    let authorization = format!("Bearer {api_key}");
    let response = agent
        .get("https://openrouter.ai/api/v1/datasets/rankings-daily")
        .set("Authorization", &authorization)
        .set("User-Agent", "CCTrans/0.1")
        .call()
        .map_err(|error| format!("Could not refresh OpenRouter rankings: {error}"))?;
    let payload: OpenRouterRankingsDailyResponse = response
        .into_json()
        .map_err(|error| format!("Could not decode OpenRouter rankings: {error}"))?;
    Ok(openrouter_daily_top_rankings(payload.data, 50))
}

fn openrouter_daily_top_rankings(
    rows: Vec<OpenRouterRankingDailyRow>,
    limit: usize,
) -> BTreeMap<String, i64> {
    let Some(latest_date) = rows
        .iter()
        .filter(|row| row.model_permaslug != "other")
        .map(|row| row.date.as_str())
        .max()
        .map(str::to_string)
    else {
        return BTreeMap::new();
    };

    let mut latest_rows = rows
        .into_iter()
        .filter(|row| row.date == latest_date && row.model_permaslug != "other")
        .collect::<Vec<_>>();
    latest_rows.sort_by(|left, right| {
        ranking_total_tokens(&right.total_tokens)
            .cmp(&ranking_total_tokens(&left.total_tokens))
            .then_with(|| left.model_permaslug.cmp(&right.model_permaslug))
    });
    latest_rows
        .into_iter()
        .take(limit)
        .enumerate()
        .map(|(index, row)| (row.model_permaslug, (index + 1) as i64))
        .collect()
}

fn apply_openrouter_daily_rankings(
    models: &mut [OpenRouterModelOption],
    rankings: &BTreeMap<String, i64>,
) {
    for model in models {
        model.daily_token_rank = rankings.get(&model.value).copied();
    }
}

fn apply_openrouter_throughput_rankings(
    models: &mut [OpenRouterModelOption],
    rankings: &BTreeMap<String, i64>,
) {
    for model in models {
        model.throughput_rank = rankings.get(&model.value).copied();
    }
}

fn apply_openrouter_latency_rankings(
    models: &mut [OpenRouterModelOption],
    rankings: &BTreeMap<String, i64>,
) {
    for model in models {
        model.latency_rank = rankings.get(&model.value).copied();
    }
}

fn ranking_total_tokens(value: &serde_json::Value) -> u128 {
    match value {
        serde_json::Value::String(value) => value.parse::<u128>().unwrap_or(0),
        serde_json::Value::Number(value) => value.as_u64().unwrap_or(0) as u128,
        _ => 0,
    }
}

fn openrouter_model_from_api(model: OpenRouterAPIModel) -> Option<OpenRouterModelOption> {
    let id = model.id.trim().to_string();
    let name = model.name.trim().to_string();
    if id.is_empty() || name.is_empty() {
        return None;
    }
    let architecture = model.architecture;
    let input_modalities = normalized_modalities(architecture.input_modalities);
    let output_modalities = normalized_modalities(architecture.output_modalities);

    let prompt_price_per_million = price_per_million(model.pricing.prompt.as_ref());
    let completion_price_per_million = price_per_million(model.pricing.completion.as_ref());
    let is_free = id.ends_with(":free") || id == "openrouter/free";
    let is_recommended = id == default_settings().open_router_text_model
        || id == default_settings().open_router_vision_model;
    let is_reasoning = model.supported_parameters.iter().any(|parameter| {
        parameter.eq_ignore_ascii_case("reasoning")
            || parameter.eq_ignore_ascii_case("include_reasoning")
    });

    Some(OpenRouterModelOption {
        label: name,
        value: id,
        note: if is_free {
            Some("Free event".to_string())
        } else if is_recommended {
            Some("Recommended".to_string())
        } else {
            None
        },
        prompt_price_per_million,
        completion_price_per_million,
        modalities: input_modalities,
        output_modalities,
        release_date: model
            .created
            .map(unix_seconds_to_ymd)
            .unwrap_or_else(|| "1970-01-01".to_string()),
        context_window: model.context_length.unwrap_or_default(),
        is_reasoning,
        is_free,
        is_recommended,
        daily_token_rank: None,
        throughput_rank: None,
        latency_rank: None,
        tokenizer: normalized_optional_string(architecture.tokenizer),
        max_completion_tokens: model.top_provider.max_completion_tokens,
        is_moderated: model.top_provider.is_moderated,
        knowledge_cutoff: normalized_optional_string(model.knowledge_cutoff),
        expiration_date: normalized_optional_string(model.expiration_date),
    })
}

fn normalized_optional_string(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn normalized_modalities(values: Vec<String>) -> Vec<String> {
    let mut normalized = values
        .into_iter()
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}

fn default_openrouter_output_modalities() -> Vec<String> {
    vec!["text".to_string()]
}

fn price_per_million(value: Option<&serde_json::Value>) -> f64 {
    let Some(value) = value else {
        return 0.0;
    };
    let per_token = match value {
        serde_json::Value::String(value) => value.parse::<f64>().unwrap_or(0.0),
        serde_json::Value::Number(value) => value.as_f64().unwrap_or(0.0),
        _ => 0.0,
    };
    if per_token.is_finite() {
        per_token * 1_000_000.0
    } else {
        0.0
    }
}

fn unix_seconds_to_ymd(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}")
}

fn civil_from_days(days_since_unix_epoch: i64) -> (i32, u32, u32) {
    let z = days_since_unix_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year_day = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * year_day + 2) / 153;
    let day = year_day - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    let year = year_of_era + era * 400 + if month <= 2 { 1 } else { 0 };
    (year as i32, month as u32, day as u32)
}

fn openrouter_model(
    label: &str,
    value: &str,
    note: Option<&str>,
    prompt_price_per_million: f64,
    completion_price_per_million: f64,
    modalities: &[&str],
    release_date: &str,
    context_window: i64,
    is_reasoning: bool,
    is_free: bool,
    is_recommended: bool,
) -> OpenRouterModelOption {
    OpenRouterModelOption {
        label: label.to_string(),
        value: value.to_string(),
        note: note.map(ToString::to_string),
        prompt_price_per_million,
        completion_price_per_million,
        modalities: modalities
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        output_modalities: default_openrouter_output_modalities(),
        release_date: release_date.to_string(),
        context_window,
        is_reasoning,
        is_free,
        is_recommended,
        daily_token_rank: None,
        throughput_rank: None,
        latency_rank: None,
        tokenizer: None,
        max_completion_tokens: None,
        is_moderated: None,
        knowledge_cutoff: None,
        expiration_date: None,
    }
}

fn language_options(include_auto: bool) -> Vec<SettingOption> {
    let languages = [
        "Auto",
        "English",
        "Korean",
        "Simplified Chinese",
        "Japanese",
        "Spanish",
        "German",
        "French",
        "Indonesian",
        "Arabic",
    ];
    languages
        .into_iter()
        .filter(|language| include_auto || *language != "Auto")
        .map(|language| option(language, language, None))
        .collect()
}

fn option(label: &str, value: &str, note: Option<&str>) -> SettingOption {
    SettingOption {
        label: label.to_string(),
        value: value.to_string(),
        note: note.map(ToString::to_string),
    }
}

fn legacy_model_id(model: LegacyHyMT2Model) -> String {
    match model {
        LegacyHyMT2Model::HyMT230B => "hymt2-transformers-30b",
        LegacyHyMT2Model::HyMT218B => "hymt2-transformers-1.8b",
    }
    .to_string()
}

fn provider_arg(provider: &TranslationProvider) -> &'static str {
    match provider {
        TranslationProvider::LocalHyMT2 => "local",
        TranslationProvider::OpenRouter => "openrouter",
        TranslationProvider::AppleTranslation => "apple",
        TranslationProvider::KargnasManaged => "managed",
    }
}

fn legacy_cli_args(settings: &Settings, base: &[&str]) -> Vec<String> {
    let mut args = base
        .iter()
        .map(|value| (*value).to_string())
        .collect::<Vec<_>>();
    args.extend([
        "--provider".to_string(),
        provider_arg(&settings.provider).to_string(),
        "--local-model".to_string(),
        settings.local_model_id.clone(),
        "--source-language".to_string(),
        settings.source_language.clone(),
        "--target-language".to_string(),
        settings.target_language.clone(),
        "--openrouter-text-model".to_string(),
        settings.open_router_text_model.clone(),
        "--openrouter-vision-model".to_string(),
        settings.open_router_vision_model.clone(),
    ]);
    if let Some(path) = &settings.local_hy_mt2_backend_path {
        args.extend(["--local-backend".to_string(), path.clone()]);
    }
    if let Some(path) = &settings.custom_local_models_path {
        args.extend(["--custom-local-models".to_string(), path.clone()]);
    }
    args
}

fn run_legacy_cli(app: &AppHandle, args: Vec<String>, title: &str) -> Result<ActionResult, String> {
    let binary = legacy_binary_path(app)?;
    let output = Command::new(&binary)
        .args(&args)
        .output()
        .map_err(|error| format!("Could not run {}: {error}", binary.display()))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let message = if output.status.success() {
        first_non_empty(&stdout, "Completed.")
    } else {
        first_non_empty(&stderr, &stdout)
    };

    Ok(action_result(title, &message, output.status.success()))
}

fn login_item_state_impl(app: &AppHandle) -> Result<LoginItemState, String> {
    // Status is read on every settings load (state_from_disk runs from 6 sync
    // commands). Serve it from the host-written cache file — a cheap read like
    // settings-overrides.json — so the frequent path never round-trips or blocks
    // on IPC. Only a missing cache (cold start) falls back to a one-shot request,
    // which also reseeds the cache host-side.
    if let Some(dir) = mas_shared_data_dir() {
        let cache = dir.join("login-state.json");
        if let Ok(data) = fs::read_to_string(&cache) {
            if let Ok(state) = serde_json::from_str::<LoginItemState>(&data) {
                return Ok(state);
            }
        }
        return request_login_item(app, "status", None);
    }
    run_login_item_cli(app, &["--login-item-status"])
}

fn set_launch_at_login_impl(app: &AppHandle, enabled: bool) -> Result<LoginItemState, String> {
    request_login_item(app, "set", Some(enabled))
}

// A correlation id for one login round-trip. Avoids pulling in a uuid crate:
// pid + epoch nanos + a process-local counter is unique enough to name a
// request/response pair in the shared dir.
fn login_request_nonce() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or(0);
    format!("{}-{nanos}-{n}", std::process::id())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LoginRequest {
    action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    enabled: Option<bool>,
    nonce: String,
    created_at: f64,
}

// Login-item registration MUST run in the outer CCTrans.app process, because
// SMAppService.mainApp registers Bundle.main. In the MAS sandbox THIS process
// (the Tauri helper) is the inner CCTransTauri.app, and the cctrans-cli helper
// it would otherwise spawn also lives inside the inner bundle — both register
// the WRONG app. So hand the intent to the resident Swift host over the shared
// app-group dir and read back the state it produces. Off-sandbox there is no
// group dir; the CLI path already resolves the outer binary, so fall through.
fn request_login_item(
    app: &AppHandle,
    action: &str,
    enabled: Option<bool>,
) -> Result<LoginItemState, String> {
    let Some(dir) = login_requests_dir() else {
        let args: Vec<&str> = match enabled {
            Some(true) => vec!["--set-launch-at-login", "true"],
            Some(false) => vec!["--set-launch-at-login", "false"],
            None => vec!["--login-item-status"],
        };
        return run_login_item_cli(app, &args);
    };

    fs::create_dir_all(&dir)
        .map_err(|error| format!("Could not create login-requests dir: {error}"))?;
    let created_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| format!("Clock error: {error}"))?
        .as_secs_f64();
    let nonce = login_request_nonce();
    let request = LoginRequest {
        action: action.to_string(),
        enabled,
        nonce: nonce.clone(),
        created_at,
    };
    let body = serde_json::to_string_pretty(&request)
        .map_err(|error| format!("Could not encode login request: {error}"))?;

    // Publish atomically (temp + rename) so the host's directory watcher never
    // reads a half-written request — same discipline as claim_launch_file. The
    // ".tmp-req-" prefix is ignored by the host's "req-" filter mid-write.
    let tmp_path = dir.join(format!(".tmp-req-{nonce}.json"));
    let request_path = dir.join(format!("req-{nonce}.json"));
    fs::write(&tmp_path, &body)
        .map_err(|error| format!("Could not write login request: {error}"))?;
    fs::rename(&tmp_path, &request_path)
        .map_err(|error| format!("Could not publish login request: {error}"))?;

    // The host is resident and normally answers within a few ms; the 3s ceiling
    // is a safety net so a missing host surfaces an error instead of hanging.
    let response_path = dir.join(format!("resp-{nonce}.json"));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        if let Ok(data) = fs::read_to_string(&response_path) {
            let parsed = serde_json::from_str::<LoginItemState>(&data);
            let _ = fs::remove_file(&response_path);
            let _ = fs::remove_file(&request_path);
            return parsed.map_err(|error| {
                format!("Could not parse login item state: {error}. Output: {data}")
            });
        }
        if std::time::Instant::now() >= deadline {
            let _ = fs::remove_file(&request_path);
            return Err("Login host did not respond".to_string());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

// Privacy prompts must run in the outer CCTrans.app process. The visible
// helper window is a nested app, so requesting Screen Recording here would
// register CCTransTauri.app in System Settings instead of CCTrans.app.
fn request_host_permission(app: &AppHandle, action: &str) -> Result<ActionResult, String> {
    let dir = permission_requests_dir(app)?;
    fs::create_dir_all(&dir)
        .map_err(|error| format!("Could not create permission-requests dir: {error}"))?;
    let created_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| format!("Clock error: {error}"))?
        .as_secs_f64();
    let nonce = login_request_nonce();
    let request = PermissionRequest {
        action: action.to_string(),
        nonce: nonce.clone(),
        created_at,
    };
    let body = serde_json::to_string_pretty(&request)
        .map_err(|error| format!("Could not encode permission request: {error}"))?;

    let tmp_path = dir.join(format!(".tmp-req-{nonce}.json"));
    let request_path = dir.join(format!("req-{nonce}.json"));
    fs::write(&tmp_path, &body)
        .map_err(|error| format!("Could not write permission request: {error}"))?;
    fs::rename(&tmp_path, &request_path)
        .map_err(|error| format!("Could not publish permission request: {error}"))?;

    let response_path = dir.join(format!("resp-{nonce}.json"));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        if let Ok(data) = fs::read_to_string(&response_path) {
            let parsed = serde_json::from_str::<PermissionResponse>(&data);
            let _ = fs::remove_file(&response_path);
            let _ = fs::remove_file(&request_path);
            return parsed
                .map(|response| ActionResult {
                    title: response.title,
                    message: response.message,
                    ok: response.ok,
                })
                .map_err(|error| {
                    format!("Could not parse permission response: {error}. Output: {data}")
                });
        }
        if std::time::Instant::now() >= deadline {
            let _ = fs::remove_file(&request_path);
            return Err("CCTrans host did not respond to the permission request.".to_string());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ScreenshotRequest {
    created_at: f64,
}

// Screenshot translation must capture the screen as the OUTER CCTrans.app for TCC
// to attribute Screen Recording to the right bundle. In the MAS sandbox the only
// spawnable capture binary (cctrans-cli) lives inside the inner CCTransTauri.app,
// so a capture there registers the wrong app. Hand the intent to the resident
// Swift host instead — it runs ScreenCaptureKit as the outer app and shows the
// toast. Fire-and-forget: the host owns the selection UI and result, so no
// response is awaited. Off-sandbox legacy_binary_path resolves the OUTER binary
// directly, so the CLI path already attributes correctly.
fn request_screenshot_translation(
    app: &AppHandle,
    settings: &Settings,
) -> Result<ActionResult, String> {
    let Some(dir) = screenshot_requests_dir() else {
        return run_legacy_cli(
            app,
            legacy_cli_args(settings, &["--screenshot-once"]),
            "Screenshot Translation",
        );
    };

    fs::create_dir_all(&dir)
        .map_err(|error| format!("Could not create screenshot-requests dir: {error}"))?;
    let created_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| format!("Clock error: {error}"))?
        .as_secs_f64();
    let nonce = login_request_nonce();
    let body = serde_json::to_string_pretty(&ScreenshotRequest { created_at })
        .map_err(|error| format!("Could not encode screenshot request: {error}"))?;

    // Atomic temp + rename so the host watcher never reads a half-written trigger.
    let tmp_path = dir.join(format!(".tmp-req-{nonce}.json"));
    let request_path = dir.join(format!("req-{nonce}.json"));
    fs::write(&tmp_path, &body)
        .map_err(|error| format!("Could not write screenshot request: {error}"))?;
    fs::rename(&tmp_path, &request_path)
        .map_err(|error| format!("Could not publish screenshot request: {error}"))?;

    Ok(action_result(
        "Screenshot Translation",
        "Screenshot translation started in CCTrans.",
        true,
    ))
}

fn run_login_item_cli(app: &AppHandle, args: &[&str]) -> Result<LoginItemState, String> {
    let binary = legacy_binary_path(app)?;
    let output = Command::new(&binary)
        .args(args)
        .output()
        .map_err(|error| format!("Could not run {}: {error}", binary.display()))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !output.status.success() {
        return Err(first_non_empty(&stderr, &stdout));
    }

    serde_json::from_str(&stdout)
        .map_err(|error| format!("Could not parse login item status: {error}. Output: {stdout}"))
}

fn open_surface_action(
    app: &AppHandle,
    surface: AppSurface,
    title: &str,
) -> Result<ActionResult, String> {
    open_surface_window(app, surface)?;
    Ok(action_result(title, "Tauri window opened.", true))
}

fn legacy_binary_path(app: &AppHandle) -> Result<PathBuf, String> {
    if let Ok(current_exe) = std::env::current_exe() {
        // Prefer the inherited-sandbox CLI helper bundled next to this Tauri
        // helper (MAS builds only). Spawning the main app's own sandboxed binary
        // from here traps in _libsecinit_appsandbox at launch; cctrans-cli is
        // signed with com.apple.security.inherit so it runs in our sandbox.
        // Falls through to the main binary in dev builds, where it does not exist.
        if let Some(sibling_cli) = current_exe.parent().map(|dir| dir.join("cctrans-cli")) {
            if sibling_cli.exists() {
                return Ok(sibling_cli);
            }
        }
        if let Some(bundle) = app_bundle_ancestor(&current_exe) {
            let candidate = host_binary_for_app_bundle(&bundle);
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }

    let roots = candidate_roots(app);
    for root in roots {
        let candidates = [
            root.join(".build/debug/CCTrans"),
            root.join("dist/CCTrans.app/Contents/MacOS/CCTrans"),
        ];
        if let Some(path) = candidates.into_iter().find(|path| path.exists()) {
            return Ok(path);
        }
    }
    Err("CCTrans CLI binary not found. Build the Swift app first.".to_string())
}

fn host_binary_for_app_bundle(bundle: &Path) -> PathBuf {
    bundle.join("Contents/MacOS/CCTrans")
}

fn legacy_working_dir(app: &AppHandle) -> Option<PathBuf> {
    candidate_roots(app)
        .into_iter()
        .find(|root| root.join("scripts/runtimes").is_dir())
}

fn app_bundle_ancestor(path: &Path) -> Option<PathBuf> {
    // MUST take the OUTERMOST `.app`, not innermost (`.last()`, not `.find()`).
    // This runs inside the nested Tauri helper (.../CCTrans.app/Contents/Resources/
    // CCTransTauri.app/...), whose bundle id is `as.kargn.cctrans.helper`. Input
    // Monitoring grants must hit the outer `as.kargn.cctrans` that creates the
    // CGEventTap; targeting the helper leaves Cmd+C dead after a "granted" prompt.
    path.ancestors()
        .filter(|ancestor| {
            ancestor
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("app"))
        })
        .last()
        .map(Path::to_path_buf)
}

fn candidate_roots(app: &AppHandle) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(root) = workspace_root_arg().or_else(workspace_root_env) {
        push_ancestors(&mut roots, &root);
    }
    if let Ok(current) = std::env::current_dir() {
        push_ancestors(&mut roots, &current);
    }
    if let Ok(resource_dir) = app.path().resource_dir() {
        push_ancestors(&mut roots, &resource_dir);
    }
    roots
}

fn workspace_root_env() -> Option<PathBuf> {
    std::env::var("CCTRANS_WORKSPACE_ROOT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
}

fn workspace_root_arg() -> Option<PathBuf> {
    let mut args = effective_args().iter();
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--workspace-root=") {
            if !value.trim().is_empty() {
                return Some(PathBuf::from(value));
            }
        }
        if arg.as_str() == "--workspace-root" {
            return args
                .next()
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from);
        }
    }
    None
}

fn push_ancestors(roots: &mut Vec<PathBuf>, start: &Path) {
    for ancestor in start.ancestors() {
        let root = ancestor.to_path_buf();
        if root.join("Package.swift").exists() && !roots.contains(&root) {
            roots.push(root);
        }
    }
}

fn first_non_empty(primary: &str, fallback: &str) -> String {
    if !primary.is_empty() {
        primary.to_string()
    } else if !fallback.is_empty() {
        fallback.to_string()
    } else {
        "No output.".to_string()
    }
}

fn request_logs_state(app: &AppHandle) -> Result<RequestLogsState, String> {
    let file = read_request_log_file(app)?;
    let summary = request_log_summary(&file.entries);
    Ok(RequestLogsState {
        entries: file.entries,
        summary,
        storage_path: request_logs_path(app)?.display().to_string(),
    })
}

fn read_request_log_file(app: &AppHandle) -> Result<RequestLogFile, String> {
    let path = request_logs_path(app)?;
    if !path.exists() {
        return Ok(RequestLogFile::default());
    }
    let data = fs::read_to_string(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    serde_json::from_str(&data)
        .map_err(|error| format!("Could not parse {}: {error}", path.display()))
}

fn write_request_log_file(app: &AppHandle, file: &RequestLogFile) -> Result<(), String> {
    let path = request_logs_path(app)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }
    let data = serde_json::to_string_pretty(file)
        .map_err(|error| format!("Could not encode request logs: {error}"))?;
    fs::write(&path, data).map_err(|error| format!("Could not write {}: {error}", path.display()))
}

fn request_logs_path(app: &AppHandle) -> Result<PathBuf, String> {
    shared_data_dir(app).map(|dir| dir.join("request-logs.json"))
}

fn request_log_summary(entries: &[RequestLogEntryState]) -> RequestLogSummaryState {
    RequestLogSummaryState {
        request_count: entries.len(),
        duplicate_suspect_count: entries
            .iter()
            .filter(|entry| entry.is_duplicate_suspect)
            .count(),
        prompt_tokens: entries.iter().map(|entry| entry.prompt_tokens).sum(),
        completion_tokens: entries.iter().map(|entry| entry.completion_tokens).sum(),
        total_tokens: entries.iter().map(|entry| entry.total_tokens).sum(),
        cost_credits: entries
            .iter()
            .map(|entry| entry.cost_credits.unwrap_or_default())
            .sum(),
    }
}

fn openrouter_api_key_state() -> Result<OpenRouterAPIKeyState, String> {
    let path = credential_env_path()?;
    let configured = std::env::var("OPENROUTER_API_KEY")
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
        || read_env_key(&path, "OPENROUTER_API_KEY")?.is_some();
    Ok(OpenRouterAPIKeyState {
        configured,
        path: path.display().to_string(),
    })
}

fn openrouter_api_key() -> Result<Option<String>, String> {
    if let Ok(value) = std::env::var("OPENROUTER_API_KEY") {
        let value = value.trim().to_string();
        if !value.is_empty() {
            return Ok(Some(value));
        }
    }
    read_env_key(&credential_env_path()?, "OPENROUTER_API_KEY")
}

fn credential_env_path() -> Result<PathBuf, String> {
    if let Some(dir) = mas_shared_data_dir() {
        return Ok(dir.join("credentials.env"));
    }
    let home = std::env::var("HOME").map_err(|_| "HOME is not set.".to_string())?;
    Ok(PathBuf::from(home).join(".config/cctrans/.env"))
}

fn read_env_key(path: &Path, key: &str) -> Result<Option<String>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let data = fs::read_to_string(path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    for line in data.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            continue;
        }
        if let Some((line_key, value)) = trimmed.split_once('=') {
            if line_key.trim() == key {
                let value = value
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .to_string();
                return Ok((!value.is_empty()).then_some(value));
            }
        }
    }
    Ok(None)
}

fn write_env_key(key: &str, value: Option<&str>) -> Result<(), String> {
    let value = match value {
        Some(raw) if validate_env_value(raw) && !raw.trim().is_empty() => Some(raw.trim()),
        Some(_) => {
            return Err("Credential values must be non-empty single-line strings.".to_string())
        }
        None => None,
    };
    let path = credential_env_path()?;
    let mut lines = if path.exists() {
        fs::read_to_string(&path)
            .map_err(|error| format!("Could not read {}: {error}", path.display()))?
            .lines()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };

    let mut replaced = false;
    lines.retain_mut(|line| {
        let trimmed = line.trim();
        let matches_key = !trimmed.starts_with('#')
            && trimmed
                .split_once('=')
                .map(|(line_key, _)| line_key.trim() == key)
                .unwrap_or(false);
        if !matches_key {
            return true;
        }
        if let Some(value) = value {
            *line = format!("{key}={value}");
            replaced = true;
            true
        } else {
            replaced = true;
            false
        }
    });

    if let Some(value) = value {
        if !replaced {
            lines.push(format!("{key}={value}"));
        }
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create {}: {error}", parent.display()))?;
    }

    let data = if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    };
    replace_private_file_contents(&path, &data)
}

fn permission_status(app: &AppHandle) -> PermissionStatus {
    // The settings/permission UI runs in THIS helper, a different TCC subject than
    // the outer CCTrans.app that actually holds these grants (it owns the CGEventTap
    // and ScreenCaptureKit). Preflighting here reports the helper's always-empty
    // state, so read the status the host publishes to the shared dir instead. Fall
    // back to a local preflight only when the cache is absent (cold start / dev).
    if let Ok(dir) = shared_data_dir(app) {
        if let Ok(data) = fs::read_to_string(dir.join("permission-status.json")) {
            if let Ok(status) = serde_json::from_str::<PermissionStatus>(&data) {
                return status;
            }
        }
    }
    permission_status_local()
}

#[cfg(target_os = "macos")]
fn permission_status_local() -> PermissionStatus {
    // MAS strips Accessibility (App Review 2.4.5): never call AXIsProcessTrusted on the
    // sandboxed variant. The caret-anchor feature was removed and the selection is read
    // through the sandbox, so accessibility is N/A; Cmd+C uses pasteboard polling, so the
    // keyboard capability is always satisfied. Only Screen Recording reflects live TCC state.
    if is_mas_variant() {
        return PermissionStatus {
            keyboard: true,
            accessibility: false,
            screen: unsafe { CGPreflightScreenCaptureAccess() },
        };
    }
    let accessibility = unsafe { AXIsProcessTrusted() };
    let keyboard = unsafe { CGPreflightListenEventAccess() || accessibility };
    let screen = unsafe { CGPreflightScreenCaptureAccess() };
    PermissionStatus {
        keyboard,
        accessibility,
        screen,
    }
}

#[cfg(not(target_os = "macos"))]
fn permission_status_local() -> PermissionStatus {
    PermissionStatus {
        keyboard: false,
        accessibility: false,
        screen: false,
    }
}

fn action_result(title: &str, message: &str, ok: bool) -> ActionResult {
    ActionResult {
        title: title.to_string(),
        message: message.to_string(),
        ok,
    }
}

#[cfg(target_os = "macos")]
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn CGPreflightListenEventAccess() -> bool;
    fn CGPreflightScreenCaptureAccess() -> bool;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_settings_omits_defaults() {
        let defaults = default_settings();
        let stored = StoredSettings::from_effective(&defaults, &defaults, false);
        assert!(stored.is_empty());
    }

    #[test]
    fn stored_settings_can_keep_default_provider_for_variant_safe_payloads() {
        let defaults = default_settings_for_current_variant();
        let stored = StoredSettings::from_effective(&defaults, &defaults, true);
        assert_eq!(stored.provider, Some(defaults.provider));
    }

    #[test]
    fn mas_runtime_defaults_and_options_stay_provider_aligned() {
        let runtime = SettingsRuntime::for_variant(AppVariant::MacAppStore);

        assert_eq!(
            runtime.default_settings().provider,
            TranslationProvider::AppleTranslation
        );

        let providers: Vec<_> = runtime
            .provider_options()
            .into_iter()
            .map(|option| option.value)
            .collect();

        assert_eq!(
            providers,
            vec![
                "appleTranslation".to_string(),
                "kargnasManaged".to_string(),
                "openRouter".to_string()
            ]
        );
    }

    #[test]
    fn mas_runtime_normalizes_stale_local_provider_payloads() {
        let runtime = SettingsRuntime::for_variant(AppVariant::MacAppStore);

        let settings = runtime.apply_stored(StoredSettings {
            provider: Some(TranslationProvider::LocalHyMT2),
            ..StoredSettings::default()
        });

        assert_eq!(settings.provider, TranslationProvider::AppleTranslation);
    }

    #[test]
    fn mas_runtime_keeps_cloud_provider_payloads() {
        let runtime = SettingsRuntime::for_variant(AppVariant::MacAppStore);

        let settings = runtime.apply_stored(StoredSettings {
            provider: Some(TranslationProvider::KargnasManaged),
            ..StoredSettings::default()
        });

        assert_eq!(settings.provider, TranslationProvider::KargnasManaged);
    }

    #[test]
    fn mas_runtime_persists_default_provider_for_host_helper_alignment() {
        let runtime = SettingsRuntime::for_variant(AppVariant::MacAppStore);
        let defaults = runtime.default_settings();
        let stored = runtime.stored_from_effective(&defaults);

        assert_eq!(stored.provider, Some(TranslationProvider::AppleTranslation));
    }

    #[test]
    fn host_app_id_args_select_host_shared_settings_dir() {
        let args = vec![
            "--surface".to_string(),
            "settings".to_string(),
            "--host-app-id".to_string(),
            "as.kargn.cctrans.dev".to_string(),
        ];
        let host_id = host_app_identifier_from_args(&args).expect("host app id");
        let dir = host_application_support_dir(Path::new("/Users/example"), &host_id);

        assert_eq!(host_id, "as.kargn.cctrans.dev");
        assert_eq!(
            dir,
            PathBuf::from("/Users/example/Library/Application Support/as.kargn.cctrans.dev")
        );
    }

    #[test]
    fn host_app_id_args_reject_invalid_bundle_ids() {
        let args = vec![
            "--host-app-id".to_string(),
            "../as.kargn.cctrans".to_string(),
        ];

        assert_eq!(host_app_identifier_from_args(&args), None);
    }

    #[test]
    fn mas_preview_model_selection_cannot_leave_local_provider_selected() {
        let runtime = SettingsRuntime::for_variant(AppVariant::MacAppStore);
        let settings = apply_preview_model_selection_for_runtime(
            runtime,
            runtime.default_settings(),
            TranslationProvider::LocalHyMT2,
            "hymt2-transformers-1.8b",
        )
        .unwrap();

        assert_eq!(settings.provider, TranslationProvider::AppleTranslation);
    }

    #[test]
    fn mas_preview_model_selection_keeps_cloud_provider_selected() {
        let runtime = SettingsRuntime::for_variant(AppVariant::MacAppStore);
        let settings = apply_preview_model_selection_for_runtime(
            runtime,
            runtime.default_settings(),
            TranslationProvider::KargnasManaged,
            "cloud",
        )
        .unwrap();

        assert_eq!(settings.provider, TranslationProvider::KargnasManaged);
    }

    #[test]
    fn replace_file_contents_swaps_directory_entry() {
        use std::os::unix::fs::MetadataExt;

        let dir = std::env::temp_dir().join(format!("cctrans-replace-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings-overrides.json");

        replace_file_contents(&path, "{\"a\":1}").unwrap();
        let first_inode = fs::metadata(&path).unwrap().ino();

        replace_file_contents(&path, "{\"a\":2}").unwrap();
        let second_inode = fs::metadata(&path).unwrap().ino();

        assert_eq!(fs::read_to_string(&path).unwrap(), "{\"a\":2}");
        // The menu-bar app's directory watcher only sees entry changes, so the
        // replace must go through rename (new inode), not an in-place write.
        assert_ne!(first_inode, second_inode);
        // The temp file must not survive the swap.
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn credential_value_rejects_environment_line_injection() {
        assert!(validate_env_value("sk-or-v1_example"));
        assert!(!validate_env_value("secret\nHF_TOKEN=injected"));
        assert!(!validate_env_value("secret\rHF_TOKEN=injected"));
        assert!(!validate_env_value("secret\0suffix"));
    }

    #[test]
    fn private_file_replace_uses_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!(
            "cctrans-private-replace-test-{}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("credentials.env");

        replace_private_file_contents(&path, "OPENROUTER_API_KEY=secret\n").unwrap();

        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "OPENROUTER_API_KEY=secret\n"
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parses_retranslate_stream_events() {
        let partial: PreviewStreamEvent = serde_json::from_str(r#"{"partial":"안녕"}"#).unwrap();
        assert_eq!(partial.partial.as_deref(), Some("안녕"));
        assert!(partial.final_text.is_none());

        let final_event: PreviewStreamEvent =
            serde_json::from_str(r#"{"final":"안녕하세요"}"#).unwrap();
        assert_eq!(final_event.final_text.as_deref(), Some("안녕하세요"));
        assert!(final_event.partial.is_none());

        // A newline inside a partial survives encoding as a single JSON line, so line-based reading
        // never splits one chunk into two malformed events.
        let multiline: PreviewStreamEvent =
            serde_json::from_str("{\"partial\":\"a\\nb\"}").unwrap();
        assert_eq!(multiline.partial.as_deref(), Some("a\nb"));
    }

    #[test]
    fn toast_refresh_shows_when_result_replaces_loading_for_same_sequence() {
        assert!(toast_refresh_should_show(3, "loading", 2, None));
        assert!(toast_refresh_should_show(
            3,
            "translated",
            3,
            Some("loading")
        ));
        assert!(toast_refresh_should_show(3, "error", 3, Some("loading")));
        assert!(!toast_refresh_should_show(
            3,
            "translated",
            3,
            Some("translated")
        ));
        assert!(!toast_refresh_should_show(
            0,
            "translated",
            0,
            Some("loading")
        ));
    }

    #[test]
    fn translation_preview_state_defaults_when_new_fields_absent() {
        let legacy = r#"{
            "mode":"translated","sourceLanguage":"English","targetLanguage":"Korean",
            "originalText":"hi","translatedText":"안녕","errorText":null,
            "providerTitle":"Local Model","model":"m","costCredits":null,"permissionAction":null
        }"#;
        let state: TranslationPreviewState = serde_json::from_str(legacy).unwrap();
        assert_eq!(state.request_sequence, 0);
        assert!(state.caret_x.is_none());
        assert!(state.caret_y.is_none());
        assert!(state.model_warning.is_none());
        assert!(state.translated_image_url.is_none());
        assert!(!state.did_reverse_because_languages_matched);
        assert!(!state.anchor_bottom);
    }

    #[test]
    fn translation_preview_state_roundtrips_new_fields() {
        let json = r#"{
            "mode":"translated","sourceLanguage":"English","targetLanguage":"Korean",
            "originalText":"hi","translatedText":"안녕","errorText":null,
            "providerTitle":"Local Model","model":"m","costCredits":null,"permissionAction":null,
            "didReverseBecauseLanguagesMatched":true,
            "translatedImageURL":"data:image/png;base64,abc",
            "modelWarning":"Vision model used","requestSequence":7,
            "caretX":10.0,"caretY":20.0,"caretW":2.0,"caretH":18.0,"anchorBottom":true
        }"#;
        let state: TranslationPreviewState = serde_json::from_str(json).unwrap();
        assert_eq!(state.request_sequence, 7);
        assert_eq!(state.caret_x, Some(10.0));
        assert_eq!(state.model_warning.as_deref(), Some("Vision model used"));
        assert!(state.did_reverse_because_languages_matched);
        assert_eq!(
            state.translated_image_url.as_deref(),
            Some("data:image/png;base64,abc")
        );
        assert!(state.anchor_bottom);
        let encoded = serde_json::to_string(&state).unwrap();
        assert!(encoded.contains("\"modelWarning\":\"Vision model used\""));
        assert!(encoded.contains("\"translatedImageURL\":\"data:image/png;base64,abc\""));
        assert!(encoded.contains("\"didReverseBecauseLanguagesMatched\":true"));
        assert!(encoded.contains("\"requestSequence\":7"));
        assert!(encoded.contains("\"anchorBottom\":true"));
    }

    #[test]
    fn persistent_translation_url_keeps_mode_state_dynamic() {
        let url = persistent_translation_url(false);
        assert_eq!(url, "index.html?surface=translation&debug=0");
        assert!(!url.contains("mode="));
    }

    #[test]
    fn stored_settings_keeps_only_overrides() {
        let defaults = default_settings();
        let mut settings = defaults.clone();
        settings.provider = TranslationProvider::OpenRouter;
        settings.open_router_text_model = "custom/text-model".to_string();

        let stored = StoredSettings::from_effective(&settings, &defaults, false);
        assert_eq!(stored.provider, Some(TranslationProvider::OpenRouter));
        assert_eq!(
            stored.open_router_text_model.as_deref(),
            Some("custom/text-model")
        );
        assert!(stored.open_router_vision_model.is_none());
        assert!(stored.target_language.is_none());
    }

    #[test]
    fn stored_settings_keeps_custom_toast_position() {
        let defaults = default_settings();
        let mut settings = defaults.clone();
        settings.toast_position = ToastPosition::Custom;
        settings.toast_custom_position = Some(ToastCustomPosition { x: 128.0, y: 256.0 });

        let stored = StoredSettings::from_effective(&settings, &defaults, false);

        assert_eq!(stored.toast_position, Some(ToastPosition::Custom));
        assert_eq!(
            stored.toast_custom_position,
            Some(ToastCustomPosition { x: 128.0, y: 256.0 })
        );
    }

    #[test]
    fn stored_settings_keeps_openrouter_filter_override() {
        let defaults = default_settings();
        let mut settings = defaults.clone();
        settings
            .open_router_model_filter
            .max_prompt_price_per_million = 1.25;
        settings
            .open_router_model_filter
            .max_completion_price_per_million = 6.5;
        settings.open_router_model_filter.modality_mode = OpenRouterModalityMode::Others;

        let stored = StoredSettings::from_effective(&settings, &defaults, false);
        let reloaded = apply_stored_settings(stored);

        assert_eq!(
            reloaded
                .open_router_model_filter
                .max_prompt_price_per_million,
            1.25
        );
        assert_eq!(
            reloaded
                .open_router_model_filter
                .max_completion_price_per_million,
            6.5
        );
        assert_eq!(
            reloaded.open_router_model_filter.modality_mode,
            OpenRouterModalityMode::Others
        );
    }

    #[test]
    fn openrouter_filter_accepts_legacy_all_modality_value() {
        let filter: OpenRouterModelFilter = serde_json::from_str(
            r#"{
                "modalityMode":"all",
                "minPromptPricePerMillion":0.0,
                "maxPromptPricePerMillion":2.0,
                "minCompletionPricePerMillion":0.0,
                "maxCompletionPricePerMillion":10.0
            }"#,
        )
        .unwrap();

        assert_eq!(filter.modality_mode, OpenRouterModalityMode::Others);
    }

    #[test]
    fn normalize_swaps_openrouter_filter_price_ranges() {
        let mut settings = default_settings();
        settings
            .open_router_model_filter
            .min_prompt_price_per_million = 8.0;
        settings
            .open_router_model_filter
            .max_prompt_price_per_million = 2.0;
        settings
            .open_router_model_filter
            .min_completion_price_per_million = 12.0;
        settings
            .open_router_model_filter
            .max_completion_price_per_million = 1.0;

        let settings = normalize_settings(settings);

        assert_eq!(
            settings
                .open_router_model_filter
                .min_prompt_price_per_million,
            2.0
        );
        assert_eq!(
            settings
                .open_router_model_filter
                .max_prompt_price_per_million,
            8.0
        );
        assert_eq!(
            settings
                .open_router_model_filter
                .min_completion_price_per_million,
            1.0
        );
        assert_eq!(
            settings
                .open_router_model_filter
                .max_completion_price_per_million,
            12.0
        );
    }

    #[test]
    fn openrouter_api_model_maps_pricing_modalities_and_release_date() {
        let model = openrouter_model_from_api(OpenRouterAPIModel {
            id: "example/model:free".to_string(),
            name: "Example Model".to_string(),
            created: Some(1_704_067_200),
            context_length: Some(131_072),
            pricing: OpenRouterAPIPricing {
                prompt: Some(serde_json::Value::String("0".to_string())),
                completion: Some(serde_json::Value::String("0".to_string())),
            },
            architecture: OpenRouterAPIArchitecture {
                tokenizer: Some("ExampleTok".to_string()),
                input_modalities: vec!["text".to_string(), "image".to_string()],
                output_modalities: vec!["text".to_string()],
            },
            supported_parameters: vec!["reasoning".to_string()],
            top_provider: OpenRouterAPITopProvider {
                max_completion_tokens: Some(32_768),
                is_moderated: Some(true),
            },
            knowledge_cutoff: Some("2025-01-01".to_string()),
            expiration_date: Some("2026-12-31".to_string()),
        })
        .unwrap();

        assert_eq!(model.value, "example/model:free");
        assert_eq!(model.release_date, "2024-01-01");
        assert_eq!(model.context_window, 131_072);
        assert_eq!(
            model.modalities,
            vec!["image".to_string(), "text".to_string()]
        );
        assert_eq!(model.output_modalities, vec!["text".to_string()]);
        assert_eq!(model.daily_token_rank, None);
        assert_eq!(model.throughput_rank, None);
        assert_eq!(model.tokenizer.as_deref(), Some("ExampleTok"));
        assert_eq!(model.max_completion_tokens, Some(32_768));
        assert_eq!(model.is_moderated, Some(true));
        assert_eq!(model.knowledge_cutoff.as_deref(), Some("2025-01-01"));
        assert_eq!(model.expiration_date.as_deref(), Some("2026-12-31"));
        assert!(model.is_free);
        assert!(model.is_reasoning);
        assert_eq!(model.note.as_deref(), Some("Free event"));
    }

    #[test]
    fn openrouter_free_router_is_free_but_auto_router_is_variable_priced() {
        let free_router = openrouter_model_from_api(OpenRouterAPIModel {
            id: "openrouter/free".to_string(),
            name: "Free Models Router".to_string(),
            created: Some(1_704_067_200),
            context_length: Some(131_072),
            pricing: OpenRouterAPIPricing {
                prompt: Some(serde_json::Value::String("0".to_string())),
                completion: Some(serde_json::Value::String("0".to_string())),
            },
            architecture: OpenRouterAPIArchitecture {
                tokenizer: Some("Router".to_string()),
                input_modalities: vec!["text".to_string(), "image".to_string()],
                output_modalities: vec!["text".to_string()],
            },
            supported_parameters: Vec::new(),
            top_provider: OpenRouterAPITopProvider::default(),
            knowledge_cutoff: None,
            expiration_date: None,
        })
        .unwrap();

        assert!(free_router.is_free);
        assert_eq!(free_router.note.as_deref(), Some("Free event"));

        let auto_router = openrouter_model_from_api(OpenRouterAPIModel {
            id: "openrouter/auto".to_string(),
            name: "Auto Router".to_string(),
            created: Some(1_704_067_200),
            context_length: None,
            pricing: OpenRouterAPIPricing {
                prompt: Some(serde_json::Value::String("-1".to_string())),
                completion: Some(serde_json::Value::String("-1".to_string())),
            },
            architecture: OpenRouterAPIArchitecture {
                tokenizer: Some("Router".to_string()),
                input_modalities: vec!["text".to_string(), "image".to_string()],
                output_modalities: vec!["text".to_string(), "image".to_string()],
            },
            supported_parameters: Vec::new(),
            top_provider: OpenRouterAPITopProvider::default(),
            knowledge_cutoff: None,
            expiration_date: None,
        })
        .unwrap();

        assert!(!auto_router.is_free);
        assert_eq!(auto_router.prompt_price_per_million, -1_000_000.0);
        assert_eq!(auto_router.completion_price_per_million, -1_000_000.0);
        assert!(auto_router.note.is_none());
    }

    #[test]
    fn throughput_rankings_keep_first_twenty_models_and_apply_to_models() {
        let models = (0..22)
            .map(|index| OpenRouterAPIModel {
                id: format!("provider/fast-{index:02}"),
                name: format!("Fast {index:02}"),
                created: None,
                context_length: None,
                pricing: OpenRouterAPIPricing::default(),
                architecture: OpenRouterAPIArchitecture {
                    tokenizer: None,
                    input_modalities: vec!["text".to_string()],
                    output_modalities: if index == 1 {
                        vec!["image".to_string()]
                    } else {
                        vec!["text".to_string()]
                    },
                },
                supported_parameters: Vec::new(),
                top_provider: OpenRouterAPITopProvider::default(),
                knowledge_cutoff: None,
                expiration_date: None,
            })
            .collect::<Vec<_>>();

        let rankings = openrouter_order_top_rankings(models, 20);
        assert_eq!(rankings.get("provider/fast-00"), Some(&1));
        assert_eq!(rankings.get("provider/fast-01"), Some(&2));
        assert_eq!(rankings.get("provider/fast-19"), Some(&20));
        assert!(!rankings.contains_key("provider/fast-20"));
        assert!(!rankings.contains_key("provider/fast-21"));

        let mut models = vec![openrouter_model(
            "Fast",
            "provider/fast-00",
            None,
            0.1,
            0.2,
            &["text"],
            "2026-05-11",
            1000,
            false,
            false,
            false,
        )];
        apply_openrouter_throughput_rankings(&mut models, &rankings);
        assert_eq!(models[0].throughput_rank, Some(1));
    }

    #[test]
    fn daily_rankings_keep_latest_top_twenty_and_apply_to_models() {
        let mut rows = vec![
            OpenRouterRankingDailyRow {
                date: "2026-05-10".to_string(),
                model_permaslug: "old/model".to_string(),
                total_tokens: serde_json::Value::String("999999".to_string()),
            },
            OpenRouterRankingDailyRow {
                date: "2026-05-11".to_string(),
                model_permaslug: "other".to_string(),
                total_tokens: serde_json::Value::String("999999999".to_string()),
            },
        ];
        for index in 0..21 {
            rows.push(OpenRouterRankingDailyRow {
                date: "2026-05-11".to_string(),
                model_permaslug: format!("provider/model-{index:02}"),
                total_tokens: serde_json::Value::String((10_000 - index).to_string()),
            });
        }

        let rankings = openrouter_daily_top_rankings(rows, 20);
        assert_eq!(rankings.get("provider/model-00"), Some(&1));
        assert_eq!(rankings.get("provider/model-19"), Some(&20));
        assert!(!rankings.contains_key("provider/model-20"));
        assert!(!rankings.contains_key("other"));
        assert!(!rankings.contains_key("old/model"));

        let mut models = vec![openrouter_model(
            "Ranked",
            "provider/model-00",
            None,
            0.1,
            0.2,
            &["text"],
            "2026-05-11",
            1000,
            false,
            false,
            false,
        )];
        apply_openrouter_daily_rankings(&mut models, &rankings);
        assert_eq!(models[0].daily_token_rank, Some(1));
    }

    #[test]
    fn normalize_clears_custom_position_for_corner_toast_position() {
        let mut settings = default_settings();
        settings.toast_position = ToastPosition::TopLeft;
        settings.toast_custom_position = Some(ToastCustomPosition { x: 128.0, y: 256.0 });

        let settings = normalize_settings(settings);

        assert_eq!(settings.toast_position, ToastPosition::TopLeft);
        assert_eq!(settings.toast_custom_position, None);
    }

    #[test]
    fn preview_model_selection_updates_openrouter_text_model() {
        let settings = apply_preview_model_selection(
            default_settings(),
            TranslationProvider::OpenRouter,
            " anthropic/claude-opus-4.8 ",
        )
        .unwrap();

        assert_eq!(settings.provider, TranslationProvider::OpenRouter);
        assert_eq!(settings.open_router_text_model, "anthropic/claude-opus-4.8");
        assert_eq!(settings.local_model_id, default_settings().local_model_id);
    }

    #[test]
    fn preview_openrouter_model_selection_survives_settings_roundtrip() {
        let defaults = default_settings();
        let settings = apply_preview_model_selection(
            defaults.clone(),
            TranslationProvider::OpenRouter,
            "anthropic/claude-opus-4.8",
        )
        .unwrap();
        let stored = StoredSettings::from_effective(&settings, &defaults, false);

        let reloaded = apply_stored_settings(stored);

        assert_eq!(reloaded.provider, TranslationProvider::OpenRouter);
        assert_eq!(reloaded.open_router_text_model, "anthropic/claude-opus-4.8");
        assert_eq!(reloaded.local_model_id, defaults.local_model_id);
    }

    #[test]
    fn managed_provider_survives_settings_roundtrip() {
        // Variant defaults, not the base ones: production writes diff against
        // the current variant's defaults (stored_from_effective).
        let defaults = default_settings_for_current_variant();
        let mut settings = defaults.clone();
        settings.provider = TranslationProvider::KargnasManaged;

        let stored = StoredSettings::from_effective(&settings, &defaults, false);
        let reloaded = apply_stored_settings(stored);

        assert_eq!(reloaded.provider, TranslationProvider::KargnasManaged);
        assert_eq!(provider_title(&reloaded.provider), "CCTrans Cloud");
        assert_eq!(selected_model_title(&reloaded), "Managed (server-chosen)");
        assert_eq!(provider_arg(&reloaded.provider), "managed");
    }

    #[test]
    fn preview_model_selection_updates_managed_provider_without_model_side_effects() {
        let defaults = default_settings_for_current_variant();
        let mut initial = defaults.clone();
        initial.local_model_id = "hymt2-transformers-1.8b".to_string();
        initial.open_router_text_model = "anthropic/claude-opus-4.8".to_string();

        let settings =
            apply_preview_model_selection(initial, TranslationProvider::KargnasManaged, "cloud")
                .unwrap();
        let stored = StoredSettings::from_effective(&settings, &defaults, false);
        let reloaded = apply_stored_settings(stored);

        assert_eq!(settings.provider, TranslationProvider::KargnasManaged);
        assert_eq!(settings.local_model_id, "hymt2-transformers-1.8b");
        assert_eq!(settings.open_router_text_model, "anthropic/claude-opus-4.8");
        assert_eq!(reloaded.provider, TranslationProvider::KargnasManaged);
        assert_eq!(reloaded.local_model_id, "hymt2-transformers-1.8b");
        assert_eq!(reloaded.open_router_text_model, "anthropic/claude-opus-4.8");
    }

    #[test]
    fn preview_model_selection_updates_local_model() {
        let settings = apply_preview_model_selection(
            default_settings(),
            TranslationProvider::LocalHyMT2,
            "hymt2-transformers-1.8b",
        )
        .unwrap();

        assert_eq!(settings.provider, TranslationProvider::LocalHyMT2);
        assert_eq!(settings.local_model_id, "hymt2-transformers-1.8b");
    }

    #[test]
    fn preview_local_model_selection_survives_settings_roundtrip() {
        let defaults = default_settings();
        let settings = apply_preview_model_selection(
            defaults.clone(),
            TranslationProvider::LocalHyMT2,
            "hymt2-transformers-1.8b",
        )
        .unwrap();
        let stored = StoredSettings::from_effective(&settings, &defaults, false);

        let reloaded = apply_stored_settings(stored);

        assert_eq!(reloaded.provider, TranslationProvider::LocalHyMT2);
        assert_eq!(reloaded.local_model_id, "hymt2-transformers-1.8b");
    }

    #[test]
    fn preview_model_selection_rejects_empty_model() {
        let error = apply_preview_model_selection(
            default_settings(),
            TranslationProvider::OpenRouter,
            "   ",
        )
        .unwrap_err();

        assert_eq!(error, "Model is empty.");
    }

    #[test]
    fn preview_retranslate_metadata_uses_selected_model_and_clears_cost() {
        let mut settings = default_settings();
        settings.provider = TranslationProvider::OpenRouter;
        settings.open_router_text_model = "anthropic/claude-opus-4.8".to_string();
        settings.toast_duration = 8.0;
        let mut state = sample_translation_preview(&default_settings());
        state.target_language = "Japanese".to_string();
        state.cost_credits = Some(0.25);
        state.model_warning = Some("stale warning".to_string());

        prepare_translation_preview_for_retranslate(&mut state, &settings, None);

        assert_eq!(state.target_language, "Japanese");
        assert_eq!(state.provider_title, "OpenRouter LLM");
        assert_eq!(state.model, "Claude Opus 4.8");
        assert_eq!(state.model_warning, None);
        assert_eq!(state.cost_credits, None);
        assert_eq!(state.toast_duration, 8.0);
    }

    #[test]
    fn preview_retranslate_marks_auto_reversed_target_language() {
        let settings = default_settings();
        let mut state = sample_translation_preview(&settings);
        state.source_language = "Korean".to_string();
        state.target_language = "Korean".to_string();

        prepare_translation_preview_for_retranslate(&mut state, &settings, None);

        assert_eq!(state.target_language, "English");
        assert!(state.did_reverse_because_languages_matched);
    }

    #[test]
    fn preview_model_retranslate_preserves_auto_reverse_indicator() {
        let settings = default_settings();
        let mut state = sample_translation_preview(&settings);
        state.source_language = "Korean".to_string();
        state.target_language = "English".to_string();
        state.did_reverse_because_languages_matched = true;

        prepare_translation_preview_for_retranslate(&mut state, &settings, None);

        assert_eq!(state.target_language, "English");
        assert!(state.did_reverse_because_languages_matched);
    }

    #[test]
    fn legacy_hymt2_model_migrates_to_local_model_id() {
        let settings = apply_stored_settings(StoredSettings {
            provider: Some(TranslationProvider::OpenRouter),
            hy_mt2_model: Some(LegacyHyMT2Model::HyMT218B),
            ..StoredSettings::default()
        });

        assert_eq!(settings.provider, TranslationProvider::OpenRouter);
        assert_eq!(settings.local_model_id, "hymt2-transformers-1.8b");
    }

    #[test]
    fn optional_paths_trim_to_none() {
        let mut settings = default_settings();
        settings.local_hy_mt2_backend_path = Some("   ".to_string());
        settings.custom_local_models_path = Some("  ~/models.json  ".to_string());
        let settings = normalize_settings(settings);

        assert_eq!(settings.local_hy_mt2_backend_path, None);
        assert_eq!(
            settings.custom_local_models_path.as_deref(),
            Some("~/models.json")
        );
    }

    #[test]
    fn app_bundle_ancestor_finds_containing_bundle() {
        let path = PathBuf::from("/Applications/CCTrans.app/Contents/MacOS/CCTrans");

        assert_eq!(
            app_bundle_ancestor(&path).as_deref(),
            Some(Path::new("/Applications/CCTrans.app"))
        );
    }

    #[test]
    fn app_bundle_ancestor_returns_outer_app_for_nested_helper() {
        let path = PathBuf::from(
            "/Applications/CCTrans.app/Contents/Resources/CCTransTauri.app/Contents/MacOS/cctrans-tauri",
        );

        assert_eq!(
            app_bundle_ancestor(&path).as_deref(),
            Some(Path::new("/Applications/CCTrans.app"))
        );
    }

    #[test]
    fn host_binary_for_app_bundle_targets_outer_bundle_executable() {
        let bundle = Path::new("/Applications/CCTrans.app");

        assert_eq!(
            host_binary_for_app_bundle(bundle),
            PathBuf::from("/Applications/CCTrans.app/Contents/MacOS/CCTrans")
        );
    }

    #[test]
    fn caret_placement_prefers_below_cursor() {
        let placement = placement_near_caret(
            ScreenRect::new(500.0, 300.0, 2.0, 18.0).unwrap(),
            test_work_area(),
            356.0,
            150.0,
        );

        assert_eq!(placement.arrow, TranslationArrowPlacement::BelowCaret);
        assert_eq!(placement.position.x, 646);
        assert_eq!(placement.position.y, 652);
    }

    #[test]
    fn caret_placement_flips_above_near_bottom() {
        let placement = placement_near_caret(
            ScreenRect::new(500.0, 760.0, 2.0, 18.0).unwrap(),
            test_work_area(),
            356.0,
            150.0,
        );

        assert_eq!(placement.arrow, TranslationArrowPlacement::AboveCaret);
        assert_eq!(placement.position.x, 646);
        assert_eq!(placement.position.y, 1204);
    }

    #[test]
    fn caret_placement_clamps_to_work_area_edges() {
        let placement = placement_near_caret(
            ScreenRect::new(10.0, 20.0, 2.0, 18.0).unwrap(),
            test_work_area(),
            356.0,
            150.0,
        );

        assert_eq!(placement.arrow, TranslationArrowPlacement::BelowCaret);
        assert_eq!(placement.position.x, 48);
        assert_eq!(placement.position.y, 92);
    }

    #[test]
    fn fallback_placement_uses_toast_position_only_without_caret() {
        let mut settings = default_settings();
        settings.toast_position = ToastPosition::TopLeft;
        let placement = fallback_placement(&settings, test_work_area(), 356.0, 150.0);

        assert_eq!(placement.arrow, TranslationArrowPlacement::Fallback);
        assert_eq!(placement.position.x, 48);
        assert_eq!(placement.position.y, 48);
    }

    #[test]
    fn fallback_placement_uses_custom_toast_position() {
        let mut settings = default_settings();
        settings.toast_position = ToastPosition::Custom;
        settings.toast_custom_position = Some(ToastCustomPosition { x: 250.0, y: 180.0 });
        let placement = fallback_placement(&settings, test_work_area(), 356.0, 150.0);

        assert_eq!(placement.arrow, TranslationArrowPlacement::Fallback);
        assert_eq!(placement.position.x, 500);
        assert_eq!(placement.position.y, 360);
    }

    fn test_work_area() -> WorkArea {
        WorkArea {
            x: 0.0,
            y: 0.0,
            width: 1200.0,
            height: 800.0,
            scale: 2.0,
        }
    }
}

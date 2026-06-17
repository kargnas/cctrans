use serde::{Deserialize, Serialize};
mod surfaces;

use std::collections::BTreeMap;
#[cfg(target_os = "macos")]
use std::ffi::CString;
use std::fs;
#[cfg(target_os = "macos")]
use std::os::raw::{c_char, c_void};
use std::path::{Path, PathBuf};
use std::process::Command;
use surfaces::{open_surface_window, AppSurface};
#[cfg(target_os = "macos")]
use tauri::ActivationPolicy;
use tauri::{
    AppHandle, LogicalSize, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewUrl,
    WebviewWindowBuilder,
};

#[cfg(target_os = "macos")]
mod macos_drag {
    use objc2::rc::Retained;
    use objc2::runtime::{NSObject, NSObjectProtocol, ProtocolObject};
    use objc2::{define_class, msg_send, AnyThread, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{
        NSApplication, NSDragOperation, NSDraggingContext, NSDraggingItem, NSDraggingSource,
        NSPasteboardWriting, NSWindow, NSWorkspace,
    };
    use objc2_foundation::{NSArray, NSPoint, NSRect, NSSize, NSString, NSURL};
    use std::ffi::c_void;
    use std::path::Path;

    define_class!(
        #[unsafe(super(NSObject))]
        #[derive(Debug, PartialEq, Eq, Hash)]
        #[name = "CCTransPermissionDragSource"]
        #[thread_kind = MainThreadOnly]
        struct PermissionDragSource;

        unsafe impl NSObjectProtocol for PermissionDragSource {}

        unsafe impl NSDraggingSource for PermissionDragSource {
            #[unsafe(method(draggingSession:sourceOperationMaskForDraggingContext:))]
            fn source_operation_mask(
                &self,
                _session: &objc2_app_kit::NSDraggingSession,
                _context: NSDraggingContext,
            ) -> NSDragOperation {
                NSDragOperation::Copy
            }
        }
    );

    impl PermissionDragSource {
        fn new(mtm: MainThreadMarker) -> Retained<Self> {
            unsafe { msg_send![Self::alloc(mtm), init] }
        }
    }

    pub fn start_app_drag(bundle_path: &Path, ns_window: *mut c_void) -> Result<(), String> {
        let mtm = MainThreadMarker::new().ok_or("Native drag must start on the main thread.")?;
        let bundle_path = bundle_path
            .to_str()
            .ok_or("The app bundle path is not valid UTF-8.")?;
        let window = unsafe { (ns_window as *mut NSWindow).as_ref() }
            .ok_or("Permission Helper window is not available.")?;
        let event = NSApplication::sharedApplication(mtm)
            .currentEvent()
            .ok_or("Start dragging from the app card first.")?;

        let path = NSString::from_str(bundle_path);
        let file_url = NSURL::fileURLWithPath(&path);
        let writer: &ProtocolObject<dyn NSPasteboardWriting> = ProtocolObject::from_ref(&*file_url);
        let item = NSDraggingItem::initWithPasteboardWriter(NSDraggingItem::alloc(), writer);

        let origin = event.locationInWindow();
        let frame = NSRect::new(
            NSPoint::new(origin.x - 24.0, origin.y - 24.0),
            NSSize::new(48.0, 48.0),
        );
        let icon = NSWorkspace::sharedWorkspace().iconForFile(&path);
        let icon_object: &objc2::runtime::AnyObject = icon.as_ref();
        unsafe {
            item.setDraggingFrame_contents(frame, Some(icon_object));
        }

        let items = NSArray::from_slice(&[&*item]);
        let source = PermissionDragSource::new(mtm);
        let source: &ProtocolObject<dyn NSDraggingSource> = ProtocolObject::from_ref(&*source);

        if let Some(view) = window.contentView() {
            view.beginDraggingSessionWithItems_event_source(&items, &event, source);
        } else {
            window.beginDraggingSessionWithItems_event_source(&items, &event, source);
        }

        Ok(())
    }
}

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
                // dismissal. Hand the decision to the WebView (which knows mode + how long the
                // result has been readable) instead of hiding here, so a stray click during loading
                // or right after the result appears does not yank the toast away before it is seen.
                let _ = app.emit_to("translation", "toast-dismiss-request", ());
            }
        });
        let token = NSEvent::addGlobalMonitorForEventsMatchingMask_handler(mask, &handler);
        // The toast helper outlives every individual popup, so keep the monitor for the whole
        // process lifetime; dropping the token would unregister it via its Drop glue.
        std::mem::forget(token);
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
    #[serde(rename = "includeScreenContextForLLM")]
    include_screen_context_for_llm: bool,
    #[serde(rename = "sourceLanguage")]
    source_language: String,
    #[serde(rename = "targetLanguage")]
    target_language: String,
    #[serde(rename = "hasCompletedLocalModelSelection")]
    has_completed_local_model_selection: bool,
    #[serde(rename = "toastPosition")]
    toast_position: ToastPosition,
    #[serde(rename = "toastCustomPosition")]
    toast_custom_position: Option<ToastCustomPosition>,
    #[serde(rename = "toastDuration")]
    toast_duration: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
enum TranslationProvider {
    #[serde(rename = "localHyMT2")]
    LocalHyMT2,
    #[serde(rename = "openRouter")]
    OpenRouter,
    // Apple's on-device Translation framework; the only local provider the
    // sandboxed Mac App Store variant can offer.
    #[serde(rename = "appleTranslation")]
    AppleTranslation,
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
    #[serde(rename = "includeScreenContextForLLM")]
    include_screen_context_for_llm: Option<bool>,
    #[serde(rename = "sourceLanguage")]
    source_language: Option<String>,
    #[serde(rename = "targetLanguage")]
    target_language: Option<String>,
    #[serde(rename = "hasCompletedLocalModelSelection")]
    has_completed_local_model_selection: Option<bool>,
    #[serde(rename = "toastPosition")]
    toast_position: Option<ToastPosition>,
    #[serde(rename = "toastCustomPosition")]
    toast_custom_position: Option<ToastCustomPosition>,
    #[serde(rename = "toastDuration")]
    toast_duration: Option<f64>,
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

#[derive(Clone, Debug, Serialize)]
struct OpenRouterModelOption {
    label: String,
    value: String,
    note: Option<String>,
    #[serde(rename = "promptPricePerMillion")]
    prompt_price_per_million: f64,
    #[serde(rename = "completionPricePerMillion")]
    completion_price_per_million: f64,
    modalities: Vec<String>,
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
}

#[derive(Clone, Debug, Serialize)]
struct OpenRouterAPIKeyState {
    configured: bool,
    path: String,
}

#[derive(Clone, Debug, Serialize)]
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

#[derive(Clone, Debug, Serialize)]
struct PermissionAppTarget {
    #[serde(rename = "bundleName")]
    bundle_name: String,
    #[serde(rename = "bundlePath")]
    bundle_path: String,
    #[serde(rename = "bundleFileURL")]
    bundle_file_url: String,
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
    #[serde(rename = "originalText")]
    original_text: String,
    #[serde(rename = "translatedText")]
    translated_text: String,
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
    caret_override: Option<ScreenRect>,
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
    let defaults = default_settings();

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
        "translateScreenshot" => run_legacy_cli(
            &app,
            legacy_cli_args(&settings, &["--screenshot-once"]),
            "Screenshot Translation",
        ),
        "showRequestLogs" => open_surface_action(&app, AppSurface::RequestLogs, "Request Logs"),
        "showLocalModelSetup" => {
            open_surface_action(&app, AppSurface::LocalModelSetup, "Model Setup")
        }
        "openPermissionHelper" => {
            open_surface_action(&app, AppSurface::PermissionHelper, "Permission Helper")
        }
        "openInputMonitoring" => open_privacy_url(
            "Input Monitoring",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ),
        "openAccessibility" => open_privacy_url(
            "Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ),
        "openScreenRecording" => open_privacy_url(
            "Screen Recording",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ),
        "requestKeyboardPrompt" => request_keyboard_prompt(),
        "revealPermissionApp" => reveal_permission_app_impl(&app),
        _ => Err(format!("Unknown settings action: {action}")),
    }
}

#[tauri::command]
fn permission_app_target(app: AppHandle) -> Result<PermissionAppTarget, String> {
    let bundle_path = resolve_permission_app_bundle(&app)?;
    Ok(PermissionAppTarget {
        bundle_name: bundle_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("CCTrans.app")
            .to_string(),
        bundle_file_url: file_url_for_path(&bundle_path),
        bundle_path: bundle_path.display().to_string(),
    })
}

#[tauri::command]
fn reveal_permission_app(app: AppHandle) -> Result<ActionResult, String> {
    reveal_permission_app_impl(&app)
}

#[tauri::command]
fn start_permission_app_drag(
    app: AppHandle,
    window: tauri::WebviewWindow,
) -> Result<ActionResult, String> {
    #[cfg(target_os = "macos")]
    {
        let bundle_path = resolve_permission_app_bundle(&app)?;
        let ns_window = window
            .ns_window()
            .map_err(|error| format!("Permission Helper window is not available: {error}"))?;
        macos_drag::start_app_drag(&bundle_path, ns_window)?;
        return Ok(ActionResult {
            title: "Drag started".to_string(),
            message: "Drop CCTrans.app into the open macOS Privacy list.".to_string(),
            ok: true,
        });
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        let _ = window;
        Err("Native privacy drag is only supported on macOS.".to_string())
    }
}

#[tauri::command]
fn open_screen_recording_settings() -> Result<ActionResult, String> {
    open_privacy_url(
        "Screen Recording",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    )
}

#[tauri::command]
fn load_translation_preview(app: AppHandle) -> Result<TranslationPreviewState, String> {
    let settings = load_effective_settings(&app).unwrap_or_else(|_| default_settings());
    read_translation_preview_state(&app).map(|state| {
        let mut state = state.unwrap_or_else(|| sample_translation_preview(&settings));
        state.toast_duration = settings.toast_duration;
        state
    })
}

#[tauri::command]
fn translate_preview_to_language(
    app: AppHandle,
    target_language: String,
) -> Result<TranslationPreviewState, String> {
    let settings = apply_preview_target_language(load_effective_settings(&app)?, &target_language)?;
    write_settings(&app, settings)?;
    let settings = load_effective_settings(&app)?;
    let target_language = settings.target_language.clone();
    retranslate_preview(&app, settings, Some(target_language))
}

#[tauri::command]
fn translate_preview_to_model(
    app: AppHandle,
    provider: TranslationProvider,
    model_id: String,
) -> Result<TranslationPreviewState, String> {
    let settings =
        apply_preview_model_selection(load_effective_settings(&app)?, provider, &model_id)?;
    write_settings(&app, settings)?;
    let settings = load_effective_settings(&app)?;
    retranslate_preview(&app, settings, None)
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

    let mut translation_settings = settings;
    translation_settings.source_language = state.source_language.clone();
    translation_settings.target_language = state.target_language.clone();

    let original_text = state.original_text.clone();
    let args = legacy_cli_args(
        &translation_settings,
        &["--translate-text-once", original_text.as_str()],
    );
    let binary = legacy_binary_path(app)?;
    let mut command = Command::new(&binary);
    command.args(&args);
    // NSWorkspace launches this Tauri helper with cwd `/`, but the spawned Swift CLI
    // resolves `scripts/runtimes/<backend>.py` relative to its cwd. Pin the workspace
    // root so local-model retranslation does not fail with localModelUnavailable.
    if let Some(dir) = legacy_working_dir(app) {
        command.current_dir(dir);
    }
    let output = command
        .output()
        .map_err(|error| format!("Could not run {}: {error}", binary.display()))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if output.status.success() && !stdout.is_empty() {
        state.mode = "translated".to_string();
        state.translated_text = stdout;
        state.error_text = None;
    } else {
        state.mode = "error".to_string();
        state.error_text = Some(first_non_empty(&stderr, &stdout));
    }
    write_translation_preview_state(app, &state)?;
    Ok(state)
}

#[tauri::command]
fn close_translation_preview(app: AppHandle) -> Result<(), String> {
    // Persistent toast hides so the warmed WebView (and its font cache) survives for reuse;
    // the legacy throwaway process still exits so its behavior is byte-for-byte unchanged.
    if is_persistent_toast() {
        if let Some(window) = app.get_webview_window("translation") {
            window.hide().map_err(|error| error.to_string())?;
        }
        return Ok(());
    }
    app.exit(0);
    Ok(())
}

#[tauri::command]
fn resize_translation_preview(
    app: AppHandle,
    height: f64,
    anchor_bottom: bool,
) -> Result<(), String> {
    let window = app
        .get_webview_window("translation")
        .ok_or("Translation window is not available.")?;
    let clamped = height.clamp(TRANSLATION_WINDOW_HEIGHT, 720.0);
    let scale = window.scale_factor().map_err(|error| error.to_string())?;
    let previous = window.outer_size().map_err(|error| error.to_string())?;
    window
        .set_size(LogicalSize::new(TRANSLATION_WINDOW_WIDTH, clamped))
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
    let settings = load_effective_settings(app).unwrap_or_else(|_| default_settings());
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
    Ok(ShowToastResult {
        arrow: placement.arrow.as_query_value().to_string(),
        anchor_bottom,
    })
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
            let mut last_sequence: u64 = 0;
            let mut last_fingerprint: Option<(
                u64,
                String,
                String,
                String,
                String,
                String,
                String,
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
                );
                if last_fingerprint.as_ref() == Some(&fingerprint) {
                    continue;
                }
                last_fingerprint = Some(fingerprint);
                let should_show = seq != 0 && seq != last_sequence;
                if should_show {
                    last_sequence = seq;
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
                let settings =
                    load_effective_settings(app.handle()).unwrap_or_else(|_| default_settings());
                let height = if request.debug {
                    TRANSLATION_DEBUG_WINDOW_HEIGHT
                } else if request.mode == "loading" || request.mode == "error" {
                    TRANSLATION_TALL_WINDOW_HEIGHT
                } else {
                    TRANSLATION_WINDOW_HEIGHT
                };
                if is_persistent_toast() {
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
                            .build()?;
                    apply_toast_theme(&window);
                    macos_toast::install_pointer_monitor(app.handle().clone());
                    start_translation_toast_watcher(app.handle().clone());
                } else {
                    let placement = translation_window_placement(
                        app.handle(),
                        &settings,
                        TRANSLATION_WINDOW_WIDTH,
                        height,
                        request.caret_override,
                    );
                    // Svelte resizes the window to fit wrapped text; it must keep the edge that
                    // points at the caret fixed, so tell it which edge is anchored.
                    let anchor_bottom = match placement.arrow {
                        TranslationArrowPlacement::AboveCaret => true,
                        TranslationArrowPlacement::BelowCaret => false,
                        TranslationArrowPlacement::Fallback => matches!(
                            settings.toast_position,
                            ToastPosition::BottomRight | ToastPosition::BottomLeft
                        ),
                    };
                    let url = format!(
                        "index.html?surface=translation&mode={}&debug={}&placement={}&anchor={}",
                        request.mode,
                        if request.debug { "1" } else { "0" },
                        placement.arrow.as_query_value(),
                        if anchor_bottom { "bottom" } else { "top" }
                    );
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
                        .build()
                        .map(|window| {
                            let _ = window.set_position(placement.position);
                            apply_toast_theme(&window);
                            macos_toast::install_pointer_monitor(app.handle().clone());
                        })?;
                }
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
            save_settings,
            login_item_status,
            set_launch_at_login,
            reset_setting,
            load_openrouter_api_key_state,
            save_openrouter_api_key,
            clear_openrouter_api_key,
            perform_settings_action,
            permission_app_target,
            reveal_permission_app,
            start_permission_app_drag,
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
            show_translation_toast,
            close_settings_window
        ])
        .build(tauri::generate_context!())
        .expect("error while building CCTrans Tauri app")
        .run(|_app, event| {
            // The persistent toast must survive dismissing its only window so the next translation
            // reuses the warm WebView; legacy throwaway processes are unaffected and exit normally.
            match event {
                tauri::RunEvent::ExitRequested { api, .. } => {
                    if is_persistent_toast() {
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
    std::env::var_os("APP_SANDBOX_CONTAINER_ID").is_some()
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
    app.path()
        .app_data_dir()
        .map_err(|error| format!("Could not resolve app data directory: {error}"))
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
    let mut caret_override = None;

    for arg in effective_args() {
        if arg.as_str() == "--translation-preview" {
            enabled = true;
        } else if arg.as_str() == "--translation-preview-debug" {
            enabled = true;
            debug = true;
        } else if let Some(value) = arg.strip_prefix("--translation-preview-state=") {
            enabled = true;
            mode = normalized_translation_mode(value).to_string();
        } else if let Some(value) = arg.strip_prefix("--translation-preview-caret=") {
            enabled = true;
            caret_override = parse_screen_rect(value);
        }
    }

    enabled.then_some(TranslationPreviewRequest {
        mode,
        debug,
        caret_override,
    })
}

fn is_persistent_toast() -> bool {
    effective_args()
        .iter()
        .any(|arg| arg.as_str() == "--persistent")
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

fn parse_screen_rect(value: &str) -> Option<ScreenRect> {
    let numbers = value
        .split(',')
        .map(str::trim)
        .map(str::parse::<f64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    if numbers.len() != 4 {
        return None;
    }
    ScreenRect::new(numbers[0], numbers[1], numbers[2], numbers[3])
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
    let caret = caret_override.or_else(focused_text_caret_bounds);

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

#[cfg(target_os = "macos")]
fn focused_text_caret_bounds() -> Option<ScreenRect> {
    unsafe { focused_text_caret_bounds_macos() }
}

#[cfg(not(target_os = "macos"))]
fn focused_text_caret_bounds() -> Option<ScreenRect> {
    None
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
        original_text: "The future belongs to those who believe in the beauty of their dreams."
            .to_string(),
        translated_text: "미래는 자신의 꿈의 아름다움을 믿는 사람들의 것이다.".to_string(),
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
        // Single-model provider; there is no model id to store.
        TranslationProvider::AppleTranslation => {}
    }
    Ok(normalize_settings(settings))
}

fn prepare_translation_preview_for_retranslate(
    state: &mut TranslationPreviewState,
    settings: &Settings,
    target_language: Option<String>,
) {
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

    state.target_language = target_language;
    state.toast_duration = settings.toast_duration;
    state.provider_title = provider_title(&settings.provider).to_string();
    state.model = selected_model_title(settings);
    state.model_warning = None;
    state.cost_credits = None;
}

fn default_toast_duration_value() -> f64 {
    default_settings().toast_duration
}

fn provider_title(provider: &TranslationProvider) -> &'static str {
    match provider {
        TranslationProvider::LocalHyMT2 => "Local Model",
        TranslationProvider::OpenRouter => "OpenRouter LLM",
        TranslationProvider::AppleTranslation => "Apple Translation",
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
    let settings = load_effective_settings(app)?;
    let defaults = default_settings();
    let storage_path = settings_path(app)?.display().to_string();

    Ok(SettingsState {
        app_variant: app_variant().to_string(),
        overrides: override_map(&settings, &defaults),
        settings,
        defaults,
        options: settings_options(),
        permissions: permission_status(),
        login_item: login_item_state_impl(app).unwrap_or_else(|error| {
            LoginItemState::unsupported(format!("Login item status unavailable: {error}"))
        }),
        storage_path,
    })
}

// Distribution variant of the host app. The Swift shell launches this helper
// with `--app-variant mas` in Mac App Store bundles; everything else is the
// direct (DMG/brew/dev) build.
fn app_variant() -> &'static str {
    static VARIANT: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();
    VARIANT.get_or_init(|| {
        let args = effective_args();
        let is_mas = args
            .windows(2)
            .any(|pair| pair[0] == "--app-variant" && pair[1] == "mas");
        if is_mas {
            "mas"
        } else {
            "direct"
        }
    })
}

fn load_effective_settings(app: &AppHandle) -> Result<Settings, String> {
    let path = settings_path(app)?;
    if !path.exists() {
        return Ok(default_settings());
    }

    let data = fs::read_to_string(&path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    let stored: StoredSettings = serde_json::from_str(&data)
        .map_err(|error| format!("Could not parse {}: {error}", path.display()))?;
    Ok(apply_stored_settings(stored))
}

fn apply_stored_settings(stored: StoredSettings) -> Settings {
    let mut settings = default_settings();
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
    if let Some(value) = stored.toast_position {
        settings.toast_position = value;
    }
    if let Some(value) = stored.toast_custom_position {
        settings.toast_custom_position = Some(value);
    }
    if let Some(value) = stored.toast_duration {
        settings.toast_duration = value;
    }
    normalize_settings(settings)
}

fn write_settings(app: &AppHandle, settings: Settings) -> Result<(), String> {
    let path = settings_path(app)?;
    let defaults = default_settings();
    let stored = StoredSettings::from_effective(&settings, &defaults);

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

impl StoredSettings {
    fn from_effective(settings: &Settings, defaults: &Settings) -> Self {
        Self {
            provider: (settings.provider != defaults.provider).then(|| settings.provider.clone()),
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
            toast_position: (settings.toast_position != defaults.toast_position)
                .then(|| settings.toast_position.clone()),
            toast_custom_position: (settings.toast_custom_position
                != defaults.toast_custom_position)
                .then_some(settings.toast_custom_position)
                .flatten(),
            toast_duration: ((settings.toast_duration - defaults.toast_duration).abs()
                > f64::EPSILON)
                .then_some(settings.toast_duration),
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
            && self.include_screen_context_for_llm.is_none()
            && self.source_language.is_none()
            && self.target_language.is_none()
            && self.has_completed_local_model_selection.is_none()
            && self.toast_position.is_none()
            && self.toast_custom_position.is_none()
            && self.toast_duration.is_none()
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
        provider: TranslationProvider::LocalHyMT2,
        local_model_id: "hymt2-mlx-1.8b-4bit".to_string(),
        local_hy_mt2_backend_path: None,
        custom_local_models_path: None,
        open_router_text_model: "deepseek/deepseek-v4-flash".to_string(),
        open_router_vision_model: "google/gemini-3.1-flash-lite".to_string(),
        favorite_local_model_ids: vec!["hymt2-mlx-1.8b-4bit".to_string()],
        favorite_open_router_models: vec!["deepseek/deepseek-v4-flash".to_string()],
        include_screen_context_for_llm: false,
        source_language: "Auto".to_string(),
        target_language: "Korean".to_string(),
        has_completed_local_model_selection: false,
        toast_position: ToastPosition::BottomRight,
        toast_custom_position: None,
        toast_duration: 6.0,
    }
}

fn normalize_settings(mut settings: Settings) -> Settings {
    settings.local_hy_mt2_backend_path = normalized_optional(settings.local_hy_mt2_backend_path);
    settings.custom_local_models_path = normalized_optional(settings.custom_local_models_path);
    settings.open_router_text_model = settings.open_router_text_model.trim().to_string();
    settings.open_router_vision_model = settings.open_router_vision_model.trim().to_string();
    settings.favorite_local_model_ids = normalized_string_list(settings.favorite_local_model_ids);
    settings.favorite_open_router_models =
        normalized_string_list(settings.favorite_open_router_models);
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
    ])
}

fn settings_options() -> SettingsOptions {
    let mut providers = vec![
        option("Local Model", "localHyMT2", None),
        option("Apple Translation", "appleTranslation", Some("On-device")),
        option("OpenRouter LLM", "openRouter", None),
    ];
    if app_variant() == "mas" {
        // The sandbox cannot run the external Python local backend.
        providers.retain(|provider| provider.value != "localHyMT2");
    }
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
        open_router_models: openrouter_models(),
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
        release_date: release_date.to_string(),
        context_window,
        is_reasoning,
        is_free,
        is_recommended,
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
    run_login_item_cli(app, &["--login-item-status"])
}

fn set_launch_at_login_impl(app: &AppHandle, enabled: bool) -> Result<LoginItemState, String> {
    run_login_item_cli(
        app,
        &[
            "--set-launch-at-login",
            if enabled { "true" } else { "false" },
        ],
    )
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

fn resolve_permission_app_bundle(app: &AppHandle) -> Result<PathBuf, String> {
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(bundle) = app_bundle_ancestor(&current_exe) {
            return Ok(existing_path(bundle));
        }
    }

    let roots = candidate_roots(app);
    for root in roots {
        let candidates = [
            root.join("dist/CCTrans.app"),
            root.join("src-tauri/target/release/bundle/macos/CCTrans.app"),
            root.join("src-tauri/target/debug/bundle/macos/CCTrans.app"),
        ];
        if let Some(path) = candidates.into_iter().find(|path| path.exists()) {
            return Ok(existing_path(path));
        }
    }

    Err("CCTrans.app bundle not found. Build and launch the app bundle first.".to_string())
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

fn existing_path(path: PathBuf) -> PathBuf {
    std::fs::canonicalize(&path).unwrap_or(path)
}

fn file_url_for_path(path: &Path) -> String {
    format!(
        "file://{}",
        percent_encode_url_path(&path.to_string_lossy())
    )
}

fn percent_encode_url_path(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'.' | b'-' | b'_' | b'~' | b':' => {
                encoded.push(*byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

fn reveal_permission_app_impl(app: &AppHandle) -> Result<ActionResult, String> {
    let bundle_path = resolve_permission_app_bundle(app)?;

    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .arg("-R")
            .arg(&bundle_path)
            .spawn()
            .map_err(|error| format!("Could not reveal {}: {error}", bundle_path.display()))?;
        return Ok(action_result(
            "CCTrans.app",
            "Revealed in Finder. Drag the selected app into the open Privacy list.",
            true,
        ));
    }

    #[cfg(not(target_os = "macos"))]
    {
        Ok(action_result(
            "CCTrans.app",
            "Revealing the app bundle is macOS-only.",
            false,
        ))
    }
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

fn credential_env_path() -> Result<PathBuf, String> {
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
    fs::write(&path, data).map_err(|error| format!("Could not write {}: {error}", path.display()))
}

fn open_privacy_url(title: &str, url: &str) -> Result<ActionResult, String> {
    open_external_url(url).map_err(|error| format!("Could not open System Settings: {error}"))?;
    Ok(action_result(title, "System Settings opened.", true))
}

fn open_external_url(url: &str) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        Command::new("open").arg(url).spawn().map(|_| ())
    }

    #[cfg(target_os = "windows")]
    {
        Command::new("cmd")
            .args(["/C", "start", "", url])
            .spawn()
            .map(|_| ())
    }

    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    {
        Command::new("xdg-open").arg(url).spawn().map(|_| ())
    }
}

fn request_keyboard_prompt() -> Result<ActionResult, String> {
    #[cfg(target_os = "macos")]
    {
        let input_granted = unsafe { CGRequestListenEventAccess() };
        let accessibility = unsafe { AXIsProcessTrusted() };
        if !accessibility {
            // Input Monitoring shows a real system prompt, but Accessibility (caret
            // popovers) cannot be granted by a prompt — macOS only exposes it as a
            // manual toggle. Open that pane so the still-missing piece is actionable
            // instead of reporting "available" off Input Monitoring alone.
            let _ = open_privacy_url(
                "Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            );
            return Ok(action_result(
                "Keyboard Prompt",
                "Accessibility (caret popovers) still needs enabling — opened Accessibility settings.",
                true,
            ));
        }
        return Ok(action_result(
            "Keyboard Prompt",
            if input_granted {
                "Keyboard monitoring is available."
            } else {
                "Keyboard permission prompt requested."
            },
            true,
        ));
    }

    #[cfg(not(target_os = "macos"))]
    {
        Ok(action_result(
            "Keyboard Prompt",
            "Keyboard permission prompt is macOS-only.",
            false,
        ))
    }
}

fn permission_status() -> PermissionStatus {
    #[cfg(target_os = "macos")]
    {
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
    {
        PermissionStatus {
            keyboard: false,
            accessibility: false,
            screen: false,
        }
    }
}

#[cfg(target_os = "macos")]
unsafe fn focused_text_caret_bounds_macos() -> Option<ScreenRect> {
    let system = OwnedCfRef::new(AXUIElementCreateSystemWide())?;
    let focused_attribute = cf_string("AXFocusedUIElement")?;
    let selected_range_attribute = cf_string("AXSelectedTextRange")?;
    let bounds_attribute = cf_string("AXBoundsForRange")?;

    let mut focused_object: CFTypeRef = std::ptr::null();
    if AXUIElementCopyAttributeValue(
        system.as_ptr(),
        focused_attribute.as_ptr(),
        &mut focused_object,
    ) != K_AX_ERROR_SUCCESS
        || focused_object.is_null()
    {
        return None;
    }
    let focused_element = OwnedCfRef::new(focused_object)?;

    let mut range_object: CFTypeRef = std::ptr::null();
    if AXUIElementCopyAttributeValue(
        focused_element.as_ptr(),
        selected_range_attribute.as_ptr(),
        &mut range_object,
    ) != K_AX_ERROR_SUCCESS
        || range_object.is_null()
    {
        return None;
    }
    let selected_range = OwnedCfRef::new(range_object)?;

    let mut bounds_object: CFTypeRef = std::ptr::null();
    if AXUIElementCopyParameterizedAttributeValue(
        focused_element.as_ptr(),
        bounds_attribute.as_ptr(),
        selected_range.as_ptr(),
        &mut bounds_object,
    ) != K_AX_ERROR_SUCCESS
        || bounds_object.is_null()
    {
        return None;
    }
    let bounds_value = OwnedCfRef::new(bounds_object)?;
    if AXValueGetType(bounds_value.as_ptr()) != K_AX_VALUE_CGRECT_TYPE {
        return None;
    }

    let mut rect = CGRect::default();
    if AXValueGetValue(
        bounds_value.as_ptr(),
        K_AX_VALUE_CGRECT_TYPE,
        &mut rect as *mut CGRect as *mut c_void,
    ) == 0
    {
        return None;
    }

    ScreenRect::new(
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height,
    )
}

#[cfg(target_os = "macos")]
fn cf_string(value: &str) -> Option<OwnedCfRef> {
    let value = CString::new(value).ok()?;
    let string = unsafe {
        CFStringCreateWithCString(std::ptr::null(), value.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    };
    OwnedCfRef::new(string)
}

#[cfg(target_os = "macos")]
struct OwnedCfRef(CFTypeRef);

#[cfg(target_os = "macos")]
impl OwnedCfRef {
    fn new(value: CFTypeRef) -> Option<Self> {
        (!value.is_null()).then_some(Self(value))
    }

    fn as_ptr(&self) -> CFTypeRef {
        self.0
    }
}

#[cfg(target_os = "macos")]
impl Drop for OwnedCfRef {
    fn drop(&mut self) {
        unsafe {
            CFRelease(self.0);
        }
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
type CFTypeRef = *const c_void;
#[cfg(target_os = "macos")]
type CFStringRef = CFTypeRef;
#[cfg(target_os = "macos")]
type AXUIElementRef = CFTypeRef;
#[cfg(target_os = "macos")]
type AXValueRef = CFTypeRef;

#[cfg(target_os = "macos")]
const K_AX_ERROR_SUCCESS: i32 = 0;
#[cfg(target_os = "macos")]
const K_AX_VALUE_CGRECT_TYPE: u32 = 3;
#[cfg(target_os = "macos")]
const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct CGSize {
    width: f64,
    height: f64,
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

#[cfg(target_os = "macos")]
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
    fn AXUIElementCopyParameterizedAttributeValue(
        element: AXUIElementRef,
        parameterized_attribute: CFStringRef,
        parameter: CFTypeRef,
        result: *mut CFTypeRef,
    ) -> i32;
    fn AXValueGetType(value: AXValueRef) -> u32;
    fn AXValueGetValue(value: AXValueRef, value_type: u32, value_ptr: *mut c_void) -> u8;
    fn CGPreflightListenEventAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
    fn CGPreflightScreenCaptureAccess() -> bool;
}

#[cfg(target_os = "macos")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFStringCreateWithCString(
        alloc: CFTypeRef,
        c_str: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFRelease(cf: CFTypeRef);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_settings_omits_defaults() {
        let defaults = default_settings();
        let stored = StoredSettings::from_effective(&defaults, &defaults);
        assert!(stored.is_empty());
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
        assert!(!state.anchor_bottom);
    }

    #[test]
    fn translation_preview_state_roundtrips_new_fields() {
        let json = r#"{
            "mode":"translated","sourceLanguage":"English","targetLanguage":"Korean",
            "originalText":"hi","translatedText":"안녕","errorText":null,
            "providerTitle":"Local Model","model":"m","costCredits":null,"permissionAction":null,
            "modelWarning":"Vision model used","requestSequence":7,
            "caretX":10.0,"caretY":20.0,"caretW":2.0,"caretH":18.0,"anchorBottom":true
        }"#;
        let state: TranslationPreviewState = serde_json::from_str(json).unwrap();
        assert_eq!(state.request_sequence, 7);
        assert_eq!(state.caret_x, Some(10.0));
        assert_eq!(state.model_warning.as_deref(), Some("Vision model used"));
        assert!(state.anchor_bottom);
        let encoded = serde_json::to_string(&state).unwrap();
        assert!(encoded.contains("\"modelWarning\":\"Vision model used\""));
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

        let stored = StoredSettings::from_effective(&settings, &defaults);
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

        let stored = StoredSettings::from_effective(&settings, &defaults);

        assert_eq!(stored.toast_position, Some(ToastPosition::Custom));
        assert_eq!(
            stored.toast_custom_position,
            Some(ToastCustomPosition { x: 128.0, y: 256.0 })
        );
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
        let stored = StoredSettings::from_effective(&settings, &defaults);

        let reloaded = apply_stored_settings(stored);

        assert_eq!(reloaded.provider, TranslationProvider::OpenRouter);
        assert_eq!(reloaded.open_router_text_model, "anthropic/claude-opus-4.8");
        assert_eq!(reloaded.local_model_id, defaults.local_model_id);
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
        let stored = StoredSettings::from_effective(&settings, &defaults);

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
    fn file_url_escapes_spaces_for_drag_payload() {
        // The app name itself has no space anymore, so use a spaced path to
        // keep exercising the percent-escaping this test exists for.
        let path = Path::new("/Applications/CC Trans.app");

        assert_eq!(
            file_url_for_path(path),
            "file:///Applications/CC%20Trans.app"
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

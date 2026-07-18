use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppSurface {
    Settings,
    LocalModelSetup,
    RequestLogs,
}

#[derive(Clone, Copy, Debug)]
struct SurfaceSpec {
    key: &'static str,
    label: &'static str,
    title: &'static str,
    width: f64,
    height: f64,
    min_width: f64,
    min_height: f64,
    resizable: bool,
    decorations: bool,
    transparent: bool,
    always_on_top: bool,
}

impl AppSurface {
    pub fn from_key(key: &str) -> Option<Self> {
        match key {
            "settings" | "main" => Some(Self::Settings),
            "local-model-setup" => Some(Self::LocalModelSetup),
            "request-logs" => Some(Self::RequestLogs),
            _ => None,
        }
    }

    pub fn key(self) -> &'static str {
        self.spec().key
    }

    fn spec(self) -> SurfaceSpec {
        match self {
            Self::Settings => SurfaceSpec {
                key: "settings",
                label: "main",
                title: "CCTrans Settings",
                width: 860.0,
                height: 640.0,
                min_width: 760.0,
                min_height: 520.0,
                resizable: true,
                decorations: true,
                transparent: false,
                always_on_top: false,
            },
            Self::LocalModelSetup => SurfaceSpec {
                key: "local-model-setup",
                label: "local-model-setup",
                title: "CCTrans Local Model Setup",
                width: 1120.0,
                height: 760.0,
                min_width: 820.0,
                min_height: 560.0,
                resizable: true,
                decorations: true,
                transparent: false,
                always_on_top: false,
            },
            Self::RequestLogs => SurfaceSpec {
                key: "request-logs",
                label: "request-logs",
                title: "CCTrans Request Logs",
                width: 760.0,
                height: 520.0,
                min_width: 700.0,
                min_height: 420.0,
                resizable: true,
                decorations: true,
                transparent: false,
                always_on_top: false,
            },
        }
    }
}

pub fn open_surface_window(app: &AppHandle, surface: AppSurface) -> Result<(), String> {
    let spec = surface.spec();
    if let Some(window) = app.get_webview_window(spec.label) {
        window.show().map_err(|error| error.to_string())?;
        window.set_focus().map_err(|error| error.to_string())?;
        return Ok(());
    }

    let url = if surface == AppSurface::Settings {
        "index.html".to_string()
    } else {
        format!("index.html?surface={}", spec.key)
    };
    let window = WebviewWindowBuilder::new(app, spec.label, WebviewUrl::App(url.into()))
        .title(spec.title)
        .inner_size(spec.width, spec.height)
        .min_inner_size(spec.min_width, spec.min_height)
        .resizable(spec.resizable)
        .decorations(spec.decorations)
        .transparent(spec.transparent)
        .always_on_top(spec.always_on_top)
        .focused(true)
        .build()
        .map_err(|error| error.to_string())?;

    window.center().map_err(|error| error.to_string())?;
    Ok(())
}

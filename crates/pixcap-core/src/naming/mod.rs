use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureContext {
    pub mode: String,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
    pub width: u32,
    pub height: u32,
    pub counter: u32,
}

/// Resolves a given pattern string using the provided context.
/// 
/// Supported variables:
/// - `{date}`: YYYY-MM-DD
/// - `{time}`: HH-MM-SS
/// - `{datetime}`: YYYY-MM-DD_HH-MM-SS
/// - `{timestamp}`: UNIX timestamp
/// - `{mode}`: Capture mode
/// - `{counter}`: Counter
/// - `{app}`: Application name (or 'App' if not present)
/// - `{title}`: Window title (or 'Window' if not present)
/// - `{width}`: Width
/// - `{height}`: Height
pub fn resolve_filename(pattern: &str, context: &CaptureContext) -> String {
    let now: DateTime<Utc> = Utc::now();
    let date = now.format("%Y-%m-%d").to_string();
    let time = now.format("%H-%M-%S").to_string();
    let datetime = now.format("%Y-%m-%d_%H-%M-%S").to_string();
    let timestamp = now.timestamp().to_string();

    let mut result = pattern.to_string();
    
    // Replace patterns
    result = result.replace("{date}", &date);
    result = result.replace("{time}", &time);
    result = result.replace("{datetime}", &datetime);
    result = result.replace("{timestamp}", &timestamp);
    result = result.replace("{mode}", &context.mode);
    result = result.replace("{counter}", &context.counter.to_string());
    result = result.replace("{app}", context.app_name.as_deref().unwrap_or("App"));
    result = result.replace("{title}", context.window_title.as_deref().unwrap_or("Window"));
    result = result.replace("{width}", &context.width.to_string());
    result = result.replace("{height}", &context.height.to_string());

    result
}

pub fn default_pattern() -> &'static str {
    "PixCap_{date}_{time}_{counter}"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_filename() {
        let ctx = CaptureContext {
            mode: "area".to_string(),
            app_name: Some("Safari".to_string()),
            window_title: Some("Github".to_string()),
            width: 1920,
            height: 1080,
            counter: 42,
        };
        
        let pattern = "Test_{app}_{mode}_{counter}_{width}x{height}";
        let resolved = resolve_filename(pattern, &ctx);
        assert_eq!(resolved, "Test_Safari_area_42_1920x1080");
    }
}

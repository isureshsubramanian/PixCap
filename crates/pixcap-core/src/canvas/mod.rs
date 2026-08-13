use serde::{Deserialize, Serialize};

/// Window frame style for the code or screenshot container
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WindowFrameStyle {
    /// macOS traffic lights (red, yellow, green)
    MacOs,
    /// Windows 11 Fluent style (minimize, maximize, close)
    Windows11,
    /// Minimalist monochrome dots
    Minimal,
    /// Borderless frame with rounded corners
    None,
}

/// Watermark position
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WatermarkPosition {
    BottomRight,
    BottomLeft,
    TopRight,
    TopLeft,
    Center,
}

/// Watermark configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatermarkConfig {
    pub text: String,
    pub position: WatermarkPosition,
    pub opacity: f32,
    pub font_size: f32,
}

/// Noise texture configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoiseTextureConfig {
    pub intensity: f32, // 0.0 to 1.0
    pub grain_size: f32,
    pub monochrome: bool,
}

/// Aspect ratio presets
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum AspectRatioPreset {
    Auto,
    Square,
    Ratio4x3,
    Ratio16x9,
    Twitter,
    LinkedIn,
    Instagram,
}

/// Padding configuration around the container
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaddingConfig {
    pub top: u32,
    pub right: u32,
    pub bottom: u32,
    pub left: u32,
}

impl Default for PaddingConfig {
    fn default() -> Self {
        Self {
            top: 32,
            right: 32,
            bottom: 32,
            left: 32,
        }
    }
}

impl PaddingConfig {
    pub fn uniform(padding: u32) -> Self {
        Self {
            top: padding,
            right: padding,
            bottom: padding,
            left: padding,
        }
    }

    pub fn auto_balance(content_width: u32, content_height: u32, target_ratio: Option<f32>) -> Self {
        // Magical auto-balance algorithm: calculates visual balance
        let ratio = target_ratio.unwrap_or(1.6); // Default ~16:10 or golden ratio
        let base_padding = (content_width as f32 * 0.08).clamp(24.0, 96.0) as u32;

        let calculated_width = content_width + (base_padding * 2);
        let desired_height = (calculated_width as f32 / ratio) as u32;

        let vertical_padding = if desired_height > content_height {
            ((desired_height - content_height) / 2).max(base_padding)
        } else {
            base_padding
        };

        Self {
            top: vertical_padding,
            right: base_padding,
            bottom: vertical_padding,
            left: base_padding,
        }
    }
}

/// Container Sizing strategy
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ContainerSizing {
    /// Expand automatically to fit content + padding
    AutoFit,
    /// Fixed total width in pixels (height auto-calculates)
    FixedWidth(u32),
    /// Constrain to a specific aspect ratio (e.g. 1.0 for Square, 1.777 for 16:9)
    AspectRatio(f32),
}

/// Drop shadow configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DropShadowConfig {
    pub enabled: bool,
    pub blur_radius: u32,
    pub y_offset: i32,
    pub opacity: f32,
    pub color_hex: String,
}

impl Default for DropShadowConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            blur_radius: 24,
            y_offset: 12,
            opacity: 0.35,
            color_hex: "#000000".to_string(),
        }
    }
}

/// Complete canvas layout specification
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanvasLayout {
    pub frame_style: WindowFrameStyle,
    pub padding: PaddingConfig,
    pub sizing: ContainerSizing,
    pub drop_shadow: DropShadowConfig,
    pub rounded_corners_radius: u32,
    pub show_line_numbers: bool,
    pub title: Option<String>,
    pub watermark: Option<WatermarkConfig>,
    pub noise_texture: Option<NoiseTextureConfig>,
    pub aspect_ratio_preset: Option<AspectRatioPreset>,
}

impl Default for CanvasLayout {
    fn default() -> Self {
        Self {
            frame_style: WindowFrameStyle::MacOs,
            padding: PaddingConfig::default(),
            sizing: ContainerSizing::AutoFit,
            drop_shadow: DropShadowConfig::default(),
            rounded_corners_radius: 12,
            show_line_numbers: true,
            title: None,
            watermark: None,
            noise_texture: None,
            aspect_ratio_preset: Some(AspectRatioPreset::Auto),
        }
    }
}

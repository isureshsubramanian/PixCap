//! Non-destructive edit documents.
//!
//! A capture is saved as a flat image plus a `.pixcap.json` sidecar holding the
//! canvas settings and the annotation list. Re-opening the sidecar restores a
//! fully editable session — nothing is baked in until export.
//!
//! The schema lives here, in the shared core, so the macOS and Windows shells
//! read and write byte-identical documents.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Schema version written by this build.
pub const DOCUMENT_VERSION: u32 = 1;

/// Extension appended to the image's base name.
pub const SIDECAR_EXTENSION: &str = "pixcap.json";

#[derive(Debug, Error)]
pub enum DocumentError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unsupported document version {0}")]
    UnsupportedVersion(u32),
}

fn default_stroke_width() -> f64 {
    3.0
}

fn default_font_size() -> f64 {
    24.0
}

fn default_blur_intensity() -> f64 {
    20.0
}

fn default_true() -> bool {
    true
}

fn default_color() -> String {
    "#FF3366".to_string()
}

fn default_arrow_head() -> String {
    "filled".to_string()
}

fn default_spotlight_dim() -> f64 {
    0.65
}

fn default_number() -> u32 {
    1
}

/// One annotation, in image-space points with a top-left origin.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnnotationRecord {
    #[serde(default)]
    pub id: String,
    pub tool: String,
    #[serde(default)]
    pub start: [f64; 2],
    #[serde(default)]
    pub end: [f64; 2],
    #[serde(default)]
    pub points: Vec<[f64; 2]>,
    #[serde(default = "default_color")]
    pub color_hex: String,
    #[serde(default = "default_stroke_width")]
    pub stroke_width: f64,
    #[serde(default)]
    pub filled: bool,
    #[serde(default)]
    pub text: String,
    #[serde(default = "default_font_size")]
    pub font_size: f64,
    #[serde(default = "default_number")]
    pub number: u32,
    #[serde(default)]
    pub blur_style: String,
    #[serde(default = "default_blur_intensity")]
    pub blur_intensity: f64,
    #[serde(default = "default_true")]
    pub curved_arrow: bool,
    #[serde(default = "default_arrow_head")]
    pub arrow_head: String,
    #[serde(default)]
    pub dashed: bool,
    #[serde(default = "default_spotlight_dim")]
    pub spotlight_dim: f64,
}

/// Canvas settings, mirroring the beautifier configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CanvasRecord {
    /// `preset`, `wallpaper`, or `image`.
    #[serde(default = "CanvasRecord::default_kind")]
    pub background_kind: String,
    /// Preset id when `background_kind` is `preset`, otherwise a file path.
    #[serde(default)]
    pub background_value: String,
    #[serde(default = "CanvasRecord::default_padding")]
    pub padding: f64,
    #[serde(default = "CanvasRecord::default_corner_radius")]
    pub corner_radius: f64,
    #[serde(default = "CanvasRecord::default_shadow_blur")]
    pub shadow_blur: f64,
    #[serde(default = "CanvasRecord::default_shadow_opacity")]
    pub shadow_opacity: f64,
    #[serde(default)]
    pub background_blur: f64,
    #[serde(default = "CanvasRecord::default_frame_style")]
    pub frame_style: String,
    #[serde(default = "CanvasRecord::default_aspect_ratio")]
    pub aspect_ratio: String,
    #[serde(default)]
    pub frame_title: Option<String>,
    /// Non-destructive crop as `[x, y, width, height]` in source-image points.
    #[serde(default)]
    pub crop: Option<[f64; 4]>,
    /// Canvas texture: None, Grain, Paper, Linen, Dots, or Grid.
    #[serde(default = "CanvasRecord::default_texture")]
    pub texture: String,
    /// Film grain strength, 0.0 to 1.0.
    #[serde(default)]
    pub noise_intensity: f64,
    /// Perspective tilt in degrees about each axis.
    #[serde(default)]
    pub tilt_x: f64,
    #[serde(default)]
    pub tilt_y: f64,
}

impl CanvasRecord {
    fn default_kind() -> String {
        "preset".to_string()
    }
    fn default_padding() -> f64 {
        32.0
    }
    fn default_corner_radius() -> f64 {
        16.0
    }
    fn default_shadow_blur() -> f64 {
        24.0
    }
    fn default_shadow_opacity() -> f64 {
        0.35
    }
    fn default_frame_style() -> String {
        "macOS".to_string()
    }
    fn default_aspect_ratio() -> String {
        "Auto".to_string()
    }
    fn default_texture() -> String {
        "None".to_string()
    }
}

impl Default for CanvasRecord {
    fn default() -> Self {
        Self {
            background_kind: Self::default_kind(),
            background_value: "azure-mesh".to_string(),
            padding: Self::default_padding(),
            corner_radius: Self::default_corner_radius(),
            shadow_blur: Self::default_shadow_blur(),
            shadow_opacity: Self::default_shadow_opacity(),
            background_blur: 0.0,
            frame_style: Self::default_frame_style(),
            aspect_ratio: Self::default_aspect_ratio(),
            frame_title: None,
            crop: None,
            texture: Self::default_texture(),
            noise_intensity: 0.0,
            tilt_x: 0.0,
            tilt_y: 0.0,
        }
    }
}

/// A re-editable capture.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnnotationDocument {
    #[serde(default)]
    pub version: u32,
    /// Path to the untouched source image.
    #[serde(default)]
    pub source_image: String,
    #[serde(default)]
    pub canvas: CanvasRecord,
    #[serde(default)]
    pub items: Vec<AnnotationRecord>,
}

impl Default for AnnotationDocument {
    fn default() -> Self {
        Self {
            version: DOCUMENT_VERSION,
            source_image: String::new(),
            canvas: CanvasRecord::default(),
            items: Vec::new(),
        }
    }
}

impl AnnotationDocument {
    /// Validates and normalises a document parsed from JSON.
    pub fn from_json(json: &str) -> Result<Self, DocumentError> {
        let mut document: AnnotationDocument = serde_json::from_str(json)?;

        if document.version == 0 {
            document.version = DOCUMENT_VERSION;
        }
        if document.version > DOCUMENT_VERSION {
            return Err(DocumentError::UnsupportedVersion(document.version));
        }

        Ok(document)
    }

    pub fn to_json(&self) -> Result<String, DocumentError> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// Writes the document to `path`, creating parent directories as needed.
    pub fn write(&self, path: &str) -> Result<(), DocumentError> {
        if let Some(parent) = Path::new(path).parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, self.to_json()?)?;
        Ok(())
    }

    pub fn read(path: &str) -> Result<Self, DocumentError> {
        Self::from_json(&fs::read_to_string(path)?)
    }
}

/// Sidecar path for an image: `shot.png` becomes `shot.pixcap.json`.
pub fn sidecar_path(image_path: &str) -> String {
    let path = PathBuf::from(image_path);
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "capture".to_string());

    path.with_file_name(format!("{stem}.{SIDECAR_EXTENSION}"))
        .to_string_lossy()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> AnnotationDocument {
        AnnotationDocument {
            version: DOCUMENT_VERSION,
            source_image: "/tmp/shot.png".to_string(),
            canvas: CanvasRecord {
                background_value: "amethyst".to_string(),
                padding: 48.0,
                frame_title: Some("Terminal".to_string()),
                ..CanvasRecord::default()
            },
            items: vec![AnnotationRecord {
                id: "abc".to_string(),
                tool: "arrow".to_string(),
                start: [10.0, 20.0],
                end: [110.0, 90.0],
                points: vec![],
                color_hex: "#00E5FF".to_string(),
                stroke_width: 5.0,
                filled: false,
                text: String::new(),
                font_size: 24.0,
                number: 1,
                blur_style: "gaussian".to_string(),
                blur_intensity: 20.0,
                curved_arrow: true,
                arrow_head: "filled".to_string(),
                dashed: false,
                spotlight_dim: 0.65,
            }],
        }
    }

    #[test]
    fn round_trips_through_json() {
        let document = sample();
        let json = document.to_json().unwrap();
        let parsed = AnnotationDocument::from_json(&json).unwrap();

        assert_eq!(parsed.items.len(), 1);
        assert_eq!(parsed.items[0].tool, "arrow");
        assert_eq!(parsed.canvas.background_value, "amethyst");
        assert_eq!(parsed.canvas.frame_title.as_deref(), Some("Terminal"));
    }

    #[test]
    fn canvas_extensions_default_for_older_documents() {
        // A sidecar written before textures existed must still load.
        let json = r#"{"canvas":{"background_value":"amethyst","padding":40.0}}"#;
        let parsed = AnnotationDocument::from_json(json).unwrap();

        assert_eq!(parsed.canvas.texture, "None");
        assert_eq!(parsed.canvas.noise_intensity, 0.0);
        assert_eq!(parsed.canvas.tilt_x, 0.0);
        assert_eq!(parsed.canvas.background_value, "amethyst");
    }

    #[test]
    fn missing_fields_fall_back_to_defaults() {
        let json = r#"{"items":[{"tool":"rectangle"}]}"#;
        let parsed = AnnotationDocument::from_json(json).unwrap();

        assert_eq!(parsed.version, DOCUMENT_VERSION);
        assert_eq!(parsed.items[0].stroke_width, 3.0);
        assert_eq!(parsed.items[0].color_hex, "#FF3366");
        assert_eq!(parsed.canvas.frame_style, "macOS");
    }

    #[test]
    fn future_versions_are_rejected() {
        let json = format!(r#"{{"version":{},"items":[]}}"#, DOCUMENT_VERSION + 1);
        assert!(matches!(
            AnnotationDocument::from_json(&json),
            Err(DocumentError::UnsupportedVersion(_))
        ));
    }

    #[test]
    fn writes_and_reads_from_disk() {
        let dir = std::env::temp_dir().join("pixcap-document-test");
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("shot.pixcap.json");
        let path_str = path.to_string_lossy().to_string();

        sample().write(&path_str).unwrap();
        let loaded = AnnotationDocument::read(&path_str).unwrap();
        assert_eq!(loaded.source_image, "/tmp/shot.png");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn derives_sidecar_paths() {
        // Asserted through `Path` rather than against a literal string: the
        // function builds the result with `std::path`, so on Windows a POSIX
        // input yields "/a/b\\shot.pixcap.json". Those mixed separators are
        // valid there, and real Windows inputs are native paths anyway, so the
        // contract worth testing is "same directory, correct file name", not
        // the byte sequence.
        let nested = sidecar_path("/a/b/shot.png");
        let nested_path = Path::new(&nested);
        assert_eq!(
            nested_path.file_name().unwrap().to_string_lossy(),
            "shot.pixcap.json"
        );
        assert_eq!(nested_path.parent(), Path::new("/a/b/shot.png").parent());

        // A bare file name has no directory to preserve.
        assert_eq!(sidecar_path("shot.jpg"), "shot.pixcap.json");

        // The extension is replaced, not appended.
        assert!(!sidecar_path("/tmp/a.png").contains(".png"));
    }
}

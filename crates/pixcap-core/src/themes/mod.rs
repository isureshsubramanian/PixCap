use serde::{Deserialize, Serialize};

/// Background fill type for canvas wrapper
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum BackgroundFill {
    /// Linear or Multi-point mesh gradient defined by stops
    Gradient {
        angle_deg: f32,
        stops: Vec<(f32, String)>, // (position 0.0..1.0, hex_color)
    },
    /// Solid background color
    Solid(String),
    /// True alpha transparency (no background, only window + drop shadow)
    Transparent,
    /// Glassmorphic translucent dark background
    Glassmorphism {
        blur_radius: u32,
        bg_hex: String,
        opacity: f32,
    },
    /// Custom image path or base64 data
    CustomImage {
        image_data: String, // base64 encoded or path
        blur_level: u32,
    },
}

impl Default for BackgroundFill {
    fn default() -> Self {
        // Default modern "Sunset Mesh" gradient
        BackgroundFill::Gradient {
            angle_deg: 135.0,
            stops: vec![
                (0.0, "#4158D0".to_string()),
                (0.5, "#C850C0".to_string()),
                (1.0, "#FFCC70".to_string()),
            ],
        }
    }
}

/// A named background preset shared by every platform shell.
///
/// The macOS and Windows front-ends both read this list so the preset
/// vocabulary (ids, display names, colours) can never drift between them.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackgroundPreset {
    pub id: String,
    pub name: String,
    pub fill: BackgroundFill,
}

impl BackgroundPreset {
    fn gradient(id: &str, name: &str, angle_deg: f32, stops: &[(f32, &str)]) -> Self {
        Self {
            id: id.to_string(),
            name: name.to_string(),
            fill: BackgroundFill::Gradient {
                angle_deg,
                stops: stops
                    .iter()
                    .map(|(pos, hex)| (*pos, hex.to_string()))
                    .collect(),
            },
        }
    }
}

/// Predefined high-end gradient themes
pub struct ThemePresets;

impl ThemePresets {
    /// The complete ordered preset catalogue exposed to the platform shells.
    pub fn all() -> Vec<BackgroundPreset> {
        vec![
            BackgroundPreset::gradient(
                "azure-mesh",
                "Azure Mesh",
                135.0,
                &[(0.0, "#0093E9"), (1.0, "#80D0C7")],
            ),
            BackgroundPreset::gradient(
                "oceanic",
                "Oceanic",
                160.0,
                &[(0.0, "#2E3192"), (0.5, "#1BFFFF"), (1.0, "#2E3192")],
            ),
            BackgroundPreset::gradient(
                "amethyst",
                "Amethyst",
                135.0,
                &[(0.0, "#4158D0"), (0.5, "#C850C0"), (1.0, "#FFCC70")],
            ),
            BackgroundPreset::gradient(
                "sunset-glow",
                "Sunset Glow",
                120.0,
                &[(0.0, "#FF9A8B"), (0.5, "#FF6A88"), (1.0, "#FF99AC")],
            ),
            BackgroundPreset::gradient(
                "neon-pulse",
                "Neon Pulse",
                45.0,
                &[(0.0, "#FC466B"), (1.0, "#3F5EFB")],
            ),
            BackgroundPreset::gradient(
                "midnight",
                "Midnight",
                90.0,
                &[(0.0, "#282a36"), (1.0, "#44475a")],
            ),
            BackgroundPreset::gradient(
                "linen",
                "Linen",
                135.0,
                &[(0.0, "#F5F7FA"), (1.0, "#C3CFE2")],
            ),
            BackgroundPreset {
                id: "graphite".to_string(),
                name: "Graphite".to_string(),
                fill: BackgroundFill::Solid("#1e1e2e".to_string()),
            },
            BackgroundPreset {
                id: "glass-dark".to_string(),
                name: "Glass Dark".to_string(),
                fill: Self::glass_dark(),
            },
            BackgroundPreset {
                id: "transparent".to_string(),
                name: "Transparent".to_string(),
                fill: BackgroundFill::Transparent,
            },
        ]
    }

    /// Looks a preset up by its stable id.
    pub fn by_id(id: &str) -> Option<BackgroundPreset> {
        Self::all().into_iter().find(|p| p.id == id)
    }

    pub fn breeze() -> BackgroundFill {
        BackgroundFill::Gradient {
            angle_deg: 45.0,
            stops: vec![
                (0.0, "#0093E9".to_string()),
                (1.0, "#80D0C7".to_string()),
            ],
        }
    }

    pub fn candy() -> BackgroundFill {
        BackgroundFill::Gradient {
            angle_deg: 135.0,
            stops: vec![
                (0.0, "#FF9A8B".to_string()),
                (0.5, "#FF6A88".to_string()),
                (1.0, "#FF99AC".to_string()),
            ],
        }
    }

    pub fn dracula_dark() -> BackgroundFill {
        BackgroundFill::Gradient {
            angle_deg: 90.0,
            stops: vec![
                (0.0, "#282a36".to_string()),
                (1.0, "#44475a".to_string()),
            ],
        }
    }

    pub fn glass_dark() -> BackgroundFill {
        BackgroundFill::Glassmorphism {
            blur_radius: 20,
            bg_hex: "#1e1e2e".to_string(),
            opacity: 0.85,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_have_unique_ids() {
        let presets = ThemePresets::all();
        assert!(presets.len() >= 8);
        let mut ids: Vec<&str> = presets.iter().map(|p| p.id.as_str()).collect();
        ids.sort_unstable();
        let count = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), count, "preset ids must be unique");
    }

    #[test]
    fn presets_are_addressable_by_id() {
        let preset = ThemePresets::by_id("amethyst").expect("amethyst preset exists");
        assert_eq!(preset.name, "Amethyst");
        assert!(ThemePresets::by_id("does-not-exist").is_none());
    }
}

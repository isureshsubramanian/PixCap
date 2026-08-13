//! Text rasterisation for the Rust renderer.
//!
//! Fonts come from the operating system rather than being bundled: Windows
//! always ships Segoe UI, so output is consistent across machines without
//! adding a font binary (and its licence obligations) to the DLL.
//!
//! This renderer is used by the Windows shell and the CLI. macOS keeps its
//! Core Graphics renderer, so the two are not expected to be glyph-identical.

use fontdue::{Font, FontSettings};
use std::sync::OnceLock;
use tiny_skia::{Color, Pixmap, PremultipliedColorU8, Transform};

/// Loads a UI font once per process. Font discovery walks the filesystem, so
/// it is far too slow to repeat per draw call.
fn ui_font() -> Option<&'static Font> {
    static FONT: OnceLock<Option<Font>> = OnceLock::new();

    FONT.get_or_init(|| {
        let mut database = fontdb::Database::new();
        database.load_system_fonts();

        // Preferred UI faces per platform, then anything sans-serif.
        let families = [
            fontdb::Family::Name("Segoe UI"),
            fontdb::Family::Name("Helvetica Neue"),
            fontdb::Family::Name("Arial"),
            fontdb::Family::Name("DejaVu Sans"),
            fontdb::Family::SansSerif,
        ];

        for family in families {
            let query = fontdb::Query {
                families: &[family],
                weight: fontdb::Weight::NORMAL,
                stretch: fontdb::Stretch::Normal,
                style: fontdb::Style::Normal,
            };

            let Some(id) = database.query(&query) else {
                continue;
            };

            let font = database.with_face_data(id, |data, index| {
                Font::from_bytes(
                    data,
                    FontSettings {
                        collection_index: index,
                        ..FontSettings::default()
                    },
                )
                .ok()
            });

            if let Some(Some(font)) = font {
                return Some(font);
            }
        }

        None
    })
    .as_ref()
}

/// Whether a usable font was found. Callers can warn rather than silently
/// dropping every label.
pub fn is_available() -> bool {
    ui_font().is_some()
}

/// Width and height a string will occupy at `size` points.
pub fn measure(text: &str, size: f32) -> (f32, f32) {
    let Some(font) = ui_font() else {
        return (0.0, 0.0);
    };

    let mut width = 0.0;
    for character in text.chars() {
        width += font.metrics(character, size).advance_width;
    }

    let line_metrics = font.horizontal_line_metrics(size);
    let height = line_metrics.map(|m| m.ascent - m.descent).unwrap_or(size);

    (width, height)
}

/// Draws `text` with its top-left corner at (`x`, `y`), in canvas points.
///
/// `transform` maps canvas points to pixels, matching the rest of the renderer.
pub fn draw(
    pixmap: &mut Pixmap,
    text: &str,
    x: f32,
    y: f32,
    size: f32,
    color: Color,
    transform: Transform,
) {
    let Some(font) = ui_font() else { return };
    if text.is_empty() {
        return;
    }

    // Glyphs are rasterised at the device size so they stay sharp when the
    // canvas is rendered at 2x.
    let scale = transform.sx.max(0.01);
    let device_size = size * scale;

    let ascent = font
        .horizontal_line_metrics(device_size)
        .map(|m| m.ascent)
        .unwrap_or(device_size);

    // Baseline position in device pixels.
    let origin_x = x * transform.sx + transform.tx;
    let origin_y = y * transform.sy + transform.ty;

    let mut pen_x = origin_x;
    let baseline = origin_y + ascent;

    let (red, green, blue) = (
        (color.red() * 255.0) as u8,
        (color.green() * 255.0) as u8,
        (color.blue() * 255.0) as u8,
    );
    let alpha = color.alpha();

    for character in text.chars() {
        let (metrics, bitmap) = font.rasterize(character, device_size);

        if metrics.width > 0 && metrics.height > 0 {
            let glyph_x = pen_x + metrics.xmin as f32;
            let glyph_y = baseline - metrics.height as f32 - metrics.ymin as f32;

            blend_glyph(
                pixmap,
                &bitmap,
                metrics.width,
                metrics.height,
                glyph_x.round() as i32,
                glyph_y.round() as i32,
                red,
                green,
                blue,
                alpha,
            );
        }

        pen_x += metrics.advance_width;
    }
}

/// Alpha-blends one rasterised glyph into the pixmap.
#[allow(clippy::too_many_arguments)]
fn blend_glyph(
    pixmap: &mut Pixmap,
    coverage: &[u8],
    width: usize,
    height: usize,
    origin_x: i32,
    origin_y: i32,
    red: u8,
    green: u8,
    blue: u8,
    alpha: f32,
) {
    let pixmap_width = pixmap.width() as i32;
    let pixmap_height = pixmap.height() as i32;
    let pixels = pixmap.pixels_mut();

    for row in 0..height {
        let target_y = origin_y + row as i32;
        if target_y < 0 || target_y >= pixmap_height {
            continue;
        }

        for column in 0..width {
            let target_x = origin_x + column as i32;
            if target_x < 0 || target_x >= pixmap_width {
                continue;
            }

            let coverage_value = coverage[row * width + column] as f32 / 255.0;
            let source_alpha = coverage_value * alpha;
            if source_alpha <= 0.0 {
                continue;
            }

            let index = (target_y * pixmap_width + target_x) as usize;
            let existing = pixels[index];

            // Source-over, on premultiplied pixels.
            let inverse = 1.0 - source_alpha;
            let out_r = (red as f32 * source_alpha) + existing.red() as f32 * inverse;
            let out_g = (green as f32 * source_alpha) + existing.green() as f32 * inverse;
            let out_b = (blue as f32 * source_alpha) + existing.blue() as f32 * inverse;
            let out_a = (source_alpha * 255.0) + existing.alpha() as f32 * inverse;

            if let Some(blended) = PremultipliedColorU8::from_rgba(
                out_r.round().clamp(0.0, 255.0) as u8,
                out_g.round().clamp(0.0, 255.0) as u8,
                out_b.round().clamp(0.0, 255.0) as u8,
                out_a.round().clamp(0.0, 255.0) as u8,
            ) {
                pixels[index] = blended;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_system_font() {
        // Every platform this builds on ships at least one sans-serif face.
        assert!(is_available(), "no system UI font was found");
    }

    #[test]
    fn measures_text() {
        let (width, height) = measure("PixCap", 24.0);
        assert!(width > 0.0, "width should be positive");
        assert!(height > 0.0, "height should be positive");

        let (wider, _) = measure("PixCap PixCap", 24.0);
        assert!(wider > width, "longer strings must measure wider");
    }

    #[test]
    fn draws_visible_pixels() {
        let mut pixmap = Pixmap::new(200, 60).unwrap();
        pixmap.fill(Color::from_rgba8(0, 0, 0, 255));

        draw(
            &mut pixmap,
            "PixCap",
            10.0,
            10.0,
            28.0,
            Color::from_rgba8(255, 255, 255, 255),
            Transform::identity(),
        );

        let lit = pixmap
            .pixels()
            .iter()
            .filter(|pixel| pixel.red() > 40)
            .count();

        assert!(lit > 50, "expected glyph coverage, got {lit} lit pixels");
    }

    #[test]
    fn empty_text_is_a_no_op() {
        let mut pixmap = Pixmap::new(50, 20).unwrap();
        pixmap.fill(Color::from_rgba8(0, 0, 0, 255));
        let before = pixmap.data().to_vec();

        draw(&mut pixmap, "", 0.0, 0.0, 20.0, Color::WHITE, Transform::identity());

        assert_eq!(before, pixmap.data(), "empty text must draw nothing");
    }
}

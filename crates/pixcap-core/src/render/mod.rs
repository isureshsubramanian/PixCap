//! Raster beautification renderer.
//!
//! Used by the Windows shell and the CLI. Before it existed the renderer was
//! Swift-only, so Windows could capture but never beautify, and the CLI could
//! only emit SVG for code snippets.
//!
//! macOS deliberately does *not* call this code — it renders through Core
//! Graphics instead, so each app draws with the framework native to its
//! platform. The two are kept in step by the shared `AnnotationDocument`
//! schema rather than by shared drawing code.
//!
//! Rendering is done with `tiny-skia` — a pure-Rust rasterizer — so the crate
//! keeps cross-compiling without a C toolchain for graphics.
//!
//! The input is an [`AnnotationDocument`], the same structure the `.pixcap.json`
//! sidecar stores, so "render this document" and "reopen this document for
//! editing" take exactly the same data.

pub mod text;

use crate::document::{AnnotationDocument, AnnotationRecord, CanvasRecord};
use crate::themes::{BackgroundFill, ThemePresets};
use image::{DynamicImage, RgbaImage};
use thiserror::Error;
use tiny_skia::{
    BlendMode, Color, FillRule, GradientStop, LinearGradient, Paint, PathBuilder, Pixmap,
    PixmapPaint, Point, Rect, SpreadMode, Stroke, Transform,
};

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("the source image is empty")]
    EmptySource,
    #[error("canvas dimensions {width}x{height} are not renderable")]
    BadCanvas { width: u32, height: u32 },
    #[error("image error: {0}")]
    Image(#[from] image::ImageError),
}

/// Geometry of a laid-out canvas, in canvas points with a top-left origin.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Layout {
    pub canvas_width: f32,
    pub canvas_height: f32,
    /// Window chrome plus image.
    pub frame_x: f32,
    pub frame_y: f32,
    pub frame_width: f32,
    pub frame_height: f32,
    /// The screenshot itself.
    pub image_x: f32,
    pub image_y: f32,
    pub image_width: f32,
    pub image_height: f32,
    /// Crop offset, subtracted from annotation coordinates.
    pub crop_x: f32,
    pub crop_y: f32,
}

/// Height of the window chrome for a frame style.
fn header_height(style: &str) -> f32 {
    match style {
        "None" => 0.0,
        _ => 34.0,
    }
}

/// Aspect ratio for a preset name, or None to leave the canvas as-is.
fn aspect_ratio(preset: &str) -> Option<f32> {
    match preset {
        "1:1" => Some(1.0),
        "4:3" => Some(4.0 / 3.0),
        "3:2" => Some(3.0 / 2.0),
        "16:9" => Some(16.0 / 9.0),
        "4:5" => Some(4.0 / 5.0),
        _ => None,
    }
}

/// Computes the canvas layout for a source image and canvas settings.
///
/// Mirrors the Swift implementation exactly: padding on all sides, the frame
/// centred, and the canvas only ever *growing* to satisfy an aspect ratio.
pub fn layout(source_width: f32, source_height: f32, canvas: &CanvasRecord) -> Layout {
    // Crop, clamped to the source bounds.
    let (crop_x, crop_y, visible_width, visible_height) = match canvas.crop {
        Some([x, y, w, h]) if w >= 1.0 && h >= 1.0 => {
            let x = (x as f32).max(0.0);
            let y = (y as f32).max(0.0);
            let w = (w as f32).min(source_width - x).max(1.0);
            let h = (h as f32).min(source_height - y).max(1.0);
            (x, y, w, h)
        }
        _ => (0.0, 0.0, source_width, source_height),
    };

    let header = header_height(&canvas.frame_style);
    let padding = canvas.padding as f32;

    let frame_width = visible_width;
    let frame_height = visible_height + header;

    let mut canvas_width = frame_width + padding * 2.0;
    let mut canvas_height = frame_height + padding * 2.0;

    if let Some(ratio) = aspect_ratio(&canvas.aspect_ratio) {
        let current = canvas_width / canvas_height;
        if current < ratio {
            canvas_width = canvas_height * ratio;
        } else if current > ratio {
            canvas_height = canvas_width / ratio;
        }
    }

    let frame_x = (canvas_width - frame_width) / 2.0;
    let frame_y = (canvas_height - frame_height) / 2.0;

    Layout {
        canvas_width,
        canvas_height,
        frame_x,
        frame_y,
        frame_width,
        frame_height,
        image_x: frame_x,
        image_y: frame_y + header,
        image_width: visible_width,
        image_height: visible_height,
        crop_x,
        crop_y,
    }
}

/// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA`.
pub fn parse_color(hex: &str) -> Option<Color> {
    let value = hex.trim().trim_start_matches('#');

    let expanded = if value.len() == 3 {
        value.chars().flat_map(|c| [c, c]).collect::<String>()
    } else {
        value.to_string()
    };

    if expanded.len() != 6 && expanded.len() != 8 {
        return None;
    }

    let number = u32::from_str_radix(&expanded, 16).ok()?;
    let has_alpha = expanded.len() == 8;

    let (r, g, b, a) = if has_alpha {
        (
            (number >> 24) & 0xFF,
            (number >> 16) & 0xFF,
            (number >> 8) & 0xFF,
            number & 0xFF,
        )
    } else {
        ((number >> 16) & 0xFF, (number >> 8) & 0xFF, number & 0xFF, 255)
    };

    Color::from_rgba8(r as u8, g as u8, b as u8, a as u8).into()
}

/// Opens an image with limits sized for real screen captures.
///
/// The `image` crate applies a conservative decode budget by default, which a
/// large display, a long scrolling capture, or a re-beautified export can
/// legitimately exceed. The ceiling here is generous but still bounded, so a
/// malformed file cannot exhaust memory.
pub fn open_image(path: &str) -> Result<DynamicImage, RenderError> {
    let mut reader = image::ImageReader::open(path)
        .map_err(|error| RenderError::Image(image::ImageError::IoError(error)))?
        .with_guessed_format()
        .map_err(|error| RenderError::Image(image::ImageError::IoError(error)))?;

    let mut limits = image::Limits::default();
    // 32768 covers an 8K display captured at 2x, and then some.
    limits.max_image_width = Some(32_768);
    limits.max_image_height = Some(32_768);
    limits.max_alloc = Some(4 * 1024 * 1024 * 1024);
    reader.limits(limits);

    Ok(reader.decode()?)
}

/// Renders a document into PNG bytes.
///
/// - `source` is the untouched capture.
/// - `scale` is output pixels per canvas point.
pub fn render_document(
    source: &DynamicImage,
    document: &AnnotationDocument,
    scale: f32,
) -> Result<Vec<u8>, RenderError> {
    let pixmap = render_to_pixmap(source, document, scale)?;
    pixmap.encode_png().map_err(|error| {
        RenderError::Image(image::ImageError::IoError(std::io::Error::other(
            error.to_string(),
        )))
    })
}

/// Renders a document into a pixmap, for callers that want the raw pixels.
pub fn render_to_pixmap(
    source: &DynamicImage,
    document: &AnnotationDocument,
    scale: f32,
) -> Result<Pixmap, RenderError> {
    let source_width = source.width() as f32;
    let source_height = source.height() as f32;

    if source_width < 1.0 || source_height < 1.0 {
        return Err(RenderError::EmptySource);
    }

    let canvas = &document.canvas;
    let layout = layout(source_width, source_height, canvas);

    let pixel_width = (layout.canvas_width * scale).round() as u32;
    let pixel_height = (layout.canvas_height * scale).round() as u32;

    let mut pixmap = Pixmap::new(pixel_width, pixel_height).ok_or(RenderError::BadCanvas {
        width: pixel_width,
        height: pixel_height,
    })?;

    // Every draw call works in canvas points; this maps them to pixels.
    let unit = Transform::from_scale(scale, scale);

    draw_background(&mut pixmap, &layout, canvas, unit);
    draw_texture(&mut pixmap, &layout, canvas, scale, unit);

    // Blur and pixelate rewrite the screenshot itself, before it is composited.
    let mut screenshot = source.to_rgba8();
    apply_pixel_redaction(&mut screenshot, &document.items);

    draw_frame(&mut pixmap, &layout, canvas, &screenshot, scale, unit);
    draw_annotations(&mut pixmap, &layout, &document.items, unit);

    Ok(pixmap)
}

// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

fn background_fill(canvas: &CanvasRecord) -> Option<BackgroundFill> {
    match canvas.background_kind.as_str() {
        "preset" => ThemePresets::by_id(&canvas.background_value).map(|preset| preset.fill),
        // Wallpaper and custom images are supplied by the shell, which knows
        // where they live; an unresolved one falls back to the default preset.
        _ => ThemePresets::by_id("azure-mesh").map(|preset| preset.fill),
    }
}

fn draw_background(pixmap: &mut Pixmap, layout: &Layout, canvas: &CanvasRecord, unit: Transform) {
    let Some(fill) = background_fill(canvas) else {
        return;
    };

    let rect = match Rect::from_xywh(0.0, 0.0, layout.canvas_width, layout.canvas_height) {
        Some(rect) => rect,
        None => return,
    };

    let mut paint = Paint::default();
    paint.anti_alias = true;

    match fill {
        BackgroundFill::Transparent => return,

        BackgroundFill::Solid(hex) => {
            let Some(color) = parse_color(&hex) else { return };
            paint.set_color(color);
        }

        BackgroundFill::Glassmorphism { bg_hex, opacity, .. } => {
            let Some(mut color) = parse_color(&bg_hex) else { return };
            color.set_alpha(opacity.clamp(0.0, 1.0));
            paint.set_color(color);
        }

        BackgroundFill::Gradient { angle_deg, stops } => {
            let gradient_stops: Vec<GradientStop> = stops
                .iter()
                .filter_map(|(position, hex)| {
                    parse_color(hex).map(|color| GradientStop::new(*position, color))
                })
                .collect();

            if gradient_stops.len() < 2 {
                return;
            }

            // Match the Swift renderer: the gradient runs through the canvas
            // centre along `angle_deg`, spanning the larger dimension.
            let radians = angle_deg.to_radians();
            let half = layout.canvas_width.max(layout.canvas_height) / 2.0;
            let center_x = layout.canvas_width / 2.0;
            let center_y = layout.canvas_height / 2.0;

            let start = Point::from_xy(
                center_x - radians.cos() * half,
                center_y - radians.sin() * half,
            );
            let end = Point::from_xy(
                center_x + radians.cos() * half,
                center_y + radians.sin() * half,
            );

            let Some(shader) = LinearGradient::new(
                start,
                end,
                gradient_stops,
                SpreadMode::Pad,
                Transform::identity(),
            ) else {
                return;
            };
            paint.shader = shader;
        }

        BackgroundFill::CustomImage { .. } => return,
    }

    pixmap.fill_rect(rect, &paint, unit, None);
}

// ---------------------------------------------------------------------------
// Texture
// ---------------------------------------------------------------------------

/// Deterministic noise, so a canvas renders identically every time.
struct Noise(u64);

impl Noise {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407))
    }

    fn next(&mut self, bound: u64) -> u64 {
        if bound == 0 {
            return 0;
        }
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % bound
    }
}

fn draw_texture(
    pixmap: &mut Pixmap,
    layout: &Layout,
    canvas: &CanvasRecord,
    scale: f32,
    unit: Transform,
) {
    let width = layout.canvas_width;
    let height = layout.canvas_height;

    let mut paint = Paint::default();
    paint.anti_alias = true;

    match canvas.texture.as_str() {
        "Dots" => {
            paint.set_color(Color::from_rgba8(255, 255, 255, 20));
            let spacing = 14.0;
            let mut y = spacing / 2.0;
            while y < height {
                let mut x = spacing / 2.0;
                while x < width {
                    if let Some(rect) = Rect::from_xywh(x, y, 1.6, 1.6) {
                        pixmap.fill_rect(rect, &paint, unit, None);
                    }
                    x += spacing;
                }
                y += spacing;
            }
        }

        "Grid" => {
            paint.set_color(Color::from_rgba8(255, 255, 255, 18));
            let spacing = 24.0;
            let mut x = 0.0;
            while x < width {
                if let Some(rect) = Rect::from_xywh(x, 0.0, 0.7, height) {
                    pixmap.fill_rect(rect, &paint, unit, None);
                }
                x += spacing;
            }
            let mut y = 0.0;
            while y < height {
                if let Some(rect) = Rect::from_xywh(0.0, y, width, 0.7) {
                    pixmap.fill_rect(rect, &paint, unit, None);
                }
                y += spacing;
            }
        }

        "Linen" => {
            paint.set_color(Color::from_rgba8(255, 255, 255, 12));
            let mut offset = 0.0;
            let mut builder = PathBuilder::new();
            while offset < width + height {
                builder.move_to(offset, 0.0);
                builder.line_to(offset - height, height);
                builder.move_to(offset - height, 0.0);
                builder.line_to(offset, height);
                offset += 4.0;
            }
            if let Some(path) = builder.finish() {
                let mut stroke = Stroke::default();
                stroke.width = 0.6;
                pixmap.stroke_path(&path, &paint, &stroke, unit, None);
            }
        }

        "Paper" => {
            let mut noise = Noise::new(7);
            let fibres = ((width * height) / 900.0) as u32;
            let mut stroke = Stroke::default();
            stroke.width = 0.7;

            for _ in 0..fibres {
                let x = noise.next(width as u64) as f32;
                let y = noise.next(height as u64) as f32;
                let length = noise.next(6) as f32 + 2.0;
                let bright = noise.next(2) == 0;

                paint.set_color(if bright {
                    Color::from_rgba8(255, 255, 255, 13)
                } else {
                    Color::from_rgba8(0, 0, 0, 13)
                });

                let mut builder = PathBuilder::new();
                builder.move_to(x, y);
                builder.line_to(x + length, y + noise.next(3) as f32 - 1.0);
                if let Some(path) = builder.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, unit, None);
                }
            }
        }

        _ => {}
    }

    // Film grain, independent of the pattern.
    let intensity = if canvas.texture == "Grain" {
        (canvas.noise_intensity as f32).max(0.35)
    } else {
        canvas.noise_intensity as f32
    };

    if intensity > 0.0 {
        draw_grain(pixmap, width, height, intensity, scale);
    }
}

/// Film grain, written into the pixmap buffer a block at a time.
///
/// One `fill_rect` per block is what the rest of the renderer would do, but a
/// 4K canvas has nearly two million blocks and each call carries a paint, a
/// transform, and an anti-aliased edge it does not need — enough to cost
/// seconds on its own. The blend here is plain source-over on premultiplied
/// bytes, which is all a flat translucent square needs.
fn draw_grain(pixmap: &mut Pixmap, width: f32, height: f32, intensity: f32, scale: f32) {
    let pixel_width = pixmap.width() as i32;
    let pixel_height = pixmap.height() as i32;

    // Blocks are 2 canvas points, except where that would land inside a single
    // pixel: a preview rendered at a third of export scale would otherwise draw
    // several blocks over the same pixel, each blending on top of the last, and
    // come out grainier than the export it is previewing.
    let step = 2.0_f32.max(1.0 / scale.max(0.01));

    let mut noise = Noise::new(42);
    let mut y = 0.0;

    while y < height {
        let top = (y * scale).round().clamp(0.0, pixel_height as f32) as i32;
        let bottom = ((y + step) * scale).round().clamp(0.0, pixel_height as f32) as i32;
        let mut x = 0.0;

        while x < width {
            let value = noise.next(100) as f32 / 100.0;
            let alpha = ((value - 0.5) * 0.12 * intensity * 255.0).abs() as u32;

            if alpha > 0 && bottom > top {
                let left = (x * scale).round().clamp(0.0, pixel_width as f32) as i32;
                let right = ((x + step) * scale).round().clamp(0.0, pixel_width as f32) as i32;

                // Premultiplied source: white is (a, a, a, a), black (0, 0, 0, a).
                let source = if value > 0.5 { alpha } else { 0 };
                let keep = 255 - alpha;
                let data = pixmap.data_mut();

                for row in top..bottom {
                    let start = ((row * pixel_width + left) * 4) as usize;
                    let end = ((row * pixel_width + right) * 4) as usize;
                    for pixel in data[start..end].chunks_exact_mut(4) {
                        for channel in 0..3 {
                            pixel[channel] = (((pixel[channel] as u32 * keep + 127) / 255) as u8)
                                .saturating_add(source as u8);
                        }
                        pixel[3] = (((pixel[3] as u32 * keep + 127) / 255) as u8)
                            .saturating_add(alpha as u8);
                    }
                }
            }

            x += step;
        }

        y += step;
    }
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

fn rounded_rect(x: f32, y: f32, width: f32, height: f32, radius: f32) -> Option<tiny_skia::Path> {
    let radius = radius.min(width / 2.0).min(height / 2.0).max(0.0);
    let mut builder = PathBuilder::new();

    if radius <= 0.0 {
        builder.push_rect(Rect::from_xywh(x, y, width, height)?);
        return builder.finish();
    }

    let kappa = radius * 0.5522847;

    builder.move_to(x + radius, y);
    builder.line_to(x + width - radius, y);
    builder.cubic_to(x + width - radius + kappa, y, x + width, y + radius - kappa, x + width, y + radius);
    builder.line_to(x + width, y + height - radius);
    builder.cubic_to(
        x + width,
        y + height - radius + kappa,
        x + width - radius + kappa,
        y + height,
        x + width - radius,
        y + height,
    );
    builder.line_to(x + radius, y + height);
    builder.cubic_to(x + radius - kappa, y + height, x, y + height - radius + kappa, x, y + height - radius);
    builder.line_to(x, y + radius);
    builder.cubic_to(x, y + radius - kappa, x + radius - kappa, y, x + radius, y);
    builder.close();

    builder.finish()
}

/// A pixel rectangle, `x1`/`y1` exclusive.
#[derive(Debug, Clone, Copy)]
struct PixelRect {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
}

/// Box blur, run three times to approximate a gaussian. tiny-skia has no blur.
///
/// Two things keep this off the critical path. Each pass walks a running total
/// rather than re-summing the kernel, so the cost per pixel is constant instead
/// of proportional to the radius; and only `region` is visited, because outside
/// it the pixmap is transparent and averaging zeroes produces zeroes.
///
/// Both matter: the straightforward version — kernel re-summed per pixel, over
/// the whole canvas, with a copy of the pixmap per pass — spent fourteen
/// seconds on a 4K capture, which was most of the time the editor took to
/// answer a slider.
fn box_blur(pixmap: &mut Pixmap, radius: u32, region: PixelRect) {
    if radius == 0 {
        return;
    }

    let width = pixmap.width() as i32;
    let height = pixmap.height() as i32;
    let radius = radius as i32;

    let x0 = region.x0.max(0);
    let y0 = region.y0.max(0);
    let x1 = region.x1.min(width);
    let y1 = region.y1.min(height);

    if x1 <= x0 || y1 <= y0 {
        return;
    }

    // Running totals for one row or column, with a leading zero so a window is
    // a single subtraction. Allocated once and reused by every pass.
    let span = ((x1 - x0).max(y1 - y0) + 1) as usize;
    let mut totals = vec![[0u32; 4]; span];

    for _ in 0..3 {
        for y in y0..y1 {
            {
                let data = pixmap.data();
                let mut running = [0u32; 4];
                totals[0] = running;
                for x in x0..x1 {
                    let index = ((y * width + x) * 4) as usize;
                    for channel in 0..4 {
                        running[channel] += data[index + channel] as u32;
                    }
                    totals[(x - x0 + 1) as usize] = running;
                }
            }

            let data = pixmap.data_mut();
            for x in x0..x1 {
                // Samples off the pixmap do not exist, but samples on it and
                // outside the region are transparent: they add nothing to the
                // total while still counting towards the average, which is what
                // the per-pixel version did.
                let count = ((x + radius).min(width - 1) - (x - radius).max(0) + 1) as u32;
                let low = ((x - radius).max(x0) - x0) as usize;
                let high = ((x + radius).min(x1 - 1) - x0) as usize;
                let index = ((y * width + x) * 4) as usize;

                for channel in 0..4 {
                    let sum = totals[high + 1][channel] - totals[low][channel];
                    data[index + channel] = (sum / count) as u8;
                }
            }
        }

        for x in x0..x1 {
            {
                let data = pixmap.data();
                let mut running = [0u32; 4];
                totals[0] = running;
                for y in y0..y1 {
                    let index = ((y * width + x) * 4) as usize;
                    for channel in 0..4 {
                        running[channel] += data[index + channel] as u32;
                    }
                    totals[(y - y0 + 1) as usize] = running;
                }
            }

            let data = pixmap.data_mut();
            for y in y0..y1 {
                let count = ((y + radius).min(height - 1) - (y - radius).max(0) + 1) as u32;
                let low = ((y - radius).max(y0) - y0) as usize;
                let high = ((y + radius).min(y1 - 1) - y0) as usize;
                let index = ((y * width + x) * 4) as usize;

                for channel in 0..4 {
                    let sum = totals[high + 1][channel] - totals[low][channel];
                    data[index + channel] = (sum / count) as u8;
                }
            }
        }
    }
}

fn draw_frame(
    pixmap: &mut Pixmap,
    layout: &Layout,
    canvas: &CanvasRecord,
    screenshot: &RgbaImage,
    scale: f32,
    unit: Transform,
) {
    let radius = canvas.corner_radius as f32;

    // Drop shadow: the frame silhouette, blurred in its own pixmap, composited
    // underneath. tiny-skia has no shadow primitive.
    let blur = canvas.shadow_blur as f32;
    let opacity = canvas.shadow_opacity as f32;

    if blur > 0.0 && opacity > 0.0 {
        if let Some(mut shadow) = Pixmap::new(pixmap.width(), pixmap.height()) {
            let drop = (blur / 2.0).max(2.0);

            if let Some(path) = rounded_rect(
                layout.frame_x,
                layout.frame_y + drop,
                layout.frame_width,
                layout.frame_height,
                radius,
            ) {
                let mut paint = Paint::default();
                paint.anti_alias = true;
                paint.set_color(Color::from_rgba8(0, 0, 0, (opacity * 255.0) as u8));
                shadow.fill_path(&path, &paint, FillRule::Winding, unit, None);
            }

            // The silhouette in pixels, grown by how far three passes can carry
            // it. Everything beyond stays transparent, so there is nothing to
            // blur there.
            let kernel = ((blur * scale) / 3.0).round() as u32;
            let reach = kernel as i32 * 3 + 2;
            let region = PixelRect {
                x0: (layout.frame_x * scale).floor() as i32 - reach,
                y0: ((layout.frame_y + drop) * scale).floor() as i32 - reach,
                x1: ((layout.frame_x + layout.frame_width) * scale).ceil() as i32 + reach,
                y1: ((layout.frame_y + drop + layout.frame_height) * scale).ceil() as i32 + reach,
            };

            box_blur(&mut shadow, kernel, region);
            pixmap.draw_pixmap(0, 0, shadow.as_ref(), &PixmapPaint::default(), Transform::identity(), None);
        }
    }

    // Header chrome.
    if canvas.frame_style != "None" {
        let header = header_height(&canvas.frame_style);
        let is_light = canvas.frame_style == "Windows";

        if let Some(path) = rounded_rect(
            layout.frame_x,
            layout.frame_y,
            layout.frame_width,
            layout.frame_height,
            radius,
        ) {
            let mut paint = Paint::default();
            paint.anti_alias = true;
            paint.set_color(if is_light {
                Color::from_rgba8(0xF3, 0xF3, 0xF3, 255)
            } else {
                Color::from_rgba8(0x2B, 0x2B, 0x33, 255)
            });
            pixmap.fill_path(&path, &paint, FillRule::Winding, unit, None);
        }

        // Traffic lights / dots.
        let center_y = layout.frame_y + header / 2.0;
        let colors: [(u8, u8, u8); 3] = match canvas.frame_style.as_str() {
            "macOS" => [(0xFF, 0x5F, 0x56), (0xFF, 0xBD, 0x2E), (0x27, 0xC9, 0x3F)],
            _ => [(200, 200, 200), (200, 200, 200), (200, 200, 200)],
        };

        for (index, (r, g, b)) in colors.iter().enumerate() {
            let cx = layout.frame_x + 20.0 + index as f32 * 20.0;
            let mut builder = PathBuilder::new();
            builder.push_circle(cx, center_y, 6.0);
            if let Some(path) = builder.finish() {
                let mut paint = Paint::default();
                paint.anti_alias = true;
                paint.set_color(Color::from_rgba8(*r, *g, *b, 255));
                pixmap.fill_path(&path, &paint, FillRule::Winding, unit, None);
            }
        }

        // Window title, centred in the chrome.
        if let Some(title) = canvas.frame_title.as_deref().filter(|t| !t.is_empty()) {
            let size = 12.0;
            let (width, height) = text::measure(title, size);
            let color = if is_light {
                Color::from_rgba8(0x3A, 0x3A, 0x3A, 255)
            } else {
                Color::from_rgba8(255, 255, 255, 190)
            };

            text::draw(
                pixmap,
                title,
                layout.frame_x + (layout.frame_width - width) / 2.0,
                center_y - height / 2.0,
                size,
                color,
                unit,
            );
        }
    }

    // The screenshot, cropped and scaled into the image rect.
    let crop_x = layout.crop_x as u32;
    let crop_y = layout.crop_y as u32;
    let crop_w = (layout.image_width as u32).min(screenshot.width().saturating_sub(crop_x));
    let crop_h = (layout.image_height as u32).min(screenshot.height().saturating_sub(crop_y));

    if crop_w == 0 || crop_h == 0 {
        return;
    }

    let cropped = image::imageops::crop_imm(screenshot, crop_x, crop_y, crop_w, crop_h).to_image();

    if let Some(mut source) = Pixmap::new(crop_w, crop_h) {
        // tiny-skia expects premultiplied RGBA.
        for (index, pixel) in cropped.pixels().enumerate() {
            let [r, g, b, a] = pixel.0;
            let premultiplied = tiny_skia::ColorU8::from_rgba(r, g, b, a).premultiply();
            source.pixels_mut()[index] = premultiplied;
        }

        let target_scale_x = (layout.image_width * scale) / crop_w as f32;
        let target_scale_y = (layout.image_height * scale) / crop_h as f32;

        let transform = Transform::from_translate(layout.image_x * scale, layout.image_y * scale)
            .pre_scale(target_scale_x, target_scale_y);

        let mut paint = PixmapPaint::default();
        paint.quality = tiny_skia::FilterQuality::Bicubic;

        pixmap.draw_pixmap(0, 0, source.as_ref(), &paint, transform, None);
    }
}

// ---------------------------------------------------------------------------
// Annotations
// ---------------------------------------------------------------------------

/// Bakes blur and pixelate regions into the screenshot itself.
fn apply_pixel_redaction(screenshot: &mut RgbaImage, items: &[AnnotationRecord]) {
    for item in items.iter().filter(|item| item.tool == "blur") {
        let (x, y, w, h) = rect_of(item);
        let x = x.max(0.0) as u32;
        let y = y.max(0.0) as u32;
        let w = (w as u32).min(screenshot.width().saturating_sub(x));
        let h = (h as u32).min(screenshot.height().saturating_sub(y));

        if w < 2 || h < 2 {
            continue;
        }

        if item.blur_style == "pixelate" {
            let block = (item.blur_intensity as u32 / 2).clamp(2, 64);
            for by in (0..h).step_by(block as usize) {
                for bx in (0..w).step_by(block as usize) {
                    // Average the block, then flood it.
                    let (mut r, mut g, mut b, mut a, mut count) = (0u32, 0u32, 0u32, 0u32, 0u32);
                    for oy in 0..block.min(h - by) {
                        for ox in 0..block.min(w - bx) {
                            let pixel = screenshot.get_pixel(x + bx + ox, y + by + oy).0;
                            r += pixel[0] as u32;
                            g += pixel[1] as u32;
                            b += pixel[2] as u32;
                            a += pixel[3] as u32;
                            count += 1;
                        }
                    }
                    if count == 0 {
                        continue;
                    }
                    let average = image::Rgba([
                        (r / count) as u8,
                        (g / count) as u8,
                        (b / count) as u8,
                        (a / count) as u8,
                    ]);
                    for oy in 0..block.min(h - by) {
                        for ox in 0..block.min(w - bx) {
                            screenshot.put_pixel(x + bx + ox, y + by + oy, average);
                        }
                    }
                }
            }
        } else {
            // Gaussian: box blur the region in place.
            let region = image::imageops::crop_imm(screenshot, x, y, w, h).to_image();
            let radius = (item.blur_intensity as f32 / 4.0).clamp(1.0, 30.0);
            let blurred = image::imageops::blur(&region, radius);
            image::imageops::replace(screenshot, &blurred, x as i64, y as i64);
        }
    }
}

fn rect_of(item: &AnnotationRecord) -> (f32, f32, f32, f32) {
    let x0 = item.start[0] as f32;
    let y0 = item.start[1] as f32;
    let x1 = item.end[0] as f32;
    let y1 = item.end[1] as f32;

    (
        x0.min(x1),
        y0.min(y1),
        (x1 - x0).abs(),
        (y1 - y0).abs(),
    )
}

fn draw_annotations(pixmap: &mut Pixmap, layout: &Layout, items: &[AnnotationRecord], unit: Transform) {
    // Annotation space is the uncropped image, so the crop offset is removed.
    let offset = Transform::from_translate(
        layout.image_x - layout.crop_x,
        layout.image_y - layout.crop_y,
    )
    .post_concat(unit);

    for item in items {
        if item.tool == "blur" || item.tool == "select" || item.tool == "crop" {
            continue;
        }

        let Some(color) = parse_color(&item.color_hex) else {
            continue;
        };

        let mut paint = Paint::default();
        paint.anti_alias = true;
        paint.set_color(color);

        let mut stroke = Stroke::default();
        stroke.width = item.stroke_width as f32;
        stroke.line_cap = tiny_skia::LineCap::Round;
        stroke.line_join = tiny_skia::LineJoin::Round;

        if item.dashed {
            let dash = (item.stroke_width as f32 * 3.0).max(6.0);
            stroke.dash = tiny_skia::StrokeDash::new(vec![dash, dash * 0.8], 0.0);
        }

        let (x, y, w, h) = rect_of(item);

        match item.tool.as_str() {
            "rectangle" => {
                if let Some(rect) = Rect::from_xywh(x, y, w, h) {
                    let mut builder = PathBuilder::new();
                    builder.push_rect(rect);
                    if let Some(path) = builder.finish() {
                        if item.filled {
                            let mut fill = paint.clone();
                            let mut translucent = color;
                            translucent.set_alpha(0.35);
                            fill.set_color(translucent);
                            pixmap.fill_path(&path, &fill, FillRule::Winding, offset, None);
                        }
                        pixmap.stroke_path(&path, &paint, &stroke, offset, None);
                    }
                }
            }

            "ellipse" => {
                let mut builder = PathBuilder::new();
                if let Some(rect) = Rect::from_xywh(x, y, w, h) {
                    builder.push_oval(rect);
                }
                if let Some(path) = builder.finish() {
                    if item.filled {
                        let mut fill = paint.clone();
                        let mut translucent = color;
                        translucent.set_alpha(0.35);
                        fill.set_color(translucent);
                        pixmap.fill_path(&path, &fill, FillRule::Winding, offset, None);
                    }
                    pixmap.stroke_path(&path, &paint, &stroke, offset, None);
                }
            }

            "line" => {
                let mut builder = PathBuilder::new();
                builder.move_to(item.start[0] as f32, item.start[1] as f32);
                builder.line_to(item.end[0] as f32, item.end[1] as f32);
                if let Some(path) = builder.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, offset, None);
                }
            }

            "arrow" => draw_arrow(pixmap, item, &paint, &stroke, offset),

            "freehand" => {
                if item.points.len() < 2 {
                    continue;
                }
                let mut builder = PathBuilder::new();
                builder.move_to(item.points[0][0] as f32, item.points[0][1] as f32);
                for point in item.points.iter().skip(1) {
                    builder.line_to(point[0] as f32, point[1] as f32);
                }
                if let Some(path) = builder.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, offset, None);
                }
            }

            "highlight" => {
                if let Some(rect) = Rect::from_xywh(x, y, w, h) {
                    let mut fill = paint.clone();
                    let mut translucent = color;
                    translucent.set_alpha(0.35);
                    fill.set_color(translucent);
                    fill.blend_mode = BlendMode::Multiply;
                    pixmap.fill_rect(rect, &fill, offset, None);
                }
            }

            "redaction" => {
                if let Some(rect) = Rect::from_xywh(x, y, w, h) {
                    let mut fill = paint.clone();
                    let mut opaque = color;
                    opaque.set_alpha(1.0);
                    fill.set_color(opaque);
                    pixmap.fill_rect(rect, &fill, offset, None);
                }
            }

            "spotlight" => {
                // Dim everything outside the rectangle: an even-odd fill of the
                // whole image with the spotlight punched out.
                let mut builder = PathBuilder::new();
                if let Some(bounds) = Rect::from_xywh(
                    layout.crop_x,
                    layout.crop_y,
                    layout.image_width,
                    layout.image_height,
                ) {
                    builder.push_rect(bounds);
                }
                if let Some(rect) = Rect::from_xywh(x, y, w, h) {
                    builder.push_rect(rect);
                }
                if let Some(path) = builder.finish() {
                    let mut fill = Paint::default();
                    fill.anti_alias = true;
                    fill.set_color(Color::from_rgba8(
                        0,
                        0,
                        0,
                        (item.spotlight_dim as f32 * 255.0) as u8,
                    ));
                    pixmap.fill_path(&path, &fill, FillRule::EvenOdd, offset, None);
                }
            }

            "text" => {
                if item.text.is_empty() {
                    continue;
                }
                text::draw(
                    pixmap,
                    &item.text,
                    item.start[0] as f32,
                    item.start[1] as f32,
                    item.font_size as f32,
                    color,
                    offset,
                );
            }

            "counter" => {
                let radius = (item.stroke_width as f32 * 6.0).max(14.0);
                let cx = item.start[0] as f32;
                let cy = item.start[1] as f32;

                let mut builder = PathBuilder::new();
                builder.push_circle(cx, cy, radius);
                if let Some(path) = builder.finish() {
                    pixmap.fill_path(&path, &paint, FillRule::Winding, offset, None);
                }

                let label = item.number.to_string();
                let (width, height) = text::measure(&label, radius);
                text::draw(
                    pixmap,
                    &label,
                    cx - width / 2.0,
                    cy - height / 2.0,
                    radius,
                    Color::WHITE,
                    offset,
                );
            }

            _ => {}
        }
    }
}

fn draw_arrow(
    pixmap: &mut Pixmap,
    item: &AnnotationRecord,
    paint: &Paint,
    stroke: &Stroke,
    transform: Transform,
) {
    let start = (item.start[0] as f32, item.start[1] as f32);
    let end = (item.end[0] as f32, item.end[1] as f32);

    let dx = end.0 - start.0;
    let dy = end.1 - start.1;
    let length = (dx * dx + dy * dy).sqrt();

    if length < 1.0 {
        return;
    }

    let mut tangent = (dx, dy);
    let mut builder = PathBuilder::new();
    builder.move_to(start.0, start.1);

    if item.curved_arrow {
        // Bow the shaft perpendicular to the straight line, then take the
        // curve's end tangent so the head stays aligned with the stroke.
        let normal = (-dy / length, dx / length);
        let bow = (length * 0.18).min(60.0);
        let control = (
            (start.0 + end.0) / 2.0 + normal.0 * bow,
            (start.1 + end.1) / 2.0 + normal.1 * bow,
        );
        builder.quad_to(control.0, control.1, end.0, end.1);
        tangent = (end.0 - control.0, end.1 - control.1);
    } else {
        builder.line_to(end.0, end.1);
    }

    if let Some(path) = builder.finish() {
        pixmap.stroke_path(&path, paint, stroke, transform, None);
    }

    if item.arrow_head == "none" {
        return;
    }

    let angle = tangent.1.atan2(tangent.0);
    let head = (item.stroke_width as f32 * 4.0).max(12.0);
    let spread = std::f32::consts::PI / 7.0;

    let left = (
        end.0 - head * (angle - spread).cos(),
        end.1 - head * (angle - spread).sin(),
    );
    let right = (
        end.0 - head * (angle + spread).cos(),
        end.1 - head * (angle + spread).sin(),
    );

    let mut builder = PathBuilder::new();

    if item.arrow_head == "open" {
        builder.move_to(left.0, left.1);
        builder.line_to(end.0, end.1);
        builder.line_to(right.0, right.1);
        if let Some(path) = builder.finish() {
            let mut plain = stroke.clone();
            plain.dash = None;
            pixmap.stroke_path(&path, paint, &plain, transform, None);
        }
    } else {
        builder.move_to(end.0, end.1);
        builder.line_to(left.0, left.1);
        builder.line_to(right.0, right.1);
        builder.close();
        if let Some(path) = builder.finish() {
            pixmap.fill_path(&path, paint, FillRule::Winding, transform, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::AnnotationDocument;
    use image::Rgba;

    fn source(width: u32, height: u32) -> DynamicImage {
        let mut image = RgbaImage::new(width, height);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = Rgba([(x % 255) as u8, (y % 255) as u8, 128, 255]);
        }
        DynamicImage::ImageRgba8(image)
    }

    fn document() -> AnnotationDocument {
        let mut document = AnnotationDocument::default();
        document.canvas.background_value = "amethyst".to_string();
        document.canvas.padding = 40.0;
        document.canvas.frame_style = "macOS".to_string();
        document
    }

    #[test]
    fn layout_matches_the_swift_renderer() {
        let mut canvas = CanvasRecord::default();
        canvas.padding = 40.0;
        canvas.frame_style = "macOS".to_string();

        let result = layout(400.0, 300.0, &canvas);

        // 400 + 80 padding, 300 + 34 header + 80 padding.
        assert_eq!(result.canvas_width, 480.0);
        assert_eq!(result.canvas_height, 414.0);
        assert_eq!(result.image_y, result.frame_y + 34.0);
    }

    #[test]
    fn aspect_ratio_only_grows_the_canvas() {
        let mut canvas = CanvasRecord::default();
        canvas.padding = 40.0;
        canvas.frame_style = "None".to_string();
        canvas.aspect_ratio = "16:9".to_string();

        let result = layout(400.0, 300.0, &canvas);
        let ratio = result.canvas_width / result.canvas_height;

        assert!((ratio - 16.0 / 9.0).abs() < 0.001, "got {ratio}");
        assert!(result.canvas_width >= 480.0);
        assert!(result.canvas_height >= 380.0);
    }

    #[test]
    fn crop_drives_the_canvas_size() {
        let mut canvas = CanvasRecord::default();
        canvas.padding = 20.0;
        canvas.frame_style = "None".to_string();
        canvas.crop = Some([50.0, 50.0, 200.0, 100.0]);

        let result = layout(400.0, 300.0, &canvas);

        assert_eq!(result.canvas_width, 240.0);
        assert_eq!(result.canvas_height, 140.0);
        assert_eq!(result.crop_x, 50.0);
    }

    #[test]
    fn out_of_bounds_crop_clamps() {
        let mut canvas = CanvasRecord::default();
        canvas.padding = 20.0;
        canvas.frame_style = "None".to_string();
        canvas.crop = Some([0.0, 0.0, 9999.0, 9999.0]);

        let result = layout(400.0, 300.0, &canvas);
        assert_eq!(result.canvas_width, 440.0);
        assert_eq!(result.canvas_height, 340.0);
    }

    #[test]
    fn parses_colours() {
        assert!(parse_color("#FF0000").is_some());
        assert!(parse_color("FF0000").is_some());
        assert!(parse_color("#F00").is_some());
        assert!(parse_color("#FF000080").is_some());
        assert!(parse_color("#ZZZ").is_none());
        assert!(parse_color("").is_none());
    }

    #[test]
    fn renders_a_document_to_png() {
        let png = render_document(&source(400, 300), &document(), 2.0).expect("renders");

        assert!(png.starts_with(&[0x89, b'P', b'N', b'G']), "not a PNG");

        let decoded = image::load_from_memory(&png).expect("decodes");
        assert_eq!(decoded.width(), 960);  // 480 canvas points at 2x
        assert_eq!(decoded.height(), 828); // 414 canvas points at 2x
    }

    #[test]
    fn transparent_background_keeps_alpha() {
        let mut document = document();
        document.canvas.background_value = "transparent".to_string();
        document.canvas.frame_style = "None".to_string();
        document.canvas.shadow_blur = 0.0;

        let pixmap = render_to_pixmap(&source(200, 150), &document, 1.0).expect("renders");
        let corner = pixmap.pixel(2, 2).expect("pixel exists");

        assert_eq!(corner.alpha(), 0, "corner should be fully transparent");
    }

    #[test]
    fn redaction_covers_only_its_rectangle() {
        let mut document = document();
        document.canvas.frame_style = "None".to_string();
        document.canvas.padding = 0.0;
        document.canvas.shadow_blur = 0.0;
        document.items = vec![AnnotationRecord {
            id: "r".to_string(),
            tool: "redaction".to_string(),
            start: [50.0, 50.0],
            end: [150.0, 150.0],
            points: vec![],
            color_hex: "#FF0000".to_string(),
            stroke_width: 1.0,
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
        }];

        let pixmap = render_to_pixmap(&source(200, 200), &document, 1.0).expect("renders");

        let inside = pixmap.pixel(100, 100).expect("inside");
        assert_eq!((inside.red(), inside.green(), inside.blue()), (255, 0, 0));

        let outside = pixmap.pixel(10, 10).expect("outside");
        assert_ne!((outside.red(), outside.green(), outside.blue()), (255, 0, 0));
    }

    #[test]
    fn pixelate_averages_blocks() {
        let mut document = document();
        document.canvas.frame_style = "None".to_string();
        document.canvas.padding = 0.0;
        document.canvas.shadow_blur = 0.0;
        document.items = vec![AnnotationRecord {
            id: "b".to_string(),
            tool: "blur".to_string(),
            start: [0.0, 0.0],
            end: [100.0, 100.0],
            points: vec![],
            color_hex: "#000000".to_string(),
            stroke_width: 1.0,
            filled: false,
            text: String::new(),
            font_size: 24.0,
            number: 1,
            blur_style: "pixelate".to_string(),
            blur_intensity: 40.0,
            curved_arrow: true,
            arrow_head: "filled".to_string(),
            dashed: false,
            spotlight_dim: 0.65,
        }];

        let pixmap = render_to_pixmap(&source(200, 200), &document, 1.0).expect("renders");

        // Neighbouring pixels inside one block must now be identical.
        let a = pixmap.pixel(4, 4).expect("a");
        let b = pixmap.pixel(5, 4).expect("b");
        assert_eq!((a.red(), a.green(), a.blue()), (b.red(), b.green(), b.blue()));
    }

    #[test]
    fn draws_text_and_counter_annotations() {
        let mut document = document();
        document.canvas.frame_style = "None".to_string();
        document.canvas.padding = 0.0;
        document.canvas.shadow_blur = 0.0;
        document.canvas.background_value = "graphite".to_string();

        let base = AnnotationRecord {
            id: "t".to_string(),
            tool: "text".to_string(),
            start: [20.0, 20.0],
            end: [0.0, 0.0],
            points: vec![],
            color_hex: "#FFFFFF".to_string(),
            stroke_width: 3.0,
            filled: false,
            text: "PixCap".to_string(),
            font_size: 28.0,
            number: 7,
            blur_style: "gaussian".to_string(),
            blur_intensity: 20.0,
            curved_arrow: true,
            arrow_head: "filled".to_string(),
            dashed: false,
            spotlight_dim: 0.65,
        };

        let without = render_to_pixmap(&source(220, 160), &document, 1.0).unwrap();

        document.items = vec![base.clone()];
        let with_text = render_to_pixmap(&source(220, 160), &document, 1.0).unwrap();
        assert_ne!(without.data(), with_text.data(), "text should change the canvas");

        let mut counter = base;
        counter.tool = "counter".to_string();
        counter.color_hex = "#FFB300".to_string();
        counter.start = [100.0, 80.0];
        document.items = vec![counter];

        let with_counter = render_to_pixmap(&source(220, 160), &document, 1.0).unwrap();

        // The bubble centre should carry the counter colour.
        let centre = with_counter.pixel(100, 80).expect("centre pixel");
        assert!(centre.red() > 150, "counter bubble should be drawn");
    }

    #[test]
    fn grain_is_deterministic() {
        let mut document = document();
        document.canvas.texture = "Grain".to_string();
        document.canvas.noise_intensity = 0.6;

        let first = render_document(&source(120, 90), &document, 1.0).unwrap();
        let second = render_document(&source(120, 90), &document, 1.0).unwrap();

        assert_eq!(first, second, "grain must not change between renders");
    }
}

//! Times `render_to_pixmap` for a real capture, so a rendering change can be
//! judged by the clock instead of by eye.
//!
//! The renderer's cost is dominated by two optional effects, so each is timed
//! on its own as well as together:
//!
//! ```text
//! cargo run --release --example render-bench -- <image.png|WxH> [scale] [out.png]
//! ```
//!
//! Passing an output path also writes the last case, so a change can be looked
//! at as well as timed.

use image::{DynamicImage, RgbaImage};
use pixcap_core::document::AnnotationDocument;
use pixcap_core::render::{open_image, render_to_pixmap};
use std::time::Instant;

/// A stand-in for a capture of a given size, for sizes there is no file for —
/// a full 4K display capture costs five times what a window capture does, and
/// that is the case the editor is judged on.
fn synthetic(width: u32, height: u32) -> DynamicImage {
    let mut image = RgbaImage::new(width, height);
    for (x, y, pixel) in image.enumerate_pixels_mut() {
        *pixel = image::Rgba([(x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8, 255]);
    }
    DynamicImage::ImageRgba8(image)
}

fn document(texture: &str, grain: f64, shadow: f64) -> AnnotationDocument {
    let mut document = AnnotationDocument::default();
    document.canvas.background_kind = "preset".to_string();
    document.canvas.background_value = "amethyst".to_string();
    document.canvas.padding = 48.0;
    document.canvas.corner_radius = 14.0;
    document.canvas.frame_style = "macOS".to_string();
    document.canvas.frame_title = Some("PixCap".to_string());
    document.canvas.texture = texture.to_string();
    document.canvas.noise_intensity = grain;
    document.canvas.shadow_blur = shadow;
    document.canvas.shadow_opacity = 0.35;
    document
}

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: render-bench <image.png|WxH> [scale]");
    let scale: f32 = args.next().map_or(2.0, |value| value.parse().expect("scale"));

    let source = match path.split_once(['x', 'X']) {
        Some((width, height)) if width.parse::<u32>().is_ok() && height.parse::<u32>().is_ok() => {
            synthetic(width.parse().unwrap(), height.parse().unwrap())
        }
        _ => open_image(&path).expect("source image opens"),
    };
    println!(
        "source {}x{} at {scale}x\n",
        source.width(),
        source.height()
    );

    let cases = [
        ("plain (no grain, no shadow)", document("None", 0.0, 0.0)),
        ("shadow only", document("None", 0.0, 30.0)),
        ("grain only", document("Grain", 0.5, 0.0)),
        ("grain + shadow (the editor's default)", document("Grain", 0.5, 30.0)),
    ];

    for (name, document) in &cases {
        // Two runs: the first pays for any lazily-built state, the second is
        // what a slider drag actually costs.
        let mut best = f64::MAX;
        for _ in 0..2 {
            let started = Instant::now();
            let pixmap = render_to_pixmap(&source, document, scale).expect("renders");
            let elapsed = started.elapsed().as_secs_f64();
            best = best.min(elapsed);
            std::hint::black_box(pixmap);
        }
        println!("{best:8.3}s  {name}");
    }

    // What the shell actually waits for: the pixmap plus the PNG encode, which
    // `pixcap_render_document` does before handing back a file.
    let full = &cases[3].1;
    let started = Instant::now();
    let pixmap = render_to_pixmap(&source, full, scale).expect("renders");
    let raster = started.elapsed().as_secs_f64();
    let started = Instant::now();
    let png = pixmap.encode_png().expect("encodes");
    println!(
        "\n{:8.3}s  raster + {:.3}s PNG encode = {:.3}s per preview ({} KB)",
        raster,
        started.elapsed().as_secs_f64(),
        raster + started.elapsed().as_secs_f64(),
        png.len() / 1024
    );

    if let Some(destination) = args.next() {
        std::fs::write(&destination, &png).expect("output writes");
        println!("wrote {destination}");
    }
}

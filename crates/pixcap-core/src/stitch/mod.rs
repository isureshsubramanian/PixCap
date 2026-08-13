//! Scrolling-capture frame stitcher.
//!
//! Consecutive screenshots of a scrolling view overlap: the bottom of frame N
//! reappears at the top of frame N+1. This module recovers that overlap with a
//! normalised match score over a band of rows, then concatenates only the new
//! content, producing one tall image.

use image::{DynamicImage, GrayImage, RgbaImage};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StitchError {
    #[error("no frames supplied")]
    NoFrames,
    #[error("frame {index} is {width}px wide, expected {expected}px")]
    WidthMismatch {
        index: usize,
        width: u32,
        expected: u32,
    },
    #[error("image error: {0}")]
    Image(#[from] image::ImageError),
}

#[derive(Debug, Clone)]
pub struct StitchOptions {
    /// Height of the band taken from the top of the incoming frame.
    pub band_height: u32,
    /// Columns are subsampled by this step when scoring (1 = every column).
    ///
    /// Safe to raise: alignment is vertical, so skipping columns only reduces
    /// the samples per row, it cannot hide a vertical misalignment.
    pub column_step: u32,
    /// Rows are subsampled by this step when scoring.
    ///
    /// Keep this at 1. Skipping rows makes flat, banded content (plain
    /// documents, tables) score a *perfect* match at slightly wrong offsets,
    /// because the sampled rows all land inside the same colour band and the
    /// mismatch at each band boundary is never examined. That produces a
    /// one-row seam duplication per frame, which accumulates as drift.
    pub row_step: u32,
    /// Mean per-pixel difference (0.0–1.0) below which a band counts as a match.
    pub match_threshold: f32,
}

impl Default for StitchOptions {
    fn default() -> Self {
        Self {
            band_height: 100,
            column_step: 4,
            row_step: 1,
            match_threshold: 0.045,
        }
    }
}

/// Where an incoming frame lines up against the accumulated canvas.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Alignment {
    /// Row in the canvas where the incoming frame's top band begins.
    pub offset_y: u32,
    /// Mean per-pixel difference at that offset (lower is better).
    pub score: f32,
    /// Whether the score cleared `match_threshold`.
    pub matched: bool,
}

/// Finds where `next`'s top band appears in `canvas`.
///
/// Searches from the bottom of the canvas upward, so the most recent scroll
/// position wins when a page contains repeating content.
pub fn find_alignment(canvas: &GrayImage, next: &GrayImage, options: &StitchOptions) -> Alignment {
    let canvas_height = canvas.height();
    let width = canvas.width().min(next.width());
    let band_height = options
        .band_height
        .min(next.height())
        .min(canvas_height.max(1));

    let mut best = Alignment {
        offset_y: canvas_height.saturating_sub(band_height),
        score: f32::MAX,
        matched: false,
    };

    if band_height == 0 || width == 0 || canvas_height < band_height {
        return best;
    }

    let column_step = options.column_step.max(1);
    let row_step = options.row_step.max(1);
    let last_offset = canvas_height - band_height;

    for offset in (0..=last_offset).rev() {
        let mut total = 0u64;
        let mut samples = 0u64;

        for row in (0..band_height).step_by(row_step as usize) {
            let canvas_row = offset + row;
            for column in (0..width).step_by(column_step as usize) {
                let a = canvas.get_pixel(column, canvas_row).0[0] as i32;
                let b = next.get_pixel(column, row).0[0] as i32;
                total += (a - b).unsigned_abs() as u64;
                samples += 1;
            }
        }

        if samples == 0 {
            continue;
        }

        let score = (total as f32 / samples as f32) / 255.0;
        if score < best.score {
            best.score = score;
            best.offset_y = offset;
        }

        // An effectively perfect match cannot be beaten; stop early.
        if score <= 0.002 {
            break;
        }
    }

    best.matched = best.score <= options.match_threshold;
    best
}

/// Stitches frames top-to-bottom into a single tall image.
///
/// Frames that add no new content (the view did not scroll) are skipped, and a
/// frame whose overlap cannot be located is appended whole rather than dropped.
pub fn stitch_vertical(
    frames: &[DynamicImage],
    options: &StitchOptions,
) -> Result<DynamicImage, StitchError> {
    let first = frames.first().ok_or(StitchError::NoFrames)?;
    let width = first.width();

    let mut canvas: RgbaImage = first.to_rgba8();
    let mut canvas_gray: GrayImage = first.to_luma8();

    for (index, frame) in frames.iter().enumerate().skip(1) {
        if frame.width() != width {
            return Err(StitchError::WidthMismatch {
                index,
                width: frame.width(),
                expected: width,
            });
        }

        let frame_rgba = frame.to_rgba8();
        let frame_gray = frame.to_luma8();
        let alignment = find_alignment(&canvas_gray, &frame_gray, options);

        let (keep_rows, start_row) = if alignment.matched {
            let band_height = options.band_height.min(frame.height());
            // Canvas keeps everything above the matched band's end; the frame
            // contributes everything below that band.
            (
                (alignment.offset_y + band_height).min(canvas.height()),
                band_height.min(frame_gray.height()),
            )
        } else {
            (canvas.height(), 0)
        };

        let new_rows = frame_gray.height().saturating_sub(start_row);
        if new_rows == 0 {
            continue; // view did not scroll
        }

        let mut combined = RgbaImage::new(width, keep_rows + new_rows);

        for y in 0..keep_rows {
            for x in 0..width {
                combined.put_pixel(x, y, *canvas.get_pixel(x, y));
            }
        }
        for y in 0..new_rows {
            for x in 0..width {
                combined.put_pixel(x, keep_rows + y, *frame_rgba.get_pixel(x, start_row + y));
            }
        }

        canvas = combined;
        canvas_gray = DynamicImage::ImageRgba8(canvas.clone()).to_luma8();
    }

    Ok(DynamicImage::ImageRgba8(canvas))
}

/// Reads frames from disk, stitches them, and writes the result to `output_path`.
pub fn stitch_files(paths: &[String], output_path: &str) -> Result<(u32, u32), StitchError> {
    let mut frames = Vec::with_capacity(paths.len());
    for path in paths {
        // Scrolling captures stitch into very tall images, so the same
        // generous decode limits apply here.
        frames.push(
            crate::render::open_image(path)
                .map_err(|error| StitchError::Image(image::ImageError::IoError(
                    std::io::Error::other(error.to_string()),
                )))?,
        );
    }

    let stitched = stitch_vertical(&frames, &StitchOptions::default())?;
    stitched.save(output_path)?;
    Ok((stitched.width(), stitched.height()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    /// Builds a tall synthetic "page" where every row has a distinct value.
    fn page(width: u32, height: u32) -> RgbaImage {
        let mut image = RgbaImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let value = ((y * 7 + x * 3) % 251) as u8;
                image.put_pixel(x, y, Rgba([value, value.wrapping_add(40), 200, 255]));
            }
        }
        image
    }

    fn viewport(source: &RgbaImage, top: u32, height: u32) -> DynamicImage {
        DynamicImage::ImageRgba8(image::imageops::crop_imm(source, 0, top, source.width(), height).to_image())
    }

    #[test]
    fn stitches_overlapping_viewports_back_into_the_original_page() {
        let source = page(120, 900);
        let frames = vec![
            viewport(&source, 0, 400),
            viewport(&source, 300, 400),
            viewport(&source, 600, 300),
        ];

        let stitched = stitch_vertical(&frames, &StitchOptions::default()).unwrap();

        assert_eq!(stitched.width(), 120);
        assert_eq!(stitched.height(), 900, "expected the full page height");

        // Spot-check that content lines up with the original page.
        let result = stitched.to_rgba8();
        for y in [0u32, 250, 500, 750, 899] {
            for x in [0u32, 60, 119] {
                assert_eq!(
                    result.get_pixel(x, y),
                    source.get_pixel(x, y),
                    "pixel mismatch at ({x}, {y})"
                );
            }
        }
    }

    #[test]
    fn identical_frames_add_no_new_rows() {
        let source = page(80, 300);
        let frame = viewport(&source, 0, 300);
        let frames = vec![frame.clone(), frame.clone(), frame];

        let stitched = stitch_vertical(&frames, &StitchOptions::default()).unwrap();
        assert_eq!(stitched.height(), 300);
    }

    #[test]
    fn alignment_reports_the_overlap_offset() {
        let source = page(100, 600);
        let canvas = viewport(&source, 0, 400).to_luma8();
        let next = viewport(&source, 250, 350).to_luma8();

        let alignment = find_alignment(&canvas, &next, &StitchOptions::default());
        assert!(alignment.matched, "overlap should be detected");
        assert_eq!(alignment.offset_y, 250);
    }

    #[test]
    fn unrelated_frames_are_appended_whole() {
        let first = DynamicImage::ImageRgba8(page(60, 200));
        let mut other = RgbaImage::new(60, 150);
        for pixel in other.pixels_mut() {
            *pixel = Rgba([10, 20, 30, 255]);
        }
        let frames = vec![first, DynamicImage::ImageRgba8(other)];

        let stitched = stitch_vertical(&frames, &StitchOptions::default()).unwrap();
        assert_eq!(stitched.height(), 350);
    }

    /// Low-frequency content: 10px bands of flat colour, as in a plain document.
    fn banded_page(width: u32, height: u32) -> RgbaImage {
        let mut image = RgbaImage::new(width, height);
        for y in 0..height {
            let band = (y / 10) as u32;
            let value = ((band * 37) % 255) as u8;
            for x in 0..width {
                image.put_pixel(x, y, Rgba([value, 255 - value, 128, 255]));
            }
        }
        image
    }

    #[test]
    fn stitches_flat_banded_content_without_drift() {
        let source = banded_page(200, 720);
        let frames = vec![
            viewport(&source, 0, 320),
            viewport(&source, 200, 320),
            viewport(&source, 400, 320),
        ];

        let stitched = stitch_vertical(&frames, &StitchOptions::default()).unwrap();
        assert_eq!(
            stitched.height(),
            720,
            "banded content must not drift at the seams"
        );
    }

    #[test]
    fn alignment_prefers_the_exact_offset_on_banded_content() {
        let source = banded_page(200, 720);
        let canvas = viewport(&source, 0, 320).to_luma8();
        let next = viewport(&source, 200, 320).to_luma8();

        let alignment = find_alignment(&canvas, &next, &StitchOptions::default());
        assert!(alignment.matched);
        assert_eq!(alignment.offset_y, 200, "score {}", alignment.score);
    }

    #[test]
    fn width_mismatch_is_reported() {
        let frames = vec![
            DynamicImage::ImageRgba8(page(100, 100)),
            DynamicImage::ImageRgba8(page(80, 100)),
        ];
        assert!(matches!(
            stitch_vertical(&frames, &StitchOptions::default()),
            Err(StitchError::WidthMismatch { index: 1, .. })
        ));
    }
}

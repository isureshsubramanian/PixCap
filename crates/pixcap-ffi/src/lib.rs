use pixcap_core::{
    AnnotationDocument, CaptureContext, CodeRenderer, HistoryDb, RenderOptions, ScreenshotRecord,
    ThemePresets,
};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_longlong, c_uint};

/// Converts a borrowed C string into a Rust `&str`, mapping null/invalid UTF-8 to `None`.
///
/// # Safety
/// `ptr` must be null or a valid, null-terminated C string.
unsafe fn opt_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        CStr::from_ptr(ptr).to_str().ok()
    }
}

/// Moves a Rust `String` into a caller-owned C string. Returns null if it cannot be represented.
fn into_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(c_string) => c_string.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// C-ABI exported function to render a code snippet to an SVG string pointer
/// # Safety
/// `code` and `language` must be valid, null-terminated C string pointers.
#[no_mangle]
pub unsafe extern "C" fn pixcap_render_snippet(
    code: *const c_char,
    language: *const c_char,
    syntax_theme: *const c_char,
) -> *mut c_char {
    let (Some(code_str), Some(lang_str)) = (opt_str(code), opt_str(language)) else {
        return std::ptr::null_mut();
    };

    let theme_str = opt_str(syntax_theme).unwrap_or("base16-ocean.dark");

    let renderer = CodeRenderer::default();
    let mut options = RenderOptions::default();
    options.code = code_str.to_string();
    options.language = lang_str.to_string();
    options.syntax_theme = theme_str.to_string();

    match renderer.render_svg(&options) {
        Ok(svg) => into_c_string(svg),
        Err(_) => std::ptr::null_mut(),
    }
}

/// C-ABI exported function to free C string allocated by Rust
/// # Safety
/// `s` must be a valid pointer allocated by `CString::into_raw`.
#[no_mangle]
pub unsafe extern "C" fn pixcap_free_string(s: *mut c_char) {
    if !s.is_null() {
        let _ = CString::from_raw(s);
    }
}

/// Returns the shared background preset catalogue as a JSON array.
///
/// Both platform shells read their preset list from here so the ids, display
/// names, and colours can never drift apart between macOS and Windows.
/// The caller owns the returned string and must free it with `pixcap_free_string`.
#[no_mangle]
pub extern "C" fn pixcap_theme_presets_json() -> *mut c_char {
    match serde_json::to_string(&ThemePresets::all()) {
        Ok(json) => into_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Resolves a file naming pattern (`{date}`, `{app}`, `{counter}`, …) against a capture context.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// String arguments must be null or valid, null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn pixcap_resolve_filename(
    pattern: *const c_char,
    mode: *const c_char,
    app_name: *const c_char,
    window_title: *const c_char,
    width: c_uint,
    height: c_uint,
    counter: c_uint,
) -> *mut c_char {
    let Some(pattern_str) = opt_str(pattern) else {
        return std::ptr::null_mut();
    };

    let context = CaptureContext {
        mode: opt_str(mode).unwrap_or("area").to_string(),
        app_name: opt_str(app_name).map(str::to_string),
        window_title: opt_str(window_title).map(str::to_string),
        width: width as u32,
        height: height as u32,
        counter: counter as u32,
    };

    into_c_string(pixcap_core::resolve_filename(pattern_str, &context))
}

/// Returns the default file naming pattern.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
#[no_mangle]
pub extern "C" fn pixcap_default_naming_pattern() -> *mut c_char {
    into_c_string(pixcap_core::default_pattern().to_string())
}

// ---------------------------------------------------------------------------
// Screenshot history (SQLite)
// ---------------------------------------------------------------------------
//
// The handle returned by `pixcap_history_open` wraps a single SQLite
// connection, which is *not* thread-safe. Callers must confine all history
// calls for a given handle to one thread or serial queue.

/// Opens (or creates) the screenshot history database at `db_path`.
///
/// Returns an opaque handle, or null on failure. Free it with `pixcap_history_close`.
///
/// # Safety
/// `db_path` must be a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_open(db_path: *const c_char) -> *mut HistoryDb {
    let Some(path) = opt_str(db_path) else {
        return std::ptr::null_mut();
    };

    match HistoryDb::new(path) {
        Ok(db) => Box::into_raw(Box::new(db)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Closes a history handle previously returned by `pixcap_history_open`.
///
/// # Safety
/// `handle` must be null or a handle from `pixcap_history_open` that has not already been closed.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_close(handle: *mut HistoryDb) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Inserts a `ScreenshotRecord` supplied as JSON. Returns the new row id, or -1 on failure.
///
/// # Safety
/// `handle` must be a live history handle and `record_json` a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_insert(
    handle: *mut HistoryDb,
    record_json: *const c_char,
) -> c_longlong {
    let Some(db) = handle.as_ref() else {
        return -1;
    };
    let Some(json) = opt_str(record_json) else {
        return -1;
    };
    let Ok(record) = serde_json::from_str::<ScreenshotRecord>(json) else {
        return -1;
    };

    db.insert_screenshot(&record).unwrap_or(-1)
}

/// Returns the most recent records as a JSON array, newest first.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// `handle` must be a live history handle.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_recent(
    handle: *mut HistoryDb,
    limit: c_longlong,
) -> *mut c_char {
    let Some(db) = handle.as_ref() else {
        return std::ptr::null_mut();
    };

    match db.get_recent(limit).and_then(|records| {
        Ok(serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string()))
    }) {
        Ok(json) => into_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Searches records by OCR text or tags, returning a JSON array.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// `handle` must be a live history handle and `query` a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_search(
    handle: *mut HistoryDb,
    query: *const c_char,
) -> *mut c_char {
    let Some(db) = handle.as_ref() else {
        return std::ptr::null_mut();
    };
    let Some(query_str) = opt_str(query) else {
        return std::ptr::null_mut();
    };

    match db.search_screenshots(query_str).map(|records| {
        serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string())
    }) {
        Ok(json) => into_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Deletes a record by id. Returns 0 on success, -1 on failure.
///
/// # Safety
/// `handle` must be a live history handle.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_delete(handle: *mut HistoryDb, id: c_longlong) -> c_int {
    match handle.as_ref() {
        Some(db) if db.delete_screenshot(id).is_ok() => 0,
        _ => -1,
    }
}

/// Toggles the favourite flag on a record. Returns 0 on success, -1 on failure.
///
/// # Safety
/// `handle` must be a live history handle.
#[no_mangle]
pub unsafe extern "C" fn pixcap_history_toggle_favorite(
    handle: *mut HistoryDb,
    id: c_longlong,
) -> c_int {
    match handle.as_ref() {
        Some(db) if db.toggle_favorite(id).is_ok() => 0,
        _ => -1,
    }
}

/// Languages the syntax engine can highlight, as a JSON array of
/// `{name, token, extensions}`.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
#[no_mangle]
pub extern "C" fn pixcap_syntax_languages_json() -> *mut c_char {
    let highlighter = pixcap_core::SyntaxHighlighter::default();
    match serde_json::to_string(&highlighter.available_languages()) {
        Ok(json) => into_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Syntax colour themes bundled with the engine, as a JSON array of names.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
#[no_mangle]
pub extern "C" fn pixcap_syntax_themes_json() -> *mut c_char {
    let highlighter = pixcap_core::SyntaxHighlighter::default();
    match serde_json::to_string(&highlighter.available_themes()) {
        Ok(json) => into_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

// ---------------------------------------------------------------------------
// Non-destructive edit documents
// ---------------------------------------------------------------------------

/// Validates `document_json` against the shared schema and writes it to `path`.
///
/// Returns 0 on success, -1 on failure.
///
/// # Safety
/// Both arguments must be valid, null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn pixcap_document_write(
    document_json: *const c_char,
    path: *const c_char,
) -> c_int {
    let (Some(json), Some(path_str)) = (opt_str(document_json), opt_str(path)) else {
        return -1;
    };

    match AnnotationDocument::from_json(json).and_then(|document| document.write(path_str)) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Reads a document from `path`, returning normalised JSON (defaults filled in).
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// `path` must be a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_document_read(path: *const c_char) -> *mut c_char {
    let Some(path_str) = opt_str(path) else {
        return std::ptr::null_mut();
    };

    match AnnotationDocument::read(path_str).and_then(|document| document.to_json()) {
        Ok(json) => into_c_string(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Returns the sidecar path for an image path.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// `image_path` must be a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_document_sidecar_path(image_path: *const c_char) -> *mut c_char {
    match opt_str(image_path) {
        Some(path) => into_c_string(pixcap_core::sidecar_path(path)),
        None => std::ptr::null_mut(),
    }
}

// ---------------------------------------------------------------------------
// Beautification rendering
// ---------------------------------------------------------------------------
//
// Used by the Windows shell and the CLI. macOS keeps its own Core Graphics
// renderer, so the two are not expected to be glyph-identical; the shared
// document schema is what keeps them semantically in step.

/// Renders a document to a PNG on disk.
///
/// `image_path` is the untouched capture, `document_json` an `AnnotationDocument`,
/// and `scale` the output pixels per canvas point (2.0 for a Retina-quality export).
///
/// Returns 0 on success, -1 on failure.
///
/// # Safety
/// All string arguments must be valid, null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn pixcap_render_document(
    image_path: *const c_char,
    document_json: *const c_char,
    scale: f32,
    output_path: *const c_char,
) -> c_int {
    let (Some(source_path), Some(json), Some(destination)) = (
        opt_str(image_path),
        opt_str(document_json),
        opt_str(output_path),
    ) else {
        return -1;
    };

    let Ok(document) = AnnotationDocument::from_json(json) else {
        eprintln!("pixcap: the document could not be parsed");
        return -1;
    };

    let source = match pixcap_core::render::open_image(source_path) {
        Ok(image) => image,
        Err(error) => {
            eprintln!("pixcap: could not open {source_path}: {error}");
            return -1;
        }
    };

    let png = match pixcap_core::render_document(&source, &document, scale.max(0.1)) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("pixcap: render failed: {error}");
            return -1;
        }
    };

    match std::fs::write(destination, png) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("pixcap: could not write {destination}: {error}");
            -1
        }
    }
}

/// Canvas dimensions a document would render to, as `{"width":W,"height":H}`.
///
/// Lets a shell size its preview without rendering first. The caller owns the
/// returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// `document_json` must be a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_render_canvas_size(
    document_json: *const c_char,
    source_width: c_uint,
    source_height: c_uint,
) -> *mut c_char {
    let Some(json) = opt_str(document_json) else {
        return std::ptr::null_mut();
    };
    let Ok(document) = AnnotationDocument::from_json(json) else {
        return std::ptr::null_mut();
    };

    let layout = pixcap_core::render_layout(
        source_width as f32,
        source_height as f32,
        &document.canvas,
    );

    into_c_string(
        serde_json::json!({
            "width": layout.canvas_width,
            "height": layout.canvas_height
        })
        .to_string(),
    )
}

/// Full canvas geometry for a document, as JSON.
///
/// An editor needs more than the canvas size: to convert a pointer position
/// into image coordinates it has to know where the screenshot sits inside the
/// canvas. Returning the renderer's own layout keeps the editor and the output
/// in agreement instead of re-deriving the arithmetic in the shell.
///
/// The caller owns the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// `document_json` must be a valid, null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn pixcap_render_layout(
    document_json: *const c_char,
    source_width: c_uint,
    source_height: c_uint,
) -> *mut c_char {
    let Some(json) = opt_str(document_json) else {
        return std::ptr::null_mut();
    };
    let Ok(document) = AnnotationDocument::from_json(json) else {
        return std::ptr::null_mut();
    };

    let layout = pixcap_core::render_layout(
        source_width as f32,
        source_height as f32,
        &document.canvas,
    );

    into_c_string(
        serde_json::json!({
            "canvas_width": layout.canvas_width,
            "canvas_height": layout.canvas_height,
            "frame_x": layout.frame_x,
            "frame_y": layout.frame_y,
            "frame_width": layout.frame_width,
            "frame_height": layout.frame_height,
            "image_x": layout.image_x,
            "image_y": layout.image_y,
            "image_width": layout.image_width,
            "image_height": layout.image_height,
            "crop_x": layout.crop_x,
            "crop_y": layout.crop_y
        })
        .to_string(),
    )
}

// ---------------------------------------------------------------------------
// Scrolling capture
// ---------------------------------------------------------------------------

/// Stitches the frames listed in `paths_json` (a JSON array of paths) into `output_path`.
///
/// Returns `{"width":W,"height":H}` as JSON, or null on failure. The caller owns
/// the returned string and must free it with `pixcap_free_string`.
///
/// # Safety
/// Both arguments must be valid, null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn pixcap_stitch_scroll_frames(
    paths_json: *const c_char,
    output_path: *const c_char,
) -> *mut c_char {
    let (Some(json), Some(output)) = (opt_str(paths_json), opt_str(output_path)) else {
        return std::ptr::null_mut();
    };

    let Ok(paths) = serde_json::from_str::<Vec<String>>(json) else {
        return std::ptr::null_mut();
    };

    match pixcap_core::stitch_files(&paths, output) {
        Ok((width, height)) => into_c_string(
            serde_json::json!({ "width": width, "height": height }).to_string(),
        ),
        Err(error) => {
            eprintln!("pixcap: stitch failed: {error}");
            std::ptr::null_mut()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn take_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null());
        let value = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        pixcap_free_string(ptr);
        value
    }

    #[test]
    fn presets_round_trip_as_json() {
        let json = unsafe { take_string(pixcap_theme_presets_json()) };
        let parsed: Vec<pixcap_core::BackgroundPreset> =
            serde_json::from_str(&json).expect("presets deserialize");
        assert!(parsed.iter().any(|p| p.id == "amethyst"));
    }

    #[test]
    fn filename_pattern_resolves_context_variables() {
        let pattern = CString::new("{app}_{mode}_{width}x{height}_{counter}").unwrap();
        let mode = CString::new("area").unwrap();
        let app = CString::new("Safari").unwrap();
        let resolved = unsafe {
            take_string(pixcap_resolve_filename(
                pattern.as_ptr(),
                mode.as_ptr(),
                app.as_ptr(),
                std::ptr::null(),
                1920,
                1080,
                7,
            ))
        };
        assert_eq!(resolved, "Safari_area_1920x1080_7");
    }

    #[test]
    fn renders_a_document_through_the_ffi() {
        let dir = std::env::temp_dir().join("pixcap-ffi-render-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // A small source image on disk.
        let source_path = dir.join("source.png");
        let mut image = image::RgbaImage::new(200, 150);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = image::Rgba([(x % 255) as u8, (y % 255) as u8, 90, 255]);
        }
        image.save(&source_path).unwrap();

        let document = serde_json::json!({
            "canvas": {
                "background_kind": "preset",
                "background_value": "amethyst",
                "padding": 30.0,
                "frame_style": "macOS",
                "frame_title": "ffi-test"
            },
            "items": [{
                "tool": "rectangle",
                "start": [10.0, 10.0],
                "end": [120.0, 90.0],
                "color_hex": "#FF3366",
                "stroke_width": 4.0
            }]
        })
        .to_string();

        let output_path = dir.join("render.png");

        unsafe {
            let source_c = CString::new(source_path.to_str().unwrap()).unwrap();
            let document_c = CString::new(document.clone()).unwrap();
            let output_c = CString::new(output_path.to_str().unwrap()).unwrap();

            let status = pixcap_render_document(
                source_c.as_ptr(),
                document_c.as_ptr(),
                2.0,
                output_c.as_ptr(),
            );
            assert_eq!(status, 0, "render should succeed");

            // 200x150 source, 30pt padding, 34pt header -> 260 x 244 points,
            // doubled by the 2x scale.
            let rendered = image::open(&output_path).expect("output decodes");
            assert_eq!(rendered.width(), 520);
            assert_eq!(rendered.height(), 488);

            // The size query must agree with what was rendered.
            let size_json = take_string(pixcap_render_canvas_size(document_c.as_ptr(), 200, 150));
            assert!(size_json.contains("260"), "got {size_json}");

            // The layout must place the image below the 34pt window chrome.
            let layout_json = take_string(pixcap_render_layout(document_c.as_ptr(), 200, 150));
            let layout: serde_json::Value = serde_json::from_str(&layout_json).unwrap();
            assert_eq!(layout["image_width"], 200.0);
            assert_eq!(layout["image_height"], 150.0);
            assert_eq!(
                layout["image_y"].as_f64().unwrap(),
                layout["frame_y"].as_f64().unwrap() + 34.0
            );

            // A bad path must fail rather than panic.
            let missing = CString::new("/definitely/not/here.png").unwrap();
            assert_eq!(
                pixcap_render_document(missing.as_ptr(), document_c.as_ptr(), 2.0, output_c.as_ptr()),
                -1
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn history_handle_supports_full_lifecycle() {
        let dir = std::env::temp_dir().join("pixcap-ffi-history-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = CString::new(dir.join("history.sqlite").to_str().unwrap()).unwrap();

        unsafe {
            let handle = pixcap_history_open(db_path.as_ptr());
            assert!(!handle.is_null());

            let record = serde_json::json!({
                "id": 0,
                "filepath": "/tmp/shot.png",
                "thumbnail_path": null,
                "captured_at": "2026-08-13T09:00:00Z",
                "capture_mode": "area",
                "width": 800,
                "height": 600,
                "ocr_text": "kubernetes dashboard",
                "tags": null,
                "is_favorited": false
            })
            .to_string();
            let record_c = CString::new(record).unwrap();
            let id = pixcap_history_insert(handle, record_c.as_ptr());
            assert!(id > 0);

            let recent = take_string(pixcap_history_recent(handle, 10));
            assert!(recent.contains("/tmp/shot.png"));

            let query = CString::new("kubernetes").unwrap();
            let found = take_string(pixcap_history_search(handle, query.as_ptr()));
            assert!(found.contains("/tmp/shot.png"));

            assert_eq!(pixcap_history_toggle_favorite(handle, id), 0);
            assert_eq!(pixcap_history_delete(handle, id), 0);

            let empty = take_string(pixcap_history_recent(handle, 10));
            assert_eq!(empty, "[]");

            pixcap_history_close(handle);
        }

        let _ = std::fs::remove_dir_all(&dir);
    }
}

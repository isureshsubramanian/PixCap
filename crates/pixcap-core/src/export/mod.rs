use crate::canvas::{CanvasLayout, WindowFrameStyle};
use crate::themes::BackgroundFill;
use crate::syntax::SyntaxHighlighter;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ExportError {
    #[error("Syntax error: {0}")]
    Syntax(String),
    #[error("Render error: {0}")]
    Render(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

pub struct RenderOptions {
    pub code: String,
    pub language: String,
    pub syntax_theme: String,
    pub layout: CanvasLayout,
    pub background: BackgroundFill,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            code: "// PixCap Native Engine\nfn hello() {\n    println!(\"High performance screenshot beautifier\");\n}".to_string(),
            language: "rust".to_string(),
            syntax_theme: "base16-ocean.dark".to_string(),
            layout: CanvasLayout::default(),
            background: BackgroundFill::default(),
        }
    }
}

pub struct CodeRenderer {
    highlighter: SyntaxHighlighter,
}

impl Default for CodeRenderer {
    fn default() -> Self {
        Self {
            highlighter: SyntaxHighlighter::default(),
        }
    }
}

impl CodeRenderer {
    /// Renders code snippet into scalable SVG string
    pub fn render_svg(&self, options: &RenderOptions) -> Result<String, ExportError> {
        let lines = self
            .highlighter
            .highlight(&options.code, &options.language, &options.syntax_theme)
            .map_err(|e| ExportError::Syntax(e.to_string()))?;

        let line_height = 24.0;
        let font_size = 14.0;
        let char_width = 8.5; // Monospace approximate

        // Calculate dimensions
        let max_line_len = lines
            .iter()
            .map(|l| l.tokens.iter().map(|(t, _)| t.len()).sum::<usize>())
            .max()
            .unwrap_or(40);

        let gutter_width = if options.layout.show_line_numbers { 40.0 } else { 0.0 };
        let window_padding = 24.0;
        let header_height = 40.0;

        let content_width = gutter_width + (max_line_len as f32 * char_width) + (window_padding * 2.0);
        let content_height = header_height + (lines.len() as f32 * line_height) + (window_padding * 2.0);

        let canvas_width = content_width + (options.layout.padding.left + options.layout.padding.right) as f32;
        let canvas_height = content_height + (options.layout.padding.top + options.layout.padding.bottom) as f32;

        let mut svg = String::new();
        svg.push_str(&format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}" viewBox="0 0 {} {}">"#,
            canvas_width, canvas_height, canvas_width, canvas_height
        ));

        // 1. Render Background Wrapper
        match &options.background {
            BackgroundFill::Gradient { angle_deg: _, stops } => {
                svg.push_str("<defs><linearGradient id=\"bg-grad\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"100%\">");
                for (pos, hex) in stops {
                    svg.push_str(&format!(r#"<stop offset="{:.0}%" stop-color="{}" />"#, pos * 100.0, hex));
                }
                svg.push_str("</linearGradient></defs>");
                svg.push_str(&format!(
                    r#"<rect width="{}" height="{}" fill="url(#bg-grad)" rx="16" />"#,
                    canvas_width, canvas_height
                ));
            }
            BackgroundFill::Solid(hex) => {
                svg.push_str(&format!(
                    r#"<rect width="{}" height="{}" fill="{}" rx="16" />"#,
                    canvas_width, canvas_height, hex
                ));
            }
            BackgroundFill::Transparent => {
                // True alpha background - no wrapper rect rendered
            }
            _ => {
                svg.push_str(&format!(
                    r##"<rect width="{}" height="{}" fill="#1e1e2e" rx="16" />"##,
                    canvas_width, canvas_height
                ));
            }
        }

        // 2. Render Code Container Window
        let win_x = options.layout.padding.left as f32;
        let win_y = options.layout.padding.top as f32;

        // Drop shadow
        if options.layout.drop_shadow.enabled {
            svg.push_str(&format!(
                r##"<filter id="shadow"><feDropShadow dx="0" dy="{}" stdDeviation="{}" flood-opacity="{}" flood-color="{}" /></filter>"##,
                options.layout.drop_shadow.y_offset,
                options.layout.drop_shadow.blur_radius,
                options.layout.drop_shadow.opacity,
                options.layout.drop_shadow.color_hex
            ));
        }

        let shadow_attr = if options.layout.drop_shadow.enabled { r#"filter="url(#shadow)""# } else { "" };
        svg.push_str(&format!(
            r##"<rect x="{}" y="{}" width="{}" height="{}" rx="{}" fill="#1e1e2e" {} />"##,
            win_x, win_y, content_width, content_height, options.layout.rounded_corners_radius, shadow_attr
        ));

        // 3. Render Window Frame Controls
        if options.layout.frame_style == WindowFrameStyle::MacOs {
            let dots_y = win_y + 20.0;
            let dots_x = win_x + 20.0;
            svg.push_str(&format!(r##"<circle cx="{}" cy="{}" r="6" fill="#FF5F56" />"##, dots_x, dots_y));
            svg.push_str(&format!(r##"<circle cx="{}" cy="{}" r="6" fill="#FFBD2E" />"##, dots_x + 18.0, dots_y));
            svg.push_str(&format!(r##"<circle cx="{}" cy="{}" r="6" fill="#27C93F" />"##, dots_x + 36.0, dots_y));
        }

        // 4. Render Code Lines
        let code_start_y = win_y + header_height + window_padding;
        let code_start_x = win_x + window_padding + gutter_width;

        for (line_idx, line) in lines.iter().enumerate() {
            let y = code_start_y + (line_idx as f32 * line_height);

            // Gutter Line Number
            if options.layout.show_line_numbers {
                let gutter_x = win_x + window_padding + 10.0;
                svg.push_str(&format!(
                    r##"<text x="{}" y="{}" font-family="JetBrains Mono, monospace" font-size="{}" fill="#6c7086">{}</text>"##,
                    gutter_x, y, font_size, line.line_number
                ));
            }

            // Tokens
            let mut current_x = code_start_x;
            for (text, style) in &line.tokens {
                let color_hex = format!("#{:02x}{:02x}{:02x}", style.foreground.r, style.foreground.g, style.foreground.b);
                let escaped_text = text
                    .replace('&', "&amp;")
                    .replace('<', "&lt;")
                    .replace('>', "&gt;")
                    .replace('"', "&quot;");

                // xml:space="preserve" is required. Each token is its own
                // <text>, and the default XML handling strips leading and
                // trailing whitespace, so `let kept` renders as `letkept`.
                svg.push_str(&format!(
                    r#"<text xml:space="preserve" x="{}" y="{}" font-family="JetBrains Mono, monospace" font-size="{}" fill="{}">{}</text>"#,
                    current_x, y, font_size, color_hex, escaped_text
                ));

                // Advance by character count, not byte length: `len()` counts
                // UTF-8 bytes, so any non-ASCII character would push the rest
                // of the line right by the number of extra bytes it occupies.
                current_x += text.chars().count() as f32 * char_width;
            }
        }

        svg.push_str("</svg>");
        Ok(svg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_svg_generation() {
        let renderer = CodeRenderer::default();
        let options = RenderOptions::default();
        let result = renderer.render_svg(&options);

        assert!(result.is_ok());
        let svg = result.unwrap();
        assert!(svg.contains("<svg"));
        assert!(svg.contains("PixCap Native Engine"));
        assert!(svg.contains("linearGradient"));
    }
}

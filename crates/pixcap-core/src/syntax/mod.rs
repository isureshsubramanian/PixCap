use syntect::easy::HighlightLines;
use syntect::highlighting::{Style, ThemeSet};
use syntect::parsing::{SyntaxDefinition, SyntaxSet};
use syntect::util::LinesWithEndings;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SyntaxError {
    #[error("Language '{0}' not recognized")]
    UnknownLanguage(String),
    #[error("Highlighting failed: {0}")]
    HighlightFailed(String),
}

pub struct SyntaxHighlighter {
    syntax_set: SyntaxSet,
    theme_set: ThemeSet,
}

/// Syntaxes compiled into the binary to cover gaps in syntect's default set.
///
/// syntect bundles Sublime Text's default packages, which predate Swift,
/// TypeScript, Kotlin, and TOML. Embedding the definitions rather than reading
/// them from disk keeps the core self-contained and works identically on every
/// platform the shared core is linked into.
const EXTRA_SYNTAXES: &[(&str, &str)] = &[
    ("Swift", include_str!("../../syntaxes/Swift.sublime-syntax")),
    ("TypeScript", include_str!("../../syntaxes/TypeScript.sublime-syntax")),
    ("Kotlin", include_str!("../../syntaxes/Kotlin.sublime-syntax")),
    ("TOML", include_str!("../../syntaxes/TOML.sublime-syntax")),
];

impl Default for SyntaxHighlighter {
    fn default() -> Self {
        let mut builder = SyntaxSet::load_defaults_newlines().into_builder();

        for (name, source) in EXTRA_SYNTAXES {
            match SyntaxDefinition::load_from_str(source, true, None) {
                Ok(definition) => builder.add(definition),
                // A malformed bundled syntax must not take the whole engine
                // down; the language is simply unavailable.
                Err(error) => eprintln!("pixcap: could not load {name} syntax: {error}"),
            }
        }

        Self {
            syntax_set: builder.build(),
            theme_set: ThemeSet::load_defaults(),
        }
    }
}

pub struct HighlightedLine {
    pub line_number: usize,
    pub tokens: Vec<(String, Style)>, // (text_content, syntect_style)
}

impl SyntaxHighlighter {
    pub fn highlight(&self, code: &str, language: &str, theme_name: &str) -> Result<Vec<HighlightedLine>, SyntaxError> {
        let syntax = self
            .syntax_set
            .find_syntax_by_token(language)
            .or_else(|| self.syntax_set.find_syntax_by_extension(language))
            .unwrap_or_else(|| self.syntax_set.find_syntax_plain_text());

        let theme = self
            .theme_set
            .themes
            .get(theme_name)
            .or_else(|| self.theme_set.themes.get("base16-ocean.dark"))
            .unwrap_or_else(|| &self.theme_set.themes["base16-ocean.dark"]);

        let mut highlighter = HighlightLines::new(syntax, theme);
        let mut highlighted_lines = Vec::new();

        for (idx, line) in LinesWithEndings::from(code).enumerate() {
            let regions = highlighter
                .highlight_line(line, &self.syntax_set)
                .map_err(|e| SyntaxError::HighlightFailed(e.to_string()))?;

            let tokens = regions
                .into_iter()
                .map(|(style, text)| (text.to_string(), style))
                .collect();

            highlighted_lines.push(HighlightedLine {
                line_number: idx + 1,
                tokens,
            });
        }

        Ok(highlighted_lines)
    }

    pub fn available_themes(&self) -> Vec<String> {
        let mut themes: Vec<String> = self.theme_set.themes.keys().cloned().collect();
        themes.sort();
        themes
    }

    /// Every syntax the engine can highlight, sorted by display name.
    ///
    /// The UI builds its language list from this rather than hardcoding one, so
    /// the picker can never advertise less than the engine supports.
    pub fn available_languages(&self) -> Vec<LanguageInfo> {
        let mut languages: Vec<LanguageInfo> = self
            .syntax_set
            .syntaxes()
            .iter()
            .filter(|syntax| {
                // Skip internal helper syntaxes and plain text, which are not
                // meaningful choices for a user.
                !syntax.name.starts_with('_')
                    && syntax.name != "Plain Text"
                    && !syntax.file_extensions.is_empty()
            })
            .map(|syntax| LanguageInfo {
                name: syntax.name.clone(),
                // `find_syntax_by_token` resolves extensions, so the first one
                // is the most reliable round-trip identifier.
                token: syntax
                    .file_extensions
                    .first()
                    .cloned()
                    .unwrap_or_else(|| syntax.name.to_lowercase()),
                extensions: syntax.file_extensions.clone(),
            })
            .collect();

        languages.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        languages.dedup_by(|a, b| a.name == b.name);
        languages
    }

    /// Whether `language` resolves to a real syntax rather than falling back to
    /// plain text. Lets the UI say so instead of silently rendering unstyled code.
    pub fn recognizes(&self, language: &str) -> bool {
        self.syntax_set
            .find_syntax_by_token(language)
            .or_else(|| self.syntax_set.find_syntax_by_extension(language))
            .is_some()
    }
}

/// A syntax the engine can highlight.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LanguageInfo {
    /// Display name, e.g. "Rust".
    pub name: String,
    /// Identifier to pass back when highlighting, e.g. "rs".
    pub token: String,
    pub extensions: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_every_bundled_language() {
        let highlighter = SyntaxHighlighter::default();
        let languages = highlighter.available_languages();

        // syntect's default set is far larger than the 14 the UI used to hardcode.
        assert!(
            languages.len() > 40,
            "expected the full syntect set, got {}",
            languages.len()
        );

        // Tokens must round-trip: whatever the picker offers has to highlight.
        for language in &languages {
            assert!(
                highlighter.recognizes(&language.token),
                "token '{}' for {} does not resolve",
                language.token,
                language.name
            );
        }

        assert!(languages.iter().any(|l| l.name == "Rust"));
        assert!(languages.iter().any(|l| l.name == "Python"));
    }

    #[test]
    fn bundles_languages_missing_from_syntect() {
        let highlighter = SyntaxHighlighter::default();
        let names: Vec<&str> = highlighter
            .available_languages()
            .iter()
            .map(|l| Box::leak(l.name.clone().into_boxed_str()) as &str)
            .collect();

        // These are absent from syntect's defaults and shipped by PixCap.
        for language in ["Swift", "TypeScript", "Kotlin", "TOML"] {
            assert!(names.contains(&language), "{language} should be available");
        }
    }

    #[test]
    fn added_syntaxes_actually_highlight() {
        let highlighter = SyntaxHighlighter::default();

        let cases = [
            ("swift", "let x: Int = 42 // comment", "keyword"),
            ("ts", "const enabled: boolean = true", "keyword"),
            ("kt", "val name: String = \"hi\"", "keyword"),
            ("toml", "[package]\nname = \"pixcap\"", "key"),
        ];

        for (token, code, label) in cases {
            assert!(highlighter.recognizes(token), "{token} not recognised");

            let lines = highlighter
                .highlight(code, token, "base16-ocean.dark")
                .unwrap_or_else(|e| panic!("{token} failed to highlight: {e}"));

            // Plain text yields one uniform style for the line; a real syntax
            // produces several differently-styled regions.
            let styles: std::collections::HashSet<String> = lines
                .iter()
                .flat_map(|line| line.tokens.iter())
                .map(|(_, style)| format!("{:?}", style.foreground))
                .collect();

            assert!(
                styles.len() > 1,
                "{token} produced a single style — {label} highlighting is not working"
            );
        }
    }

    #[test]
    fn reports_unknown_languages() {
        let highlighter = SyntaxHighlighter::default();
        assert!(highlighter.recognizes("rs"));
        assert!(!highlighter.recognizes("definitely-not-a-language"));
    }

    #[test]
    fn test_rust_syntax_highlighting() {
        let highlighter = SyntaxHighlighter::default();
        let code = "fn main() {\n    println!(\"Hello, PixCap!\");\n}";
        let result = highlighter.highlight(code, "rs", "base16-ocean.dark");

        assert!(result.is_ok());
        let lines = result.unwrap();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].line_number, 1);
    }
}

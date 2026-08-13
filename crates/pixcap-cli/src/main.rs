use clap::{Parser, Subcommand};
use pixcap_core::{CanvasLayout, CodeRenderer, RedactionEngine, RenderOptions, ThemePresets};
use pixcap_ipc::{IpcMessageRequest, IpcServer};
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "pixcap", author = "PixCap Team", version = "0.1.0")]
#[command(about = "High-performance cross-platform screen snapshot & code beautifier CLI", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Render code snippet to SVG or PNG file
    Code {
        /// Code input file path or string text
        #[arg(short, long)]
        input: Option<PathBuf>,

        /// Programming language (e.g. rust, js, py, ts, cpp)
        #[arg(short, long, default_value = "rust")]
        lang: String,

        /// Output SVG file path
        #[arg(short, long, default_value = "output.svg")]
        out: PathBuf,

        /// Theme name (breeze, candy, dracula, glass)
        #[arg(short, long, default_value = "breeze")]
        theme: String,

        /// Auto-redact sensitive info (API keys, tokens, emails, IPs)
        #[arg(short, long)]
        redact: bool,
    },
    /// Ping IPC daemon server
    Ping,
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Code {
            input,
            lang,
            out,
            theme,
            redact,
        } => {
            let mut code_content = match input {
                Some(path) => fs::read_to_string(&path).unwrap_or_else(|_| {
                    eprintln!("Error reading input file: {:?}", path);
                    std::process::exit(1);
                }),
                None => "// PixCap CLI Output\nfn main() {\n    println!(\"Beautified Code Snippet\");\n}".to_string(),
            };

            if redact {
                let redaction_engine = RedactionEngine::default();
                code_content = redaction_engine.redact(&code_content, '█');
            }

            let bg = match theme.as_str() {
                "candy" => ThemePresets::candy(),
                "dracula" => ThemePresets::dracula_dark(),
                "glass" => ThemePresets::glass_dark(),
                _ => ThemePresets::breeze(),
            };

            let renderer = CodeRenderer::default();
            let options = RenderOptions {
                code: code_content,
                language: lang,
                syntax_theme: "base16-ocean.dark".to_string(),
                layout: CanvasLayout::default(),
                background: bg,
            };

            match renderer.render_svg(&options) {
                Ok(svg) => {
                    if let Err(e) = fs::write(&out, svg) {
                        eprintln!("Failed to write output file: {}", e);
                    } else {
                        println!("✨ Successfully generated beautified snippet: {:?}", out);
                    }
                }
                Err(e) => {
                    eprintln!("Failed to render code: {}", e);
                }
            }
        }
        Commands::Ping => {
            let res = IpcServer::process_request(IpcMessageRequest::Ping);
            println!("IPC Daemon response: {:?}", res);
        }
    }
}

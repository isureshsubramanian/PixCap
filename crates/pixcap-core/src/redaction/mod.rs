use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum RedactionType {
    Email,
    IpAddress,
    AwsAccessKey,
    GitHubToken,
    CreditCard,
    CustomRegex(String),
}

/// Sensitive data redaction engine
pub struct RedactionEngine {
    patterns: Vec<(RedactionType, Regex)>,
}

impl Default for RedactionEngine {
    fn default() -> Self {
        let mut engine = Self { patterns: Vec::new() };
        engine.add_default_rules();
        engine
    }
}

impl RedactionEngine {
    pub fn add_default_rules(&mut self) {
        // Email pattern
        if let Ok(re) = Regex::new(r"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}") {
            self.patterns.push((RedactionType::Email, re));
        }

        // IPv4 address pattern
        if let Ok(re) = Regex::new(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b") {
            self.patterns.push((RedactionType::IpAddress, re));
        }

        // AWS Access Key ID pattern
        if let Ok(re) = Regex::new(r"\b(AKIA[0-9A-Z]{16})\b") {
            self.patterns.push((RedactionType::AwsAccessKey, re));
        }

        // GitHub Personal Access Token pattern
        if let Ok(re) = Regex::new(r"\b(ghp_[a-zA-Z0-9]{36})\b") {
            self.patterns.push((RedactionType::GitHubToken, re));
        }
    }

    /// Redacts all detected sensitive text matching configured rules
    pub fn redact(&self, input: &str, replacement_char: char) -> String {
        let mut result = input.to_string();
        for (_, regex) in &self.patterns {
            result = regex
                .replace_all(&result, |caps: &regex::Captures| {
                    let matched = caps.get(0).unwrap().as_str();
                    replacement_char.to_string().repeat(matched.len())
                })
                .to_string();
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_email_and_ip_redaction() {
        let engine = RedactionEngine::default();
        let source = "Contact dev@example.com at server 192.168.1.100 with key AKIAIOSFODNN7EXAMPLE";
        let redacted = engine.redact(source, '█');

        assert!(!redacted.contains("dev@example.com"));
        assert!(!redacted.contains("192.168.1.100"));
        assert!(!redacted.contains("AKIAIOSFODNN7EXAMPLE"));
        assert!(redacted.contains("Contact"));
    }
}

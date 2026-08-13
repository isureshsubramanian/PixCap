use serde::{Deserialize, Serialize};

/// A point in 2D space.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A rectangle in 2D space.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub origin: Point,
    pub size: Size,
}

/// A size in 2D space.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// Arrow head styles
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArrowHeadStyle {
    Open,
    Filled,
    None,
}

/// Blur styles
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlurStyle {
    Gaussian,
    Pixelate,
}

/// Enum containing all possible annotations.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Annotation {
    Arrow {
        start_point: Point,
        end_point: Point,
        color: String,
        stroke_width: f64,
        head_style: ArrowHeadStyle,
    },
    Rectangle {
        origin: Point,
        size: Size,
        color: String,
        stroke_width: f64,
        fill_color: Option<String>,
        corner_radius: f64,
    },
    Ellipse {
        center: Point,
        radii: Size,
        color: String,
        stroke_width: f64,
        fill_color: Option<String>,
    },
    Line {
        start: Point,
        end: Point,
        color: String,
        stroke_width: f64,
        dash_pattern: Option<Vec<f64>>,
    },
    Text {
        position: Point,
        content: String,
        font_size: f64,
        color: String,
        background_color: Option<String>,
    },
    Counter {
        position: Point,
        number: u32,
        color: String,
        size: f64,
    },
    Blur {
        region: Rect,
        intensity: f32,
        style: BlurStyle,
    },
    Highlight {
        region: Rect,
        color: String,
        opacity: f32,
    },
    Freehand {
        points: Vec<Point>,
        color: String,
        stroke_width: f64,
        smoothing: bool,
    },
    Spotlight {
        region: Rect,
        outer_opacity: f32,
    },
}

/// Holds a collection of annotations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnnotationLayer {
    pub annotations: Vec<Annotation>,
}

impl AnnotationLayer {
    /// Creates a new, empty annotation layer.
    pub fn new() -> Self {
        Self {
            annotations: Vec::new(),
        }
    }
}

impl Default for AnnotationLayer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_annotation_layer() {
        let mut layer = AnnotationLayer::new();
        layer.annotations.push(Annotation::Counter {
            position: Point { x: 10.0, y: 10.0 },
            number: 1,
            color: "#ff0000".to_string(),
            size: 24.0,
        });
        assert_eq!(layer.annotations.len(), 1);
    }
}

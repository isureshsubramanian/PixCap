#ifndef PIXCAP_FFI_H
#define PIXCAP_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Renders code snippet to SVG string pointer
char* pixcap_render_snippet(const char* code, const char* language, const char* syntax_theme);

/// Frees string allocated by Rust FFI
void pixcap_free_string(char* s);

#ifdef __cplusplus
}
#endif

#endif // PIXCAP_FFI_H

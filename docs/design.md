# Design

## Language rule: prefer Odin

Write new code in Odin. Use Rust only where it is absolutely necessary: the thin
C-ABI wrapper in `shim/` that talks to ratatui and crossterm (terminal setup, key
input, drawing one widget into a rect, layout solving).

Everything else is Odin: JSON specs and state, bindings, catalog validation,
streaming, scroll/focus, hot reload, the viewer, and `boardd`.

Before you add Rust, ask: does this call ratatui or crossterm directly? If not, it goes in Odin.

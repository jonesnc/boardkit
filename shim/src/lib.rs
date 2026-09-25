//! Thin C-ABI wrapper over ratatui + crossterm. It only sets up the terminal, reads keys, solves
//! layouts and draws one widget into one rect. Specs, state, bindings, validation, scrolling and
//! hot reload live in Odin (../ratatui). See docs/design.md: prefer Odin unless Rust is necessary.

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::Relaxed};
use std::time::Duration;

use crossterm::event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseButton, MouseEventKind};
use ratatui::{
    DefaultTerminal, Frame, Terminal,
    backend::TestBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    symbols::Marker,
    text::Line,
    widgets::{
        RatatuiLogo, RatatuiMascot,
        calendar::{CalendarEventStore, Monthly},
        canvas::{Canvas, Circle, Line as CLine, Map, MapResolution, Points, Rectangle},
        Axis, Bar, BarChart, BarGroup, Block, Chart, Clear, Dataset, Gauge, GraphType, LineGauge, List, ListState, Paragraph, Row,
        Scrollbar, ScrollbarOrientation, ScrollbarState, Sparkline, Table, Tabs, Wrap,
    },
};

static RESIZED: AtomicBool = AtomicBool::new(false);
static MOUSE: AtomicU32 = AtomicU32::new(0); // column << 16 | row of the last mouse event

/// A real terminal, or an in-memory one for tests.
pub enum Term {
    Real(DefaultTerminal),
    Test(Terminal<TestBackend>),
}

// ---- C types. Odin `string` and `[]T` have the same layout as Str and Slice. ----

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Str {
    ptr: *const u8,
    len: isize,
}

impl Str {
    fn s<'a>(&self) -> &'a str {
        if self.ptr.is_null() || self.len <= 0 {
            return "";
        }
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(self.ptr, self.len as usize) }).unwrap_or("")
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Slice<T> {
    ptr: *const T,
    len: isize,
}

impl<T> Slice<T> {
    fn get<'a>(&self) -> &'a [T] {
        if self.ptr.is_null() || self.len <= 0 {
            return &[];
        }
        unsafe { std::slice::from_raw_parts(self.ptr, self.len as usize) }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct RRect {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
}

impl From<RRect> for Rect {
    fn from(r: RRect) -> Rect {
        Rect::new(r.x, r.y, r.w, r.h)
    }
}

impl From<Rect> for RRect {
    fn from(r: Rect) -> RRect {
        RRect { x: r.x, y: r.y, w: r.width, h: r.height }
    }
}

pub const BOLD: u32 = 1;
pub const ITALIC: u32 = 2;
pub const UNDERLINE: u32 = 4;
pub const REVERSED: u32 = 8;
pub const DIM: u32 = 16;

/// Colors are names or #rrggbb, parsed by ratatui. Empty = unset.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RStyle {
    fg: Str,
    bg: Str,
    mods: u32,
}

fn color(s: &Str) -> Option<Color> {
    let s = s.s();
    if s.is_empty() { None } else { s.parse::<Color>().ok() }
}

fn style(p: *const RStyle) -> Style {
    let Some(r) = (unsafe { p.as_ref() }) else { return Style::default() };
    let mut st = Style::default();
    if let Some(c) = color(&r.fg) {
        st = st.fg(c);
    }
    if let Some(c) = color(&r.bg) {
        st = st.bg(c);
    }
    for (bit, m) in [(BOLD, Modifier::BOLD), (ITALIC, Modifier::ITALIC), (UNDERLINE, Modifier::UNDERLINED), (REVERSED, Modifier::REVERSED), (DIM, Modifier::DIM)] {
        if r.mods & bit != 0 {
            st = st.add_modifier(m);
        }
    }
    st
}

/// kind: 0 fill, 1 length, 2 percent, 3 min, 4 max.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RCons {
    kind: i32,
    n: u16,
}

fn cons(c: &RCons) -> Constraint {
    match c.kind {
        1 => Constraint::Length(c.n),
        2 => Constraint::Percentage(c.n),
        3 => Constraint::Min(c.n),
        4 => Constraint::Max(c.n),
        _ => Constraint::Fill(c.n),
    }
}

#[repr(C)]
pub struct RItem {
    text: Str,
    style: RStyle,
}

#[repr(C)]
pub struct RRow {
    cells: Slice<Str>,
    style: RStyle,
}

#[repr(C)]
pub struct RSeries {
    name: Str,
    style: RStyle,
    pts: Slice<[f64; 2]>,
}

#[repr(C)]
pub struct RBar {
    label: Str,
    value: u64,
}

/// kind: 0 line, 1 rect, 2 circle, 3 points, 4 map, 5 text. a..d: x1 y1 x2 y2 | x y w h | x y r | - | high=1 | x y.
#[repr(C)]
pub struct RShape {
    kind: i32,
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    style: RStyle,
    text: Str,
    pts: Slice<[f64; 2]>,
}

fn frame<'a>(f: *mut c_void) -> &'a mut Frame<'a> {
    unsafe { &mut *(f as *mut Frame<'a>) }
}

// ---- terminal ----

/// Enter raw mode + alt screen. Returns an opaque handle.
#[unsafe(no_mangle)]
pub extern "C" fn rt_init() -> *mut Term {
    let t = ratatui::init();
    // Mouse capture, so the wheel scrolls the table under the pointer (rt_mouse_pos).
    let _ = crossterm::execute!(std::io::stdout(), EnableMouseCapture);
    Box::into_raw(Box::new(Term::Real(t)))
}

/// An in-memory w x h terminal for tests. Free with rt_restore.
#[unsafe(no_mangle)]
pub extern "C" fn rt_test_init(w: u16, h: u16) -> *mut Term {
    match Terminal::new(TestBackend::new(w, h)) {
        Ok(t) => Box::into_raw(Box::new(Term::Test(t))),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Restore the terminal and free the handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_restore(t: *mut Term) {
    if t.is_null() {
        return;
    }
    let real = matches!(unsafe { &*t }, Term::Real(_));
    drop(unsafe { Box::from_raw(t) });
    if real {
        let _ = crossterm::execute!(std::io::stdout(), DisableMouseCapture);
        ratatui::restore();
    }
}

/// Wait up to `timeout_ms` for a key press. Returns the char code, a negative
/// special code (-1 none, -2 esc, -3 enter, -4 up, -5 down, -6 left, -7 right,
/// -8 backspace, -9 tab, -10 pgup, -11 pgdn, -12 home, -13 end, -14 wheel up, -15 wheel down,
/// -16 left click; rt_mouse_pos gives where), or -100 for any other key.
#[unsafe(no_mangle)]
pub extern "C" fn rt_poll_key(timeout_ms: u32) -> i32 {
    if !event::poll(Duration::from_millis(timeout_ms as u64)).unwrap_or(false) {
        return -1;
    }
    match event::read() {
        Ok(Event::Resize(..)) => {
            RESIZED.store(true, Relaxed);
            -1
        }
        Ok(Event::Mouse(m)) => {
            MOUSE.store(((m.column as u32) << 16) | m.row as u32, Relaxed);
            match m.kind {
                MouseEventKind::ScrollUp => -14,
                MouseEventKind::ScrollDown => -15,
                MouseEventKind::Down(MouseButton::Left) => -16,
                _ => -1,
            }
        }
        Ok(Event::Key(k)) if k.kind == KeyEventKind::Press => match k.code {
            KeyCode::Char(c) => c as i32,
            KeyCode::Esc => -2,
            KeyCode::Enter => -3,
            KeyCode::Up => -4,
            KeyCode::Down => -5,
            KeyCode::Left => -6,
            KeyCode::Right => -7,
            KeyCode::Backspace => -8,
            KeyCode::Tab => -9,
            KeyCode::PageUp => -10,
            KeyCode::PageDown => -11,
            KeyCode::Home => -12,
            KeyCode::End => -13,
            _ => -100,
        },
        _ => -1,
    }
}

/// Where the last mouse event happened (column, row).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_mouse_pos(x: *mut u16, y: *mut u16) {
    let v = MOUSE.load(Relaxed);
    if let (Some(x), Some(y)) = (unsafe { x.as_mut() }, unsafe { y.as_mut() }) {
        (*x, *y) = ((v >> 16) as u16, v as u16);
    }
}

/// 1 if the terminal was resized since the last call (the caller should redraw), else 0.
#[unsafe(no_mangle)]
pub extern "C" fn rt_take_resized() -> i32 {
    RESIZED.swap(false, Relaxed) as i32
}

/// Draw one frame: calls `cb(frame, ud)`, which draws with the rt_* widget calls below.
/// Returns 0, -1 on bad args, -3 on IO error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_frame(t: *mut Term, cb: Option<extern "C" fn(*mut c_void, *mut c_void)>, ud: *mut c_void) -> i32 {
    let (Some(t), Some(cb)) = (unsafe { t.as_mut() }, cb) else { return -1 };
    let draw = |f: &mut Frame| cb(f as *mut Frame as *mut c_void, ud);
    let ok = match t {
        Term::Real(t) => t.draw(draw).is_ok(),
        Term::Test(t) => t.draw(draw).is_ok(),
    };
    if ok { 0 } else { -3 }
}

/// Test terminals: copy the screen as UTF-8 rows joined by '\n' into buf. Returns the byte length
/// needed (call again with a bigger buf if it exceeds cap), or -1.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_test_screen(t: *mut Term, buf: *mut u8, cap: isize) -> isize {
    let Some(Term::Test(t)) = (unsafe { t.as_ref() }) else { return -1 };
    let b = t.backend().buffer();
    let rows: Vec<String> = (0..b.area.height).map(|y| (0..b.area.width).map(|x| b[(x, y)].symbol().to_string()).collect()).collect();
    let s = rows.join("\n");
    if !buf.is_null() && s.len() as isize <= cap {
        unsafe { std::ptr::copy_nonoverlapping(s.as_ptr(), buf, s.len()) };
    }
    s.len() as isize
}

/// Test terminals: the foreground color of cell (x, y) as ratatui prints it ("Red", "Reset", ...).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_test_fg(t: *mut Term, x: u16, y: u16, buf: *mut u8, cap: isize) -> isize {
    let Some(Term::Test(t)) = (unsafe { t.as_ref() }) else { return -1 };
    let s = format!("{:?}", t.backend().buffer()[(x, y)].fg);
    if !buf.is_null() && s.len() as isize <= cap {
        unsafe { std::ptr::copy_nonoverlapping(s.as_ptr(), buf, s.len()) };
    }
    s.len() as isize
}

/// 1 if ratatui accepts the color string (name or #rrggbb), else 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_color_ok(s: *const Str) -> i32 {
    unsafe { s.as_ref() }.is_some_and(|s| s.s().parse::<Color>().is_ok()) as i32
}

// ---- layout ----

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_frame_area(f: *mut c_void, out: *mut RRect) {
    unsafe { *out = frame(f).area().into() };
}

/// Split `area` by `n` constraints into `out` (n rects). vertical: 1 = vstack, 0 = hstack.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_layout(area: *const RRect, vertical: i32, c: *const RCons, n: isize, out: *mut RRect) {
    let c = Slice { ptr: c, len: n };
    let d = if vertical != 0 { Direction::Vertical } else { Direction::Horizontal };
    let areas = Layout::new(d, c.get().iter().map(cons)).split(unsafe { *area }.into());
    for (i, a) in areas.iter().enumerate() {
        unsafe { *out.add(i) = (*a).into() };
    }
}

// ---- widgets: each draws into `area` on frame `f` ----

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_clear(f: *mut c_void, area: *const RRect) {
    frame(f).render_widget(Clear, unsafe { *area }.into());
}

/// Bordered block. Writes the inner rect to `inner`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_block(f: *mut c_void, area: *const RRect, title: *const Str, st: *const RStyle, inner: *mut RRect) {
    let area: Rect = unsafe { *area }.into();
    let b = Block::bordered().title(unsafe { &*title }.s().to_string()).style(style(st));
    if !inner.is_null() {
        unsafe { *inner = b.inner(area).into() };
    }
    frame(f).render_widget(b, area);
}

/// Wrapped text, scrolled down `scroll` lines.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_paragraph(f: *mut c_void, area: *const RRect, text: *const Str, st: *const RStyle, scroll: u16) {
    let p = Paragraph::new(unsafe { &*text }.s().to_string()).style(style(st)).wrap(Wrap { trim: false }).scroll((scroll, 0));
    frame(f).render_widget(p, unsafe { *area }.into());
}

/// List rows; `selected` < 0 means none. Selected row is reversed with a "> " marker.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_list(f: *mut c_void, area: *const RRect, items: *const RItem, n: isize, st: *const RStyle, selected: i64) {
    let items = Slice { ptr: items, len: n };
    let lines: Vec<Line> = items.get().iter().map(|i| Line::styled(i.text.s().to_string(), style(&i.style))).collect();
    let list = List::new(lines)
        .style(style(st))
        .highlight_style(Style::default().add_modifier(Modifier::REVERSED))
        .highlight_symbol("> ");
    let mut state = ListState::default();
    state.select(usize::try_from(selected).ok());
    frame(f).render_stateful_widget(list, unsafe { *area }.into(), &mut state);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_gauge(f: *mut c_void, area: *const RRect, ratio: f64, label: *const Str, st: *const RStyle) {
    let g = Gauge::default().ratio(ratio.clamp(0.0, 1.0)).label(unsafe { &*label }.s().to_string()).gauge_style(style(st));
    frame(f).render_widget(g, unsafe { *area }.into());
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_linegauge(f: *mut c_void, area: *const RRect, ratio: f64, label: *const Str, st: *const RStyle) {
    let g = LineGauge::default().ratio(ratio.clamp(0.0, 1.0)).label(unsafe { &*label }.s().to_string()).filled_style(style(st));
    frame(f).render_widget(g, unsafe { *area }.into());
}

/// Line chart over the given axis bounds (the caller computes them). Axis labels show the bounds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_chart(
    f: *mut c_void, area: *const RRect, series: *const RSeries, n: isize, x_title: *const Str, y_title: *const Str, bounds: *const [f64; 4],
) {
    let series = Slice { ptr: series, len: n };
    let pts: Vec<Vec<(f64, f64)>> = series.get().iter().map(|s| s.pts.get().iter().map(|p| (p[0], p[1])).collect()).collect();
    let sets: Vec<Dataset> = series
        .get()
        .iter()
        .zip(&pts)
        .map(|(s, p)| Dataset::default().name(s.name.s().to_string()).marker(Marker::Braille).graph_type(GraphType::Line).style(style(&s.style)).data(p))
        .collect();
    let [x0, x1, y0, y1] = unsafe { *bounds };
    let axis = |t: &Str, lo: f64, hi: f64| Axis::default().title(t.s().to_string()).bounds([lo, hi]).labels([format!("{lo:.4}"), format!("{hi:.4}")]);
    let c = Chart::new(sets).x_axis(axis(unsafe { &*x_title }, x0, x1)).y_axis(axis(unsafe { &*y_title }, y0, y1));
    frame(f).render_widget(c, unsafe { *area }.into());
}

/// Month calendar; `highlight` days are reversed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_calendar(f: *mut c_void, area: *const RRect, year: i32, month: u8, highlight: *const u8, n: isize, st: *const RStyle) {
    let Ok(month) = time::Month::try_from(month.clamp(1, 12)) else { return };
    let mut ev = CalendarEventStore::default();
    for &d in (Slice { ptr: highlight, len: n }).get() {
        if let Ok(date) = time::Date::from_calendar_date(year, month, d) {
            ev.add(date, Style::default().add_modifier(Modifier::REVERSED).patch(style(st)));
        }
    }
    if let Ok(first) = time::Date::from_calendar_date(year, month, 1) {
        let cal = Monthly::new(first, ev)
            .show_month_header(Style::default().add_modifier(Modifier::BOLD))
            .show_weekdays_header(Style::default().add_modifier(Modifier::DIM))
            .default_style(style(st));
        frame(f).render_widget(cal, unsafe { *area }.into());
    }
}

enum Shape {
    Line(CLine),
    Rect(Rectangle),
    Circle(Circle),
    Points(Vec<(f64, f64)>, Color),
    Map(Map),
    Text(f64, f64, String, Style),
}

/// Braille canvas with x/y bounds and shapes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_canvas(f: *mut c_void, area: *const RRect, xb: *const [f64; 2], yb: *const [f64; 2], shapes: *const RShape, n: isize) {
    let shapes: Vec<Shape> = (Slice { ptr: shapes, len: n })
        .get()
        .iter()
        .filter_map(|s| {
            let col = style(&s.style).fg.unwrap_or(Color::Reset);
            let (a, b, c, d) = (s.a, s.b, s.c, s.d);
            Some(match s.kind {
                0 => Shape::Line(CLine { x1: a, y1: b, x2: c, y2: d, color: col }),
                1 => Shape::Rect(Rectangle { x: a, y: b, width: c, height: d, color: col }),
                2 => Shape::Circle(Circle { x: a, y: b, radius: c, color: col }),
                3 => Shape::Points(s.pts.get().iter().map(|p| (p[0], p[1])).collect(), col),
                4 => Shape::Map(Map { color: col, resolution: if a != 0.0 { MapResolution::High } else { MapResolution::Low } }),
                5 => Shape::Text(a, b, s.text.s().to_string(), style(&s.style)),
                _ => return None,
            })
        })
        .collect();
    let c = Canvas::default().x_bounds(unsafe { *xb }).y_bounds(unsafe { *yb }).marker(Marker::Braille).paint(move |ctx| {
        for s in &shapes {
            match s {
                Shape::Line(l) => ctx.draw(l),
                Shape::Rect(r) => ctx.draw(r),
                Shape::Circle(c) => ctx.draw(c),
                Shape::Points(p, col) => ctx.draw(&Points::new(p, *col)),
                Shape::Map(m) => ctx.draw(m),
                Shape::Text(x, y, t, st) => ctx.print(*x, *y, Line::styled(t.clone(), *st)),
            }
        }
    });
    frame(f).render_widget(c, unsafe { *area }.into());
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_logo(f: *mut c_void, area: *const RRect, small: i32) {
    let logo = if small != 0 { RatatuiLogo::small() } else { RatatuiLogo::tiny() };
    frame(f).render_widget(logo, unsafe { *area }.into());
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_mascot(f: *mut c_void, area: *const RRect) {
    frame(f).render_widget(RatatuiMascot::new(), unsafe { *area }.into());
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_sparkline(f: *mut c_void, area: *const RRect, data: *const u64, n: isize, st: *const RStyle) {
    let data = (Slice { ptr: data, len: n }).get().to_vec();
    frame(f).render_widget(Sparkline::default().data(data).style(style(st)), unsafe { *area }.into());
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_tabs(f: *mut c_void, area: *const RRect, titles: *const Str, n: isize, selected: u64, st: *const RStyle) {
    let titles: Vec<String> = (Slice { ptr: titles, len: n }).get().iter().map(|s| s.s().to_string()).collect();
    let t = Tabs::new(titles)
        .select(selected as usize)
        .style(style(st))
        .highlight_style(Style::default().add_modifier(Modifier::BOLD | Modifier::REVERSED));
    frame(f).render_widget(t, unsafe { *area }.into());
}

/// Table. An empty header draws none; no widths means equal Fill columns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_table(
    f: *mut c_void, area: *const RRect, header: *const Str, nh: isize, rows: *const RRow, nr: isize, widths: *const RCons, nw: isize, st: *const RStyle,
) {
    let header: Vec<String> = (Slice { ptr: header, len: nh }).get().iter().map(|s| s.s().to_string()).collect();
    let rows = (Slice { ptr: rows, len: nr }).get();
    let ncols = rows.first().map_or(0, |r| r.cells.get().len());
    let widths: Vec<Constraint> = match (Slice { ptr: widths, len: nw }).get() {
        w if !w.is_empty() => w.iter().map(cons).collect(),
        _ => vec![Constraint::Fill(1); ncols.max(1)],
    };
    let body: Vec<Row> = rows
        .iter()
        .map(|r| Row::new(r.cells.get().iter().map(|c| c.s().to_string()).collect::<Vec<_>>()).style(style(&r.style)))
        .collect();
    let mut t = Table::new(body, widths).style(style(st));
    if !header.is_empty() {
        t = t.header(Row::new(header).style(Style::default().add_modifier(Modifier::BOLD)));
    }
    frame(f).render_widget(t, unsafe { *area }.into());
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_barchart(f: *mut c_void, area: *const RRect, bars: *const RBar, n: isize, bar_width: u16, st: *const RStyle) {
    let bars: Vec<Bar> = (Slice { ptr: bars, len: n }).get().iter().map(|b| Bar::default().label(Line::from(b.label.s().to_string())).value(b.value)).collect();
    let c = BarChart::default().data(BarGroup::new(bars)).bar_width(bar_width).bar_gap(1).style(style(st));
    frame(f).render_widget(c, unsafe { *area }.into());
}

/// Scrollbar. viewport = 0 leaves ratatui's default viewport length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_scrollbar(f: *mut c_void, area: *const RRect, content: u64, position: u64, viewport: u64, horizontal: i32, st: *const RStyle) {
    let orient = if horizontal != 0 { ScrollbarOrientation::HorizontalBottom } else { ScrollbarOrientation::VerticalRight };
    let mut s = ScrollbarState::new(content as usize).position(position as usize);
    if viewport > 0 {
        s = s.viewport_content_length(viewport as usize);
    }
    frame(f).render_stateful_widget(Scrollbar::new(orient).style(style(st)), unsafe { *area }.into(), &mut s);
}

/// Show the terminal cursor at (x, y) after this frame.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_set_cursor(f: *mut c_void, x: u16, y: u16) {
    frame(f).set_cursor_position((x, y));
}

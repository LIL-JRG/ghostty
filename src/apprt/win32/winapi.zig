//! Win32 API declarations needed by the win32 apprt. The Zig standard
//! library intentionally only ships the subset of Win32 that it needs
//! (kernel32, ntdll, etc.), so the windowing/GDI/OpenGL APIs we need are
//! declared here.
const std = @import("std");
const win = std.os.windows;

pub const HWND = win.HWND;
pub const HINSTANCE = win.HINSTANCE;
pub const HMODULE = win.HMODULE;
pub const HANDLE = win.HANDLE;
pub const BOOL = win.BOOL;
pub const DWORD = win.DWORD;
pub const UINT = win.UINT;
pub const WPARAM = win.WPARAM;
pub const LPARAM = win.LPARAM;
pub const LRESULT = win.LRESULT;
pub const RECT = win.RECT;
pub const POINT = win.POINT;
pub const WORD = win.WORD;
pub const ATOM = u16;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = HICON;
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: c_long,
    lpszName: [*:0]const u16,
    lpszClass: [*:0]const u16,
    dwExStyle: DWORD,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: WORD = 1,
    dwFlags: DWORD = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

// Window class styles
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_OWNDC: UINT = 0x0020;

// Window styles
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;

// SetWindowPos flags
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const SWP_HIDEWINDOW: UINT = 0x0080;

pub const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));

// ShowWindow
pub const SW_HIDE: c_int = 0;
pub const SW_SHOW: c_int = 5;
pub const SW_SHOWDEFAULT: c_int = 10;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_RESTORE: c_int = 9;

// GetWindowLongPtr offsets
pub const GWLP_USERDATA: c_int = -21;

// Messages
pub const WM_NULL: UINT = 0x0000;
pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SHOWWINDOW: UINT = 0x0018;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_DEADCHAR: UINT = 0x0103;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_SYSDEADCHAR: UINT = 0x0107;
pub const WM_UNICHAR: UINT = 0x0109;
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;
pub const WM_IME_SETCONTEXT: UINT = 0x0281;
pub const WM_IME_NOTIFY: UINT = 0x0282;
pub const WM_IME_CHAR: UINT = 0x0286;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_USER: UINT = 0x0400;
pub const WM_APP: UINT = 0x8000;

// Our custom messages
pub const WM_APP_TICK: UINT = WM_APP + 1;
pub const WM_APP_SURFACE_CLOSE: UINT = WM_APP + 2;


// PeekMessage
pub const PM_NOREMOVE: UINT = 0x0000;
pub const PM_REMOVE: UINT = 0x0001;

// Mouse
pub const WHEEL_DELTA: i16 = 120;
pub const TME_LEAVE: DWORD = 0x00000002;
pub const HTCLIENT: LRESULT = 1;

// IME
pub const HIMC = *opaque {};
pub const GCS_COMPSTR: DWORD = 0x0008;
pub const GCS_RESULTSTR: DWORD = 0x0800;
pub const CFS_POINT: DWORD = 0x0002;
pub const CFS_CANDIDATEPOS: DWORD = 0x0040;
pub const ISC_SHOWUICOMPOSITIONWINDOW: usize = 0x80000000;
pub const VK_PROCESSKEY: WPARAM = 0xE5;

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(.winapi) c_long;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(HIMC, *CANDIDATEFORM) callconv(.winapi) BOOL;

// Virtual keys
pub const VK_SHIFT: c_int = 0x10;
pub const VK_CONTROL: c_int = 0x11;
pub const VK_MENU: c_int = 0x12;
pub const VK_CAPITAL: c_int = 0x14;
pub const VK_NUMLOCK: c_int = 0x90;
pub const VK_LSHIFT: c_int = 0xA0;
pub const VK_RSHIFT: c_int = 0xA1;
pub const VK_LCONTROL: c_int = 0xA2;
pub const VK_RCONTROL: c_int = 0xA3;
pub const VK_LMENU: c_int = 0xA4;
pub const VK_RMENU: c_int = 0xA5;
pub const VK_LWIN: c_int = 0x5B;
pub const VK_RWIN: c_int = 0x5C;

pub const MAPVK_VK_TO_VSC: UINT = 0;
pub const MAPVK_VK_TO_CHAR: UINT = 2;

// Clipboard
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// Cursors (IDC_*) are integer resources.
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;

// DPI awareness contexts (handle values)
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// Pixel format flags
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_TYPE_RGBA: u8 = 0;
pub const PFD_MAIN_PLANE: u8 = 0;

// WGL context attributes (WGL_ARB_create_context)
pub const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
pub const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x0001;
pub const WGL_CONTEXT_FLAGS_ARB: c_int = 0x2094;
pub const WGL_CONTEXT_DEBUG_BIT_ARB: c_int = 0x0001;

pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

// user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW([*:0]const u16, HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) isize;
pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.winapi) isize;
pub extern "user32" fn LoadCursorW(?HINSTANCE, ?[*:0]align(1) const u16) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, ?[*:0]align(1) const u16) callconv(.winapi) ?HICON;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn ShowCursor(BOOL) callconv(.winapi) c_int;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(c_int) callconv(.winapi) i16;
pub extern "user32" fn GetKeyboardState([*]u8) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
pub extern "user32" fn ToUnicode(UINT, UINT, ?[*]const u8, [*]u16, c_int, UINT) callconv(.winapi) c_int;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, UINT) callconv(.winapi) c_int;

// gdi32
pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
pub extern "gdi32" fn SetPixelFormat(HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn DescribePixelFormat(HDC, c_int, UINT, ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;

// GDI drawing (custom tab bar)
pub const COLORREF = DWORD;
pub const HGDIOBJ = *anyopaque;
pub const HBITMAP = *anyopaque;
pub const HFONT = *anyopaque;

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

pub const TRANSPARENT: c_int = 1;
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const DT_LEFT: UINT = 0x0000;
pub const DT_CENTER: UINT = 0x0001;
pub const DT_VCENTER: UINT = 0x0004;
pub const DT_SINGLELINE: UINT = 0x0020;
pub const DT_END_ELLIPSIS: UINT = 0x8000;
pub const FW_NORMAL: c_int = 400;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const OUT_DEFAULT_PRECIS: DWORD = 0;
pub const CLIP_DEFAULT_PRECIS: DWORD = 0;
pub const CLEARTYPE_QUALITY: DWORD = 5;
pub const DEFAULT_PITCH: DWORD = 0;

pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(HDC, [*:0]const u16, c_int, *RECT, UINT) callconv(.winapi) c_int;
pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(HDC, c_int, c_int) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, ?HDC, c_int, c_int, DWORD) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateFontW(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: ?[*:0]const u16,
) callconv(.winapi) ?HFONT;

// GDI+ (antialiased rounded tab pills)
pub const GpGraphics = *opaque {};
pub const GpSolidFill = *opaque {};
pub const GpPath = *opaque {};

pub const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: BOOL = 0,
    SuppressExternalCodecs: BOOL = 0,
};

pub const SmoothingModeAntiAlias: c_int = 4;
pub const FillModeAlternate: c_int = 0;

pub extern "gdiplus" fn GdiplusStartup(*usize, *const GdiplusStartupInput, ?*anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreateFromHDC(HDC, *?GpGraphics) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteGraphics(GpGraphics) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipSetSmoothingMode(GpGraphics, c_int) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreateSolidFill(u32, *?GpSolidFill) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteBrush(GpSolidFill) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreatePath(c_int, *?GpPath) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeletePath(GpPath) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipAddPathArcI(GpPath, c_int, c_int, c_int, c_int, f32, f32) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipClosePathFigure(GpPath) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipFillPath(GpGraphics, GpSolidFill, GpPath) callconv(.winapi) c_int;

/// COLORREF (0x00BBGGRR) to GDI+ opaque ARGB (0xAARRGGBB).
pub fn argbFromColorref(c: COLORREF) u32 {
    const r = c & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = (c >> 16) & 0xFF;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

// DWM (dark title bar, transparency)
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const DWMWA_CAPTION_COLOR: DWORD = 35;
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.winapi) win.HRESULT;

pub const HRGN = *opaque {};
pub const DWM_BB_ENABLE: DWORD = 0x01;
pub const DWM_BB_BLURREGION: DWORD = 0x02;

pub const DWM_BLURBEHIND = extern struct {
    dwFlags: DWORD,
    fEnable: BOOL,
    hRgnBlur: ?HRGN,
    fTransitionOnMaximized: BOOL = 0,
};

pub extern "dwmapi" fn DwmEnableBlurBehindWindow(HWND, *const DWM_BLURBEHIND) callconv(.winapi) win.HRESULT;
pub extern "gdi32" fn CreateRectRgn(c_int, c_int, c_int, c_int) callconv(.winapi) ?HRGN;

// Undocumented but long-stable compositor attribute used for the
// acrylic/blur-behind effect (same mechanism used by many terminals).
pub const ACCENT_DISABLED: DWORD = 0;
pub const ACCENT_ENABLE_BLURBEHIND: DWORD = 3;
pub const ACCENT_ENABLE_ACRYLICBLURBEHIND: DWORD = 4;
pub const WCA_ACCENT_POLICY: DWORD = 19;

pub const ACCENT_POLICY = extern struct {
    AccentState: DWORD,
    AccentFlags: DWORD,
    GradientColor: DWORD, // AABBGGRR
    AnimationId: DWORD,
};

pub const WINDOWCOMPOSITIONATTRIBDATA = extern struct {
    Attrib: DWORD,
    pvData: *anyopaque,
    cbData: usize,
};

pub extern "user32" fn SetWindowCompositionAttribute(HWND, *WINDOWCOMPOSITIONATTRIBDATA) callconv(.winapi) BOOL;

// Registry (light/dark theme detection)
pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;
pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) c_long;

pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WA_INACTIVE: u16 = 0;
pub const SIZE_MINIMIZED: WPARAM = 1;

// Layered windows (whole-window opacity)
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const GWL_EXSTYLE: c_int = -20;
pub const LWA_ALPHA: DWORD = 0x00000002;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, COLORREF, u8, DWORD) callconv(.winapi) BOOL;

// Title bar text color
pub const DWMWA_TEXT_COLOR: DWORD = 36;

// Window dragging / maximize from the tab bar
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const HTCAPTION: WPARAM = 2;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const CS_DBLCLKS: UINT = 0x0008;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;

// Window placement persistence (window-save-state)
pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;

// opengl32
pub extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "opengl32" fn wglGetCurrentContext() callconv(.winapi) ?HGLRC;

// kernel32 extras (not in std.os.windows.kernel32)
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HMODULE;

pub const GetLastError = win.GetLastError;

/// Helper to make an integer resource pointer (MAKEINTRESOURCE). The
/// result is not a real pointer (it carries an integer ID) so it has
/// no alignment guarantee.
pub fn makeIntResourceW(id: usize) [*:0]align(1) const u16 {
    return @ptrFromInt(id);
}

/// Extract low/high words from LPARAM for mouse coordinates (signed).
pub fn getXLParam(lparam: LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
}

pub fn getYLParam(lparam: LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}

pub fn loWord(v: usize) u16 {
    return @truncate(v);
}

pub fn hiWord(v: usize) u16 {
    return @truncate(v >> 16);
}

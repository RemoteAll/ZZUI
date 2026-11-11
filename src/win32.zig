//! 手写 Win32 声明层（Zig 0.17 已移除 @cImport，只声明本项目用到的部分）。
//! 约束：只用 Windows 7 上存在的 API；不链 libc。
const std = @import("std");

// ---------------------------------------------------------------- 基础类型
pub const HANDLE = *opaque {};
pub const HWND = HANDLE;
pub const HINSTANCE = HANDLE;
pub const HMODULE = HANDLE;
pub const HMENU = HANDLE;
pub const HICON = HANDLE;
pub const HCURSOR = HANDLE;
pub const HBRUSH = HANDLE;
pub const HDC = HANDLE;
pub const HFONT = HANDLE;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const BOOL = i32;
pub const UINT = u32;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = i32;
pub const ULONG_PTR = usize;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const LPVOID = ?*anyopaque;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

// ---------------------------------------------------------------- 结构体
pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };
pub const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };

pub const SYSTEMTIME = extern struct {
    wYear: WORD,
    wMonth: WORD,
    wDayOfWeek: WORD,
    wDay: WORD,
    wHour: WORD,
    wMinute: WORD,
    wSecond: WORD,
    wMilliseconds: WORD,
};

pub const MSG = extern struct {
    hwnd: HANDLE,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: ?WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: ?LPCWSTR,
    hIconSm: ?HICON,
};

pub const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};

pub const CRITICAL_SECTION = extern struct {
    DebugInfo: ?*anyopaque,
    LockCount: LONG,
    RecursionCount: LONG,
    OwningThread: ?HANDLE,
    LockSemaphore: ?HANDLE,
    SpinCount: ULONG_PTR,
};

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    offset: DWORD,
    offset_high: DWORD,
    hEvent: ?HANDLE,
};

pub const DCB = extern struct {
    DCBlength: DWORD,
    BaudRate: DWORD,
    flags: DWORD,
    wReserved: WORD,
    XonLim: WORD,
    XoffLim: WORD,
    ByteSize: u8,
    Parity: u8,
    StopBits: u8,
    XonChar: u8,
    XoffChar: u8,
    ErrorChar: u8,
    EofChar: u8,
    EvtChar: u8,
    wReserved1: WORD,
};

pub const COMMTIMEOUTS = extern struct {
    ReadIntervalTimeout: DWORD,
    ReadTotalTimeoutMultiplier: DWORD,
    ReadTotalTimeoutConstant: DWORD,
    WriteTotalTimeoutMultiplier: DWORD,
    WriteTotalTimeoutConstant: DWORD,
};

pub const COMSTAT = extern struct {
    flags: DWORD,
    cbInQue: DWORD,
    cbOutQue: DWORD,
};

// ---------------------------------------------------------------- 常量
pub const MF_STRING: UINT = 0x00000000;
pub const MF_POPUP: UINT = 0x00000010;
pub const MF_SEPARATOR: UINT = 0x00000800;

pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_VSCROLL: DWORD = 0x00200000;
pub const WS_HSCROLL: DWORD = 0x00100000;
pub const WS_TABSTOP: DWORD = 0x00010000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_EX_DLGMODALFRAME: DWORD = 0x00000001;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;

pub const ES_LEFT: DWORD = 0x0000;
pub const ES_MULTILINE: DWORD = 0x0004;
pub const ES_AUTOVSCROLL: DWORD = 0x0040;
pub const ES_AUTOHSCROLL: DWORD = 0x0080;
pub const ES_READONLY: DWORD = 0x0800;
pub const ES_WANTRETURN: DWORD = 0x1000;

pub const CBS_DROPDOWN: DWORD = 0x0002;
pub const CBS_DROPDOWNLIST: DWORD = 0x0003;
pub const CBS_OWNERDRAWFIXED: DWORD = 0x0010;
pub const CBS_HASSTRINGS: DWORD = 0x0200;
pub const CBS_SORT: DWORD = 0x0100;

pub const LBS_NOTIFY: DWORD = 0x0001;

pub const BS_PUSHBUTTON: DWORD = 0x00000000;
pub const BS_AUTOCHECKBOX: DWORD = 0x00000003;
pub const BS_GROUPBOX: DWORD = 0x00000007;
pub const BS_OWNERDRAW: DWORD = 0x0000000B;
pub const BS_TYPEMASK: DWORD = 0x0000000F;

pub const SS_LEFT: DWORD = 0x00000000;
pub const SS_CENTER: DWORD = 0x00000001;
pub const SS_RIGHT: DWORD = 0x00000002;
pub const SS_SUNKEN: DWORD = 0x00001000;

pub const SBS_VERT: DWORD = 0x0001;
pub const SBM_SETRANGE: UINT = 0x00E0;
pub const SBM_SETPOS: UINT = 0x00E1;

pub const SB_LINEUP: i32 = 0;
pub const SB_LINEDOWN: i32 = 1;
pub const SB_PAGEUP: i32 = 2;
pub const SB_PAGEDOWN: i32 = 3;
pub const SB_THUMBPOSITION: i32 = 4;
pub const SB_THUMBTRACK: i32 = 5;
pub const SB_TOP: i32 = 6;
pub const SB_BOTTOM: i32 = 7;
pub const SB_ENDSCROLL: i32 = 8;

pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_GETFONT: UINT = 0x0031;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_VSCROLL: UINT = 0x0115;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
pub const WM_APP: UINT = 0x8000;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_CTLCOLORSTATIC: UINT = 0x0138;
pub const WM_CTLCOLOREDIT: UINT = 0x0133;
pub const WM_CTLCOLORLISTBOX: UINT = 0x0134;
pub const WM_CTLCOLORBTN: UINT = 0x0135;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_DRAWITEM: UINT = 0x002B;

pub const WM_GETTEXT: UINT = 0x000D;
pub const WM_GETTEXTLENGTH: UINT = 0x000E;
pub const WM_SETTEXT: UINT = 0x000C;
pub const WM_ENABLE: UINT = 0x000A;

pub const EM_SETSEL: UINT = 0x00B1;
pub const EM_SCROLLCARET: UINT = 0x00B7;
pub const EM_REPLACESEL: UINT = 0x00C2;
pub const EM_SETLIMITTEXT: UINT = 0x00C5;
pub const EM_GETLINECOUNT: UINT = 0x00BA;

pub const CB_ADDSTRING: UINT = 0x0143;
pub const CB_GETCOUNT: UINT = 0x0146;
pub const CB_GETCURSEL: UINT = 0x0147;
pub const CB_GETLBTEXT: UINT = 0x0148;
pub const CB_GETLBTEXTLEN: UINT = 0x0149;
pub const CB_SETCURSEL: UINT = 0x014E;
pub const CB_SETITEMHEIGHT: UINT = 0x0153;
pub const CB_RESETCONTENT: UINT = 0x014B;
pub const CBN_SELCHANGE: u16 = 1;

pub const LB_ADDSTRING: UINT = 0x0180;
pub const LB_DELETESTRING: UINT = 0x0182;
pub const LB_RESETCONTENT: UINT = 0x0184;
pub const LB_SETCURSEL: UINT = 0x0186;
pub const LB_GETCURSEL: UINT = 0x0188;
pub const LB_GETTEXT: UINT = 0x0189;
pub const LB_GETTEXTLEN: UINT = 0x018A;
pub const LB_GETCOUNT: UINT = 0x018B;
pub const LB_SETTOPINDEX: UINT = 0x0197;
pub const LBN_DBLCLK: u16 = 2;

pub const BM_GETCHECK: UINT = 0x00F0;
pub const BM_SETCHECK: UINT = 0x00F1;
pub const BST_CHECKED: LRESULT = 1;
pub const BN_CLICKED: u16 = 0;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_SHOWMAXIMIZED: i32 = 3;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_RESTORE: i32 = 9;

pub const COLOR_BTNFACE: i32 = 15;
pub const COLOR_WINDOW: i32 = 5;

pub const FW_NORMAL: i32 = 400;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const OUT_DEFAULT_PRECIS: DWORD = 0;
pub const CLIP_DEFAULT_PRECIS: DWORD = 0;
pub const DEFAULT_QUALITY: DWORD = 0;
pub const FIXED_PITCH: DWORD = 1;
pub const FF_MODERN: DWORD = 48;
pub const FF_DONTCARE: DWORD = 0;

pub const GWLP_USERDATA: i32 = -21;
pub const GWL_STYLE: i32 = -16;

pub const ODS_SELECTED: UINT = 0x0001;
pub const ODS_DISABLED: UINT = 0x0004;
pub const ODT_BUTTON: UINT = 4;
pub const ODT_COMBOBOX: UINT = 3;

pub const DT_LEFT: UINT = 0x0000;
pub const DT_CENTER: UINT = 0x0001;
pub const DT_RIGHT: UINT = 0x0002;
pub const DT_VCENTER: UINT = 0x0004;
pub const DT_SINGLELINE: UINT = 0x0020;
pub const DT_END_ELLIPSIS: UINT = 0x00008000;
pub const DT_NOPREFIX: UINT = 0x00000800;

pub const TRANSPARENT: i32 = 1;
pub const PS_SOLID: i32 = 0;

pub const CP_ACP: UINT = 0;
pub const CP_UTF8: UINT = 65001;

pub const MB_ERR_INVALID_CHARS: DWORD = 0x00000008;

// 文件 / 串口
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;

pub const PURGE_TXABORT: DWORD = 0x0001;
pub const PURGE_RXABORT: DWORD = 0x0002;
pub const PURGE_TXCLEAR: DWORD = 0x0004;
pub const PURGE_RXCLEAR: DWORD = 0x0008;

pub const EV_RXCHAR: DWORD = 0x0001;
pub const EV_ERR: DWORD = 0x0080;

pub const NOPARITY: u8 = 0;
pub const ODDPARITY: u8 = 1;
pub const EVENPARITY: u8 = 2;
pub const MARKPARITY: u8 = 3;
pub const SPACEPARITY: u8 = 4;

pub const ONESTOPBIT: u8 = 0;
pub const ONE5STOPBITS: u8 = 1;
pub const TWOSTOPBITS: u8 = 2;

pub const DTR_CONTROL_DISABLE: u32 = 0;
pub const DTR_CONTROL_ENABLE: u32 = 1;
pub const DTR_CONTROL_HANDSHAKE: u32 = 2;
pub const RTS_CONTROL_DISABLE: u32 = 0;
pub const RTS_CONTROL_ENABLE: u32 = 1;
pub const RTS_CONTROL_HANDSHAKE: u32 = 2;

pub const SETDTR: DWORD = 5;
pub const CLRDTR: DWORD = 6;
pub const SETRTS: DWORD = 3;
pub const CLRRTS: DWORD = 4;

pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_IO_PENDING: DWORD = 997;
pub const ERROR_IO_INCOMPLETE: DWORD = 996;
pub const ERROR_OPERATION_ABORTED: DWORD = 995;
pub const ERROR_DEVICE_NOT_CONNECTED: DWORD = 1167;
pub const ERROR_INVALID_HANDLE: DWORD = 6;

pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;

// ---------------------------------------------------------------- kernel32
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?HANDLE;
pub const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HMODULE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

pub extern "kernel32" fn InitializeCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub extern "kernel32" fn EnterCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub extern "kernel32" fn LeaveCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub extern "kernel32" fn DeleteCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(
    nCount: DWORD,
    lpHandles: [*]const HANDLE,
    bWaitAll: BOOL,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetupComm(hFile: HANDLE, dwInQueue: DWORD, dwOutQueue: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCommState(hFile: HANDLE, lpDCB: *DCB) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetCommState(hFile: HANDLE, lpDCB: *DCB) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetCommTimeouts(hFile: HANDLE, lpCommTimeouts: *COMMTIMEOUTS) callconv(.winapi) BOOL;
pub extern "kernel32" fn PurgeComm(hFile: HANDLE, dwFlags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ClearCommError(hFile: HANDLE, lpErrors: ?*DWORD, lpStat: ?*COMSTAT) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitCommEvent(hFile: HANDLE, lpEvtMask: *DWORD, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn EscapeCommFunction(hFile: HANDLE, dwFunc: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn QueryDosDeviceW(
    lpDeviceName: ?LPCWSTR,
    lpTargetPath: [*]u16,
    ucchMax: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn MultiByteToWideChar(
    CodePage: UINT,
    dwFlags: DWORD,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: i32,
    lpWideCharStr: ?[*]u16,
    cchWideChar: i32,
) callconv(.winapi) i32;
pub extern "kernel32" fn WideCharToMultiByte(
    CodePage: UINT,
    dwFlags: DWORD,
    lpWideCharStr: [*]const u16,
    cchWideChar: i32,
    lpMultiByteStr: ?[*]u8,
    cbMultiByte: i32,
    lpDefaultChar: ?[*]const u8,
    lpUsedDefaultChar: ?*BOOL,
) callconv(.winapi) i32;
pub extern "kernel32" fn IsDBCSLeadByteEx(CodePage: UINT, TestChar: u8) callconv(.winapi) BOOL;

// ---------------------------------------------------------------- user32
pub const ARROW_POINT: u8 = 0; // 占位，避免误用

pub extern "imm32" fn ImmAssociateContext(hWnd: HWND, hIMC: ?HANDLE) callconv(.winapi) ?HANDLE;

pub const INITCOMMONCONTROLSEX = extern struct { dwSize: DWORD, dwICC: DWORD };
pub const ICC_BAR_CLASSES: DWORD = 0x00000004;
pub extern "comctl32" fn InitCommonControlsEx(picci: *const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;

pub const SBARS_SIZEGRIP: DWORD = 0x0100;
pub const SB_SETPARTS: UINT = 0x0404;
pub const SB_SETTEXTW: UINT = 0x040B;
pub const STATUSCLASS = "msctls_statusbar32";

pub extern "user32" fn CreateMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn SetMenu(hWnd: HWND, hMenu: ?HMENU) callconv(.winapi) BOOL;

pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) WORD;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*const anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
/// 空闲等待：等到「有消息」或超时（`QS_ALLINPUT` = 键鼠/重绘/定时器等全部输入类消息）。
/// `App.next` 在没有动画时用它替代忙等，让 CPU 真正闲下来。
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    nCount: DWORD,
    pHandles: ?*const HANDLE,
    dwMilliseconds: DWORD,
    dwWakeMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) DWORD;
pub const QS_ALLINPUT: DWORD = 0x04FF;
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;
pub extern "user32" fn MoveWindow(hWnd: HWND, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CXVSCROLL: i32 = 2;
pub const SM_CYSCREEN: i32 = 1;
/// 修饰键状态（高位为按下）。VK 与 `types.Key` 同值。
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
pub const VK_SHIFT: i32 = 0x10;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_MENU: i32 = 0x12;
pub const VK_LWIN: i32 = 0x5B;
pub extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.winapi) BOOL;
pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindow(hWnd: HWND, uCmd: UINT) callconv(.winapi) ?HWND;
pub const GW_CHILD: UINT = 5;
pub extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT) callconv(.winapi) i32;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: LPCWSTR) callconv(.winapi) ?HICON;
pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
pub extern "user32" fn GetSysColorBrush(nIndex: i32) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn DrawTextW(hdc: ?HDC, lpchText: [*:0]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowLongW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;

// x86 上没有 SetWindowLongPtrW，按指针宽度选择
pub fn setWindowLongPtr(hwnd: HWND, index: i32, value: isize) isize {
    return SetWindowLongW(hwnd, index, value);
}
pub fn getWindowLongPtr(hwnd: HWND, index: i32) isize {
    return GetWindowLongW(hwnd, index);
}

// ---------------------------------------------------------------- 剪贴板
pub const CF_UNICODETEXT: u32 = 13;

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------- winsock2
pub const SOCKADDR_IN = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8,
};
pub const AF_INET: i32 = 2;
pub const SOCK_STREAM: i32 = 1;
pub const IPPROTO_TCP: i32 = 6;
pub const INVALID_SOCKET: usize = std.math.maxInt(usize);
pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(.winapi) usize;
pub extern "ws2_32" fn bind(s: usize, name: *const SOCKADDR_IN, namelen: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(s: usize, backlog: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn accept(s: usize, addr: ?*anyopaque, addrlen: ?*i32) callconv(.winapi) usize;
pub extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) i32;

pub fn htons(v: u16) u16 {
    return (v >> 8) | (v << 8);
}

// ---------------------------------------------------------------- gdi32
pub extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: LPCWSTR,
) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn DeleteObject(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn CreatePen(style: i32, width: i32, color: DWORD) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) ?HANDLE;
pub const WHITE_BRUSH: i32 = 0;
pub const BLACK: DWORD = 0x00000000;
pub const WHITE: DWORD = 0x00FFFFFF;
pub extern "gdi32" fn RoundRect(hdc: HDC, l: i32, t: i32, r: i32, b: i32, w: i32, h: i32) callconv(.winapi) BOOL;
pub extern "gdi32" fn MoveToEx(hdc: HDC, x: i32, y: i32, p: ?*POINT) callconv(.winapi) BOOL;
pub extern "gdi32" fn LineTo(hdc: HDC, x: i32, y: i32) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(hdc: HDC, rc: *const RECT, brush: HBRUSH) callconv(.winapi) i32;
pub extern "user32" fn FrameRect(hdc: HDC, rc: *const RECT, brush: HBRUSH) callconv(.winapi) i32;
pub extern "kernel32" fn SetFilePointer(hFile: HANDLE, lDistanceToMove: LONG, lpDistanceToMoveHigh: ?*LONG, dwMoveMethod: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileSize(hFile: HANDLE, lpFileSizeHigh: ?*DWORD) callconv(.winapi) DWORD;

pub const OFN_HIDEREADONLY: DWORD = 0x00000004;
pub const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
pub const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
pub const OFN_FILEMUSTEXIST: DWORD = 0x00001000;

pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE,
    lpstrFilter: ?LPCWSTR,
    lpstrCustomFilter: ?[*]u16,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: [*]u16,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*]u16,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?LPCWSTR,
    lpstrTitle: ?LPCWSTR,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?LPCWSTR,
    lCustData: usize,
    lpfnHook: ?*const anyopaque,
    lpTemplateName: ?LPCWSTR,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};
pub extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "shell32" fn ShellExecuteW(hwnd: ?HWND, lpOperation: ?LPCWSTR, lpFile: ?LPCWSTR, lpParameters: ?LPCWSTR, lpDirectory: ?LPCWSTR, nShowCmd: i32) callconv(.winapi) ?HANDLE;

pub const HWND_TOPMOST: ?HWND = @ptrFromInt(std.math.maxInt(usize));
pub const HWND_NOTOPMOST: ?HWND = @ptrFromInt(std.math.maxInt(usize) - 1);
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetParent(hWndChild: HWND, hWndNewParent: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) i32;
pub extern "gdi32" fn GetDeviceCaps(hdc: HDC, index: i32) callconv(.winapi) i32;
pub const LOGPIXELSX: i32 = 88;

// ---------------------------------------------------------------- 便捷函数
pub fn loword(v: usize) u16 {
    return @truncate(v);
}
pub fn hiword(v: usize) u16 {
    return @truncate(v >> 16);
}

/// 把 zig 字符串转成宽字符写入调用方缓冲，返回以 0 结尾的切片。
pub fn narrowToWide(buf: []u16, s: []const u8) [:0]const u16 {
    if (buf.len == 0) {
        const empty_buf = [_:0]u16{};
        return &empty_buf;
    }
    const n = MultiByteToWideChar(CP_UTF8, 0, s.ptr, @intCast(s.len), buf.ptr, @intCast(buf.len - 1));
    const len: usize = if (n > 0) @intCast(n) else 0;
    buf[len] = 0;
    return buf[0..len :0];
}

// ---------------------------------------------------------------- ZZUI 里程碑 1 追加
// 窗口 / 消息
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const PM_REMOVE: UINT = 0x0001;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_CHAR: UINT = 0x0102;
/// 文件拖放（需 `DragAcceptFiles(hwnd, TRUE)` 才会收到）。`wParam` 是 HDROP。
pub const WM_DROPFILES: UINT = 0x0233;
pub const VK_ESCAPE: UINT = 0x001B;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const IDC_ARROW: usize = 32512;

pub extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: UINT,
    wMsgFilterMax: UINT,
    wRemoveMsg: UINT,
) callconv(.winapi) BOOL;

// 位图 / DIB
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: UINT = 0;

pub const SIZE = extern struct { cx: LONG, cy: LONG };

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};
pub const RGBQUAD = extern struct { rgbBlue: u8, rgbGreen: u8, rgbRed: u8, rgbReserved: u8 };
pub const BITMAPINFO = extern struct { bmiHeader: BITMAPINFOHEADER, bmiColors: [1]RGBQUAD };

pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateDIBSection(
    hdc: HDC,
    pbmi: *const BITMAPINFO,
    usage: UINT,
    ppvBits: *?*anyopaque,
    hSection: ?HANDLE,
    offset: DWORD,
) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn BitBlt(
    hdcDest: HDC,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hdcSrc: HDC,
    x1: i32,
    y1: i32,
    rop: DWORD,
) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetTextExtentPoint32W(
    hdc: HDC,
    lpString: [*]const u16,
    c: i32,
    psizl: *SIZE,
) callconv(.winapi) BOOL;
pub extern "gdi32" fn TextOutW(
    hdc: HDC,
    x: i32,
    y: i32,
    lpString: [*]const u16,
    c: i32,
) callconv(.winapi) BOOL;
pub extern "gdi32" fn SaveDC(hdc: HDC) callconv(.winapi) i32;
pub extern "gdi32" fn RestoreDC(hdc: HDC, nSavedDC: i32) callconv(.winapi) BOOL;

// ------------------------------------------------------------ shell32（文件拖放）
// 只需三个函数：开启接收拖放、枚举拖入的文件、结束。`shell32.dll` 是系统组件，
// 链接它只多一项导入表（几十字节），不是静态拷贝。
pub extern "shell32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) callconv(.winapi) void;
pub extern "shell32" fn DragQueryFileW(hDrop: HANDLE, iFile: UINT, lpszFile: [*]u16, cch: UINT) callconv(.winapi) UINT;
pub extern "shell32" fn DragFinish(hDrop: HANDLE) callconv(.winapi) void;
pub extern "gdi32" fn IntersectClipRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) i32;

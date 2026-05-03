import os, sys, struct, time, signal, traceback, collections, msvcrt, logging
import numpy as np
from pathlib import Path
import asyncio
from playwright.async_api import async_playwright
import cv2

# Persistent file-based logging for post-mortem debugging
_log_dir = Path(__file__).parent
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(_log_dir / "server.log", encoding="utf-8"),
    ]
)
_logger = logging.getLogger("MT5Browser")

from rich.live import Live
from rich.table import Table
from rich.panel import Panel
from rich.layout import Layout
from rich.console import Console
from rich.text import Text

import json

FRAME_WIDTH, FRAME_HEIGHT = 1280, 720
TARGET_FPS = 60
FRAME_INTERVAL = 1.0 / TARGET_FPS
STATE_OFFLINE, STATE_READY, STATE_RUNNING, STATE_PAUSED = 0, 1, 2, 3

_shutdown = False
def _sig(s, f):
    global _shutdown; _shutdown = True
signal.signal(signal.SIGINT, _sig)
signal.signal(signal.SIGTERM, _sig)

g_state = {
    "url": "Initializing...",
    "status": "Starting up",
    "fps": "0.0",
    "canvas": "1280x720",
    "mouse": "0,0",
    "logs": collections.deque(maxlen=10),
    "tabs": 1,
    "ui_focus": "PAGE"
}

def log_msg(msg):
    ts = time.strftime("%H:%M:%S")
    g_state["logs"].append(f"[{ts}] {msg}")
    _logger.info(msg)
    
def get_layout():
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=4),
        Layout(name="main"),
        Layout(name="logs", size=14)
    )
    
    header = Table.grid(expand=True)
    header.add_column(justify="center", ratio=1)
    header.add_row("[bold cyan]MT5 PiP Browser - Playwright Backend Engine[/]")
    header.add_row("[dim]Hotkeys: [+] Res UP  [-] Res DOWN  [R] Refresh  [B] Back  [U] Enter URL  [Q] Quit[/]")
    layout["header"].update(Panel(header))
    
    table = Table(show_header=True, header_style="bold magenta", expand=True)
    table.add_column("Metric", style="dim", width=25)
    table.add_column("Value")
    
    table.add_row("Status", f"[green]{g_state['status']}[/]" if "Running" in g_state['status'] else f"[yellow]{g_state['status']}[/]")
    table.add_row("Active URL", f"[bold blue]{g_state['url']}[/]")
    table.add_row("Tabs Open", str(g_state['tabs']))
    table.add_row("Internal DOM Res", f"{FRAME_WIDTH}x{FRAME_HEIGHT}")
    table.add_row("MT5 Render Target", g_state['canvas'])
    table.add_row("Framerate (FPS)", g_state['fps'])
    table.add_row("Virtual Mouse", g_state['mouse'])
    
    layout["main"].update(Panel(table, title="[bold]System Telemetry[/]"))
    
    log_text = Text("\n".join(g_state["logs"]))
    layout["logs"].update(Panel(log_text, title="[bold]System Logs[/]", style="white"))
    
    return layout

def write_atomic(path: Path, data: bytes):
    tmp = path.with_suffix(".tmp")
    try:
        with open(tmp, "wb") as f: f.write(data)
        os.replace(str(tmp), str(path))
    except Exception as e:
        _logger.warning(f"write_atomic failed for {path.name}: {e}")

def read_safe(path: Path, size: int):
    try:
        with open(path, "rb") as f: d = f.read()
        return d if len(d) >= size else None
    except Exception:
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# COMPLETE VIRTUAL KEYCODE -> PLAYWRIGHT KEY MAPPING
# Covers the full Windows VK_* range that MT5 sends via GetAsyncKeyState
# ═══════════════════════════════════════════════════════════════════════════════

# Maps (vk_code, shift) -> playwright key string
# For simple chars, we compute dynamically; this table covers non-obvious ones
VK_SPECIAL = {
    8:   "Backspace",
    9:   "Tab",
    13:  "Enter",
    27:  "Escape",
    32:  " ",
    33:  "PageUp",
    34:  "PageDown",
    35:  "End",
    36:  "Home",
    37:  "ArrowLeft",
    38:  "ArrowUp",
    39:  "ArrowRight",
    40:  "ArrowDown",
    45:  "Insert",
    46:  "Delete",
    112: "F1",  113: "F2",  114: "F3",  115: "F4",
    116: "F5",  117: "F6",  118: "F7",  119: "F8",
    120: "F9",  121: "F10", 122: "F11", 123: "F12",
}

# Windows VK codes for punctuation keys -> (normal_char, shifted_char)
VK_PUNCT = {
    186: (";", ":"),   # VK_OEM_1
    187: ("=", "+"),   # VK_OEM_PLUS
    188: (",", "<"),   # VK_OEM_COMMA
    189: ("-", "_"),   # VK_OEM_MINUS
    190: (".", ">"),   # VK_OEM_PERIOD
    191: ("/", "?"),   # VK_OEM_2
    192: ("`", "~"),   # VK_OEM_3
    219: ("[", "{"),   # VK_OEM_4
    220: ("\\", "|"),  # VK_OEM_5
    221: ("]", "}"),   # VK_OEM_6
    222: ("'", '"'),   # VK_OEM_7
}

# Number row: shift produces symbols
SHIFT_DIGITS = {
    48: ")", 49: "!", 50: "@", 51: "#", 52: "$",
    53: "%", 54: "^", 55: "&", 56: "*", 57: "(",
}


def vk_to_key(keycode, shift, ctrl):
    """Convert a Windows virtual keycode + modifier state to a Playwright key string.
    Returns (key_string, use_type) where use_type=True means use keyboard.type()
    for proper input field handling, False means use keyboard.press()."""

    # Ctrl combos — always use press() with modifier prefix
    if ctrl:
        if 65 <= keycode <= 90:
            letter = chr(keycode).lower()
            return f"Control+{letter}", False
        return None, False

    # Special/navigation keys
    if keycode in VK_SPECIAL:
        return VK_SPECIAL[keycode], False

    # A-Z letters
    if 65 <= keycode <= 90:
        ch = chr(keycode) if shift else chr(keycode).lower()
        return ch, True

    # 0-9 number row
    if 48 <= keycode <= 57:
        if shift:
            return SHIFT_DIGITS[keycode], True
        return chr(keycode), True

    # Numpad 0-9
    if 96 <= keycode <= 105:
        return chr(keycode - 48), True

    # Numpad operators
    numpad_ops = {106: "*", 107: "+", 109: "-", 110: ".", 111: "/"}
    if keycode in numpad_ops:
        return numpad_ops[keycode], True

    # Punctuation keys
    if keycode in VK_PUNCT:
        normal, shifted = VK_PUNCT[keycode]
        return (shifted if shift else normal), True

    return None, False


# Navigation lock — prevents URL sync from writing stale URLs during navigation
_nav_lock = False

async def safe_navigate(page, url, ipc_path=None):
    """Navigate with proper error handling and URL sync lock."""
    global _nav_lock
    _nav_lock = True
    try:
        # Use 'commit' (least strict) — just waits for server response header,
        # doesn't wait for full DOM/load which can timeout on heavy pages
        resp = await page.goto(url, timeout=60000, wait_until="commit")
        # Give the page a moment to settle for the first screenshot
        await page.wait_for_timeout(500)

        final_url = page.url
        # Don't sync Chromium internal error pages back to the URL bar
        if final_url.startswith("chrome-error://") or final_url == "about:blank":
            log_msg(f"Nav failed (error page): {url[:60]}")
            # Keep showing what the user intended, not the error URL
            g_state["url"] = url
        else:
            g_state["url"] = final_url
            if ipc_path:
                write_atomic(ipc_path / "url.bin", final_url.encode('utf-8'))
            log_msg(f"Navigated to: {final_url[:60]}")
    except Exception as e:
        log_msg(f"Nav error: {str(e)[:80]}")
        # Keep the intended URL visible even on failure
        g_state["url"] = url
    finally:
        _nav_lock = False


async def main():
    global _shutdown, FRAME_WIDTH, FRAME_HEIGHT
    appdata = os.environ.get("APPDATA", "")
    ipc = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files" / "MT5Browser"
    ipc.mkdir(parents=True, exist_ok=True)
    log_msg(f"IPC Bound: {ipc}")

    fc = 0
    fps_c = 0
    fps_t = time.time()
    last_x, last_y, last_flags = -1, -1, 0
    target_w, target_h = 640, 360
    
    # Track consecutive screenshot failures to avoid log spam
    screenshot_fail_count = 0
    MAX_SCREENSHOT_FAILS_LOG = 3
    
    last_screenshot_bytes = b""
    
    write_atomic(ipc / "status.bin", struct.pack("<I", STATE_READY))

    # Create persistent profile directory for logins
    user_data_dir = ipc / "Profile"
    user_data_dir.mkdir(parents=True, exist_ok=True)
    
    # Load settings from MQL5
    config = {
        "homepage": "https://www.google.com",
        "width": 1280,
        "height": 720,
        "dark_mode": True,
        "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
    }
    config_file = ipc / "config.json"
    if config_file.exists():
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                config.update(json.load(f))
        except Exception as e:
            log_msg(f"Failed to read config.json: {e}")
            
    FRAME_WIDTH = max(320, min(config.get("width", 1280), 3840))
    FRAME_HEIGHT = max(240, min(config.get("height", 720), 2160))
    color_scheme = "dark" if config.get("dark_mode", True) else "light"
    user_agent = config.get("user_agent", config["user_agent"])
    homepage = config.get("homepage", "https://www.google.com")

    with Live(get_layout(), refresh_per_second=4, screen=True) as live:
        async with async_playwright() as p:
            g_state["status"] = "Launching Persistent Chromium"
            live.update(get_layout())
            
            context = await p.chromium.launch_persistent_context(
                user_data_dir=user_data_dir,
                headless=False,
                viewport={'width': FRAME_WIDTH, 'height': FRAME_HEIGHT},
                user_agent=user_agent,
                color_scheme=color_scheme,
                java_script_enabled=True,
                bypass_csp=True,
                ignore_https_errors=True,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                    "--window-position=-32000,-32000",
                    "--window-size=1,1",
                    "--autoplay-policy=no-user-gesture-required",
                    "--disable-web-security",
                    "--allow-running-insecure-content",
                    "--ignore-certificate-errors",
                    "--disable-features=IsolateOrigins,site-per-process,OptimizationGuideModelDownloading,OptimizationHints",
                    "--disable-site-isolation-trials",
                    "--disable-client-side-phishing-detection"
                ]
            )

            if len(context.pages) > 0:
                page = context.pages[0]
            else:
                page = await context.new_page()
            
            # Anti-bot stealth injection
            await page.add_init_script("""
                Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
                Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
                Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
                window.chrome = {runtime: {}, loadTimes: function(){}, csi: function(){}};
                const originalQuery = window.navigator.permissions.query;
                window.navigator.permissions.query = (parameters) => (
                    parameters.name === 'notifications' ? Promise.resolve({state: Notification.permission}) : originalQuery(parameters)
                );
            """)
            
            g_state["url"] = homepage
            g_state["status"] = "Loading"
            log_msg("Loading initial URL...")
            live.update(get_layout())
            
            # Use safe navigation instead of fire-and-forget
            asyncio.create_task(safe_navigate(page, homepage, ipc))
            
            g_state["status"] = "Running"
            write_atomic(ipc / "status.bin", struct.pack("<I", STATE_RUNNING))
            
            while not _shutdown:
                t0 = time.perf_counter()
                
                # ─── TUI KEYBOARD COMMANDS ────────────────────────────────
                if msvcrt.kbhit():
                    char = msvcrt.getch()
                    if char in (b'q', b'Q'):
                        _shutdown = True
                    elif char == b'+':
                        FRAME_WIDTH = int(FRAME_WIDTH * 1.2)
                        FRAME_HEIGHT = int(FRAME_HEIGHT * 1.2)
                        asyncio.create_task(page.set_viewport_size({"width": FRAME_WIDTH, "height": FRAME_HEIGHT}))
                        log_msg(f"DOM Res scaled UP: {FRAME_WIDTH}x{FRAME_HEIGHT}")
                    elif char == b'-':
                        if FRAME_WIDTH > 640:
                            FRAME_WIDTH = int(FRAME_WIDTH / 1.2)
                            FRAME_HEIGHT = int(FRAME_HEIGHT / 1.2)
                            asyncio.create_task(page.set_viewport_size({"width": FRAME_WIDTH, "height": FRAME_HEIGHT}))
                            log_msg(f"DOM Res scaled DOWN: {FRAME_WIDTH}x{FRAME_HEIGHT}")
                    elif char in (b'r', b'R'):
                        asyncio.create_task(page.reload())
                        log_msg("TUI Command: Reload triggered")
                    elif char in (b'b', b'B'):
                        asyncio.create_task(page.go_back())
                        log_msg("TUI Command: Back triggered")
                    elif char in (b'u', b'U'):
                        live.stop()
                        print("\n=== TUI COMMAND INTERFACE ===")
                        new_url = input("Enter new URL or Search: ")
                        if new_url.strip():
                            if "." not in new_url and not new_url.startswith("http"):
                                new_url = "https://www.google.com/search?q=" + new_url
                            elif not new_url.startswith("http"):
                                new_url = "https://" + new_url
                            g_state["url"] = new_url
                            asyncio.create_task(safe_navigate(page, new_url, ipc))
                            log_msg(f"TUI Command: Navigating to {new_url}")
                        live.start()
                
                # ─── IPC PROCESSING ────────────────────────────────────────
                try:
                    # === CONTROL COMMANDS ===
                    control_file = ipc / "control.bin"
                    if control_file.exists():
                        # Require full 260 bytes to ensure MQL5 has finished writing the padded payload
                        cdata = read_safe(control_file, 260)
                        if cdata:
                            cmd = struct.unpack("<I", cdata[:4])[0]
                            if cmd != 0:
                                # Extract payload (everything after the 4-byte cmd, up to first null)
                                payload = ""
                                if len(cdata) > 4:
                                    payload = cdata[4:].split(b'\x00')[0].decode('utf-8', errors='ignore').strip()
                                # Clear the command file
                                write_atomic(control_file, struct.pack("<I", 0) + bytes(256))
                                
                                if cmd == 99:
                                    # Graceful shutdown signal from MQL5 OnDeinit
                                    log_msg("Received shutdown command from MT5.")
                                    _shutdown = True
                                    break

                                elif cmd == 5:
                                    # Navigate to URL
                                    if not payload.startswith("http"): payload = "https://" + payload
                                    g_state["url"] = payload
                                    log_msg(f"Navigation triggered: {payload}")
                                    asyncio.create_task(safe_navigate(page, payload, ipc))
                                    
                                elif cmd == 6:
                                    # Switch tab
                                    tab_idx = int(payload)
                                    while len(context.pages) <= tab_idx:
                                        new_p = await context.new_page()
                                        asyncio.create_task(safe_navigate(new_p, "https://www.google.com", ipc))
                                    page = context.pages[tab_idx]
                                    await page.bring_to_front()
                                    g_state["tabs"] = len(context.pages)
                                    log_msg(f"Switched to Tab {tab_idx}")
                                    
                                elif cmd == 7:
                                    # Resize canvas natively (High-Fidelity Mode)
                                    try:
                                        w_str, h_str = payload.split(",")
                                        new_w, new_h = int(w_str), int(h_str)
                                        # Clamp size to prevent excessive memory allocation
                                        target_w = max(150, min(new_w, 2560))
                                        target_h = max(100, min(new_h, 1440))
                                        
                                        # Only resize Playwright if the difference is significant to debounce
                                        if abs(FRAME_WIDTH - target_w) > 10 or abs(FRAME_HEIGHT - target_h) > 10:
                                            FRAME_WIDTH, FRAME_HEIGHT = target_w, target_h
                                            g_state["canvas"] = f"{target_w}x{target_h}"
                                            asyncio.create_task(page.set_viewport_size({'width': target_w, 'height': target_h}))
                                    except Exception as e:
                                        log_msg(f"Resize error: {e}")
                                    
                                elif cmd == 8:
                                    try: await page.go_back(timeout=30000)
                                    except Exception as e: log_msg(f"Back nav error: {e}")
                                    
                                elif cmd == 9:
                                    try: await page.go_forward(timeout=30000)
                                    except Exception as e: log_msg(f"Forward nav error: {e}")
                                    
                                elif cmd == 10:
                                    try: await page.reload(timeout=30000)
                                    except Exception as e: log_msg(f"Reload error: {e}")

                                elif cmd == 11:
                                    # Scroll up
                                    try: await page.mouse.wheel(0, -500)
                                    except Exception as e: log_msg(f"Scroll up error: {e}")

                                elif cmd == 12:
                                    # Scroll down
                                    try: await page.mouse.wheel(0, 500)
                                    except Exception as e: log_msg(f"Scroll down error: {e}")

                                elif cmd == 13:
                                    # Double-click at current mouse position
                                    try:
                                        parts = payload.split(",")
                                        if len(parts) >= 2:
                                            dx = int(parts[0]) * (FRAME_WIDTH / target_w)
                                            dy = int(parts[1]) * (FRAME_HEIGHT / target_h)
                                            await page.mouse.dblclick(dx, dy)
                                    except Exception as e:
                                        log_msg(f"DblClick error: {e}")

                                elif cmd == 15:
                                    # Middle-click at position
                                    try:
                                        parts = payload.split(",")
                                        if len(parts) >= 2:
                                            mx = int(parts[0]) * (FRAME_WIDTH / target_w)
                                            my = int(parts[1]) * (FRAME_HEIGHT / target_h)
                                            await page.mouse.click(mx, my, button="middle")
                                    except Exception as e:
                                        log_msg(f"Middle-click error: {e}")

                                elif cmd == 16:
                                    # Explicit left click (guarantees fast clicks aren't dropped by polling)
                                    try:
                                        parts = payload.split(",")
                                        if len(parts) >= 2:
                                            dx = int(parts[0]) * (FRAME_WIDTH / target_w)
                                            dy = int(parts[1]) * (FRAME_HEIGHT / target_h)
                                            await page.mouse.click(dx, dy, button="left")
                                    except Exception as e:
                                        log_msg(f"Click error: {e}")

                                elif cmd == 17:
                                    # Navigate Home
                                    g_state["url"] = homepage
                                    asyncio.create_task(safe_navigate(page, homepage, ipc))

                                elif cmd == 18:
                                    # New Tab
                                    new_p = await context.new_page()
                                    asyncio.create_task(safe_navigate(new_p, homepage, ipc))
                                    page = new_p
                                    await page.bring_to_front()
                                    g_state["tabs"] = len(context.pages)
                                    log_msg(f"Opened New Tab (Total: {g_state['tabs']})")

                                elif cmd == 19:
                                    # Cycle Tabs
                                    pages = context.pages
                                    if len(pages) > 1:
                                        try:
                                            idx = pages.index(page)
                                            next_idx = (idx + 1) % len(pages)
                                            page = pages[next_idx]
                                            await page.bring_to_front()
                                            log_msg(f"Cycled to Tab {next_idx + 1}/{len(pages)}")
                                        except ValueError: pass

                    # === INPUT (MOUSE + KEYBOARD) ===
                    data = read_safe(ipc / "input.bin", 16)
                    if data:
                        mx, my, flags, keycode = struct.unpack("<iiii", data)
                        
                        # Extract modifier state from flags
                        # Bit 0: left mouse down
                        # Bit 1: shift held
                        # Bit 2: right mouse down
                        # Bit 3: ctrl held
                        # Bit 4: alt held
                        shift = (flags & 2) != 0
                        ctrl  = (flags & 8) != 0
                        alt   = (flags & 16) != 0
                        
                        # ─── KEYBOARD INPUT ──────────────────────────
                        if keycode != 0:
                            # Clear the keycode immediately to prevent re-processing
                            write_atomic(ipc / "input.bin", struct.pack("<iiii", mx, my, flags, 0))
                            
                            key_str, use_type = vk_to_key(keycode, shift, ctrl)
                            
                            if key_str:
                                try:
                                    if use_type and not ctrl:
                                        # Printable character — use type() for proper
                                        # input field handling (triggers input events)
                                        await page.keyboard.type(key_str)
                                    else:
                                        # Navigation/special key or Ctrl combo — use press()
                                        await page.keyboard.press(key_str)
                                except Exception as e:
                                    log_msg(f"Key error ({keycode}): {e}")
                        
                        # ─── MOUSE MOVEMENT ──────────────────────────
                        if mx != last_x or my != last_y:
                            pw_x = int(mx * (FRAME_WIDTH / target_w))
                            pw_y = int(my * (FRAME_HEIGHT / target_h))
                            await page.mouse.move(pw_x, pw_y)
                            last_x, last_y = mx, my
                            g_state["mouse"] = f"{pw_x},{pw_y}"
                        
                        # ─── MOUSE BUTTON STATE CHANGES ──────────────
                        left_down = flags & 1
                        last_left_down = last_flags & 1
                        if left_down and not last_left_down:
                            await page.mouse.down(button="left")
                        elif not left_down and last_left_down:
                            await page.mouse.up(button="left")
                        
                        right_down = flags & 4
                        last_right_down = last_flags & 4
                        if right_down and not last_right_down:
                            await page.mouse.down(button="right")
                        elif not right_down and last_right_down:
                            await page.mouse.up(button="right")
                        
                        last_flags = flags

                    # === FRAME CAPTURE ===
                    try:
                        # Dropped quality to 50 for much faster compression/decompression to hit 60fps
                        screenshot_bytes = await page.screenshot(type='jpeg', quality=50)
                        screenshot_fail_count = 0  # Reset on success
                    except Exception as e:
                        screenshot_fail_count += 1
                        if screenshot_fail_count <= MAX_SCREENSHOT_FAILS_LOG:
                            log_msg(f"Screenshot failed ({screenshot_fail_count}x): {str(e)[:60]}")
                        # Skip frame rendering on failure, sleep briefly
                        await asyncio.sleep(0.1)
                        continue

                    img = cv2.imdecode(np.frombuffer(screenshot_bytes, np.uint8), cv2.IMREAD_COLOR)
                    
                    if img is not None:
                        if img.shape[1] != target_w or img.shape[0] != target_h:
                            img = cv2.resize(img, (target_w, target_h), interpolation=cv2.INTER_AREA)
                            
                        b = img[:, :, 0].astype(np.uint32)
                        g = img[:, :, 1].astype(np.uint32)
                        r = img[:, :, 2].astype(np.uint32)
                        
                        argb = np.full((target_h, target_w), 0xFF000000, dtype=np.uint32)
                        argb |= (r << 16) | (g << 8) | b
                        
                        fc += 1
                        hdr = struct.pack("<III", fc, target_w, target_h)
                        write_atomic(ipc / "frame.bin", hdr + argb.flatten().tobytes())
                        
                        # Write current URL back to MT5 for URL bar sync
                        # Skip during active navigation to prevent stale URL overwrite
                        # Skip chrome-error:// and about:blank URLs
                        if not _nav_lock:
                            try:
                                cur_url = page.url
                                if (cur_url != g_state["url"]
                                        and not cur_url.startswith("chrome-error://")
                                        and cur_url != "about:blank"):
                                    g_state["url"] = cur_url
                                    write_atomic(ipc / "url.bin", cur_url.encode('utf-8'))
                            except Exception as e:
                                log_msg(f"URL sync error: {e}")
                        
                        fps_c += 1
                        now = time.time()
                        if now - fps_t >= 1.0:
                            g_state["fps"] = f"{fps_c/(now-fps_t):.1f}"
                            fps_c = 0; fps_t = now
                            live.update(get_layout())

                except Exception as e:
                    if "Target page, context or browser has been closed" not in str(e):
                        log_msg(f"Frame warning: {e}")
                
                sl = FRAME_INTERVAL - (time.perf_counter() - t0)
                if sl > 0: await asyncio.sleep(sl)
                else: await asyncio.sleep(0.001)

            log_msg("Shutting down Chromium context...")
            await context.close()
            write_atomic(ipc / "status.bin", struct.pack("<I", STATE_OFFLINE))
            log_msg("Shutdown complete.")

if __name__ == "__main__":
    asyncio.run(main())

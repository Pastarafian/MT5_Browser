"""
MT5Browser Launcher — Watches for start.signal from MQL5 and auto-launches the browser server.
Run this ONCE and leave it running. It will auto-start the server whenever the EA is attached.

Usage:
  pythonw launcher.pyw          (silent, no console window)
  python  launcher.pyw          (with console for debugging)
"""
import os, sys, time, subprocess, struct
from pathlib import Path

# IPC directory shared with MQL5
APPDATA = os.environ.get("APPDATA", "")
IPC_DIR = Path(APPDATA) / "MetaQuotes" / "Terminal" / "Common" / "Files" / "MT5Browser"
IPC_DIR.mkdir(parents=True, exist_ok=True)

SIGNAL_FILE  = IPC_DIR / "start.signal"
STATUS_FILE  = IPC_DIR / "status.bin"
STOP_SIGNAL  = IPC_DIR / "stop.signal"
SCRIPT_DIR   = Path(__file__).parent
SERVER_SCRIPT = SCRIPT_DIR / "python" / "browser_server.py"

STATE_OFFLINE, STATE_READY, STATE_RUNNING = 0, 1, 2

server_process = None

def read_status():
    """Read the current server state from status.bin."""
    try:
        data = STATUS_FILE.read_bytes()
        if len(data) >= 4:
            return struct.unpack("<I", data[:4])[0]
    except Exception:
        pass
    return STATE_OFFLINE

def is_server_alive():
    """Check if the server process is still running."""
    global server_process
    if server_process is None:
        return False
    return server_process.poll() is None

def launch_server():
    """Launch browser_server.py as a subprocess."""
    global server_process
    if is_server_alive():
        print(f"[Launcher] Server already running (PID {server_process.pid}), skipping.")
        return
    
    print(f"[Launcher] Launching: python {SERVER_SCRIPT}")
    try:
        server_process = subprocess.Popen(
            [sys.executable, str(SERVER_SCRIPT)],
            cwd=str(SCRIPT_DIR / "python"),
            creationflags=subprocess.CREATE_NEW_CONSOLE
        )
        print(f"[Launcher] Server started (PID {server_process.pid})")
    except Exception as e:
        print(f"[Launcher] ERROR: Failed to launch server: {e}")

def stop_server():
    """Stop the server gracefully via cmd=99, with fallback to terminate."""
    global server_process
    if not is_server_alive():
        print("[Launcher] Server not running, nothing to stop.")
        return
    
    # Write shutdown command (cmd=99) to control.bin
    control_file = IPC_DIR / "control.bin"
    try:
        tmp = control_file.with_suffix(".tmp")
        with open(tmp, "wb") as f:
            f.write(struct.pack("<I", 99))  # cmd=99 shutdown
            f.write(bytes(256))             # padding
        os.replace(str(tmp), str(control_file))
        print("[Launcher] Sent shutdown signal (cmd=99)")
    except Exception as e:
        print(f"[Launcher] Failed to write shutdown: {e}")
    
    # Wait up to 5 seconds for graceful shutdown
    for _ in range(50):
        if not is_server_alive():
            print("[Launcher] Server stopped gracefully.")
            server_process = None
            return
        time.sleep(0.1)
    
    # Force kill if still alive
    print("[Launcher] Server didn't stop gracefully, terminating...")
    try:
        server_process.terminate()
        server_process.wait(timeout=3)
    except Exception:
        server_process.kill()
    server_process = None
    print("[Launcher] Server terminated.")


def main():
    print("=" * 50)
    print("  MT5Browser Launcher - Signal Watcher")
    print("=" * 50)
    print(f"  IPC Dir: {IPC_DIR}")
    print(f"  Server:  {SERVER_SCRIPT}")
    print(f"  Watching for: start.signal / stop.signal")
    print("=" * 50)
    
    if not SERVER_SCRIPT.exists():
        print(f"\nERROR: Server script not found at: {SERVER_SCRIPT}")
        print("Ensure the launcher is in the MT5_Browser project root.")
        input("Press Enter to exit...")
        return
    
    while True:
        try:
            # Check for start signal from MQL5
            if SIGNAL_FILE.exists():
                print("\n[Launcher] Start signal detected!")
                try:
                    SIGNAL_FILE.unlink()  # Consume the signal
                except Exception:
                    pass
                launch_server()
            
            # Check for stop signal from MQL5 OnDeinit
            if STOP_SIGNAL.exists():
                print("\n[Launcher] Stop signal detected!")
                try:
                    STOP_SIGNAL.unlink()
                except Exception:
                    pass
                stop_server()
            
            # Monitor server health — restart if it crashed
            if server_process is not None and not is_server_alive():
                exit_code = server_process.returncode
                print(f"\n[Launcher] Server process exited (code {exit_code})")
                server_process = None
            
            time.sleep(0.5)  # Poll every 500ms
            
        except KeyboardInterrupt:
            print("\n[Launcher] Shutting down...")
            stop_server()
            break


if __name__ == "__main__":
    main()

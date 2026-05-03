# MT5_Browser 🌐

**A native, fully interactive Chromium browser engine built directly inside MetaTrader 5.**

MT5_Browser bridges the gap between the isolated MQL5 ecosystem and the modern web. By utilizing an asynchronous Python Playwright backend and a high-performance File I/O Inter-Process Communication (IPC) bridge, this Expert Advisor renders web pages, intercepts inputs (mouse/keyboard), and streams 60fps framebuffers directly onto the MT5 Chart Canvas.

No WebRequests, no simple URL redirects—this is a true "Dumb Terminal" rendering engine inside MT5.

## ✨ Features
* **Full Interactivity:** Supports mouse movement, clicks, scrolling, and keyboard input directly from the MT5 chart.
* **High-Fidelity Rendering:** Dynamic DPI scaling up to 60fps using OpenCV compression and atomic IPC pipelines.
* **Zero-DLL Architecture:** Operates entirely over `Common/Files` signaling. You do not need to enable "Allow DLL Imports".
* **Headless & Stealth:** Built with anti-bot injection (bypasses Cloudflare/Datadome) to safely load TradingView, Twitter, News sources, or even games (like Lichess or Doom).
* **Automated Lifecycle:** Drag the EA onto the chart to instantly boot the Python Chromium server. Remove the EA to gracefully kill the server.

## 🛠️ How It Works
1. **MQL5 Frontend (`MT5Browser.mq5`):** Acts as a dumb terminal. It listens for user inputs (clicks/keys) on the MT5 chart, translates them to screen coordinates, and writes them to atomic `.bin` files.
2. **Python Backend (`browser_server.py`):** An asynchronous Playwright server continuously watches the input buffers. It executes the interactions on a hidden Chromium instance, takes a JPEG screenshot, decodes it to an ARGB pixel array via OpenCV, and writes the framebuffer back to the IPC folder.
3. **The Bridge (`launcher.pyw`):** A lightweight watchdog that detects when the EA is attached (`start.signal`) or removed (`stop.signal`) to autonomously manage the Python lifecycle.

## 🚀 Installation & Usage

### Prerequisites
* Python 3.10+
* MetaTrader 5

### Setup
1. Clone this repository into your MT5 `Experts` or `Documents` folder.
2. Install the required Python dependencies:
   ```bash
   pip install -r python/requirements.txt
   playwright install chromium
   ```
3. Run the Python launcher (it will run silently in the background):
   ```bash
   pythonw launcher.pyw
   ```
4. Open **MetaEditor** (F4), open `mql5/Experts/MT5Browser.mq5`, and hit **F7 to compile**.

### Usage
Drag the `MT5Browser` Expert Advisor onto any MT5 chart.
In the Inputs tab, you can configure:
* **Homepage URL** (e.g., TradingView, Lichess, Google)
* **Display Width & Height** (Resolution of the browser on the chart)
* **Dark Mode** 
* **Custom User-Agent**

## ⚠️ Disclaimer
This is an experimental proof-of-concept for circumventing the sandbox limitations of MetaTrader 5. It is provided as-is.

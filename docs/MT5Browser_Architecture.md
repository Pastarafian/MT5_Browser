# MT5Browser: Institutional Web Intelligence Bridge

## Phase 1: Core Rendering Engine (The Viewport)
**Objective**: Build a 720p (1280x720) headless Chromium wrapper that streams framebuffers to an MT5 canvas at 30-60 FPS.

1. **Python Backend (`browser_server.py`)**: 
   - Uses `playwright.async_api` to launch headless Chromium.
   - Sets viewport to 1280x720.
   - Continuously captures screenshots via `page.screenshot(type='jpeg', quality=80)` or raw pixels.
   - Upgrades IPC to **Memory-Mapped Files (mmap)** to prevent SSD degradation at high resolution.
2. **MQL5 EA (`MT5Browser.mq5`)**:
   - Creates a 1280x720 `OBJ_BITMAP_LABEL` anchored to `CORNER_LEFT_LOWER`.
   - Reads the mmap buffer in `OnTimer` and updates the chart using `ResourceCreate`.
   - Uses `CHARTEVENT_MOUSE_MOVE` to send X/Y coordinates and clicks back to Python.

## Phase 2: Native MT5 UI & Interaction
**Objective**: Add tabs, minimize/maximize, and keyboard routing.
1. **Tabs & Hotbar**: MQL5 `OBJ_BUTTON`s along the top of the browser canvas to switch contexts in Playwright.
2. **Minimize to Hotbar**: A toggle button that shrinks the canvas to 50x50 pixels.
3. **Keyboard Routing**: Reusing the `GetAsyncKeyState` hardware-polling loop from MT5Doom to type into the browser (routing keystrokes to `page.keyboard.press()`).

## Phase 3: AI Intelligence Layer (MQClaw VLM/LLM)
**Objective**: Inject AI directly into the browsing experience.
1. **DOM Scraping Engine**: Python script that uses BeautifulSoup to extract the text of the currently active page.
2. **Local LLM Sentiment**: Feed extracted text into a local DeepSeek/Llama model via Ollama. 
3. **MQL5 Sentiment Label**: Print real-time "Bullish/Bearish" scores on the MT5 chart based on what the user is currently reading.

## Phase 4: Algorithmic Triggers (No-API Trading)
**Objective**: Execute trades based on visual DOM changes.
1. **MutationObserver Injection**: Inject JS into the Playwright page: `new MutationObserver(() => {...})`.
2. **IPC Trigger**: When a specific element (e.g., an economic calendar row) changes class to "red" or updates its innerHTML, JS calls a bound Python function.
3. **MQL5 Execution**: Python writes `CMD_TRADE_SELL` to `control.bin`. MQL5 reads it and executes an `OrderSend()`.

## Phase 5: OCR & Crosshair Sync
1. **Tesseract OCR**: Run `pytesseract` over the Playwright framebuffer every 500ms to detect keyword spikes (e.g., "LIQUIDATION").
2. **TradingView Sync**: Inject JS into TradingView to capture `mousemove` event coordinates, map them to standard time/price, and send to MT5 to draw `OBJ_VLINE` and `OBJ_HLINE`.

## Setup Requirements
```bash
pip install playwright pytesseract mmap
playwright install chromium
```

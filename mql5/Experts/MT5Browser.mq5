//+------------------------------------------------------------------+
//| MT5Browser.mq5 — Native MQL5 Chromium Renderer                   |
//| Streams framebuffers from Playwright via Common Files IPC        |
//+------------------------------------------------------------------+
#property copyright "VegaTech"
#property version   "4.00"
#property strict

//--- Backend state codes (must match Python)
#define STATE_OFFLINE 0
#define STATE_READY   1
#define STATE_RUNNING 2

//--- User Settings
input string InpProjectPath   = "C:\\Users\\fakej\\Documents\\MT5Doom\\MT5_Browser";
input string InpHomePage       = "https://www.google.com"; // Default Homepage URL
input int    InpDisplayWidth   = 640;                      // Display Width (pixels on chart)
input int    InpDisplayHeight  = 360;                      // Display Height (pixels on chart)
input bool   InpDarkMode       = true;                     // Force Dark Mode
input string InpUserAgent      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"; // Custom User-Agent

#define IPC_SUBDIR        "MT5Browser"
#define FRAME_FILE        "frame.bin"
#define FRAME_WIDTH       1280
#define FRAME_HEIGHT      720
#define FRAME_HEADER_SIZE 3
#define OBJ_SCREEN        "BrowserScreen"
#define RES_NAME          "::BrowserFrame"
#define OBJ_BTN_MIN       "BrowserBtnMin"
#define OBJ_URL_BAR       "BrowserURLBar"
#define OBJ_BTN_BACK      "BrowserBtnBack"
#define OBJ_BTN_FWD       "BrowserBtnFwd"
#define OBJ_BTN_REF       "BrowserBtnRef"
#define OBJ_BTN_UP        "BrowserBtnUp"
#define OBJ_BTN_DWN       "BrowserBtnDwn"

int g_timer_ms = 16;
uint g_last_frame_counter = 0;
bool g_minimized = false;

// Scaled render target dimensions
int g_target_w = 0;
int g_target_h = 0;

// Mouse state
int g_last_mx = 0;
int g_last_my = 0;
int g_last_mflags = 0;

// Double-click detection
uint g_last_click_time = 0;
int  g_last_click_x = 0;
int  g_last_click_y = 0;
#define DBLCLICK_THRESHOLD_MS  400
#define DBLCLICK_THRESHOLD_PX  6

// Track whether the URL bar is actively focused so we don't
// forward keystrokes to the browser canvas while typing a URL
bool g_url_bar_focused = false;


void SendControlCommand(int cmd, string payload)
{
   int h = INVALID_HANDLE;
   for(int i=0; i<100; i++)
   {
      h = FileOpen(IPC_SUBDIR + "\\control.bin", FILE_WRITE | FILE_BIN | FILE_SHARE_READ | FILE_COMMON);
      if(h != INVALID_HANDLE) break;
      Sleep(1);
   }
   
   if(h != INVALID_HANDLE)
   {
      FileWriteInteger(h, cmd, 4);
      uchar arr[];
      int arr_len = StringToCharArray(payload, arr);
      if(arr_len > 0)
         FileWriteArray(h, arr, 0, arr_len);
      // Pad to minimum 260 bytes total (4 cmd + 256 payload) for IPC reliability
      int written = 4 + arr_len;
      if(written < 260)
      {
         uchar pad[];
         ArrayResize(pad, 260 - written);
         ArrayInitialize(pad, 0);
         FileWriteArray(h, pad, 0, ArraySize(pad));
      }
      FileClose(h);
   }
}

void SendInputState(int mx, int my, int flags, int keycode)
{
   int h = FileOpen(IPC_SUBDIR + "\\input.bin", FILE_WRITE | FILE_BIN | FILE_SHARE_READ | FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileWriteInteger(h, mx, 4);
      FileWriteInteger(h, my, 4);
      FileWriteInteger(h, flags, 4);
      FileWriteInteger(h, keycode, 4);
      FileClose(h);
   }
}

void ProcessURL()
{
   string url = ObjectGetString(0, OBJ_URL_BAR, OBJPROP_TEXT);
   if(StringFind(url, "http") != 0 && StringFind(url, ".") == -1) {
      url = "https://www.google.com/search?q=" + url;
   } else if(StringFind(url, "http") != 0) {
      url = "https://" + url;
   }
   SendControlCommand(5, url);
}

void CreateButton(string name, string text, color bg)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 20);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}


int OnInit()
{
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_SHOW_VOLUMES, CHART_VOLUME_HIDE);
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrBlack);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   
   ObjectCreate(0, OBJ_SCREEN, OBJ_BITMAP_LABEL, 0, 0, 0);
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_BACK, false);
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_ZORDER, 10);

   // Navigation cluster
   CreateButton(OBJ_BTN_BACK, "<", C'55,55,60');
   CreateButton(OBJ_BTN_FWD,  ">", C'55,55,60');
   CreateButton(OBJ_BTN_REF,  "R", C'55,55,60');
   
   // Expanded feature cluster
   CreateButton("Browser_BtnHome", "H", C'55,55,60');
   CreateButton("Browser_BtnNewTab", "+", C'40,60,40');
   CreateButton("Browser_BtnCycleTab", "T", C'40,60,60');
   
   // URL Bar
   ObjectCreate(0, OBJ_URL_BAR, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, OBJ_URL_BAR, OBJPROP_TEXT, "google.com");
   ObjectSetString(0, OBJ_URL_BAR, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_BGCOLOR, C'30,30,35');
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_BORDER_COLOR, C'70,70,80');
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_ALIGN, ALIGN_LEFT);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_READONLY, false);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_ZORDER, 20);
   
   // Scroll cluster
   CreateButton(OBJ_BTN_UP,  "UP",  C'80,60,40');
   CreateButton(OBJ_BTN_DWN, "DWN", C'80,60,40');
   
   // Window controls
   CreateButton(OBJ_BTN_MIN, "_", C'140,40,40');

   EventSetMillisecondTimer(g_timer_ms);
   
   // --- AUTO-LAUNCH: Write config.json and trigger signal ---
   // Clear stale status.bin from previous sessions
   int clear_h = FileOpen(IPC_SUBDIR + "\\status.bin", FILE_WRITE | FILE_BIN | FILE_SHARE_READ | FILE_COMMON);
   if(clear_h != INVALID_HANDLE)
   {
      uint offline[1] = {STATE_OFFLINE};
      FileWriteArray(clear_h, offline);
      FileClose(clear_h);
   }
   
   // Write config.json
   string json_config = "{\n" +
      "  \"homepage\": \"" + InpHomePage + "\",\n" +
      "  \"width\": " + IntegerToString(InpDisplayWidth) + ",\n" +
      "  \"height\": " + IntegerToString(InpDisplayHeight) + ",\n" +
      "  \"dark_mode\": " + (InpDarkMode ? "true" : "false") + ",\n" +
      "  \"user_agent\": \"" + InpUserAgent + "\"\n" +
      "}";
      
   int cfg_h = FileOpen(IPC_SUBDIR + "\\config.json", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(cfg_h != INVALID_HANDLE)
   {
      FileWriteString(cfg_h, json_config);
      FileClose(cfg_h);
   }
   
   // Write start signal so the Python launcher knows to boot the server
   int sig_h = FileOpen(IPC_SUBDIR + "\\start.signal", FILE_WRITE | FILE_BIN | FILE_SHARE_READ | FILE_COMMON);
   if(sig_h != INVALID_HANDLE)
   {
      uchar marker[1] = {1};
      FileWriteArray(sig_h, marker);
      FileClose(sig_h);
      Print("[MT5Browser] Start signal written. Waiting for Python server...");
   }
   
   // Wait up to 15 seconds for the server to become ready
   bool server_ready = false;
   for(int i = 0; i < 150; i++)
   {
      Sleep(100);
      int chk = FileOpen(IPC_SUBDIR + "\\status.bin", FILE_READ | FILE_BIN | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_COMMON);
      if(chk != INVALID_HANDLE)
      {
         uint sv[1];
         if(FileReadArray(chk, sv, 0, 1) == 1 && (sv[0] == STATE_RUNNING || sv[0] == STATE_READY))
            server_ready = true;
         FileClose(chk);
      }
      if(server_ready) break;
   }
   
   if(server_ready)
      Print("[MT5Browser] Server confirmed ready.");
   else
      Print("[MT5Browser] Server not detected. Run launcher.pyw from the project folder.");
   
   Print("[MT5Browser] v4.0 Initialized.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   
   // Only kill the Python server on permanent removal or terminal close.
   // Timeframe changes (REASON_CHARTCHANGE) and parameter changes
   // (REASON_PARAMETERS) keep the server alive to avoid restart churn.
   bool kill_server = (reason == REASON_REMOVE     ||
                       reason == REASON_CHARTCLOSE  ||
                       reason == REASON_CLOSE       ||
                       reason == REASON_PROGRAM     ||
                       reason == REASON_ACCOUNT);
   
   if(kill_server)
   {
      Print("[MT5Browser] Sending shutdown signal...");
      SendControlCommand(99, "");
      // Also write stop signal for the launcher.pyw watcher
      int stop_h = FileOpen(IPC_SUBDIR + "\\stop.signal", FILE_WRITE | FILE_BIN | FILE_SHARE_READ | FILE_COMMON);
      if(stop_h != INVALID_HANDLE)
      {
         uchar marker[1] = {1};
         FileWriteArray(stop_h, marker);
         FileClose(stop_h);
      }
      Sleep(500);
   }
   
   // Delete each named object explicitly to avoid collateral damage
   ObjectDelete(0, OBJ_SCREEN);
   ObjectDelete(0, OBJ_BTN_MIN);
   ObjectDelete(0, OBJ_URL_BAR);
   ObjectDelete(0, OBJ_BTN_BACK);
   ObjectDelete(0, OBJ_BTN_FWD);
   ObjectDelete(0, OBJ_BTN_REF);
   ObjectDelete(0, OBJ_BTN_UP);
   ObjectDelete(0, OBJ_BTN_DWN);
   ObjectDelete(0, "Browser_BtnHome");
   ObjectDelete(0, "Browser_BtnNewTab");
   ObjectDelete(0, "Browser_BtnCycleTab");
   ResourceFree(RES_NAME);
   ChartRedraw();
}

void UpdateUI(int target_w, int target_h)
{
   // CORNER_LEFT_UPPER: (0,0) = top-left, X right, Y down
   int chart_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   int bar_h = 24;   // control bar height
   int margin = 4;   // gap from chart bottom
   
   // Layout: bar sits at top, video frame directly below
   int frame_y = chart_h - margin - target_h;
   int bar_y   = frame_y - bar_h;
   
   if(g_minimized)
   {
      ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, OBJ_BTN_BACK, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, OBJ_BTN_FWD, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, OBJ_BTN_REF, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, OBJ_BTN_UP, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, OBJ_BTN_DWN, OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, "Browser_BtnHome", OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, "Browser_BtnNewTab", OBJPROP_YDISTANCE, 9999);
      ObjectSetInteger(0, "Browser_BtnCycleTab", OBJPROP_YDISTANCE, 9999);
      // Show restore button at bottom-left
      ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_XDISTANCE, 0);
      ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_YDISTANCE, chart_h - 24);
      ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_XSIZE, 70);
      ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_YSIZE, 22);
      ObjectSetString(0, OBJ_BTN_MIN, OBJPROP_TEXT, "SHOW");
      return;
   }

   // Video frame
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_XDISTANCE, 0);
   ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_YDISTANCE, frame_y);
   
   // === TOOLBAR ROW ===
   int btn_w = 28;
   int x = 0;
   
   // [<] Back
   ObjectSetInteger(0, OBJ_BTN_BACK, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, OBJ_BTN_BACK, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_BTN_BACK, OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, OBJ_BTN_BACK, OBJPROP_YSIZE, bar_h);
   x += btn_w + 2;
   
   // [>] Forward
   ObjectSetInteger(0, OBJ_BTN_FWD, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, OBJ_BTN_FWD, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_BTN_FWD, OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, OBJ_BTN_FWD, OBJPROP_YSIZE, bar_h);
   x += btn_w + 2;
   
   // [R] Refresh
   ObjectSetInteger(0, OBJ_BTN_REF, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, OBJ_BTN_REF, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_BTN_REF, OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, OBJ_BTN_REF, OBJPROP_YSIZE, bar_h);
   x += btn_w + 4;
   
   // [H] Home
   ObjectSetInteger(0, "Browser_BtnHome", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, "Browser_BtnHome", OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, "Browser_BtnHome", OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, "Browser_BtnHome", OBJPROP_YSIZE, bar_h);
   x += btn_w + 2;
   
   // [+] New Tab
   ObjectSetInteger(0, "Browser_BtnNewTab", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, "Browser_BtnNewTab", OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, "Browser_BtnNewTab", OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, "Browser_BtnNewTab", OBJPROP_YSIZE, bar_h);
   x += btn_w + 2;
   
   // [T] Cycle Tab
   ObjectSetInteger(0, "Browser_BtnCycleTab", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, "Browser_BtnCycleTab", OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, "Browser_BtnCycleTab", OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, "Browser_BtnCycleTab", OBJPROP_YSIZE, bar_h);
   x += btn_w + 4; // extra gap before URL
   
   // Right side buttons (position from right edge)
   int rx = target_w;
   
   // [_] Minimize (rightmost)
   rx -= btn_w;
   ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_XDISTANCE, rx);
   ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_XSIZE, btn_w);
   ObjectSetInteger(0, OBJ_BTN_MIN, OBJPROP_YSIZE, bar_h);
   ObjectSetString(0, OBJ_BTN_MIN, OBJPROP_TEXT, "_");
   rx -= 2;
   
   // [DWN] Scroll Down
   rx -= 36;
   ObjectSetInteger(0, OBJ_BTN_DWN, OBJPROP_XDISTANCE, rx);
   ObjectSetInteger(0, OBJ_BTN_DWN, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_BTN_DWN, OBJPROP_XSIZE, 36);
   ObjectSetInteger(0, OBJ_BTN_DWN, OBJPROP_YSIZE, bar_h);
   rx -= 2;
   
   // [UP] Scroll Up  
   rx -= 30;
   ObjectSetInteger(0, OBJ_BTN_UP, OBJPROP_XDISTANCE, rx);
   ObjectSetInteger(0, OBJ_BTN_UP, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_BTN_UP, OBJPROP_XSIZE, 30);
   ObjectSetInteger(0, OBJ_BTN_UP, OBJPROP_YSIZE, bar_h);
   rx -= 4; // gap before URL
   
   // URL bar fills the remaining space
   int url_w = rx - x;
   if(url_w < 60) url_w = 60;
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_YDISTANCE, bar_y);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_XSIZE, url_w);
   ObjectSetInteger(0, OBJ_URL_BAR, OBJPROP_YSIZE, bar_h);
}


//+------------------------------------------------------------------+
//| Build modifier flags bitmask from GetAsyncKeyState               |
//| Bit 0: left mouse (set by mouse event directly)                  |
//| Bit 1: shift                                                     |
//| Bit 2: right mouse (set by mouse event directly)                 |
//| Bit 3: ctrl                                                      |
//| Bit 4: alt                                                       |
//+------------------------------------------------------------------+
int GetModifierFlags(int mouse_flags)
{
   int flags = mouse_flags & 0x05;   // preserve bits 0 (left) and 2 (right) from mouse event
   
   if(TerminalInfoInteger(TERMINAL_KEYSTATE_SHIFT) < 0)
      flags |= 2;   // bit 1: shift
   if(TerminalInfoInteger(TERMINAL_KEYSTATE_CONTROL) < 0)
      flags |= 8;   // bit 3: ctrl
   // Alt detection — MQL5 uses TERMINAL_KEYSTATE_MENU for Alt key
   if(TerminalInfoInteger(TERMINAL_KEYSTATE_MENU) < 0)
      flags |= 16;  // bit 4: alt
   
   return flags;
}


void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // ─── BUTTON CLICKS ────────────────────────────────────────────
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      
      if(sparam == OBJ_BTN_MIN)
      {
         g_minimized = !g_minimized;
         UpdateUI(g_target_w, g_target_h);
         ChartRedraw();
         return;
      }
      if(sparam == OBJ_BTN_BACK) { SendControlCommand(8, ""); return; }
      if(sparam == OBJ_BTN_FWD)  { SendControlCommand(9, ""); return; }
      if(sparam == OBJ_BTN_REF)  { SendControlCommand(10, ""); return; }
      if(sparam == OBJ_BTN_UP)   { SendControlCommand(11, ""); return; }
      if(sparam == OBJ_BTN_DWN)  { SendControlCommand(12, ""); return; }
      if(sparam == "Browser_BtnHome")     { SendControlCommand(17, ""); return; }
      if(sparam == "Browser_BtnNewTab")   { SendControlCommand(18, ""); return; }
      if(sparam == "Browser_BtnCycleTab") { SendControlCommand(19, ""); return; }
      
      // If the URL bar was clicked, mark it as focused
      if(sparam == OBJ_URL_BAR)
      {
         g_url_bar_focused = true;
         return;
      }
      
      // If the canvas was clicked, send explicit click command to prevent polling drops
      if(sparam == OBJ_SCREEN)
      {
         SendControlCommand(16, IntegerToString(g_last_mx) + "," + IntegerToString(g_last_my));
      }
      
      // Any other click unfocuses the URL bar
      g_url_bar_focused = false;
   }
   
   // ─── URL BAR SUBMIT (Enter pressed while editing) ─────────────
   if(id == CHARTEVENT_OBJECT_ENDEDIT && sparam == OBJ_URL_BAR)
   {
      g_url_bar_focused = false;
      ProcessURL();
      return;
   }
   
   // ─── KEYBOARD INPUT ──────────────────────────────────────────
   // Only forward to browser when NOT typing in the URL bar
   if(id == CHARTEVENT_KEYDOWN && !g_minimized && g_target_w > 0 && !g_url_bar_focused)
   {
      int kc = (int)lparam;
      int flags = GetModifierFlags(g_last_mflags);
      
      SendInputState(g_last_mx, g_last_my, flags, kc);
      return;
   }
   
   // ─── MOUSE INPUT ─────────────────────────────────────────────
   if(id == CHARTEVENT_MOUSE_MOVE && !g_minimized && g_target_w > 0)
   {
      int x = (int)lparam;
      int y = (int)dparam;
      int raw_flags = (int)StringToInteger(sparam);
      
      // Build full modifier flags (mouse bits + keyboard modifiers)
      int flags = GetModifierFlags(raw_flags);
      
      // Compute canvas boundaries
      int chart_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      int canvas_x = 0;
      int canvas_y = chart_h - 4 - g_target_h;
      
      // Only process if mouse is over the browser canvas
      if(x >= canvas_x && x < canvas_x + g_target_w && y >= canvas_y && y < canvas_y + g_target_h)
      {
         // Unfocus URL bar when clicking on the canvas
         if((raw_flags & 1) != 0 && (g_last_mflags & 1) == 0)
            g_url_bar_focused = false;
         
         int local_x = x - canvas_x;
         int local_y = y - canvas_y;
         
         // ─── DOUBLE-CLICK DETECTION ─────────────────────────
         // Detect a second left-click within time+distance threshold
         bool left_just_pressed = ((raw_flags & 1) != 0) && ((g_last_mflags & 1) == 0);
         if(left_just_pressed)
         {
            uint now_ms = GetTickCount();
            int dx = MathAbs(local_x - g_last_click_x);
            int dy = MathAbs(local_y - g_last_click_y);
            
            if((now_ms - g_last_click_time) < DBLCLICK_THRESHOLD_MS
               && dx < DBLCLICK_THRESHOLD_PX
               && dy < DBLCLICK_THRESHOLD_PX)
            {
               // Send double-click command to Python
               SendControlCommand(13, IntegerToString(local_x) + "," + IntegerToString(local_y));
               // Reset so a third click doesn't re-trigger
               g_last_click_time = 0;
            }
            else
            {
               g_last_click_time = now_ms;
               g_last_click_x = local_x;
               g_last_click_y = local_y;
            }
         }
         
         if(local_x != g_last_mx || local_y != g_last_my || flags != g_last_mflags)
         {
            g_last_mx = local_x; g_last_my = local_y; g_last_mflags = flags;
            SendInputState(local_x, local_y, flags, 0);
         }
      }
   }
}

void OnTimer()
{
   if(g_minimized) return; 

   // Use user-specified display dimensions (clamped to sane range)
   int target_w = MathMax(150, MathMin(InpDisplayWidth, (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS)));
   int target_h = MathMax(100, MathMin(InpDisplayHeight, (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS) - 30));
   
   if(target_w != g_target_w || target_h != g_target_h)
   {
       g_target_w = target_w; g_target_h = target_h;
       UpdateUI(target_w, target_h);
       SendControlCommand(7, IntegerToString(target_w) + "," + IntegerToString(target_h));
   }
   
   // Sync URL bar from Python (page navigations, redirects)
   int url_h = FileOpen(IPC_SUBDIR + "\\url.bin", FILE_READ | FILE_BIN | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_COMMON);
   if(url_h != INVALID_HANDLE)
   {
      int fsize = (int)FileSize(url_h);
      if(fsize > 0 && fsize < 2048)
      {
         uchar url_bytes[];
         ArrayResize(url_bytes, fsize);
         FileReadArray(url_h, url_bytes, 0, fsize);
         string new_url = CharArrayToString(url_bytes);
         // Only update if URL bar is not being edited by the user
         if(new_url != "" && !g_url_bar_focused && new_url != ObjectGetString(0, OBJ_URL_BAR, OBJPROP_TEXT))
            ObjectSetString(0, OBJ_URL_BAR, OBJPROP_TEXT, new_url);
      }
      FileClose(url_h);
   }
   
   static uint frame_data[];
   
   string filepath = IPC_SUBDIR + "\\" + FRAME_FILE;
   int handle = FileOpen(filepath, FILE_READ | FILE_BIN | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_COMMON);
   if(handle == INVALID_HANDLE) return;

   uint header[];
   ArrayResize(header, FRAME_HEADER_SIZE);
   if(FileReadArray(handle, header, 0, FRAME_HEADER_SIZE) == FRAME_HEADER_SIZE)
   {
      uint frame_counter = header[0];
      uint w = header[1];
      uint h = header[2];
      
      // C4 FIX: Clamp to sane maximums to prevent multi-GB allocation from corrupt IPC data
      if(w > 0 && h > 0 && w <= 2560 && h <= 1440 && frame_counter != g_last_frame_counter)
      {
         if(w != (uint)g_target_w || h != (uint)g_target_h)
         {
            SendControlCommand(7, IntegerToString(g_target_w) + "," + IntegerToString(g_target_h));
         }
         
         uint pixels = w * h;
         if(ArraySize(frame_data) != (int)pixels) ArrayResize(frame_data, (int)pixels);
         if(FileReadArray(handle, frame_data, 0, (int)pixels) == (int)pixels)
         {
            g_last_frame_counter = frame_counter;
            ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_XSIZE, w);
            ObjectSetInteger(0, OBJ_SCREEN, OBJPROP_YSIZE, h);
            ResourceCreate(RES_NAME, frame_data, w, h, 0, 0, w, COLOR_FORMAT_ARGB_NORMALIZE);
            ObjectSetString(0, OBJ_SCREEN, OBJPROP_BMPFILE, RES_NAME);
            ChartRedraw();
         }
      }
   }
   FileClose(handle);
}

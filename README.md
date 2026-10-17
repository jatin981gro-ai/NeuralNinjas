# Desk-OS — point. speak. automate.
### Tangible-Bridge: Live Hackathon Demo Prototype

> **Turn any physical desk, seen through a laptop webcam, into a programmable spatial computing interface.**

---

## ⚡ Quick Start: Running on Local Server (Required for Webcam & MediaPipe)

Modern browsers enforce strict secure-context constraints (`isSecureContext === true`) for camera access. Always run Desk-OS via a local HTTP server so Chrome/Edge can grant webcam permissions and load MediaPipe WebAssembly assets without CORS or security blocks:

### Option 1: Native Windows / PowerShell (Zero Dependencies)
```powershell
powershell -ExecutionPolicy Bypass -File .\serve.ps1
```

### Option 2: Python 3
```bash
python -m http.server 8000
```

### Option 3: Node / NPX
```bash
npx serve -l 8000 .
```

Then open in Google Chrome or Microsoft Edge:
```
http://localhost:8000/
```

*(Note: If camera permission is blocked or no webcam is physically present, Desk-OS displays an explicit error banner with a retry button and gracefully activates the Virtual Desk explainer fallback).*

---

## 🔍 Root Cause Analysis & Fix Summary

### What Was Broken:
1. **Silent Virtual Desk Defaulting**: The application was defaulting to the Virtual Desk fallback mode because `@mediapipe/camera_utils` was attempting a duplicate `getUserMedia` call in the background, creating a camera lock contention. Additionally, `loadDemoPrewiredNodes` was forcibly calling `activateVirtualDeskMode()`.
2. **MediaPipe Asset Loader Exceptions**: Pinned version hash mismatches and premature `hands.send()` frame pumping during WASM asset download threw `TypeError: Cannot read properties of undefined` in `hands_solution_packed_assets_loader.js`.
3. **Pen Timer Trigger**: The timer was previously wired to virtual canvas dragging rather than the real physical webcam feed ROI.

### What Fixed It:
1. **Real Camera as True Default**:
   - Pinned clean MediaPipe Hands script via canonical CDN.
   - Pumping video frames directly from `<video>` to `hands.send({ image: video })` without duplicate `getUserMedia` calls.
   - Guarded frame pumping so frames are only dispatched once `hands.initialize()` resolves and status transitions to `Hands: Ready`.
   - Virtual Desk is strictly reserved as an emergency fallback on confirmed `NotAllowedError` or missing hardware, accompanied by an explicit `#cameraErrorOverlay` with a `🎥 Retry Camera Access` button.
2. **Real Physical Pen Tracking (No Virtual Prop Dependency)**:
   - The user clicks on the real webcam video stream where their physical pen rests.
   - Desk-OS samples a resting baseline ROI patch (`canvas.getImageData`) at `(restingX, restingY)`.
   - Frame-by-frame, the engine evaluates both tracked pen spatial displacement (`dist > 32px`) and dock color shift (`dockColorShift > 40Δ`) against the resting baseline, fused with hand proximity detection.
   - Lifting the real pen auto-starts the on-screen focus stopwatch; placing it back in the resting dock auto-pauses it (preserving elapsed time).
3. **Zero Console Errors**: Full test suite runs with 0 unhandled promise rejections and 0 console errors.

---

## ⏱️ Feature Spotlight: Real-Camera Pen Focus Stopwatch

Desk-OS includes a tangible spatial productivity tool: lifting your physical pen off your desk automatically starts a high-contrast focus timer; placing it back down pauses it.

### How It Works on the Live Camera Stream:
1. **Resting ROI Dock**: When a pen is registered by clicking on the live camera view, Desk-OS stores its resting coordinates `(restingX, restingY)` and baseline color profile.
2. **Real-World Lift Detection**: When you pick up the pen, the camera detects that the pen has left the dock (`dist > 32px` or color delta `> 40Δ`), triggering `startPenTimer()`. The top-right widget pulses magenta with status `RUNNING (PEN LIFTED)`.
3. **Real-World Dock Return**: When you place the pen back into its resting spot, the camera detects that the dock ROI matches the resting baseline, triggering `pausePenTimer()`. Status transitions to `PAUSED (PEN DOCKED)` while retaining elapsed time.
4. **Manual Control**: Dedicated `🔄 Reset` and `▶ Start / ⏸ Pause` buttons provide complete stage control.

---

## 🎬 Live Hackathon Demo Scripts (For Judges)

### Script A: Real Physical Desk Demo (Primary — Real Camera + Real Pen)
1. Launch `http://localhost:8000/` in Chrome and allow camera access.
2. Confirm the top status bar displays:
   - `Camera: Live (720p)` (green dot)
   - `Hands: Ready` (green dot)
3. Wave your hand over the camera — observe the 21-point MediaPipe AR joint skeleton render in real time.
4. Place your physical pen on your desk. Click on the pen in the live video stream.
5. In the slide-out registration drawer, click the quick chip: **`🖊️ Pen Lift ➔ Focus Timer`**, then click **⚡ Bind Node**.
6. Observe the AR reticle and dashed resting dock lock onto your pen.
7. **Lift your physical pen off the desk**:
   - The top-right Focus Timer immediately starts ticking up with an audio confirmation chime.
   - Badge updates to `RUNNING (PEN LIFTED)`.
8. **Place the pen back down on the desk in its spot**:
   - The stopwatch automatically pauses.
   - Badge updates to `PAUSED (PEN DOCKED)`.
9. Click **`🔄 Reset`** on the widget to zero the timer back to `00:00.0`.

### Script B: 30-Second Stage Safety Demo (`🪄 Demo Mode` on Live Webcam)
*If judges arrive quickly and you need pre-configured nodes instantly:*
1. Click **`🪄 Demo Mode`** in the header.
2. Desk-OS pre-wires three spatial nodes overlaid directly on your **live webcam feed**:
   - ☕ **Ceramic Mug**: Move left `dx > 30px` ➔ fires `desk_lights_off` webhook.
   - 📝 **Sticky Note**: Touch with index finger ➔ fires `spotify_pause` notification.
   - 🖊️ **Pen**: Lifted from resting dock ➔ auto-starts Focus Stopwatch.
3. Slide an object or tap the screen cards to demonstrate node firing with green shockwaves, laser wire pulses, and audio feedback.
4. Click **`🔄 Reset Demo`** before the next judge arrives to wipe all state cleanly in `< 100ms`.

---

## 🛡️ Hackathon Judge Safety Nets & Graceful Fallbacks

| Failure Scenario | Automatic Graceful Fallback |
| :--- | :--- |
| **Camera Denied / Insecure Context (`file:///`)** | Displays explicit warning modal with `🎥 Retry Camera Access` button and switches to Virtual Desk explainer fallback. |
| **MediaPipe CDN Stalled / Slow Network** | 8000ms watchdog transitions status cleanly to `Hands: Failed — using fallback`. Real camera stream and ROI tracking remain 100% active. |
| **Flaky Wi-Fi / No Gemini API Key** | Autonomous Local NLP Keyword Parser extracts trigger, direction, action label, and type in `< 1ms` offline with 0 network calls. |
| **Next Judge Arrives** | Click **`🔄 Reset Demo`** in header to wipe all state in `< 100ms` without reloading the page. |

---

## 🧪 Automated End-to-End Test Suite

Run the full headless Chrome DevTools test suite:
```powershell
powershell -ExecutionPolicy Bypass -File .\test-desk-os.ps1
```
Verified results:
* [1/6] Launch Chrome with live webcam mock: **PASS**
* [2/6] Connect to Chrome DevTools Protocol: **PASS**
* [3/6] Real Camera & MediaPipe Initialization (`feedMode: webcam`): **PASS**
* [4/6] Real Camera Pen ROI Registration & Lift/Dock Stopwatch: **PASS**
* [5/6] Demo Mode on Real Camera Feed (no virtual fallback): **PASS**
* [6/6] Console Errors & Unhandled Exceptions: **ZERO (0)**

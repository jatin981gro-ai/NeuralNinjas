# Desk-OS -- point. speak. automate.
### Tangible-Bridge: Spatial Computing Interface Prototype

> Turn any physical desk, seen through a webcam, into a programmable spatial computing interface.

---

## Live Deployment (Primary)

Desk-OS is deployed and publicly accessible via GitHub Pages over HTTPS:

**Live URL**: [https://jatin981gro-ai.github.io/NeuralNinjas/](https://jatin981gro-ai.github.io/NeuralNinjas/)

### Secure Context & Browser Permissions
Modern browsers require a secure origin (`window.isSecureContext === true`) to access hardware webcams via `navigator.mediaDevices.getUserMedia` and compile WebAssembly neural models. The GitHub Pages HTTPS deployment provides an authenticated secure context out of the box, allowing camera permission requests to succeed without local server setup.

- **Custom Domain Status**: Pending (no custom domain currently mapped; production traffic serves via GitHub Pages HTTPS).

---

## Local Development Only

If modifying source files or running offline diagnostics locally, run via a local HTTP server (browsers block camera access on `file:///` protocols):

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

Then visit `http://localhost:8000/` in Google Chrome or Microsoft Edge.

---

## System Architecture & Features

### 1. Real Physical Pen Focus Stopwatch
- **Resting ROI Dock**: Clicking a physical pen on the live webcam feed samples a baseline Region of Interest (ROI) patch and records resting spatial coordinates.
- **Lift Detection**: Lifting the pen triggers immediate displacement (`dist > 32px`) and color delta thresholding, auto-starting the high-contrast focus stopwatch.
- **Dock Return**: Placing the pen back into its resting dock auto-pauses the stopwatch while preserving elapsed time.
- **Manual Overrides**: Dedicated reset and start/pause controls provide manual stage control.

### 2. High-Precision Gesture Recognition & Debounce
- **Point Gesture**: Starts or resumes the focus timer with on-screen visual confirmation HUD.
- **Fist Gesture**: Stops / pauses the focus timer and retains elapsed time.
- **Wave Gesture**: Multi-directional horizontal palm trajectory recognition resets the stopwatch to `00:00.0`.
- **Debounce State Machine**: Strict hysteresis thresholds prevent accidental double-firing or bouncing during transitions.

### 3. Accessible Mode & Voice Synthesizer
- **Semantic HTML Landmarks**: Proper `<header>`, `<nav>`, `<main>`, and `<footer>` landmarks with skip-to-content navigation.
- **Screen Reader Live Region**: `aria-live="polite"` region communicates timer states, gesture recognitions, and node triggers in real time.
- **Web Speech API Voice Mode**: Toggleable spoken announcements mirror visual notifications for hands-free audio confirmation.
- **Keyboard Navigation**: Complete Tab/Enter/Space accessibility with visible high-contrast focus rings.

### 4. Strict Monochrome Design & Dark Mode
- **Palette**: Pure white (`#FFFFFF`), pure black (`#000000`), and neutral grays (`#E5E5E5`, `#999999`, `#333333`).
- **Accent**: Single functional orange accent (`#D9480F`) strictly reserved for active states and primary calls to action.
- **Dark Mode**: Dynamic `[data-theme="dark"]` token inversion with `localStorage` persistence.
- **Typography System**: Headings set in Space Grotesk (geometric, technical) and body copy in IBM Plex Sans (high legibility), rendered with a fluid `clamp()` type scale.

---

## Automated Verification & Test Suites

The project includes headless Chrome DevTools test suites covering all architectural layers:

```powershell
# 1. Typography System & Font Integrity Check
powershell -ExecutionPolicy Bypass -File .\test-typography.ps1

# 2. Header, Footer, Legal Routes & Mobile Responsiveness
powershell -ExecutionPolicy Bypass -File .\test-header-footer.ps1

# 3. Real Camera Feed, MediaPipe Hands, Pen Tracker & Gestures E2E
powershell -ExecutionPolicy Bypass -File .\test-desk-os.ps1
```

All suites execute against headless Chrome with 100% pass rates and zero console errors.

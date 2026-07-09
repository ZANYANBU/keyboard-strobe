# 🎹 Keyboard Strobe

<div align="center">
  <a href="https://www.youtube.com/watch?v=RabYGyTQNDw">
    <img src="https://img.youtube.com/vi/RabYGyTQNDw/maxresdefault.jpg" alt="Keyboard Strobe Demo" width="100%">
  </a>
</div>

> **Turn your MacBook's keyboard backlight into a zero-latency, beat-synced strobe light!**

`keyboard-strobe` is a high-performance macOS menubar utility that captures direct system audio and flashes your MacBook keyboard's backlight in perfect sync with the beats of your music. It is built in native Swift and leverages Apple's **ScreenCaptureKit** to stream internal mixer audio directly—bypassing the microphone entirely and ignoring ambient room noise.

> **Note:** Just made this repo for fun! Love to connect! 🤝

### 🎧 Great For:
- **EDM & Bass Music:** Feel the physical impact of heavy kicks and drops.
- **YouTube & Talk Shows:** Surprisingly enhances the viewing experience of regular everyday videos by adding a subtle, ambient reactive light to spoken transients and sound effects!

---

## 🎥 Demos

*Click to play the demo clips below:*

https://github.com/ZANYANBU/keyboard-strobe/raw/main/demos/Demo.mp4

https://github.com/ZANYANBU/keyboard-strobe/raw/main/demos/demo1.mp4

https://github.com/ZANYANBU/keyboard-strobe/raw/main/demos/demo2.mp4

---

## ✨ Features

- **⚡ Zero-Latency Response:** Captures and processes internal system audio streams directly, syncing key flashes perfectly with the sound reaching your ears.
- **🔊 Dual-Band Beat Detection:** Employs a digital signal processing (DSP) engine to isolate and detect:
  - **Bass kicks:** Using a low-pass filter ($fc \approx 120\text{ Hz}$).
  - **Snare drums, claps, and vocal transients:** Using a high-pass filter ($fc \approx 1200\text{ Hz}$).
- **🎛️ Onset Detection Algorithm:** Maintains a sliding average history to trigger flashes strictly on major musical peaks, ignoring minor background melodies and static.
- **🚥 Hardware LED Protection:** Embeds a sustain/decay timing envelope ($60\text{ms}$ ON / $20\text{ms}$ OFF minimum hold-gates) to accommodate the MacBook's physical LED fade limits, producing crisp, high-speed strobe transitions.
- **🤫 Dynamic Auto-Calibration:** Automatically calibrates sensitivity to the current audio output volume so beats pop just as clearly on quiet acoustic tracks as they do on loud club music.
- **🔒 Dynamic Auto-Brightness Override:** Automatically disables macOS's ambient light sensor control when active and restores it cleanly on exit.

---

## 🤔 The "Wait, a MacBook can do that?" Factor

While PC users with Razer or Corsair keyboards have had music-reactive RGB lighting for a decade, Apple has always kept their hardware tightly locked down. There is practically zero native support for this kind of hardware customization on macOS.

This app exists to fill that totally unoccupied niche. It leverages undocumented, private Apple APIs (`CoreBrightness`) to commandeer the physical LEDs in the MacBook's keyboard. The result? A completely standard, un-modded MacBook doing a lightning-fast music strobe sync in a pitch-black room with zero latency and no external microphone required. 

People love discovering hidden capabilities in hardware they already own. This project unlocks one of them!

---

## 🚀 Installation

### 1. Download
Download the latest `KeyboardStrobe.zip` from the [Releases](https://github.com/ZANYANBU/keyboard-strobe/releases) page.

### 2. Install
1. Unzip the downloaded file.
2. Drag **KeyboardStrobe.app** to your macOS `/Applications` folder.
3. Open your Applications folder and double-click the app to launch it!

### 3. Optimal System Settings
For the best visual experience, go to **System Settings > Keyboard** and apply these settings to prevent macOS from overriding the strobe effect:
- **Adjust keyboard brightness in low light:** OFF
- **Turn keyboard backlight off after inactivity:** Never

*Tip: If you want it to launch automatically when you turn on your Mac, you can add it to **System Settings > General > Login Items**.*

---

---

## 🛠️ Usage

1. Double click the **KeyboardStrobe** app icon to open it.
2. A new waveform icon will appear in your macOS menu bar at the top right of your screen. **Click this menubar icon for adjustments.**
3. In the dropdown menu, you can dynamically switch:
   - **Start / Stop** the strobe visualizer.
   - **Mode:** Select between Dual (default), Bass Only, or Snare Only.
   - **Audio Delay:** Compensate for Bluetooth speaker latency (default is 120ms).
   - **Max Brightness:** Limit the hardware brightness to 100%, 75%, or 50% to make the strobe flashes visually faster and snappier.

---

## ⚠️ Important Troubleshooting

### 1. Screen & System Audio Recording Permission
Because this tool taps into your Mac's internal audio mixer, macOS requires you to grant it **Screen & System Audio Recording** permissions.
* The first time you run it, a system prompt will appear.
* Go to **System Settings > Privacy & Security > Screen & System Audio Recording**, and toggle **KeyboardStrobe** to **ON**.

### 2. Works Best in Low Light Environments (Hardware Limitation)
macOS has a hardware-level battery-saving restriction: **If the room you are in is brightly lit, macOS physically cuts power to the keyboard backlight LEDs.**
* **For the best experience, use this app in a low lighting environment or a dark room.**
* If your room is too bright, your keyboard backlight will remain completely off even if the app is running successfully.
* *Workaround:* If you want to use it in a bright room, cover the ambient light sensor (next to the camera notch at the top center of your display) with a piece of tape or cloth.

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

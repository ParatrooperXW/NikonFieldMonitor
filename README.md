# NikonFieldMonitor

> 🌐 **Languages / 语言**: [English](#english) | [简体中文](#简体中文) | [繁體中文](#繁體中文)

---

<a id="english"></a>

## English

A professional wireless / USB live-view monitor and remote controller for Nikon Z-series cameras, built with Flutter. Turns your Android phone into a cinema-grade field monitor with false color, waveform, histogram, focus peaking, zebras, and 3D LUT support.

### ⚠️ Important Disclaimer — Vibe Coding Project, Untested

This is a **vibe coding** project — the entire codebase was generated through AI-assisted conversation without manual review or verification of every line. As such:

- ❌ **It has NOT been tested on real hardware.** No Nikon camera has been connected during development.
- ❌ **Normal functionality is NOT guaranteed.** Crashes, connection failures, broken features, or incorrect behavior are expected.
- ❌ **Do not use it for any production or critical work.** It may fail silently, behave unpredictably, or damage your workflow.
- ⚠️ **Use at your own risk.** The author is not responsible for any loss, including but not limited to data loss, equipment issues, or missed shots.

If you actually need a working field monitor, please use mature commercial solutions such as SmallHD, Atomos, or Nikon's official SnapBridge / Webcam Utility.

### Features

- **PTP/IP over Wi-Fi** — Connect to Nikon Z-series cameras via TCP port 15740
- **USB OTG support** — Direct USB connection via Android USB Host API
- **Live View rendering** — OpenGL ES 2.0 pipeline with Flutter TextureRegistry
- **3D LUT support** — Import `.cube` LUT files for on-set color grading
- **Monitoring assists**
  - False color (exposure mapping)
  - Waveform monitor (bottom / side, adjustable opacity)
  - Histogram (luma / RGB parade)
  - Focus peaking (color & sensitivity selectable)
  - Zebra stripes (IRE range configurable)
  - Safe frame overlays (16:9, 2.39:1, 4:3, center cross)
  - HUD overlay
- **GPU post-processing** — Custom GLSL shaders for all monitoring effects
- **Multi-language UI** — English, Simplified Chinese, Traditional Chinese
- **Settings screen** — Toggle any monitoring assist and switch language on the fly

### Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.22+ / Dart 3.x |
| State | Riverpod 2.5 |
| Persistence | SharedPreferences |
| Native render | OpenGL ES 2.0 + EGL14 |
| Native bridge | MethodChannel / EventChannel (Kotlin) |
| Protocol | PTP/IP (TCP 15740), PTP-over-USB |
| Platform | Android 5.0+ (minSdk 21) |

### Supported Cameras (Theoretical)

Any Nikon camera exposing a PTP/IP endpoint should work in principle — including Z5, Z6, Z6II, Z6III, Z7, Z7II, Z8, Z9, Zf, Z50, Z50II, Zfc, D850, D780, D6. USB connectivity requires the camera to support PTP-over-USB. **None of these have been verified.**

### Project Structure

```
nikon_field_monitor/
├── lib/
│   ├── main.dart                       # App entry, global error handlers
│   ├── l10n/app_strings.dart           # i18n string table (en / zh-CN / zh-TW)
│   ├── models/                         # Camera state, LUT, assist settings
│   ├── native_bridge/                  # Dart → Kotlin MethodChannel bridges
│   ├── ptp/                            # PTP/IP packet protocol & LiveView parser
│   ├── services/                       # Connection / LiveView / LUT / preferences
│   ├── state/providers.dart            # Riverpod providers
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── connection_screen.dart  # Wi-Fi/USB discovery & connect
│   │   │   ├── liveview_screen.dart    # Main monitor view
│   │   │   └── settings_screen.dart    # Settings menu (assists + language)
│   │   └── widgets/                    # Assist sheet, HUD, drawer, action rail
│   └── utils/theme.dart                # Dark cinema-monitor theme
└── android/app/src/main/kotlin/com/nikonfieldmonitor/
    ├── app/MainActivity.kt             # Plugin registration
    ├── render/                         # OpenGL ES render pipeline
    │   ├── RenderPlugin.kt
    │   ├── LiveViewRenderer.kt
    │   └── ShaderProgram.kt
    └── usb/UsbPtpPlugin.kt             # USB OTG PTP bridge
```

### Build

Requirements: Flutter 3.19+, Android SDK 34, JDK 17.

```bash
cd nikon_field_monitor
flutter pub get
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### License

MIT — see [LICENSE](LICENSE). Provided "as is", without warranty of any kind.

---

<a id="简体中文"></a>

## 简体中文

一款基于 Flutter 开发的尼康 Z 系列相机无线 / USB 实时取景监看器与遥控器，可将安卓手机变成具备伪色、波形图、直方图、峰值对焦、斑马纹和 3D LUT 支持的专业级现场监视器。

### ⚠️ 重要声明 —— Vibe Coding 项目，未经测试

本项目是一个 **Vibe Coding**（氛围编程）项目 —— 整个代码库均由 AI 辅助对话生成，并未对每一行代码进行人工审查或验证。因此：

- ❌ **未在真实硬件上测试过。** 开发过程中没有连接过任何尼康相机。
- ❌ **不保证正常功能。** 闪退、连接失败、功能异常、行为错误都是预期之中的。
- ❌ **请勿用于任何生产或关键工作。** 它可能静默失败、产生不可预测的行为，或破坏你的工作流。
- ⚠️ **风险自负。** 作者不对任何损失负责，包括但不限于数据丢失、设备问题或错过拍摄。

如果你确实需要可用的现场监视器，请使用成熟的商业方案，例如 SmallHD、Atomos 或尼康官方的 SnapBridge / Webcam Utility。

### 功能特性

- **Wi-Fi PTP/IP 连接** —— 通过 TCP 端口 15740 连接尼康 Z 系列相机
- **USB OTG 支持** —— 通过 Android USB Host API 直连
- **实时取景渲染** —— OpenGL ES 2.0 管线 + Flutter TextureRegistry
- **3D LUT 支持** —— 导入 `.cube` LUT 文件进行现场调色
- **监看辅助功能**
  - 伪色（曝光映射）
  - 波形图（底部 / 侧边，可调透明度）
  - 直方图（亮度 / RGB Parade）
  - 峰值对焦（颜色与灵敏度可选）
  - 斑马纹（IRE 范围可配置）
  - 安全框（16:9、2.39:1、4:3、中心十字）
  - HUD 信息层
- **GPU 后处理** —— 所有监看效果均使用自定义 GLSL 着色器
- **多语言界面** —— 英文、简体中文、繁体中文
- **设置菜单** —— 可快速开关任意监看辅助功能并切换语言

### 技术栈

| 层级 | 技术 |
|---|---|
| 框架 | Flutter 3.22+ / Dart 3.x |
| 状态管理 | Riverpod 2.5 |
| 持久化 | SharedPreferences |
| 原生渲染 | OpenGL ES 2.0 + EGL14 |
| 原生桥接 | MethodChannel / EventChannel (Kotlin) |
| 通信协议 | PTP/IP (TCP 15740)、PTP-over-USB |
| 平台 | Android 5.0+ (minSdk 21) |

### 支持相机（理论支持）

任何提供 PTP/IP 端点的尼康相机原则上均可连接 —— 包括 Z5、Z6、Z6II、Z6III、Z7、Z7II、Z8、Z9、Zf、Z50、Z50II、Zfc、D850、D780、D6。USB 连接需要相机支持 PTP-over-USB。**以上均未经验证。**

### 项目结构

```
nikon_field_monitor/
├── lib/
│   ├── main.dart                       # 应用入口，全局错误处理
│   ├── l10n/app_strings.dart           # 国际化字符串表 (en / zh-CN / zh-TW)
│   ├── models/                         # 相机状态、LUT、辅助设置模型
│   ├── native_bridge/                  # Dart → Kotlin MethodChannel 桥接
│   ├── ptp/                            # PTP/IP 协议包与 LiveView 解析
│   ├── services/                       # 连接 / LiveView / LUT / 偏好服务
│   ├── state/providers.dart            # Riverpod providers
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── connection_screen.dart  # Wi-Fi/USB 发现与连接
│   │   │   ├── liveview_screen.dart    # 主监视器界面
│   │   │   └── settings_screen.dart    # 设置菜单（辅助功能 + 语言）
│   │   └── widgets/                    # 辅助面板、HUD、抽屉、操作栏
│   └── utils/theme.dart                # 暗色影院监看主题
└── android/app/src/main/kotlin/com/nikonfieldmonitor/
    ├── app/MainActivity.kt             # 插件注册
    ├── render/                         # OpenGL ES 渲染管线
    │   ├── RenderPlugin.kt
    │   ├── LiveViewRenderer.kt
    │   └── ShaderProgram.kt
    └── usb/UsbPtpPlugin.kt             # USB OTG PTP 桥接
```

### 构建

环境要求：Flutter 3.19+、Android SDK 34、JDK 17。

```bash
cd nikon_field_monitor
flutter pub get
flutter build apk --release
# 输出：build/app/outputs/flutter-apk/app-release.apk
```

### 许可证

MIT —— 详见 [LICENSE](LICENSE)。按"原样"提供，不附带任何形式的担保。

---

<a id="繁體中文"></a>

## 繁體中文

一款基於 Flutter 開發的尼康 Z 系列相機無線 / USB 即時取景監看器與遙控器，可將 Android 手機變成具備偽色、波形圖、直方圖、峰值對焦、斑馬紋和 3D LUT 支援的專業級現場監視器。

### ⚠️ 重要聲明 —— Vibe Coding 專案，未經測試

本專案是一個 **Vibe Coding**（氛圍程式設計）專案 —— 整個程式碼庫均由 AI 輔助對話產生，並未對每一行程式碼進行人工審查或驗證。因此：

- ❌ **未在真實硬體上測試過。** 開發過程中沒有連接過任何尼康相機。
- ❌ **不保證正常功能。** 閃退、連線失敗、功能異常、行為錯誤都是預期之中的。
- ❌ **請勿用於任何生產或關鍵工作。** 它可能靜默失敗、產生不可預測的行為，或破壞你的工作流程。
- ⚠️ **風險自負。** 作者不對任何損失負責，包括但不限於資料遺失、裝置問題或錯過拍攝。

如果你確實需要可用的現場監視器，請使用成熟的商業方案，例如 SmallHD、Atomos 或尼康官方的 SnapBridge / Webcam Utility。

### 功能特性

- **Wi-Fi PTP/IP 連線** —— 透過 TCP 連接埠 15740 連接尼康 Z 系列相機
- **USB OTG 支援** —— 透過 Android USB Host API 直連
- **即時取景渲染** —— OpenGL ES 2.0 管線 + Flutter TextureRegistry
- **3D LUT 支援** —— 匯入 `.cube` LUT 檔案進行現場調色
- **監看輔助功能**
  - 偽色（曝光映射）
  - 波形圖（底部 / 側邊，可調透明度）
  - 直方圖（亮度 / RGB Parade）
  - 峰值對焦（顏色與靈敏度可選）
  - 斑馬紋（IRE 範圍可設定）
  - 安全框（16:9、2.39:1、4:3、中心十字）
  - HUD 資訊層
- **GPU 後處理** —— 所有監看效果均使用自訂 GLSL 著色器
- **多語言介面** —— 英文、簡體中文、繁體中文
- **設定選單** —— 可快速開關任意監看輔助功能並切換語言

### 技術棧

| 層級 | 技術 |
|---|---|
| 框架 | Flutter 3.22+ / Dart 3.x |
| 狀態管理 | Riverpod 2.5 |
| 持久化 | SharedPreferences |
| 原生渲染 | OpenGL ES 2.0 + EGL14 |
| 原生橋接 | MethodChannel / EventChannel (Kotlin) |
| 通訊協定 | PTP/IP (TCP 15740)、PTP-over-USB |
| 平台 | Android 5.0+ (minSdk 21) |

### 支援相機（理論支援）

任何提供 PTP/IP 端點的尼康相機原則上均可連線 —— 包括 Z5、Z6、Z6II、Z6III、Z7、Z7II、Z8、Z9、Zf、Z50、Z50II、Zfc、D850、D780、D6。USB 連線需要相機支援 PTP-over-USB。**以上均未經驗證。**

### 專案結構

```
nikon_field_monitor/
├── lib/
│   ├── main.dart                       # 應用程式進入點，全域錯誤處理
│   ├── l10n/app_strings.dart           # 國際化字串表 (en / zh-CN / zh-TW)
│   ├── models/                         # 相機狀態、LUT、輔助設定模型
│   ├── native_bridge/                  # Dart → Kotlin MethodChannel 橋接
│   ├── ptp/                            # PTP/IP 協定封包與 LiveView 解析
│   ├── services/                       # 連線 / LiveView / LUT / 偏好服務
│   ├── state/providers.dart            # Riverpod providers
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── connection_screen.dart  # Wi-Fi/USB 探索與連線
│   │   │   ├── liveview_screen.dart    # 主監視器介面
│   │   │   └── settings_screen.dart    # 設定選單（輔助功能 + 語言）
│   │   └── widgets/                    # 輔助面板、HUD、抽屜、操作列
│   └── utils/theme.dart                # 暗色戲院監看主題
└── android/app/src/main/kotlin/com/nikonfieldmonitor/
    ├── app/MainActivity.kt             # 外掛註冊
    ├── render/                         # OpenGL ES 渲染管線
    │   ├── RenderPlugin.kt
    │   ├── LiveViewRenderer.kt
    │   └── ShaderProgram.kt
    └── usb/UsbPtpPlugin.kt             # USB OTG PTP 橋接
```

### 建置

環境需求：Flutter 3.19+、Android SDK 34、JDK 17。

```bash
cd nikon_field_monitor
flutter pub get
flutter build apk --release
# 輸出：build/app/outputs/flutter-apk/app-release.apk
```

### 授權條款

MIT —— 詳見 [LICENSE](LICENSE)。以「原樣」提供，不附帶任何形式的擔保。

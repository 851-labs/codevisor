#if DEBUG
  import SwiftUI

  enum AppStoreScreenshotPage {
    static let copyButtonTitle = "Copy emoji"

    static var html: String {
      """
      <!doctype html>
      <html lang="en"><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <meta name="theme-color" content="\(AppStoreScreenshotData.colorScheme == .dark ? "#17161c" : "#fbfaf7")">
      <title>emojis</title>
      <style>
      * { box-sizing: border-box; }
      body { margin: 0; background: #fbfaf7; color: #1f1d24; font: 16px -apple-system, sans-serif; }
      main { max-width: 860px; margin: auto; padding: 28px 22px 120px; }
      nav { display: flex; align-items: center; justify-content: space-between; margin-bottom: 40px; }
      nav strong { font-size: 22px; letter-spacing: -0.5px; }
      .badge { color: #6b6676; border: 1px solid #e3e0e8; border-radius: 30px; padding: 7px 12px; font-size: 12px; }
      h1 { font-size: 44px; letter-spacing: -1.5px; line-height: 1.05; margin: 0 0 12px; }
      .intro { color: #6b6676; line-height: 1.5; max-width: 360px; margin: 0 0 28px; }
      .picker { background: white; border: 1px solid #ece9f0; border-radius: 24px; padding: 18px;
        box-shadow: 0 18px 40px -24px rgba(40, 30, 70, 0.35); }
      .search { background: #f4f2f7; border-radius: 12px; padding: 11px 14px; color: #8d8898; font-size: 15px; }
      .label { font-size: 12px; font-weight: 600; letter-spacing: 1px; color: #8d8898; margin: 18px 0 10px; }
      .tones { display: flex; gap: 8px; }
      .tone { width: 34px; height: 34px; border-radius: 50%; border: 2px solid transparent; }
      .tone.on { border-color: #6d5bd0; box-shadow: 0 0 0 3px #e7e2fb; }
      .grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 6px; font-size: 30px; text-align: center; }
      .grid span { padding: 8px 0; border-radius: 12px; }
      .grid .on { background: #efeafd; }
      button { margin-top: 18px; width: 100%; background: #6d5bd0; color: white; border: 0; border-radius: 14px;
        padding: 14px; font: 600 15px -apple-system, sans-serif; }
      @media (min-width: 650px) {
        main { display: grid; grid-template-columns: 1fr 1fr; gap: 34px; align-items: center; padding: 34px; }
        nav { grid-column: 1 / -1; margin-bottom: 8px; }
        h1 { font-size: 56px; }
      }
      body.dark { color-scheme: dark; background: #17161c; color: #f1eff6; }
      .dark .badge { border-color: #34313d; color: #a7a2b3; }
      .dark .intro, .dark .label { color: #a7a2b3; }
      .dark .picker { background: #211f28; border-color: #2f2c38; box-shadow: none; }
      .dark .search { background: #2b2833; color: #8d8898; }
      .dark .tone.on { border-color: #a898f5; box-shadow: 0 0 0 3px #3a3360; }
      .dark .grid .on { background: #332d4f; }
      .dark button { background: #a898f5; color: #17161c; }
      </style></head><body class="\(AppStoreScreenshotData.colorScheme == .dark ? "dark" : "light")"><main>
      <nav><strong>emojis</strong><span class="badge">3,790 emoji</span></nav>
      <section>
      <h1>Every emoji, in your tone.</h1>
      <p class="intro">Pick a skin tone once and every hand, face, and wave follows. We remember it next time.</p>
      </section>
      <section class="picker" aria-label="Emoji picker">
      <div class="search">Search emoji</div>
      <div class="label">SKIN TONE</div>
      <div class="tones">
      <span class="tone" style="background:#ffc93a"></span><span class="tone" style="background:#f7d7c4"></span>
      <span class="tone" style="background:#e0b590"></span><span class="tone on" style="background:#b98a5f"></span>
      <span class="tone" style="background:#8d5f3b"></span><span class="tone" style="background:#5c3d2a"></span>
      </div>
      <div class="label">PEOPLE</div>
      <div class="grid">
      <span class="on">👋🏽</span><span>👍🏽</span><span>🙌🏽</span><span>👏🏽</span><span>✌🏽</span><span>🤞🏽</span>
      <span>💪🏽</span><span>🙏🏽</span><span>🤙🏽</span><span>👌🏽</span><span>🫶🏽</span><span>🤘🏽</span>
      </div>
      <button>\(copyButtonTitle)</button>
      </section>
      </main></body></html>
      """
    }
  }
#endif

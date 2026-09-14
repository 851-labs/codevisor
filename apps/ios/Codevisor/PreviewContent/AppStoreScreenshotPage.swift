#if DEBUG
  /// A bundled example of a user's project, shown inside the real browser pane.
  /// No external fonts, assets, scripts, network requests, or live server.
  enum AppStoreScreenshotPage {
    static let html = """
      <!doctype html>
      <html lang="en"><head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <meta name="theme-color" content="#f7f5ef">
      <title>Daylight</title>
      <style>
      * { box-sizing: border-box; }
      body { margin: 0; background: #f7f5ef; color: #24372c; font: 16px -apple-system, sans-serif; }
      main { max-width: 850px; margin: auto; padding: 28px 24px 130px; }
      nav { display: flex; align-items: center; justify-content: space-between; margin-bottom: 44px; }
      nav strong { font-size: 23px; letter-spacing: -1px; }
      .badge { color: #526e56; border: 1px solid #ced8ca; border-radius: 30px; padding: 7px 12px; font-size: 12px; }
      .eyebrow { color: #66816c; font-size: 12px; letter-spacing: 2px; font-weight: 600; }
      h1 { font: 46px Georgia, serif; letter-spacing: -2px; margin: 12px 0; }
      .intro { line-height: 1.5; color: #718076; max-width: 340px; margin-bottom: 32px; }
      .timer { text-align: center; background: #e5ebdd; border-radius: 26px; padding: 26px 16px; }
      .timer p { font-size: 13px; margin: 0; color: #5c755e; }
      .ring { width: 200px; height: 200px; border: 7px solid #bdcdb3; border-top-color: #536f4c;
        border-right-color: #536f4c; border-radius: 50%; display: grid; place-content: center; margin: 24px auto; }
      .time { font-size: 49px; letter-spacing: -2px; font-weight: 300; }
      .ring span { font-size: 12px; color: #6d8066; margin-top: 6px; }
      button { background: #304b34; color: white; border: 0; border-radius: 30px; padding: 15px 36px;
        font: 15px -apple-system, sans-serif; }
      .tasks { margin-top: 30px; }
      h2 { font-size: 18px; font-weight: 500; }
      .task { border-top: 1px solid #e0e3d8; padding: 17px 0; display: flex; align-items: center; gap: 12px; }
      .check { border: 1px solid #aaba9d; border-radius: 50%; width: 21px; height: 21px; }
      .done { background: #dce7d4; color: #526b4d; text-align: center; font-size: 14px; }
      .muted { color: #81907e; text-decoration: line-through; }
      @media (min-width: 650px) {
        main { padding-top: 50px; } nav { margin-bottom: 68px; } h1 { font-size: 66px; }
        .intro { font-size: 19px; max-width: 490px; margin-bottom: 42px; }
        .timer { padding: 38px; } .ring { width: 270px; height: 270px; } .time { font-size: 64px; }
        .tasks { margin-top: 38px; } .task { padding: 22px 0; }
      }
      </style></head><body><main>
      <nav><strong>☀ Daylight</strong><span class="badge">Your daily space</span></nav>
      <div class="eyebrow">MAKE ROOM FOR WHAT MATTERS</div>
      <h1>One thing at a time.</h1>
      <p class="intro">A little structure. A little breathing room.<br>Find your focus and enjoy the work.</p>
      <section class="timer" aria-label="Focus timer"><p>FOCUS SESSION</p>
      <div class="ring"><div class="time">25:00</div><span>Time to settle in</span></div>
      <button>Start focus</button></section>
      <section class="tasks"><h2>A little progress today</h2>
      <div class="task"><span class="check done">✓</span><span class="muted">Make a little room to think</span></div>
      <div class="task"><span class="check"></span>Bring your next idea to life</div>
      <div class="task"><span class="check"></span>Step outside for a moment</div></section>
      </main></body></html>
      """
  }
#endif

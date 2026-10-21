import Foundation

/// A read-only browser view over the existing device and screenshot endpoints.
/// Embed the page so SwiftPM and the standalone app need no extra resource bundle.
enum WebPreview {
    static var response: HTTPResponse {
        HTTPResponse(
            contentType: "text/html; charset=utf-8",
            headers: ["Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"],
            body: Data(html.utf8))
    }

    static let html = #"""
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>iPhone Use · 实时画面</title>
        <style>
        :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        * { box-sizing: border-box; }
        body { margin: 0; background: #141619; color: #eef0f3; }
        .app { height: 100vh; height: 100dvh; display: grid; grid-template-rows: auto minmax(0, 1fr) auto; }
        header { padding: 18px 20px 14px; border-bottom: 1px solid #ffffff0e; }
        .title-row, .controls, footer { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
        h1 { margin: 0; font-size: 16px; font-weight: 600; letter-spacing: -.3px; }
        .badge { display: flex; align-items: center; gap: 6px; font-size: 12px; color: #969ca7; white-space: nowrap; }
        .dot { width: 6px; height: 6px; border-radius: 50%; background: #717783; }
        .live .dot { background: #62d4a0; box-shadow: 0 0 10px #62d4a033; }
        .live { color: #9fe5c2; }
        .controls { margin-top: 14px; }
        select, button { height: 34px; border: 1px solid #ffffff15; border-radius: 8px;
          background: #212429; color: inherit; padding: 0 10px; font: inherit; font-size: 12px; }
        select { min-width: 0; flex: 1; text-overflow: ellipsis; }
        button { cursor: pointer; white-space: nowrap; }
        button:hover { background: #2c3037; }
        :focus-visible { outline: 2px solid #8caeff; outline-offset: 3px; }
        main { position: relative; min-height: 0; padding: 18px; display: flex; align-items: center; justify-content: center;
          background: radial-gradient(ellipse at center, #20242b 0%, #141619 75%); overflow: hidden; }
        #screen { display: block; max-width: 100%; max-height: 100%; width: auto; height: auto; object-fit: contain;
          border-radius: 14px; box-shadow: 0 12px 48px #0006; }
        [hidden] { display: none !important; }
        .empty { text-align: center; max-width: 290px; padding: 24px 12px; }
        .phone { width: 48px; height: 80px; border: 2px solid #4a515e; border-radius: 12px; margin: 0 auto 24px;
          position: relative; }
        .phone::after { content: ''; position: absolute; width: 16px; height: 3px; border-radius: 2px;
          background: #4a515e; bottom: 6px; left: 14px; }
        h2 { margin: 0 0 10px; font-size: 16px; font-weight: 500; }
        .empty p { margin: 0; color: #8f97a4; font-size: 13px; line-height: 1.8; }
        footer { padding: 11px 20px; border-top: 1px solid #ffffff0e; color: #858e9b; font-size: 11px; }
        #dimensions { white-space: nowrap; }
        @media (max-width: 340px) { header { padding: 14px 12px; } main { padding: 10px; } footer { padding: 10px 12px; } }
        </style>
        </head>
        <body>
        <div class="app">
          <header>
            <div class="title-row">
              <h1>iPhone Use</h1>
              <span class="badge" id="badge"><span class="dot"></span><span id="state">连接中</span></span>
            </div>
            <div class="controls">
              <select id="devices" aria-label="选择 iPhone"><option value="">正在查找 iPhone…</option></select>
              <button id="pause" type="button" aria-pressed="false">暂停画面</button>
            </div>
          </header>
          <main>
            <img id="screen" alt="iPhone 实时画面" hidden>
            <div class="empty" id="empty" role="status">
              <div class="phone" aria-hidden="true"></div>
              <h2 id="message">正在连接 iPhone Use</h2>
              <p id="detail">手机画面将在这里显示。</p>
            </div>
          </main>
          <footer><span>通过 Codex 聊天控制手机</span><span id="dimensions">USB 画面</span></footer>
        </div>
        <script>
        'use strict';
        const select = document.getElementById('devices');
        const screen = document.getElementById('screen');
        const empty = document.getElementById('empty');
        const badge = document.getElementById('badge');
        const state = document.getElementById('state');
        const pause = document.getElementById('pause');
        const dimensions = document.getElementById('dimensions');
        let selected = new URLSearchParams(location.search).get('device') || '';
        let connected = false, paused = false, scanning = false;
        let generation = 0, imageURL = '', frameRequest = null;

        function showState(label, title, detail) {
          state.textContent = label;
          badge.classList.remove('live');
          empty.hidden = false;
          screen.hidden = true;
          document.getElementById('message').textContent = title;
          document.getElementById('detail').textContent = detail;
          dimensions.textContent = 'USB 画面';
        }
        function clearFrame() {
          generation++;
          if (frameRequest) frameRequest.abort();
          screen.removeAttribute('src');
          if (imageURL) URL.revokeObjectURL(imageURL);
          imageURL = '';
          screen.hidden = true;
        }
        function updateURL() {
          const url = new URL(location.href);
          if (selected) url.searchParams.set('device', selected);
          else url.searchParams.delete('device');
          history.replaceState(null, '', url);
        }
        async function scanDevices() {
          if (scanning || document.hidden) return;
          scanning = true;
          try {
            const response = await fetch('/devices', {cache: 'no-store', signal: AbortSignal.timeout(5000)});
            if (!response.ok) throw new Error('devices unavailable');
            const {devices} = await response.json();
            if (!Array.isArray(devices)) throw new Error('invalid devices');
            if (!selected && devices.length) { selected = devices[0].id; clearFrame(); updateURL(); }
            const wasConnected = connected;
            connected = devices.some(device => device.id === selected);
            const options = devices.map(device => new Option(
              (device.name || 'iPhone') + ' · ' + device.id, device.id));
            if (selected && !connected) options.unshift(new Option('已断开 · ' + selected, selected));
            if (!options.length) options.push(new Option('暂无连接的 iPhone', ''));
            // Keep focus and an open device picker stable while polling.
            if (JSON.stringify(options.map(o => [o.value, o.text])) !==
                JSON.stringify(Array.from(select.options, o => [o.value, o.text]))) {
              select.replaceChildren(...options);
            }
            select.value = selected;
            select.disabled = !devices.length && !selected;
            if (!connected) {
              if (wasConnected) clearFrame();
              showState('等待连接', selected ? 'iPhone 已断开' : '等待 iPhone 连接',
                selected ? '重新连接这台 iPhone 后，画面会自动恢复。也可以在上方选择其他手机。' :
                  '用 USB 连接 iPhone，解锁手机并选择“信任此电脑”。');
            }
          } catch (error) {
            connected = false;
            clearFrame();
            showState('未连接', '无法连接 iPhone Use', '请确认 Mac 上的主程序仍在运行，连接恢复后会自动重试。');
          } finally { scanning = false; }
        }
        async function refreshFrame() {
          let pendingURL = '';
          const currentGeneration = generation;
          const currentDevice = selected;
          let timeout;
          try {
            if (document.hidden || paused || !connected || !currentDevice) return;
            frameRequest = new AbortController();
            timeout = setTimeout(() => frameRequest?.abort(), 5000);
            const query = new URLSearchParams({device: currentDevice, maxEdge: '1200'});
            const response = await fetch('/screenshot?' + query, {cache: 'no-store', signal: frameRequest.signal});
            if (!response.ok) throw new Error('frame unavailable');
            pendingURL = URL.createObjectURL(await response.blob());
            const decoded = new Image();
            decoded.src = pendingURL;
            await decoded.decode();
            if (generation !== currentGeneration || selected !== currentDevice || document.hidden || paused) return;
            screen.src = pendingURL;
            if (imageURL) URL.revokeObjectURL(imageURL);
            imageURL = pendingURL;
            pendingURL = '';
            screen.hidden = false;
            empty.hidden = true;
            state.textContent = '实时画面';
            badge.classList.add('live');
            dimensions.textContent = decoded.naturalWidth + ' × ' + decoded.naturalHeight;
          } catch (error) {
            if (generation === currentGeneration && !paused && !document.hidden) {
              showState('等待画面', '暂时无法获取画面', '请解锁 iPhone，确认 USB 连接和 Mac 的相机授权。');
            }
          } finally {
            clearTimeout(timeout);
            frameRequest = null;
            if (pendingURL) URL.revokeObjectURL(pendingURL);
            // At most five frames per second, one request at a time. Hidden tabs send no frames.
            setTimeout(refreshFrame, paused || document.hidden ? 1000 : 200);
          }
        }
        select.addEventListener('change', () => {
          selected = select.value;
          clearFrame();
          connected = false;
          updateURL();
          showState('切换中', '正在连接所选 iPhone', '手机画面即将显示。');
          scanDevices();
        });
        pause.addEventListener('click', () => {
          paused = !paused;
          clearFrame();
          pause.textContent = paused ? '继续画面' : '暂停画面';
          pause.setAttribute('aria-pressed', String(paused));
          showState(paused ? '已暂停' : '连接中', paused ? '画面已暂停' : '正在恢复画面',
            paused ? '点击“继续画面”恢复实时预览。' : '请稍候。');
        });
        document.addEventListener('visibilitychange', () => {
          if (document.hidden) clearFrame();
          else scanDevices();
        });
        async function pollDevices() {
          await scanDevices();
          setTimeout(pollDevices, 2000);
        }
        pollDevices();
        refreshFrame();
        </script>
        </body>
        </html>
        """#
}

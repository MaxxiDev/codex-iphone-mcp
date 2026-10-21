import Foundation

/// A read-only browser view over the existing device and screenshot endpoints.
/// Embed the page so SwiftPM and the standalone app need no extra resource bundle.
/// Generated per request in the app's current language; `?lang=zh|en` pins one.
enum WebPreview {
    static func response(for language: AppLanguage) -> HTTPResponse {
        HTTPResponse(
            contentType: "text/html; charset=utf-8",
            headers: ["Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"],
            body: Data(html(for: language).utf8))
    }

    static func html(for language: AppLanguage) -> String {
        let table = StringsWeb(language: language)
        // The JS strings ride in as one JSON object so localized text (including
        // apostrophes) can never break the script's string literals.
        let l10nData =
            (try? JSONSerialization.data(withJSONObject: table.jsDictionary, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let l10n = String(decoding: l10nData, as: UTF8.self)
        return #"""
            <!doctype html>
            <html lang="\#(table.htmlLang)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\#(table.title)</title>
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
                  <span class="badge" id="badge"><span class="dot"></span><span id="state">\#(table.stateConnecting)</span></span>
                </div>
                <div class="controls">
                  <select id="devices" aria-label="\#(table.deviceSelectLabel)"><option value="">\#(table.deviceSearching)</option></select>
                  <button id="pause" type="button" aria-pressed="false">\#(table.pauseButton)</button>
                </div>
              </header>
              <main>
                <img id="screen" alt="\#(table.imgAlt)" hidden>
                <div class="empty" id="empty" role="status">
                  <div class="phone" aria-hidden="true"></div>
                  <h2 id="message">\#(table.emptyTitle)</h2>
                  <p id="detail">\#(table.emptyDetail)</p>
                </div>
              </main>
              <footer><span>\#(table.footerControl)</span><span id="dimensions">\#(table.usbFrame)</span></footer>
            </div>
            <script>
            'use strict';
            const L = \#(l10n);
            const PAGE_LANG = '\#(language.rawValue)';
            // A pinned ?lang= keeps its language even when the app switches.
            const LANG_PINNED = new URLSearchParams(location.search).has('lang');
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
              dimensions.textContent = L.usbFrame;
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
            async function checkLanguage() {
              // Reload within one poll (~2 s) when the app's language changes.
              if (LANG_PINNED) return;
              try {
                const response = await fetch('/config', {cache: 'no-store', signal: AbortSignal.timeout(5000)});
                if (!response.ok) return;
                const {language} = await response.json();
                if (language && language !== PAGE_LANG) location.reload();
              } catch (error) { /* unreachable app keeps the current language */ }
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
                if (selected && !connected) options.unshift(new Option(L.disconnectedPrefix + selected, selected));
                if (!options.length) options.push(new Option(L.noDevices, ''));
                // Keep focus and an open device picker stable while polling.
                if (JSON.stringify(options.map(o => [o.value, o.text])) !==
                    JSON.stringify(Array.from(select.options, o => [o.value, o.text]))) {
                  select.replaceChildren(...options);
                }
                select.value = selected;
                select.disabled = !devices.length && !selected;
                if (!connected) {
                  if (wasConnected) clearFrame();
                  showState(L.stateWaiting, selected ? L.disconnectedTitle : L.waitingDeviceTitle,
                    selected ? L.disconnectedDetail : L.waitingDeviceDetail);
                }
              } catch (error) {
                connected = false;
                clearFrame();
                showState(L.stateOffline, L.offlineTitle, L.offlineDetail);
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
                state.textContent = L.stateLive;
                badge.classList.add('live');
                dimensions.textContent = decoded.naturalWidth + ' × ' + decoded.naturalHeight;
              } catch (error) {
                if (generation === currentGeneration && !paused && !document.hidden) {
                  showState(L.stateWaitingFrame, L.frameFailTitle, L.frameFailDetail);
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
              showState(L.stateSwitching, L.switchingTitle, L.switchingDetail);
              scanDevices();
            });
            pause.addEventListener('click', () => {
              paused = !paused;
              clearFrame();
              pause.textContent = paused ? L.resumeButton : L.pauseButton;
              pause.setAttribute('aria-pressed', String(paused));
              showState(paused ? L.statePaused : L.stateConnecting, paused ? L.pausedTitle : L.resumingTitle,
                paused ? L.pausedDetail : L.resumingDetail);
            });
            document.addEventListener('visibilitychange', () => {
              if (document.hidden) clearFrame();
              else scanDevices();
            });
            async function pollDevices() {
              await scanDevices();
              await checkLanguage();
              setTimeout(pollDevices, 2000);
            }
            pollDevices();
            refreshFrame();
            </script>
            </body>
            </html>
            """#
    }
}

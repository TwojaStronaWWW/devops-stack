/**
 * TwojaStronaWWW - Universal Embeddable AI Chat Widget
 * 
 * Samodzielny, bezkonfliktowy widget czatu (Vanilla JS & CSS).
 * Użycie na dowolnej stronie:
 * <script src="https://ai.twojastronawww.pl/widget.js" data-site-id="katosalsahub" defer></script>
 */
(function() {
  'use strict';

  // Pobranie konfiguracji ze skryptu ładującego
  const currentScript = document.currentScript || (function() {
    const scripts = document.getElementsByTagName('script');
    return scripts[scripts.length - 1];
  })();

  const SITE_ID = currentScript?.getAttribute('data-site-id') || 'katosalsahub';
  const ROUTER_URL = currentScript?.getAttribute('data-router-url') || 'https://ai.twojastronawww.pl/chat-router.php';
  const TITLE = currentScript?.getAttribute('data-title') || 'Asystent AI';

  // Zapobieganie wielokrotnemu wstrzykiwaniu
  if (document.getElementById('tsw-ai-widget-root')) return;

  // Wstrzyknięcie stylów CSS w izolowany sposób
  const style = document.createElement('style');
  style.id = 'tsw-ai-widget-styles';
  style.textContent = `
    .tsw-ai-btn {
      position: fixed;
      bottom: 24px;
      right: 24px;
      width: 58px;
      height: 58px;
      border-radius: 50%;
      background: linear-gradient(135deg, #00d2ff 0%, #3a7bd5 100%);
      color: #ffffff;
      box-shadow: 0 8px 24px rgba(0, 210, 255, 0.35);
      border: none;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 999999;
      transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.2s;
    }
    .tsw-ai-btn:hover {
      transform: scale(1.08);
      box-shadow: 0 12px 30px rgba(0, 210, 255, 0.45);
    }
    .tsw-ai-btn svg {
      width: 26px;
      height: 26px;
      fill: currentColor;
    }
    .tsw-ai-window {
      position: fixed;
      bottom: 96px;
      right: 24px;
      width: 380px;
      max-width: calc(100vw - 32px);
      height: 540px;
      max-height: calc(100vh - 120px);
      background: #0f172a;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 18px;
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.5);
      z-index: 999999;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      transition: opacity 0.25s, transform 0.25s, visibility 0.25s;
      opacity: 0;
      transform: translateY(16px) scale(0.96);
      visibility: hidden;
      pointer-events: none;
    }
    .tsw-ai-window.tsw-open {
      opacity: 1;
      transform: translateY(0) scale(1);
      visibility: visible;
      pointer-events: auto;
    }
    .tsw-ai-header {
      background: #1e293b;
      padding: 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    }
    .tsw-ai-header-title {
      font-size: 15px;
      font-weight: 600;
      color: #f8fafc;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .tsw-ai-status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #10b981;
      box-shadow: 0 0 8px #10b981;
    }
    .tsw-ai-close {
      background: transparent;
      border: none;
      color: #94a3b8;
      cursor: pointer;
      font-size: 20px;
      padding: 4px;
      line-height: 1;
    }
    .tsw-ai-close:hover { color: #fff; }
    .tsw-ai-messages {
      flex: 1;
      overflow-y: auto;
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .tsw-ai-msg {
      max-width: 85%;
      padding: 10px 14px;
      border-radius: 14px;
      font-size: 14px;
      line-height: 1.45;
      word-wrap: break-word;
    }
    .tsw-ai-msg-bot {
      background: #1e293b;
      color: #e2e8f0;
      align-self: flex-start;
      border-bottom-left-radius: 4px;
      border: 1px solid rgba(255, 255, 255, 0.05);
    }
    .tsw-ai-msg-user {
      background: linear-gradient(135deg, #00d2ff 0%, #3a7bd5 100%);
      color: #ffffff;
      align-self: flex-end;
      border-bottom-right-radius: 4px;
    }
    .tsw-ai-input-bar {
      padding: 12px;
      background: #1e293b;
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      display: flex;
      gap: 8px;
    }
    .tsw-ai-input {
      flex: 1;
      background: #0f172a;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 10px;
      padding: 10px 14px;
      color: #fff;
      font-size: 14px;
      outline: none;
    }
    .tsw-ai-input:focus {
      border-color: #00d2ff;
    }
    .tsw-ai-send {
      background: #00d2ff;
      border: none;
      border-radius: 10px;
      padding: 0 16px;
      color: #0f172a;
      font-weight: 600;
      cursor: pointer;
      transition: opacity 0.2s;
    }
    .tsw-ai-send:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .tsw-ai-typing {
      font-size: 12px;
      color: #94a3b8;
      font-style: italic;
    }
  `;
  document.head.appendChild(style);

  // Budowa struktury HTML
  const root = document.createElement('div');
  root.id = 'tsw-ai-widget-root';
  root.innerHTML = `
    <button class="tsw-ai-btn" id="tswAiToggleBtn" aria-label="Otwórz czat AI">
      <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
    </button>

    <div class="tsw-ai-window" id="tswAiWindow">
      <div class="tsw-ai-header">
        <div class="tsw-ai-header-title">
          <span class="tsw-ai-status-dot"></span>
          <span>${TITLE}</span>
        </div>
        <button class="tsw-ai-close" id="tswAiCloseBtn">&times;</button>
      </div>

      <div class="tsw-ai-messages" id="tswAiMessages">
        <div class="tsw-ai-msg tsw-ai-msg-bot">
          Cześć! W czym mogę Ci dzisiaj pomóc? Odpowiadam na pytania dotyczące oferty, cennika i grafiku.
        </div>
      </div>

      <form class="tsw-ai-input-bar" id="tswAiForm">
        <input type="text" class="tsw-ai-input" id="tswAiInput" placeholder="Napisz pytanie..." required autocomplete="off" />
        <button type="submit" class="tsw-ai-send" id="tswAiSendBtn">Wyślij</button>
      </form>
    </div>
  `;
  document.body.appendChild(root);

  // Logika interakcji
  const toggleBtn = document.getElementById('tswAiToggleBtn');
  const closeBtn = document.getElementById('tswAiCloseBtn');
  const chatWindow = document.getElementById('tswAiWindow');
  const chatForm = document.getElementById('tswAiForm');
  const chatInput = document.getElementById('tswAiInput');
  const messagesContainer = document.getElementById('tswAiMessages');
  const sendBtn = document.getElementById('tswAiSendBtn');

  function toggleChat() {
    chatWindow.classList.toggle('tsw-open');
    if (chatWindow.classList.contains('tsw-open')) {
      chatInput.focus();
    }
  }

  toggleBtn.addEventListener('click', toggleChat);
  closeBtn.addEventListener('click', toggleChat);

  chatForm.addEventListener('submit', async function(e) {
    e.preventDefault();
    const text = chatInput.value.trim();
    if (!text) return;

    // Dodanie wiadomości użytkownika
    const userMsg = document.createElement('div');
    userMsg.className = 'tsw-ai-msg tsw-ai-msg-user';
    userMsg.textContent = text;
    messagesContainer.appendChild(userMsg);
    chatInput.value = '';

    // Wskaźnik pisania
    const typingMsg = document.createElement('div');
    typingMsg.className = 'tsw-ai-msg tsw-ai-msg-bot tsw-ai-typing';
    typingMsg.textContent = 'Asystent pisze...';
    messagesContainer.appendChild(typingMsg);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;

    sendBtn.disabled = true;

    try {
      const res = await fetch(ROUTER_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          site_id: SITE_ID,
          question: text
        })
      });

      const data = await res.json();
      typingMsg.remove();

      const botMsg = document.createElement('div');
      botMsg.className = 'tsw-ai-msg tsw-ai-msg-bot';

      if (res.ok && data.success) {
        botMsg.textContent = data.answer;
      } else {
        botMsg.textContent = data.error || 'Przepraszam, wystąpił problem z połączeniem. Spróbuj ponownie później.';
      }
      messagesContainer.appendChild(botMsg);

    } catch (err) {
      typingMsg.remove();
      const errorMsg = document.createElement('div');
      errorMsg.className = 'tsw-ai-msg tsw-ai-msg-bot';
      errorMsg.textContent = 'Błąd sieci. Sprawdź połączenie z internetem.';
      messagesContainer.appendChild(errorMsg);
    } finally {
      sendBtn.disabled = false;
      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }
  });

})();

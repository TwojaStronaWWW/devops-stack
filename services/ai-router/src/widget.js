/**
 * TwojaStronaWWW - Universal Embeddable AI Agent Widget v2.0
 * 
 * Samodzielny, bezkonfliktowy widget एजenta AI (Vanilla JS & CSS):
 * - Pamięć rozmowy (Multi-Turn Context + sessionStorage)
 * - Bezpieczne formatowanie Markdown (pogrubienia, listy, klikalne linki/e-maile)
 * - Sugerowane szybkie pytania (Quick Replies per site_id)
 * 
 * Użycie na dowolnej stronie:
 * <script src="https://ai.twojastronawww.pl/widget.js" data-site-id="katosalsahub" defer></script>
 */
(function() {
  'use strict';

  const currentScript = document.currentScript || (function() {
    const scripts = document.getElementsByTagName('script');
    return scripts[scripts.length - 1];
  })();

  const SITE_ID = (currentScript?.getAttribute('data-site-id') || 'katosalsahub').toLowerCase();
  const ROUTER_URL = currentScript?.getAttribute('data-router-url') || 'https://ai.twojastronawww.pl/chat-router.php';
  const TITLE = currentScript?.getAttribute('data-title') || 'Asystent AI';
  const STORAGE_KEY = 'tsw_ai_history_' + SITE_ID;

  if (document.getElementById('tsw-ai-widget-root')) return;

  // Domyślne podpowiedzi szybkich pytań dopasowane do strony (zgodne z _site-template/assets/js/ai-widget.js i warm-ai-cache.sh)
  const QUICK_PROMPTS_MAP = {
    twojastronawww: [
      'Ile kosztuje strona WWW?',
      'Dlaczego kod zamiast WordPressa?',
      'Wdrożenie czatbota AI (RAG)',
      'Jak wygląda współpraca?'
    ],
    fuegolingua: [
      'Bezpłatna lekcja próbna',
      'Ile kosztuje kurs hiszpańskiego?',
      'Zajęcia indywidualne czy grupowe?',
      'Hiszpański w biznesie / branżowy'
    ],
    katosalsahub: [
      'Czym jest Salsopedia i jak z niej korzystać?',
      'Co to jest Enchufla i Dile Que No?',
      'Gdzie tańczymy i jak działa Radio?',
      'Jak dodać lub poprawić hasło w Salsopedii?'
    ],
    raricart: [
      'Jak działa kreator okładek AI?',
      'Ile trwa i kosztuje wysyłka obrazu?',
      'Jakie rozmiary obrazów są dostępne?',
      'Z jakich materiałów wykonane jest płótno?'
    ],
    dancepuls: [
      'Czym jest aplikacja DancePuls?',
      'Jakie style tańca obsługuje DancePuls?',
      'Jak działa trening rytmu i clave?',
      'Czy DancePuls jest darmowy?'
    ]
  };
  const quickPrompts = QUICK_PROMPTS_MAP[SITE_ID] || QUICK_PROMPTS_MAP.twojastronawww;

  /**
   * Bezpieczny mikro-parser Markdown (100% odporny na XSS)
   */
  function formatMarkdown(rawText) {
    if (!rawText) return '';
    // 1. Escapowanie HTML
    let safe = String(rawText)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');

    // 2. Pogrubienia **tekst**
    safe = safe.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');

    // 3. Klikalne adresy URL (https://...)
    safe = safe.replace(
      /(https?:\/\/[^\s<)]+)/g,
      '<a href="$1" target="_blank" rel="noopener noreferrer" class="tsw-ai-link">$1</a>'
    );

    // 4. Klikalne adresy e-mail
    safe = safe.replace(
      /([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/g,
      '<a href="mailto:$1" class="tsw-ai-link">$1</a>'
    );

    // 5. Proste wypunktowania i podział na linie
    const lines = safe.split(/\r?\n/);
    let html = '';
    let inList = false;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      const bulletMatch = line.match(/^[-*•]\s+(.+)$/);
      if (bulletMatch) {
        if (!inList) {
          html += '<ul class="tsw-ai-list">';
          inList = true;
        }
        html += '<li>' + bulletMatch[1] + '</li>';
      } else {
        if (inList) {
          html += '</ul>';
          inList = false;
        }
        if (line !== '') {
          html += (html && !html.endsWith('</ul>') ? '<br>' : '') + line;
        } else if (html && !html.endsWith('<br>')) {
          html += '<br>';
        }
      }
    }
    if (inList) {
      html += '</ul>';
    }
    return html;
  }

  // Wstrzyknięcie stylów CSS
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
      width: 390px;
      max-width: calc(100vw - 32px);
      height: 560px;
      max-height: calc(100vh - 120px);
      background: #0f172a;
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 18px;
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.55);
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
      padding: 14px 16px;
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
    .tsw-ai-header-actions {
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .tsw-ai-icon-btn {
      background: transparent;
      border: none;
      color: #94a3b8;
      cursor: pointer;
      font-size: 16px;
      padding: 4px 6px;
      border-radius: 6px;
      line-height: 1;
      transition: color 0.15s, background 0.15s;
    }
    .tsw-ai-icon-btn:hover {
      color: #fff;
      background: rgba(255, 255, 255, 0.08);
    }
    .tsw-ai-messages {
      flex: 1;
      overflow-y: auto;
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .tsw-ai-msg {
      max-width: 86%;
      padding: 10px 14px;
      border-radius: 14px;
      font-size: 14px;
      line-height: 1.5;
      word-wrap: break-word;
    }
    .tsw-ai-msg strong {
      color: #38bdf8;
      font-weight: 600;
    }
    .tsw-ai-list {
      margin: 6px 0 4px 18px;
      padding: 0;
    }
    .tsw-ai-list li {
      margin-bottom: 4px;
    }
    .tsw-ai-link {
      color: #38bdf8;
      text-decoration: underline;
      word-break: break-all;
    }
    .tsw-ai-msg-bot {
      background: #1e293b;
      color: #e2e8f0;
      align-self: flex-start;
      border-bottom-left-radius: 4px;
      border: 1px solid rgba(255, 255, 255, 0.06);
    }
    .tsw-ai-msg-user {
      background: linear-gradient(135deg, #00d2ff 0%, #3a7bd5 100%);
      color: #ffffff;
      align-self: flex-end;
      border-bottom-right-radius: 4px;
    }
    .tsw-ai-chips {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      padding: 0 16px 10px;
    }
    .tsw-ai-chip {
      background: rgba(56, 189, 248, 0.12);
      border: 1px solid rgba(56, 189, 248, 0.3);
      color: #bae6fd;
      border-radius: 999px;
      padding: 5px 11px;
      font-size: 12px;
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s, transform 0.1s;
    }
    .tsw-ai-chip:hover {
      background: rgba(56, 189, 248, 0.24);
      border-color: #38bdf8;
      color: #fff;
      transform: translateY(-1px);
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
      border: 1px solid rgba(255, 255, 255, 0.12);
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
        <div class="tsw-ai-header-actions">
          <button class="tsw-ai-icon-btn" id="tswAiClearBtn" title="Nowa rozmowa">&#x21bb;</button>
          <button class="tsw-ai-icon-btn" id="tswAiCloseBtn" title="Zamknij">&times;</button>
        </div>
      </div>

      <div class="tsw-ai-messages" id="tswAiMessages"></div>
      <div class="tsw-ai-chips" id="tswAiChips"></div>

      <form class="tsw-ai-input-bar" id="tswAiForm">
        <input type="text" class="tsw-ai-input" id="tswAiInput" placeholder="Napisz pytanie..." required autocomplete="off" />
        <button type="submit" class="tsw-ai-send" id="tswAiSendBtn">Wyślij</button>
      </form>
    </div>
  `;
  document.body.appendChild(root);

  const toggleBtn = document.getElementById('tswAiToggleBtn');
  const closeBtn = document.getElementById('tswAiCloseBtn');
  const clearBtn = document.getElementById('tswAiClearBtn');
  const chatWindow = document.getElementById('tswAiWindow');
  const chatForm = document.getElementById('tswAiForm');
  const chatInput = document.getElementById('tswAiInput');
  const messagesContainer = document.getElementById('tswAiMessages');
  const chipsContainer = document.getElementById('tswAiChips');
  const sendBtn = document.getElementById('tswAiSendBtn');

  let conversationHistory = [];
  try {
    const saved = sessionStorage.getItem(STORAGE_KEY);
    if (saved) {
      const parsed = JSON.parse(saved);
      if (Array.isArray(parsed)) conversationHistory = parsed.slice(-8);
    }
  } catch (_) {}

  function saveHistory() {
    try {
      sessionStorage.setItem(STORAGE_KEY, JSON.stringify(conversationHistory.slice(-8)));
    } catch (_) {}
  }

  function appendMessageElement(role, text) {
    const msg = document.createElement('div');
    msg.className = 'tsw-ai-msg ' + (role === 'user' ? 'tsw-ai-msg-user' : 'tsw-ai-msg-bot');
    if (role === 'user') {
      msg.textContent = text;
    } else {
      msg.innerHTML = formatMarkdown(text);
    }
    messagesContainer.appendChild(msg);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
  }

  function renderInitialView() {
    messagesContainer.innerHTML = '';
    appendMessageElement(
      'model',
      'Cześć! Jestem wirtualnym doradcą. W czym mogę Ci dzisiaj pomóc? Pytaj śmiało o ofertę, cennik i zapisy.'
    );
    for (let i = 0; i < conversationHistory.length; i++) {
      appendMessageElement(conversationHistory[i].role, conversationHistory[i].text);
    }
    renderChips();
  }

  function renderChips() {
    chipsContainer.innerHTML = '';
    if (conversationHistory.length > 0) {
      chipsContainer.style.display = 'none';
      return;
    }
    chipsContainer.style.display = 'flex';
    quickPrompts.forEach(function(promptText) {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'tsw-ai-chip';
      chip.textContent = promptText;
      chip.addEventListener('click', function() {
        sendAnalyticsBeacon({ type: 'event', event: 'quick_prompt_click' });
        sendQuestion(promptText);
      });
      chipsContainer.appendChild(chip);
    });
  }

  const ANALYTICS_URL = ROUTER_URL.replace(/\/chat-router\.php.*$/, '/analytics');

  function sendAnalyticsBeacon(extra) {
    try {
      const loc = window.location || {};
      const params = new URLSearchParams(loc.search || '');
      const rawPath = (loc.pathname || '/') + (loc.hash || '');
      const payload = Object.assign({
        site_id: SITE_ID,
        type: 'pageview',
        path: rawPath || '/',
        referrer: document.referrer || '',
        utm_source: params.get('utm_source') || '',
        utm_term: params.get('utm_term') || params.get('q') || ''
      }, extra || {});
      const body = JSON.stringify(payload);
      let sent = false;
      if (typeof navigator !== 'undefined' && typeof navigator.sendBeacon === 'function') {
        try {
          sent = navigator.sendBeacon(ANALYTICS_URL, body);
        } catch (_) {}
      }
      if (!sent && typeof fetch === 'function') {
        fetch(ANALYTICS_URL, {
          method: 'POST',
          body: body,
          keepalive: true,
          mode: 'cors',
          credentials: 'omit'
        }).catch(function() {});
      }
    } catch (_) {}
  }

  function toggleChat() {
    chatWindow.classList.toggle('tsw-open');
    if (chatWindow.classList.contains('tsw-open')) {
      chatInput.focus();
      sendAnalyticsBeacon({ type: 'event', event: 'chat_open' });
    }
  }

  toggleBtn.addEventListener('click', toggleChat);
  closeBtn.addEventListener('click', toggleChat);
  clearBtn.addEventListener('click', function() {
    conversationHistory = [];
    saveHistory();
    renderInitialView();
  });

  async function sendQuestion(text) {
    const trimmed = text.trim();
    if (!trimmed || sendBtn.disabled) return;

    chipsContainer.style.display = 'none';
    appendMessageElement('user', trimmed);
    chatInput.value = '';

    const typingMsg = document.createElement('div');
    typingMsg.className = 'tsw-ai-msg tsw-ai-msg-bot tsw-ai-typing';
    typingMsg.textContent = 'Asystent analizuje...';
    messagesContainer.appendChild(typingMsg);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;

    sendBtn.disabled = true;

    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timeoutId = controller ? setTimeout(function() { controller.abort(); }, 9000) : null;

    try {
      const res = await fetch(ROUTER_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: controller ? controller.signal : undefined,
        body: JSON.stringify({
          site_id: SITE_ID,
          question: trimmed,
          history: conversationHistory.slice(-8)
        })
      });

      const data = await res.json();
      typingMsg.remove();

      if (res.ok && data.success) {
        appendMessageElement('model', data.answer);
        conversationHistory.push({ role: 'user', text: trimmed });
        conversationHistory.push({ role: 'model', text: data.answer });
        conversationHistory = conversationHistory.slice(-8);
        saveHistory();
      } else {
        appendMessageElement(
          'model',
          data.error || 'Przepraszam, wystąpił problem z połączeniem. Spróbuj ponownie za chwilę.'
        );
      }
    } catch (_) {
      typingMsg.remove();
      appendMessageElement('model', 'Błąd sieci. Sprawdź połączenie z internetem.');
    } finally {
      if (timeoutId) clearTimeout(timeoutId);
      sendBtn.disabled = false;
      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }
  }

  chatForm.addEventListener('submit', function(e) {
    e.preventDefault();
    sendQuestion(chatInput.value);
  });

  renderInitialView();

  // Automatyczny Cookieless Web Analytics & Core Web Vitals (Zero-PII)
  if (!window.__TSW_ANALYTICS_ACTIVE__) {
    window.__TSW_ANALYTICS_ACTIVE__ = true;
    let lcpMeasured = 0;
    try {
      if (typeof PerformanceObserver !== 'undefined') {
        const po = new PerformanceObserver(function(list) {
          const entries = list.getEntries();
          if (entries && entries.length > 0) {
            lcpMeasured = Math.round(entries[entries.length - 1].startTime || 0);
          }
        });
        po.observe({ type: 'largest-contentful-paint', buffered: true });
      }
    } catch (_) {}

    setTimeout(function() {
      sendAnalyticsBeacon(lcpMeasured > 0 ? { type: 'pageview', lcp_ms: lcpMeasured } : { type: 'pageview' });
    }, 600);

    window.addEventListener('hashchange', function() {
      sendAnalyticsBeacon({ type: 'pageview' });
    });

    setTimeout(function() {
      if (document.visibilityState !== 'hidden') {
        sendAnalyticsBeacon({ type: 'engaged' });
      }
    }, 15000);

    document.addEventListener('click', function(e) {
      const target = e.target && e.target.closest ? e.target : null;
      if (!target) return;
      const link = target.closest('a[href]');
      if (link) {
        const href = String(link.getAttribute('href') || '');
        if (href.startsWith('tel:')) {
          sendAnalyticsBeacon({ type: 'event', event: 'cta_phone_click' });
        } else if (href.startsWith('mailto:')) {
          sendAnalyticsBeacon({ type: 'event', event: 'cta_email_click' });
        }
      }
      const radioBtn = target.closest('#radio-toggle, .radio-toggle, [data-radio-toggle], #radioPlayBtn');
      if (radioBtn) {
        sendAnalyticsBeacon({ type: 'event', event: 'radio_play' });
      }
    });

    document.addEventListener('submit', function(e) {
      const form = e.target;
      if (form && form.id !== 'tsw-ai-form' && (form.id === 'contactForm' || (form.classList && form.classList.contains('contact-form')))) {
        sendAnalyticsBeacon({ type: 'event', event: 'contact_form_submit' });
      }
    });
  }
})();


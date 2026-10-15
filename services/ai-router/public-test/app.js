/**
 * TwojaStronaWWW - AI Router Client
 * 
 * Czysty Vanilla JavaScript (bez frameworków i zewnętrznych bibliotek).
 * Komunikuje się z centralnym routerem AI na serwerze VPS.
 */

// Konfiguracja domyślna frontendu (zgodnie z wytycznymi zadania)
const SITE_ID = 'katosalsahub';

// Elementy DOM
const chatForm = document.getElementById('chatForm');
const questionInput = document.getElementById('questionInput');
const submitBtn = document.getElementById('submitBtn');
const btnText = document.getElementById('btnText');
const siteSelect = document.getElementById('siteSelect');
const routerUrlInput = document.getElementById('routerUrlInput');
const responseCard = document.getElementById('responseCard');
const responseBody = document.getElementById('responseBody');
const responseLatency = document.getElementById('responseLatency');
const errorAlert = document.getElementById('errorAlert');

// Pamięć rozmowy per site_id w testerze
const historyBySite = {};

if (siteSelect) {
  siteSelect.value = SITE_ID;
}

/**
 * Ustawia stan ładowania interfejsu (loading state)
 * @param {boolean} isLoading
 */
function setLoading(isLoading) {
  if (isLoading) {
    submitBtn.disabled = true;
    btnText.innerHTML = '<span class="spinner"></span> Myślę...';
    errorAlert.style.display = 'none';
    errorAlert.textContent = '';
  } else {
    submitBtn.disabled = false;
    btnText.textContent = 'Wyślij zapytanie';
  }
}

/**
 * Wyświetla komunikat błędu
 * @param {string} message
 */
function showError(message) {
  errorAlert.textContent = message;
  errorAlert.style.display = 'block';
  responseCard.style.display = 'none';
}

/**
 * Obsługa wysyłania formularza
 */
chatForm.addEventListener('submit', async (e) => {
  e.preventDefault();

  const question = questionInput.value.trim();
  if (!question) return;

  // Pobranie site_id (z selektora lub stałej) oraz URL routera
  const currentSiteId = siteSelect ? siteSelect.value : SITE_ID;
  const routerUrl = routerUrlInput.value.trim() || 'http://localhost:8085/chat-router.php';
  const siteHistory = historyBySite[currentSiteId] || [];

  setLoading(true);
  const startTime = performance.now();

  try {
    const response = await fetch(routerUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        site_id: currentSiteId,
        question: question,
        history: siteHistory.slice(-8)
      })
    });

    const endTime = performance.now();
    const latencySec = ((endTime - startTime) / 1000).toFixed(2);

    let data;
    try {
      data = await response.json();
    } catch {
      throw new Error(`Niepoprawna odpowiedź serwera (kod HTTP ${response.status}).`);
    }

    if (!response.ok || !data.success) {
      if (response.status === 429) {
        throw new Error(`Przekroczono limit zapytań (Rate Limit). Odczekaj ${data.retry_after || 60} sekund.`);
      }
      if (response.status === 403) {
        throw new Error('Dostęp zablokowany przez CORS: Twoja domena nie jest na białej liście routera.');
      }
      throw new Error(data.error || `Błąd serwera (HTTP ${response.status})`);
    }

    // Zapisanie do historii konwersacji
    siteHistory.push({ role: 'user', text: question });
    siteHistory.push({ role: 'model', text: data.answer });
    historyBySite[currentSiteId] = siteHistory.slice(-8);

    // Wyświetlenie sukcesu
    const modelBadge = data.model ? ` • ${data.model}` : '';
    responseBody.textContent = data.answer;
    responseLatency.textContent = `Czas: ${latencySec}s • [${data.site_id}]${modelBadge}`;
    responseCard.style.display = 'block';

  } catch (err) {
    showError(err.message || 'Wystąpił błąd podczas połączenia z routerem AI.');
  } finally {
    setLoading(false);
  }
});

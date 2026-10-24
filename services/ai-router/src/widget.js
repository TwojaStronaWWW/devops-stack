(function () {
"use strict";
/**
 * TwojaStronaWWW — Uniwersalny Moduł Asystenta AI (Single Source of Truth v4.0)
 *
 * Architektura Platform-First & Zero-Bloat (Vanilla ES6+, ISO 27001, WCAG 2.1 AA):
 * - Jedno Źródło Prawdy (Single Source of Truth): wspólna geometria, szerokości, odstępy,
 *   klikalność, dostępność (ARIA), dyktowanie głosowe (Web Speech API), Response Cache i analityka
 * - Warstwa Kolorów oparta o CSS Custom Properties (--tsw-ai-*), dziedzicząca z lokalnego CSS strony,
 *   presetów per site_id lub atrybutów HTML (data-primary, data-accent, data-bg, data-surface)
 * - Komunikacja z centralnym routerem AI na VPS (https://ai.twojastronawww.pl/chat-router.php)
 * - Obsługa 11-modelowej kaskady High-Availability (6 dostawców API) po stronie VPS
 * - Priorytetowe przekazywanie leadów kontaktowych (telefon / e-mail omija cache i wyzwala Ntfy 1-Klik)
 * - Dynamiczne Centrum Wiedzy ze strony i bazy JSON/Wiki (np. Salsopedia) z wyszukiwaniem fleksyjnym
 * - Dwupoziomowy Response Cache z automatyczną inwalidacją po zmianie wersji wiedzy (kbVersion)
 * - Bezpieczny mikro-parser Markdown (100% odporny na XSS) z obsługą list i linków wewnętrznych
 * - Automatyczne zamykanie okna czatu po kliknięciu w kotwicę (#kontakt) lub poza oknem czatu
 */

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
    'Co dzieje się w Wolnych Ludziach w niedzielę (15:00–18:00)?',
    'Gdzie tańczymy w Katowicach i gdzie za darmo zaparkować?',
    'Czym zajmuje się społeczność i Fundacja Kato Salsa Hub?',
    'Wyjaśnij figury: Dile Que No, Enchufla i Setenta'
  ],
  raricart: [
    'Ile kosztują stacje Live Food (Lody, Pancakes, Sery)?',
    'Jak działają pakiety łączone 2 i 3 stanowisk z rabatem?',
    'Jak wygląda dojazd i montaż stacji na weselu lub evencie?',
    'Jak sprawdzić wolny termin i zarezerwować datę?'
  ],
  dancepuls: [
    'Czym jest aplikacja DancePuls?',
    'Jakie style tańca obsługuje DancePuls?',
    'Jak działa trening rytmu i clave?',
    'Czy DancePuls jest darmowy?'
  ],
  'radar-p1': [
    'Co zrobić w gabinecie lub aptece, gdy nie działa e-Recepta (P1)?',
    'Jak odróżnić awarię centralną P1/NFZ od problemu z lokalnym łączem?',
    'Co zrobić w rejestracji, gdy nie działa eWUŚ?',
    'Jak działa tryb awaryjny i offline24 w KSeF oraz ZUS e-ZLA?'
  ]
};

const THEME_PRESETS = {
  twojastronawww: {
    primary: 'var(--color-primary, #2563eb)',
    accent: 'var(--color-primary-hover, #7c3aed)',
    highlight: '#60a5fa',
    bg: 'var(--color-bg, #0f172a)',
    surface: 'var(--color-surface, #1e293b)',
    text: 'var(--color-text, #f8fafc)',
    muted: 'var(--color-text-muted, #94a3b8)',
    onPrimary: '#ffffff'
  },
  fuegolingua: {
    primary: '#c92a2a',
    accent: '#e8590c',
    highlight: '#ffd43b',
    bg: '#0f172a',
    surface: '#1e293b',
    text: '#f8fafc',
    muted: '#cbd5e1',
    onPrimary: '#ffffff'
  },
  katosalsahub: {
    primary: 'var(--red, #e63946)',
    accent: 'var(--orange, #f4a261)',
    highlight: 'var(--yellow, #fbbf24)',
    bg: 'var(--bg, #0f172a)',
    surface: 'var(--card, #1e293b)',
    text: '#f8fafc',
    muted: '#cbd5e1',
    onPrimary: '#ffffff'
  },
  raricart: {
    primary: 'var(--color-text-dark, #3d4a3a)',
    accent: 'var(--color-accent-dark, #6b7d63)',
    highlight: 'var(--color-gold, #d4af37)',
    bg: '#1c241b',
    surface: '#283326',
    text: '#f5f1eb',
    muted: '#c2cbbd',
    onPrimary: '#ffffff'
  },
  dancepuls: {
    primary: '#e11d48',
    accent: '#7c3aed',
    highlight: '#38bdf8',
    bg: '#0f172a',
    surface: '#1e293b',
    text: '#f8fafc',
    muted: '#94a3b8',
    onPrimary: '#ffffff'
  },
  'radar-p1': {
    primary: 'var(--accent, #2563eb)',
    accent: '#0284c7',
    highlight: '#38bdf8',
    bg: 'var(--bg, #0f172a)',
    surface: 'var(--surface, #1e293b)',
    text: 'var(--text, #f8fafc)',
    muted: 'var(--text-muted, #94a3b8)',
    onPrimary: '#ffffff'
  }
};

const CATEGORY_LABELS_PL = {
  steps: 'Kroki (Podstawy)',
  figures: 'Figury (Casino / Rueda)',
  dance: 'Taniec',
  styles: 'Style Tańca',
  music: 'Muzyka',
  instruments: 'Instrumenty',
  bands: 'Zespoły i Artyści',
  history: 'Historia',
  gods: 'Bogowie (Orishas)',
  instructors: 'Instruktorzy',
  schools: 'Szkoły Tańca'
};

const KSH_CORE_CONTEXT = [
  'PODSTAWOWE INFORMACJE O DZIAŁALNOŚCI KATO SALSA HUB (SALSA KATOWICE):',
  '- Kim jesteśmy (WAŻNE — TYLKO SALSA): Jesteśmy niezależną społecznością i Fundacją Kato Salsa Hub (https://katosalsahub.pl/) łączącą miłośników Salsy (Salsy Kubańskiej / Casino, Timby, Ruedy de Casino, Sonu Kubańskiego, Rumby oraz Salsy Liniowej) w Katowicach i na całym Śląsku ponad podziałami szkolnymi. Nasza społeczność i fundacja skupia się wyłącznie na Salsie i kulturze kubańskiej (nie zajmujemy się bachatą ani kizombą).',
  '- NIEDZIELNE POTAŃCÓWKI W WOLNYCH LUDZIACH (POD DACHEM): W KAŻDĄ NIEDZIELĘ w godz. 15:00–18:00 spotykamy się i tańczymy Salsę w lokalu Wolni Ludzie (ul. Mariacka 2, Katowice — róg ul. Mielęckiego). Wstęp otwarty dla każdego poziomu (od początkujących po zaawansowanych), nie trzeba mieć własnej pary! W niedziele oraz po godz. 17:00 wszystkie ulice wokół (Warszawska, Tylna Mariacka, Dworcowa, Wojewódzka, pl. Szramka) są DARMOWE, a jako główny Parking Rekomendowany polecamy ogromny, bezpłatny w niedzielę parking pod NOSPR-em (12 min wyznaczoną trasą pieszą przez kładkę).',
  '- PLENERY TANECZNE W KATOWICACH (WIOSNA–LATO I CIEPŁE DNI): 1) Kamienny Krąg w Dolinie Trzech Stawów (ul. Trzech Stawów 22, obok przystani i La Cantina) — w razie deszczu tańczymy pod zadaszoną wiatą przy przystani kajakowej UKS 4 / SUP Tomi (ul. Trzech Stawów 10); na mapie zaznaczyliśmy 3 toalety (w tym przy AMO Pizza) oraz 13-minutową trasę pieszą z darmowego Parkingu Rekomendowanego (Południe / Rolkostrada). 2) Amfiteatr pod NOSPR-em w Strefie Kultury (pl. Wojciecha Kilara 1, od wschodniej strony NOSPR przy fontannach) z darmowym w weekendy parkingiem od ul. Olimpijskiej.',
  '- WSPÓLNY GRAFIK I PORÓWNYWARKA CENNIKÓW SZKÓŁ TAŃCA W KATOWICACH (https://katosalsahub.pl/grafik.html): Tworzymy i prowadzimy ujednolicony, wspólny grafik katowickich szkół tańca (130 kursów tygodniowo: La Clave, Good Mood, Mil Pasos, Evolution) z ustandaryzowaną 5-stopniową skalą poziomów zaawansowania KSH (P0 Od zera, P1 Podstawowy, P2 Podstawowy+, S1 Średniozaawansowany/Zaawansowany, OPEN), kalkulatorem opłacalności cenników (La Clave: 45 min, karnety BEZTERMINOWE 4x 109 zł / 8x 189 zł / 10x 219 zł / Open 300 zł, dopłaty w blokach +15 zł i +10 zł lub 3. jednostka gratis przy 2 skreśleniach; Good Mood: 60 min, ważność 28 dni, 4h 100 zł [student 90 zł] / 8h 170 zł [student 160 zł] / Open 260 zł; Mil Pasos: 55 min, ważność 4 tyg., 4h 119 zł / 8h 199 zł / 12h 249 zł / 16h 299 zł / Open 399 zł, -10% dla studentów), kalendarzem wydarzeń i mapą szkół.',
  '- SALSOPEDIA (https://katosalsahub.pl/salsopedia.html): Tworzymy otwartą, społecznościową encyklopedię ponad 200 haseł (figury Casino, komendy Rueda de Casino, rytmy, instrumenty, historia, bóstwa Orishas, zespoły, instruktorzy i śląskie szkoły tańca) z edytorem Salsopedia Studio.',
  '- RADIO TIMBA NATION 24/7 (ODTWARZACZ NA STRONIE): Timba Nation Radio to niezależna internetowa stacja radiowa z Zurychu (Szwajcaria), założona i prowadzona przez DJ Maikiu na platformie Zeno.FM (https://zeno.fm/radio/timba-nation-radio/). To NIE jest radio tworzone ani finansowane przez Kato Salsa Hub — nasza społeczność udostępnia na stronie głównej dedykowany odtwarzacz tego strumienia (z podglądem granego utworu na żywo, obsługą ekranu blokady telefonu MediaSession oraz wyłącznikiem czasowym Sleep Timer: 15, 30, 60 min). Stacja gra 24/7 współczesną kubańską Timbę i Salsę Cubana (w tym autorskie sety DJ Maikiu - Cuban Salsa Mix) bez komercyjnych bloków reklamowych, ponieważ jest autorskim, pasjonackim projektem muzycznym DJ Maikiu promującym kubańską muzykę.',
  '- DANCEPULS (https://dancepuls.katosalsahub.pl/): Tworzymy cotygodniowy radar i agregator imprez tanecznych, warsztatów i festiwali na Śląsku i w Krakowie, publikowany co tydzień z ankietą na naszej grupie FB (https://www.facebook.com/groups/519446499987373), fanpage\'u FB (https://www.facebook.com/KatoSalsaHub) oraz Instagramie (https://www.instagram.com/katosalsahub/). Formularz zgłaszania imprez: https://tiny.pl/2bc8z7649.',
  '- INTEGRACJE, SPOTKANIA COMIESIĘCZNE I WYJAZDY: Organizujemy comiesięczne spotkania grupowe społeczności z systemem opasek (Leaders/Followers), grupy zniżkowe KSH na festiwale oraz wielki wiosenny Wyjazd Integracyjny Kato Salsa Hub (9–11 kwietnia, do 100 osób).'
].join('\n');

/**
 * Normalizuje tekst zapytania do klucza pamięci podręcznej (Response Cache)
 * @param {string} text
 * @returns {string}
 */
function normalizeCacheQuery(text) {
  if (!text) return '';
  return String(text)
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/ł/g, 'l')
    .replace(/[?!.,;:()"'«»„”`~[\]{}/\\|_+-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Usuwa znaki diakrytyczne (PL / ES) i upraszcza tekst do wyszukiwania pełnotekstowego
 * @param {string} text
 * @returns {string}
 */
function normalizeSearchText(text) {
  if (!text) return '';
  const map = {
    ą: 'a', ć: 'c', ę: 'e', ł: 'l', ń: 'n', ó: 'o', ś: 's', ź: 'z', ż: 'z',
    á: 'a', é: 'e', í: 'i', ú: 'u', ü: 'u', ñ: 'n'
  };
  return String(text)
    .toLowerCase()
    .replace(/[ąćęłńóśźżáéíúüñ]/g, (ch) => map[ch] || ch)
    .replace(/[^a-z0-9\s-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Szybki, deterministyczny skrót wersji bazy wiedzy (FNV-1a 32-bit + rozmiar bazy).
 * @param {Array<Object>} entries
 * @returns {string}
 */
function computeKnowledgeVersion(entries) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return 'kb_v0_empty';
  }
  let hash = 0x811c9dc5;
  for (let i = 0; i < entries.length; i++) {
    const item = entries[i] || {};
    const cats = Array.isArray(item.category) ? item.category.join(',') : String(item.category || '');
    const record = `${item.id || ''}|${item.term || ''}|${item.definition || ''}|${cats}|${item.status || ''}|${item.verification_count || 0}|${item.last_updated || ''}`;
    for (let j = 0; j < record.length; j++) {
      hash ^= record.charCodeAt(j);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
  }
  return `kb_v${entries.length}_${hash.toString(16)}`;
}

/**
 * Przeszukuje dynamiczną bazę wiedzy (np. Salsopedię) pod kątem zapytania użytkownika.
 * @param {string} question
 * @param {Array<Object>} entries
 * @param {number} limit
 * @returns {Array<Object>}
 */
function searchKnowledgeEntries(question, entries, limit = 5) {
  if (!question || !Array.isArray(entries) || entries.length === 0) return [];

  const qNorm = normalizeSearchText(question);
  if (!qNorm) return [];

  const stopWords = new Set([
    'co', 'to', 'jest', 'sa', 'jak', 'jaki', 'jaka', 'jakie', 'gdzie', 'kiedy',
    'czy', 'na', 'w', 'we', 'z', 'ze', 'do', 'od', 'po', 'o', 'i', 'a', 'oraz',
    'lub', 'albo', 'mi', 'sie', 'tym', 'ten', 'ta', 'te', 'oznacza', 'znaczy',
    'opowiedz', 'wyjasnij', 'powiedz', 'czym', 'kim', 'kto', 'mozna', 'jakis',
    'salsopedii', 'salsopedia', 'salsa', 'salsie', 'tancu', 'taniec', 'figura', 'krok'
  ]);

  const rawTokens = qNorm.split(' ').filter((t) => t.length >= 2 && !stopWords.has(t));
  const stems = rawTokens.map((t) => {
    if (t.length >= 6) return t.replace(/(ach|ami|owi|iem|om|ie|ow|ej|ym|im|ia|iu|ek|ka|ki|ce|ke|y|a|e|i|u|o)$/, '');
    if (t.length >= 5) return t.replace(/(ie|ow|ej|ym|ia|ka|ki|ce|y|a|e|i|u)$/, '');
    return t;
  }).filter((s) => s.length >= 3);

  const categoryAliases = {
    steps: ['krok', 'kroki', 'podstaw', 'basico', 'guapea'],
    figures: ['figur', 'rueda', 'ruedzie', 'komend', 'casino', 'wystep'],
    styles: ['styl', 'odmian', 'gatun', 'rodzaj'],
    music: ['muzyk', 'rytm', 'clave', 'utwor', 'piosen'],
    instruments: ['instrument', 'beben', 'bebny', 'perkuj', 'conga', 'timbales', 'clave'],
    bands: ['zespol', 'orkiestr', 'artyst', 'kapel', 'spiewa', 'muzykant', 'van', 'havana'],
    history: ['histori', 'korzen', 'pochodz', 'tradycj', 'kuba'],
    gods: ['orish', 'orisza', 'bog', 'bostw', 'santeri', 'yorub', 'afro', 'chango', 'eleggua', 'yemaya', 'oshun'],
    instructors: ['instruktor', 'nauczyciel', 'prowadz', 'trener', 'uczy'],
    schools: ['szkol', 'kurs', 'zajec', 'lekcj', 'gdzie uczyc']
  };

  const matchedCategories = new Set();
  for (const [catKey, keywords] of Object.entries(categoryAliases)) {
    if (keywords.some((kw) => qNorm.includes(kw))) {
      matchedCategories.add(catKey);
    }
  }

  const scored = [];
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (!entry || !entry.term) continue;

    const termNorm = normalizeSearchText(entry.term);
    const termClean = termNorm.replace(/\([^)]*\)/g, '').trim();
    const defNorm = normalizeSearchText(entry.definition || '');
    const cats = Array.isArray(entry.category) ? entry.category : (entry.category ? [entry.category] : []);

    let score = 0;

    if (termNorm && qNorm === termNorm) {
      score += 120;
    } else if (termClean && termClean.length >= 3 && qNorm.includes(termClean)) {
      score += 85;
    } else if (termNorm && termNorm.length >= 3 && qNorm.includes(termNorm)) {
      score += 80;
    }

    for (const token of rawTokens) {
      if (termNorm.split(' ').includes(token)) {
        score += 45;
      } else if (token.length >= 3 && termNorm.includes(token)) {
        score += 30;
      }
      if (token.length >= 3 && defNorm.includes(token)) {
        score += 10;
      }
    }

    for (const stem of stems) {
      if (stem.length >= 3 && termNorm.includes(stem)) {
        score += 22;
      }
      if (stem.length >= 4 && defNorm.includes(stem)) {
        score += 6;
      }
    }

    for (const cat of cats) {
      if (matchedCategories.has(cat)) {
        score += 14;
      }
    }

    if (score > 0) {
      scored.push({ entry, score });
    }
  }

  scored.sort((a, b) => b.score - a.score || String(a.entry.term).localeCompare(String(b.entry.term), 'pl'));
  return scored.slice(0, limit).map((item) => item.entry);
}

/**
 * Buduje zwięzły kontekst RAG z dynamicznej bazy wiedzy (np. Salsopedii) do przesłania do routera AI
 * @param {string} question
 * @param {Array<Object>} entries
 * @returns {string}
 */
function buildDynamicContext(question, entries) {
  const safeEntries = Array.isArray(entries) ? entries : [];
  const matched = searchKnowledgeEntries(question, safeEntries, 6);

  const lines = matched.map((m) => {
    const catsLabel = (Array.isArray(m.category) ? m.category : [m.category])
      .filter(Boolean)
      .map((c) => CATEGORY_LABELS_PL[c] || c)
      .join(', ');
    const verifiedBadge = m.status === 'verified' ? ' [Zweryfikowane]' : '';
    return `- **${m.term}** [Kategoria: ${catsLabel || 'Ogólne'}]${verifiedBadge}: ${m.definition}`;
  });

  if (safeEntries.length === 0 && lines.length === 0) {
    return KSH_CORE_CONTEXT;
  }

  const versionTag = computeKnowledgeVersion(safeEntries);
  if (lines.length === 0) {
    return `${KSH_CORE_CONTEXT}\n\n[AKTUALNY STAN BAZY SALSOPEDII (${versionTag})]: Łącznie ${safeEntries.length} haseł.`;
  }

  return (
    `${KSH_CORE_CONTEXT}\n\n` +
    `[AKTUALNY STAN BAZY SALSOPEDII (${versionTag})]: Łącznie ${safeEntries.length} haseł.\n` +
    `Najbardziej pasujące hasła z Salsopedii na stronie:\n` +
    lines.join('\n')
  );
}

/**
 * Bezpieczny mikro-parser Markdown (100% odporny na XSS)
 * @param {string} rawText
 * @returns {string}
 */
function formatMarkdown(rawText) {
  if (!rawText) return '';
  let safe = String(rawText)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');

  // Pogrubienia **tekst**
  safe = safe.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');

  // Kursywa *tekst*
  safe = safe.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');

  // Klikalne adresy URL (https://...)
  safe = safe.replace(
    /(https?:\/\/[^\s<]+[^<.,:;"')\]\s])/g,
    '<a href="$1" target="_blank" rel="noopener noreferrer" class="tsw-ai-link">$1</a>'
  );

  // Klikalne adresy e-mail oraz linki wewnętrzne (#kontakt, salsopedia.html, grafik.html, cennik.html, /pakiety)
  safe = safe.replace(
    /([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/g,
    '<a href="mailto:$1" class="tsw-ai-link">$1</a>'
  );
  safe = safe.replace(
    /(^|\s)(#[a-zA-Z0-9_-]+)\b/g,
    '$1<a href="$2" class="tsw-ai-link">$2</a>'
  );
  safe = safe.replace(
    /(^|[\s(])((?:salsopedia|grafik|cennik|jak-pracuje)\.html(?:#[a-zA-Z0-9_-]+)?)/g,
    '$1<a href="$2" class="tsw-ai-link">$2</a>'
  );

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
      } else if (html && !html.endsWith('<br>') && !html.endsWith('</ul>')) {
        html += '<br>';
      }
    }
  }
  if (inList) {
    html += '</ul>';
  }
  return html;
}

/**
 * Pomocnicze rozpoznawanie siteId, gdy nie podano go jawnie w wywołaniu funkcji
 * @param {string} [explicitSiteId]
 * @returns {string}
 */
function resolveSiteIdContext(explicitSiteId) {
  if (explicitSiteId && typeof explicitSiteId === 'string') {
    return explicitSiteId.toLowerCase();
  }
  try {
    const doc = typeof document !== 'undefined' ? document : globalThis.document;
    const scriptEl =
      doc?.currentScript ||
      doc?.querySelector?.('script[data-site-id]') ||
      doc?.querySelector?.('script[src*="ai-widget.js"]') ||
      doc?.querySelector?.('script[src*="widget.js"]');
    const fromAttr = scriptEl?.getAttribute?.('data-site-id');
    if (fromAttr) return fromAttr.toLowerCase();
  } catch (_) {}
  return 'twojastronawww';
}

/**
 * Lokalna odpowiedź awaryjna (Zero-Downtime Fallback) dopasowana do projektu
 * oraz dynamicznej bazy wiedzy ze strony (np. Salsopedii).
 * @param {string} question
 * @param {string} [siteId]
 * @param {Array<Object>} [knowledgeEntries=[]]
 * @returns {string}
 */
function getLocalFallbackAnswer(question, siteId, knowledgeEntries = []) {
  const resolvedSiteId = resolveSiteIdContext(siteId);
  const q = String(question || '').toLowerCase();
  const qNorm = normalizeSearchText(question);

  // ===========================================================================
  // 1. KATO SALSA HUB & SALSOPEDIA
  // ===========================================================================
  if (resolvedSiteId === 'katosalsahub' || (Array.isArray(knowledgeEntries) && knowledgeEntries.length > 0)) {
    const isActivityOrEventScheduleQuestion =
      qNorm.includes('wolni ludzie') ||
      qNorm.includes('wolnych ludzi') ||
      qNorm.includes('mariack') ||
      qNorm.includes('niedziel') ||
      qNorm.includes('15 00') ||
      qNorm.includes('18 00') ||
      qNorm.includes('dzialalnosc') ||
      qNorm.includes('czym sie zajmuj') ||
      qNorm.includes('czym zajmuj') ||
      qNorm.includes('fundacj') ||
      qNorm.includes('spolecznosc') ||
      qNorm.includes('co robicie') ||
      qNorm.includes('kim jestescie') ||
      qNorm.includes('o was') ||
      qNorm.includes('wyjazd integracyjn') ||
      qNorm.includes('spotkania grupowe');

    if (isActivityOrEventScheduleQuestion) {
      return (
        `🌴 **Czym zajmuje się społeczność i Fundacja Kato Salsa Hub?**\n` +
        `Jesteśmy niezależną społecznością i fundacją łączącą miłośników **Salsy** (Salsy Kubańskiej / Casino, Timby, Ruedy de Casino oraz Sonu) w Katowicach i na całym Śląsku ponad podziałami szkolnymi:\n` +
        `- **🍹 Niedzielne potańcówki w Wolnych Ludziach (ul. Mariacka 2, Katowice):** W **każdą niedzielę w godz. 15:00–18:00** spotykamy się na otwartych potańcówkach i praktykach pod dachem (**Salsa Kubańska / Casino, Timba, Rueda de Casino, Son** — nie musisz mieć własnej pary!). W niedziele ulice wokół są darmowe, a jako główny **Parking Rekomendowany** polecamy bezpłatny w niedzielę **Parking pod NOSPR-em** (12 min spacerem przez kładkę).\n` +
        `- **💃 Darmowe plenery taneczne:** W sezonie wiosenno-letnim tańczymy na **Kamiennym Kręgu w Dolinie Trzech Stawów (ul. Trzech Stawów 22)** — w razie deszczu pod wiatą **UKS 4 / SUP Tomi (ul. Trzech Stawów 10)** — oraz pod **Amfiteatrem NOSPR (pl. Wojciecha Kilara 1)**.\n` +
        `- **🗓️ Wspólny Grafik Szkół Tańca (grafik.html), 📖 Salsopedia (salsopedia.html) i 📊 DancePuls:** Tworzymy ujednolicony **Wspólny Grafik Szkół Tańca w Katowicach** (130 kursów z ustandaryzowanymi poziomami P0–OPEN), społecznościową encyklopedię **Salsopedię** (ponad 200 haseł), agregator imprez **DancePuls** (https://dancepuls.katosalsahub.pl/), udostępniamy odtwarzacz **Radia Timba Nation 24/7** (stacji DJ Maikiu z Zurychu na Zeno.FM) oraz organizujemy wyjazdy i spotkania integracyjne!`
      );
    }

    const isRadioQuestion =
      qNorm.includes('radio') ||
      qNorm.includes('radia') ||
      qNorm.includes('radiu') ||
      qNorm.includes('timba nation') ||
      qNorm.includes('maikiu') ||
      qNorm.includes('zeno') ||
      qNorm.includes('odtwarzacz') ||
      qNorm.includes('stream') ||
      qNorm.includes('sleep') ||
      qNorm.includes('timer') ||
      qNorm.includes('wylacznik czasow') ||
      qNorm.includes('reklam');

    if (isRadioQuestion) {
      return (
        `📻 **Radio Timba Nation 24/7 — skąd pochodzi i dlaczego gra bez reklam?**\n` +
        `- **Skąd jest to radio:** **Timba Nation Radio** to niezależna internetowa stacja radiowa z **Zurychu (Szwajcaria)**, założona i prowadzona przez **DJ Maikiu** na platformie **Zeno.FM** (https://zeno.fm/radio/timba-nation-radio/). To nie jest nasza własna rozgłośnia — na portalu Kato Salsa Hub udostępniamy tancerzom zintegrowany odtwarzacz tego strumienia.\n` +
        `- **Dlaczego gra bez reklam:** Stacja jest autorskim, pasjonackim projektem muzycznym **DJ Maikiu** promującym współczesną kubańską **Timbę, Salsę Cubana (Casino) i Son** (w tym jego autorskie sety *Cuban Salsa Mix*), dzięki czemu nadaje czystą muzykę 24/7 bez komercyjnych bloków reklamowych.\n` +
        `- **Funkcje naszego odtwarzacza:** Wyświetla aktualnie grany utwór na żywo, działa przy zablokowanym ekranie telefonu (MediaSession) i posiada **wyłącznik czasowy (Sleep Timer: 15, 30 lub 60 min)** z płynnym wyciszaniem dźwięku!`
      );
    }

    const isMetaSalsopediaQuestion =
      qNorm.includes('czym jest salsopedia') ||
      qNorm.includes('co to jest salsopedia') ||
      qNorm.includes('jak dziala salsopedia') ||
      qNorm.includes('dodac hasl') ||
      qNorm.includes('zaproponowac hasl') ||
      qNorm.includes('zglosic poprawk') ||
      qNorm.includes('poprawic hasl') ||
      qNorm.includes('moderacj') ||
      qNorm.includes('weryfikacj') ||
      qNorm.includes('ile hasel');

    const matchedEntries = searchKnowledgeEntries(question, knowledgeEntries, 3);

    if (matchedEntries.length > 0 && !isMetaSalsopediaQuestion) {
      const top = matchedEntries[0];
      const cats = (Array.isArray(top.category) ? top.category : [top.category])
        .filter(Boolean)
        .map((c) => CATEGORY_LABELS_PL[c] || c)
        .join(', ');

      let response = `W **Salsopedii** znajdziesz dokładne wyjaśnienie hasła **${top.term}**${cats ? ` (${cats})` : ''}:\n- ${top.definition}`;
      if (matchedEntries.length > 1) {
        const related = matchedEntries
          .slice(1)
          .map((e) => `**${e.term}** (${e.definition})`)
          .join('\n- ');
        response += `\nPowiązane pojęcia w Salsopedii:\n- ${related}`;
      }
      response += `\nPełny katalog haseł z wyszukiwarką i linkowaniem znajdziesz w zakładce salsopedia.html`;
      return response;
    }

    if (
      isMetaSalsopediaQuestion ||
      qNorm.includes('salsoped') ||
      qNorm.includes('encykloped') ||
      qNorm.includes('wikiped')
    ) {
      const countInfo = Array.isArray(knowledgeEntries) && knowledgeEntries.length > 0
        ? `obecnie **${knowledgeEntries.length} haseł**`
        : 'ponad **200 haseł**';
      return (
        `**Salsopedia** (salsopedia.html) to nasza otwarta encyklopedia salsy kubańskiej i kultury afro-kubańskiej (zawiera ${countInfo} w 11 kategoriach: Kroki, Figury Casino/Rueda, Taniec, Style, Muzyka, Instrumenty, Zespoły, Historia, Bogowie Orishas, Instruktorzy i Szkoły Tańca):\n` +
        `- **Wyszukiwanie i linki**: wpisz frazę w wyszukiwarce lub klikaj podświetlone pojęcia bezpośrednio w definicjach\n` +
        `- **Dodawanie i edycja (Salsopedia Studio)**: kliknij **„Zaproponuj hasło”** lub **„Zgłoś poprawkę”** przy karcie — zobaczysz podgląd na żywo oraz porównanie zmian *Przed vs Po (Diff)*\n` +
        `- **Weryfikacja merytoryczna**: zgłoszenia trafiają do kolejki moderacji i są oznaczane statusem potwierdzenia instruktorskiego.`
      );
    }

    if (qNorm.includes('dancepuls') || qNorm.includes('imprez') || qNorm.includes('wydarzen') || qNorm.includes('event') || qNorm.includes('weekend') || qNorm.includes('warsztat') || qNorm.includes('social') || qNorm.includes('grafik')) {
      return (
        `Aktualne imprezy taneczne (sociale), kursy i warsztaty sprawdzisz w trzech miejscach:\n` +
        `- **Wspólny Grafik Szkół Tańca** (grafik.html) — 130 kursów tygodniowo w Katowicach z kalkulatorem cenników\n` +
        `- **DancePuls** (https://dancepuls.katosalsahub.pl/) — nasz automatyczny kalendarz i zestawienie imprez na Śląsku i w Krakowie\n` +
        `- **Grupa Facebook Kato Salsa Hub** (https://www.facebook.com/groups/519446499987373) — bieżące umawianie się na potańcówki plenerowe i niedzielne praktyki w **Wolnych Ludziach (ul. Mariacka 2, 15:00–18:00)**.`
      );
    }

    if (qNorm.includes('gdzie') || qNorm.includes('lokalizacj') || qNorm.includes('lokacj') || qNorm.includes('dolin') || qNorm.includes('trzech staw') || qNorm.includes('adres') || qNorm.includes('mapa') || qNorm.includes('katowic') || qNorm.includes('parking')) {
      return (
        `📍 **Gdzie tańczymy w Katowicach?**\n` +
        `- **Wolni Ludzie (ul. Mariacka 2):** w każdą niedzielę w godz. **15:00–18:00** (darmowy w niedzielę Parking Rekomendowany pod NOSPR-em)\n` +
        `- **Dolina Trzech Stawów (Kamienny Krąg, ul. Trzech Stawów 22):** plenerowe spotkania wiosną i latem (w razie deszczu wiata UKS 4, ul. Trzech Stawów 10) — sprawdź mapę w sekcji **#mapa**\n` +
        `- **Szkoły Tańca w Katowicach:** m.in. La Clave, Good Mood, Mil Pasos, Evolution (pełny wykaz w salsopedia.html i grafik.html).`
      );
    }

    if (qNorm.includes('cen') || qNorm.includes('koszt') || qNorm.includes('karnet') || qNorm.includes('multisport') || qNorm.includes('medicover') || qNorm.includes('fitprofit') || qNorm.includes('od podstaw') || qNorm.includes('p0') || qNorm.includes('poczatkuj') || qNorm.includes('ubrac') || qNorm.includes('buty') || qNorm.includes('par')) {
      return (
        `Praktyczne informacje dla osób zaczynających przygodę z salsą w Katowicach:\n` +
        `- **Poziom P0 (od podstaw)**: nie potrzebujesz własnej pary ani wcześniejszego doświadczenia (w grupie rotujemy w parach)\n` +
        `- **Ceny i karty sportowe**: w katowickich szkołach tańca (La Clave, Good Mood, Mil Pasos) pojedyncze wejście kosztuje **30–35 PLN**, karnet 4 wejść **90–119 PLN**, a wszystkie szkoły akceptują karty **Multisport, Medicover Sport, FitProfit i PZU Sport**\n` +
        `- **Jak się ubrać**: wygodny strój niekrępujący ruchów oraz zmienne obuwie na płaskiej podeszwie.`
      );
    }

    if (qNorm.includes('styl') || qNorm.includes('co tancz') || qNorm.includes('cubana') || qNorm.includes('rued') || qNorm.includes('son') || qNorm.includes('rumb') || qNorm.includes('afro')) {
      return (
        `W społeczności **Kato Salsa Hub** królują kubańskie rytmy:\n` +
        `- **Salsa Cubana (Casino)**, **Timba** oraz zespołowa **Rueda de Casino**\n` +
        `- Tradycyjny **Son Cubano**, **Rumba Cubana** (Guaguancó, Yambú, Columbia), **Afro Cubano (Orishas)** oraz **Salsa Liniowa**\n` +
        `Każdy z tych stylów i jego figury znajdziesz dokładnie opisane w naszej **Salsopedii** (salsopedia.html)!`
      );
    }

    if (qNorm.includes('kontakt') || qNorm.includes('napisz') || qNorm.includes('wiadomosc') || qNorm.includes('formularz') || qNorm.includes('facebook') || qNorm.includes('mail')) {
      return (
        `Skontaktujesz się z nami bezpośrednio przez:\n` +
        `- **Formularz kontaktowy** w sekcji **#kontakt** na dole strony głównej (dbamy o RODO — wystarczy podać imię lub pseudonim)\n` +
        `- **Grupę na Facebooku**: https://www.facebook.com/groups/519446499987373\n` +
        `- **E-mail**: kontakt@katosalsahub.pl`
      );
    }

    if (resolvedSiteId === 'katosalsahub') {
      const kbCount = Array.isArray(knowledgeEntries) && knowledgeEntries.length > 0 ? knowledgeEntries.length : 200;
      return `Cześć! 💃🕺 Jestem asystentem **Kato Salsa Hub & Salsopedii**. Czerpię wiedzę na żywo z naszej **Salsopedii (${kbCount} haseł)** oraz całego portalu.\nZapytaj mnie o dowolną **figurę (np. Enchufla, Dile Que No, Setenta)**, **niedzielne potańcówki w Wolnych Ludziach (15:00–18:00)**, **Radio Timba Nation**, **Wspólny Grafik Szkół (grafik.html)** lub **gdzie tańczymy w Katowicach**!`;
    }
  }

  // ===========================================================================
  // 2. RARICART (Mobilne Live Food Stations na wesela i eventy)
  // ===========================================================================
  if (resolvedSiteId === 'raricart') {
    if (q.includes('pakiet') || q.includes('rabat') || q.includes('łącz') || q.includes('lacz') || q.includes('2 ') || q.includes('3 ') || q.includes('kompleks')) {
      return (
        `Oferujemy **pakiety łączone z rabatem** (logistyka i dojazd do 50 km liczone tylko raz):\n` +
        `- **2 stanowiska (rabat -5%)**: np. *Mini Pancakes + Lody Włoskie*: 50 os. **6 250 zł** | 100 os. **8 720 zł** | 150 os. **11 240 zł** | 200 os. **13 710 zł**\n` +
        `- **Pakiet Kompleksowy — 3 stanowiska (rabat -10%, Pancakes + Lody + Deska Serów)**: 50 os. **8 870 zł** | 100 os. **12 560 zł** | 150 os. **16 340 zł** | 200 os. **20 030 zł**\n` +
        `Pełny konfigurator znajdziesz na https://raricart.pl/pakiety lub w sekcji **#kontakt**!`
      );
    }
    if (q.includes('cen') || q.includes('koszt') || q.includes('ile ') || q.includes('lody') || q.includes('pancake') || q.includes('ser')) {
      return (
        `Cennik pojedynczych mobilnych stacji **Raricart Live Food Station** (pełna aranżacja + obsługa na żywo):\n` +
        `- **Lody Włoskie Live Station**: do 50 os. **3 000 zł** | do 100 os. **4 250 zł** | do 150 os. **5 550 zł**\n` +
        `- **Mini Pancakes Live Station**: do 50 os. **3 150 zł** | do 100 os. **4 500 zł** | do 150 os. **5 850 zł**\n` +
        `- **Deska Serów Live Station (12 włoskich serów i wędlin)**: do 50 os. **3 250 zł** | do 100 os. **4 750 zł** | do 150 os. **6 300 zł**\n` +
        `Sprawdź dostępne terminy w formularzu **#kontakt** lub zadzwoń: **+48 883 392 688**.`
      );
    }
    if (q.includes('dojazd') || q.includes('montaż') || q.includes('montaz') || q.includes('prąd') || q.includes('prad') || q.includes('wymaga') || q.includes('gdzie')) {
      return (
        `Logistyka i montaż stanowisk **Raricart** są po naszej stronie:\n` +
        `- **Dojazd do 50 km w cenie pakietu** (powyżej 50 km dopłata wynosi tylko **+2 zł/km**)\n` +
        `- **Wymagania na miejscu**: standardowe gniazdko **230V** i kawałek miejsca na sali lub w plenerze pod zadaszeniem\n` +
        `- Przyjeżdżamy odpowiednio wcześniej, rozkładamy stację i po serwisie zostawiamy idealny porządek.`
      );
    }
    return (
      `Cześć! 🥞🍦🧀 Jestem wirtualnym doradcą **Raricart Live Food Station**. Tworzymy mobilne stacje kulinarne na żywo na wesela i eventy (**Lody Włoskie, Mini Pancakes, Deski Serów**).\n` +
      `Zapytaj mnie o cennik na 50–200 gości, pakiety łączone lub zostaw datę przyjęcia i numer telefonu — potwierdzimy dostępność terminu (tel. **+48 883 392 688**, kontakt@raricart.pl)!`
    );
  }

  // ===========================================================================
  // 3. FUEGO LINGUA (Szkoła języka hiszpańskiego)
  // ===========================================================================
  if (resolvedSiteId === 'fuegolingua') {
    if (q.includes('próbn') || q.includes('probn') || q.includes('darmow') || q.includes('bezpłatn') || q.includes('bezplatn') || q.includes('konsultacj')) {
      return 'Pierwsza **konsultacja wstępna online jest całkowicie bezpłatna**! To krótkie spotkanie, podczas którego poznajemy się, określamy Twój poziom i ustalamy plan nauki.\n- Zapisz się przez formularz na dole strony\n- Napisz na: kontakt@fuegolingua.pl\n- Zadzwoń: **796-868-967**';
    }
    if (q.includes('biznes') || q.includes('firm') || q.includes('stolar') || q.includes('budow') || q.includes('turyst') || q.includes('branż') || q.includes('specjalist')) {
      return 'Prowadzimy dedykowane **kursy specjalistyczne** (cena maleje o **5 zł** za każdą dodatkową osobę, do 6 osób):\n- **Hiszpański w Biznesie**: od **130 zł** (60 min) / **160 zł** (90 min)\n- **Hiszpański w Stolarce i Budownictwie**: od **150 zł** (60 min) / **170 zł** (90 min)\n- **Hiszpański w Turystyce**: od **100 zł** (60 min) / **120 zł** (90 min)\nPełny wykaz znajdziesz w zakładce https://fuegolingua.pl/cennik.html';
    }
    if (q.includes('cen') || q.includes('koszt') || q.includes('ile ') || q.includes('pakiet') || q.includes('płaci')) {
      return 'Oto nasz cennik dla **Ogólnych Poziomów (A1–B2)**:\n- **Lekcje indywidualne (1:1)**: 60 min – **95 zł** | 90 min – **135 zł**\n- **Lekcje w parze (2 osoby)**: 60 min – **85 zł/os.** | 90 min – **115 zł/os.**\n- **Grupy (3–6 osób)**: 60 min – **75 zł/os.** | 90 min – **95 zł/os.**\n- **Poziom Extreme (C1–C2)**: 1:1 od **140 zł** (60 min), w parze **120 zł/os.**, w grupie **100 zł/os.**\nPierwsza konsultacja jest **bezpłatna**!';
    }
    if (q.includes('indywidualn') || q.includes('grupow') || q.includes('parze') || q.includes('form') || q.includes('wygląda')) {
      return 'Zajęcia odbywają się w **100% online na żywo**, a **80% lekcji to żywa rozmowa**:\n- **Indywidualnie (1:1)**: 100% uwagi lektora i tempo dopasowane do Ciebie (**95 zł** / 60 min na poz. A1–B2)\n- **W parze (2 os.)**: wspólna nauka ze znajomym lub partnerem (**85 zł/os.** / 60 min)\n- **Kameralne grupy (3–6 os.)**: duża dawka interakcji i wzajemnej motywacji (**75 zł/os.** / 60 min)';
    }
    if (q.includes('kontakt') || q.includes('telefon') || q.includes('mail') || q.includes('zapis')) {
      return 'Skontaktuj się ze mną wygodnie:\n- E-mail: kontakt@fuegolingua.pl\n- Telefon: **796-868-967**\n- Instagram: **@fuegolingua_sin_limites**\nMożesz też wypełnić formularz kontaktowy na dole strony głównej!';
    }
    if (q.includes('tłumacz') || q.includes('tlumacz') || q.includes('delegacj') || q.includes('przysięgł') || q.includes('przysiegl')) {
      return 'Główna działalność Fuego Lingua to **nauka hiszpańskiego**, a tłumaczenia nie są standardową usługą. Prowadząca jest w trakcie uzyskiwania uprawnień tłumacza przysięgłego, więc **na dziś nie wykonuje tłumaczeń przysięgłych**.\nW sprawie wyjazdu lub delegacji napisz na kontakt@fuegolingua.pl albo zadzwoń: **796-868-967**. Opisz termin i rodzaj zadania, a dostaniesz indywidualną odpowiedź.';
    }
    return 'Jestem wirtualnym doradcą **Fuego Lingua**. Zapytaj o bezpłatną konsultację, cennik zajęć indywidualnych i grupowych lub kursy specjalistyczne (kontakt@fuegolingua.pl, tel. **796-868-967**).';
  }

  // ===========================================================================
  // 4. TWOJASTRONAWWW & SZABLON BAZOWY (Domyślny)
  // ===========================================================================
  if (q.includes('wordpress') || q.includes('wtyczk') || q.includes('kod') || q.includes('sql') || q.includes('szybk')) {
    return 'Tworzymy strony w **czystym kodzie (architektura Flat-File)** zamiast ciężkiego WordPressa z dziesiątkami wtyczek:\n- **Waga poniżej 100 KB** i ładowanie **< 0.6s** (Google PageSpeed **95–100/100**)\n- **Brak bazy SQL** = zero ryzyka ataków SQL Injection i awarii po aktualizacjach\n- **100% kodu na własność** w repozytorium Git i brak ukrytych abonamentów.';
  }

  if (q.includes('ai') || q.includes('czat') || q.includes('bot') || q.includes('asystent') || q.includes('rag')) {
    return 'Wdrażamy dedykowanych **Asystentów AI z bazą wiedzy firmy (RAG)** zintegrowanych z centralną bramką kaskadową (11 modeli LLM, pamięć podręczna zapytań `< 5 ms`):\n- Koszt wdrożenia: **od 900 PLN netto** (jednorazowa konfiguracja)\n- Działa **24/7**, odpowiada w ułamku sekundy z pamięci podręcznej i korzysta z darmowych pul API\n- Automatycznie przesyła powiadomienia na telefon (z numerem telefonu i e-mailem na samej górze wiadomości), gdy klient zostawi namiar kontaktowy.';
  }

  if (q.includes('współprac') || q.includes('wspolprac') || q.includes('krok') || q.includes('proces') || q.includes('etap') || q.includes('czas') || q.includes('ile trwa') || q.includes('jak wygląda')) {
    return 'Współpraca przebiega w **3 prostych krokach** (pełne wdrożenie w **7–14 dni roboczych**):\n- **Krok 1**: Bezpłatna konsultacja, analiza potrzeb i stała wycena w 24h\n- **Krok 2**: Projekt UX/UI, programowanie w czystym kodzie oraz podgląd na żywo przez szyfrowany link testowy\n- **Krok 3**: Testy jakościowe PageSpeed 95+, wdrożenie na domenie i **30 dni gwarancji**.';
  }

  if (q.includes('cen') || q.includes('koszt') || q.includes('ile ') || q.includes('pakiet') || q.includes('wycen')) {
    return 'Każdy projekt wyceniamy przejrzyście przed startem prac (pakiety bazowe w **TwojaStronaWWW.pl**):\n- **Wizytówka / Landing Page**: **2 499 PLN netto** (czysty kod RWD, SEO, formularz z ochroną anty-spam)\n- **Strona Firmowa**: **5 499 PLN netto** (do 10 podstron, autorski CMS Flat-File bez SQL, PageSpeed 90+)\n- **Wdrożenie Czatbota AI (RAG)**: **od 900 PLN netto**\nNapisz przez formularz kontaktowy na dole strony – przygotujemy **bezpłatną wycenę w 24h**!';
  }

  if (q.includes('realizacj') || q.includes('portfolio') || q.includes('przykład') || q.includes('projekt')) {
    return 'Przykładowe wdrożenia z wynikami **Google PageSpeed 98–100/100**:\n- **Raricart.pl** (branża eventowa) – ładowanie skrócone z 4.2s do **0.6s** i automatyzacja rezerwacji\n- **KatoSalsaHub.pl** & **DancePuls** – portal społecznościowy z Salsopedią i automatycznym agregatorem wydarzeń\n- **FuegoLingua.pl** – ultra-lekka strona (45 KB) bez bazy SQL z wirtualnym doradcą AI.';
  }

  if (q.includes('kontakt') || q.includes('telefon') || q.includes('mail') || q.includes('oddzwon') || q.includes('wiadomo')) {
    return 'Najwygodniej skontaktować się bezpośrednio przez **formularz kontaktowy na dole strony** lub napisać na kontakt@twojastronawww.pl – odpowiadamy i przygotowujemy bezpłatną wycenę w ciągu **24h**!';
  }

  return `Jestem wirtualnym doradcą serwisu **${resolvedSiteId}**. Chętnie odpowiem na pytania o ofertę, wycenę, wdrożenie asystenta AI lub przebieg współpracy. Możesz też zostawić wiadomość w formularzu kontaktowym na dole strony!`;
}

/**
 * Inicjalizuje widget czatu AI w drzewie DOM
 * @param {Document} doc
 * @param {Window} win
 * @param {Object} options
 */
function initAiWidget(doc = document, win = globalThis.window, options = {}) {
  if (!doc || !doc.body) return null;
  const existingRoot = doc.getElementById('tsw-ai-widget-root');
  if (existingRoot && !options.forceReinit) return null;
  if (existingRoot && options.forceReinit && existingRoot.parentNode) {
    existingRoot.parentNode.removeChild(existingRoot);
  }

  const scriptEl =
    doc.currentScript ||
    doc.querySelector('script[data-site-id]') ||
    doc.querySelector('script[src*="ai-widget.js"]') ||
    doc.querySelector('script[src*="widget.js"]');

  const siteId = (
    options.siteId ||
    scriptEl?.getAttribute('data-site-id') ||
    'twojastronawww'
  ).toLowerCase();

  const isLocalhost =
    win?.location?.hostname === 'localhost' || win?.location?.hostname === '127.0.0.1';
  const defaultRouterUrl = isLocalhost
    ? 'http://localhost:8085/chat-router.php'
    : 'https://ai.twojastronawww.pl/chat-router.php';
  const routerUrl =
    options.routerUrl || scriptEl?.getAttribute('data-router-url') || defaultRouterUrl;
  const title =
    options.title || scriptEl?.getAttribute('data-title') || 'Asystent AI';
  const kbUrl =
    options.kbUrl ||
    scriptEl?.getAttribute('data-kb-url') ||
    (siteId === 'katosalsahub' ? 'assets/data/salsopedia.json' : '');
  const kbApiUrl =
    options.kbApiUrl ||
    scriptEl?.getAttribute('data-kb-api') ||
    (siteId === 'katosalsahub' ? 'assets/php/wiki.php?action=list' : '');

  // Konfiguracja kolorów: atrybuty HTML data-* -> opcje JS -> THEME_PRESETS[siteId] -> zmienne CSS strony
  const preset = THEME_PRESETS[siteId] || THEME_PRESETS.twojastronawww;
  const themePrimary = options.primaryColor || scriptEl?.getAttribute('data-primary') || preset.primary;
  const themeAccent = options.accentColor || scriptEl?.getAttribute('data-accent') || preset.accent;
  const themeHighlight = options.highlightColor || scriptEl?.getAttribute('data-highlight') || preset.highlight;
  const themeBg = options.bgColor || scriptEl?.getAttribute('data-bg') || preset.bg;
  const themeSurface = options.surfaceColor || scriptEl?.getAttribute('data-surface') || preset.surface;
  const themeText = options.textColor || scriptEl?.getAttribute('data-text') || preset.text;
  const themeMuted = options.mutedColor || scriptEl?.getAttribute('data-muted') || preset.muted;
  const themeOnPrimary = options.onPrimaryColor || scriptEl?.getAttribute('data-on-primary') || preset.onPrimary;

  // Automatyczne wykrycie, czy na stronie jest pływający przycisk CTA (np. #floatingCta na Raricart)
  const hasFloatingCta = Boolean(doc.getElementById('floatingCta') || doc.querySelector('.floating-cta'));

  const storageKey = 'tsw_ai_history_' + siteId;
  const cacheStorageKey = 'tsw_ai_cache_' + siteId;
  const cacheTtlMs = Number(options.cacheTtlMs) || 24 * 60 * 60 * 1000;
  const quickPrompts = QUICK_PROMPTS_MAP[siteId] || QUICK_PROMPTS_MAP.twojastronawww;

  const existingGlobalTerms = Array.isArray(win?.__SALSOPEDIA_TERMS__) && win.__SALSOPEDIA_TERMS__.length > 0
    ? win.__SALSOPEDIA_TERMS__
    : (Array.isArray(win?.AppState?.terms) && win.AppState.terms.length > 0 ? win.AppState.terms : []);
  let knowledgeEntries = Array.isArray(options.initialKnowledge)
    ? [...options.initialKnowledge]
    : [...existingGlobalTerms];
  let kbVersion = computeKnowledgeVersion(knowledgeEntries);

  let responseCache = { kbVersion, entries: {} };

  function loadResponseCache() {
    try {
      const storage = win?.localStorage || win?.sessionStorage;
      const raw = storage?.getItem(cacheStorageKey);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object' && parsed.entries) {
          if (knowledgeEntries.length > 0 && parsed.kbVersion !== kbVersion) {
            responseCache = { kbVersion, entries: {} };
            saveResponseCache();
          } else {
            responseCache = {
              kbVersion: parsed.kbVersion || kbVersion,
              entries: parsed.entries || {}
            };
          }
        }
      }
    } catch (_) {
      responseCache = { kbVersion, entries: {} };
    }
  }

  function saveResponseCache() {
    try {
      const storage = win?.localStorage || win?.sessionStorage;
      storage?.setItem(cacheStorageKey, JSON.stringify(responseCache));
    } catch (_) {}
  }

  function hasContactPii(text) {
    const s = String(text || '');
    const emailRegex = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/;
    const phoneRegex = /(?:\+?48[\s.\-()]*)?(?:\d[\s.\-()]*){8}\d/;
    return emailRegex.test(s) || phoneRegex.test(s);
  }

  function getCachedAnswer(question) {
    const normQ = normalizeCacheQuery(question);
    if (!normQ || hasContactPii(question)) return null;

    if (knowledgeEntries.length > 0 && responseCache.kbVersion !== kbVersion) {
      responseCache = { kbVersion, entries: {} };
      saveResponseCache();
      return null;
    }

    const item = responseCache.entries?.[normQ];
    if (!item || !item.answer) return null;

    const now = Date.now();
    if (item.ts && now - item.ts > cacheTtlMs) {
      delete responseCache.entries[normQ];
      saveResponseCache();
      return null;
    }

    if (knowledgeEntries.length > 0 && item.kbVersion && item.kbVersion !== kbVersion) {
      delete responseCache.entries[normQ];
      saveResponseCache();
      return null;
    }

    return item.answer;
  }

  function setCachedAnswer(question, answer, source = 'ai') {
    const normQ = normalizeCacheQuery(question);
    if (!normQ || !answer || hasContactPii(question)) return;
    if (!responseCache.entries || responseCache.kbVersion !== kbVersion) {
      responseCache = { kbVersion, entries: {} };
    }
    responseCache.kbVersion = kbVersion;
    responseCache.entries[normQ] = {
      answer: String(answer),
      kbVersion,
      source,
      ts: Date.now()
    };
    saveResponseCache();
  }

  // @tsw-css-start
  const existingStyle = doc.getElementById('tsw-ai-widget-styles');
  if (existingStyle && existingStyle.parentNode) {
    existingStyle.parentNode.removeChild(existingStyle);
  }

  const style = doc.createElement('style');
  style.id = 'tsw-ai-widget-styles';
  style.textContent = `
    #tsw-ai-widget-root {
      --tsw-ai-primary: ${themePrimary};
      --tsw-ai-accent: ${themeAccent};
      --tsw-ai-highlight: ${themeHighlight};
      --tsw-ai-bg: ${themeBg};
      --tsw-ai-surface: ${themeSurface};
      --tsw-ai-text: ${themeText};
      --tsw-ai-muted: ${themeMuted};
      --tsw-ai-on-primary: ${themeOnPrimary};
      --tsw-ai-bottom-offset: ${hasFloatingCta ? '96px' : '24px'};
      --tsw-ai-window-bottom: ${hasFloatingCta ? '166px' : '96px'};
    }
    .tsw-ai-btn {
      position: fixed;
      bottom: var(--tsw-ai-bottom-offset, 24px);
      right: 24px;
      width: 60px;
      height: 60px;
      border-radius: 50%;
      background: linear-gradient(135deg, var(--tsw-ai-primary) 0%, var(--tsw-ai-accent) 100%);
      color: var(--tsw-ai-on-primary, #ffffff);
      box-shadow: 0 10px 26px rgba(0, 0, 0, 0.42);
      border: 2px solid rgba(255, 255, 255, 0.32);
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 999999;
      transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.2s;
    }
    .tsw-ai-btn:hover,
    .tsw-ai-btn:focus-visible {
      transform: scale(1.08);
      box-shadow: 0 14px 32px rgba(0, 0, 0, 0.55);
      outline: 3px solid var(--tsw-ai-highlight);
      outline-offset: 2px;
    }
    .tsw-ai-btn svg {
      width: 28px;
      height: 28px;
      fill: currentColor;
    }
    .tsw-ai-btn-badge {
      position: absolute;
      top: -3px;
      right: -3px;
      background: #10b981;
      color: #ffffff;
      font-size: 10px;
      font-weight: 800;
      padding: 2px 5px;
      border-radius: 999px;
      border: 2px solid var(--tsw-ai-bg, #0f172a);
      line-height: 1;
      letter-spacing: 0.02em;
      pointer-events: none;
    }
    .fab-add,
    #addTermBtn {
      bottom: 100px !important;
      right: 27px !important;
    }
    .tsw-ai-window {
      position: fixed;
      bottom: var(--tsw-ai-window-bottom, 96px);
      right: 24px;
      width: 400px;
      max-width: calc(100vw - 32px);
      height: 560px;
      max-height: calc(100vh - 120px);
      max-height: calc(100dvh - 120px);
      background: var(--tsw-ai-bg);
      border: 1px solid rgba(255, 255, 255, 0.16);
      border-radius: 18px;
      box-shadow: 0 22px 48px rgba(0, 0, 0, 0.72);
      z-index: 999999;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      font-family: inherit;
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
    @media (max-width: 600px) {
      #tsw-ai-widget-root {
        --tsw-ai-bottom-offset: ${hasFloatingCta ? '78px' : '16px'};
        --tsw-ai-window-bottom: ${hasFloatingCta ? '140px' : '80px'};
      }
      .tsw-ai-btn {
        right: 16px;
        width: 54px;
        height: 54px;
      }
      .fab-add,
      #addTermBtn {
        bottom: 84px !important;
        right: 16px !important;
      }
      .tsw-ai-window {
        right: 12px;
        left: 12px;
        width: auto;
        max-width: none;
        height: min(510px, calc(100vh - 100px));
        max-height: calc(100dvh - 100px);
      }
    }
    .tsw-ai-header {
      background: var(--tsw-ai-surface);
      padding: 14px 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 1px solid rgba(255, 255, 255, 0.12);
      flex-shrink: 0;
    }
    .tsw-ai-header-title {
      font-size: 15px;
      font-weight: 700;
      color: var(--tsw-ai-text);
      display: flex;
      align-items: center;
      gap: 9px;
      min-width: 0;
    }
    .tsw-ai-status-dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: #22c55e;
      box-shadow: 0 0 8px #22c55e;
      flex-shrink: 0;
    }
    .tsw-ai-header-actions {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-shrink: 0;
    }
    .tsw-ai-icon-btn {
      background: transparent;
      border: 1px solid transparent;
      color: var(--tsw-ai-text);
      cursor: pointer;
      font-size: 16px;
      padding: 4px 8px;
      border-radius: 6px;
      line-height: 1;
      transition: color 0.15s, background 0.15s, border-color 0.15s;
    }
    .tsw-ai-icon-btn:hover,
    .tsw-ai-icon-btn:focus-visible {
      color: var(--tsw-ai-highlight);
      background: rgba(255, 255, 255, 0.1);
      border-color: rgba(255, 255, 255, 0.16);
    }
    .tsw-ai-messages {
      flex: 1;
      overflow-y: auto;
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 14px;
    }
    .tsw-ai-msg {
      max-width: 88%;
      padding: 12px 15px;
      border-radius: 14px;
      font-size: 14px;
      line-height: 1.56;
      word-wrap: break-word;
      overflow-wrap: break-word;
    }
    .tsw-ai-msg strong {
      color: var(--tsw-ai-highlight);
      font-weight: 700;
    }
    .tsw-ai-list,
    .tsw-ai-msg ul {
      margin: 8px 0 8px 18px;
      padding: 0;
      list-style: disc;
    }
    .tsw-ai-list li,
    .tsw-ai-msg ul li {
      margin-bottom: 6px;
      line-height: 1.5;
    }
    .tsw-ai-list li:last-child,
    .tsw-ai-msg ul li:last-child {
      margin-bottom: 0;
    }
    .tsw-ai-link {
      color: var(--tsw-ai-highlight);
      text-decoration: underline;
      text-underline-offset: 2px;
      word-break: break-word;
      font-weight: 600;
    }
    .tsw-ai-msg-bot {
      background: var(--tsw-ai-surface);
      color: var(--tsw-ai-text);
      align-self: flex-start;
      border-bottom-left-radius: 4px;
      border: 1px solid rgba(255, 255, 255, 0.1);
    }
    .tsw-ai-msg-user {
      background: linear-gradient(135deg, var(--tsw-ai-primary) 0%, var(--tsw-ai-accent) 100%);
      color: var(--tsw-ai-on-primary, #ffffff);
      font-weight: 600;
      align-self: flex-end;
      border-bottom-right-radius: 4px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.22);
    }
    .tsw-ai-msg-user strong,
    .tsw-ai-msg-user .tsw-ai-link {
      color: var(--tsw-ai-on-primary, #ffffff);
    }
    .tsw-ai-chips {
      display: flex;
      flex-wrap: wrap;
      gap: 7px;
      padding: 0 16px 12px;
      flex-shrink: 0;
    }
    .tsw-ai-chips.tsw-hidden {
      display: none !important;
    }
    .tsw-ai-chip {
      background: rgba(255, 255, 255, 0.07);
      border: 1px solid rgba(255, 255, 255, 0.22);
      color: var(--tsw-ai-text);
      border-radius: 999px;
      padding: 6px 12px;
      font-size: 12px;
      font-weight: 600;
      line-height: 1.35;
      text-align: left;
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s, transform 0.1s;
    }
    .tsw-ai-chip:hover,
    .tsw-ai-chip:focus-visible {
      background: rgba(255, 255, 255, 0.15);
      border-color: var(--tsw-ai-highlight);
      color: #ffffff;
      transform: translateY(-1px);
    }
    .tsw-ai-input-bar {
      padding: 12px;
      background: var(--tsw-ai-surface);
      border-top: 1px solid rgba(255, 255, 255, 0.12);
      display: flex;
      align-items: center;
      gap: 8px;
      flex-shrink: 0;
    }
    .tsw-ai-input {
      flex: 1;
      min-width: 0;
      background: var(--tsw-ai-bg);
      border: 1px solid rgba(255, 255, 255, 0.2);
      border-radius: 10px;
      padding: 10px 12px;
      color: var(--tsw-ai-text);
      font-size: 14px;
      outline: none;
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .tsw-ai-input::placeholder {
      color: var(--tsw-ai-muted);
    }
    .tsw-ai-input:focus {
      border-color: var(--tsw-ai-highlight);
    }
    .tsw-ai-input.tsw-input-listening {
      border-color: var(--tsw-ai-primary);
      box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.15);
    }
    .tsw-ai-voice-btn {
      background: var(--tsw-ai-bg);
      border: 1px solid rgba(255, 255, 255, 0.2);
      border-radius: 10px;
      width: 40px;
      height: 40px;
      padding: 0;
      color: var(--tsw-ai-text);
      display: inline-flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      flex-shrink: 0;
      transition: background 0.15s, border-color 0.15s, color 0.15s, transform 0.15s;
    }
    .tsw-ai-voice-btn svg {
      width: 18px;
      height: 18px;
      fill: currentColor;
    }
    .tsw-ai-voice-btn:hover,
    .tsw-ai-voice-btn:focus-visible {
      border-color: var(--tsw-ai-highlight);
      color: var(--tsw-ai-highlight);
      transform: translateY(-1px);
    }
    .tsw-ai-voice-btn.tsw-listening {
      background: linear-gradient(135deg, var(--tsw-ai-primary) 0%, var(--tsw-ai-accent) 100%);
      border-color: rgba(255, 255, 255, 0.5);
      color: var(--tsw-ai-on-primary, #ffffff);
      animation: tswVoicePulse 1.3s infinite ease-in-out;
    }
    @keyframes tswVoicePulse {
      0% { box-shadow: 0 0 0 0 rgba(255, 255, 255, 0.45); }
      70% { box-shadow: 0 0 0 8px rgba(255, 255, 255, 0); }
      100% { box-shadow: 0 0 0 0 rgba(255, 255, 255, 0); }
    }
    .tsw-ai-send {
      background: linear-gradient(135deg, var(--tsw-ai-primary) 0%, var(--tsw-ai-accent) 100%);
      border: 1px solid rgba(255, 255, 255, 0.28);
      border-radius: 10px;
      height: 40px;
      padding: 0 15px;
      color: var(--tsw-ai-on-primary, #ffffff);
      font-weight: 700;
      font-size: 14px;
      white-space: nowrap;
      flex-shrink: 0;
      cursor: pointer;
      transition: opacity 0.2s, transform 0.15s;
    }
    .tsw-ai-send:hover:not(:disabled) {
      transform: translateY(-1px);
    }
    .tsw-ai-send:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
    .tsw-ai-typing {
      font-size: 12px;
      color: var(--tsw-ai-muted);
      font-style: italic;
    }
  `;
  (doc.head || doc.documentElement || doc.body).appendChild(style);
  // @tsw-css-end

  const placeholderText =
    siteId === 'katosalsahub'
      ? 'Zapytaj o hasło z Salsopedii, style, radio lub eventy...'
      : siteId === 'fuegolingua'
      ? 'Napisz pytanie o kurs lub cennik...'
      : siteId === 'raricart'
      ? 'Zapytaj o stacje Live Food, pakiety lub wolny termin...'
      : 'Napisz pytanie o ofertę lub wycenę...';

  const root = doc.createElement('div');
  root.id = 'tsw-ai-widget-root';
  root.setAttribute('data-nosnippet', '');
  root.innerHTML = `
    <button type="button" class="tsw-ai-btn" id="tswAiToggleBtn" aria-label="Otwórz czat z asystentem AI" aria-expanded="false" aria-controls="tswAiWindow">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
      <span class="tsw-ai-btn-badge" aria-hidden="true">AI</span>
    </button>

    <div class="tsw-ai-window" id="tswAiWindow" role="dialog" aria-label="${title}">
      <div class="tsw-ai-header">
        <div class="tsw-ai-header-title tsw-ai-title">
          <span class="tsw-ai-status-dot tsw-ai-dot" aria-hidden="true"></span>
          <span>${title}</span>
        </div>
        <div class="tsw-ai-header-actions tsw-ai-actions">
          <button type="button" class="tsw-ai-icon-btn" id="tswAiClearBtn" title="Nowa rozmowa" aria-label="Nowa rozmowa">&#x21bb;</button>
          <button type="button" class="tsw-ai-icon-btn" id="tswAiCloseBtn" title="Zamknij czat" aria-label="Zamknij czat">&times;</button>
        </div>
      </div>

      <div class="tsw-ai-messages" id="tswAiMessages" aria-live="polite"></div>
      <div class="tsw-ai-chips" id="tswAiChips"></div>

      <form class="tsw-ai-input-bar tsw-ai-form" id="tswAiForm">
        <input type="text" class="tsw-ai-input" id="tswAiInput" placeholder="${placeholderText}" aria-label="Zadaj pytanie asystentowi" maxlength="500" required autocomplete="off" />
        <button type="button" class="tsw-ai-voice-btn" id="tswAiVoiceBtn" title="Zadaj pytanie głosem (mikrofon)" aria-label="Zadaj pytanie głosem" aria-pressed="false">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20c0 .55.45 1 1 1s1-.45 1-1v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/></svg>
        </button>
        <button type="submit" class="tsw-ai-send" id="tswAiSendBtn">Wyślij</button>
      </form>
    </div>
  `;
  doc.body.appendChild(root);

  const toggleBtn = doc.getElementById('tswAiToggleBtn');
  const closeBtn = doc.getElementById('tswAiCloseBtn');
  const clearBtn = doc.getElementById('tswAiClearBtn');
  const chatWindow = doc.getElementById('tswAiWindow');
  const chatForm = doc.getElementById('tswAiForm');
  const chatInput = doc.getElementById('tswAiInput');
  const voiceBtn = doc.getElementById('tswAiVoiceBtn');
  const messagesContainer = doc.getElementById('tswAiMessages');
  const chipsContainer = doc.getElementById('tswAiChips');
  const sendBtn = doc.getElementById('tswAiSendBtn');

  // Obsługa dyktowania głosowego (Web Speech API — Tryb Bezpieczny)
  const defaultPlaceholder = chatInput?.getAttribute('placeholder') || placeholderText;
  const SpeechRecognitionCtor = win?.SpeechRecognition || win?.webkitSpeechRecognition || null;
  let recognition = null;
  let isListening = false;
  let voiceBaseText = '';
  let lastVoiceErrorPlaceholder = '';

  function setVoiceListeningState(active, customPlaceholder = '') {
    isListening = Boolean(active);
    if (voiceBtn) {
      voiceBtn.classList.toggle('tsw-listening', isListening);
      voiceBtn.setAttribute('aria-pressed', String(isListening));
      voiceBtn.setAttribute(
        'title',
        isListening ? 'Zatrzymaj dyktowanie (Słucham...)' : 'Zadaj pytanie głosem (mikrofon)'
      );
      voiceBtn.setAttribute(
        'aria-label',
        isListening ? 'Zatrzymaj dyktowanie głosowe' : 'Zadaj pytanie głosem'
      );
    }
    if (chatInput) {
      chatInput.classList.toggle('tsw-input-listening', isListening);
      chatInput.setAttribute(
        'placeholder',
        customPlaceholder || (isListening ? '🎙️ Słucham... mów teraz po polsku' : defaultPlaceholder)
      );
    }
  }

  function stopVoiceRecognition() {
    lastVoiceErrorPlaceholder = '';
    if (recognition && isListening) {
      try {
        recognition.stop();
      } catch (_) {}
    }
    setVoiceListeningState(false);
  }

  function toggleVoiceRecognition() {
    if (isListening) {
      stopVoiceRecognition();
      chatInput?.focus?.();
      return false;
    }

    const Ctor = win?.SpeechRecognition || win?.webkitSpeechRecognition || SpeechRecognitionCtor;
    if (typeof Ctor !== 'function') {
      setVoiceListeningState(false, 'Dyktowanie głosowe wymaga Chrome, Edge lub Safari');
      chatInput?.focus?.();
      return false;
    }

    try {
      if (!recognition) {
        recognition = new Ctor();
        recognition.lang = 'pl-PL';
        recognition.continuous = false;
        recognition.interimResults = true;
        recognition.maxAlternatives = 1;

        recognition.onstart = () => {
          lastVoiceErrorPlaceholder = '';
          setVoiceListeningState(true);
        };

        recognition.onresult = (event) => {
          if (!chatInput || !event || !event.results) return;
          lastVoiceErrorPlaceholder = '';
          let finalChunk = '';
          let interimChunk = '';
          for (let i = 0; i < event.results.length; i++) {
            const res = event.results[i];
            const transcript = res && res[0] && res[0].transcript ? String(res[0].transcript) : '';
            if (res.isFinal) {
              finalChunk += transcript;
            } else {
              interimChunk += transcript;
            }
          }
          const spoken = (finalChunk + interimChunk).replace(/\s+/g, ' ').trim();
          const combined = [voiceBaseText, spoken].filter(Boolean).join(' ').slice(0, 500);
          chatInput.value = combined;
        };

        recognition.onerror = (event) => {
          const code = event?.error || '';
          if (code === 'not-allowed' || code === 'service-not-allowed') {
            lastVoiceErrorPlaceholder = '⚠️ Zezwól na mikrofon (ikona obok adresu URL)';
          } else if (code === 'audio-capture') {
            lastVoiceErrorPlaceholder = '⚠️ Nie wykryto mikrofonu w urządzeniu';
          } else if (code === 'no-speech') {
            lastVoiceErrorPlaceholder = '🎙️ Nie usłyszałem głosu — kliknij mikrofon ponownie';
          } else if (code === 'network') {
            lastVoiceErrorPlaceholder = '⚠️ Przeglądarka blokuje usługę mowy (np. tarcza Brave)';
          } else {
            lastVoiceErrorPlaceholder = defaultPlaceholder;
          }
          setVoiceListeningState(false, lastVoiceErrorPlaceholder);
        };

        recognition.onend = () => {
          setVoiceListeningState(false, lastVoiceErrorPlaceholder || defaultPlaceholder);
          if (chatInput?.value) {
            chatInput?.focus?.();
          }
        };
      }

      lastVoiceErrorPlaceholder = '';
      voiceBaseText = String(chatInput?.value || '').trim();
      setVoiceListeningState(true);
      recognition.start();
      return true;
    } catch (_) {
      setVoiceListeningState(false);
      return false;
    }
  }

  voiceBtn?.addEventListener('click', toggleVoiceRecognition);

  let conversationHistory = [];
  try {
    const saved = win?.sessionStorage?.getItem(storageKey);
    if (saved) {
      const parsed = JSON.parse(saved);
      if (Array.isArray(parsed)) conversationHistory = parsed.slice(-8);
    }
  } catch (_) {}

  loadResponseCache();

  function saveHistory() {
    try {
      win?.sessionStorage?.setItem(storageKey, JSON.stringify(conversationHistory.slice(-8)));
    } catch (_) {}
  }

  function updateKnowledgeEntries(newEntries) {
    if (!Array.isArray(newEntries)) return kbVersion;
    const prevVersion = kbVersion;
    knowledgeEntries = [...newEntries];
    kbVersion = computeKnowledgeVersion(knowledgeEntries);

    if (prevVersion !== kbVersion) {
      responseCache = { kbVersion, entries: {} };
      saveResponseCache();

      let historyUpdated = false;
      for (let i = 0; i < conversationHistory.length - 1; i++) {
        if (conversationHistory[i].role === 'user' && conversationHistory[i + 1]?.role === 'model') {
          const userQ = conversationHistory[i].text;
          const matched = searchKnowledgeEntries(userQ, knowledgeEntries, 1);
          if (matched.length > 0) {
            const refreshedAnswer = getLocalFallbackAnswer(userQ, siteId, knowledgeEntries);
            if (conversationHistory[i + 1].text !== refreshedAnswer) {
              conversationHistory[i + 1].text = refreshedAnswer;
              setCachedAnswer(userQ, refreshedAnswer, 'kb_live_sync');
              historyUpdated = true;
            }
          }
        }
      }
      if (historyUpdated) {
        saveHistory();
        renderInitialView();
      }
    }
    return kbVersion;
  }

  async function refreshKnowledge() {
    const fetchFn = win?.fetch || globalThis.fetch;
    if (typeof fetchFn !== 'function') return kbVersion;

    const liveTerms = win?.__SALSOPEDIA_TERMS__ || win?.AppState?.terms;
    if (Array.isArray(liveTerms) && liveTerms.length > 0) {
      updateKnowledgeEntries(liveTerms);
    }

    const urlsToTry = [kbApiUrl, kbUrl].filter(Boolean);
    for (const url of urlsToTry) {
      try {
        const res = await fetchFn(url, { cache: 'no-store' });
        if (res && res.ok) {
          const data = await res.json();
          if (Array.isArray(data) && data.length > 0) {
            updateKnowledgeEntries(data);
            break;
          }
        }
      } catch (_) {}
    }
    return kbVersion;
  }

  function appendMessageElement(role, text) {
    if (!messagesContainer) return null;
    const msg = doc.createElement('div');
    msg.className = 'tsw-ai-msg ' + (role === 'user' ? 'tsw-ai-msg-user' : 'tsw-ai-msg-bot');
    if (role === 'user') {
      msg.textContent = text;
    } else {
      msg.innerHTML = formatMarkdown(text);
    }
    messagesContainer.appendChild(msg);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
    return msg;
  }

  function setChipsVisible(visible) {
    if (!chipsContainer) return;
    chipsContainer.classList?.toggle('tsw-hidden', !visible);
  }

  const analyticsUrl = routerUrl.replace(/\/chat-router\.php.*$/, '/analytics');

  function sendAnalyticsBeacon(extra) {
    try {
      const nav = win?.navigator || (typeof navigator !== 'undefined' ? navigator : null);
      const loc = win?.location || {};
      const params = new URLSearchParams(loc.search || '');
      const rawPath = (loc.pathname || '/') + (loc.hash || '');
      const payload = Object.assign({
        site_id: siteId,
        type: 'pageview',
        path: rawPath || '/',
        referrer: doc?.referrer || '',
        utm_source: params.get('utm_source') || '',
        utm_term: params.get('utm_term') || params.get('q') || ''
      }, extra || {});
      const body = JSON.stringify(payload);
      let sent = false;
      if (nav && typeof nav.sendBeacon === 'function') {
        try {
          sent = nav.sendBeacon(analyticsUrl, body);
        } catch (_) {}
      }
      const fetchFn = win?.fetch || globalThis.fetch;
      if (!sent && typeof fetchFn === 'function') {
        fetchFn(analyticsUrl, {
          method: 'POST',
          body,
          keepalive: true,
          mode: 'cors',
          credentials: 'omit'
        }).catch(() => {});
      }
    } catch (_) {}
  }

  function renderChips() {
    if (!chipsContainer) return;
    chipsContainer.innerHTML = '';
    if (conversationHistory.length > 0) {
      setChipsVisible(false);
      return;
    }
    setChipsVisible(true);
    quickPrompts.forEach((promptText) => {
      const chip = doc.createElement('button');
      chip.type = 'button';
      chip.className = 'tsw-ai-chip';
      chip.textContent = promptText;
      chip.addEventListener('click', () => {
        sendAnalyticsBeacon({ type: 'event', event: 'quick_prompt_click' });
        sendQuestion(promptText);
      });
      chipsContainer.appendChild(chip);
    });
  }

  function renderInitialView() {
    if (!messagesContainer) return;
    messagesContainer.innerHTML = '';
    const welcomeText =
      siteId === 'katosalsahub'
        ? `Cześć! 💃🕺 Jestem wirtualnym asystentem **${title}**. Moim głównym centrum wiedzy jest **Salsopedia**, ale odpowiem też na wszystkie pytania o nasze potańcówki w Katowicach, style tańca, **Radio Timba Nation** i **DancePuls**. O co chcesz zapytać?`
        : siteId === 'fuegolingua'
        ? '¡Hola! 💃 Jestem wirtualnym doradcą **Fuego Lingua**. W czym mogę Ci pomóc? Zapytaj o bezpłatną lekcję próbną, cennik lub kursy hiszpańskiego!'
        : siteId === 'raricart'
        ? 'Cześć! 🥞🍦🧀 Jestem wirtualnym doradcą **Raricart Live Food Station**. Zapytaj o cennik stacji na żywo (Lody Włoskie, Mini Pancakes, Deska Serów), pakiety łączone lub dostępność terminu na Twoje wesele czy event!'
        : `Cześć! 👋 Jestem wirtualnym doradcą **${title}**. W czym mogę Ci pomóc? Zapytaj o ofertę, wycenę lub współpracę!`;

    appendMessageElement('model', welcomeText);
    for (let i = 0; i < conversationHistory.length; i++) {
      appendMessageElement(conversationHistory[i].role, conversationHistory[i].text);
    }
    renderChips();
  }

  function toggleChat() {
    if (!chatWindow || !toggleBtn) return;
    const isOpen = chatWindow.classList.toggle('tsw-open');
    toggleBtn.setAttribute('aria-expanded', String(isOpen));
    if (isOpen) {
      chatInput?.focus?.();
      sendAnalyticsBeacon({ type: 'event', event: 'chat_open' });
      if (kbUrl || kbApiUrl) {
        refreshKnowledge();
      }
    } else {
      stopVoiceRecognition();
    }
  }

  function closeChat() {
    if (!chatWindow || !toggleBtn) return;
    stopVoiceRecognition();
    chatWindow.classList.remove('tsw-open');
    toggleBtn.setAttribute('aria-expanded', 'false');
    toggleBtn.focus?.();
  }

  toggleBtn?.addEventListener('click', toggleChat);
  closeBtn?.addEventListener('click', closeChat);
  clearBtn?.addEventListener('click', () => {
    stopVoiceRecognition();
    conversationHistory = [];
    saveHistory();
    renderInitialView();
  });

  // Automatyczne zamykanie czatu po kliknięciu w link kotwicowy (#kontakt, #mapa) wewnątrz odpowiedzi
  messagesContainer?.addEventListener?.('click', (e) => {
    const target = e?.target;
    const link = target?.closest ? target.closest('a[href]') : (target?.tagName === 'A' ? target : null);
    if (!link) return;
    const href = String(link.getAttribute('href') || '');
    if (href.startsWith('#') && href.length > 1) {
      closeChat();
    }
  });

  doc.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && chatWindow?.classList.contains('tsw-open')) {
      closeChat();
    }
  });

  const handleKnowledgeEvent = (e) => {
    const terms = e?.detail?.terms || win?.__SALSOPEDIA_TERMS__ || win?.AppState?.terms;
    if (Array.isArray(terms)) {
      updateKnowledgeEntries(terms);
    } else {
      refreshKnowledge();
    }
  };
  win?.addEventListener?.('salsopedia:updated', handleKnowledgeEvent);
  doc.addEventListener?.('salsopedia:updated', handleKnowledgeEvent);
  win?.addEventListener?.('storage', (e) => {
    if (!e || e.key === 'ksh_salsopedia_sync') {
      refreshKnowledge();
    }
  });

  async function sendQuestion(text) {
    const trimmed = String(text || '').trim();
    if (!trimmed || sendBtn?.disabled) return;

    stopVoiceRecognition();

    const liveGlobalTerms = win?.__SALSOPEDIA_TERMS__ || win?.AppState?.terms;
    if (Array.isArray(liveGlobalTerms) && liveGlobalTerms.length > 0) {
      updateKnowledgeEntries(liveGlobalTerms);
    }

    setChipsVisible(false);
    appendMessageElement('user', trimmed);
    if (chatInput) chatInput.value = '';

    const cachedAnswer = getCachedAnswer(trimmed);
    if (cachedAnswer) {
      appendMessageElement('model', cachedAnswer);
      conversationHistory.push({ role: 'user', text: trimmed });
      conversationHistory.push({ role: 'model', text: cachedAnswer });
      conversationHistory = conversationHistory.slice(-8);
      saveHistory();
      if (messagesContainer) messagesContainer.scrollTop = messagesContainer.scrollHeight;
      return { answer: cachedAnswer, cached: true, kbVersion };
    }

    const typingMsg = doc.createElement('div');
    typingMsg.className = 'tsw-ai-msg tsw-ai-msg-bot tsw-ai-typing';
    typingMsg.textContent = 'Asystent pisze...';
    messagesContainer?.appendChild(typingMsg);
    if (messagesContainer) messagesContainer.scrollTop = messagesContainer.scrollHeight;

    if (sendBtn) sendBtn.disabled = true;

    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timeoutId = controller ? setTimeout(() => controller.abort(), 9000) : null;

    const dynamicContext = buildDynamicContext(trimmed, knowledgeEntries);

    try {
      const fetchFn = win?.fetch || globalThis.fetch;
      const res = await fetchFn(routerUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        ...(controller ? { signal: controller.signal } : {}),
        body: JSON.stringify({
          site_id: siteId,
          question: trimmed,
          kb_version: kbVersion,
          dynamic_context: dynamicContext,
          history: conversationHistory.slice(-8)
        })
      });

      const data = await res.json();
      typingMsg.remove?.();

      if (res.ok && data && data.success && data.answer) {
        appendMessageElement('model', data.answer);
        setCachedAnswer(trimmed, data.answer, 'ai');
        conversationHistory.push({ role: 'user', text: trimmed });
        conversationHistory.push({ role: 'model', text: data.answer });
        conversationHistory = conversationHistory.slice(-8);
        saveHistory();
        return { answer: data.answer, cached: Boolean(data.cached), kbVersion };
      } else {
        const fallback = getLocalFallbackAnswer(trimmed, siteId, knowledgeEntries);
        appendMessageElement('model', fallback);
        setCachedAnswer(trimmed, fallback, 'fallback');
        conversationHistory.push({ role: 'user', text: trimmed });
        conversationHistory.push({ role: 'model', text: fallback });
        conversationHistory = conversationHistory.slice(-8);
        saveHistory();
        return { answer: fallback, cached: false, kbVersion };
      }
    } catch (_) {
      typingMsg.remove?.();
      const fallback = getLocalFallbackAnswer(trimmed, siteId, knowledgeEntries);
      appendMessageElement('model', fallback);
      setCachedAnswer(trimmed, fallback, 'fallback');
      conversationHistory.push({ role: 'user', text: trimmed });
      conversationHistory.push({ role: 'model', text: fallback });
      conversationHistory = conversationHistory.slice(-8);
      saveHistory();
      return { answer: fallback, cached: false, kbVersion };
    } finally {
      if (timeoutId) clearTimeout(timeoutId);
      if (sendBtn) sendBtn.disabled = false;
      if (messagesContainer) messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }
  }

  chatForm?.addEventListener('submit', (e) => {
    if (typeof e.preventDefault === 'function') e.preventDefault();
    sendQuestion(chatInput?.value || '');
  });

  renderInitialView();

  if (win && !win.__TSW_ANALYTICS_ACTIVE__ && (typeof win.navigator?.sendBeacon === 'function' || typeof win.fetch === 'function')) {
    win.__TSW_ANALYTICS_ACTIVE__ = true;
    let lcpMeasured = 0;
    try {
      if (typeof PerformanceObserver !== 'undefined' && doc.visibilityState !== 'hidden') {
        const po = new PerformanceObserver((list) => {
          if (doc.visibilityState === 'hidden') return;
          const entries = list.getEntries();
          if (entries && entries.length > 0) {
            const candidate = Math.round(entries[entries.length - 1].startTime || 0);
            if (candidate >= 50 && candidate <= 8000) {
              lcpMeasured = candidate;
            }
          }
        });
        po.observe({ type: 'largest-contentful-paint', buffered: true });
      }
    } catch (_) {}

    setTimeout(() => {
      sendAnalyticsBeacon(lcpMeasured > 0 ? { type: 'pageview', lcp_ms: lcpMeasured } : { type: 'pageview' });
    }, 600);

    win.addEventListener?.('hashchange', () => {
      sendAnalyticsBeacon({ type: 'pageview' });
    });

    setTimeout(() => {
      if (doc.visibilityState !== 'hidden') {
        sendAnalyticsBeacon({ type: 'engaged' });
      }
    }, 15000);

    doc.addEventListener?.('click', (e) => {
      const target = e?.target?.closest ? e.target : null;
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

    doc.addEventListener?.('submit', (e) => {
      const form = e?.target;
      if (form && form.id !== 'tsw-ai-form' && (form.id === 'contactForm' || form.classList?.contains?.('contact-form'))) {
        sendAnalyticsBeacon({ type: 'event', event: 'contact_form_submit' });
      }
    });
  }

  if ((kbUrl || kbApiUrl) && knowledgeEntries.length === 0 && !options.skipInitialFetch) {
    refreshKnowledge();
  }

  return {
    root,
    toggleBtn,
    closeBtn,
    clearBtn,
    chatWindow,
    chatForm,
    chatInput,
    voiceBtn,
    messagesContainer,
    chipsContainer,
    sendBtn,
    toggleChat,
    closeChat,
    sendQuestion,
    toggleVoiceRecognition,
    stopVoiceRecognition,
    isVoiceListening: () => isListening,
    getHistory: () => conversationHistory,
    getKnowledgeVersion: () => kbVersion,
    getKnowledgeEntries: () => knowledgeEntries,
    updateKnowledgeEntries,
    refreshKnowledge,
    getCachedAnswer,
    clearCache: () => {
      responseCache = { kbVersion, entries: {} };
      saveResponseCache();
    }
  };
}

function autoInitAiWidget() {
  if (typeof document === 'undefined') return;
  if (document.getElementById('tsw-ai-widget-root')) return;
  if (document.body) {
    initAiWidget(document, globalThis.window);
  }
}

if (typeof document !== 'undefined') {
  if (document.body) {
    autoInitAiWidget();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', autoInitAiWidget);
  }
  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('load', autoInitAiWidget);
  }
}

const __tswExports = {
  QUICK_PROMPTS_MAP,
  THEME_PRESETS,
  normalizeCacheQuery,
  normalizeSearchText,
  computeKnowledgeVersion,
  searchKnowledgeEntries,
  buildDynamicContext,
  formatMarkdown,
  getLocalFallbackAnswer,
  initAiWidget
};
if (typeof globalThis !== "undefined") {
  Object.assign(globalThis, __tswExports);
}
if (typeof window !== "undefined") {
  Object.assign(window, __tswExports);
}
if (typeof module !== "undefined" && module.exports) {
  module.exports = __tswExports;
}
})();

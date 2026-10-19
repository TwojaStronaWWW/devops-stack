// scripts/setup-kuma.js
// Automatyczna konfiguracja konta admina i monitorowanych serwisów w Uptime Kuma

import { io } from "socket.io-client";

const ADMIN_USER = process.env.KUMA_ADMIN_USER;
const ADMIN_PASS = process.env.KUMA_ADMIN_PASS;
const KUMA_URL = process.env.KUMA_URL || "http://127.0.0.1:3001";

if (!ADMIN_USER || !ADMIN_PASS) {
    console.error("BŁĄD: Zmienne KUMA_ADMIN_USER i KUMA_ADMIN_PASS są wymagane w środowisku (.env).");
    process.exit(1);
}

const SITES = [
    { name: "Raricart.pl", url: "https://raricart.pl" },
    { name: "TwojaStronaWWW.pl", url: "https://twojastronawww.pl" },
    { name: "DancePuls.pl", url: "https://dancepuls.katosalsahub.pl/" },
    { name: "KatoSalsaHub.pl", url: "https://katosalsahub.pl" },
    { name: "osTicket Helpdesk", url: "https://hd.twojastronawww.pl" },
    { name: "GalAnonim.pl", url: "https://galanonim.pl" },
    { name: "GalAnonim API", url: "https://api.galanonim.pl/" },
    { name: "Serwis Maxbit", url: "https://serwis.maxbit.com.pl/" },
    { name: "FuegoLingua.pl", url: "https://fuegolingua.pl/" },
    { name: "AI Router Healthcheck", url: "http://ai-router:8080/health" },
    { name: "Asystent AMMS & Oracle DBA", url: "http://ai-router:8080/amms" },
];

console.log("==> Łączenie z Uptime Kuma pod " + KUMA_URL + "...");

const socket = io(KUMA_URL, {
    reconnection: false,
    timeout: 10000,
});

let existingMonitors = {};
socket.on("monitorList", (data) => {
    if (data && typeof data === "object") {
        existingMonitors = { ...existingMonitors, ...data };
    }
});

socket.on("connect", () => {
    console.log("==> Połączono przez WebSocket. Sprawdzanie stanu instalacji...");

    socket.emit("needSetup", async (needSetup) => {
        console.log("--> needSetup:", needSetup);

        if (needSetup) {
            console.log(`--> Konfiguracja konta administratora '${ADMIN_USER}'...`);
            await new Promise((resolve, reject) => {
                socket.emit("setup", ADMIN_USER, ADMIN_PASS, (res) => {
                    if (res.ok) {
                        console.log("--> [OK] Administrator utworzony pomyślnie.");
                        resolve();
                    } else {
                        console.error("--> [BŁĄD] Setup nie powiódł się:", res.msg);
                        reject(new Error(res.msg));
                    }
                });
            });
        }

        console.log(`--> Logowanie jako '${ADMIN_USER}'...`);
        socket.emit("login", {
            username: ADMIN_USER,
            password: ADMIN_PASS,
        }, async (res) => {
            if (!res.ok) {
                console.error("--> [BŁĄD] Logowanie nie powiodło się:", res.msg);
                socket.close();
                process.exit(1);
            }

            console.log("--> [OK] Zalogowano pomyślnie! Oczekiwanie na listę istniejących monitorów...");
            await new Promise((r) => setTimeout(r, 800));

            const monitorValues = Object.values(existingMonitors).sort((a, b) => a.id - b.id);
            console.log(`--> Wykryto ${monitorValues.length} monitorów w bazie Uptime Kuma.`);

            // 1. Usuwanie duplikatów (zostawiamy najstarszy monitor o danej nazwie, z preferencją poprawnego URL)
            const byName = new Map();
            for (const m of monitorValues) {
                if (!byName.has(m.name)) {
                    byName.set(m.name, []);
                }
                byName.get(m.name).push(m);
            }

            const keptByName = new Map();
            for (const [name, list] of byName.entries()) {
                const targetSite = SITES.find((s) => s.name === name);
                // Wybierz monitor z poprawnym URL (jeśli istnieje), w przeciwnym razie najstarszy (najniższe ID)
                let primary = list[0];
                if (targetSite) {
                    const exactMatch = list.find((m) => m.url === targetSite.url);
                    if (exactMatch) {
                        primary = exactMatch;
                    }
                }
                keptByName.set(name, primary);

                for (const m of list) {
                    if (m.id !== primary.id) {
                        console.log(`--> [DEDUPLIKACJA] Usuwanie zduplikowanego monitora ID=${m.id}: ${m.name} (${m.url})...`);
                        await new Promise((resolve) => {
                            socket.emit("deleteMonitor", m.id, (delRes) => {
                                if (delRes && delRes.ok) {
                                    console.log(`    [USUNIĘTO] Duplikat ID=${m.id} (${m.name})`);
                                } else {
                                    console.log(`    [INFO] Status usuwania ID=${m.id}: ${delRes ? delRes.msg : "brak"}`);
                                }
                                resolve();
                            });
                        });
                    }
                }
            }

            // 2. Dodawanie brakujących monitorów lub aktualizacja URL, jeśli się zmienił
            for (const site of SITES) {
                const existing = keptByName.get(site.name);
                if (existing) {
                    if (existing.url !== site.url) {
                        console.log(`--> [AKTUALIZACJA URL] ${site.name} (ID=${existing.id}): ${existing.url} -> ${site.url}`);
                        const updatedMonitor = {
                            ...existing,
                            url: site.url,
                        };
                        await new Promise((resolve) => {
                            socket.emit("editMonitor", updatedMonitor, (editRes) => {
                                if (editRes && editRes.ok) {
                                    console.log(`    [OK] Zaktualizowano URL dla: ${site.name}`);
                                } else {
                                    console.log(`    [INFO] Informacja: ${editRes ? editRes.msg : "brak"}`);
                                }
                                resolve();
                            });
                        });
                    } else {
                        console.log(`--> [OK / ISTNIEJE] ${site.name} (ID=${existing.id}, ${site.url}) — pomijam duplikowanie.`);
                    }
                    continue;
                }

                console.log(`--> [NOWY] Dodawanie monitora: ${site.name} (${site.url})...`);

                const monitorData = {
                    type: "http",
                    name: site.name,
                    url: site.url,
                    method: "GET",
                    interval: 60,
                    retryInterval: 60,
                    resendInterval: 0,
                    maxretries: 3,
                    accepted_statuscodes: ["200-299"],
                    expiryNotification: true,
                    ignoreTls: false,
                    upsideDown: false,
                    maxredirects: 10,
                    kafkaProducerBrokers: [],
                    kafkaProducerSaslOptions: {},
                    notificationIDList: {},
                };

                await new Promise((resolve) => {
                    socket.emit("add", monitorData, (addRes) => {
                        if (addRes.ok) {
                            console.log(`    [OK] Dodano: ${site.name}`);
                        } else {
                            console.log(`    [INFO] Informacja: ${addRes.msg}`);
                        }
                        resolve();
                    });
                });
            }

            console.log(`==> [SUKCES] Synchronizacja zakończona! Aktywne unikalne serwisy: ${SITES.length}.`);
            socket.close();
            process.exit(0);
        });
    });
});

socket.on("connect_error", (err) => {
    console.error("==> Błąd połączenia z Uptime Kuma:", err.message);
    process.exit(1);
});

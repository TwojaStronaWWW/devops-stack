// scripts/setup-ntfy.js
// Idempotentna konfiguracja powiadomień Push (Ntfy.sh) w Uptime Kuma (ESM)

import { io } from "socket.io-client";

const ADMIN_USER = process.env.KUMA_ADMIN_USER;
const ADMIN_PASS = process.env.KUMA_ADMIN_PASS;
const KUMA_URL = process.env.KUMA_URL || "http://127.0.0.1:3001";
const TOPIC = process.env.NTFY_TOPIC;

if (!ADMIN_USER || !ADMIN_PASS) {
    console.error("BŁĄD: Zmienne KUMA_ADMIN_USER i KUMA_ADMIN_PASS są wymagane w środowisku (.env).");
    process.exit(1);
}

if (!TOPIC || TOPIC === "twojastronawww-alerty-prod") {
    console.error("BŁĄD: Zmienna NTFY_TOPIC musi być ustawiona na unikalny temat w pliku .env.");
    process.exit(1);
}

const NOTIFICATION_NAME = "Alerty na Telefon (Ntfy)";

const socket = io(KUMA_URL, {
    reconnection: false,
    timeout: 10000,
});

let existingNotifications = [];
socket.on("notificationList", (data) => {
    if (Array.isArray(data)) {
        existingNotifications = data;
    }
});

socket.on("connect", () => {
    socket.emit("login", {
        username: ADMIN_USER,
        password: ADMIN_PASS,
    }, async (res) => {
        if (!res.ok) {
            console.error("Błąd logowania:", res.msg);
            socket.close();
            process.exit(1);
        }

        console.log("==> Zalogowano pomyślnie. Sprawdzanie istniejących powiadomień Ntfy...");
        await new Promise((r) => setTimeout(r, 600));

        const matching = existingNotifications
            .filter((n) => n && n.name === NOTIFICATION_NAME)
            .sort((a, b) => a.id - b.id);

        let targetId = null;
        if (matching.length > 0) {
            targetId = matching[0].id;
            for (const dup of matching.slice(1)) {
                console.log(`--> [DEDUPLIKACJA] Usuwanie zduplikowanego powiadomienia ID=${dup.id} (${dup.name})...`);
                await new Promise((resolve) => {
                    socket.emit("deleteNotification", dup.id, () => resolve());
                });
            }
        }

        const ntfyNotification = {
            name: NOTIFICATION_NAME,
            type: "ntfy",
            isDefault: true,
            applyExisting: true,
            ntfytopic: TOPIC,
            ntfyserverurl: "https://ntfy.sh",
            ntfyPriority: 5,
            ntfyAuthenticationMethod: "none",
        };

        // 1. Wykonaj test powiadomienia
        console.log(`--> Wysyłanie wiadomości testowej do https://ntfy.sh/${TOPIC}...`);
        await new Promise((resolve) => {
            socket.emit("testNotification", ntfyNotification, (testRes) => {
                if (testRes && testRes.ok) {
                    console.log("--> [SUKCES] Test Ntfy zakończony pomyślnie! Wiadomość wysłana na telefon.");
                } else {
                    console.error("--> [BŁĄD] Test nie powiódł się:", testRes ? testRes.msg : "brak odpowiedzi");
                }
                resolve();
            });
        });

        // 2. Zapisz lub zaktualizuj powiadomienie idempotentnie
        console.log(
            targetId
                ? `--> Aktualizacja istniejącego powiadomienia Ntfy (ID=${targetId}) w bazie Uptime Kuma...`
                : "--> Tworzenie nowego powiadomienia Ntfy w bazie Uptime Kuma..."
        );
        await new Promise((resolve) => {
            socket.emit("addNotification", ntfyNotification, targetId, (saveRes) => {
                if (saveRes && saveRes.ok) {
                    console.log("--> [SUKCES] Powiadomienie Ntfy zapisane i podpięte pod wszystkie monitory!");
                } else {
                    console.error("--> [BŁĄD] Zapis nie powiódł się:", saveRes ? saveRes.msg : "brak odpowiedzi");
                }
                resolve();
            });
        });

        socket.close();
        process.exit(0);
    });
});


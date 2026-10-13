// scripts/setup-ntfy.js
const { io } = require("socket.io-client");

const ADMIN_USER = process.env.KUMA_ADMIN_USER;
const ADMIN_PASS = process.env.KUMA_ADMIN_PASS;
const KUMA_URL = process.env.KUMA_URL || "http://127.0.0.1:3001";
const TOPIC = process.env.NTFY_TOPIC || "kpoczatek-vps-alerty";

if (!ADMIN_USER || !ADMIN_PASS) {
    console.error("BŁĄD: Zmienne KUMA_ADMIN_USER i KUMA_ADMIN_PASS są wymagane w środowisku (.env).");
    process.exit(1);
}

const socket = io(KUMA_URL, {
    reconnection: false,
    timeout: 10000,
});

socket.on("connect", () => {
    socket.emit("login", {
        username: ADMIN_USER,
        password: ADMIN_PASS,
    }, async (res) => {
        if (!res.ok) {
            console.error("Błąd logowania:", res.msg);
            process.exit(1);
        }

        console.log("Zalogowano pomyślnie. Konfiguracja Ntfy...");

        const ntfyNotification = {
            name: "Alerty na Telefon (Ntfy)",
            type: "ntfy",
            isDefault: true,
            applyExisting: true,
            ntfytopic: TOPIC,
            ntfyserverurl: "https://ntfy.sh",
            ntfyPriority: 5,
            ntfyAuthenticationMethod: "none",
        };

        // 1. Wykonaj test
        console.log(`Wysyłanie testu do https://ntfy.sh/${TOPIC}...`);
        await new Promise((resolve) => {
            socket.emit("testNotification", ntfyNotification, (testRes) => {
                if (testRes.ok) {
                    console.log("--> [SUKCES] Test Ntfy zakończony pomyślnie! Wiadomość wysłana na telefon.");
                } else {
                    console.error("--> [BŁĄD] Test nie powiódł się:", testRes.msg);
                }
                resolve();
            });
        });

        // 2. Zapisz powiadomienie
        console.log("Zapisywanie powiadomienia w bazie Uptime Kuma...");
        await new Promise((resolve) => {
            socket.emit("addNotification", ntfyNotification, null, (saveRes) => {
                if (saveRes.ok) {
                    console.log("--> [SUKCES] Powiadomienie Ntfy zapisane i podpięte pod wszystkie monitory!");
                } else {
                    console.error("--> [BŁĄD] Zapis nie powiódł się:", saveRes.msg);
                }
                resolve();
            });
        });

        socket.close();
        process.exit(0);
    });
});

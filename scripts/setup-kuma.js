// scripts/setup-kuma.js
// Automatyczna konfiguracja konta admina i monitorowanych serwisów w Uptime Kuma

const { io } = require("socket.io-client");

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
    { name: "DancePuls.pl", url: "https://dancepuls.pl" },
    { name: "KatoSalsaHub.pl", url: "https://katosalsahub.pl" },
    { name: "osTicket Helpdesk", url: "https://hd.twojastronawww.pl" },
    { name: "GalAnonim.pl", url: "https://galanonim.pl" },
    { name: "GalAnonim API", url: "https://api.galanonim.pl/" },
    { name: "Serwis Maxbit", url: "https://serwis.maxbit.com.pl/" },
    { name: "FuegoLingua.pl", url: "https://fuegolingua.pl/" },
];

console.log("==> Łączenie z Uptime Kuma pod " + KUMA_URL + "...");

const socket = io(KUMA_URL, {
    reconnection: false,
    timeout: 10000,
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

            console.log("--> [OK] Zalogowano pomyślnie!");

            for (const site of SITES) {
                console.log(`--> Dodawanie monitora: ${site.name} (${site.url})...`);

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

            console.log("==> [SUKCES] Wszystkie 7 serwisów zostało pomyślnie dodanych i uruchomionych!");
            socket.close();
            process.exit(0);
        });
    });
});

socket.on("connect_error", (err) => {
    console.error("==> Błąd połączenia z Uptime Kuma:", err.message);
    process.exit(1);
});

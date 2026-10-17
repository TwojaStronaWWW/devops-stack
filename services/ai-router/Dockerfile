# ==============================================================================
# AI ROUTER MICROSERVICE - DOCKERFILE (PHP 8.3 ALPINE)
# Standard: Zero-Bloat, ISO 27001 (PoLP / Non-Root), Architecture: ARM64 & AMD64
# ==============================================================================
FROM php:8.3-alpine

# Zainstaluj tylko niezbędne pakiety runtime (cURL, CA certyfikaty do bezpiecznego TLS)
RUN apk add --no-cache curl ca-certificates && \
    mkdir -p /app/src /app/data /app/storage/rate_limits && \
    chown -R nobody:nobody /app

WORKDIR /app

# Kopiowanie kodu źródłowego
COPY --chown=nobody:nobody src/ /app/src/

# Uruchomienie jako użytkownik nieuprzywilejowany (nobody:nobody - PoLP)
USER nobody

# Port wewnętrzny kontenera
EXPOSE 8080

# Wbudowany, lekki serwer HTTP PHP przekierowujący ruch przez router (brak ciężkiego Apache/Nginx, ukryty X-Powered-By)
CMD ["php", "-d", "expose_php=0", "-S", "0.0.0.0:8080", "-t", "/app/src", "/app/src/chat-router.php"]

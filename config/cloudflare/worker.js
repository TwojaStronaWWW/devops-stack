/**
 * TwojaStronaWWW Zero-Trust Edge Tunnel Router (Cloudflare Workers VPC)
 * Kieruje ruch HTTPS z subdomen push.twojastronawww.pl oraz sejf.twojastronawww.pl
 * bezpośrednio przez szyfrowany tunel Cloudflare (77d91fca-0f1b-4167-8bff-7a5c2671b058)
 * do kontenerów ntfy:8080 i privatebin:8080 w sieci devops_internal_network.
 */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const host = url.hostname.toLowerCase();

    // Kontenery wewnątrz szyfrowanego tunelu Cloudflare VPC nasłuchują na porcie 8080 HTTP
    url.protocol = "http:";

    const headers = new Headers(request.headers);
    headers.set("Host", host);
    headers.set("X-Forwarded-Proto", "https");
    headers.set("X-Forwarded-Host", host);

    const upstreamReq = new Request(url.toString(), {
      method: request.method,
      headers,
      body: request.method !== "GET" && request.method !== "HEAD" ? request.body : null,
      redirect: "manual"
    });

    if (host === "push.twojastronawww.pl") {
      return env.NTFY_VPC.fetch(upstreamReq);
    }
    if (host === "sejf.twojastronawww.pl") {
      return env.PRIVATEBIN_VPC.fetch(upstreamReq);
    }

    return new Response("Not Found", { status: 404 });
  }
};

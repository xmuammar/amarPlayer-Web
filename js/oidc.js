function base64Url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function sha256(text) {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

function randomVerifier() {
  const bytes = new Uint8Array(48);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

export async function loadAuthConfig() {
  try {
    const response = await fetch("/api/auth/config", { cache: "no-store" });
    if (!response.ok) return { enabled: false };
    return response.json();
  } catch {
    return { enabled: false };
  }
}

export async function startLogin(config) {
  if (!config?.enabled || !config.authorization_endpoint) return;

  const verifier = randomVerifier();
  const challenge = base64Url(await sha256(verifier));
  const state = crypto.randomUUID();

  sessionStorage.setItem("amar_oidc_verifier", verifier);
  sessionStorage.setItem("amar_oidc_state", state);

  const url = new URL(config.authorization_endpoint);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", config.client_id);
  url.searchParams.set("redirect_uri", config.redirect_uri || location.origin + "/");
  url.searchParams.set("scope", config.scope || "openid profile email");
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");

  location.assign(url.toString());
}

/*
 * amarSSO is intentionally not emulated locally.
 * This module prepares Authorization Code + PKCE initiation.
 * Token exchange will be wired when amarSSO's OIDC endpoints are created.
 */

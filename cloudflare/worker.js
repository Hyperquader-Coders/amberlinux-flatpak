// Serves an ostree repo for flatpak. objects/** and deltas/** come from R2;
// everything else — the summary, config, refs and the landing page — falls
// through to static assets.
//
// The split is the 25 MiB asset cap. Most ostree objects are small, but a repo
// carrying a toolchain has a few that are not: the Odin SDK extension's libLLVM
// is over 100 MiB before compression. Splitting by prefix rather than by size
// keeps the rule something a person can hold in their head.
//
// flatpak needs real status codes and untouched bytes — no path redirects,
// ever. The scheme is the one exception: signatures prove origin, not
// freshness, so plain HTTP lets an on-path attacker stall or replay an older
// validly signed summary, and ostree has no rollback protection. HTTP gets a
// 301 to the same path over TLS, and every response carries HSTS.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.protocol === 'http:') {
      url.protocol = 'https:';
      return Response.redirect(url.toString(), 301);
    }

    // html_handling "none" keeps the extension-less ostree files byte-exact,
    // and also disables / -> index.html, so the landing page is mapped here.
    if (url.pathname === '/') {
      return env.ASSETS.fetch(new URL('/index.html', url).toString());
    }

    const fromR2 =
      url.pathname.startsWith('/objects/') || url.pathname.startsWith('/deltas/');
    if (!fromR2) {
      return env.ASSETS.fetch(request);
    }

    // On error responses too: HSTS pins on whatever response a client sees
    // first, and a probe of a missing object must not be the exception.
    const hsts = { 'Strict-Transport-Security': 'max-age=31536000' };

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('method not allowed', { status: 405, headers: hsts });
    }

    let key;
    try {
      key = decodeURIComponent(url.pathname).slice(1);
    } catch {
      return new Response('bad request', { status: 400, headers: hsts });
    }

    const object = await env.OBJECTS.get(key);
    if (object === null) {
      return new Response('not found', { status: 404, headers: hsts });
    }

    // Most ostree objects are content-addressed — the checksum IS the filename —
    // so they can never change and cache forever. Two kinds can:
    //   .commitmeta  named after its commit; rewritten when a signature is added
    //   deltas/**    named after a commit pair; rewritten when regenerated
    // Caching those as immutable pins a stale copy at the edge for a year, and
    // the symptoms are "no signatures found" and "Invalid checksum for static
    // delta" — neither of which points anywhere near a caching header.
    const mutable =
      url.pathname.endsWith('.commitmeta') || url.pathname.startsWith('/deltas/');
    const headers = new Headers({
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(object.size),
      'Cache-Control': mutable
        ? 'public, no-cache'
        : 'public, max-age=31536000, immutable',
      ETag: object.httpEtag,
      'Strict-Transport-Security': 'max-age=31536000',
    });
    return new Response(request.method === 'HEAD' ? null : object.body, {
      headers,
    });
  },
};

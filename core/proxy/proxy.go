// Package proxy is SafariFix's HTTP proxy for Safari. It serves the PAC file and the root certificate, tunnels
// the hosts that work as they are, and decrypts the others so the fix package can rewrite their pages.
package proxy

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"html"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dogkeeper886/safarifix/core/certs"
	"github.com/dogkeeper886/safarifix/core/fix"
	"github.com/dogkeeper886/safarifix/core/rules"
)

// A page or script larger than this passes through unchanged.
const maxRewrite = 16 << 20

// etagMark marks the ETag of a rewritten response, so a revalidation can tell Safari's fixed copy from an unfixed
// one it cached before SafariFix ran.
const etagMark = "-sfx1"

// hopHeaders apply to one connection and never pass through a proxy.
var hopHeaders = []string{"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
	"Te", "Trailer", "Transfer-Encoding", "Upgrade"}

// Stats counts what the proxy did. Rejected counts the TLS handshakes in which Safari refused SafariFix's
// certificate, as it does while the root isn't trusted.
type Stats struct {
	Connections, Tunnels, Decrypted, Requests, Failures, Rejected int64
}

// Proxy serves Safari.
type Proxy struct {
	// First, so its 64-bit counters are 8-byte aligned, which atomic needs on 32-bit ARM: the iPhone 5 crashes
	// at address 0x4 otherwise.
	stats Stats

	auth     *certs.Authority
	fixer    *fix.Fixer
	upstream *http.Transport
	// WebSockets need HTTP/1.1, which upstream may not pick.
	upgrades *http.Transport
	logf     func(format string, args ...interface{})

	// Debug, when set, serves the paths under /debug/ of the proxy's own pages, the app's debug record, to requests
	// that name this machine by its loopback address.
	Debug http.Handler
}

// New returns a proxy that signs site certificates with auth and rewrites pages with fixer. roots verifies the
// websites' certificates; nil means the Mozilla roots built into SafariFix.
func New(auth *certs.Authority, fixer *fix.Fixer, roots *x509.CertPool, logf func(string, ...interface{})) *Proxy {
	if roots == nil {
		roots = MozillaRoots()
	}
	if logf == nil {
		logf = func(string, ...interface{}) {}
	}
	dialer := &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	upstream := &http.Transport{
		// Proxy stays nil: the proxy connects to the websites itself.
		DialContext:         dialer.DialContext,
		TLSClientConfig:     &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		ForceAttemptHTTP2:   true,
		MaxIdleConnsPerHost: 6,
		IdleConnTimeout:     90 * time.Second,
	}
	upgrades := upstream.Clone()
	upgrades.ForceAttemptHTTP2 = false
	upgrades.TLSClientConfig.NextProtos = []string{"http/1.1"}
	return &Proxy{auth: auth, fixer: fixer, logf: logf, upstream: upstream, upgrades: upgrades}
}

// MozillaRoots returns the root certificates from curl's Mozilla bundle, built in by core/go.sh.
func MozillaRoots() *x509.CertPool {
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM([]byte(mozillaRoots))
	return pool
}

// Stats returns the counts so far.
func (p *Proxy) Stats() Stats {
	return Stats{
		Connections: atomic.LoadInt64(&p.stats.Connections),
		Tunnels:     atomic.LoadInt64(&p.stats.Tunnels),
		Decrypted:   atomic.LoadInt64(&p.stats.Decrypted),
		Requests:    atomic.LoadInt64(&p.stats.Requests),
		Failures:    atomic.LoadInt64(&p.stats.Failures),
		Rejected:    atomic.LoadInt64(&p.stats.Rejected),
	}
}

// Serve answers Safari's connections on l until l closes.
func (p *Proxy) Serve(l net.Listener) error {
	srv := &http.Server{Handler: p, ErrorLog: log.New(ioutil.Discard, "", 0)}
	return srv.Serve(countingListener{l, &p.stats.Connections})
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == http.MethodConnect:
		p.connect(w, r)
	case r.URL.IsAbs() && toSelf(r):
		// Safari opening the proxy's own pages through the proxy.
		p.local(w, r)
	case r.URL.IsAbs():
		// A plain-HTTP page, asked of the proxy with its full URL.
		p.forward(w, r, "http", r.URL.Host)
	default:
		p.local(w, r)
	}
}

// local serves the pages Safari asks of the proxy itself.
func (p *Proxy) local(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/proxy.pac":
		// The PAC file names the proxy at the address Safari reached it on. DIRECT keeps Safari online while
		// the proxy isn't running.
		w.Header().Set("Content-Type", "application/x-ns-proxy-autoconfig")
		fmt.Fprintf(w, "function FindProxyForURL(url, host) { return \"PROXY %s; DIRECT\"; }\n", r.Host)
	case "/safarifix.crt":
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		w.Write(p.auth.RootDER())
	case "/":
		// The setup page, which the app opens in Safari: only what the user does here. The counts are in the
		// app's Details and the phone's log.
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, setupPage, html.EscapeString(p.auth.Root().Subject.CommonName))
	default:
		if p.Debug != nil && strings.HasPrefix(r.URL.Path, "/debug/") && namesLoopback(r) {
			http.StripPrefix("/debug", p.Debug).ServeHTTP(w, r)
			return
		}
		http.NotFound(w, r)
	}
}

// setupPage installs the root certificate; %s is the root's name.
const setupPage = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>SafariFix</title>
<style>
body { margin: 0; padding: 24px 20px; background: #efeff4; color: #000; font: 17px/1.4 -apple-system, sans-serif; }
h1 { margin: 0 0 16px; font-size: 28px; }
.card { background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
.button { display: block; margin: 16px 0 4px; padding: 13px; border-radius: 10px; background: #007aff; color: #fff;
  font-weight: 600; text-align: center; text-decoration: none; }
ol { margin: 0; padding-left: 22px; }
li { margin: 8px 0; }
.name { font-weight: 600; }
</style>
<h1>SafariFix</h1>
<div class="card">Safari needs SafariFix's certificate to open the sites SafariFix fixes.
<a class="button" href="/safarifix.crt">Install the certificate</a></div>
<div class="card"><ol>
<li>Tap <b>Allow</b>, then <b>Install</b> in Settings.</li>
<li>In Settings → General → About → Certificate Trust Settings, turn on <span class="name">%s</span> and tap <b>Continue</b>.</li>
<li>Go back to SafariFix.</li>
</ol></div>
`

func (p *Proxy) connect(w http.ResponseWriter, r *http.Request) {
	conn, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	if _, err := conn.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n")); err != nil {
		conn.Close()
		return
	}
	client := net.Conn(conn)
	if buffered.Reader.Buffered() > 0 {
		client = &prefixConn{Conn: conn, r: io.MultiReader(buffered.Reader, conn)}
	}
	if rules.ModeFor(r.Host) == rules.Pass {
		p.tunnel(client, r.Host)
	} else {
		p.decrypt(client, r.Host)
	}
}

// tunnel copies bytes between Safari and the website, untouched.
func (p *Proxy) tunnel(client net.Conn, hostport string) {
	atomic.AddInt64(&p.stats.Tunnels, 1)
	defer client.Close()
	server, err := net.DialTimeout("tcp", hostport, 15*time.Second)
	if err != nil {
		atomic.AddInt64(&p.stats.Failures, 1)
		p.logf("tunnel to %s failed: %v", hostport, err)
		return
	}
	defer server.Close()
	pipe(client, server)
}

// decrypt answers Safari's TLS with a certificate for the host, then serves its requests through forward.
func (p *Proxy) decrypt(client net.Conn, hostport string) {
	atomic.AddInt64(&p.stats.Decrypted, 1)
	host := rules.Hostname(hostport)
	base := &tls.Config{
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			if hello.ServerName != "" {
				return p.auth.For(hello.ServerName)
			}
			return p.auth.For(host)
		},
		// After one failed handshake, Safari 10 retries that host with older TLS until it quits.
		MinVersion: tls.VersionTLS10,
		NextProtos: []string{"http/1.1"},
	}
	conn := tls.Server(client, &tls.Config{
		// Safari's retry carries the fallback signal, TLS_FALLBACK_SCSV, and Go refuses it while the server could
		// speak a newer version; offering none newer than Safari does lets the retry through. Safari is on the same
		// phone, so there's no one in between to force the downgrade.
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			config := base.Clone()
			for _, v := range hello.SupportedVersions {
				if v > config.MaxVersion {
					config.MaxVersion = v
				}
			}
			return config, nil
		},
	})
	if err := conn.Handshake(); err != nil {
		atomic.AddInt64(&p.stats.Failures, 1)
		if strings.Contains(err.Error(), "remote error: tls: unknown certificate") ||
			strings.Contains(err.Error(), "remote error: tls: bad certificate") {
			atomic.AddInt64(&p.stats.Rejected, 1)
		}
		p.logf("TLS with Safari for %s failed: %v", host, err)
		client.Close()
		return
	}
	srv := &http.Server{
		Handler:  http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { p.forward(w, r, "https", hostport) }),
		ErrorLog: log.New(ioutil.Discard, "", 0),
	}
	srv.Serve(newOneConnListener(conn))
}

// forward asks the website for Safari's request, and fixes the answer by the host's mode.
func (p *Proxy) forward(w http.ResponseWriter, r *http.Request, scheme, hostport string) {
	atomic.AddInt64(&p.stats.Requests, 1)
	mode := rules.ModeFor(hostport)
	if mode == rules.Fix && r.URL.Path == fix.PolyfillPath {
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		w.Write(fix.Polyfills())
		return
	}

	out := r.Clone(r.Context())
	out.URL.Scheme, out.URL.Host = scheme, r.Host
	if r.URL.IsAbs() {
		out.URL.Host = r.URL.Host
	}
	out.RequestURI = ""
	upgrade := strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
	removeHopHeaders(out.Header)
	if upgrade {
		out.Header.Set("Connection", "Upgrade")
		out.Header.Set("Upgrade", "websocket")
	}
	// Without Accept-Encoding, the transport asks for gzip itself and unpacks it, so the body can be rewritten.
	out.Header.Del("Accept-Encoding")
	fixedCopy := mode == rules.Fix && revalidateFixedCopiesOnly(out)

	transport := p.upstream
	if upgrade {
		transport = p.upgrades
	}
	resp, err := transport.RoundTrip(out)
	if err != nil {
		atomic.AddInt64(&p.stats.Failures, 1)
		p.logf("%s %s%s failed: %v", r.Method, out.URL.Host, short(r.URL.Path), err)
		http.Error(w, "SafariFix couldn't reach the site: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusSwitchingProtocols {
		p.switchProtocols(w, resp)
		return
	}
	removeHopHeaders(resp.Header)
	if fixedCopy && resp.StatusCode == http.StatusNotModified {
		markETag(resp.Header)
	}

	ctype := strings.ToLower(resp.Header.Get("Content-Type"))
	what := out.URL.Host + short(r.URL.Path)
	var rewrite func([]byte) []byte
	switch {
	case resp.StatusCode != http.StatusOK || r.Method == http.MethodHead:
	case mode == rules.Fix && strings.Contains(ctype, "text/html"):
		rewrite = func(b []byte) []byte { return p.fixer.Page(b, what) }
		for _, h := range []string{"Content-Security-Policy", "Content-Security-Policy-Report-Only", "X-Content-Security-Policy"} {
			resp.Header.Del(h)
		}
	case mode == rules.Fix && isJavaScript(ctype, r.URL.Path):
		rewrite = func(b []byte) []byte { return p.fixer.Script(b, what) }
	case mode == rules.SignIn && strings.Contains(ctype, "text/html"):
		rewrite = fix.SignInPage
	}

	if rewrite != nil && resp.ContentLength <= maxRewrite {
		body, err := ioutil.ReadAll(io.LimitReader(resp.Body, maxRewrite+1))
		if err == nil && len(body) <= maxRewrite {
			body = rewrite(body)
			copyHeader(w.Header(), resp.Header)
			markETag(w.Header())
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.WriteHeader(resp.StatusCode)
			w.Write(body)
			return
		}
		// Too large or cut short: send what arrived, then the rest, unchanged.
		copyHeader(w.Header(), resp.Header)
		w.WriteHeader(resp.StatusCode)
		w.Write(body)
		io.Copy(w, resp.Body)
		return
	}
	copyHeader(w.Header(), resp.Header)
	w.WriteHeader(resp.StatusCode)
	copyFlushing(w, resp.Body, strings.Contains(ctype, "text/event-stream"))
}

// switchProtocols hands a WebSocket over: it answers Safari with the website's 101 and copies frames both ways.
func (p *Proxy) switchProtocols(w http.ResponseWriter, resp *http.Response) {
	server, ok := resp.Body.(io.ReadWriteCloser)
	if !ok {
		http.Error(w, "SafariFix couldn't switch protocols", http.StatusBadGateway)
		return
	}
	conn, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer conn.Close()
	resp.Header.Set("Connection", "Upgrade")
	resp.Header.Set("Upgrade", "websocket")
	fmt.Fprintf(buffered, "HTTP/1.1 101 Switching Protocols\r\n")
	resp.Header.Write(buffered)
	buffered.WriteString("\r\n")
	buffered.Flush()
	pipe(&prefixConn{Conn: conn, r: io.MultiReader(buffered.Reader, conn)}, rwConn{server})
}

// revalidateFixedCopiesOnly keeps Safari from revalidating an unfixed page or script it cached before SafariFix ran:
// a 304 would keep it. A request that names a marked ETag revalidates SafariFix's own copy and goes ahead with
// the website's ETag; a page or script request with any other condition loses its conditions and gets a fresh copy.
// It returns whether r revalidates SafariFix's own copy.
func revalidateFixedCopiesOnly(r *http.Request) bool {
	if inm := r.Header.Get("If-None-Match"); strings.Contains(inm, etagMark) {
		r.Header.Set("If-None-Match", strings.Replace(inm, etagMark, "", -1))
		r.Header.Del("If-Modified-Since")
		return true
	}
	if mayBeRewritten(r) {
		r.Header.Del("If-None-Match")
		r.Header.Del("If-Modified-Since")
	}
	return false
}

// mayBeRewritten guesses from the request alone whether its answer is a page or a script.
func mayBeRewritten(r *http.Request) bool {
	path := strings.ToLower(r.URL.Path)
	if strings.Contains(r.Header.Get("Accept"), "text/html") {
		return true
	}
	for _, ext := range []string{".js", ".mjs", ".html", ".htm"} {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}
	slash := strings.LastIndex(path, "/")
	return !strings.Contains(path[slash+1:], ".")
}

// markETag marks a rewritten response's ETag, and drops Last-Modified so Safari revalidates by the ETag.
func markETag(h http.Header) {
	if etag := h.Get("Etag"); strings.HasSuffix(etag, `"`) {
		h.Set("Etag", strings.TrimSuffix(etag, `"`)+etagMark+`"`)
	}
	h.Del("Last-Modified")
}

// namesLoopback reports whether r names this machine as 127.0.0.1, ::1 or localhost, as the app and the PC over USB
// do. A website that points its own name at 127.0.0.1 reaches the proxy too, but under that name, and so can't
// read the debug record as one of its own pages.
func namesLoopback(r *http.Request) bool {
	host := r.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return strings.EqualFold(host, "localhost") || ip != nil && ip.IsLoopback()
}

// toSelf reports whether a proxy request names the address it arrived on.
func toSelf(r *http.Request) bool {
	local, ok := r.Context().Value(http.LocalAddrContextKey).(*net.TCPAddr)
	if !ok {
		return false
	}
	host, port, err := net.SplitHostPort(r.URL.Host)
	if err != nil || port != strconv.Itoa(local.Port) {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.Equal(local.IP) || ip.IsLoopback() && local.IP.IsLoopback())
}

func isJavaScript(ctype, path string) bool {
	if strings.Contains(ctype, "javascript") || strings.Contains(ctype, "ecmascript") {
		return true
	}
	return (strings.HasSuffix(path, ".js") || strings.HasSuffix(path, ".mjs")) && !strings.Contains(ctype, "json")
}

func removeHopHeaders(h http.Header) {
	for _, name := range hopHeaders {
		h.Del(name)
	}
}

func copyHeader(dst, src http.Header) {
	for name, values := range src {
		dst[name] = append([]string(nil), values...)
	}
}

// copyFlushing streams src to w; with flush, it sends each piece as it arrives, as server-sent events need.
func copyFlushing(w http.ResponseWriter, src io.Reader, flush bool) {
	if !flush {
		io.Copy(w, src)
		return
	}
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

// pipe copies both ways until both directions end, passing each end on with a half-close.
func pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	copyHalf := func(dst, src net.Conn) {
		defer wg.Done()
		io.Copy(dst, src)
		if c, ok := dst.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
		} else {
			dst.Close()
		}
	}
	go copyHalf(a, b)
	go copyHalf(b, a)
	wg.Wait()
}

func short(path string) string {
	if len(path) > 60 {
		return path[:60] + "…"
	}
	return path
}

// prefixConn reads first what a buffered reader already took from the connection.
type prefixConn struct {
	net.Conn
	r io.Reader
}

func (c *prefixConn) Read(b []byte) (int, error) { return c.r.Read(b) }

func (c *prefixConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return c.Conn.Close()
}

// rwConn lets a WebSocket's upstream body, an io.ReadWriteCloser, take part in pipe.
type rwConn struct{ io.ReadWriteCloser }

func (rwConn) LocalAddr() net.Addr              { return nil }
func (rwConn) RemoteAddr() net.Addr             { return nil }
func (rwConn) SetDeadline(time.Time) error      { return nil }
func (rwConn) SetReadDeadline(time.Time) error  { return nil }
func (rwConn) SetWriteDeadline(time.Time) error { return nil }

// countingListener counts the connections it accepts.
type countingListener struct {
	net.Listener
	count *int64
}

func (l countingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		atomic.AddInt64(l.count, 1)
	}
	return c, err
}

// oneConnListener hands http.Server a single, already-accepted connection, and ends Serve once it closes.
type oneConnListener struct {
	mu     sync.Mutex
	conn   net.Conn
	closed chan struct{}
	once   sync.Once
}

func newOneConnListener(c net.Conn) *oneConnListener {
	return &oneConnListener{conn: c, closed: make(chan struct{})}
}

func (l *oneConnListener) Accept() (net.Conn, error) {
	l.mu.Lock()
	c := l.conn
	l.conn = nil
	l.mu.Unlock()
	if c != nil {
		return &notifyConn{Conn: c, done: l.done}, nil
	}
	<-l.closed
	return nil, io.EOF
}

func (l *oneConnListener) done()          { l.once.Do(func() { close(l.closed) }) }
func (l *oneConnListener) Close() error   { l.done(); return nil }
func (l *oneConnListener) Addr() net.Addr { return dummyAddr{} }

type notifyConn struct {
	net.Conn
	done func()
}

func (c *notifyConn) Close() error {
	c.done()
	return c.Conn.Close()
}

type dummyAddr struct{}

func (dummyAddr) Network() string { return "tcp" }
func (dummyAddr) String() string  { return "safarifix" }

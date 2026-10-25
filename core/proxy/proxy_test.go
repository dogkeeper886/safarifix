package proxy

import (
	"crypto/tls"
	"crypto/x509"
	"io/ioutil"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dogkeeper886/safarifix/core/certs"
	"github.com/dogkeeper886/safarifix/core/fix"
)

// start runs a proxy in front of website, and returns a client that uses it the way Safari does: through the
// proxy, trusting SafariFix's root.
func start(t *testing.T, website *httptest.Server) (*http.Client, *Proxy, func()) {
	dir, err := ioutil.TempDir("", "proxy")
	if err != nil {
		t.Fatal(err)
	}
	auth, err := certs.Load(filepath.Join(dir, "certs"))
	if err != nil {
		t.Fatal(err)
	}
	websiteRoots := x509.NewCertPool()
	websiteRoots.AddCert(website.Certificate())
	p := New(auth, fix.New(filepath.Join(dir, "cache")), websiteRoots, t.Logf)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go p.Serve(l)
	safariRoots := x509.NewCertPool()
	safariRoots.AddCert(auth.Root())
	proxyURL, _ := url.Parse("http://" + l.Addr().String())
	client := &http.Client{Transport: &http.Transport{
		Proxy:           http.ProxyURL(proxyURL),
		TLSClientConfig: &tls.Config{RootCAs: safariRoots, MaxVersion: tls.VersionTLS12},
	}}
	return client, p, func() { l.Close(); os.RemoveAll(dir) }
}

func website() *httptest.Server {
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("Content-Security-Policy", "script-src 'self'")
			w.Write([]byte(`<html><head><script>var x = a?.b;</script></head></html>`))
		case "/app.js":
			w.Header().Set("Content-Type", "application/javascript")
			w.Header().Set("Etag", `"v1"`)
			if r.Header.Get("If-None-Match") == `"v1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Write([]byte(`const o = {...p};`))
		}
	}))
}

func get(t *testing.T, client *http.Client, u string, header http.Header) (*http.Response, string) {
	req, _ := http.NewRequest("GET", u, nil)
	for k, v := range header {
		req.Header[k] = v
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := ioutil.ReadAll(resp.Body)
	return resp, string(body)
}

func TestFixesAPageThroughTheProxy(t *testing.T) {
	site := website()
	defer site.Close()
	client, p, done := start(t, site)
	defer done()

	resp, body := get(t, client, site.URL+"/", nil)
	if !strings.HasPrefix(body, `<html><head><script src="`+fix.PolyfillPath+`">`) || strings.Contains(body, "?.") {
		t.Errorf("page not fixed: %s", body)
	}
	if resp.Header.Get("Content-Security-Policy") != "" {
		t.Error("the CSP header would block the rewritten scripts")
	}
	if _, polyfills := get(t, client, site.URL+fix.PolyfillPath, nil); !strings.Contains(polyfills, "AbortController") {
		t.Error("the polyfills aren't served on the site's own host")
	}
	if s := p.Stats(); s.Decrypted == 0 || s.Failures != 0 {
		t.Errorf("stats: %+v", s)
	}
}

func TestRevalidatesOnlyFixedCopies(t *testing.T) {
	site := website()
	defer site.Close()
	client, _, done := start(t, site)
	defer done()

	// An unfixed copy Safari cached before SafariFix ran: the condition goes, and the script comes back fixed.
	resp, body := get(t, client, site.URL+"/app.js", http.Header{"If-None-Match": {`"v1"`}})
	if resp.StatusCode != http.StatusOK || strings.Contains(body, "...") {
		t.Fatalf("unfixed copy kept: %d %s", resp.StatusCode, body)
	}
	etag := resp.Header.Get("Etag")
	if etag != `"v1`+etagMark+`"` {
		t.Fatalf("ETag not marked: %s", etag)
	}
	// SafariFix's own copy: the website answers 304, and the mark stays.
	resp, _ = get(t, client, site.URL+"/app.js", http.Header{"If-None-Match": {etag}})
	if resp.StatusCode != http.StatusNotModified || resp.Header.Get("Etag") != etag {
		t.Errorf("fixed copy not revalidated: %d %s", resp.StatusCode, resp.Header.Get("Etag"))
	}
}

func TestServesThePACFileAndTheRoot(t *testing.T) {
	site := website()
	defer site.Close()
	_, p, done := start(t, site)
	defer done()
	srv := httptest.NewServer(p)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/proxy.pac")
	if err != nil {
		t.Fatal(err)
	}
	pac, _ := ioutil.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(pac), `"PROXY `+strings.TrimPrefix(srv.URL, "http://")+`; DIRECT"`) {
		t.Errorf("PAC file: %s", pac)
	}
	resp, err = http.Get(srv.URL + "/safarifix.crt")
	if err != nil {
		t.Fatal(err)
	}
	der, _ := ioutil.ReadAll(resp.Body)
	resp.Body.Close()
	if _, err := x509.ParseCertificate(der); err != nil {
		t.Errorf("root certificate: %v", err)
	}
}

func TestServesItsOwnPagesThroughItself(t *testing.T) {
	site := website()
	defer site.Close()
	client, p, done := start(t, site)
	defer done()
	self := client.Transport.(*http.Transport).Proxy
	proxyURL, _ := self(&http.Request{URL: &url.URL{}})
	_, pac := get(t, client, proxyURL.String()+"/proxy.pac", nil)
	if !strings.Contains(pac, "FindProxyForURL") {
		t.Errorf("the proxy's own PAC file, asked through the proxy: %s", pac)
	}
	if s := p.Stats(); s.Requests != 0 {
		t.Errorf("the request went out as if to a website: %+v", s)
	}
}

func TestTheSetupPageShowsOnlyTheSetup(t *testing.T) {
	site := website()
	defer site.Close()
	_, p, done := start(t, site)
	defer done()
	srv := httptest.NewServer(p)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	page, _ := ioutil.ReadAll(resp.Body)
	resp.Body.Close()
	for _, want := range []string{`href="/safarifix.crt"`, p.auth.Root().Subject.CommonName, "Certificate Trust Settings"} {
		if !strings.Contains(string(page), want) {
			t.Errorf("the setup page lacks %q: %s", want, page)
		}
	}
	if strings.Contains(string(page), "connections") {
		t.Errorf("the setup page shows the counts: %s", page)
	}
}

func TestServesDebugFilesOnlyWhenAsked(t *testing.T) {
	site := website()
	defer site.Close()
	_, p, done := start(t, site)
	defer done()
	srv := httptest.NewServer(p)
	defer srv.Close()

	if resp, err := http.Get(srv.URL + "/debug/screen.png"); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Errorf("debug path without Debug: %v %v", resp, err)
	}
	p.Debug = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("got " + r.URL.Path)) })
	_, body := get(t, http.DefaultClient, srv.URL+"/debug/screen.png", nil)
	if body != "got /screen.png" {
		t.Errorf("debug path with Debug: %q", body)
	}
	// A website whose name points at 127.0.0.1, asking under its own name.
	req, _ := http.NewRequest("GET", srv.URL+"/debug/log.txt", nil)
	req.Host = "rebound.example:8118"
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Errorf("debug path under a website's name: %v %v", resp, err)
	}
}

func TestCountsSafariRefusingTheCertificate(t *testing.T) {
	site := website()
	defer site.Close()
	client, p, done := start(t, site)
	defer done()
	// Safari before the root is trusted: the system roots don't include SafariFix's.
	client.Transport.(*http.Transport).TLSClientConfig.RootCAs = x509.NewCertPool()
	if _, err := client.Get(site.URL + "/"); err == nil {
		t.Fatal("a client without the root reached the site")
	}
	// The proxy reads the client's alert after the client has given up.
	for i := 0; i < 100 && p.Stats().Rejected == 0; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	if s := p.Stats(); s.Rejected != 1 {
		t.Errorf("rejected: %+v", s)
	}
}

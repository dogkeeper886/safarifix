// Package fix rewrites pages for Safari 10.1: scripts to the syntax iOS 10.3 reads, and polyfills for the web
// APIs it lacks.
package fix

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io/ioutil"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"sync/atomic"
	"time"

	"github.com/evanw/esbuild/pkg/api"
)

// PolyfillPath is where pages on a fixed host load the polyfills from; the proxy serves it on every such host,
// so it's same-origin and the browser caches it per site.
const PolyfillPath = "/__safarifix/polyfills.js"

var (
	inlineScript = regexp.MustCompile(`(?is)<script\b([^>]*)>(.*?)</script>`)
	scriptType   = regexp.MustCompile(`(?i)\btype\s*=\s*["']?([^"'\s>]+)`)
	hasSrc       = regexp.MustCompile(`(?i)\bsrc\s*=`)
	scriptOrLink = regexp.MustCompile(`(?i)<(?:script|link)\b[^>]*>`)
	integrity    = regexp.MustCompile(`(?i)\s(?:integrity|nonce)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)`)
	metaCSP      = regexp.MustCompile(`(?i)<meta[^>]+http-equiv\s*=\s*["']?content-security-policy[^>]*>`)
	headTag      = regexp.MustCompile(`(?i)<head\b[^>]*>`)
	scriptNonce  = regexp.MustCompile(`(?i)<script\b[^>]*\bnonce\s*=\s*["']?([^"'\s>]+)`)
)

// Fixer rewrites scripts with esbuild, caching each result on disk by the script's hash.
type Fixer struct {
	cacheDir string
	// esbuild runs at most this many at once; the iPhone 5 has two cores.
	limit chan struct{}
	// Log, when set, gets one line per rewrite.
	Log func(format string, args ...interface{})

	rewritten, failed, cached int64
}

// New returns a Fixer that caches in cacheDir.
func New(cacheDir string) *Fixer {
	return &Fixer{cacheDir: cacheDir, limit: make(chan struct{}, 2)}
}

// Stats returns how many scripts were rewritten, came from the cache, or failed to rewrite.
func (f *Fixer) Stats() (rewritten, cached, failed int64) {
	return atomic.LoadInt64(&f.rewritten), atomic.LoadInt64(&f.cached), atomic.LoadInt64(&f.failed)
}

// Script returns code in the syntax Safari 10.1 reads, or code unchanged when esbuild can't lower it.
func (f *Fixer) Script(code []byte, what string) []byte {
	sum := sha256.Sum256(code)
	key := hex.EncodeToString(sum[:])
	path := filepath.Join(f.cacheDir, key[:2], key+".js")
	if out, err := ioutil.ReadFile(path); err == nil {
		atomic.AddInt64(&f.cached, 1)
		return out
	}
	f.limit <- struct{}{}
	start := time.Now()
	result := api.Transform(string(code), api.TransformOptions{
		Loader:  api.LoaderJS,
		Engines: []api.Engine{{Name: api.EngineIOS, Version: "10.3"}},
		// esbuild can't lower let, const or the destructuring inside them for iOS 10, and refuses the target
		// for them; Safari 10.1 runs all three, so keep them as they are.
		Supported:        map[string]bool{"const-and-let": true, "destructuring": true},
		MinifyWhitespace: true,
		Charset:          api.CharsetUTF8,
		LogLevel:         api.LogLevelSilent,
	})
	<-f.limit
	if len(result.Errors) > 0 {
		atomic.AddInt64(&f.failed, 1)
		f.logf("esbuild FAILED %s (%d B): %s", what, len(code), result.Errors[0].Text)
		return code
	}
	atomic.AddInt64(&f.rewritten, 1)
	f.logf("esbuild %s: %d -> %d B in %d ms", what, len(code), len(result.Code), time.Since(start).Milliseconds())
	if err := os.MkdirAll(filepath.Dir(path), 0700); err == nil {
		ioutil.WriteFile(path, result.Code, 0600)
	}
	return result.Code
}

// Page rewrites an HTML page from a fixed host: its inline scripts, the integrity hashes and CSP meta tags the
// rewritten scripts would fail, and a script tag for the polyfills at the top. The caller drops the CSP headers.
func (f *Fixer) Page(html []byte, what string) []byte {
	html = metaCSP.ReplaceAll(html, nil)
	matches := inlineScript.FindAllSubmatchIndex(html, -1)
	bodies := make([][]byte, len(matches))
	var wg sync.WaitGroup
	for i, m := range matches {
		attrs, body := html[m[2]:m[3]], html[m[4]:m[5]]
		if !isJavaScript(attrs) || len(bytes.TrimSpace(body)) == 0 {
			continue
		}
		wg.Add(1)
		go func(i int, body []byte) {
			defer wg.Done()
			bodies[i] = f.Script(body, "inline script on "+what)
		}(i, body)
	}
	wg.Wait()
	var out bytes.Buffer
	last := 0
	for i, m := range matches {
		if bodies[i] == nil {
			continue
		}
		out.Write(html[last:m[4]])
		out.Write(bodies[i])
		last = m[5]
	}
	out.Write(html[last:])
	html = scriptOrLink.ReplaceAllFunc(out.Bytes(), func(tag []byte) []byte { return integrity.ReplaceAll(tag, nil) })
	return insertAtHead(html, []byte(`<script src="`+PolyfillPath+`"></script>`))
}

// SignInPage adds the AbortController polyfill to one of Google's sign-in pages, under the nonce of the page's
// own scripts, so its Content-Security-Policy stays as it is. The page's scripts need no rewriting.
func SignInPage(html []byte) []byte {
	tag := []byte("<script>")
	if m := scriptNonce.FindSubmatch(html); m != nil {
		tag = []byte(`<script nonce="` + string(m[1]) + `">`)
	}
	script := append(append(tag, abortController...), "</script>"...)
	return insertAtHead(html, script)
}

// Polyfills returns the polyfills served at PolyfillPath: core-js, IntersectionObserver, ResizeObserver,
// the performance stand-ins and AbortController.
func Polyfills() []byte { return allPolyfills }

var allPolyfills = bytes.Join([][]byte{[]byte(vendorPolyfills), []byte(performance), []byte(abortController)}, []byte("\n;\n"))

func isJavaScript(attrs []byte) bool {
	if hasSrc.Match(attrs) {
		return false
	}
	m := scriptType.FindSubmatch(attrs)
	if m == nil {
		return true
	}
	switch string(bytes.ToLower(m[1])) {
	case "module", "text/javascript", "application/javascript":
		return true
	}
	return false
}

func insertAtHead(html, tag []byte) []byte {
	loc := headTag.FindIndex(html)
	at := 0
	if loc != nil {
		at = loc[1]
	}
	out := make([]byte, 0, len(html)+len(tag))
	out = append(out, html[:at]...)
	out = append(out, tag...)
	return append(out, html[at:]...)
}

func (f *Fixer) logf(format string, args ...interface{}) {
	if f.Log != nil {
		f.Log(format, args...)
	}
}

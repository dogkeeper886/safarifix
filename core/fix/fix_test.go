package fix

import (
	"bytes"
	"io/ioutil"
	"os"
	"strings"
	"testing"
)

func newFixer(t *testing.T) (*Fixer, func()) {
	dir, err := ioutil.TempDir("", "fix")
	if err != nil {
		t.Fatal(err)
	}
	return New(dir), func() { os.RemoveAll(dir) }
}

func TestScriptLowersNewSyntax(t *testing.T) {
	f, done := newFixer(t)
	defer done()
	out := string(f.Script([]byte("const a = {...b, c: d?.e ?? 1}; try { f() } catch { }"), "test"))
	for _, newSyntax := range []string{"...", "?.", "??", "catch {"} {
		if strings.Contains(out, newSyntax) {
			t.Errorf("%q still in %s", newSyntax, out)
		}
	}
	if !strings.Contains(out, "const a") {
		t.Errorf("const should stay, since Safari 10.1 runs it: %s", out)
	}
	if _, cached, _ := f.Stats(); cached != 0 {
		t.Errorf("first rewrite came from the cache")
	}
	f.Script([]byte("const a = {...b, c: d?.e ?? 1}; try { f() } catch { }"), "test")
	if _, cached, _ := f.Stats(); cached != 1 {
		t.Errorf("second rewrite didn't come from the cache")
	}
}

func TestScriptKeepsWhatEsbuildCantLower(t *testing.T) {
	f, done := newFixer(t)
	defer done()
	code := []byte("for (;;);{\"json\": 1}")
	if out := f.Script(code, "test"); !bytes.Equal(out, code) {
		t.Errorf("unparseable code changed: %s", out)
	}
}

func TestPage(t *testing.T) {
	f, done := newFixer(t)
	defer done()
	html := `<html><head><meta http-equiv="Content-Security-Policy" content="script-src 'self'">` +
		`<script src="/app.js" integrity="sha384-abc" nonce="n1"></script>` +
		`<script>var x = a?.b;</script><script type="application/ld+json">{"a": 1}</script></head><body></body></html>`
	out := string(f.Page([]byte(html), "test"))
	if !strings.HasPrefix(out, `<html><head><script src="`+PolyfillPath+`"></script>`) {
		t.Errorf("polyfills not first in the head: %s", out)
	}
	for _, gone := range []string{"Content-Security-Policy", "integrity=", "nonce=", "a?.b"} {
		if strings.Contains(out, gone) {
			t.Errorf("%q still in %s", gone, out)
		}
	}
	if !strings.Contains(out, `{"a": 1}`) {
		t.Errorf("a JSON script changed: %s", out)
	}
}

func TestSignInPageUsesThePageNonce(t *testing.T) {
	html := `<html><head><script nonce="abc123">init()</script></head></html>`
	out := string(SignInPage([]byte(html)))
	if !strings.HasPrefix(out, `<html><head><script nonce="abc123">(function () {`+"\n  if (window.AbortController)") {
		t.Errorf("AbortController not added under the page's nonce: %.120s", out)
	}
}

func TestPolyfillsIncludeEveryPart(t *testing.T) {
	all := string(Polyfills())
	for _, part := range []string{"core-js", "IntersectionObserver", "ResizeObserver", "PerformanceObserver", "AbortController"} {
		if !strings.Contains(all, part) {
			t.Errorf("polyfills lack %s", part)
		}
	}
}

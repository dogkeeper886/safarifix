// Command ios is the SafariFix core as a C library for the iPhone app, built with
//   go build -buildmode=c-archive ./ios
// for darwin/arm by ios/build.sh. The app calls SFStart once; SFRootName and SFTestChain for its checks on the main
// screen; and SFStatus and SFRecentLog for its heartbeat and its Details screen.
package main

/*
#include <stdlib.h>

void sf_syslog(const char *line); // in syslog.c
*/
import "C"

import (
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/dogkeeper886/safarifix/core/certs"
	"github.com/dogkeeper886/safarifix/core/fix"
	"github.com/dogkeeper886/safarifix/core/proxy"
)

var (
	mu    sync.Mutex
	p     *proxy.Proxy
	fixer *fix.Fixer
	auth  *certs.Authority
)

// recentLines is how many of the core's last log lines the Details screen shows.
const recentLines = 100

var (
	recentMu sync.Mutex
	recent   []string
	// zone is the time zone of recent's times: the phone's once the app sets it, since Go reads UTC on iOS.
	zone = time.UTC
)

// syslogWriter hands each log line to syslog, and keeps the last ones for the Details screen.
type syslogWriter struct{}

func (syslogWriter) Write(b []byte) (int, error) {
	line := C.CString("SafariFix core: " + string(b))
	C.sf_syslog(line)
	C.free(unsafe.Pointer(line))
	recentMu.Lock()
	recent = append(recent, time.Now().In(zone).Format("15:04:05 ")+strings.TrimSuffix(string(b), "\n"))
	if len(recent) > recentLines {
		recent = recent[len(recent)-recentLines:]
	}
	recentMu.Unlock()
	return len(b), nil
}

// SFSetTimeZone sets the time zone of SFRecentLog's times to the phone's, offset seconds east of UTC, which the app
// reads; Go on iOS reads only UTC.
//export SFSetTimeZone
func SFSetTimeZone(offset C.int) {
	recentMu.Lock()
	zone = time.FixedZone("", int(offset))
	recentMu.Unlock()
}

// SFStart starts the proxy on 127.0.0.1:port, keeping the root certificate in dataDir and the rewritten scripts
// in cacheDir. A debug build passes debugDir, whose files the proxy serves under /debug/; others pass "". It
// returns NULL once the proxy listens, or an error message for the caller to free. The first start makes the
// root's RSA key, which takes a while on the iPhone 5, so call it off the main thread. A second call does nothing.
//export SFStart
func SFStart(dataDir, cacheDir, debugDir *C.char, port C.int) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if p != nil {
		return nil
	}
	log.SetFlags(0)
	log.SetOutput(syslogWriter{})
	a, err := certs.Load(C.GoString(dataDir))
	if err != nil {
		return C.CString("root certificate: " + err.Error())
	}
	f := fix.New(C.GoString(cacheDir))
	f.Log = log.Printf
	// Loopback only: no other device on the WiFi can use the proxy.
	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", int(port)))
	if err != nil {
		return C.CString(err.Error())
	}
	auth, fixer, p = a, f, proxy.New(a, f, nil, log.Printf)
	if dir := C.GoString(debugDir); dir != "" {
		p.Debug = http.FileServer(http.Dir(dir))
	}
	go func() { log.Printf("stopped: %v", p.Serve(l)) }()
	log.Printf("listening on %s; root certificate %q", l.Addr(), a.Root().Subject.CommonName)
	return nil
}

// SFStatus returns one line about the proxy, for the screen and the heartbeat; the caller frees it.
//export SFStatus
func SFStatus() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if p == nil {
		return C.CString("not started")
	}
	s := p.Stats()
	rewritten, cached, failed := fixer.Stats()
	return C.CString(fmt.Sprintf("%d connections: %d tunnelled, %d decrypted, %d certificates rejected; %d requests, %d failed; scripts %d rewritten, %d cached, %d left",
		s.Connections, s.Tunnels, s.Decrypted, s.Rejected, s.Requests, s.Failures, rewritten, cached, failed))
}

// SFRecentLog returns the core's last log lines, oldest first, one per line; the caller frees it.
//export SFRecentLog
func SFRecentLog() *C.char {
	recentMu.Lock()
	defer recentMu.Unlock()
	return C.CString(strings.Join(recent, "\n"))
}

// SFTestChain returns a site's name, then its certificate the way Safari gets one and the root, in base64, each on
// its own line, or an empty string before SFStart; the caller frees it. The app checks that iOS trusts the
// certificate for the site, as Safari would.
//export SFTestChain
func SFTestChain() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if auth == nil {
		return C.CString("")
	}
	site, err := auth.For(testHost)
	if err != nil {
		return C.CString("")
	}
	return C.CString(testHost + "\n" + base64.StdEncoding.EncodeToString(site.Certificate[0]) + "\n" +
		base64.StdEncoding.EncodeToString(auth.RootDER()))
}

// testHost names SFTestChain's site; .invalid names no real site.
const testHost = "check.safarifix.invalid"

// SFRootName returns the root certificate's name as Certificate Trust Settings shows it, or an empty string before
// SFStart; the caller frees it.
//export SFRootName
func SFRootName() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if auth == nil {
		return C.CString("")
	}
	return C.CString(auth.Root().Subject.CommonName)
}

func main() {}

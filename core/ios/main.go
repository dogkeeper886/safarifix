// Command ios is the SafariFix core as a C library for the iPhone app, built with
//   go build -buildmode=c-archive ./ios
// for darwin/arm by ios/build.sh. The app calls SFStart once, then SFStatus for its screen and heartbeat.
package main

/*
#include <stdlib.h>

void sf_syslog(const char *line); // in syslog.c
*/
import "C"

import (
	"fmt"
	"log"
	"net"
	"sync"
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

// syslogWriter hands each log line to syslog.
type syslogWriter struct{}

func (syslogWriter) Write(b []byte) (int, error) {
	line := C.CString("SafariFix core: " + string(b))
	C.sf_syslog(line)
	C.free(unsafe.Pointer(line))
	return len(b), nil
}

// SFStart starts the proxy on 127.0.0.1:port, keeping the root certificate in dataDir and the rewritten scripts
// in cacheDir. It returns NULL once the proxy listens, or an error message for the caller to free. The first start
// makes the root's RSA key, which takes a while on the iPhone 5, so call it off the main thread. A second call
// does nothing.
//export SFStart
func SFStart(dataDir, cacheDir *C.char, port C.int) *C.char {
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
	return C.CString(fmt.Sprintf("%d connections: %d tunnelled, %d decrypted; %d requests, %d failed; scripts %d rewritten, %d cached, %d left",
		s.Connections, s.Tunnels, s.Decrypted, s.Requests, s.Failures, rewritten, cached, failed))
}

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

// Command safarifix-pc runs SafariFix's proxy on the PC, to test the core with the iPhone before it runs in the
// app: set the iPhone's Settings → Wi-Fi → HTTP Proxy → Manual to this PC and port, open http://<PC>:<port>/ in
// Safari, and install the root certificate from there.
package main

import (
	"flag"
	"log"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/dogkeeper886/safarifix/core/certs"
	"github.com/dogkeeper886/safarifix/core/fix"
	"github.com/dogkeeper886/safarifix/core/proxy"
)

func main() {
	home, _ := os.UserHomeDir()
	listen := flag.String("listen", "0.0.0.0:8118", "address to listen on; the iPhone must reach it over the WiFi")
	data := flag.String("data", filepath.Join(home, ".local/share/safarifix/pc"), "folder for the root certificate and the script cache")
	quiet := flag.Bool("quiet", false, "log failures and the 30-second summary only, not each rewrite")
	flag.Parse()

	auth, err := certs.Load(filepath.Join(*data, "certs"))
	if err != nil {
		log.Fatal(err)
	}
	fixer := fix.New(filepath.Join(*data, "cache"))
	if !*quiet {
		fixer.Log = log.Printf
	}
	p := proxy.New(auth, fixer, nil, log.Printf)
	l, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("SafariFix on %s; root certificate %q", l.Addr(), auth.Root().Subject.CommonName)
	go func() {
		for range time.Tick(30 * time.Second) {
			s := p.Stats()
			rewritten, cached, failed := fixer.Stats()
			log.Printf("%d connections: %d tunnelled, %d decrypted; %d requests, %d failed; scripts %d rewritten, %d cached, %d left",
				s.Connections, s.Tunnels, s.Decrypted, s.Requests, s.Failures, rewritten, cached, failed)
		}
	}()
	log.Fatal(p.Serve(l))
}

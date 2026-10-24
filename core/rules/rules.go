// Package rules decides what SafariFix does with each host Safari connects to.
package rules

import (
	"net"
	"strings"
)

// Mode says how the proxy treats a host.
type Mode int

const (
	// Fix decrypts the host's traffic, rewrites its scripts for Safari 10.1 and adds the polyfills.
	Fix Mode = iota
	// Pass tunnels the host untouched.
	Pass
	// SignIn decrypts Google's sign-in pages only to add AbortController, which their script needs.
	SignIn
)

func (m Mode) String() string {
	return [...]string{"fix", "pass", "sign-in"}[m]
}

// passDomains work in Safari 10.1 as they are (Google search, YouTube), or serve the phone's own services,
// which accept no certificate but the real one: trusting a developer fails with "needs internet" otherwise.
var passDomains = []string{
	"google.com", "google.com.tw", "youtube.com", "youtube-nocookie.com", "googlevideo.com", "gstatic.com",
	"ytimg.com", "ggpht.com", "googleapis.com", "googleusercontent.com", "googlesyndication.com", "doubleclick.net",
	"apple.com", "icloud.com", "mzstatic.com", "cdn-apple.com", "apple-cloudkit.com",
}

// signInHosts serve Google's sign-in pages.
var signInHosts = map[string]bool{"accounts.google.com": true}

// ModeFor returns the mode for host, which may carry a port.
func ModeFor(host string) Mode {
	host = strings.ToLower(Hostname(host))
	if signInHosts[host] {
		return SignIn
	}
	for _, d := range passDomains {
		if host == d || strings.HasSuffix(host, "."+d) {
			return Pass
		}
	}
	return Fix
}

// Hostname returns host without its port or IPv6 brackets.
func Hostname(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		return h
	}
	return strings.Trim(host, "[]")
}

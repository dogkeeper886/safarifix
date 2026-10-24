package rules

import "testing"

func TestModeFor(t *testing.T) {
	for host, want := range map[string]Mode{
		"www.google.com:443":          Pass,
		"m.youtube.com":               Pass,
		"rr2---sn-x.googlevideo.com":  Pass,
		"ppq.apple.com:443":           Pass,
		"accounts.google.com:443":     SignIn,
		"ACCOUNTS.GOOGLE.COM":         SignIn,
		"www.bbc.com:443":             Fix,
		"notgoogle.com":               Fix,
		"google.com.evil.example:443": Fix,
		"[::1]:8443":                  Fix,
	} {
		if got := ModeFor(host); got != want {
			t.Errorf("ModeFor(%q) = %v, want %v", host, got, want)
		}
	}
}

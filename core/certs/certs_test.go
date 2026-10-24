package certs

import (
	"crypto/x509"
	"io/ioutil"
	"os"
	"testing"
)

func TestSiteCertificateVerifiesAgainstRoot(t *testing.T) {
	dir, err := ioutil.TempDir("", "certs")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	a, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(a.Root())
	for _, host := range []string{"www.bbc.com", "127.0.0.1"} {
		cert, err := a.For(host)
		if err != nil {
			t.Fatal(err)
		}
		leaf, err := x509.ParseCertificate(cert.Certificate[0])
		if err != nil {
			t.Fatal(err)
		}
		if _, err := leaf.Verify(x509.VerifyOptions{DNSName: host, Roots: roots}); err != nil {
			t.Errorf("%s: %v", host, err)
		}
	}
}

func TestLoadKeepsTheRoot(t *testing.T) {
	dir, err := ioutil.TempDir("", "certs")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	first, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if string(first.RootDER()) != string(second.RootDER()) {
		t.Error("a second Load made a new root; the phone would stop trusting the proxy")
	}
}

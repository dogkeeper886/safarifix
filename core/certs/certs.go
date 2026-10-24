// Package certs makes SafariFix's root certificate, which the user installs and trusts on the phone,
// and the per-site certificates it signs for Safari.
package certs

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"io/ioutil"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Authority signs a certificate for each site Safari visits.
type Authority struct {
	root    *x509.Certificate
	rootDER []byte
	rootKey crypto.Signer
	// One key serves every site certificate. ECDSA, since an RSA key takes seconds to make on the iPhone 5;
	// iOS 10 accepts ECDSA site certificates.
	siteKey *ecdsa.PrivateKey

	mu    sync.Mutex
	sites map[string]*tls.Certificate
}

// Load reads the root certificate and key from dir, or makes and saves them there.
func Load(dir string) (*Authority, error) {
	certPath, keyPath := filepath.Join(dir, "root.pem"), filepath.Join(dir, "root-key.pem")
	der, key, err := read(certPath, keyPath)
	if os.IsNotExist(err) {
		der, key, err = makeRoot()
		if err == nil {
			err = save(dir, certPath, keyPath, der, key)
		}
	}
	if err != nil {
		return nil, err
	}
	root, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	siteKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Authority{root: root, rootDER: der, rootKey: key, siteKey: siteKey, sites: map[string]*tls.Certificate{}}, nil
}

// RootDER returns the root certificate, for the phone to install.
func (a *Authority) RootDER() []byte { return a.rootDER }

// Root returns the root certificate.
func (a *Authority) Root() *x509.Certificate { return a.root }

// For returns the certificate for host, a name or an IP address, signing it on first use.
func (a *Authority) For(host string) (*tls.Certificate, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if cert := a.sites[host]; cert != nil {
		return cert, nil
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    now.Add(-24 * time.Hour),
		NotAfter:     now.Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if ip := net.ParseIP(host); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, a.root, &a.siteKey.PublicKey, a.rootKey)
	if err != nil {
		return nil, err
	}
	cert := &tls.Certificate{Certificate: [][]byte{der}, PrivateKey: a.siteKey}
	a.sites[host] = cert
	return cert, nil
}

// makeRoot makes a root with the layout of mitmproxy's, which iOS 10 trusts: an RSA key, no path length, and server
// authentication. iOS 10 refused Go's first roots even with their switches on in Certificate Trust Settings
// (2026-10-25), likely a decision the phone had cached rather than the layout, but this one is the known-good
// layout. Making the RSA key takes a while on the iPhone 5, once.
func makeRoot() ([]byte, crypto.Signer, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}
	publicKey, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return nil, nil, err
	}
	keyID := sha1.Sum(publicKey)
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial(),
		// The suffix tells one install's root from another's in Certificate Trust Settings.
		Subject:               pkix.Name{CommonName: "SafariFix root " + hex.EncodeToString(keyID[:3]), Organization: []string{"SafariFix"}},
		NotBefore:             now.Add(-24 * time.Hour),
		NotAfter:              now.Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            -1,
		// Go 1.14 doesn't add the key ID itself; site certificates copy it as their authority key ID.
		SubjectKeyId: keyID[:],
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	return der, key, err
}

func read(certPath, keyPath string) ([]byte, crypto.Signer, error) {
	certPEM, err := ioutil.ReadFile(certPath)
	if err != nil {
		return nil, nil, err
	}
	keyPEM, err := ioutil.ReadFile(keyPath)
	if err != nil {
		return nil, nil, err
	}
	certBlock, keyBlock := firstBlock(certPEM), firstBlock(keyPEM)
	if certBlock == nil || keyBlock == nil {
		return nil, nil, errors.New("certs: unreadable root certificate or key")
	}
	key, err := x509.ParsePKCS8PrivateKey(keyBlock)
	if err != nil {
		return nil, nil, err
	}
	signer, ok := key.(crypto.Signer)
	if !ok {
		return nil, nil, errors.New("certs: the root key can't sign")
	}
	return certBlock, signer, nil
}

func save(dir, certPath, keyPath string, der []byte, key crypto.Signer) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	if err := ioutil.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0600); err != nil {
		return err
	}
	return ioutil.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0644)
}

func firstBlock(data []byte) []byte {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil
	}
	return block.Bytes
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	return n
}

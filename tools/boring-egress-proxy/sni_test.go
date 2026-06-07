package main

import (
	"crypto/tls"
	"net"
	"testing"
	"time"
)

// realClientHello produces a genuine TLS ClientHello record for serverName by
// driving crypto/tls over an in-memory pipe and capturing the first flight.
// This beats hand-encoding bytes: it stays correct as the TLS stack evolves.
func realClientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	got := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 8192)
		_ = c2.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _ := c2.Read(buf)
		got <- append([]byte(nil), buf[:n]...)
	}()

	tlsConn := tls.Client(c1, &tls.Config{ServerName: serverName, InsecureSkipVerify: true})
	go func() { _ = tlsConn.Handshake() }() // blocks; we only want the ClientHello it writes

	select {
	case b := <-got:
		if len(b) == 0 {
			t.Fatal("captured empty ClientHello")
		}
		return b
	case <-time.After(2 * time.Second):
		t.Fatal("timed out capturing ClientHello")
		return nil
	}
}

func TestExtractSNI_RealClientHello(t *testing.T) {
	for _, name := range []string{
		"bigquery.googleapis.com",
		"shop.myshopify.com",
		"a.b.c.example.com",
	} {
		hello := realClientHello(t, name)
		host, _, err := extractSNI(hello)
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", name, err)
		}
		if host != name {
			t.Fatalf("got SNI %q, want %q", host, name)
		}
	}
}

func TestExtractSNI_Truncated(t *testing.T) {
	hello := realClientHello(t, "bigquery.googleapis.com")
	// Feeding only a prefix must ask for more data, not misparse or panic.
	if _, _, err := extractSNI(hello[:5]); err != errNeedMoreData {
		t.Fatalf("got %v, want errNeedMoreData", err)
	}
	if _, _, err := extractSNI(hello[:len(hello)/2]); err != errNeedMoreData {
		t.Fatalf("half buffer: got %v, want errNeedMoreData", err)
	}
}

func TestExtractSNI_NotClientHello(t *testing.T) {
	// A plain-HTTP request is not a TLS handshake record.
	if _, _, err := extractSNI([]byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n")); err != errNotClientHello {
		t.Fatalf("got %v, want errNotClientHello", err)
	}
}

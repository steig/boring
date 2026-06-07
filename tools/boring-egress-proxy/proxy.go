package main

import (
	"errors"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// peekCap bounds how many bytes we buffer looking for the ClientHello before
// giving up. A ClientHello is normally < 1 KiB; 16 KiB is the max TLS record.
const peekCap = 16 * 1024

// errNotTCP is returned when transparent mode is asked to read SO_ORIGINAL_DST
// from a non-TCP connection.
var errNotTCP = errors.New("boring-egress: connection is not TCP")

// Server is the SNI-filtering egress proxy.
type Server struct {
	Allow        *Allowlist
	Upstream     string // "original" (transparent, SO_ORIGINAL_DST) or "sni"
	UpstreamPort string // used in "sni" mode, e.g. "443"
	DialTimeout  time.Duration
}

func (s *Server) logf(format string, args ...any) { log.Printf(format, args...) }

// Serve accepts connections on ln until it errors.
func (s *Server) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go s.handle(c)
	}
}

func (s *Server) handle(c net.Conn) {
	defer c.Close()

	buf, sni, err := peekSNI(c)
	if err != nil {
		s.logf("drop: %v", err)
		return
	}
	if sni == "" {
		s.logf("DENY <no-sni>")
		return
	}
	if !s.Allow.Allowed(sni) {
		s.logf("DENY %s", sni)
		return
	}

	target, err := s.upstreamAddr(c, sni)
	if err != nil {
		s.logf("drop %s: %v", sni, err)
		return
	}

	up, err := net.DialTimeout("tcp", target, s.DialTimeout)
	if err != nil {
		s.logf("drop %s -> %s: %v", sni, target, err)
		return
	}
	defer up.Close()
	s.logf("ALLOW %s -> %s", sni, target)

	// Replay the buffered ClientHello, then splice the rest of the streams.
	if _, err := up.Write(buf); err != nil {
		return
	}
	splice(c, up)
}

// upstreamAddr resolves where to forward. In transparent mode it reads the
// pre-DNAT destination via SO_ORIGINAL_DST (Linux); in "sni" mode (for
// non-transparent local prototyping) it dials the requested host directly.
func (s *Server) upstreamAddr(c net.Conn, sni string) (string, error) {
	if s.Upstream == "sni" {
		port := s.UpstreamPort
		if port == "" {
			port = "443"
		}
		return net.JoinHostPort(sni, port), nil
	}
	tcp, ok := c.(*net.TCPConn)
	if !ok {
		return "", errNotTCP
	}
	return originalDst(tcp)
}

// peekSNI reads from c until a full ClientHello is buffered, returning the
// buffered bytes (to be replayed upstream) and the parsed SNI.
func peekSNI(c net.Conn) (buf []byte, sni string, err error) {
	tmp := make([]byte, 4096)
	for len(buf) < peekCap {
		_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
		n, rerr := c.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			host, _, perr := extractSNI(buf)
			if perr == nil {
				_ = c.SetReadDeadline(time.Time{})
				return buf, host, nil
			}
			if perr != errNeedMoreData {
				return buf, "", perr
			}
		}
		if rerr != nil {
			if rerr == io.EOF {
				return buf, "", errNeedMoreData
			}
			return buf, "", rerr
		}
	}
	return buf, "", errNeedMoreData
}

// splice copies bidirectionally until both directions close.
func splice(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if c, ok := dst.(*net.TCPConn); ok {
			_ = c.CloseWrite() // half-close so the peer sees EOF
		}
	}
	go cp(a, b)
	go cp(b, a)
	wg.Wait()
}

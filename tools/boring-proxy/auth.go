// auth.go — per-user token: generate (256 bits crypto/rand), persist 0600,
// validate via cookie. Bootstrap via /auth?t=<token> sets the cookie.
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"

	"github.com/fsnotify/fsnotify"
)

const (
	cookieName = "boring_token"
	tokenBytes = 32 // 256 bits
)

// TokenStore holds the active token in an atomic.Value and watches the on-disk
// file via fsnotify so `rotate-token` invalidates live sessions without a
// proxy restart. Per security review (critical-1). It also re-reads from disk
// on validate-time mismatch as a belt-and-suspenders fallback for filesystems
// where fsnotify is unreliable.
type TokenStore struct {
	path string
	cur  atomic.Value // string
}

// NewTokenStore loads (or creates) the token at path and returns a store.
func NewTokenStore(path string) (*TokenStore, error) {
	tok, err := LoadOrCreateToken(path)
	if err != nil {
		return nil, err
	}
	s := &TokenStore{path: path}
	s.cur.Store(tok)
	return s, nil
}

// Watch installs an fsnotify watch on the token file's parent directory and
// reloads the cached token on any change. Blocks until ctx is done. Failures
// (missing fsnotify, bad dir) degrade silently to validate-time disk reread.
func (s *TokenStore) Watch(ctx context.Context) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("token watcher disabled: %v", err)
		return
	}
	defer w.Close()
	dir := filepath.Dir(s.path)
	if err := w.Add(dir); err != nil {
		log.Printf("token: watch %s: %v", dir, err)
		return
	}
	target := filepath.Base(s.path)
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			if filepath.Base(ev.Name) != target {
				continue
			}
			if data, err := os.ReadFile(s.path); err == nil {
				fresh := trimNewline(string(data))
				if fresh != "" {
					s.cur.Store(fresh)
				}
			}
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			log.Printf("token watcher error: %v", err)
		}
	}
}

// Current returns the cached token value (after attempting a disk-side
// refresh if the file has been rewritten — the watcher handles this normally,
// but Validate calls reload as a belt-and-suspenders fallback).
func (s *TokenStore) Current() string {
	v, _ := s.cur.Load().(string)
	return v
}

// Validate compares got against the cached token. Belt-and-suspenders: even
// on a cached "match", re-reads from disk if the cached value disagrees with
// disk (handles the rotation-during-request case where fsnotify hasn't fired
// yet). Constant-time at each step.
func (s *TokenStore) Validate(got string) bool {
	if got == "" {
		return false
	}
	// Always check current disk value first — rotation may have happened
	// before fsnotify could deliver. Cheap (64 bytes) and auth is not hot.
	s.reloadFromDisk()
	return ValidateToken(got, s.Current())
}

// reloadFromDisk atomically updates the cached token if disk differs. Silent
// failure (returns without error) — the cached value remains in place.
func (s *TokenStore) reloadFromDisk() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	fresh := trimNewline(string(data))
	if fresh != "" && fresh != s.Current() {
		s.cur.Store(fresh)
	}
}

// GenerateToken returns a fresh hex-encoded 256-bit token.
func GenerateToken() (string, error) {
	b := make([]byte, tokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("rand: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// LoadOrCreateToken reads path; if missing, generates a token and writes it
// with 0600 perms (per ARD-0021 §6.2). The parent directory is created 0700.
// Refuses to load an existing token whose perms are looser than 0600. Per
// security review (high-9).
func LoadOrCreateToken(path string) (string, error) {
	if _, err := os.Stat(path); err == nil {
		if err := ensurePrivatePerms(path); err != nil {
			return "", err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read token: %w", err)
		}
		tok := trimNewline(string(data))
		if len(tok) >= 32 {
			return tok, nil
		}
		// Stale/short token — regenerate.
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("stat token: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", fmt.Errorf("mkdir token dir: %w", err)
	}
	tok, err := GenerateToken()
	if err != nil {
		return "", err
	}
	if err := atomicWriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write token: %w", err)
	}
	return tok, nil
}

// RotateToken always generates a fresh token and overwrites path.
func RotateToken(path string) (string, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", fmt.Errorf("mkdir: %w", err)
	}
	tok, err := GenerateToken()
	if err != nil {
		return "", err
	}
	if err := atomicWriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write token: %w", err)
	}
	return tok, nil
}

// ValidateToken returns true if got matches want (constant-time compare).
func ValidateToken(got, want string) bool {
	if want == "" || got == "" {
		return false
	}
	if len(got) != len(want) {
		// subtle.ConstantTimeCompare returns 0 on length mismatch without
		// timing leak, but explicit check keeps intent clear.
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// ValidateRequest pulls the cookie and validates against the live token store.
// Returns false if no cookie or no match (after rotation reload).
func ValidateRequest(req *http.Request, store *TokenStore) bool {
	if store == nil {
		return false
	}
	c, err := req.Cookie(cookieName)
	if err != nil {
		return false
	}
	return store.Validate(c.Value)
}

// HandleAuth implements the bootstrap handshake. GET /auth shows a paste-box
// for users who came in without the URL param; GET /auth?t=<token> validates
// and sets the cookie. Security headers (including Referrer-Policy: no-referrer
// per security review critical-6) are set BEFORE any redirect/write.
func HandleAuth(w http.ResponseWriter, req *http.Request, store *TokenStore) {
	// Per security review (critical-6): set Referrer-Policy before any
	// redirect so the /auth?t=<token> URL doesn't leak via Referer.
	setSecurityHeaders(w)

	t := req.URL.Query().Get("t")
	if t == "" {
		// TODO(boring-ui): nicer paste UI; for now just instruct.
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `<!doctype html><html><body style="font-family:system-ui;padding:2rem">
<h1>boring-ui — auth</h1>
<p>Visit <code>/auth?t=&lt;your-token&gt;</code> to sign in. The token was printed by <code>boring proxy install</code>.</p>
</body></html>`)
		return
	}
	want := ""
	if store != nil {
		want = store.Current()
	}
	if !ValidateToken(t, want) {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    t,
		Path:     "/",
		HttpOnly: true,
		Secure:   req.TLS != nil,
		SameSite: http.SameSiteStrictMode,
		// 30-day expiry; rotation invalidates the on-disk token, which
		// invalidates the cookie on next request.
		MaxAge: 30 * 24 * 60 * 60,
	})
	http.Redirect(w, req, "/", http.StatusFound)
}

func trimNewline(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}

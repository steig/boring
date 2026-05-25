package main

import (
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestGenerateTokenIs256Bits — token is hex-encoded 32 bytes (64 hex chars).
func TestGenerateTokenIs256Bits(t *testing.T) {
	tok, err := GenerateToken()
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	if len(tok) != 64 {
		t.Errorf("want 64 hex chars (256 bits), got %d", len(tok))
	}
	if _, err := hex.DecodeString(tok); err != nil {
		t.Errorf("not valid hex: %v", err)
	}
}

// TestGenerateTokenUnique — two consecutive calls must not collide.
func TestGenerateTokenUnique(t *testing.T) {
	a, _ := GenerateToken()
	b, _ := GenerateToken()
	if a == b {
		t.Errorf("two tokens collided: %s", a)
	}
}

// TestValidateToken — exact match accepts, mismatches reject, empties reject.
func TestValidateToken(t *testing.T) {
	tok, _ := GenerateToken()
	if !ValidateToken(tok, tok) {
		t.Errorf("good token rejected")
	}
	if ValidateToken("nope", tok) {
		t.Errorf("bad token accepted")
	}
	if ValidateToken("", tok) {
		t.Errorf("empty got accepted")
	}
	if ValidateToken(tok, "") {
		t.Errorf("empty want accepted")
	}
}

// TestLoadOrCreateTokenPersists — first call creates, second call reuses.
func TestLoadOrCreateTokenPersists(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "proxy", "token")

	tok1, err := LoadOrCreateToken(p)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if len(tok1) != 64 {
		t.Errorf("want 64-char token, got %d", len(tok1))
	}

	st, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Errorf("want mode 0600, got %o", st.Mode().Perm())
	}

	tok2, err := LoadOrCreateToken(p)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if tok2 != tok1 {
		t.Errorf("token changed between loads: %q vs %q", tok1, tok2)
	}
}

// TestRotateTokenChanges — RotateToken always issues a fresh value.
func TestRotateTokenChanges(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "proxy", "token")

	tok1, _ := LoadOrCreateToken(p)
	tok2, err := RotateToken(p)
	if err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if tok1 == tok2 {
		t.Errorf("rotation produced same token")
	}
}

// TestValidateRequestCookie — cookie-set requests pass; cookie-missing fail.
func TestValidateRequestCookie(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "token")
	store, err := NewTokenStore(p)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	tok := store.Current()
	req := httptest.NewRequest("GET", "/", nil)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: tok})
	if !ValidateRequest(req, store) {
		t.Errorf("good cookie rejected")
	}

	req2 := httptest.NewRequest("GET", "/", nil)
	if ValidateRequest(req2, store) {
		t.Errorf("missing cookie accepted")
	}
}

// TestHandleAuthSetsCookie — /auth?t=<good> sets the cookie + redirects.
func TestHandleAuthSetsCookie(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "token")
	store, err := NewTokenStore(p)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	tok := store.Current()
	req := httptest.NewRequest("GET", "/auth?t="+tok, nil)
	rec := httptest.NewRecorder()
	HandleAuth(rec, req, store)

	if rec.Code != http.StatusFound {
		t.Errorf("want 302, got %d", rec.Code)
	}
	setCookie := rec.Header().Get("Set-Cookie")
	if !strings.Contains(setCookie, cookieName+"="+tok) {
		t.Errorf("cookie not set; got %q", setCookie)
	}
}

// TestHandleAuthRejectsBadToken — /auth?t=<bad> returns 401, no cookie.
func TestHandleAuthRejectsBadToken(t *testing.T) {
	tmp := t.TempDir()
	p := filepath.Join(tmp, "token")
	store, err := NewTokenStore(p)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	req := httptest.NewRequest("GET", "/auth?t=wrong", nil)
	rec := httptest.NewRecorder()
	HandleAuth(rec, req, store)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("want 401, got %d", rec.Code)
	}
}

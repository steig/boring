// atomic.go — helpers for atomic file writes and permission checks.
// Critical files (token, plist/unit) are written via temp+rename so an
// interrupted write doesn't leave a half-written file in place.
package main

import (
	"fmt"
	"os"
)

// atomicWriteFile writes data to path+".tmp" then renames over path so an
// interrupted write doesn't leave a partial file behind. Caller-supplied perm
// is applied on the temp file before rename. Per security review (high-12).
func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return fmt.Errorf("write temp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename %s -> %s: %w", tmp, path, err)
	}
	return nil
}

// ensurePrivatePerms returns an error if path's mode allows group/world bits.
// Per security review (high-8, high-9): refuse to load secrets that aren't 0600.
func ensurePrivatePerms(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	if perm := st.Mode().Perm(); perm&0o077 != 0 {
		return fmt.Errorf("%s has insecure perms %#o; require 0600 (chmod 600 %s)", path, perm, path)
	}
	return nil
}

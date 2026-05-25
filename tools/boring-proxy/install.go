// install.go — `boring proxy install`, uninstall, status, rotate-token.
// v0 PROTOTYPE: provisions mkcert certs (if mkcert present), generates a token,
// writes the launchd plist / systemd unit. DOES NOT run sudo or launchctl —
// prints commands the user must run themselves (per scope guard).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func runInstall(_ []string) error {
	dataDir, err := DataDir()
	if err != nil {
		return fmt.Errorf("resolve data dir: %w", err)
	}
	proxyDir := filepath.Join(dataDir, "proxy")
	tlsDir := filepath.Join(proxyDir, "tls")

	if err := os.MkdirAll(tlsDir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", tlsDir, err)
	}

	fmt.Println("boring-proxy install (v0)")
	fmt.Println()

	// 1. mkcert check + cert provisioning.
	mkcert, err := exec.LookPath("mkcert")
	if err != nil {
		fmt.Println("WARN: mkcert not found.")
		fmt.Println("      Install: brew install mkcert  (macOS) | apt install mkcert  (Linux)")
		fmt.Println("      Then re-run `boring proxy install` to provision TLS.")
		fmt.Println()
	} else {
		fmt.Printf("mkcert: %s\n", mkcert)
		fmt.Println()
		fmt.Println("To install the local CA into your trust store, run (ONCE per machine):")
		fmt.Println("  mkcert -install")
		fmt.Println()
		certPath := filepath.Join(tlsDir, "boring.local.pem")
		keyPath := filepath.Join(tlsDir, "boring.local-key.pem")
		if _, err := os.Stat(certPath); err == nil {
			fmt.Printf("  TLS cert already present at %s\n", certPath)
		} else {
			fmt.Println("Issuing TLS cert for boring.local + *.boring.local...")
			cmd := exec.Command(mkcert, "-cert-file", certPath, "-key-file", keyPath,
				"boring.local", "*.boring.local")
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("mkcert issue: %w", err)
			}
			fmt.Printf("  cert: %s\n  key:  %s\n", certPath, keyPath)
			// Per security review (high-8): TLS key must be 0600.
			if err := os.Chmod(keyPath, 0o600); err != nil {
				return fmt.Errorf("chmod TLS key 0600: %w", err)
			}
		}
		fmt.Println()
	}

	// 2. Token.
	tokenPath := filepath.Join(proxyDir, "token")
	tok, err := LoadOrCreateToken(tokenPath)
	if err != nil {
		return fmt.Errorf("token: %w", err)
	}
	fmt.Printf("Token: %s (stored at %s, mode 0600)\n", tok, tokenPath)
	fmt.Printf("First-visit URL: https://boring.local/auth?t=%s\n", tok)
	fmt.Println()

	// 3. Autostart unit (write only; do NOT load).
	switch runtime.GOOS {
	case "darwin":
		if err := writeLaunchdPlist(dataDir); err != nil {
			return err
		}
	case "linux":
		if err := writeSystemdUnit(dataDir); err != nil {
			return err
		}
	default:
		fmt.Printf("Autostart not supported on %s; run `boring proxy serve` manually.\n", runtime.GOOS)
	}
	fmt.Println()

	// 4. /etc/hosts hint.
	if !hostsEntryPresent() {
		fmt.Println("Add boring.local to /etc/hosts (one-time sudo):")
		fmt.Println("  echo '127.0.0.1 boring.local' | sudo tee -a /etc/hosts")
	} else {
		fmt.Println("/etc/hosts: boring.local entry present.")
	}
	fmt.Println()
	fmt.Println("Install staged. Run the printed commands to activate.")
	return nil
}

func runUninstall(_ []string) error {
	dataDir, err := DataDir()
	if err != nil {
		return fmt.Errorf("resolve data dir: %w", err)
	}
	switch runtime.GOOS {
	case "darwin":
		plist, err := launchdPlistPath()
		if err != nil {
			return err
		}
		fmt.Printf("To stop and remove the autostart unit:\n")
		fmt.Printf("  launchctl unload %s\n", plist)
		fmt.Printf("  rm %s\n", plist)
	case "linux":
		unit, err := systemdUnitPath()
		if err != nil {
			return err
		}
		fmt.Printf("To stop and remove the autostart unit:\n")
		fmt.Printf("  systemctl --user disable --now boring-proxy.service\n")
		fmt.Printf("  rm %s\n", unit)
	}
	fmt.Println()
	fmt.Println("Token and certs left in place. Remove manually if desired:")
	fmt.Printf("  rm -rf %s\n", filepath.Join(dataDir, "proxy"))
	return nil
}

func runStatus(_ []string) error {
	dataDir, err := DataDir()
	if err != nil {
		return fmt.Errorf("resolve data dir: %w", err)
	}
	fmt.Printf("data dir:  %s\n", dataDir)

	tokPath := filepath.Join(dataDir, "proxy", "token")
	if st, err := os.Stat(tokPath); err == nil {
		fmt.Printf("token:     present (%s, mode %o)\n", tokPath, st.Mode().Perm())
		if perm := st.Mode().Perm(); perm&0o077 != 0 {
			fmt.Printf("           WARN: token perms %#o are loose; expected 0600 (chmod 600 %s)\n", perm, tokPath)
		}
	} else {
		fmt.Printf("token:     MISSING (%s)\n", tokPath)
	}

	certPath := filepath.Join(dataDir, "proxy", "tls", "boring.local.pem")
	keyPath := filepath.Join(dataDir, "proxy", "tls", "boring.local-key.pem")
	if _, err := os.Stat(certPath); err == nil {
		fmt.Printf("tls cert:  present (%s)\n", certPath)
	} else {
		fmt.Printf("tls cert:  MISSING (%s) — run `boring proxy install`\n", certPath)
	}
	if st, err := os.Stat(keyPath); err == nil {
		// Per security review (high-8): surface loose key perms.
		if perm := st.Mode().Perm(); perm&0o077 != 0 {
			fmt.Printf("tls key:   WARN perms %#o; expected 0600 (chmod 600 %s)\n", perm, keyPath)
		} else {
			fmt.Printf("tls key:   present (%s, mode %o)\n", keyPath, st.Mode().Perm())
		}
	}

	if hostsEntryPresent() {
		fmt.Println("/etc/hosts: boring.local present")
	} else {
		fmt.Println("/etc/hosts: boring.local NOT present")
	}

	regPath := filepath.Join(dataDir, "registry.json")
	if _, err := os.Stat(regPath); err == nil {
		fmt.Printf("registry:  %s\n", regPath)
	} else {
		fmt.Printf("registry:  not present yet (%s)\n", regPath)
	}

	// TODO(boring-ui): check whether the proxy process is actually running
	// (PID file or launchctl/systemctl query).
	fmt.Println("running:   (TODO) check launchd/systemd status")
	return nil
}

func runRotateToken(_ []string) error {
	dataDir, err := DataDir()
	if err != nil {
		return fmt.Errorf("resolve data dir: %w", err)
	}
	tokenPath := filepath.Join(dataDir, "proxy", "token")
	tok, err := RotateToken(tokenPath)
	if err != nil {
		return err
	}
	fmt.Printf("New token: %s\n", tok)
	fmt.Printf("New auth URL: https://boring.local/auth?t=%s\n", tok)
	fmt.Println()
	fmt.Println("Existing browser sessions will be signed out on their next request.")
	// TODO(boring-ui): push a `--reset` mode that proactively invalidates sessions.
	return nil
}

// launchdPlistPath returns the LaunchAgent plist path.
func launchdPlistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home: %w", err)
	}
	return filepath.Join(home, "Library", "LaunchAgents", "io.boring.proxy.plist"), nil
}

func writeLaunchdPlist(dataDir string) error {
	binPath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve self: %w", err)
	}
	plistPath, err := launchdPlistPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(plistPath), 0o755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.boring.proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>%s/proxy/proxy.log</string>
  <key>StandardErrorPath</key><string>%s/proxy/proxy.log</string>
</dict>
</plist>
`, binPath, dataDir, dataDir)
	if err := atomicWriteFile(plistPath, []byte(content), 0o644); err != nil {
		return fmt.Errorf("write plist: %w", err)
	}
	fmt.Printf("LaunchAgent plist written: %s\n", plistPath)
	fmt.Println("Activate with:")
	fmt.Printf("  launchctl load %s\n", plistPath)
	return nil
}

func systemdUnitPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home: %w", err)
	}
	return filepath.Join(home, ".config", "systemd", "user", "boring-proxy.service"), nil
}

func writeSystemdUnit(dataDir string) error {
	binPath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve self: %w", err)
	}
	unitPath, err := systemdUnitPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(unitPath), 0o755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	content := fmt.Sprintf(`[Unit]
Description=boring-ui host-side reverse proxy (ARD-0021)
After=default.target

[Service]
Type=simple
ExecStart=%s serve
Restart=on-failure
RestartSec=5s
StandardOutput=append:%s/proxy/proxy.log
StandardError=append:%s/proxy/proxy.log

[Install]
WantedBy=default.target
`, binPath, dataDir, dataDir)
	if err := atomicWriteFile(unitPath, []byte(content), 0o644); err != nil {
		return fmt.Errorf("write unit: %w", err)
	}
	fmt.Printf("systemd user unit written: %s\n", unitPath)
	fmt.Println("Activate with:")
	fmt.Printf("  systemctl --user daemon-reload\n")
	fmt.Printf("  systemctl --user enable --now boring-proxy.service\n")
	return nil
}

// hostsEntryPresent does a best-effort scan; returns false on any read error.
func hostsEntryPresent() bool {
	data, err := os.ReadFile("/etc/hosts")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		l := strings.TrimSpace(line)
		if strings.HasPrefix(l, "#") || l == "" {
			continue
		}
		if strings.Contains(l, "boring.local") {
			return true
		}
	}
	return false
}

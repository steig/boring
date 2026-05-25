// boring-proxy is the host-side reverse proxy for boring-ui (ARD-0021).
// v0 prototype: serves the project picker at /, routes /<slug>/... to per-project
// Unix sockets, terminates TLS, validates a per-user token cookie.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("boring-proxy: ")

	if len(os.Args) < 2 {
		printHelp()
		os.Exit(1)
	}

	sub := os.Args[1]
	args := os.Args[2:]

	switch sub {
	case "serve":
		if err := runServe(args); err != nil {
			log.Fatalf("serve: %v", err)
		}
	case "install":
		if err := runInstall(args); err != nil {
			log.Fatalf("install: %v", err)
		}
	case "uninstall":
		if err := runUninstall(args); err != nil {
			log.Fatalf("uninstall: %v", err)
		}
	case "status":
		if err := runStatus(args); err != nil {
			log.Fatalf("status: %v", err)
		}
	case "rotate-token":
		if err := runRotateToken(args); err != nil {
			log.Fatalf("rotate-token: %v", err)
		}
	case "-h", "--help", "help":
		printHelp()
	default:
		fmt.Fprintf(os.Stderr, "boring-proxy: unknown subcommand: %s\n\n", sub)
		printHelp()
		os.Exit(1)
	}
}

func printHelp() {
	fmt.Fprint(os.Stderr, `boring-proxy — host-side reverse proxy for boring-ui (ARD-0021, v0)

USAGE
  boring-proxy <subcommand> [flags]

SUBCOMMANDS
  serve          Run the proxy (TLS on :443 by default, or HTTP --insecure)
  install        Provision TLS certs (mkcert), token, launchd/systemd unit
  uninstall      Remove autostart unit; leaves token + certs in place
  status         Print proxy status (running, certs, token presence)
  rotate-token   Regenerate the per-user auth token
  help           Print this help

SERVE FLAGS
  --insecure        HTTP only, no TLS (dev mode)
  --port <n>        Port to bind (default: 443 with TLS, 8080 without)
  --bind <addr>     Bind address (default: 127.0.0.1)
  --no-auth         Skip token validation (dev only)
`)
}

// runServe parses serve-mode flags and starts the HTTP(S) server.
func runServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	insecure := fs.Bool("insecure", false, "HTTP only (dev mode)")
	port := fs.Int("port", 0, "port (default 443 TLS, 8080 HTTP)")
	bind := fs.String("bind", "127.0.0.1", "bind address")
	noAuth := fs.Bool("no-auth", false, "skip token validation (dev only)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *port == 0 {
		if *insecure {
			*port = 8080
		} else {
			*port = 443
		}
	}

	cfg := ServeConfig{
		Insecure: *insecure,
		Port:     *port,
		Bind:     *bind,
		NoAuth:   *noAuth,
	}
	return Serve(cfg)
}

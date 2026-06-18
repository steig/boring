// picker.go — serves the project picker (HTML + assets) and the /api/projects
// JSON endpoint the dashboard consumes.
package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"net/http"
	"strings"
)

//go:embed assets
var pickerAssets embed.FS

// ServePickerIndex serves the picker's index.html (root of the embedded assets).
func ServePickerIndex(w http.ResponseWriter, _ *http.Request) {
	data, err := pickerAssets.ReadFile("assets/index.html")
	if err != nil {
		http.Error(w, "picker assets missing", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(data)
}

// ServePickerAsset serves anything under /assets/. Trims the leading slash
// (embed.FS uses unrooted paths) and refuses anything that escapes.
func ServePickerAsset(w http.ResponseWriter, req *http.Request) {
	name := strings.TrimPrefix(req.URL.Path, "/")
	if strings.Contains(name, "..") {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	sub, err := fs.Sub(pickerAssets, "assets")
	if err != nil {
		http.Error(w, "picker assets misconfigured", http.StatusInternalServerError)
		return
	}
	http.StripPrefix("/assets/", http.FileServer(http.FS(sub))).ServeHTTP(w, req)
}

// projectCard is the per-project view the dashboard renders. It augments the
// registry entry with a live status (resolved from socket reachability, not
// just the operator-asserted registry field) and the project's in-proxy URL.
type projectCard struct {
	Slug       string `json:"slug"`
	Name       string `json:"name"`
	URL        string `json:"url"`
	Status     string `json:"status"`
	LastActive string `json:"last_active,omitempty"`
	Summary    string `json:"summary,omitempty"`
}

// ServeProjectsAPI returns the registry, decorated with live status, as JSON
// for the dashboard's JS.
func ServeProjectsAPI(w http.ResponseWriter, _ *http.Request, reg *Registry) {
	projects := reg.List()
	cards := make([]projectCard, 0, len(projects))
	for _, p := range projects {
		cards = append(cards, projectCard{
			Slug:       p.Slug,
			Name:       p.Name,
			URL:        "/" + p.Slug + "/",
			Status:     liveStatus(p),
			LastActive: p.LastActive,
			Summary:    p.Summary,
		})
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"projects": cards,
	})
}

// liveStatus resolves status from the project's socket rather than the
// operator-asserted registry field (which ARD-0021 left as a TODO). A reachable
// socket reads "running"; otherwise transient registry states pass through and
// everything else collapses to "stopped".
func liveStatus(p Project) string {
	sock := p.Socket
	if sock == "" {
		sock = defaultSocketPath(p.Slug)
	}
	// verifySocketOwner Lstats the path, so a missing socket fails here too.
	if verifySocketOwner(sock) == nil {
		return "running"
	}
	switch p.Status {
	case "starting", "error":
		return p.Status
	default:
		return "stopped"
	}
}

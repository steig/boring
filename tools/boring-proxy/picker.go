// picker.go — serves the project picker (HTML + assets) and the /api/projects
// JSON endpoint the picker consumes.
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

// ServeProjectsAPI returns the registry as JSON for the picker's JS.
func ServeProjectsAPI(w http.ResponseWriter, _ *http.Request, reg *Registry) {
	projects := reg.List()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"projects": projects,
	})
}

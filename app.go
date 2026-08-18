package main

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

const (
	defaultHTTPTimeout  = 15 * time.Second
	defaultWriteTimeout = 60 * time.Second
	defaultIdleTimeout  = 90 * time.Second
	defaultDNSAddress   = "1.1.1.1:53"
	maxJSONBody         = 1 << 20
	maxBackupBody       = 16 << 20
)

//go:embed web/*
var webFiles embed.FS

type app struct {
	store    *store
	runtime  *roomRuntime
	password string
	sessions *sessionStore
}

type sessionStore struct {
	mu     sync.Mutex
	tokens map[string]time.Time
}

func newApp(store *store, runtime *roomRuntime, password string) *app {
	return &app{store: store, runtime: runtime, password: password, sessions: &sessionStore{tokens: make(map[string]time.Time)}}
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", a.health)
	mux.HandleFunc("POST /api/login", a.login)
	mux.HandleFunc("POST /api/logout", a.auth(a.logout))
	mux.HandleFunc("GET /api/dashboard", a.auth(a.dashboard))
	mux.HandleFunc("PUT /api/settings", a.auth(a.updateSettings))
	mux.HandleFunc("POST /api/rooms", a.auth(a.createRoom))
	mux.HandleFunc("PUT /api/rooms/{id}", a.auth(a.updateRoom))
	mux.HandleFunc("DELETE /api/rooms/{id}", a.auth(a.deleteRoom))
	mux.HandleFunc("POST /api/rooms/{id}/restart", a.auth(a.restartRoom))
	mux.HandleFunc("GET /api/rooms/{id}/qr", a.auth(a.roomQR))
	mux.HandleFunc("POST /api/backup/export", a.auth(a.exportBackup))
	mux.HandleFunc("POST /api/backup/import", a.auth(a.importBackup))
	mux.HandleFunc("/", a.serveWeb)
	return securityHeaders(requestLogger(a.accessControl(mux)))
}

func (a *app) accessControl(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if !a.store.snapshot().PublicAccess {
			host := request.RemoteAddr
			if parsed, _, err := net.SplitHostPort(request.RemoteAddr); err == nil {
				host = parsed
			}
			if net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback() {
				if forwarded := request.Header.Get("X-Real-IP"); forwarded != "" {
					host = forwarded
				}
			}
			if net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
				http.Error(w, "remote access disabled", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, request)
	})
}

func (a *app) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": version})
}

func (a *app) login(w http.ResponseWriter, request *http.Request) {
	var input struct {
		Password string `json:"password"`
	}
	if err := decodeJSON(request, &input, maxJSONBody); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if subtle.ConstantTimeCompare([]byte(input.Password), []byte(a.password)) != 1 {
		time.Sleep(350 * time.Millisecond)
		writeError(w, http.StatusUnauthorized, errors.New("invalid password"))
		return
	}
	token, err := randomHex(32)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	a.sessions.put(token)
	http.SetCookie(w, &http.Cookie{
		Name:     "olc_session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   request.TLS != nil || request.Header.Get("X-Forwarded-Proto") == "https",
		MaxAge:   int((24 * time.Hour).Seconds()),
	})
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) logout(w http.ResponseWriter, request *http.Request) {
	if cookie, err := request.Cookie("olc_session"); err == nil {
		a.sessions.remove(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: "olc_session", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: request.TLS != nil || request.Header.Get("X-Forwarded-Proto") == "https"})
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		cookie, err := request.Cookie("olc_session")
		if err != nil || !a.sessions.valid(cookie.Value) {
			writeError(w, http.StatusUnauthorized, errors.New("authentication required"))
			return
		}
		if request.Method != http.MethodGet && request.Method != http.MethodHead {
			if request.Header.Get("X-OLC-Request") != "1" {
				writeError(w, http.StatusForbidden, errors.New("invalid request origin"))
				return
			}
		}
		next(w, request)
	}
}

func (a *app) dashboard(w http.ResponseWriter, _ *http.Request) {
	state := a.store.snapshot()
	rooms := make([]RoomView, 0, len(state.Rooms))
	for _, room := range state.Rooms {
		status, runtimeError := a.runtime.status(room.ID)
		rooms = append(rooms, RoomView{Room: room, Status: status, Error: runtimeError, Link: profileLink(room)})
	}
	writeJSON(w, http.StatusOK, Dashboard{Version: version, Rooms: rooms, PublicAccess: state.PublicAccess, DefaultCarrier: state.DefaultCarrier})
}

func (a *app) updateSettings(w http.ResponseWriter, request *http.Request) {
	var input struct {
		PublicAccess   bool   `json:"publicAccess"`
		DefaultCarrier string `json:"defaultCarrier"`
	}
	if err := decodeJSON(request, &input, maxJSONBody); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if input.DefaultCarrier != "jitsi" && input.DefaultCarrier != "telemost" && input.DefaultCarrier != "wbstream" {
		writeError(w, http.StatusBadRequest, errors.New("unsupported default provider"))
		return
	}
	if err := a.store.update(func(state *State) error {
		state.PublicAccess = input.PublicAccess
		state.DefaultCarrier = input.DefaultCarrier
		return nil
	}); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, input)
}

func (a *app) createRoom(w http.ResponseWriter, request *http.Request) {
	var input Room
	if err := decodeJSON(request, &input, maxJSONBody); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	room, err := normalizeRoom(input, true)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := a.store.update(func(state *State) error {
		state.Rooms = append(state.Rooms, room)
		return nil
	}); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if err := a.runtime.restart(room); err != nil {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("room saved, but could not start: %w", err))
		return
	}
	writeJSON(w, http.StatusCreated, room)
}

func (a *app) updateRoom(w http.ResponseWriter, request *http.Request) {
	id := request.PathValue("id")
	var input Room
	if err := decodeJSON(request, &input, maxJSONBody); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	input.ID = id
	room, err := normalizeRoom(input, false)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	found := false
	err = a.store.update(func(state *State) error {
		for index := range state.Rooms {
			if state.Rooms[index].ID == id {
				room.CreatedAt = state.Rooms[index].CreatedAt
				state.Rooms[index] = room
				found = true
				return nil
			}
		}
		return nil
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, errors.New("room not found"))
		return
	}
	if err := a.runtime.restart(room); err != nil {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("room saved, but could not restart: %w", err))
		return
	}
	writeJSON(w, http.StatusOK, room)
}

func (a *app) deleteRoom(w http.ResponseWriter, request *http.Request) {
	id := request.PathValue("id")
	found := false
	if err := a.store.update(func(state *State) error {
		rooms := state.Rooms[:0]
		for _, room := range state.Rooms {
			if room.ID == id {
				found = true
				continue
			}
			rooms = append(rooms, room)
		}
		state.Rooms = rooms
		return nil
	}); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, errors.New("room not found"))
		return
	}
	a.runtime.remove(id)
	w.WriteHeader(http.StatusNoContent)
}

func (a *app) restartRoom(w http.ResponseWriter, request *http.Request) {
	room, ok := findRoom(a.store.snapshot().Rooms, request.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, errors.New("room not found"))
		return
	}
	if err := a.runtime.restart(room); err != nil {
		writeError(w, http.StatusUnprocessableEntity, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) roomQR(w http.ResponseWriter, request *http.Request) {
	room, ok := findRoom(a.store.snapshot().Rooms, request.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, errors.New("room not found"))
		return
	}
	data, err := qrcode.Encode(profileLink(room), qrcode.Medium, 512)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "private, no-store")
	_, _ = w.Write(data)
}

func (a *app) exportBackup(w http.ResponseWriter, request *http.Request) {
	data, err := encodeBackup(a.store.snapshot())
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="olcserver-backup.olcbak"`)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (a *app) importBackup(w http.ResponseWriter, request *http.Request) {
	data, err := io.ReadAll(http.MaxBytesReader(w, request.Body, maxBackupBody))
	if err != nil {
		writeError(w, http.StatusBadRequest, errors.New("backup is too large"))
		return
	}
	state, err := decodeBackup(data)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := validateState(state); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := a.store.replace(state); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if err := a.runtime.reconcile(state.Rooms); err != nil {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("backup restored, but some rooms did not start: %w", err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) serveWeb(w http.ResponseWriter, request *http.Request) {
	name := strings.TrimPrefix(path.Clean(request.URL.Path), "/")
	if name == "." || name == "" {
		name = "index.html"
	}
	data, err := fs.ReadFile(webFiles, "web/"+name)
	if err != nil {
		data, err = fs.ReadFile(webFiles, "web/index.html")
	}
	if err != nil {
		http.Error(w, "UI unavailable", http.StatusInternalServerError)
		return
	}
	if contentType := mime.TypeByExtension(path.Ext(name)); contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	_, _ = w.Write(data)
}

func normalizeRoom(input Room, create bool) (Room, error) {
	input.Name = strings.TrimSpace(input.Name)
	input.Description = strings.TrimSpace(input.Description)
	input.Carrier = strings.ToLower(strings.TrimSpace(input.Carrier))
	input.Transport = strings.ToLower(strings.TrimSpace(input.Transport))
	input.RoomID = strings.TrimSpace(input.RoomID)
	input.DNS = strings.TrimSpace(input.DNS)
	if input.Name == "" || input.RoomID == "" {
		return Room{}, errors.New("name and room ID are required")
	}
	if strings.ContainsAny(input.RoomID, "@#$\n\r") {
		return Room{}, errors.New("room ID contains characters unsupported by olcrtc links")
	}
	if input.Carrier != "jitsi" && input.Carrier != "telemost" && input.Carrier != "wbstream" {
		return Room{}, errors.New("unsupported carrier")
	}
	if input.Transport != "datachannel" && input.Transport != "vp8channel" {
		return Room{}, errors.New("this manager supports datachannel and vp8channel")
	}
	if input.Carrier == "jitsi" && input.Transport != "datachannel" {
		return Room{}, errors.New("use datachannel for Jitsi")
	}
	if (input.Carrier == "telemost" || input.Carrier == "wbstream") && input.Transport != "vp8channel" {
		return Room{}, errors.New("use vp8channel for Telemost and WB Stream")
	}
	if input.DNS == "" {
		input.DNS = defaultDNSAddress
	}
	if input.VP8FPS == 0 {
		input.VP8FPS = 60
	}
	if input.VP8Batch == 0 {
		input.VP8Batch = 64
	}
	if input.VP8FPS < 1 || input.VP8FPS > 120 || input.VP8Batch < 1 || input.VP8Batch > 64 {
		return Room{}, errors.New("VP8 values are outside the supported range")
	}
	if input.KeyHex == "" {
		key, err := randomHex(32)
		if err != nil {
			return Room{}, err
		}
		input.KeyHex = key
	}
	if len(input.KeyHex) != 64 {
		return Room{}, errors.New("encryption key must contain 64 hexadecimal characters")
	}
	if _, err := hex.DecodeString(input.KeyHex); err != nil {
		return Room{}, errors.New("encryption key must contain 64 hexadecimal characters")
	}
	now := time.Now().UTC()
	if create {
		id, err := randomHex(12)
		if err != nil {
			return Room{}, err
		}
		input.ID = id
		input.CreatedAt = now
	}
	input.UpdatedAt = now
	return input, nil
}

func validateState(state State) error {
	seen := make(map[string]bool)
	for _, room := range state.Rooms {
		if room.ID == "" || seen[room.ID] {
			return errors.New("backup contains invalid room identifiers")
		}
		seen[room.ID] = true
		if _, err := normalizeRoom(room, false); err != nil {
			return fmt.Errorf("invalid room %q: %w", room.Name, err)
		}
	}
	for _, grant := range state.Grants {
		if grant.ID == "" || !seen[grant.RoomID] {
			return errors.New("backup contains an invalid access link")
		}
	}
	return nil
}

func profileLink(room Room) string {
	options := ""
	if room.Transport == "vp8channel" {
		options = "<vp8-fps=" + strconv.Itoa(room.VP8FPS) + "&vp8-batch=" + strconv.Itoa(room.VP8Batch) + ">"
	}
	name := strings.ReplaceAll(url.QueryEscape(room.Name), "+", "%20")
	return "olcrtc://" + room.Carrier + "?" + room.Transport + options + "@" + room.RoomID + "#" + room.KeyHex + "$" + name
}

func findRoom(rooms []Room, id string) (Room, bool) {
	for _, room := range rooms {
		if room.ID == id {
			return room, true
		}
	}
	return Room{}, false
}

func randomHex(size int) (string, error) {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

func decodeJSON(request *http.Request, target any, limit int64) error {
	decoder := json.NewDecoder(http.MaxBytesReader(nil, request.Body, limit))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("invalid request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("invalid request: expected one JSON value")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

func (sessions *sessionStore) put(token string) {
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	now := time.Now()
	for value, expiry := range sessions.tokens {
		if now.After(expiry) {
			delete(sessions.tokens, value)
		}
	}
	sessions.tokens[token] = now.Add(24 * time.Hour)
}

func (sessions *sessionStore) valid(token string) bool {
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	expiry, ok := sessions.tokens[token]
	if !ok || time.Now().After(expiry) {
		delete(sessions.tokens, token)
		return false
	}
	return true
}

func (sessions *sessionStore) remove(token string) {
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	delete(sessions.tokens, token)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, request)
	})
}

func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, request)
		if strings.HasPrefix(request.URL.Path, "/api/") && request.URL.Path != "/api/health" {
			fmt.Printf("%s %s %s\n", request.Method, request.URL.Path, time.Since(started).Round(time.Millisecond))
		}
	})
}

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeRoomGeneratesKeyAndDefaults(t *testing.T) {
	room, err := normalizeRoom(Room{
		Name:      " Main ",
		Carrier:   "JITSI",
		Transport: "datachannel",
		RoomID:    "https://meet.example/room",
		Enabled:   true,
	}, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(room.ID) != 24 || len(room.KeyHex) != 64 {
		t.Fatalf("unexpected generated identifiers: id=%q key=%q", room.ID, room.KeyHex)
	}
	if room.Name != "Main" || room.DNS != "8.8.8.8:53" || room.VP8FPS != 60 || room.VP8Batch != 64 {
		t.Fatalf("unexpected normalized room: %+v", room)
	}
}

func TestNormalizeRoomRejectsIncompatibleTransport(t *testing.T) {
	_, err := normalizeRoom(Room{
		Name: "WB", Carrier: "wbstream", Transport: "datachannel", RoomID: "room",
	}, true)
	if err == nil {
		t.Fatal("expected incompatible transport error")
	}
}

func TestBackupRoundTrip(t *testing.T) {
	state := State{
		Version: 1,
		Rooms: []Room{{
			ID: "room-id", Name: "Main", Carrier: "jitsi", Transport: "datachannel",
			RoomID: "https://meet.example/room", KeyHex: strings.Repeat("a", 64), DNS: "8.8.8.8:53",
			VP8FPS: 25, VP8Batch: 1, Enabled: true,
		}},
	}
	data, err := encodeBackup(state)
	if err != nil {
		t.Fatal(err)
	}
	restored, err := decodeBackup(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(restored.Rooms) != 1 || restored.Rooms[0].KeyHex != state.Rooms[0].KeyHex {
		t.Fatalf("unexpected restored state: %+v", restored)
	}
	if _, err := decodeBackup([]byte("not-a-backup")); err == nil {
		t.Fatal("expected invalid backup error")
	}
}

func TestStorePersistsState(t *testing.T) {
	dir := t.TempDir()
	first, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.update(func(state *State) error {
		state.Rooms = append(state.Rooms, Room{ID: "one", Name: "Room"})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	second, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if rooms := second.snapshot().Rooms; len(rooms) != 1 || rooms[0].ID != "one" {
		t.Fatalf("unexpected persisted rooms: %+v", rooms)
	}
}

func TestLoginAndRoomFlow(t *testing.T) {
	dir := t.TempDir()
	store, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	runtime := newRoomRuntime(dir, "/bin/sleep")
	defer runtime.stopAll()
	server := httptest.NewServer(newApp(store, runtime, "test-password").routes())
	defer server.Close()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Jar: jar}
	loginResponse := jsonRequest(t, client, http.MethodPost, server.URL+"/api/login", `{"password":"test-password"}`, false)
	if loginResponse.StatusCode != http.StatusOK {
		t.Fatalf("login status = %d", loginResponse.StatusCode)
	}
	_ = loginResponse.Body.Close()

	roomJSON := `{"id":"","name":"Main","carrier":"jitsi","transport":"datachannel","roomId":"https://meet.example/room","keyHex":"","dns":"","vp8Fps":25,"vp8Batch":1,"enabled":false,"createdAt":"0001-01-01T00:00:00Z","updatedAt":"0001-01-01T00:00:00Z"}`
	roomResponse := jsonRequest(t, client, http.MethodPost, server.URL+"/api/rooms", roomJSON, true)
	if roomResponse.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(roomResponse.Body)
		t.Fatalf("create room status = %d: %s", roomResponse.StatusCode, body)
	}
	var room Room
	if err := json.NewDecoder(roomResponse.Body).Decode(&room); err != nil {
		t.Fatal(err)
	}
	_ = roomResponse.Body.Close()

	qrResponse, err := client.Get(server.URL + "/api/rooms/" + room.ID + "/qr")
	if err != nil {
		t.Fatal(err)
	}
	defer qrResponse.Body.Close()
	if qrResponse.StatusCode != http.StatusOK || qrResponse.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("QR response status=%d content-type=%q", qrResponse.StatusCode, qrResponse.Header.Get("Content-Type"))
	}
}

func TestRoomYAML(t *testing.T) {
	room := Room{
		Carrier: "wbstream", RoomID: "room", KeyHex: strings.Repeat("b", 64),
		Transport: "vp8channel", DNS: "1.1.1.1:53", VP8FPS: 30, VP8Batch: 4,
	}
	config := roomYAML(room, "/var/lib/olc/data")
	for _, expected := range []string{`provider: "wbstream"`, `transport: "vp8channel"`, "fps: 30", "batch_size: 4"} {
		if !strings.Contains(config, expected) {
			t.Fatalf("config does not contain %q:\n%s", expected, config)
		}
	}
}

func TestEnsureAdminPasswordIsStable(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")
	first, created, err := ensureAdminPassword(dir)
	if err != nil || !created {
		t.Fatalf("first password: created=%v err=%v", created, err)
	}
	second, created, err := ensureAdminPassword(dir)
	if err != nil || created || first != second {
		t.Fatalf("second password: created=%v err=%v equal=%v", created, err, first == second)
	}
	info, err := os.Stat(filepath.Join(dir, "admin-password"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("password permissions = %o", info.Mode().Perm())
	}
}

func TestSettingsPersistDefaultCarrier(t *testing.T) {
	dir := t.TempDir()
	store, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := store.snapshot().DefaultCarrier; got != "jitsi" {
		t.Fatalf("default carrier = %q", got)
	}
	if err := store.update(func(state *State) error {
		state.DefaultCarrier = "wbstream"
		state.PublicAccess = false
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	reloaded, err := newStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	state := reloaded.snapshot()
	if state.DefaultCarrier != "wbstream" || state.PublicAccess {
		t.Fatalf("settings did not persist: %+v", state)
	}
}

func jsonRequest(t *testing.T, client *http.Client, method, url, body string, authenticated bool) *http.Response {
	t.Helper()
	request, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	if authenticated {
		request.Header.Set("X-OLC-Request", "1")
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

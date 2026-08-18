package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	runtimeErrorLogBytes = 8 << 10
	runtimeErrorLogLines = 8
)

var ansiEscapeSequence = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)

type processState struct {
	command *exec.Cmd
	status  string
	err     string
	done    chan struct{}
}

type roomRuntime struct {
	mu         sync.Mutex
	dataDir    string
	executable string
	processes  map[string]*processState
}

func newRoomRuntime(dataDir, executable string) *roomRuntime {
	return &roomRuntime{dataDir: dataDir, executable: executable, processes: make(map[string]*processState)}
}

func (r *roomRuntime) reconcile(rooms []Room) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	wanted := make(map[string]Room, len(rooms))
	for _, room := range rooms {
		if room.Enabled {
			wanted[room.ID] = room
		}
	}
	for id := range r.processes {
		if _, ok := wanted[id]; !ok {
			r.stopLocked(id)
		}
	}
	var failures []string
	for id, room := range wanted {
		if current := r.processes[id]; current != nil && current.status == "running" {
			continue
		}
		if err := r.startLocked(room); err != nil {
			failures = append(failures, room.Name+": "+err.Error())
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("start rooms: %s", strings.Join(failures, "; "))
	}
	return nil
}

func (r *roomRuntime) restart(room Room) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.stopLocked(room.ID)
	if !room.Enabled {
		return nil
	}
	return r.startLocked(room)
}

func (r *roomRuntime) remove(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.stopLocked(id)
	_ = os.RemoveAll(filepath.Join(r.dataDir, "rooms", id))
}

func (r *roomRuntime) status(id string) (string, string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := r.processes[id]
	if state == nil {
		return "stopped", ""
	}
	return state.status, state.err
}

func (r *roomRuntime) stopAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id := range r.processes {
		r.stopLocked(id)
	}
}

func (r *roomRuntime) startLocked(room Room) error {
	dir := filepath.Join(r.dataDir, "rooms", room.ID)
	if err := os.MkdirAll(filepath.Join(dir, "data"), 0o700); err != nil {
		return err
	}
	configPath := filepath.Join(dir, "server.yaml")
	if err := os.WriteFile(configPath, []byte(roomYAML(room, filepath.Join(dir, "data"))), 0o600); err != nil {
		return err
	}
	logPath := filepath.Join(dir, "olcrtc.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	logStart := int64(0)
	if info, statErr := logFile.Stat(); statErr == nil {
		logStart = info.Size()
	}
	cmd := exec.Command(r.executable, configPath)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	state := &processState{command: cmd, status: "starting", done: make(chan struct{})}
	r.processes[room.ID] = state
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		state.status = "failed"
		state.err = err.Error()
		return err
	}
	state.status = "running"
	go func(id string, process *processState) {
		err := cmd.Wait()
		_ = logFile.Close()
		close(process.done)
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.processes[id] != process {
			return
		}
		process.status = "failed"
		process.err = processError(err, logPath, logStart)
	}(room.ID, state)
	return nil
}

func processError(waitErr error, logPath string, logStart int64) string {
	message := "process exited"
	if waitErr != nil {
		message = waitErr.Error()
	}
	if excerpt := runtimeLogExcerpt(logPath, logStart); excerpt != "" {
		return message + "\n" + excerpt
	}
	return message
}

func runtimeLogExcerpt(logPath string, logStart int64) string {
	file, err := os.Open(logPath)
	if err != nil {
		return ""
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return ""
	}
	offset := logStart
	if minimum := info.Size() - runtimeErrorLogBytes; offset < minimum {
		offset = minimum
	}
	if offset < 0 || offset > info.Size() {
		offset = 0
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return ""
	}
	data, err := io.ReadAll(io.LimitReader(file, runtimeErrorLogBytes))
	if err != nil {
		return ""
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if offset > logStart {
		if newline := strings.IndexByte(text, '\n'); newline >= 0 {
			text = text[newline+1:]
		}
	}
	text = strings.TrimSpace(ansiEscapeSequence.ReplaceAllString(text, ""))
	if text == "" {
		return ""
	}
	lines := strings.Split(text, "\n")
	if len(lines) > runtimeErrorLogLines {
		lines = lines[len(lines)-runtimeErrorLogLines:]
	}
	return strings.Join(lines, "\n")
}

func (r *roomRuntime) stopLocked(id string) {
	state := r.processes[id]
	if state == nil {
		return
	}
	delete(r.processes, id)
	if state.command != nil && state.command.Process != nil {
		_ = state.command.Process.Signal(os.Interrupt)
		select {
		case <-state.done:
		case <-time.After(5 * time.Second):
			_ = state.command.Process.Kill()
			<-state.done
		}
	}
}

func roomYAML(room Room, dataDir string) string {
	var builder strings.Builder
	builder.WriteString("mode: srv\n")
	builder.WriteString("auth:\n  provider: " + yamlString(room.Carrier) + "\n")
	builder.WriteString("room:\n  id: " + yamlString(room.RoomID) + "\n")
	builder.WriteString("crypto:\n  key: " + yamlString(room.KeyHex) + "\n")
	builder.WriteString("net:\n  transport: " + yamlString(room.Transport) + "\n  dns: " + yamlString(room.DNS) + "\n")
	if room.Transport == "vp8channel" {
		builder.WriteString("vp8:\n  fps: " + strconv.Itoa(room.VP8FPS) + "\n  batch_size: " + strconv.Itoa(room.VP8Batch) + "\n")
	}
	builder.WriteString("data: " + yamlString(dataDir) + "\n")
	return builder.String()
}

func yamlString(value string) string {
	return strconv.Quote(value)
}

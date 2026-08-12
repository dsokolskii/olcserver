package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type store struct {
	mu    sync.RWMutex
	path  string
	state State
}

func newStore(dataDir string) (*store, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data directory: %w", err)
	}
	s := &store{path: filepath.Join(dataDir, "state.json")}
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		s.state = State{Version: 1, Rooms: []Room{}, PublicAccess: true, DefaultCarrier: "jitsi", UpdatedAt: time.Now().UTC()}
		return s, s.persistLocked()
	}
	if err != nil {
		return nil, fmt.Errorf("read state: %w", err)
	}
	if err := json.Unmarshal(data, &s.state); err != nil {
		return nil, fmt.Errorf("decode state: %w", err)
	}
	var persisted map[string]json.RawMessage
	if err := json.Unmarshal(data, &persisted); err != nil {
		return nil, fmt.Errorf("decode state settings: %w", err)
	}
	needsPersist := false
	if _, ok := persisted["publicAccess"]; !ok {
		s.state.PublicAccess = true
		needsPersist = true
	}
	if s.state.DefaultCarrier == "" {
		s.state.DefaultCarrier = "jitsi"
		needsPersist = true
	}
	if needsPersist {
		if err := s.persistLocked(); err != nil {
			return nil, err
		}
	}
	if s.state.Version != 1 {
		return nil, fmt.Errorf("unsupported state version %d", s.state.Version)
	}
	return s, nil
}

func (s *store) snapshot() State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return cloneState(s.state)
}

func (s *store) update(fn func(*State) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.state)
	if err := fn(&next); err != nil {
		return err
	}
	next.UpdatedAt = time.Now().UTC()
	previous := s.state
	s.state = next
	if err := s.persistLocked(); err != nil {
		s.state = previous
		return err
	}
	return nil
}

func (s *store) replace(state State) error {
	if state.Version != 1 {
		return fmt.Errorf("unsupported backup version %d", state.Version)
	}
	return s.update(func(next *State) error {
		*next = cloneState(state)
		return nil
	})
}

func (s *store) persistLocked() error {
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode state: %w", err)
	}
	temp := s.path + ".tmp"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	if err := os.Rename(temp, s.path); err != nil {
		return fmt.Errorf("replace state: %w", err)
	}
	return nil
}

func cloneState(state State) State {
	copy := state
	copy.Rooms = append([]Room(nil), state.Rooms...)
	copy.Grants = append([]Grant(nil), state.Grants...)
	return copy
}

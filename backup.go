package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

var backupMagic = []byte("OLCBACKUP2\n")

func encodeBackup(state State) ([]byte, error) {
	plain, err := json.Marshal(state)
	if err != nil {
		return nil, err
	}
	result := append([]byte{}, backupMagic...)
	result = append(result, plain...)
	return result, nil
}

func decodeBackup(data []byte) (State, error) {
	if len(data) <= len(backupMagic) || string(data[:len(backupMagic)]) != string(backupMagic) {
		return State{}, errors.New("invalid backup file")
	}
	var state State
	if err := json.Unmarshal(data[len(backupMagic):], &state); err != nil {
		return State{}, fmt.Errorf("decode backup: %w", err)
	}
	return state, nil
}

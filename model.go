package main

import "time"

type State struct {
	Version        int       `json:"version"`
	Rooms          []Room    `json:"rooms"`
	Grants         []Grant   `json:"grants,omitempty"`
	PublicAccess   bool      `json:"publicAccess"`
	DefaultCarrier string    `json:"defaultCarrier"`
	UpdatedAt      time.Time `json:"updatedAt"`
}

type Room struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitempty"`
	Carrier     string    `json:"carrier"`
	Transport   string    `json:"transport"`
	RoomID      string    `json:"roomId"`
	KeyHex      string    `json:"keyHex"`
	DNS         string    `json:"dns"`
	VP8FPS      int       `json:"vp8Fps"`
	VP8Batch    int       `json:"vp8Batch"`
	Enabled     bool      `json:"enabled"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type Grant struct {
	ID               string     `json:"id"`
	RoomID           string     `json:"roomId"`
	Name             string     `json:"name"`
	DeviceLimit      int        `json:"deviceLimit"`
	ExpiresAt        *time.Time `json:"expiresAt,omitempty"`
	RevokedAt        *time.Time `json:"revokedAt,omitempty"`
	CreatedAt        time.Time  `json:"createdAt"`
	SubscriptionPath string     `json:"subscriptionPath"`
}

type RoomView struct {
	Room
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
	Link   string `json:"link"`
}

type Dashboard struct {
	Version        string     `json:"version"`
	Rooms          []RoomView `json:"rooms"`
	PublicAccess   bool       `json:"publicAccess"`
	DefaultCarrier string     `json:"defaultCarrier"`
}

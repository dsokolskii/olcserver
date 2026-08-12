package main

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

const version = "0.1.0"

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: olcserver <init|serve|version>")
	}
	switch args[0] {
	case "init":
		return initCommand(args[1:])
	case "serve":
		return serveCommand(args[1:])
	case "version", "--version", "-version":
		fmt.Println(version)
		return nil
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func initCommand(args []string) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	dataDir := flags.String("data", "/var/lib/olcserver", "data directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	password, created, err := ensureAdminPassword(*dataDir)
	if err != nil {
		return err
	}
	if !created {
		return errors.New("admin password already exists; use the password file on the server")
	}
	fmt.Println(password)
	return nil
}

func serveCommand(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := flags.String("listen", "0.0.0.0:8080", "HTTP listen address")
	dataDir := flags.String("data", "/var/lib/olcserver", "data directory")
	olcrtc := flags.String("olcrtc", "/usr/local/bin/olcrtc", "olcrtc executable")
	if err := flags.Parse(args); err != nil {
		return err
	}
	password, created, err := ensureAdminPassword(*dataDir)
	if err != nil {
		return err
	}
	if created {
		log.Printf("generated admin password: %s", password)
	}
	store, err := newStore(*dataDir)
	if err != nil {
		return err
	}
	runtime := newRoomRuntime(*dataDir, *olcrtc)
	defer runtime.stopAll()
	if err := runtime.reconcile(store.snapshot().Rooms); err != nil {
		log.Printf("initial room start failed: %v", err)
	}
	app := newApp(store, runtime, password)
	server := &http.Server{
		Addr:              *listen,
		Handler:           app.routes(),
		ReadHeaderTimeout: defaultHTTPTimeout,
		ReadTimeout:       defaultHTTPTimeout,
		WriteTimeout:      defaultWriteTimeout,
		IdleTimeout:       defaultIdleTimeout,
	}
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stopped
		_ = server.Close()
	}()
	log.Printf("Olc Server %s listening on http://%s", version, *listen)
	err = server.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func ensureAdminPassword(dataDir string) (string, bool, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return "", false, fmt.Errorf("create data directory: %w", err)
	}
	path := filepath.Join(dataDir, "admin-password")
	if data, err := os.ReadFile(path); err == nil {
		return string(data), false, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", false, fmt.Errorf("read admin password: %w", err)
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", false, fmt.Errorf("generate admin password: %w", err)
	}
	password := base64.RawURLEncoding.EncodeToString(raw)
	if err := os.WriteFile(path, []byte(password), 0o600); err != nil {
		return "", false, fmt.Errorf("write admin password: %w", err)
	}
	return password, true, nil
}

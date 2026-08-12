.PHONY: build test check

build:
	go build -trimpath -o build/olcserver .

test:
	go test -race ./...

check:
	gofmt -w *.go
	go vet ./...
	go test -race ./...

package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func SocketPath() (string, error) {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		var err error
		dir, err = os.UserCacheDir()
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(dir, "herdsman", "daemon.sock"), nil
}

// A private directory protects the API (which accepts task prompts), and flock
// gives a single owner permission to replace an abandoned socket after a crash.
func listen(path string) (net.Listener, func(), error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || stat.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
		return nil, nil, fmt.Errorf("socket directory must be user-owned and private (0700): %s", dir)
	}
	lock, err := os.OpenFile(filepath.Join(dir, "daemon.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, nil, fmt.Errorf("another Herdsman daemon owns this socket: %w", err)
	}
	cleanup := func() { _ = lock.Close() }
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		cleanup()
		return nil, nil, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		cleanup()
		return nil, nil, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		listener.Close()
		cleanup()
		return nil, nil, err
	}
	return listener, cleanup, nil
}

func (d *Daemon) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /inventory", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(d.Inventory())
	})
	mux.HandleFunc("POST /requests", func(w http.ResponseWriter, r *http.Request) {
		// JSON escaping can expand each supported 120 KiB title/prompt byte
		// sixfold. Include headroom for selection metadata and descriptions.
		r.Body = http.MaxBytesReader(w, r.Body, 4*1024*1024)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var request Request
		if err := decoder.Decode(&request); err != nil {
			http.Error(w, "invalid or oversized request", http.StatusBadRequest)
			return
		}
		var extra any
		if err := decoder.Decode(&extra); err != io.EOF {
			http.Error(w, "request must contain one JSON object", http.StatusBadRequest)
			return
		}
		if err := d.Submit(request); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	})
	return mux
}

func (d *Daemon) Serve(ctx context.Context, path string) error {
	listener, cleanup, err := listen(path)
	if err != nil {
		return err
	}
	defer cleanup()
	defer listener.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	server := &http.Server{Handler: d.handler(), ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 10 * time.Second}
	done := make(chan struct{})
	go func() { d.Run(ctx); close(done) }()
	go func() { <-ctx.Done(); _ = server.Close() }()
	err = server.Serve(listener)
	cancel()
	<-done
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

type Client struct{ http *http.Client }

// Rejection means a response was received and the server did not enqueue work.
// Transport failures remain uncertain and must not be automatically retried.
type Rejection struct {
	Status int
	Reason string
}

func (r *Rejection) Error() string {
	return fmt.Sprintf("daemon rejected request (%d): %s", r.Status, r.Reason)
}

func NewClient(path string) *Client {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", path)
	}}
	return &Client{http: &http.Client{Transport: transport, Timeout: 3 * time.Second}}
}
func (c *Client) Close() { c.http.CloseIdleConnections() }
func (c *Client) call(ctx context.Context, method, path string, body io.Reader, result any) error {
	request, err := http.NewRequestWithContext(ctx, method, "http://herdsman"+path, body)
	if err != nil {
		return err
	}
	response, err := c.http.Do(request)
	if err != nil {
		return fmt.Errorf("Herdsman daemon unavailable; check the managed service and its logs: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return &Rejection{Status: response.StatusCode, Reason: string(data)}
	}
	if result != nil {
		return json.NewDecoder(io.LimitReader(response.Body, 16*1024*1024)).Decode(result)
	}
	return nil
}
func (c *Client) Inventory(ctx context.Context) (Inventory, error) {
	var i Inventory
	err := c.call(ctx, "GET", "/inventory", nil, &i)
	return i, err
}
func (c *Client) Submit(ctx context.Context, r Request) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return c.call(ctx, "POST", "/requests", bytes.NewReader(data), nil)
}
